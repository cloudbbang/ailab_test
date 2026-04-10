# S80 NPU Arithmetic Contract v1.0

**적용 범위:** WP1 M1 (FP16 MAC) 이후 전 RTL/골든 모델/테스트벤치
**확정일:** 2026-03-25

---

## 1. 지원 포맷

### 1.1 FP16 (IEEE 754 Half-Precision)

```
Bit [15]    : Sign (1-bit)
Bit [14:10] : Exponent (5-bit, bias = 15)
Bit [9:0]   : Mantissa (10-bit, implicit leading 1 → effective 11-bit)

Value = (-1)^S × 2^(E-15) × 1.M   (when 0 < E < 31)
```

| 항목 | 값 |
|------|-----|
| Exponent range | 1 ~ 30 (normal) |
| Max normal | 65504 (0x7BFF) |
| Min normal | 2^-14 ≈ 6.1035e-5 (0x0400) |
| Max exponent (reserved) | 31 (Inf/NaN) |

### 1.2 FP32 (IEEE 754 Single-Precision)

```
Bit [31]    : Sign (1-bit)
Bit [30:23] : Exponent (8-bit, bias = 127)
Bit [22:0]  : Mantissa (23-bit, implicit leading 1 → effective 24-bit)
```

FP32는 MAC 내부 누산 및 결과 출력 포맷으로 사용.

---

## 2. Rounding Mode

**RNE (Round-to-Nearest-Even)** 단일 모드만 지원.

Guard(G), Round(R), Sticky(S) 비트 기반:
- G=0 → truncate (round down)
- G=1, R=1 or S=1 → round up
- G=1, R=0, S=0 → round to even (LSB=1이면 round up, LSB=0이면 truncate)

---

## 3. Overflow 정책

**Saturate-to-max.** Inf를 생성하지 않는다.

| 조건 | 동작 |
|------|------|
| FP16 결과 > 65504 | 출력 = ±65504 (0x7BFF / 0xFBFF) |
| FP32 결과 > 3.4028235e+38 | 출력 = ±FP32_MAX (0x7F7FFFFF / 0xFF7FFFFF) |
| 누산 중 overflow | accumulator를 FP32_MAX로 saturate 후 계속 누산 |

---

## 4. Underflow 정책

**Flush-to-Zero (FTZ).** Subnormal을 지원하지 않는다.

| 조건 | 동작 |
|------|------|
| FP16 입력이 subnormal (exp=0, mant≠0) | **±0으로 강제 변환** 후 처리 |
| 연산 결과가 subnormal 범위 | ±0으로 flush |

---

## 5. Special Value 처리

### 5.1 분류 (FP16 입력 기준)

| 분류 | Exponent | Mantissa | 동작 |
|------|----------|----------|------|
| Positive Zero | 0 | 0 | 정상 (값 = +0) |
| Negative Zero | 0 | 0 (sign=1) | +0과 동일 취급 |
| Subnormal | 0 | ≠ 0 | FTZ → ±0으로 변환 |
| Normal | 1~30 | any | 정상 연산 |
| Infinity | 31 | 0 | 입력으로 감지만 함 (saturate 모드에서 Inf 미생성) |
| Quiet NaN | 31 | ≠ 0, bit[9]=1 | NaN 전파 |
| Signaling NaN | 31 | ≠ 0, bit[9]=0 | Quiet NaN으로 변환 후 전파 |

### 5.2 곱셈 특수 케이스

| 입력 A | 입력 B | 결과 |
|--------|--------|------|
| 0 | any | 0 (곱셈 skip, 누산기 유지) |
| any | 0 | 0 (곱셈 skip, 누산기 유지) |
| NaN | any | NaN (누산기 NaN 플래그 set) |
| any | NaN | NaN (누산기 NaN 플래그 set) |
| normal | normal | 정상 곱셈 → FP32 누산 |

### 5.3 Signed Zero 규칙

- -0 = +0 동일 취급
- (-0) × (-0) = +0
- (+0) + (-0) = +0
- 누산기가 정확히 0이면 sign = 0 (positive)

---

## 6. 누산 경계

| 구간 | 정밀도 |
|------|--------|
| FP16 × FP16 곱셈 (mantissa) | 22-bit exact product |
| 곱 → 누산기 변환 | FP32 정밀도로 확장 |
| 누산기 내부 | FP32 (sign + 8-bit exp + 23-bit mantissa) |
| Adder Tree (M3 이후) | FP32 유지 |
| 최종 출력 | FP32 (필요 시 FP16으로 pack) |

---

## 7. 모드 전환 규칙 (M2 이후 적용)

- precision_mode 변경 시 파이프라인을 **완전 flush** 후 전환
- flush 완료 전까지 새 입력 수신 금지
- 누산기는 자동 clear

---

## 8. 수치 정확도 기준

| 정밀도 | 최대 상대 오차 | 최대 ULP 오차 |
|--------|--------------|-------------|
| FP32 Accumulator (단일 곱) | < 1e-6 | ≤ 1 ULP |
| FP16 GEMV (N=256) | < 0.1% | ≤ 2 ULP |

---

## 9. 비트 패턴 참조

| 이름 | FP16 Hex | 설명 |
|------|----------|------|
| +0 | 0x0000 | Positive zero |
| -0 | 0x8000 | Negative zero (= +0 취급) |
| +Max | 0x7BFF | 65504 |
| -Max | 0xFBFF | -65504 |
| +Min normal | 0x0400 | 2^-14 |
| QNaN (canonical) | 0x7E00 | Quiet NaN |
| +Inf | 0x7C00 | (입력 감지용, 생성 안 함) |

---

*본 문서는 S80 NPU RTL, Python 골든 모델, 테스트벤치의 공통 기준이다.*
*모든 연산 구현체는 이 계약을 준수해야 하며, 불일치 발견 시 이 문서를 기준으로 수정한다.*
