# S80 NPU Vivado FPGA 구현 완성 계획서

**작성일:** 2026-03-23
**프로젝트:** SEMICS S80 NPU - Vivado 기반 FPGA 프로토타이핑 및 ASIC 테이프아웃
**현재 상태:** KCU116에서 256x256 INT16 GEMV 동작 확인
**최종 목표:** FP16 8.39 PFLOPS, MFU 90%+, ASIC 테이프아웃

---

## 목차

1. [프로젝트 현황 및 목표](#1-프로젝트-현황-및-목표)
2. [WP1: MAC/PE RTL 설계](#2-wp1-macpe-rtl-설계)
3. [WP2: 메모리 서브시스템](#3-wp2-메모리-서브시스템)
4. [WP3: SFM 활성화/정규화 엔진](#4-wp3-sfm-활성화정규화-엔진)
5. [WP4: NoC 인터커넥트 & 제어](#5-wp4-noc-인터커넥트--제어)
6. [WP5: SEDA 컴파일러 & 소프트웨어](#6-wp5-seda-컴파일러--소프트웨어)
7. [WP6: 검증 & ASIC 전환](#7-wp6-검증--asic-전환)
8. [WP7: LLM 워크로드 매핑](#8-wp7-llm-워크로드-매핑)
9. [통합 로드맵 & 마일스톤](#9-통합-로드맵--마일스톤)
10. [리소스 계획](#10-리소스-계획)

---

## 1. 프로젝트 현황 및 목표

### 1.1 현재 상태 (As-Is)

| 항목 | 현재 |
|------|------|
| FPGA 보드 | KCU116 (Kintex UltraScale+ XCKU5P) |
| 구현 규모 | 1 MVE, 4 sub, 256 MAC |
| 데이터 타입 | INT16 |
| 클럭 | 100 MHz |
| 검증된 연산 | 256x256 GEMV |
| 미구현 | FP16/FP32, Activation, Softmax, LayerNorm, PCIe, 컴파일러 |

### 1.2 목표 (To-Be)

| 항목 | FPGA 프로토타입 | ASIC 최종 |
|------|---------------|----------|
| 규모 | 8 MVE, 16+ sub | 8 MVE, 64 sub/MVE |
| 데이터 타입 | FP16/FP8 | FP32/FP16/FP8/FP4 |
| 클럭 | 200-250 MHz | 2 GHz |
| 성능 | MFU 60%+ | MFU 90%+, HFU 95%+ |
| 인터페이스 | PCIe Gen3 x16 | PCIe Gen5 + HBM |
| 소프트웨어 | PyTorch 연동, GPT-2 데모 | SEDA 컴파일러, Llama-3 70B |

### 1.3 FPGA 보드 스케일업 경로

```
Phase 1: KCU116 (XCKU5P)  → 4 Sub, 256 MAC, DDR4 1GB
Phase 2: VCU118 (VU9P)    → 16 Sub, 1024+ MAC, DDR4
Phase 3: Alveo U280/U55C  → HBM2 8GB, 대역폭 검증
Phase 4: VCK5000 (Versal) → AI Engine 하이브리드
```

| 보드 | DSP | LUT | BRAM | URAM | 최대 VE 수 |
|------|-----|-----|------|------|-----------|
| KCU116 (XCKU5P) | 1,824 | 356K | 28.6Mb | 36Mb | **14** (DSP 병목) |
| VCU118 (VU9P) | 6,840 | 1,182K | 75.9Mb | 270Mb | **53** |
| Alveo U280 | 9,024 | 1,080K | 36Mb | 240Mb | **70** + HBM |

---

## 2. WP1: MAC/PE RTL 설계

### 2.1 FP16 MAC 구현 전략

**DSP48E2 1개로 FP16 mantissa 곱셈 가능** (11x11 < 27x18). 완전한 FP16 MAC에는 추가 LUT 로직 필요.

| 구성 요소 | 구현 방식 | 리소스 |
|-----------|----------|--------|
| Mantissa Multiply (11x11) | DSP48E2 | 1 DSP |
| Exponent Add + Bias | LUT | ~30 LUT |
| Alignment Shifter | LUT/MUX | ~80 LUT |
| FP32 Accumulator | DSP48E2 또는 LUT | 0-1 DSP + ~100 LUT |
| Normalize + Round | LUT | ~90 LUT |
| **합계/MAC** | | **1-2 DSP + 300 LUT** |

**권장: 커스텀 RTL** (Xilinx FP IP 대신). 멀티 정밀도 지원과 리소스 효율을 위해 필수.

### 2.2 멀티 정밀도 DSP-Packing

| 정밀도 | DSP48E2 1개당 MAC 수 | 패킹 방법 |
|--------|---------------------|----------|
| FP16 | 1 MAC | 11x11 mantissa 직접 |
| FP8 | 2 MAC | 입력 분할 |
| FP4 | 4-6 MAC | MR-Overpacking |

**핵심 원칙:** 곱셈은 저정밀도, 누산은 항상 FP32로 유지하여 수치 안정성 확보.

### 2.3 Village Engine (VE) RTL 구조

```
VE (128 MAC, 128x128 WF):
  Weight File: URAM 2개 (카스케이드) = 64KB
  Input Vector: 레지스터 또는 BRAM 1개 = 512B
  MAC Array: 128 DSP48E2 + LUT
  Adder Tree: 7-stage pipeline (log2(128))
  Output Vector: 128x32bit 래치

  파이프라인 깊이: 12 stage → 100MHz에서 1 output/cycle
```

### 2.4 계층 확장 (VE→TE→CE→CM)

각 레벨에 2-stage pipelined adder tree 삽입:

| 계층 | 구성 | Adder 추가 | 총 레이턴시 |
|------|------|-----------|-----------|
| VE | 기본 단위 | - | 12 cycles |
| TE (4 VE) | 1st Adder | +2 | 14 cycles |
| CE (4 TE) | 2nd Adder | +2 | 16 cycles |
| CM (4 CE) | 3rd Adder | +2 | 18 cycles |

### 2.5 마일스톤

| 단계 | 기간 | 산출물 |
|------|------|--------|
| M1: FP16 MAC | 2주 | `fp16_mac.sv`, 검증 TB |
| M2: 멀티정밀도 MAC | 3주 | `multi_prec_mac.sv` |
| M3: VE 구현 | 4주 | `ve_top.sv`, BRAM/URAM 매핑 |
| M4: TE/CE 확장 | 3주 | `te_top.sv`, `ce_top.sv` |
| M5: KCU116 검증 | 4주 | 비트스트림, ILA 검증 |

---

## 3. WP2: 메모리 서브시스템

### 3.1 BRAM/URAM 활용 전략

**Weight File (128x128x32bit = 64KB/VE):**

| 구현 방식 | VE당 리소스 | XCKU5P 최대 VE |
|-----------|-----------|---------------|
| BRAM36 only | 16 BRAM/VE | ~13 |
| **URAM (권장)** | **2 URAM/VE** | **~24** |
| Double-buffered URAM | 4 URAM/VE | ~12 |

```systemverilog
(* ram_style = "ultra" *)    // URAM 강제 매핑
(* cascade_height = 2 *)     // 2개 카스케이드
logic [63:0] wf_mem [0:8191];
```

### 3.2 DDR4/HBM 인터페이스

**KCU116 DDR4:** MIG IP, AXI4 256-bit, 19.2 GB/s 이론, ~15 GB/s 실효

**Alveo U280 HBM2:** 32 Pseudo Channel, 각 256-bit AXI, 총 460 GB/s

```
HBM 메모리 맵:
  PC 0-7:   Weight Storage (2GB)
  PC 8-11:  Input Activation (1GB)
  PC 12-15: Output Activation (1GB)
  PC 16-31: Intermediate / Host Comm
```

### 3.3 DMA & Double-Buffering

```
시간 ->  T0          T1          T2
Bank A: [Load W[0]] [Compute  ] [Load W[2]]
Bank B: [idle     ] [Load W[1]] [Compute  ]
→ DMA 로딩과 MAC 연산 완전 중첩 (latency hiding)
```

| 항목 | DDR4 (KCU116) | HBM2 (U280) |
|------|-------------|-------------|
| WF 1개 로드 (64KB) | ~4.3 us | ~0.15 us |
| MAC 연산 (128x128) | 0.512 us | 0.512 us |
| DMA > 연산? | **예 (DDR4 병목)** | **아니오 (HBM 충분)** |

### 3.4 메모리 계층: SPM (스크래치패드) 방식 채택

캐시 대신 DMA 기반 스크래치패드 메모리. NPU의 규칙적 접근 패턴에 최적:
- **결정론적** 접근 (항상 1-2 cycle)
- **100% 데이터 저장** (태그 오버헤드 없음)
- Groq/Cerebras와 동일한 접근 방식

### 3.5 타일링 컨트롤러

대형 행렬(12,288x49,152) → VE 크기(128x128)로 자동 분할하는 하드웨어 FSM:
- 6중 루프로 타일 주소 생성
- 행 병렬 전략: 8 VE가 각각 다른 행 블록 담당, 입력 벡터 broadcast

---

## 4. WP3: SFM 활성화/정규화 엔진

### 4.1 활성화 함수 구현 방식

| 함수 | 방식 | 리소스 | 레이턴시 |
|------|------|--------|---------|
| ReLU | MSB 비트 조작 | 0 LUT | 0 cycle |
| Sigmoid | **PWL 16구간** | 120 LUT, 1 DSP | 2 cycle |
| Tanh | Sigmoid 재사용 | +20 LUT | 2 cycle |
| GELU | **ISPA 16구간** | 337 LUT, 185 FF | 4 cycle |
| Swish | Sigmoid + 곱셈 | +1 DSP | 3 cycle |
| SiLU | Swish와 동일 | 동일 | 동일 |

**PWL(Piecewise Linear)이 S80에 최적:** DSP 1개로 `y = k*x + b`, 16구간에서 MSE ~2e-6.

### 4.2 Softmax 3-Pass 파이프라인

```
Pass 1: z_max = max(z_1..z_n)     [비교기 트리, N cycles]
Pass 2: sum = Σ exp(z_i - z_max)  [exp LUT + 누적, N cycles]
Pass 3: p_i = exp(z_i-z_max)/sum  [exp + 곱셈, N cycles]
총: 3N + 6 cycles
```

- **exp():** 2^y 분리 방식 (LUT 256엔트리, 512B)
- **나눗셈:** Newton-Raphson 역수 (2회 반복, DSP 3개)
- **수치 안정성:** Log-Sum-Exp 트릭으로 오버플로우 방지

### 4.3 LayerNorm 2-Pass 구조

```
Pass 1: sum = Σx_i, sum_sq = Σx_i² (내부 INT32/48 정밀도)
중간:   μ = sum/N, σ² = sum_sq/N - μ², rsqrt = 1/√(σ²+ε)
Pass 2: y_i = γ * (x_i - μ) * rsqrt + β
```

- **역제곱근:** Newton-Raphson (`y = 0.5*y*(3 - x*y²)`, 2회 반복)

### 4.4 2D Conv: On-the-fly Im2col

기존 GEMV 엔진을 **변경 없이 재사용.** 주소 생성기(~500 LUT)만 추가:

```
[Input SRAM] --읽기--> [Im2col Addr Gen] --데이터--> [기존 GEMV Engine]
  원본 데이터             주소만 생성                   변경 없이 재사용
```

### 4.5 SFM 전체 리소스

| 모듈 | LUT | DSP | BRAM |
|------|-----|-----|------|
| Activation (8종) | 1,500 | 5 | 1 |
| Softmax | 1,200 | 6 | 1 |
| LayerNorm | 800 | 4 | 2 |
| Pooling | 200 | 0 | 2 |
| Im2col Addr Gen | 500 | 1 | 0 |
| Control + Regs | 300 | 0 | 0 |
| **합계** | **4,630 (1.8%)** | **16 (25%)** | **6 (2.8%)** |

### 4.6 구현 우선순위

```
Week 1-2:  ReLU + Adder Tree (즉시 CNN/MLP 지원)
Week 3-5:  Sigmoid/Tanh/Swish (LSTM/RNN 지원)
Week 6-7:  GELU (Transformer 핵심)
Week 8-10: Softmax (Attention 핵심)
Week 11-13: LayerNorm (Transformer 완성)
Week 14-17: Pooling + Im2col (CNN 완성)
Week 18-20: 통합 검증
```

---

## 5. WP4: NoC 인터커넥트 & 제어

### 5.1 토폴로지: 하이브리드 Ring + Crossbar

```
     ┌──────── Crossbar (부분합 Reduction) ────────┐
     │  Port0  Port1  Port2  ...  Port7            │
     └──┬───┬───┬───┬───┬───┬───┬───┬──────────────┘
        │   │   │   │   │   │   │   │
     ┌──▼───▼───▼───▼───▼───▼───▼───▼──┐
     │  MVE0─MVE1─MVE2─...─MVE7        │
     │       Bidirectional Ring          │
     └──────────────────────────────────┘
```

- **Ring (256-bit, 250MHz):** 순차 데이터 스트리밍, ~16 GB/s 양방향
- **Crossbar (8x8):** 부분합 All-Reduce, ~64 GB/s

### 5.2 DBC (Decoder & Bus Controller)

**하이브리드 마이크로코드 + FSM:**

```
명령어 Fetch → μCode Sequencer (BRAM ROM) → μop Decoder
                                              ├── MVE Ctrl FSM
                                              ├── NoC Ctrl FSM
                                              ├── DMA Ctrl FSM
                                              └── Sync Barrier FSM
```

**마이크로코드 포맷 (64-bit):**
```
[63:60] uop_type | [55:48] mve_mask | [47:44] opcode | [31:0] params
```

### 5.3 PCIe 호스트 인터페이스

**XDMA IP 활용 (pg195):**
- H2C x2 채널: 가중치 + 입력 데이터 DMA (~12 GB/s 실효)
- C2H x2 채널: 결과 수신
- AXI-Lite: CSR 레지스터 접근
- MSI-X 인터럽트 4벡터

### 5.4 S80 ISA (64-bit 고정폭)

| Category | Opcode | 니모닉 | 설명 | 사이클 |
|----------|--------|--------|------|--------|
| 연산 | 0x01 | GEMV | 행렬-벡터 곱 | M+64 |
| 연산 | 0x02 | GEMM | 행렬-행렬 곱 | M*N+64 |
| 활성화 | 0x11 | GELU | GELU 활성화 | N/256+4 |
| 활성화 | 0x15 | SFMX | Softmax | 3*N/256+8 |
| 활성화 | 0x16 | LNRM | LayerNorm | 3*N/256+8 |
| 데이터 | 0x20 | DMA_H2S | HBM→SRAM | size/bw |
| 제어 | 0x32 | BARRIER | MVE 동기화 | 가변 |
| 제어 | 0x3F | HALT | 종료+IRQ | - |

### 5.5 멀티 FPGA 확장

Aurora 64B/66B + GTY: 4-lane @10.3 Gbps = ~5 GB/s 유효 (FPGA간)

### 5.6 XCKU5P 리소스 예산

| 모듈 | LUT | BRAM36K | DSP48E2 |
|------|-----|---------|---------|
| XDMA IP | ~15K | 12 | 0 |
| DBC 시퀀서 | ~5K | 4 | 0 |
| Ring NoC (8 라우터) | ~8K | 8 | 0 |
| Crossbar Reduce | ~12K | 0 | 16 |
| 8x MVE (MAC+SRAM) | ~80K | 128 | 256 |
| Aurora + Bridge | ~10K | 4 | 0 |
| AXI + Misc | ~10K | 8 | 0 |
| **합계** | **~140K (65%)** | **164 (34%)** | **272 (22%)** |

---

## 6. WP5: SEDA 컴파일러 & 소프트웨어

### 6.1 소프트웨어 스택 구조

```
Python API (seda-py) / PyTorch Backend (torch-seda)
        │
SEDA Runtime Library (libseda-rt)
  ├── Command Queue
  ├── Memory Manager
  └── Device Manager
        │
SEDA Kernel Driver (XDMA 래퍼)
        │ PCIe
FPGA (XDMA IP → AXI → MVE/DBC/DDR4)
```

### 6.2 컴파일러 파이프라인

```
PyTorch Model → ONNX Export → SEDA Frontend (ONNX Parser)
  → Graph Optimizer (Op Fusion, Const Folding)
  → Tiling Scheduler (행렬 분할, DMA 계획)
  → Backend CodeGen (S80 ISA 명령어 생성)
  → S80 Binary (.s80b)
```

### 6.3 컴파일러 MVP 우선순위

| Phase | 기능 | 시점 |
|-------|------|------|
| P1 | ONNX MatMul 파싱 → S80 GEMV 명령어 | Month 1-3 |
| P2 | 타일링 스케줄러 + 더블 버퍼링 | Month 4-6 |
| P3 | Op Fusion + torch.compile 백엔드 | Month 7-9 |
| P4 | 결정론적 스케줄러 (Groq급) | Month 10-12 |

### 6.4 시뮬레이터 (2단계)

| 시뮬레이터 | 언어 | 속도 | 용도 |
|-----------|------|------|------|
| 기능 시뮬레이터 | Python/NumPy | ~1000x | 연산 정확성, 골든 모델 |
| 사이클 정확 | C++ | ~10x | 타이밍, 대역폭 병목 |

### 6.5 PyTorch 통합

- **Phase 1:** ONNX Runtime Custom EP (MatMul, Add, ReLU)
- **Phase 2-3:** `torch.compile(model, backend="seda")` 백엔드

### 6.6 MFU 90%+ 달성 전략

S80 SRAM 2GB에 Llama-3 70B 단일 레이어 가중치(~1.2GB) **완전 상주 가능:**
- HBM 접근 = 첫 로드 1회만
- 이후 토큰은 입력 벡터만 스트리밍 (96KB)
- **실질 MFU ~100% (compute-bound)** 달성 가능

---

## 7. WP6: 검증 & ASIC 전환

### 7.1 Vivado 3단계 시뮬레이션

| 단계 | 목적 | 시점 |
|------|------|------|
| Behavioral | 기능 정확성 | 매 커밋 |
| Post-Synthesis | 합성 후 기능/타이밍 | Weekly |
| Post-Implementation | 배치배선 후 최종 타이밍 | 크리티컬 블록 |

**시뮬레이션 가속:** SystemVerilog DPI-C로 C/C++ 골든 모델과 연결, 10-100X 속도 향상.

### 7.2 UVM 검증 환경

- MAC Agent, VE Agent, TE Agent 3개 독립 에이전트
- Constrained Random: 50K+ 트랜잭션
- Functional Coverage 목표: 95%+
- SVA Assertion: MAC 레이턴시, 이중 예외, AXI 핸드셰이크

### 7.3 FPGA In-System 검증

- ILA 6개 + VIO 2개 배치 (~23 BRAM)
- AXI Protocol Checker IP 삽입
- 하드웨어 성능 카운터 16개 (64-bit)

### 7.4 수치 정확도 검증

| 정밀도 | 최대 상대 오차 | 최대 ULP 오차 |
|--------|--------------|-------------|
| FP32 Accum | < 1e-6 | <= 1 ULP |
| FP16 GEMV | < 0.1% | <= 2 ULP |
| FP8 E4M3 | < 5% | <= 1 ULP |
| FP4 E2M1 | < 25% | <= 1 ULP |

### 7.5 FPGA → ASIC 전환 전략

**코드 이중화 (`ifdef` 기반):**

| FPGA 구성요소 | ASIC 대체 |
|-------------|----------|
| BRAM/URAM | 파운드리 SRAM 컴파일러 매크로 |
| DSP48E2 | DesignWare/ChipWare MAC |
| MMCM/PLL | Latch-based Clock Gating |
| XDC | SDC (OCV/AOCV 마진 추가) |

**ASIC 전환 전 필수 정적 검증:**
1. RTL Lint (SpyGlass)
2. CDC/RDC 검증
3. Formal Equivalence (Formality)

### 7.6 CI/CD 자동화

Jenkins/GitLab CI + Vivado Batch Mode:
- 매 커밋: MAC/VE/TE 시뮬레이션 (30분)
- Daily: 정밀도 정확도 (2시간), 시스템 통합 (4시간)
- Nightly: UVM Random 50K+ (12시간)
- Weekly: Post-Synth Simulation (6시간)

---

## 8. WP7: LLM 워크로드 매핑

### 8.1 Llama-3 70B → S80 MVE 매핑

| 연산 | 행렬 크기 | MVE 할당 | 타일 수 |
|------|----------|---------|--------|
| W_Q * x | **8192x8192** | MVE 0 (완벽 매핑) | 1 |
| W_K,V * x | 8192x1024 | MVE 1 (병합) | 1 |
| W_O * x | **8192x8192** | MVE 0 (재사용) | 1 |
| W_gate * x | 8192x28672 | MVE 0-3 (4타일) | 4 |
| W_up * x | 8192x28672 | MVE 4-7 (4타일) | 4 |
| W_down * x | 28672x8192 | MVE 0-3 (재사용) | 4 |

**단일 레이어:** ~50,000 cycles, 80 레이어: ~4M cycles = **2ms @ 2GHz**

### 8.2 KV Cache 관리

| 컨텍스트 길이 | KV Cache | 배치 |
|-------------|----------|------|
| ~2K tokens | 640MB | SRAM 상주 |
| ~4K tokens | 1.28GB | SRAM 상주 |
| ~8K+ tokens | 2.56GB+ | SRAM + HBM |

### 8.3 멀티칩 추론 (70칩)

**권장: TP=5, PP=14 하이브리드**
- 5칩이 Tensor Parallel로 각 레이어 분할
- 14 파이프라인 스테이지 (5-6 layers/stage)
- 칩간 대역폭 100+ GB/s 필요 (오버헤드 2.5%)

### 8.4 에너지 효율

| 플랫폼 | J/token | 근거 |
|--------|---------|------|
| NVIDIA H100 | 10-30 | 700W, HBM 접근 비용 |
| Groq LPU | 1-3 | SRAM-only, 576칩 |
| **S80 (목표)** | **0.5-1.5** | SRAM 2GB + HBM, 70칩 |

### 8.5 FPGA 데모 시나리오

| 모델 | 파라미터 | FPGA | 예상 성능 |
|------|---------|------|----------|
| MNIST MLP | 234K | KCU116 | 즉시 가능 |
| ResNet-20 | 270K | KCU116 | 단기 구현 |
| **GPT-2 Small** | **124M** | **KCU116** | **80-300 tok/s** |
| TinyLlama 1.1B | 1.1B | VCU118 | 5-15 tok/s |

---

## 9. 통합 로드맵 & 마일스톤

### 9.1 12개월 로드맵

```
Month 1-3:  ██████████  Phase 1 - Foundation
  ├── FP16 MAC RTL + 검증 (WP1 M1-M2)
  ├── URAM Weight File + DDR4 MIG (WP2)
  ├── ReLU + Sigmoid + Adder Tree (WP3)
  ├── XDMA PCIe 링크업 + DBC v1 (WP4)
  ├── XDMA 드라이버 + Python API (WP5)
  ├── CI/CD 파이프라인 구축 (WP6)
  └── MNIST MLP 데모

Month 4-6:  ██████████  Phase 2 - Transformer Core
  ├── VE/TE 구현 + 멀티정밀도 (WP1 M3-M4)
  ├── DMA 엔진 + Double-Buffering (WP2)
  ├── GELU + Softmax + LayerNorm (WP3)
  ├── Ring NoC + 8 MVE 연결 (WP4)
  ├── SEDA 컴파일러 MVP + ONNX EP (WP5)
  ├── UVM Agent 구축 (WP6)
  └── ★ GPT-2 Small 데모 (핵심 마일스톤)

Month 7-9:  ██████████  Phase 3 - Optimization
  ├── KCU116 타이밍 클로저 200MHz (WP1 M5)
  ├── 타일링 컨트롤러 HW (WP2)
  ├── Pooling + Im2col (WP3)
  ├── ISA v2 + Aurora 멀티FPGA (WP4)
  ├── torch.compile 백엔드 + 프로파일러 (WP5)
  ├── RTL Clean-up + Lint (WP6)
  └── ResNet-50, BERT 벤치마크

Month 10-12: ██████████  Phase 4 - Scale-up & ASIC Prep
  ├── VCU118 이관 (16 Sub, FP16) (WP1)
  ├── HBM 보드 검증 (U280/U55C) (WP2)
  ├── 2:4 Structured Sparsity (WP3)
  ├── 결정론적 스케줄러 (WP5)
  ├── ASIC 합성 시작 (Synopsys DC) (WP6)
  ├── Llama-3 8B 단일 레이어 벤치마크 (WP7)
  └── ★ MFU 90%+ 달성 (시뮬레이터)
```

### 9.2 핵심 마일스톤 요약

| # | 마일스톤 | 시점 | 성공 기준 |
|---|---------|------|----------|
| MS1 | FP16 GEMV 동작 | Month 2 | 256x256 FP16 정확 일치 |
| MS2 | MNIST 추론 | Month 3 | 97%+ 정확도, PCIe 통신 |
| MS3 | **GPT-2 Small 데모** | **Month 6** | **텍스트 생성, 80+ tok/s** |
| MS4 | VCU118 16 Sub | Month 10 | FP16 200MHz 타이밍 클로저 |
| MS5 | MFU 90%+ (시뮬레이터) | Month 12 | 사이클 정확 시뮬레이터 기준 |
| MS6 | ASIC RTL Freeze | Month 15 | Lint/CDC/RDC 클린 |
| MS7 | ASIC Tapeout | Month 18 | GDS 제출 |

---

## 10. 리소스 계획

### 10.1 팀 구성 (15-19명)

| 역할 | 인원 | WP | 주요 업무 |
|------|------|-----|----------|
| RTL 설계 (시니어) | 2 | WP1,2 | MAC/VE/TE, 메모리, DMA |
| RTL 설계 (주니어) | 2 | WP3,4 | SFM, NoC, DBC |
| FPGA 엔지니어 | 2 | WP1-4 | Vivado 구현, 타이밍 클로저 |
| 검증 엔지니어 | 3 | WP6 | UVM, ILA, 수치 정확도 |
| 컴파일러 엔지니어 | 2 | WP5 | SEDA 프론트엔드/백엔드 |
| 런타임/드라이버 | 1 | WP5 | XDMA, Python API |
| 시뮬레이터 엔지니어 | 1 | WP5 | Python/C++ 시뮬레이터 |
| ASIC Physical | 2 | WP6 | 합성, P&R, Sign-off |
| DevOps | 1 | WP6 | CI/CD, 빌드 자동화 |
| PM | 1 | 전체 | 일정/리스크 관리 |

### 10.2 하드웨어 비용

| 항목 | 수량 | 비용 (USD) |
|------|------|-----------|
| KCU116 (보유) | 1 | $0 |
| VCU118 (VU9P) | 1 | ~$9,000 |
| Alveo U280/U55C | 1 | ~$10,000-14,000 |
| 서버 (빌드팜) | 2 | ~$20,000 |
| **합계** | | **~$40,000-45,000** |

### 10.3 EDA 도구

| 단계 | 도구 | 연간 비용 |
|------|------|----------|
| FPGA | Vivado Design Suite | 무료~$3,500 |
| 검증 | Questa/VCS | $100K-200K |
| ASIC 합성 | Synopsys DC / Cadence Genus | $200K-400K |
| ASIC P&R | ICC2 / Innovus | $200K-400K |
| Sign-off | PrimeTime, Calibre | $100K-200K |
| **합계 (Phase 1-2)** | Vivado + Questa | **$100K-200K** |
| **합계 (Full ASIC)** | 전체 EDA | **$500K-1M+** |

### 10.4 핵심 리스크 & 대응

| 리스크 | 영향 | 확률 | 대응 |
|--------|------|------|------|
| DSP 부족 (FPGA) | VE 수 제한 | 높음 | VCU118 스케일업, PWL slope를 시프트로 대체 |
| DDR4 대역폭 병목 | DMA > 연산 | 중간 | 타일 축소, HBM 보드 이관 |
| 타이밍 클로저 실패 | 클럭 하향 | 중간 | 파이프라인 추가, Pblock 배치 |
| FP16 수치 오차 | 모델 정확도 | 낮음 | FP32 누산, 혼합 정밀도 |
| ASIC 합성 호환성 | 전환 지연 | 중간 | 조기 `ifdef` 분리, RTL Lint |
| 컴파일러 복잡도 | MFU 목표 미달 | 중간 | Groq/TVM 참조, 단계적 기능 추가 |

---

## 부록: Vivado 프로젝트 구조

```
D:\scp80\
├── rtl\
│   ├── common\       (s80_pkg.sv, fp16_mac.sv, multi_prec_mac.sv, adder_tree.sv)
│   ├── ve\           (ve_top.sv, weight_file.sv, mac_array_128.sv, vec_buffer.sv)
│   ├── te\           (te_top.sv, te_adder.sv)
│   ├── ce\           (ce_top.sv, ce_adder.sv)
│   ├── cm\           (cm_top.sv, cm_adder.sv)
│   ├── sfm\          (sfm_top.sv, sigmoid_pwl.sv, gelu_ispa.sv, softmax.sv, layer_norm.sv)
│   ├── noc\          (ring_noc.sv, noc_router.sv, crossbar_reduce.sv)
│   ├── dbc\          (dbc_top.sv, ucode_sequencer.sv, isa_decoder.sv)
│   ├── mem\          (dma_controller.sv, tiling_ctrl.sv, weight_dma.sv)
│   └── top\          (s80_top.sv, pcie_wrapper.sv)
├── tb\               (UVM testbenches, golden models)
├── ip\               (Vivado IP: XDMA, MIG, ILA, VIO)
├── constraints\      (XDC: pinout, timing, floorplan)
├── scripts\          (TCL: build, sim, program, CI)
├── sw\
│   ├── driver\       (XDMA 래퍼, 커널 모듈)
│   ├── runtime\      (libseda-rt, Python API)
│   ├── compiler\     (SEDA frontend/backend)
│   └── simulator\    (Python functional, C++ cycle-accurate)
└── docs\             (아키텍처 스펙, 마이크로아키텍처)
```

---

*본 계획서는 7개 영역의 병렬 심층 연구 결과를 통합하여 작성되었습니다.*
*Vivado 기반 FPGA 프로토타이핑부터 ASIC 테이프아웃까지의 18개월 로드맵을 포함합니다.*
