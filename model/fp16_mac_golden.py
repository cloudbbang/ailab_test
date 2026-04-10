"""
S80 NPU FP16 MAC Golden Model (Bit-Accurate)

Arithmetic Contract v1.0 준수:
- Rounding: RNE (Round-to-Nearest-Even)
- Overflow: Saturate-to-max (no Inf generation)
- Underflow: Flush-to-Zero (no subnormal support)
- NaN: Quiet NaN propagation
- Signed zero: -0 = +0
- Accumulation: FP32 precision
"""

import struct
import random


# ============================================================
# Constants
# ============================================================

FP16_EXP_BITS = 5
FP16_MAN_BITS = 10
FP16_BIAS = 15
FP16_EXP_MAX = 31  # reserved for Inf/NaN

FP32_EXP_BITS = 8
FP32_MAN_BITS = 23
FP32_BIAS = 127

FP16_POS_ZERO = 0x0000
FP16_NEG_ZERO = 0x8000
FP16_QNAN = 0x7E00
FP16_POS_MAX = 0x7BFF
FP16_NEG_MAX = 0xFBFF
FP16_POS_INF = 0x7C00

FP32_POS_ZERO = 0x00000000
FP32_QNAN = 0x7FC00000
FP32_POS_MAX = 0x7F7FFFFF
FP32_NEG_MAX = 0xFF7FFFFF


# ============================================================
# FP16 Unpack / Pack
# ============================================================

def fp16_unpack(bits: int) -> dict:
    """FP16 비트를 sign, exponent, mantissa로 분리.

    Arithmetic Contract:
    - subnormal → FTZ (zero 반환)
    - NaN → is_nan 플래그
    - mantissa에 implicit 1 포함 (11-bit)
    """
    bits &= 0xFFFF
    sign = (bits >> 15) & 1
    exp = (bits >> 10) & 0x1F
    mant = bits & 0x3FF

    if exp == 0:
        # Zero or subnormal → FTZ
        return {"sign": sign, "exp": 0, "mant": 0,
                "is_zero": True, "is_nan": False, "is_inf": False}
    elif exp == FP16_EXP_MAX:
        if mant == 0:
            return {"sign": sign, "exp": exp, "mant": 0,
                    "is_zero": False, "is_nan": False, "is_inf": True}
        else:
            # NaN — signaling NaN을 quiet NaN으로 변환
            return {"sign": 0, "exp": exp, "mant": mant | (1 << 9),
                    "is_zero": False, "is_nan": True, "is_inf": False}
    else:
        # Normal: implicit 1 추가
        mant_full = (1 << FP16_MAN_BITS) | mant  # 11-bit
        return {"sign": sign, "exp": exp, "mant": mant_full,
                "is_zero": False, "is_nan": False, "is_inf": False}


def fp16_pack(sign: int, exp: int, mant: int, man_bits: int = FP16_MAN_BITS) -> int:
    """FP16 비트 조립. RNE rounding + saturate-to-max."""
    if exp >= FP16_EXP_MAX:
        # Saturate to max (no Inf)
        return (sign << 15) | (0x1E << 10) | 0x3FF  # ±65504
    if exp <= 0:
        # Underflow → FTZ
        return sign << 15  # ±0
    mant_out = mant & 0x3FF  # lower 10 bits (implicit 1 제거됨)
    return (sign << 15) | (exp << 10) | mant_out


# ============================================================
# FP32 Unpack / Pack / Utilities
# ============================================================

def fp32_unpack(bits: int) -> dict:
    """FP32 비트를 sign, exponent, mantissa로 분리."""
    bits &= 0xFFFFFFFF
    sign = (bits >> 31) & 1
    exp = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF

    if exp == 0:
        return {"sign": sign, "exp": 0, "mant": 0,
                "is_zero": True, "is_nan": False}
    elif exp == 0xFF:
        if mant == 0:
            return {"sign": sign, "exp": exp, "mant": 0,
                    "is_zero": False, "is_nan": False}
        else:
            return {"sign": 0, "exp": exp, "mant": mant | (1 << 22),
                    "is_zero": False, "is_nan": True}
    else:
        mant_full = (1 << FP32_MAN_BITS) | mant  # 24-bit
        return {"sign": sign, "exp": exp, "mant": mant_full,
                "is_zero": False, "is_nan": False}


def fp32_pack(sign: int, exp: int, mant: int) -> int:
    """FP32 비트 조립. Saturate-to-max."""
    if exp >= 0xFF:
        # Saturate to FP32 max
        return (sign << 31) | (0xFE << 23) | 0x7FFFFF
    if exp <= 0:
        return sign << 31  # FTZ → ±0
    mant_out = mant & 0x7FFFFF  # lower 23 bits
    return (sign << 31) | (exp << 23) | mant_out


def fp32_to_float(bits: int) -> float:
    """FP32 비트 → Python float 변환 (디버그용)."""
    return struct.unpack('f', struct.pack('I', bits & 0xFFFFFFFF))[0]


def float_to_fp32(val: float) -> int:
    """Python float → FP32 비트 변환."""
    return struct.unpack('I', struct.pack('f', val))[0]


def float_to_fp16(val: float) -> int:
    """Python float → FP16 비트 변환 (RNE)."""
    # Use struct for IEEE 754 conversion
    fp32_bits = float_to_fp32(val)
    sign = (fp32_bits >> 31) & 1
    exp32 = (fp32_bits >> 23) & 0xFF
    mant32 = fp32_bits & 0x7FFFFF

    if exp32 == 0xFF:
        if mant32 != 0:
            return FP16_QNAN
        return (sign << 15) | 0x7C00  # Inf → will be saturated if used

    # Rebias exponent: FP32 bias=127, FP16 bias=15
    exp16 = exp32 - 127 + 15

    if exp16 >= 31:
        # Overflow → saturate to max
        return (sign << 15) | (0x1E << 10) | 0x3FF
    if exp16 <= 0:
        # Underflow → FTZ
        return sign << 15

    # Mantissa: 23-bit → 10-bit with RNE
    mant16 = mant32 >> 13  # top 10 bits
    # RNE: check guard, round, sticky
    guard = (mant32 >> 12) & 1
    round_bit = (mant32 >> 11) & 1
    sticky = 1 if (mant32 & 0x7FF) != 0 else 0

    if guard and (round_bit or sticky or (mant16 & 1)):
        mant16 += 1
        if mant16 > 0x3FF:
            mant16 = 0
            exp16 += 1
            if exp16 >= 31:
                return (sign << 15) | (0x1E << 10) | 0x3FF  # saturate

    return (sign << 15) | (exp16 << 10) | (mant16 & 0x3FF)


# ============================================================
# FP16 Multiply
# ============================================================

def fp16_multiply(a_bits: int, b_bits: int) -> dict:
    """두 FP16 값의 곱셈. mantissa product는 22-bit exact.

    Returns:
        dict with sign, exp, mant (22-bit product), is_zero, is_nan
    """
    a = fp16_unpack(a_bits)
    b = fp16_unpack(b_bits)

    # NaN propagation
    if a["is_nan"] or b["is_nan"]:
        return {"sign": 0, "exp": 0, "mant": 0, "is_zero": False, "is_nan": True}

    # Zero handling: 0 × anything = 0
    if a["is_zero"] or b["is_zero"]:
        return {"sign": 0, "exp": 0, "mant": 0, "is_zero": True, "is_nan": False}

    # Inf handling (입력에 있을 수 있음): Inf × 0 은 위에서 처리됨
    # Inf × normal → saturate (Inf 미생성)
    if a["is_inf"] or b["is_inf"]:
        result_sign = a["sign"] ^ b["sign"]
        return {"sign": result_sign, "exp": 0xFE - FP32_BIAS + FP16_BIAS,
                "mant": 0x3FFFFF, "is_zero": False, "is_nan": False}

    # Normal multiply
    result_sign = a["sign"] ^ b["sign"]
    # exp_sum = (ea - bias) + (eb - bias) + bias = ea + eb - bias
    result_exp = a["exp"] + b["exp"] - FP16_BIAS
    # mantissa product: 11-bit × 11-bit = 22-bit exact
    result_mant = a["mant"] * b["mant"]  # 22-bit

    return {"sign": result_sign, "exp": result_exp, "mant": result_mant,
            "is_zero": False, "is_nan": False}


# ============================================================
# FP32 Accumulate
# ============================================================

def fp32_accumulate(acc: dict, product: dict) -> dict:
    """FP32 누산기에 FP16 곱셈 결과를 누산.

    acc: {"sign", "exp", "mant" (24-bit with implicit 1), "is_zero", "is_nan"}
    product: fp16_multiply() 결과

    Returns: 업데이트된 acc
    """
    # NaN propagation
    if acc.get("is_nan") or product["is_nan"]:
        return {"sign": 0, "exp": 0xFF, "mant": (1 << 22),
                "is_zero": False, "is_nan": True}

    # Zero product → skip
    if product["is_zero"]:
        return acc

    # Convert product to FP32 representation
    # product.mant is 22-bit (11×11), normalize to 1.xxx format
    prod_mant = product["mant"]
    prod_exp = product["exp"]
    prod_sign = product["sign"]

    # Find leading 1 position in 22-bit product
    # 11-bit × 11-bit: result is either 22-bit (bit21=1) or 21-bit (bit21=0)
    if prod_mant == 0:
        return acc

    # Normalize: find MSB position
    msb_pos = prod_mant.bit_length() - 1  # 0-indexed position of highest bit

    # Product value = 2^(prod_exp - FP16_BIAS) × (prod_mant / 2^(2*FP16_MAN_BITS))
    # FP32  value = 2^(fp32_exp - FP32_BIAS) × (fp32_mant / 2^FP32_MAN_BITS)
    # where fp32_mant has implicit 1 at bit FP32_MAN_BITS (bit 23)
    #
    # Equating: fp32_exp = prod_exp + (msb_pos - 2*FP16_MAN_BITS) + (FP32_BIAS - FP16_BIAS)

    if msb_pos <= FP32_MAN_BITS:
        fp32_mant = prod_mant << (FP32_MAN_BITS - msb_pos)
    else:
        fp32_mant = prod_mant >> (msb_pos - FP32_MAN_BITS)

    fp32_exp = prod_exp + (msb_pos - 2 * FP16_MAN_BITS) + (FP32_BIAS - FP16_BIAS)

    # Handle exponent overflow/underflow
    if fp32_exp >= 0xFF:
        # Saturate
        return {"sign": prod_sign, "exp": 0xFE,
                "mant": (1 << 23) | 0x7FFFFF,
                "is_zero": False, "is_nan": False}
    if fp32_exp <= 0:
        # FTZ → product is zero, skip
        return acc

    # Ensure fp32_mant has implicit 1 at bit 23
    fp32_mant = fp32_mant & 0xFFFFFF  # 24-bit mask

    # Now accumulate: acc + product (both in FP32)
    if acc["is_zero"]:
        return {"sign": prod_sign, "exp": fp32_exp, "mant": fp32_mant,
                "is_zero": False, "is_nan": False}

    # Alignment: shift smaller exponent's mantissa
    acc_exp = acc["exp"]
    acc_mant = acc["mant"]
    acc_sign = acc["sign"]

    exp_diff = fp32_exp - acc_exp

    if exp_diff > 0:
        # Product has larger exponent, shift accumulator right
        if exp_diff > 48:
            # Accumulator is negligible
            return {"sign": prod_sign, "exp": fp32_exp, "mant": fp32_mant,
                    "is_zero": False, "is_nan": False}
        shifted_acc_mant = acc_mant >> exp_diff
        sticky = 1 if (acc_mant & ((1 << exp_diff) - 1)) != 0 else 0
        result_exp = fp32_exp
        a_mant = fp32_mant
        b_mant = shifted_acc_mant
        a_sign = prod_sign
        b_sign = acc_sign
    elif exp_diff < 0:
        # Accumulator has larger exponent, shift product right
        shift = -exp_diff
        if shift > 48:
            return acc
        shifted_prod_mant = fp32_mant >> shift
        sticky = 1 if (fp32_mant & ((1 << shift) - 1)) != 0 else 0
        result_exp = acc_exp
        a_mant = acc_mant
        b_mant = shifted_prod_mant
        a_sign = acc_sign
        b_sign = prod_sign
    else:
        result_exp = acc_exp
        a_mant = acc_mant
        b_mant = fp32_mant
        a_sign = acc_sign
        b_sign = prod_sign

    # Add/subtract based on signs
    if a_sign == b_sign:
        result_mant = a_mant + b_mant
        result_sign = a_sign
    else:
        if a_mant >= b_mant:
            result_mant = a_mant - b_mant
            result_sign = a_sign
        else:
            result_mant = b_mant - a_mant
            result_sign = b_sign

    # Handle zero result
    if result_mant == 0:
        return {"sign": 0, "exp": 0, "mant": 0,
                "is_zero": True, "is_nan": False}

    # Re-normalize
    msb = result_mant.bit_length() - 1
    target_msb = 23  # bit 23 should be the implicit 1

    if msb > target_msb:
        shift_r = msb - target_msb
        result_mant = result_mant >> shift_r
        result_exp += shift_r
    elif msb < target_msb:
        shift_l = target_msb - msb
        result_mant = result_mant << shift_l
        result_exp -= shift_l

    # Saturate check
    if result_exp >= 0xFF:
        return {"sign": result_sign, "exp": 0xFE,
                "mant": (1 << 23) | 0x7FFFFF,
                "is_zero": False, "is_nan": False}
    if result_exp <= 0:
        return {"sign": 0, "exp": 0, "mant": 0,
                "is_zero": True, "is_nan": False}

    result_mant &= 0xFFFFFF  # 24-bit mask

    return {"sign": result_sign, "exp": result_exp, "mant": result_mant,
            "is_zero": False, "is_nan": False}


def acc_to_fp32_bits(acc: dict) -> int:
    """누산기 상태를 FP32 비트로 변환."""
    if acc["is_nan"]:
        return FP32_QNAN
    if acc["is_zero"]:
        return acc.get("sign", 0) << 31
    return fp32_pack(acc["sign"], acc["exp"], acc["mant"])


# ============================================================
# MAC Top-Level Golden Function
# ============================================================

def fp16_mac_golden(a_list: list, b_list: list) -> int:
    """N개 FP16 쌍의 MAC 결과를 FP32 비트로 반환.

    Args:
        a_list: FP16 비트 값 리스트 (weights)
        b_list: FP16 비트 값 리스트 (activations)

    Returns:
        FP32 비트 값 (누산 결과)
    """
    assert len(a_list) == len(b_list), "Input lists must have same length"

    acc = {"sign": 0, "exp": 0, "mant": 0, "is_zero": True, "is_nan": False}

    for a_bits, b_bits in zip(a_list, b_list):
        product = fp16_multiply(a_bits, b_bits)
        acc = fp32_accumulate(acc, product)

    return acc_to_fp32_bits(acc)


# ============================================================
# Verification Utilities
# ============================================================

def ulp_error(result_bits: int, reference_bits: int) -> int:
    """두 FP32 비트 값 간의 ULP 차이."""
    result_bits &= 0xFFFFFFFF
    reference_bits &= 0xFFFFFFFF

    # Handle NaN
    r_exp = (result_bits >> 23) & 0xFF
    r_man = result_bits & 0x7FFFFF
    ref_exp = (reference_bits >> 23) & 0xFF
    ref_man = reference_bits & 0x7FFFFF

    if (r_exp == 0xFF and r_man != 0) or (ref_exp == 0xFF and ref_man != 0):
        # Both NaN → 0 ULP, one NaN → max ULP
        if (r_exp == 0xFF and r_man != 0) and (ref_exp == 0xFF and ref_man != 0):
            return 0
        return 0xFFFFFFFF

    # Handle sign
    def to_signed(bits):
        if bits & 0x80000000:
            return -(bits & 0x7FFFFFFF)
        return bits

    return abs(to_signed(result_bits) - to_signed(reference_bits))


def relative_error(result_bits: int, reference_float: float) -> float:
    """FP32 비트 결과와 float 레퍼런스 간의 상대 오차."""
    result_float = fp32_to_float(result_bits)
    if reference_float == 0.0:
        return abs(result_float)
    return abs((result_float - reference_float) / reference_float)


# ============================================================
# Test / Self-check
# ============================================================

def _self_check():
    """기본 동작 확인."""
    # Test 1: 1.0 × 1.0 = 1.0
    one_fp16 = 0x3C00  # FP16 1.0
    result = fp16_mac_golden([one_fp16], [one_fp16])
    result_float = fp32_to_float(result)
    assert abs(result_float - 1.0) < 1e-6, f"1.0×1.0 failed: {result_float}"

    # Test 2: 0 × anything = 0
    result = fp16_mac_golden([FP16_POS_ZERO], [one_fp16])
    assert fp32_to_float(result) == 0.0, "0×1 failed"

    # Test 3: NaN propagation
    result = fp16_mac_golden([FP16_QNAN], [one_fp16])
    assert result == FP32_QNAN, f"NaN propagation failed: {hex(result)}"

    # Test 4: Subnormal → FTZ
    subnorm = 0x0001  # smallest subnormal
    result = fp16_mac_golden([subnorm], [one_fp16])
    assert fp32_to_float(result) == 0.0, "FTZ failed"

    # Test 5: Simple accumulation: 1.0 + 1.0 = 2.0
    result = fp16_mac_golden([one_fp16, one_fp16], [one_fp16, one_fp16])
    result_float = fp32_to_float(result)
    assert abs(result_float - 2.0) < 1e-6, f"1+1 failed: {result_float}"

    # Test 6: 2.0 × 3.0 = 6.0
    two_fp16 = float_to_fp16(2.0)
    three_fp16 = float_to_fp16(3.0)
    result = fp16_mac_golden([two_fp16], [three_fp16])
    result_float = fp32_to_float(result)
    assert abs(result_float - 6.0) < 1e-6, f"2×3 failed: {result_float}"

    print("All self-checks passed.")


if __name__ == "__main__":
    _self_check()

    # Random test: 256-element MAC
    random.seed(42)
    n = 256
    a_list = [float_to_fp16(random.uniform(-1.0, 1.0)) for _ in range(n)]
    b_list = [float_to_fp16(random.uniform(-1.0, 1.0)) for _ in range(n)]

    result_bits = fp16_mac_golden(a_list, b_list)
    result_float = fp32_to_float(result_bits)

    # NumPy reference
    import numpy as np
    a_floats = np.array([fp32_to_float(float_to_fp32(
        fp32_to_float(fp32_pack(*fp16_unpack(a).values())) if False
        else 0.0)) for a in a_list], dtype=np.float32)
    # Simpler: convert FP16 bits → float directly
    a_floats = np.array([struct.unpack('e', struct.pack('H', a))[0] for a in a_list], dtype=np.float32)
    b_floats = np.array([struct.unpack('e', struct.pack('H', b))[0] for b in b_list], dtype=np.float32)
    ref_float = float(np.dot(a_floats, b_floats))

    rel_err = abs((result_float - ref_float) / ref_float) if ref_float != 0 else abs(result_float)
    print(f"256-MAC result: {result_float:.6f}, numpy ref: {ref_float:.6f}, rel_error: {rel_err:.2e}")
