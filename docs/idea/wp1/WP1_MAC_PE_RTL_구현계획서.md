# WP1: MAC/PE RTL 설계 구현 계획서

**작성일:** 2026-03-25
**최종 수정:** 2026-03-25 (Codex/Gemini 리뷰 반영)
**상위 문서:** S80 NPU Vivado FPGA 구현 완성 계획서
**범위:** FP16 MAC → 멀티정밀도 MAC → VE → TE/CE 계층 확장 → KCU116 실증
**목표:** FPGA 상에서 FP16/FP8 멀티정밀도 MAC Array 기반 연산 엔진 구현 및 검증

---

## 목차

1. [개요 및 선행 조건](#1-개요-및-선행-조건)
2. [R0: 산술 계약 및 사전 분석](#2-r0-산술-계약-및-사전-분석)
3. [M1: FP16 MAC 단일 유닛 구현](#3-m1-fp16-mac-단일-유닛-구현)
4. [M2: 멀티정밀도 MAC 구현](#4-m2-멀티정밀도-mac-구현)
5. [M3: Village Engine (VE) 구현](#5-m3-village-engine-ve-구현)
6. [M4: TE/CE 계층 확장](#6-m4-tece-계층-확장)
7. [M5: KCU116 FPGA 통합 검증](#7-m5-kcu116-fpga-통합-검증)
8. [RTL 파일 구조 및 코딩 규칙](#8-rtl-파일-구조-및-코딩-규칙)
9. [검증 전략](#9-검증-전략)
10. [리소스 예산 및 리스크](#10-리소스-예산-및-리스크)
11. [일정 요약](#11-일정-요약)

---

## 1. 개요 및 선행 조건

### 1.1 현재 상태

| 항목 | 현재 값 |
|------|---------|
| FPGA 보드 | KCU116 (XCKU5P) |
| 구현 규모 | 1 MVE, 4 sub, 256 MAC |
| 데이터 타입 | INT16 only |
| 클럭 | 100 MHz |
| 검증된 연산 | 256x256 GEMV |

### 1.2 WP1 완료 후 목표 상태

| 항목 | 목표 값 |
|------|---------|
| 데이터 타입 | FP16/FP8 (FP32 누산) |
| MAC 구조 | 128 MAC/VE, DSP-Packing 기반 |
| 계층 구조 | VE → TE(4 VE) 보드 실증, CE(4 TE) RTL/시뮬레이션 검증 |
| 클럭 | pilot synthesis 기준 200 MHz feasibility 확인 후 full closure |
| 검증 수준 | cocotb + Verilator + UVM + ILA 실증 |

### 1.3 실증 목표와 아키텍처 목표 분리

KCU116 (XCKU5P)은 DSP48E2 1,824개이므로 full CE(2,048 DSP)는 물리적으로 수용 불가.
따라서 목표를 명확히 둘로 나눈다.

| 구분 | 대상 | 범위 |
|------|------|------|
| **보드 실증 목표** | KCU116 | 1 TE(4 VE, 512 MAC) 또는 축소형 다중 VE |
| **아키텍처 목표** | RTL/시뮬레이션 | CE 기능 정의 + RTL 확장 가능성 확보 |

CE 보드 실증은 차기 보드(VCU118)로 이월.

### 1.4 선행 조건 (다른 WP에서 필요한 사항)

| 선행 항목 | 담당 WP | 필요 시점 | 설명 |
|-----------|---------|----------|------|
| Weight File URAM 매핑 | WP2 | M3 시작 전 | VE의 Weight File은 URAM 2개 카스케이드 |
| DDR4 MIG 링크업 | WP2 | M5 시작 전 | 외부 데이터 로드를 위한 MIG IP |
| XDMA PCIe 링크업 | WP4 | M5 시작 전 | 호스트 통신 |
| 검증 인프라 (CI/CD) | WP6 | M1 시작 시 | 매 커밋 자동 시뮬레이션 |

### 1.5 핵심 설계 원칙

1. **증명 우선 (Proof-First)** — 기능 확장보다 축소 모델의 합성/배치 검증을 먼저 수행
2. **커스텀 RTL 우선** — Xilinx FP IP 대신 직접 설계하여 멀티정밀도 지원과 리소스 효율 확보
3. **저정밀도 곱셈 + FP32 누산** — 수치 안정성 확보의 핵심 원칙
4. **파이프라인 설계** — 매 사이클 1개 결과 출력 가능하도록 fully-pipelined 구조
5. **ASIC 전환 대비** — `ifdef FPGA` / `ifdef ASIC` 으로 코드 이중화 준비

---

## 2. R0: 산술 계약 및 사전 분석

**기간:** 1~2주 (M1 착수 전 필수)
**산출물:** `arithmetic_contract.md`, `bandwidth_budget.md`, Python bit-accurate 모델, pilot synthesis 리포트

RTL 코딩 전에 산술 규약과 물리 제약을 먼저 닫아야 골든 모델/RTL/테스트벤치가 서로 다른 해석으로 흔들리는 것을 방지할 수 있다.

### 2.1 Arithmetic Contract (산술 계약)

RTL, 골든 모델, 테스트벤치가 동일한 기준으로 동작하려면 다음 항목이 구현 전에 확정되어야 한다.

| 항목 | 정의 내용 |
|------|----------|
| 지원 포맷 | FP16 (E5M10), FP8 E4M3, FP8 E5M2(확장 예비), FP4 E2M1(연구) |
| Rounding Mode | Round-to-Nearest-Even (RNE) |
| Overflow 정책 | Saturate-to-max (Inf 미사용) 또는 Inf 전파 — **택 1 확정 필수** |
| Underflow 정책 | Flush-to-Zero (FTZ) — subnormal 미지원 |
| NaN 전파 규칙 | Quiet NaN 전파, Signaling NaN → Quiet NaN 변환 |
| Signed Zero | -0 = +0 동일 취급 |
| 누산 경계 | MAC 내부 FP32 누산, Adder Tree도 FP32 유지 |
| 모드 전환 시 규칙 | 파이프라인 완전 flush 후 모드 변경 |

이 계약 문서를 기준으로 Python bit-accurate 모델과 RTL SVA assertion을 동시에 작성한다.

### 2.2 Bandwidth & Dataflow Budget

메모리 구조를 "용량"이 아닌 "사이클당 공급량" 관점에서 정량화한다.

| 항목 | 분석 내용 |
|------|----------|
| 정밀도별 cycle당 weight/input 소비량 | FP16: 128×16bit = 256B/cycle, FP8: 128×8bit = 128B/cycle |
| URAM bank 수 및 포트 계획 | VE당 URAM 2개, read 포트 1개/cycle |
| URAM read latency 정렬 | OREG 활성화 시 +1 cycle → 파이프라인 모델에 반영 필수 |
| Single/Double buffer 전환 기준 | DMA 로드 시간 > MAC 연산 시간이면 double buffer 필수 |
| Dataflow 선언 | **Weight-Stationary** (가중치 URAM 상주, 입력 스트리밍) |
| Roofline 분석 | DDR4 15 GB/s 기준 Compute-bound/Memory-bound 경계 산출 |

### 2.3 Pilot Synthesis (더미 합성)

M1/M2 코딩 전에 DSP48E2 + URAM 더미 모듈로 200 MHz 라우팅 가능성을 선행 확인한다.

| 실험 | 내용 | 판단 기준 |
|------|------|----------|
| DSP 배치 실험 | 128개 DSP48E2 인스턴스 + fan-out | routing congestion level |
| URAM 거리 실험 | URAM ↔ DSP 간 배선 지연 | setup slack @ 200 MHz |
| Pblock 초안 | VE 단위 물리 배치 영역 지정 | DSP/URAM co-location 가능 여부 |

### 2.4 구현 태스크

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 0-1 | Arithmetic Contract 작성 | 2일 | `arithmetic_contract.md` |
| 0-2 | Python bit-accurate 모델 (DSP48E2 48-bit accumulator 모사) | 3일 | `fp_golden_model.py` |
| 0-3 | Bandwidth & Dataflow Budget + Roofline 분석 | 2일 | `bandwidth_budget.md` |
| 0-4 | Pilot Synthesis (DSP+URAM 더미) | 2일 | 합성/배치 리포트, Pblock 초안 |
| 0-5 | cocotb + Verilator 환경 구축 | 2일 | 검증 인프라 |

### 2.5 Exit Criteria

> **산술 계약 문서가 팀 합의로 확정되고, pilot synthesis에서 200 MHz 가능성이 확인되면 M1 진입. pilot에서 심각한 routing congestion이 발견되면 MAC 수/클럭 목표를 조정한 뒤 진입.**

---

## 3. M1: FP16 MAC 단일 유닛 구현

**기간:** 2주 (R0 완료 후)
**산출물:** `fp16_mac.sv`, 검증 Testbench
**선행:** R0 Arithmetic Contract 확정

### 3.1 FP16 포맷 정의

```
IEEE 754 Half-Precision (FP16):
  [15]    Sign (1-bit)
  [14:10] Exponent (5-bit, bias=15)
  [9:0]   Mantissa (10-bit, implicit 1 → 실효 11-bit)
```

### 3.2 FP16 MAC 마이크로아키텍처

```
             ┌──────────────┐
  A[15:0] ───┤ Unpack       ├─── sign_a, exp_a[4:0], mant_a[10:0]
  B[15:0] ───┤ (FP16→분리)   ├─── sign_b, exp_b[4:0], mant_b[10:0]
             └──────┬───────┘
                    │
        ┌───────────▼───────────┐
        │ Stage 1: Mantissa Mul │  ← DSP48E2 (11x11 < 27x18)
        │   prod = mant_a * mant_b  (22-bit)
        │   exp_sum = exp_a + exp_b - bias(15)
        │   sign_out = sign_a ^ sign_b
        └───────────┬───────────┘
                    │
        ┌───────────▼───────────┐
        │ Stage 2: Alignment    │  ← LUT/MUX (~80 LUT)
        │   exp_diff = exp_sum - acc_exp
        │   aligned = prod >> exp_diff (또는 acc >> diff)
        └───────────┬───────────┘
                    │
        ┌───────────▼───────────┐
        │ Stage 3: FP32 Accum   │  ← DSP48E2 또는 LUT (~100 LUT)
        │   acc += aligned_prod
        │   (FP32 정밀도 유지)
        └───────────┬───────────┘
                    │
        ┌───────────▼───────────┐
        │ Stage 4: Normalize    │  ← LUT (~90 LUT)
        │   Leading Zero Detect
        │   Shift + Round (RNE)
        └───────────┬───────────┘
                    │
              result[31:0] (FP32 누산 결과)
```

### 3.3 DSP48E2 활용 상세

```
DSP48E2 포트 매핑:
  A[29:0] = {19'b0, mant_a[10:0]}   (11-bit mantissa + implicit 1)
  B[17:0] = {7'b0, mant_b[10:0]}
  P[47:0] = A * B                    (22-bit 유효 결과)

  동작 모드: MULTIPLY (OPMODE = 7'b000_01_01)
  파이프라인: AREG=1, BREG=1, MREG=1 → 3-stage
```

### 3.4 리소스 예산 (MAC 1개당)

| 구성 요소 | DSP48E2 | LUT | FF |
|-----------|---------|-----|----|
| Mantissa Multiply | 1 | 0 | 0 |
| Exponent Add + Bias | 0 | ~30 | ~15 |
| Alignment Shifter | 0 | ~80 | ~40 |
| FP32 Accumulator | 0~1 | ~100 | ~50 |
| Normalize + Round | 0 | ~90 | ~45 |
| **합계** | **1~2** | **~300** | **~150** |

### 3.5 구현 태스크

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 1-1 | 패키지 정의 (s80_pkg.sv) | 1일 | FP16/FP32 타입, 상수, 유틸 함수 |
| 1-2 | FP16 Unpack/Pack 모듈 | 1일 | `fp16_unpack.sv`, `fp16_pack.sv` |
| 1-3 | DSP48E2 Wrapper (mantissa mul) | 2일 | `dsp48_mul_wrapper.sv` |
| 1-4 | Exponent 연산 + Alignment Shifter | 2일 | FP16 MAC 내부 |
| 1-5 | FP32 Accumulator | 1일 | FP32 누산기 |
| 1-6 | Normalizer + Rounder (RNE) | 2일 | Leading-zero detect, round |
| 1-7 | FP16 MAC Top 통합 | 1일 | `fp16_mac.sv` |
| 1-8 | cocotb Testbench + 골든 모델 연동 검증 | 2일 | `test_fp16_mac.py` |
| 1-9 | Vivado 합성 + 리소스 확인 | 1일 | 합성 리포트 |

### 3.6 검증 항목

- [ ] 정상 입력: 랜덤 FP16 값 10,000쌍 → R0 골든 모델과 비교 (ULP 오차 ≤ 2)
- [ ] Arithmetic Contract 준수: subnormal FTZ, NaN 전파, overflow 정책 일치
- [ ] 누산 정밀도: 256개 FP16 곱의 누산 → FP32 레퍼런스 대비 상대 오차 < 0.1%
- [ ] 오버플로우/언더플로우: Arithmetic Contract에 명시된 정책대로 동작
- [ ] 파이프라인 throughput: 매 사이클 새 입력 가능 (no stall)
- [ ] 타이밍: 합성 후 200 MHz feasibility 확인

### 3.7 성공 기준

> **256x256 FP16 GEMV 연산 결과가 R0 골든 모델과 Arithmetic Contract 기준으로 정확 일치하며, 합성 후 200 MHz setup slack이 양수**

---

## 4. M2: 멀티정밀도 MAC 구현

**기간:** 4주 (M2-A 2주 + M2-B 2주)
**산출물:** `multi_prec_mac.sv`
**선행:** M1 완료

### 4.1 단계 분리 및 FP4 정책

FP8/FP4를 한 번에 구현하는 것은 packing 난이도 대비 일정 리스크가 크다. 단계를 나눈다.

| 단계 | 대상 | 성격 | 기간 |
|------|------|------|------|
| **M2-A** | FP8 E4M3 2-MAC packing | **제품 기능** — 필수 구현 | 2주 |
| **M2-B** | FP8 E5M2 옵션 + guard bit 안전성 강화 | **1차 확장** — 인터페이스 확보 | 2주 |
| **M2-C** | FP4 E2M1 feasibility study | **연구 기능** — M2-A/B 성공 후 채택 결정 | 별도 |

**FP4 정책:** FP4는 곱셈 자체는 저비용이나, 정규화/반올림/예외처리의 상대적 비용이 커서 총 이득이 불확실하다. M2-A에서 FP8 packing이 독립 MAC 정확도를 만족하고, guard bit 안전성이 수학적으로 증명된 후에만 FP4 진입 여부를 결정한다.

### 4.2 DSP-Packing 전략

| 정밀도 | DSP48E2 1개당 MAC 수 | 패킹 방법 | 누산 정밀도 |
|--------|---------------------|----------|-----------|
| FP16 (E5M10) | 1 MAC | 11×11 mantissa 직접 매핑 | FP32 |
| FP8 E4M3 | 2 MAC | 입력 분할 (4×4 두 쌍) | FP32 |
| FP8 E5M2 | 2 MAC | 입력 분할 (3×3 두 쌍) | FP32 |
| FP4 E2M1 | 4~6 MAC | MR-Overpacking (연구) | FP32 |

### 4.3 FP8 2-MAC 패킹 상세

```
DSP48E2 (27x18) 내에서 FP8 E4M3 mantissa (4-bit) 두 쌍 동시 처리:

  A[29:0] = { 0, mant_a1[3:0], guard[8:0], mant_a0[3:0], 0[4:0] }
  B[17:0] = { 0, mant_b1[3:0], guard[4:0], mant_b0[3:0] }

  P = A * B → 결과에서 두 곱을 비트 위치로 분리
    prod_0 = P[8:0]    (하위 FP8 곱)
    prod_1 = P[25:17]  (상위 FP8 곱)

  ※ Guard bits로 두 곱의 교차 오염(cross-contamination) 방지
```

**Guard bit 안전성 검증 필수:** R0의 Python bit-accurate 모델로 DSP48E2의 48-bit accumulator 동작과 carry 전파를 정확히 모사하여, guard bit 최소 폭과 cross-term 제거 조건을 수학적으로 증명한 뒤 RTL에 진입한다.

### 4.4 멀티정밀도 모드 선택

```systemverilog
typedef enum logic [1:0] {
    PREC_FP16    = 2'b00,  // 1 MAC/DSP
    PREC_FP8_E4  = 2'b01,  // 2 MAC/DSP (E4M3)
    PREC_FP8_E5  = 2'b10,  // 2 MAC/DSP (E5M2)
    PREC_FP4     = 2'b11   // 4-6 MAC/DSP (연구, 미구현 예비)
} precision_mode_t;
```

E5M2를 별도 모드로 분리하여 향후 OCP MX 규격 호환성을 확보한다. FP4 슬롯은 예비로 남겨둔다.

### 4.5 멀티정밀도 MAC 아키텍처

```
                     precision_mode[1:0]
                            │
             ┌──────────────▼──────────────┐
  A[15:0] ───┤  Precision-Aware Unpacker    │
  B[15:0] ───┤  FP16→1쌍, FP8→2쌍           │
             └──────────────┬──────────────┘
                            │
             ┌──────────────▼──────────────┐
             │  DSP48E2 Wrapper             │
             │  (패킹 방식에 따라 입력 배치)    │
             └──────────────┬──────────────┘
                            │
             ┌──────────────▼──────────────┐
             │  Result Unpacker + Aligner   │
             │  (곱 결과 분리 + 지수 보정)     │
             └──────────────┬──────────────┘
                            │
             ┌──────────────▼──────────────┐
             │  FP32 Accumulator(s)         │
             │  FP16: 1개, FP8: 2개         │
             └──────────────┬──────────────┘
                            │
                     result[31:0] × N
```

### 4.6 구현 태스크

**M2-A (FP8 E4M3, 2주):**

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 2-1 | Guard bit 최소 폭 Python 증명 | 2일 | 수학적 증명 리포트 |
| 2-2 | FP8 E4M3 Unpack/Pack | 1일 | `fp8_unpack.sv`, `fp8_pack.sv` |
| 2-3 | FP8 2-MAC DSP Packing | 3일 | DSP48E2 입력 배치 + 결과 분리 |
| 2-4 | Precision MUX + Mode Select | 2일 | 모드 전환 로직 |
| 2-5 | 멀티 FP32 Accumulator (2-bank) | 1일 | FP8 다중 누산기 |
| 2-6 | cocotb 검증 + cross-contamination 집중 테스트 | 3일 | `test_fp8_packing.py` |
| 2-7 | 합성 + DSP 절감률 vs LUT 증가율 분석 | 1일 | packing 분석 리포트 |

**M2-B (FP8 E5M2 + 통합, 2주):**

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 2-8 | FP8 E5M2 Unpack/Pack + Packing | 3일 | E5M2 지원 추가 |
| 2-9 | `multi_prec_mac.sv` 통합 (FP16 + E4M3 + E5M2) | 2일 | 최종 모듈 |
| 2-10 | 전 모드 regression 검증 | 3일 | `tb_multi_prec_mac.sv` |
| 2-11 | 합성 + 리소스 비교 분석 | 1일 | 합성 리포트 |

### 4.7 검증 항목

- [ ] FP16 모드: M1과 bit-exact 동일 결과 (역호환)
- [ ] FP8 E4M3 모드: 2-MAC throughput 확인, 각 MAC 독립 정확성
- [ ] FP8 E5M2 모드: E4M3와 동일 구조 검증
- [ ] Cross-contamination: guard bit 경계 최악 케이스에서 오염 없음
- [ ] 모드 전환: Arithmetic Contract의 flush 규칙 준수
- [ ] 각 정밀도별 ULP 오차 기준 충족 (FP16 ≤ 2 ULP, FP8 ≤ 1 ULP)

### 4.8 Exit Criteria

> **M2-A:** FP8 E4M3 2-MAC packing이 cross-contamination 없이 동작하고, guard bit 안전성이 Python 모델로 증명됨. **이 조건 미충족 시 FP4는 무기한 보류.**
>
> **M2-B:** E5M2 추가 후 전 모드 regression pass. 합성에서 FP8 모드의 DSP 절감률 대비 LUT 증가가 합리적(LUT 증가 < 50%)이면 성공.

---

## 5. M3: Village Engine (VE) 구현

**기간:** 5주 (축소형 VE 2주 + 128 MAC 확장 3주)
**산출물:** `ve_top.sv`, BRAM/URAM 매핑 검증
**선행:** M2-A 완료, WP2 URAM Weight File 준비

### 5.1 점진적 확장 전략

128 MAC VE를 한 번에 구현하지 않고, 축소형에서 합성/타이밍을 먼저 확인한다.

```
Step 1: 32 MAC VE shell → pilot synthesis → Fmax/congestion 확인
Step 2: 64 MAC VE       → timing 재확인
Step 3: 128 MAC VE      → 최종 타이밍 클로저
```

각 단계에서 확인할 항목:
- Fmax (200 MHz 달성 여부)
- LUT/FF/DSP/URAM 사용량
- Routing congestion level
- Adder Tree reduction 구조의 물리적 타당성

### 5.2 VE 구조 개요

```
VE (128 MAC, 128×128 Weight File):
  ┌─────────────────────────────────────────────────┐
  │                  VE Top                          │
  │                                                  │
  │  ┌──────────┐   ┌──────────────────────┐         │
  │  │ Weight   │   │  MAC Array (128개)    │         │
  │  │ File     ├──►│  ┌───┬───┬───┬───┐   │         │
  │  │ (URAM×2) │   │  │MAC│MAC│MAC│...│   │         │
  │  │ 64KB     │   │  └─┬─┘ └─┬─┘     │   │         │
  │  └──────────┘   │    │     │        │   │         │
  │                 │  ┌─▼─────▼────────▼─┐ │         │
  │  ┌──────────┐   │  │ Clustered        │ │         │
  │  │ Input    ├──►│  │ Adder Tree       │ │         │
  │  │ Vector   │   │  └────────┬─────────┘ │         │
  │  │ (Reg/    │   └───────────┼───────────┘         │
  │  │  BRAM)   │               │                     │
  │  │ 512B     │   ┌───────────▼───────────┐         │
  │  └──────────┘   │ Output Vector Latch   │         │
  │                 │ 128×32bit             │         │
  │                 └───────────┬───────────┘         │
  │                             │                     │
  │                        out[31:0]×128              │
  └─────────────────────────────────────────────────┘
```

### 5.3 Weight File (URAM 매핑)

```systemverilog
// URAM 강제 매핑 + 2개 카스케이드
(* ram_style = "ultra" *)
(* cascade_height = 2 *)
logic [63:0] wf_mem [0:8191];
// 64KB = 128 rows × 128 cols × 32bit (FP32 기준)
// 또는 128 rows × 128 cols × 16bit × 2 (FP16 double-packed)
```

**URAM OREG 파이프라인 필수 활성화:**
URAM의 optional output register(OREG)를 반드시 활성화하여 read latency를 안정화한다. OREG 미활성 시 URAM→DSP 간 배선 지연이 타이밍 병목이 된다.

```systemverilog
// OREG 활성화 → read latency +1 cycle → 파이프라인 모델에 반영
(* ram_style = "ultra" *)
(* cascade_height = 2 *)
// Vivado는 OREG를 자동 추론하지만, RTL에서 output register를 명시적으로 삽입
always_ff @(posedge clk) begin
    wf_rd_data_r <= wf_mem[wf_rd_addr];  // 1st read stage
    wf_rd_data   <= wf_rd_data_r;         // 2nd read stage (OREG)
end
```

**이중 버퍼링 (Double-Buffering):**
- Bank A/B 교대 사용 → DMA 로드와 MAC 연산 완전 중첩
- Bandwidth Budget(R0)에서 DMA 로드 시간 > MAC 연산 시간이면 필수
- KCU116에서는 리소스 절약을 위해 싱글 버퍼도 고려 (Budget 결과에 따라 결정)

### 5.4 Input Vector Buffer

```systemverilog
// 128 × FP16 = 256 Byte (FP16 모드)
// 128 × FP32 = 512 Byte (FP32 모드)
logic [15:0] input_vec [0:127];  // FP16 모드
```

- Broadcast 구조: 모든 MAC에 동일 입력 벡터 공급
- VE 내부는 레지스터로, VE 간은 BRAM 공유로 구현

### 5.5 Clustered Adder Tree

128개 MAC 출력을 flat하게 한 tree로 모으면 fan-in 집중과 routing congestion이 발생한다. 대신 **8~16 MAC 단위 클러스터**로 local reduction 후 상위 tree로 연결한다.

```
Clustered Reduction (8-MAC 클러스터 × 16):

  Cluster 0: MAC[0:7]   → Local Adder (3-stage) → partial_0
  Cluster 1: MAC[8:15]  → Local Adder (3-stage) → partial_1
  ...
  Cluster 15: MAC[120:127] → Local Adder (3-stage) → partial_15

  Upper Tree: 16 partials → 4-stage global reduction → final output

  총: 3 (local) + 4 (global) = 7 stage (기존과 동일 depth)
  차이: 물리 배치에서 클러스터 단위 Pblock 가능 → routing congestion 대폭 감소
```

DSP cascade 활용 가능 구간(cluster 내 인접 DSP)은 fabric adder 대신 cascade path를 사용하여 속도와 전력 모두 개선한다.

**SRL16/SRLC32E 활용:** 클러스터 간 파이프라인 깊이 차이로 발생하는 데이터 스큐를 SRL16/SRLC32E로 관리한다. 추가 FF/LUT 낭비 없이 지연을 조절할 수 있다.

### 5.6 VE 파이프라인 전체

| Stage | 동작 | Cycle |
|-------|------|-------|
| 1 | Weight File Read (URAM stage 1) | 1 |
| 2 | URAM OREG Read (stage 2) + Input Vector Read | 1 |
| 3 | Unpack | 1 |
| 4-6 | DSP48E2 Multiply (3-stage) | 3 |
| 7 | Alignment + Accumulate | 1 |
| 8-10 | Local Cluster Adder (3-stage) | 3 |
| 11-14 | Global Adder Tree (4-stage) | 4 |
| **총 레이턴시** | | **14 cycles** |
| **Throughput** | 1 output vector / cycle | (after pipeline fill) |

※ URAM OREG 추가로 기존 12 → 14 cycle. Throughput은 동일.

### 5.7 VE 제어 FSM

```
IDLE → LOAD_WEIGHT → LOAD_INPUT → COMPUTE → OUTPUT → IDLE
                 ↑                              │
                 └──── (다음 타일) ───────────────┘
```

| 상태 | 동작 |
|------|------|
| IDLE | 대기, DBC 명령 수신 |
| LOAD_WEIGHT | Weight File에 DMA로 가중치 로드 |
| LOAD_INPUT | Input Vector Buffer에 입력 로드 |
| COMPUTE | MAC Array + Adder Tree 파이프라인 가동 (128 cycle) |
| OUTPUT | 결과 벡터 NoC/메모리로 출력 |

### 5.8 구현 태스크

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 3-1 | 32 MAC VE shell + pilot synthesis | 3일 | `ve_top_32.sv`, Fmax/congestion 리포트 |
| 3-2 | 64 MAC VE 확장 + timing 확인 | 2일 | routing 분석 |
| 3-3 | Weight File URAM 모듈 (OREG 포함) | 3일 | `weight_file.sv` |
| 3-4 | Input Vector Buffer | 1일 | `vec_buffer.sv` |
| 3-5 | Clustered Adder Tree (8-MAC local + global) | 4일 | `clustered_adder_tree.sv` |
| 3-6 | MAC Array 128개 인스턴스 | 3일 | `mac_array_128.sv` |
| 3-7 | Output Vector Latch | 1일 | output 레지스터 |
| 3-8 | VE 제어 FSM | 2일 | `ve_ctrl.sv` |
| 3-9 | VE Top 통합 (128 MAC) | 2일 | `ve_top.sv` |
| 3-10 | cocotb/Verilator 검증 + 골든 모델 대비 | 3일 | 수치 정확도 리포트 |
| 3-11 | Vivado 합성 + URAM 매핑/congestion 확인 | 2일 | 합성 리포트 |

### 5.9 검증 항목

- [ ] 128×128 GEMV: 골든 모델 대비 상대 오차 < 0.1%
- [ ] Weight File 접근: URAM 매핑 확인 (합성 후), OREG latency 정합
- [ ] 파이프라인: 14 cycle 레이턴시, 이후 매 cycle 결과 출력
- [ ] Clustered Adder: cluster 내/외 경계에서 데이터 정합성
- [ ] 제어 FSM: 상태 전이 정확성, 에러 상태 복구
- [ ] 더블 버퍼링 (적용 시): Bank 전환 시 데이터 정합성
- [ ] 멀티정밀도: VE 레벨에서 FP16/FP8 모드 전환 동작

### 5.10 Exit Criteria

> **128 MAC VE가 합성에서 200 MHz setup slack 양수이고, routing congestion이 manageable 수준이면 M4 진입. 128 MAC에서 타이밍 실패 시 64 MAC VE로 fallback하여 M4 진행.**

---

## 6. M4: TE/CE 계층 확장

**기간:** 3주 (Month 4 ~ Month 5 초)
**산출물:** `te_top.sv`, `ce_top.sv`
**선행:** M3 완료

### 6.1 계층 구조

```
CM (Compute Module)
 └── CE (Compute Element) × 4      ← RTL/시뮬레이션 검증만
      └── TE (Tile Engine) × 4     ← KCU116 보드 실증 대상
           └── VE (Village Engine) × 4
                └── MAC × 128

CM = 64 VE = 8,192 MAC
CE = 16 VE = 2,048 MAC  → KU5P에 물리적 수용 불가 (DSP 1,824 < 2,048)
TE =  4 VE =   512 MAC  → KU5P 보드 실증 가능
VE =            128 MAC
```

### 6.2 TE (Tile Engine) 구조 — 보드 실증 대상

```
         ┌─────────────────────────────┐
         │          TE Top              │
         │                              │
         │  ┌────┐ ┌────┐ ┌────┐ ┌────┐│
         │  │VE_0│ │VE_1│ │VE_2│ │VE_3││
         │  └──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘│
         │     │      │      │      │   │
         │  ┌──▼──────▼──────▼──────▼─┐ │
         │  │ 1st Adder Tree          │ │
         │  │ (2-stage pipelined)     │ │
         │  │ 4→1 FP32 reduction      │ │
         │  └────────────┬────────────┘ │
         │               │              │
         └───────────────┼──────────────┘
                         │
                   te_out[31:0]×128
```

- 4개 VE의 출력 벡터(각 128×FP32)를 element-wise 합산
- 2-stage pipelined adder: 4→2→1 reduction
- TE 총 레이턴시: VE(14) + Adder(2) = **16 cycles**

### 6.3 CE (Compute Element) 구조 — RTL/시뮬레이션 검증만

```
         ┌──────────────────────────────┐
         │          CE Top               │
         │                               │
         │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ │
         │  │TE_0│ │TE_1│ │TE_2│ │TE_3│ │
         │  └──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘ │
         │     │      │      │      │    │
         │  ┌──▼──────▼──────▼──────▼──┐ │
         │  │ 2nd Adder Tree           │ │
         │  │ (2-stage pipelined)      │ │
         │  └─────────────┬────────────┘ │
         │                │              │
         └────────────────┼──────────────┘
                          │
                    ce_out[31:0]×128
```

- CE 총 레이턴시: VE(14) + TE Adder(2) + CE Adder(2) = **18 cycles**
- **CE on-board 실증은 VCU118 이관 시점으로 이월**

### 6.4 Adder Tree 모듈 (재사용)

TE/CE의 2-stage adder는 동일 모듈을 파라미터화하여 재사용:

```systemverilog
module reduction_adder #(
    parameter int NUM_INPUTS = 4,      // 4 VE or 4 TE
    parameter int DATA_WIDTH = 32,     // FP32
    parameter int VEC_LENGTH = 128     // 출력 벡터 길이
)(
    input  logic clk, rst_n,
    input  logic [DATA_WIDTH-1:0] in_vec [NUM_INPUTS][VEC_LENGTH],
    input  logic                  in_valid [NUM_INPUTS],
    output logic [DATA_WIDTH-1:0] out_vec [VEC_LENGTH],
    output logic                  out_valid
);
```

### 6.5 데이터 흐름 (GEMV 연산 예시)

대형 행렬(M×N)을 VE 크기(128×128)로 타일링:

```
예: 512×512 GEMV → TE(4 VE) 활용

  VE_0: W[0:127, 0:127]   × x[0:127]   → partial_0
  VE_1: W[0:127, 128:255] × x[128:255] → partial_1
  VE_2: W[0:127, 256:383] × x[256:383] → partial_2
  VE_3: W[0:127, 384:511] × x[384:511] → partial_3

  TE Adder: partial_0 + partial_1 + partial_2 + partial_3 = result[0:127]

  다음 타일: W[128:255, :] → result[128:255]
  ...
```

### 6.6 구현 태스크

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 4-1 | 2-stage Reduction Adder 모듈 | 2일 | `reduction_adder.sv` |
| 4-2 | TE Top (4 VE + Adder) | 3일 | `te_top.sv`, `te_adder.sv` |
| 4-3 | CE Top (4 TE + Adder) — RTL only | 2일 | `ce_top.sv`, `ce_adder.sv` |
| 4-4 | TE/CE 제어 로직 (VE 동기화) | 2일 | 배리어, 입력 broadcast |
| 4-5 | TE cocotb/Verilator 검증 (512×512 GEMV) | 3일 | `test_te_top.py` |
| 4-6 | CE 시뮬레이션 검증 (2048×2048 부분) | 2일 | Verilator cycle-accurate 검증 |
| 4-7 | TE 합성 + 리소스/타이밍 분석 | 2일 | 합성 리포트 |

### 6.7 검증 항목

- [ ] TE 레벨: 512×512 GEMV 정확성 (4 VE 부분합 합산)
- [ ] CE 레벨: 2048×2048 GEMV 시뮬레이션 정확성 (보드 실증 제외)
- [ ] 파이프라인 레이턴시: TE=16, CE=18 cycle 확인
- [ ] VE 간 데이터 동기화: 모든 VE의 출력이 동시에 Adder에 도달
- [ ] Input Vector Broadcast: 동일 입력이 모든 하위 VE에 정확히 전달

### 6.8 Exit Criteria

> **TE:** KCU116 합성에서 200 MHz 타이밍 클로저 달성 시 M5 진입.
> **CE:** RTL 시뮬레이션에서 기능 정확성 확인. 보드 실증은 VCU118 이관 시점에서 별도 계획.

---

## 7. M5: KCU116 FPGA 통합 검증

**기간:** 4주 (WP2/WP4 병합 후 수행)
**산출물:** 비트스트림, ILA 검증 결과
**선행:** M4 완료, WP2 DDR4 MIG, WP4 XDMA PCIe

### 7.1 통합 대상

```
KCU116 통합 블록다이어그램:

  Host PC ←PCIe→ [XDMA IP] ←AXI→ [DBC] ←Ctrl→ [TE/VE Array]
                                    │              ↕
                              [DDR4 MIG] ←→ [Weight/Input DMA]
```

- XDMA IP: 호스트 통신 (WP4 산출물)
- DBC: 명령 디코더 (WP4 산출물)
- DDR4 MIG: 외부 메모리 (WP2 산출물)
- TE/VE Array: **WP1 산출물**

### 7.2 KCU116 리소스 배분 (WP1 해당)

| 모듈 | DSP48E2 | LUT | BRAM36K | URAM |
|------|---------|-----|---------|------|
| VE × 4 (1 TE) | 512~1024 | ~48K | 4 | 8~16 |
| TE Adder | 0 | ~2K | 0 | 0 |
| VE 제어 FSM × 4 | 0 | ~2K | 0 | 0 |
| **WP1 소계** | **512~1024** | **~52K** | **4** | **8~16** |
| **XCKU5P 총량** | 1,824 | 356K | 624 | 80 |
| **WP1 점유율** | **28~56%** | **~15%** | **<1%** | **10~20%** |

### 7.3 타이밍 클로저 전략

**목표: pilot synthesis 기준 200 MHz feasibility 확인 후 full design closure**

| 전략 | 적용 대상 | 효과 |
|------|----------|------|
| 파이프라인 레지스터 삽입 | MAC ↔ Adder Tree 경계 | 크리티컬 패스 분할 |
| DSP48E2 내부 레지스터 활성 | AREG, BREG, MREG, PREG | DSP 내 타이밍 개선 |
| URAM OREG 활성화 | Weight File 출력 | URAM→DSP 배선 지연 제거 |
| Pblock 배치 제약 | VE/Cluster 단위 물리 인접 배치 | 배선 지연 최소화 |
| SRL16/SRLC32E 활용 | 클러스터 간 스큐 관리 | 파이프라인 밸런싱 (FF/LUT 절약) |
| DSP cascade path | Cluster 내 인접 DSP 가산 | fabric adder 대비 속도/전력 개선 |
| `DONT_TOUCH` 속성 | 크리티컬 넷 | 합성 최적화 방지 |

### 7.4 ILA 디버그 포인트

| ILA # | 관측 대상 | 트리거 조건 |
|-------|----------|-----------|
| ILA_0 | MAC Array 입출력 | compute_start rising |
| ILA_1 | Adder Tree 중간값 (cluster 경계) | adder_valid rising |
| ILA_2 | VE FSM 상태 | state 변화 |
| ILA_3 | Weight File R/W | wf_wr_en or wf_rd_en |

### 7.5 구현 태스크

| # | 태스크 | 소요 | 산출물 |
|---|--------|------|--------|
| 5-1 | XDC 타이밍 제약 작성 | 2일 | `timing.xdc` |
| 5-2 | Pblock 플로어플랜 (R0 pilot 기반 정교화) | 2일 | `floorplan.xdc` |
| 5-3 | WP1 모듈 + WP2/WP4 통합 Top | 3일 | `s80_top.sv` (공동) |
| 5-4 | Post-Synthesis Simulation | 3일 | 합성 후 기능 검증 |
| 5-5 | Place & Route + 타이밍 분석 | 3일 | 타이밍 리포트 |
| 5-6 | ILA/VIO 삽입 + 비트스트림 생성 | 2일 | `.bit` 파일 |
| 5-7 | FPGA 보드 실증 | 4일 | ILA 캡처, 하드웨어 검증 |
| 5-8 | 성능 측정 (cycle count, throughput) | 2일 | 벤치마크 리포트 |
| 5-9 | 버그 수정 + 최적화 반복 | 3일 | 최종 비트스트림 |

### 7.6 성공 기준

> **KCU116 보드에서 TE(4 VE) FP16 GEMV가 200 MHz 타이밍 클로저로 동작하며, ILA로 실시간 파형을 확인하고 호스트 PC에서 PCIe를 통해 결과를 수신**

---

## 8. RTL 파일 구조 및 코딩 규칙

### 8.1 디렉토리 구조

```
rtl/
├── common/
│   ├── s80_pkg.sv                # 전역 패키지 (타입, 상수, 유틸)
│   ├── fp16_unpack.sv            # FP16 언패킹
│   ├── fp16_pack.sv              # FP16 패킹
│   ├── fp8_e4m3_unpack.sv        # FP8 E4M3 언패킹
│   ├── fp8_e4m3_pack.sv          # FP8 E4M3 패킹
│   ├── fp8_e5m2_unpack.sv        # FP8 E5M2 언패킹
│   ├── fp8_e5m2_pack.sv          # FP8 E5M2 패킹
│   ├── fp16_mac.sv               # FP16 단일 MAC (M1)
│   ├── multi_prec_mac.sv         # 멀티정밀도 MAC (M2)
│   ├── dsp48_mul_wrapper.sv      # DSP48E2 래퍼
│   ├── fp32_adder.sv             # FP32 덧셈기
│   └── clustered_adder_tree.sv   # Clustered Pipelined Adder Tree
├── ve/
│   ├── ve_top.sv                 # VE 최상위 (M3)
│   ├── weight_file.sv            # URAM Weight File (OREG 포함)
│   ├── mac_array_128.sv          # 128-MAC 어레이
│   ├── vec_buffer.sv             # Input Vector Buffer
│   └── ve_ctrl.sv                # VE 제어 FSM
├── te/
│   ├── te_top.sv                 # TE 최상위 (M4)
│   ├── te_adder.sv               # TE Reduction Adder
│   └── reduction_adder.sv        # 파라미터화 Reduction Adder
└── ce/
    ├── ce_top.sv                 # CE 최상위 (M4, RTL/sim only)
    └── ce_adder.sv               # CE Reduction Adder
```

### 8.2 코딩 규칙

| 항목 | 규칙 |
|------|------|
| 언어 | SystemVerilog (IEEE 1800-2017) |
| 네이밍 | 모듈: `snake_case`, 신호: `snake_case`, 파라미터: `UPPER_SNAKE` |
| 클럭/리셋 | `clk` (posedge), `rst_n` (active-low async reset) |
| 파이프라인 | 각 stage 경계에 `_r` 접미사 레지스터 |
| ASIC 호환 | Xilinx 프리미티브는 `ifdef FPGA` 내부에 배치 |
| 매직 넘버 금지 | 모든 상수는 `s80_pkg.sv`에 정의 |
| Assertion | 각 모듈에 SVA assertion 최소 3개 |

### 8.3 s80_pkg.sv 핵심 정의

```systemverilog
package s80_pkg;
    // 정밀도 모드
    typedef enum logic [1:0] {
        PREC_FP16    = 2'b00,  // 1 MAC/DSP
        PREC_FP8_E4  = 2'b01,  // 2 MAC/DSP (E4M3)
        PREC_FP8_E5  = 2'b10,  // 2 MAC/DSP (E5M2)
        PREC_FP4     = 2'b11   // 연구 예비
    } precision_mode_t;

    // VE 파라미터
    parameter int VE_MAC_COUNT   = 128;
    parameter int VE_WF_ROWS     = 128;
    parameter int VE_WF_COLS     = 128;
    parameter int VE_PIPELINE    = 14;   // URAM OREG 반영
    parameter int VE_CLUSTER_SZ  = 8;    // Adder cluster 크기

    // 계층 파라미터
    parameter int TE_VE_COUNT    = 4;
    parameter int CE_TE_COUNT    = 4;
    parameter int CM_CE_COUNT    = 4;

    // FP 상수
    parameter int FP16_EXP_WIDTH = 5;
    parameter int FP16_MAN_WIDTH = 10;
    parameter int FP16_BIAS      = 15;
    parameter int FP8_E4M3_EXP   = 4;
    parameter int FP8_E4M3_MAN   = 3;
    parameter int FP8_E5M2_EXP   = 5;
    parameter int FP8_E5M2_MAN   = 2;
    parameter int FP32_EXP_WIDTH = 8;
    parameter int FP32_MAN_WIDTH = 23;
    parameter int FP32_BIAS      = 127;
endpackage
```

---

## 9. 검증 전략

### 9.1 검증 스택 역할 분리

"모든 것을 UVM"이 아니라 도구별 역할을 분리하여 속도와 정확성을 모두 확보한다.

| 도구 | 역할 | 적용 레벨 |
|------|------|----------|
| **Python/NumPy** | Arithmetic Contract 기반 bit-accurate 골든 모델 생성 | 전 레벨 정답 생성 |
| **cocotb** | 랜덤/시나리오 구동, 빠른 Python-RTL 연동 | Level 0-1 (MAC, VE) |
| **Verilator** | 대규모 cycle-accurate 시뮬레이션, lint 겸용 | Level 2 (TE/CE) |
| **SystemVerilog TB / UVM** | 프로토콜 검증, constrained random, coverage | Level 1-2 장기 회귀 |
| **FPGA ILA** | 시스템 통합 실시간 디버그 | Level 3 (보드 실증) |

### 9.2 검증 레벨

```
Level 0: 단위 검증 (MAC 1개)
  → cocotb + Python 골든 모델
  → Arithmetic Contract 준수 (특수값, rounding, overflow)

Level 1: 모듈 검증 (VE)
  → cocotb + Python 골든 모델
  → 128×128 GEMV, 연속 타일
  → URAM 읽기/쓰기

Level 2: 계층 검증 (TE/CE)
  → Verilator cycle-accurate
  → 대형 행렬 타일링
  → VE 간 동기화

Level 3: 시스템 검증 (FPGA)
  → ILA 실시간 디버그
  → PCIe end-to-end
```

### 9.3 골든 모델

| 모델 | 언어 | 용도 |
|------|------|------|
| `fp_golden_model.py` | Python/NumPy | Arithmetic Contract 기반 bit-accurate 모델 (R0 산출물) |
| `ve_golden.py` | Python/NumPy | VE GEMV 정확성 |
| `gemv_golden.c` | C (Verilator 연동) | 대규모 계층 시뮬레이션 가속 |

### 9.4 수치 정확도 기준

| 정밀도 | 최대 상대 오차 | 최대 ULP 오차 |
|--------|--------------|-------------|
| FP32 Accumulator | < 1e-6 | ≤ 1 ULP |
| FP16 GEMV | < 0.1% | ≤ 2 ULP |
| FP8 E4M3 | < 5% | ≤ 1 ULP |
| FP8 E5M2 | < 5% | ≤ 1 ULP |

### 9.5 CI/CD 연동

| 트리거 | 테스트 | 도구 | 예상 시간 |
|--------|--------|------|----------|
| 매 커밋 | MAC/VE 기능 시뮬레이션 | cocotb | ~15분 |
| 매 커밋 | Verilator lint | Verilator --lint-only | ~5분 |
| Daily | 정밀도 정확도 (전 정밀도, 전 레벨) | cocotb + Verilator | ~2시간 |
| Weekly | Post-Synthesis Simulation | Vivado | ~6시간 |

---

## 10. 리소스 예산 및 리스크

### 10.1 XCKU5P 리소스 사용 예측 (WP1 전체)

| 구성 | VE 수 | DSP48E2 | LUT | URAM |
|------|-------|---------|-----|------|
| 최소 (1 TE) | 4 | 512 (28%) | ~52K (15%) | 8 (10%) |
| 권장 (2 TE) | 8 | 1,024 (56%) | ~104K (29%) | 16 (20%) |
| 최대 (VCU118) | 53 | 6,784 (99%) | ~690K (58%) | 106 (39%) |

### 10.2 리스크 및 대응

| # | 리스크 | 영향 | 확률 | 대응 방안 |
|---|--------|------|------|----------|
| R1 | DSP 부족으로 VE 수 제한 | 성능 하향 | 높음 | VCU118 스케일업, FP8로 MAC 밀도 증가 |
| R2 | FP16 수치 오차 누적 | 모델 정확도 저하 | 낮음 | FP32 누산 유지, Arithmetic Contract 기반 검증 |
| R3 | 200 MHz 타이밍 미달 | 클럭 하향 | 중간 | R0 pilot synthesis로 조기 발견, 파이프라인 추가 |
| R4 | URAM 매핑 실패 / URAM↔DSP 거리 | Fmax 저하 | 낮음 | OREG 활성화, Pblock co-location 강제 |
| R5 | FP8 guard bit cross-contamination | 연산 오류 | 중간 | R0/M2-A에서 Python bit-accurate 증명 선행 |
| R6 | 128-way Adder routing congestion | 타이밍 실패 | 중간 | Clustered reduction, 32/64 MAC fallback |
| R7 | FP4 packing 난이도 | 일정 지연 | 높음 | 연구 기능 격하, M2-A/B 성공 후에만 진입 |

---

## 11. 일정 요약

```
Week 1-2:   ████████ R0: 산술 계약 + Bandwidth Budget + Pilot Synthesis
Week 3-4:   ████████ M1: FP16 MAC 단일 유닛
Week 5-6:   ████████ M2-A: FP8 E4M3 packing 증명
Week 7-8:   ████████ M2-B: FP8 E5M2 + 통합
Week 9-10:  ████████ M3-전반: 축소형 VE (32/64 MAC) pilot synthesis
Week 11-13: ████████████ M3-후반: 128 MAC VE 확장 + 검증
Week 14-16: ████████████ M4: TE 보드 실증 대상 + CE RTL/sim
  ... (WP2/WP4 병합 대기) ...
Week 25-28: ████████████████ M5: KCU116 통합 검증
```

| 마일스톤 | 기간 | 완료 기준 | 의존성 |
|---------|------|----------|--------|
| **R0** | 2주 | 산술 계약 확정, pilot synthesis pass | 없음 |
| **M1** | 2주 | FP16 MAC 기능 검증 + 200 MHz feasibility | R0 |
| **M2-A** | 2주 | FP8 E4M3 2-MAC packing + guard bit 증명 | M1 |
| **M2-B** | 2주 | E5M2 추가 + 전 모드 regression pass | M2-A |
| **M3** | 5주 | VE 128×128 GEMV + URAM 매핑 + clustered adder | M2-A, WP2(URAM) |
| **M4** | 3주 | TE 합성 pass + CE RTL sim pass | M3 |
| **M5** | 4주 | KCU116 비트스트림 + ILA 검증 | M4, WP2(DDR4), WP4(PCIe) |

**총 순수 WP1 소요: 약 18주 (R0~M4) + 4주 (M5 통합)**

---

*본 문서는 S80 NPU 완성 계획서의 WP1 섹션을 기반으로 상세 구현 계획을 기술합니다.*
*Codex/Gemini 리뷰의 채택된 개선사항이 반영되어 있습니다.*
*다른 WP(WP2~WP7)와의 인터페이스 및 일정 조율은 통합 로드맵을 참조하십시오.*
