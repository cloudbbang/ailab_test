# SEMICS Fabless Center 발표자료 통합 분석 보고서

**작성일:** 2026-03-23
**분석 대상:** Fabless Center_20250418 폴더 내 PPT 10개 파일 (총 165장 슬라이드)
**프로젝트:** SEMICS S80 NPU (Neural Processing Unit) 개발
**발표자:** Ted Lee (SEMICS)
**보안등급:** Confidential

---

## 1. 개요

본 보고서는 SEMICS사의 Fabless Center 프로젝트에서 2025년 4월~2026년 2월까지 약 10개월에 걸쳐 진행된 S80 NPU 칩 설계 과정을 10개의 발표자료(총 165장 슬라이드)를 기반으로 통합 정리한 것입니다. S80은 LLM(대규모 언어 모델) 추론에 최적화된 전용 AI 가속기로, GEMV/GEMM 행렬 연산에 특화된 아키텍처를 지향합니다.

---

## 2. 발표 시간순 진행 요약

| # | 파일명 | 날짜 | 주제 | 슬라이드 |
|---|--------|------|------|----------|
| 1 | Fabless Center_20250418 | 2025.04.18 | GPT-3 파라미터/연산량 분석 및 NPU 아키텍처 조사 | 23장 |
| 2 | Fabless Center_20250509 | 2025.05.09 | S80 코어 기본 아키텍처 (3D+Mesh 구조) | 10장 |
| 3 | Fabless Center_20250613 | 2025.06.13 | 행렬 곱셈 타일링 최적화 기법 | 15장 |
| 4 | Fabless Center_20250711 | 2025.07.11 | S80 코어 구조 확정 및 DNN 연산 지원 범위 | 21장 |
| 5 | Fabless Center_20250801 | 2025.08.01 | S80 데이터 흐름 설계 (메모리-PE 간) | 15장 |
| 6 | Fabless Center_20250829 | 2025.08.29 | S80 통신 포트 설계 및 멀티코어 확장 | 15장 |
| 7 | Fabless Center_20251219 | 2025.12.19 | S80 NPU 상세 아키텍처 확정 및 경쟁 분석 | 17장 |
| 8 | Fabless Center_20260109 | 2026.01.09 | S80 FPGA 구현 및 Groq LPU 비교 분석 | 18장 |
| 9 | Fabless Center_20260130 | 2026.01.30 | FPGA 프로토타이핑 결과 및 성능 목표 | 15장 |
| 10 | S80-Village-Town architecture | 2026.02.27 | Village-Town 계층적 연산 엔진 구조 | 16장 |

---

## 3. S80 NPU 아키텍처 설계 진화 과정

### 3.1 Phase 1: 기초 연구 및 요구사항 도출 (2025.04~05)

#### GPT-3 모델 분석을 통한 연산 요구사항 도출 (2025.04.18)
- GPT-3의 175B 파라미터 구조를 정밀 분석
  - **임베딩:** 1.229B (0.7%) - 50,257 x 12,288 행렬
  - **어텐션:** 57.982B (33.1%) - 128 x 12,288 x 4 x 96 x 96
  - **피드포워드 신경망(FFN):** 115.964B (66.2%) - 12,288 x 49,152 x 2 x 96
- **핵심 관찰:** FFN이 전체 파라미터의 66.2%를 차지하며, 행렬-벡터 곱셈(GEMV)이 NPU 가속의 주요 대상
- FP16 기준 350GB 메모리 필요
- 연간 목표: 지적재산권 2건 이상, AI 칩의 장비 적용 1건 이상

#### S80 코어 기본 개념 정립 (2025.05.09)
- **3D + Mesh 구조** 채택: PE 레이어와 메모리 레이어의 2층 적층
- **100x100 PE = 10,000개** MAC 유닛 배열
- GPU 대비 Systolic Array 방식의 효율성 근거로 설계
- 4가지 데이터플로우 방식(WS/OS/IS/RS) 검토 → Dynamic 방식 채택
- **DRAM 접근의 에너지 비용이 연산 대비 200배 이상** (32b DRAM Read: 640pJ vs 32b FP Mult: 3.7pJ)
- 네오와인 특허(32x32 MAC Array 깊이방향 컨볼루션 가속장치) 참조

### 3.2 Phase 2: 최적화 기법 연구 (2025.06)

#### 행렬 곱셈 타일링 최적화 (2025.06.13)
- 10,000 x 10,000 행렬 곱셈 기준 단계적 최적화 결과:

| 방식 | 데이터 이동 시간 (H100 기준) | 연산 시간 | 병목 |
|------|---------------------------|----------|------|
| Naive | **1,334 ms** | 2 ms | Memory-bound |
| A 행 재사용 | **667 ms** | 2 ms | Memory-bound |
| A행+B열 블록 재사용 (b=100) | **6.67 ms** | 2 ms | 거의 Compute-bound |
| **타일링 (b=100)** | **1.11 ms** | 2 ms | **Compute-bound 달성** |

- 타일링으로 데이터 이동 시간을 연산 시간 이하로 줄여 **Compute-bound** 달성
- H100, Cerebras CS-2, AMD XDNA NPU 메모리 계층 비교 분석
- CNN 적용: Toeplitz 행렬 및 가중치 복제 방식으로 컨볼루션을 행렬 곱으로 변환

### 3.3 Phase 3: 코어 구조 확정 (2025.07~08)

#### S80 코어 구조 확정 (2025.07.11)
- **확정된 코어 사양:**
  - 다이 크기: 100 mm² (1cm x 1cm)
  - PE 수: 10,000개 (N=100)
  - PE당 SRAM: 24.8 KB (12,680 FP16)
  - 연산 성능: 22 TOPS (10,000 x 2 x 1.1GHz)
  - AMD 3D V-Cache 적용 시: PE당 177MB/10,000 = 18.12KB

- **PE 내부 구성 요소:**
  - Fabric Router (4방향 PE간 라우팅)
  - Register File
  - MAC (Multiply-Accumulate)
  - Math (비선형 함수 처리)
  - Data Compression
  - CRC Check

- **지원 DNN 연산 7가지:**
  1. GEMV/GEMM (행렬-벡터/행렬-행렬 곱셈)
  2. 2D Convolution
  3. Hadamard Product (요소별 곱셈)
  4. Pooling & Unpooling
  5. Add & Normalization
  6. Softmax
  7. Nonlinear Activation (ReLU, tanh, exp 등)

- **지원 DNN 모델:** MLP, CNN, RNN, LSTM, Autoencoder, GAN, Transformer

#### S80 데이터 흐름 설계 (2025.08.01)
- **두 가지 데이터 흐름 차원:**
  - **S80(I):** PE layer ↔ Memory layer (TSV 3D 수직 연결)
    - 데이터 라인: N²(10,000) x 2bytes(FP16) = 160,000개
    - 주소+제어 라인: 14+2
  - **S80(II):** 칩 ↔ 메인 메모리(HBM) (인터포저 기반 연결)

- **HBM 로드맵:**

| 세대 | 출시년도 | 속도 | I/O 수 |
|------|---------|------|--------|
| HBM4 | 2026 | 8 Gbps | 2,048 |
| HBM5 | 2027 | 8 Gbps | 4,096 |
| HBM6 | 2032 | 16 Gbps | 4,096 |
| HBM7 | 2035 | 24 Gbps | 8,192 |
| HBM8 | 2038 | 32 Gbps | 16,384 |

- **연산 밀도 비교:**
  - S80: 22 TOPS / 100 mm² = **0.22 TOPS/mm²**
  - H100: 989.4 TOPS / 814 mm² = **1.22 TOPS/mm²**
  - Cerebras: 7,480 / 46,225 mm² = **0.16 TOPS/mm²**

#### S80 통신 포트 설계 (2025.08.29)
- **SEAS (SEmics AI System)** 시스템 아키텍처 정의
  - 여러 S80 코어가 양방향 버스로 연결, CPU/메모리와 통합
- **듀얼 포트 SRAM** 기반 통신 인터페이스
- **멀티코어 확장 전략:**
  - 단일 코어: 연산 시간 = 2N²
  - 듀얼 코어: 연산 시간 = N² + α (α = 코어 간 통신 오버헤드)
  - 4코어: 연산 시간 = 2N² + α → 코어 수에 따른 선형적 성능 향상
- **TSV 요구사항:** 160,000개 (100mm² 다이 기준), 균일 분배 필요
- 향후 과제: 실리콘 포토닉스 탐색, 가중치 희소성(sparsity) 활용

### 3.4 Phase 4: 상세 아키텍처 확정 (2025.12)

#### S80 NPU 상세 아키텍처 (2025.12.19)
- **최종 아키텍처 구성:**
  - S80 chip → S80 core → 8개 MVE(Matrix-Vector multiplication Engine)
  - 각 MVE → 32개 sub 블록 + SFM(Special Function Module)
  - 외부: HBM 2개 (192GB), PCIe, DBC

- **sub 블록 사양:**
  - SRAM: (8192+1) x 257 x 16bit = 32Mb ≒ 4MB
  - MAC: 8,192개 (16bit)
  - Dual-port 8T SRAM

- **성능 스펙:**

| 정밀도 | 행렬 크기 | 성능 |
|--------|----------|------|
| FP16 | 8192 x 8192 | **8.39 PFLOPS** |
| FP8 | 16384 x 16384 | **16.78 PFLOPS** |
| FP4 | 32768 x 32768 | **33.55 PFLOPS** |

- **트랜지스터 수:**
  - MAC: 약 755억 개
  - SRAM: 약 756억 개
  - **총합: 약 1,511억 개**

- **16bit FP MAC 게이트 수 분석:** 약 4,700~5,900 Gates/MAC
  - Mantissa Multiplier: 1,200~1,400
  - Exponent Adder: 300~400
  - Alignment Shifter: 800~1,000
  - 32-bit FP Adder: 1,200~1,500
  - Normalization Unit: 800~1,000
  - Rounding & Exception: 400~600

- **SFM(Special Function Module) 기능:**
  - sub 결과 합산 및 32bit→16bit 변환
  - Activation function 처리
  - Softmax 연산

### 3.5 Phase 5: FPGA 검증 및 경쟁 분석 (2026.01)

#### FPGA 프로토타이핑 (2026.01.09 ~ 01.30)
- **개발 보드:** Xilinx KCU116 (Kintex UltraScale+ XCKU5P-2FFVB676E)
- **FPGA 프로토타입 사양:** (S80 대비 축소)

| 항목 | S80 (타겟) | FPGA (프로토타입) |
|------|-----------|-----------------|
| MVE 수 | 8 | 1 |
| sub/MVE | 64 | 4 |
| MAC/sub | 8,192 | 256 |
| SRAM/sub | 4MB | 32KB |
| 클럭 | 2GHz | 100MHz |
| Word length | 4byte(FP32) | 2byte(INT16) |

- **FPGA 구현 구조:** MicroBlaze 소프트 프로세서 + APB 레지스터 + BRAM 기반 MAC 연산
- **GEMV 연산 시간:** (64+α) clocks (256x256 기준)
- **향후 과제:** INT16→FP16/FP32 변환, Overflow 처리, Activation 구현, Real-time input

#### 성능 목표 (MFU/HFU)

| 지표 | NVIDIA GPU | Groq LPU | S80 (목표) |
|------|-----------|----------|-----------|
| HFU (가동률) | 50~70% | 90%+ | **95%+** |
| MFU (모델 효율) | 30~40% | 80~90% | **90%+** |
| Llama-3 70B 소요 칩 수 | 2~4 | 576~640 | **70** |

#### Groq LPU 경쟁 분석

| 항목 | S80 (2 die) | Groq (1 die, 14nm) |
|------|------------|-------------------|
| 기본 행렬 크기 | **8192 x 8192** | 320 x 320 |
| SRAM | **2 GB** | 230 MB |
| MAC 수 | **4.19M (32bit)** | 409.6K (8bit) |
| MAC/SRAM (#/MB) | 2,048 | 1,781 |
| 칩간 통신 | 미정 | **64 링크** |
| 컴파일러 | SEDA | GroqWare |
| 연산 성능 (INT8) | - | 750 TOPS |
| 연산 성능 (FP16) | - | 188 TFLOPS |
| 메모리 대역폭 | - | 80 TB/s |
| 공정 | - | 14nm (차세대 4nm) |

- **Groq 핵심 특징:** 결정론적 아키텍처, SRAM-only, TSP 구조, Jitter-free 실행
- **CUDA vs GroqWare:** 동적 하드웨어 스케줄링 vs 컴파일 시점 결정론적 스케줄링

### 3.6 Phase 6: Village-Town 계층적 아키텍처 (2026.02)

#### S80 Village-Town Architecture (2026.02.27)
새로운 **계층적 연산 엔진 구조** 제안:

| 계층 | 구성 | MAC 수 | SRAM | 행렬 크기 |
|------|------|--------|------|----------|
| **VE (Village Engine)** | 기본 단위 | 128 | 64KB | 128x128 |
| **TE (Town Engine)** | 4 VE | 512 | 256KB | 256x256 |
| **CE (City Engine)** | 4 TE = 16 VE | 2,048 | 1MB | 512x512 |
| **CM (County Module)** | 4 CE = 64 VE | 8,192 | 4MB | 1024x1024 |

- **Village Engine(VE) 상세:**
  - WF(Weight File): 128 x 128 x 32bit 메모리
  - InV(Input Vector): 128 x 32bit, Serial shift out per clock
  - OtV(Output Vector): 128 x 32bit 출력 래치
  - 128개 64bit MAC 연산기

- **확장 원리:** 행렬을 블록 분할 → 하위 계층에서 병렬 연산 → Adder로 합산
  - TE: W를 2x2 블록 분할, 1st Adder로 합산
  - CE: W를 4x4 블록 분할, 2nd Adder로 합산
  - CM: W를 8x8 블록 분할, 3rd Adder로 합산

- **S80 칩 전체 구성:**
  - 4~8개 CM + DMAC/uCP + CIM + SFM + 2~4개 HBM(48~96GB)
  - NOC로 상호 연결, PCIe로 CPU Host 연결, SiP 패키징

- **메모리 접근:** Short-form(D0-D31) + Long-form(D0-D32767) 이중 모드

---

## 4. 경쟁 제품 비교 종합

### 4.1 최종 성능 비교표

| 항목 | NVIDIA H100 | NVIDIA B200 | Google Ironwood | Groq LPU | **S80 (target)** |
|------|------------|------------|----------------|----------|-----------------|
| PFLOPS (FP8) | 3.96 | 9 | 4.61 | 0.75(INT8) | **67.11** |
| PFLOPS (FP4) | N/A | 18 | - | - | **134.22** |
| PFLOPS (FP32) | - | - | 2.31(FP16) | 0.188(FP16) | **16.78** |
| 트랜지스터 | 800억 | 2,080억 | - | - | **1,511억** |
| 다이 수 | 1 | 2 | 2 | 1 | **2** |
| HBM | 80GB | 192GB | 192GB | 없음(230MB SRAM) | **192GB** |
| 대역폭 | 3.35 TB/s | 8 TB/s | 7.4 TB/s | 80 TB/s | **8 TB/s** |
| 연산 밀도 | 1.22 TOPS/mm² | - | - | - | 0.22→개선 중 |

### 4.2 Cerebras WSE 분석 요약
- WSE-2: 215mm x 215mm 웨이퍼, 84 다이, 850,000 코어
- 온칩 SRAM: 40GB, 메모리 대역폭: 255 TB/s
- 학습: Weight Streaming (Activation Stationary)
- 추론: Weight Stationary (Llama 3.1 70B에 4x WSE-3 사용, 176GB SRAM)
- inter-die IO: 2.88 TB/s

---

## 5. 핵심 기술 결정사항 정리

### 5.1 아키텍처 설계 원칙
1. **최대 병렬성 & 데이터 재사용** (Maximum Parallelism & Data Reuse)
2. **DRAM 접근 최소화** (에너지 비용 200배 차이)
3. **3D 적층 구조** (PE 레이어 + 메모리 레이어, TSV/하이브리드 본딩)
4. **Compute-bound 달성을 위한 타일링 최적화**
5. **멀티 정밀도 지원** (FP32/FP16/FP8/FP4 Configurable MAC)

### 5.2 기술 선택
- **데이터플로우:** Dynamic Weight/Input/Output 방식
- **메모리:** 8T Dual-port SRAM + HBM (192GB)
- **인터커넥트:** TSV 기반 3D 적층 (AMD 3D V-Cache 참조)
- **HBM 연결:** 인터포저 기반
- **시스템:** SEAS (SEmics AI System) 멀티코어 버스 아키텍처
- **컴파일러:** SEDA (Semics Enhanced Device Architecture)

### 5.3 참조 특허 및 기술
- 네오와인 특허: MAC 어레이 기반 깊이방향 컨볼루션 가속장치
- AMD 3D V-Cache: TSV/하이브리드 본딩 기술
- iVECONNE: 32x32 MAC Array NPU 구조

---

## 6. 향후 과제 및 미해결 사항

### 6.1 하드웨어 설계
- [ ] PE 구조 최적화: Single PE vs Group PE 비교 결정
- [ ] 연산 밀도(TOPS/mm²) 향상 (현재 0.22 → H100의 1.22 수준 목표)
- [ ] TSV 160,000개의 물리적 구현 및 균일 분배
- [ ] 실리콘 포토닉스 기반 통신 탐색

### 6.2 FPGA 검증
- [ ] INT16 → FP16/FP32 변환 지원
- [ ] Overflow 처리 구현
- [ ] Activation function 구현
- [ ] DRAM(1GB) 활용 데이터 로드
- [ ] Real-time input (X vector) 지원
- [ ] 최대 용량 구현 검증
- [ ] 응용 application 검토

### 6.3 시스템/소프트웨어
- [ ] SEDA 컴파일러 개발 (GroqWare 벤치마크)
- [ ] 칩간 통신(Chip-to-chip) 설계
- [ ] Simultaneous inference & training 지원
- [ ] 가중치 희소성(sparsity) 활용 방안

### 6.4 응용
- [ ] CNN 애플리케이션 검증
- [ ] LLM 추론 최적화 (Llama-3 70B 등)
- [ ] Thermal Network Model → AI Model 변환 (PINNs)

---

## 7. 아키텍처 진화 타임라인

```
2025.04 ─ GPT-3 분석, NPU 요구사항 도출, 기존 아키텍처(GPU/Systolic Array/TPU) 조사
    │
2025.05 ─ S80 코어 기본 개념: 3D+Mesh, 10,000 PE, 데이터플로우 방식 검토
    │
2025.06 ─ 타일링 최적화로 Compute-bound 달성 검증, CNN 행렬 변환 기법 연구
    │
2025.07 ─ 코어 구조 확정: PE 내부 구성(Router/MAC/Math/Compression), DNN 7가지 연산 정의
    │
2025.08 ─ 데이터 흐름 설계(PE↔Memory, 칩↔HBM), 통신 포트(듀얼포트 SRAM), 멀티코어 확장
    │
    ⋮ (4개월 집중 설계 기간)
    │
2025.12 ─ 상세 아키텍처 확정: 8 MVE x 32 sub, 8.39~33.55 PFLOPS, 1,511억 트랜지스터
    │
2026.01 ─ FPGA 프로토타이핑(KCU116), Groq LPU 경쟁 분석, 성능 목표(MFU 90%+) 수립
    │
2026.02 ─ Village-Town 계층적 아키텍처 제안 (VE→TE→CE→CM 4단계 확장 구조)
```

---

## 8. 결론

SEMICS의 S80 NPU는 약 10개월의 설계 과정을 거쳐 다음과 같은 특징을 가진 AI 가속기로 구체화되었습니다:

1. **대규모 행렬 연산 특화:** 8192x8192 GEMV를 8,192 사이클에 처리하는 MVE 기반 구조
2. **대용량 온칩 메모리:** 2GB SRAM으로 Groq(230MB) 대비 8.7배, HBM 192GB로 B200급
3. **높은 연산 성능 목표:** FP8 기준 67.11 PFLOPS (H100의 약 17배, B200의 약 7.5배)
4. **효율성 지향:** MFU 90%+, HFU 95%+ 목표로 Groq LPU에 근접하는 효율성 추구
5. **계층적 확장:** Village-Town 아키텍처로 128x128 기본 단위에서 1024x1024까지 유연한 스케일링
6. **FPGA 검증 진행 중:** Xilinx KCU116에서 축소 모델의 GEMV 연산 기능 검증 완료

핵심 과제는 연산 밀도 향상(0.22 → 1.22+ TOPS/mm²), 칩간 통신 설계, SEDA 컴파일러 개발, 그리고 실제 LLM 모델에서의 성능 검증입니다.

---

*본 보고서는 Fabless Center 발표자료 10건(165장 슬라이드)의 이미지 분석을 기반으로 자동 생성되었습니다.*
