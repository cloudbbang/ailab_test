# WP1 MAC/PE RTL 구현 계획서 - 분석, 문제점 및 개선/연구 방향

본 문서는 `WP1_MAC_PE_RTL_구현계획서.md`를 바탕으로 분석한 잠재적 문제점과 성능/효율을 극대화하기 위한 개선 및 추가 연구 방안을 정리한 문서입니다.

## 1. DSP-Packing 및 멀티정밀도 연산 (M2 단계)

### 🧐 분석 및 잠재적 문제점
* **교차 오염 (Cross-contamination) 리스크:** FP8 (2-MAC) 및 FP4 (4~6-MAC) 연산을 위해 하나의 DSP48E2를 시분할/비트분할(Overpacking)하여 사용 시 Guard bit를 두더라도 누산 과정에서 오버플로우나 Carry로 인한 교차 오염 리스크가 존재합니다.
* **FP Format 다양성 부족:** E4M3 형식의 FP8만 부분 명시되어 있으나 최근 생성형 AI 모델 (예: Llama, GPT)에서는 용도에 따라 E5M2 포맷과 혼합하여 쓰는 추세입니다.
* **Microscaling(MX) 포맷 부재:** OCP(Open Compute Project) 표준 등으로 떠오르는 MX 포맷이나 블록 단위 공유 지수(Shared Exponent) 처리에 대한 설계 확장이 반영되어 있지 않습니다.

### 💡 개선 및 연구 방향
* **Bit-accurate 모델링 강화:** Python 골든 모델 작성 시 DSP48E2의 48-bit Accumulator 동작과 Carry Save Adder(CSA)의 트리를 정확하게 모사하는 시뮬레이터를 구축하여 Guard bit의 안전성을 사전 수학적으로 검증해야 합니다.
* **유연한 데이터 포맷 동적 브랜치:** `precision_mode_t`에 E5M2 지원 모드를 추가하고, 향후 OCP MX4/MX6 등 Shared Exponent 블록 모드를 지원할 수 있는 `Pre-Scaler`, `Post-Scaler` 인터페이스를 준비해야 합니다.
* **ASIC 전환 시 아키텍처 다변화:** FPGA용 코드는 DSP48E2 Packing에 의존하지만, ASIC 합성 시에는 개별 Multiplier(11x11, 4x4 등) 인스턴스화가 면적과 전력 측면에서 월등히 유리합니다. `ifdef ASIC` 분기 시 Multiplier 인스턴스를 동적으로 생성하고, 파이프라인 단계를 파라미터화할 수 있는(Generate 구문 적극 활용) 구조적 분리가 요구됩니다.

## 2. Adder Tree와 라우팅 혼잡 (M3 / M4 단계)

### 🧐 분석 및 잠재적 문제점
* **라우팅 병목(Fan-in/Fan-out) 혼잡:** 128개의 MAC 출력을 7-stage Adder Tree로 묶는(Reduction) 방식은 수천 가닥의 와이어 넷이 중앙으로 모여들게 만들어 물리적 라우팅 Congestion을 유발하고, 결과적으로 200MHz 타이밍 클로저 달성에 치명적인 실패 원인이 될 수 있습니다.
* **TE/CE의 계층적 덧셈 딜레이 누적:** VE 내부의 트리 구조뿐 아니라, 상위 레벨인 TE와 CE에서도 지속적으로 Adder Tree가 이어져 전체 SoC 차원에서 배선 지연(Routing Delay)이 누적됩니다.

### 💡 개선 및 연구 방향
* **Systolic Array 기반 로컬 통신 구조 검토:** Adder Tree 방식(Reduction tree) 대신 인접 MAC 사이에만 부분합 연산을 넘겨받는 (Weight/Output Stationary 방식 혼합) 1D/2D Systolic Array 형태로 설계를 보완 반영하면 라우팅 혼잡을 획기적으로 줄여 고클럭을 쉽게 달성할 수 있습니다.
* **Tapped-Delay Line 및 Shift Register(SRL) 최적화:** Xilinx FPGA의 구조적 이점인 SRL16/SRLC32E를 적극 활용하여, Adder Tree 과정 파이프라인에서 발생하는 데이터 스큐를 추가 FF나 LUT 낭비 없이 관리할 수 있는 스케줄링 최적화 연구가 필요합니다.
* **Pblock 최적화 기반 Hard Macro 적용:** VE 설계 초기부터 평면 공간 상(Vivado Floorplanning) 위치를 특정하는 Pblock 제약을 실험 라인으로 추가하여 물리적 위치와 논리적 경로 시차를 동기화하는 기법을 실험합니다.

## 3. 메모리 계층 대역폭 및 병목 (M3 / M5 단계)

### 🧐 분석 및 잠재적 문제점
* **URAM 배치 이격(Distance)으로 인한 병목:** KCU116 보드의 URAM은 칩 전반에 흩어져 있고, 논리적으로 가깝다 해도 DSP 블록과의 다이 내 거리가 물리적으로 멀면 M3 단계 동작 최고 주파수(Fmax)가 떨어집니다.
* **전체 시스템 대역폭 한계:** 16개 VE가 동작하는 CE 단위(2048 MAC)가 매 사이클 작동 시 엄청난 양의 외부 메모리 트래픽(DDR/PCIe)을 오프칩에서 온칩으로 동기 시켜야 합니다. 연산력(MAC)에 비해 입출력 메모리 시스템의 성능이 뒷받침하지 못할 위험이 큽니다.

### 💡 개선 및 연구 방향
* **URAM 파이프라이닝 및 비동기 분리 구조(GALS):** URAM 내장 OREG 파이프라인 레지스터를 반드시 활성화하고, 더 나아가 MAC 연산 영역과 메모리 영역 클럭 도메인을 분리하는 비동기식 FIFO 기반 구조를 검토하여 연산부 성능 저하를 방지합니다.
* **Roofline 모델 정량 분석 수행:** 하드웨어 구현 전, 예상되는 DDR4 대역폭과 PCIe Throughput을 바탕으로 해당 연산 모듈이 Memory-bound 형태에 놓일지 Compute-bound 형태를 띌지 수식적인 정량(Roofline Model) 분석이 필수적으로 수행되어야 합니다.
* **Sparsity 및 Compression 처리기(Decoder) 삽입 방안:** 대역폭 절감을 위해 모델 가중치(Weights) 데이터의 2:4 Sparse 처리나 압축 전송(Lossless compression) 기능을 VE 메모리 버퍼 단 바로 앞단에 삽입하는 것을 연구해야 합니다.

## 4. 검증 및 CI/CD 아키텍처 개선 (M1 ~ M5 전반)

### 🧐 분석 및 잠재적 문제점
* 통합 검증 단계로 올라갈수록 SystemVerilog 기반의 연산 시뮬레이션 시간이 기하급수적으로 늘어나 개발 사이클이 지체됩니다.

### 💡 개선 및 연구 방향
* **cocotb 연동 환경 구축:** 파이썬(Python)의 빠른 생태계와 골든 모델(Numpy)을 C/C++ 포킹 없이 RTL 시뮬레이터와 직접 연동할 수 있는 `cocotb` 기반 Testbench 환경으로 마이그레이션하여 수치적 무결성 분석 속도를 압도적으로 높입니다.
* **Verilator 모델 혼합 시뮬레이션 활성화:** DPI-C 보다 훨씬 빠른 Cycle-accurate 시뮬레이션 도구인 Verilator를 활용하여 계층적 검증 시간(M4, M5 단계)을 대규모 C++ 바이너리 컴파일 형태로 단축시키는 연구가 병행되어야 합니다.

---

## 🚀 결론 및 Next Action Items

상기 개선 방향을 바탕으로 당면한 WP1 추진 전제로서 아래 3가지 Action Item의 우선 수행을 제안합니다.

1. **Cocob + Verilator 기반 High-speed 검증 파이프라인 사전 셋업**
2. **DSP48E2 Bit-Accurate 파이썬 에뮬레이터 개발 및 Guard Bits 오차 시나리오 검증**
3. **Vivado 합성 파일럿 패스 (Pilot Pass):** M1/M2 코딩 전, DSP와 URAM 껍데기(Dummy) 모듈을 이용한 더미 200MHz 라우팅 Floorplanning 선행 연구
