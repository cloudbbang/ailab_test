"""
S80 NPU FP16 MAC - cocotb Testbench
Arithmetic Contract v1.0 검증

Test cases:
  1. test_single_mac       - 단일 곱셈 + 누산
  2. test_basic_values     - 기본 값 검증 (1×1, 2×3, etc.)
  3. test_special_values   - 0, NaN, subnormal(→FTZ), max
  4. test_accumulate_256   - 256개 누산 후 FP32 정확도
  5. test_random_pairs     - 랜덤 FP16 쌍 검증
"""

import sys
import os
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Add model directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'model'))
from fp16_mac_golden import (
    fp16_mac_golden, fp16_unpack, fp16_multiply,
    fp32_to_float, float_to_fp16, float_to_fp32,
    ulp_error, relative_error,
    FP16_POS_ZERO, FP16_NEG_ZERO, FP16_QNAN, FP16_POS_MAX,
    FP32_QNAN
)


async def reset_dut(dut):
    """DUT 리셋."""
    dut.rst_n.value = 0
    dut.clear.value = 0
    dut.valid_in.value = 0
    dut.fp16_a.value = 0
    dut.fp16_b.value = 0
    dut.last.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def clear_acc(dut):
    """누산기 클리어."""
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)


async def run_mac(dut, a_list, b_list):
    """MAC 연산 실행 후 결과 반환.

    Args:
        a_list: FP16 비트 값 리스트
        b_list: FP16 비트 값 리스트

    Returns:
        FP32 결과 비트 값
    """
    await clear_acc(dut)

    n = len(a_list)
    for i in range(n):
        dut.valid_in.value = 1
        dut.fp16_a.value = a_list[i]
        dut.fp16_b.value = b_list[i]
        dut.last.value = 1 if i == n - 1 else 0
        await RisingEdge(dut.clk)

    dut.valid_in.value = 0
    dut.last.value = 0

    # Wait for result (pipeline latency: ~5-6 cycles after last input)
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.result_valid.value == 1:
            return int(dut.fp32_result.value)

    # Timeout
    return None


@cocotb.test()
async def test_single_mac(dut):
    """Test 1: 단일 곱셈 1.0 × 1.0 = 1.0"""
    clock = Clock(dut.clk, 10, units="ns")  # 100 MHz
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    one = float_to_fp16(1.0)
    result = await run_mac(dut, [one], [one])

    assert result is not None, "Timeout waiting for result"
    result_float = fp32_to_float(result)
    assert abs(result_float - 1.0) < 1e-4, \
        f"Expected 1.0, got {result_float} (0x{result:08X})"
    dut._log.info(f"PASS: 1.0 × 1.0 = {result_float}")


@cocotb.test()
async def test_basic_values(dut):
    """Test 2: 기본 값 검증."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    test_cases = [
        (2.0, 3.0, 6.0,   "2×3=6"),
        (0.5, 4.0, 2.0,   "0.5×4=2"),
        (-1.0, 1.0, -1.0, "-1×1=-1"),
        (-2.0, -3.0, 6.0, "-2×-3=6"),
        (100.0, 0.01, 1.0, "100×0.01≈1"),
    ]

    for a_val, b_val, expected, desc in test_cases:
        a_fp16 = float_to_fp16(a_val)
        b_fp16 = float_to_fp16(b_val)
        result = await run_mac(dut, [a_fp16], [b_fp16])

        assert result is not None, f"Timeout: {desc}"
        result_float = fp32_to_float(result)
        golden = fp16_mac_golden([a_fp16], [b_fp16])
        golden_float = fp32_to_float(golden)

        ulp = ulp_error(result, golden)
        assert ulp <= 2, \
            f"{desc}: ULP error {ulp} > 2 (got {result_float}, golden {golden_float})"
        dut._log.info(f"PASS: {desc} = {result_float} (ULP={ulp})")


@cocotb.test()
async def test_special_values(dut):
    """Test 3: 특수값 처리 (Arithmetic Contract 준수)."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    one = float_to_fp16(1.0)

    # Zero × anything = 0
    result = await run_mac(dut, [FP16_POS_ZERO], [one])
    assert result is not None
    assert fp32_to_float(result) == 0.0, f"0×1 should be 0, got {fp32_to_float(result)}"
    dut._log.info("PASS: 0 × 1 = 0")

    # NaN propagation
    result = await run_mac(dut, [FP16_QNAN], [one])
    assert result is not None
    # Check NaN: exp=0xFF, mant≠0
    r_exp = (result >> 23) & 0xFF
    r_mant = result & 0x7FFFFF
    assert r_exp == 0xFF and r_mant != 0, \
        f"NaN not propagated: 0x{result:08X}"
    dut._log.info("PASS: NaN propagation")

    # Subnormal → FTZ
    subnorm = 0x0001  # smallest FP16 subnormal
    result = await run_mac(dut, [subnorm], [one])
    assert result is not None
    assert fp32_to_float(result) == 0.0, \
        f"Subnormal should FTZ to 0, got {fp32_to_float(result)}"
    dut._log.info("PASS: Subnormal FTZ")

    # Negative zero
    result = await run_mac(dut, [FP16_NEG_ZERO], [one])
    assert result is not None
    assert fp32_to_float(result) == 0.0, f"-0 × 1 should be 0"
    dut._log.info("PASS: -0 × 1 = 0")


@cocotb.test()
async def test_accumulate_256(dut):
    """Test 4: 256개 FP16 쌍 누산 후 FP32 정확도 검증."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    random.seed(42)
    n = 256
    a_list = [float_to_fp16(random.uniform(-1.0, 1.0)) for _ in range(n)]
    b_list = [float_to_fp16(random.uniform(-1.0, 1.0)) for _ in range(n)]

    # Golden reference
    golden_bits = fp16_mac_golden(a_list, b_list)
    golden_float = fp32_to_float(golden_bits)

    # DUT
    result = await run_mac(dut, a_list, b_list)
    assert result is not None, "Timeout on 256-MAC"

    result_float = fp32_to_float(result)
    ulp = ulp_error(result, golden_bits)
    rel_err = relative_error(result, golden_float)

    dut._log.info(f"256-MAC: result={result_float:.6f}, golden={golden_float:.6f}, "
                  f"ULP={ulp}, rel_err={rel_err:.2e}")

    assert ulp <= 2, f"ULP error {ulp} > 2"
    assert rel_err < 0.001, f"Relative error {rel_err} > 0.1%"


@cocotb.test()
async def test_random_pairs(dut):
    """Test 5: 랜덤 FP16 쌍 1000개 개별 검증."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    random.seed(123)
    fail_count = 0

    for i in range(1000):
        a_val = random.uniform(-100.0, 100.0)
        b_val = random.uniform(-100.0, 100.0)
        a_fp16 = float_to_fp16(a_val)
        b_fp16 = float_to_fp16(b_val)

        golden_bits = fp16_mac_golden([a_fp16], [b_fp16])
        result = await run_mac(dut, [a_fp16], [b_fp16])

        if result is None:
            fail_count += 1
            continue

        ulp = ulp_error(result, golden_bits)
        if ulp > 2:
            fail_count += 1
            if fail_count <= 5:  # Log first 5 failures
                dut._log.error(
                    f"Pair {i}: a=0x{a_fp16:04X} b=0x{b_fp16:04X} "
                    f"result=0x{result:08X} golden=0x{golden_bits:08X} ULP={ulp}")

    assert fail_count == 0, f"{fail_count}/1000 random pairs failed (ULP > 2)"
    dut._log.info(f"PASS: 1000 random pairs, all ULP ≤ 2")
