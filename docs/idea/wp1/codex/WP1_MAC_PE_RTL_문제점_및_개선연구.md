# WP1 MAC/PE RTL 구현계획서 문제점 및 개선 연구

작성일: 2026-03-25  
대상 문서: `docs/idea/wp1/WP1_MAC_PE_RTL_구현계획서.md`

## 1. 검토 목적

본 문서는 WP1 구현계획서를 기준으로 다음을 수행하기 위해 작성했다.

- 계획서의 기술적 리스크와 실행상 공백 식별
- FPGA 실장 가능성, 수치 정확도, 검증 가능성 관점에서 개선 포인트 정리
- 실제 수행 가능한 단계별 연구/개선 로드맵 제안

핵심 결론은 다음과 같다.

- 현재 계획서는 방향성은 타당하지만, "기능 목록" 중심으로 작성되어 있어 실제 구현에서 가장 먼저 터질 리스크가 전면에 드러나지 않는다.
- 가장 큰 리스크는 `부동소수점 연산 규약 미정`, `FP8/FP4 DSP packing 난이도 과소평가`, `128-way reduction의 물리 구현 리스크`, `메모리/대역폭 예산 부재`, `보드 실증 범위와 아키텍처 목표 범위의 혼선`이다.
- 따라서 WP1은 기능 확장 순서보다 `증명 가능한 축소 모델`과 `사전 합성/배치 기반의 리스크 소거`를 우선하는 방식으로 재구성하는 것이 안전하다.

## 2. 총평

원 계획서의 장점은 분명하다.

- FP16 단일 MAC에서 시작해 VE, TE/CE로 올라가는 단계적 확장 구조가 명확하다.
- FP32 누산을 유지해 저정밀도 곱셈의 수치 불안정을 제어하려는 방향이 합리적이다.
- FPGA 실증까지 고려한 점, `ifdef FPGA` / `ifdef ASIC` 분리를 미리 의식한 점도 적절하다.

하지만 아래 항목들은 현재 상태로 진행할 경우 일정 지연 또는 구조 변경을 유발할 가능성이 높다.

## 3. 핵심 문제점

### 3.1 부동소수점 연산 규약이 충분히 닫혀 있지 않음

계획서에는 FP16/FP8/FP4 지원, FP32 누산, RNE 반올림, 특수값 처리, flush-to-zero, saturate-to-max가 함께 등장한다. 문제는 이들이 하나의 일관된 산술 규약으로 정리되어 있지 않다는 점이다.

현재 공백은 다음과 같다.

- FP16 입력에서 subnormal을 완전 지원할지, 입력 변환 시 flush-to-zero 할지 불명확함
- FP8/FP4 변환에서 overflow 시 `Inf`, `NaN`, `saturate` 중 어느 정책을 택할지 미정
- MAC 내부 누산과 VE/TE/CE 상위 reduction에서 예외값을 어떻게 전파할지 정의가 없음
- "FP32 accumulator"가 MAC 내부 누산인지, 벡터 reduction까지 포함하는지 경계가 모호함

이 상태에서는 골든 모델, RTL, 테스트벤치가 서로 다른 해석으로 구현될 수 있다.

개선안:

- 구현 시작 전에 `Arithmetic Contract` 문서를 별도로 정의해야 한다.
- 최소 포함 항목:
  - 지원 포맷별 비트 정의
  - rounding mode
  - overflow/underflow 정책
  - NaN/Inf/subnormal 처리
  - signed zero 처리
  - mode switch 시 pipeline flush 규칙
- 이 계약 문서를 기준으로 Python bit-accurate 모델과 RTL assertion을 함께 맞춰야 한다.

### 3.2 FP8/FP4 DSP packing 난이도가 일정 대비 과소평가되어 있음

계획서는 DSP48E2 1개에서 FP16 1-MAC, FP8 2-MAC, FP4 4~6-MAC를 목표로 한다. 방향 자체는 타당하지만, 실제 리스크는 "곱셈 수"보다 "독립성 보장"과 "후처리 비용"에 있다.

핵심 문제는 다음과 같다.

- packed multiply에서는 cross-contamination을 막기 위한 guard bit 설계가 필수다.
- sign, exponent, mantissa 분리 및 재조합 로직이 DSP 외부 LUT 경로를 크게 늘릴 수 있다.
- FP4는 곱셈만 싸도 정규화/반올림/예외처리 비용이 상대적으로 커져 총 이득이 줄어들 수 있다.
- 계획서가 FP8 E4M3 중심으로 서술되어 있으나, 실제 모델/툴체인 호환성까지 고려하면 E5M2 대응 여지도 검토하는 편이 낫다.

연구 관점의 보완 포인트:

- OCP MX 규격은 MXFP8에서 E4M3와 E5M2를 모두 concrete format으로 다루며, MXFP4(E2M1)도 정의한다. 즉 향후 확장성 관점에서는 E4M3 단일 가정으로 고정하는 것보다 인터페이스 수준에서 다형성을 열어 두는 편이 유리하다.
- 다만 이 사실이 "초기 구현에서 둘 다 한 번에 넣어야 한다"는 뜻은 아니다. 초기 RTL은 E4M3 우선이 맞지만, 타입 정의와 변환 계층은 E5M2 추가를 막지 않게 구성해야 한다.

개선안:

- M2를 한 번에 `FP8+FP4 완료`로 보지 말고 아래처럼 쪼개는 것이 안전하다.
  - M2-A: FP8 E4M3 2-MAC 증명
  - M2-B: FP8 E5M2 옵션 확장
  - M2-C: FP4 E2M1 feasibility study
- FP4는 "필수 기능"보다 "연구 기능"으로 내려서 bit-accurate packing 증명 이후에만 진입하는 것이 적절하다.

### 3.3 128-way Adder Tree가 물리 구현 병목이 될 가능성이 큼

계획서는 VE 내부에서 128개 MAC 출력을 7-stage FP32 adder tree로 reduce한다. 논리적으로는 맞지만, FPGA 구현에서는 이 부분이 가장 위험하다.

이유는 다음과 같다.

- 128개 출력이 한 reduction 구조로 집중되면 fan-in과 배선 혼잡이 급격히 증가한다.
- FP32 adder tree는 LUT 수보다도 routing delay가 더 빨리 병목이 된다.
- 상위 계층인 TE/CE에서도 다시 vector reduction을 수행하므로 병목이 누적된다.

AMD UG579도 fabric adder tree의 최종 post-addition 단계가 성능 병목이 되기 쉽고, adder tree 깊이가 `log2(taps)`로 증가하며 비용, 로직, 전력까지 커진다고 설명한다. 같은 문서는 cascade path를 활용한 가산 구조가 속도와 전력 측면에서 유리하다고 안내한다.

개선안:

- 128-way flat tree 대신 `clustered reduction`으로 바꾸는 것이 좋다.
- 예시:
  - 8개 또는 16개 MAC 단위 local reduction
  - local partial sum을 상위 tree로 연결
  - floorplan 상에서 cluster 단위로 배치
- FP32 full adder를 전부 fabric에 두지 말고, 가능한 구간은 DSP cascade 사용 가능성도 병행 검토해야 한다.
- 128 MAC/VE는 기능 목표로 유지하되, 첫 실험은 32 MAC 또는 64 MAC VE 쉘에서 timing/resource를 먼저 확인하는 편이 안전하다.

### 3.4 메모리 구조는 정의되어 있으나 대역폭 예산과 데이터플로우가 정량화되지 않음

계획서에는 URAM 기반 Weight File, input vector buffer, double-buffering이 언급되어 있다. 그러나 실제 구현에서 중요한 것은 "저장 위치"보다 "사이클당 공급량"이다.

현재 부족한 점:

- VE 1개가 cycle당 몇 개의 weight와 input을 소비하는지 정량식이 없음
- URAM read latency와 pipeline 정렬 규칙이 정의되지 않음
- double-buffering이 필수인지 옵션인지 판단 기준이 없음
- TE/CE에서 input broadcast와 partial sum merge가 on-chip memory traffic에 어떤 부담을 주는지 분석이 없음

특히 URAM은 optional output register(OREG) 같은 파이프라인 요소를 갖기 때문에, 기능 모델과 실제 읽기 레이턴시 모델을 일치시켜야 한다.

개선안:

- 구현 전에 최소 1개의 `Bandwidth & Dataflow Budget` 문서를 작성해야 한다.
- 포함 항목:
  - precision별 cycle당 weight/input 소비량
  - URAM bank 수와 포트 사용 계획
  - single buffer / double buffer 전환 기준
  - VE/TE/CE 확장 시 on-chip traffic 증가량
- 동시에 dataflow를 명확히 선언해야 한다.
  - output-stationary
  - weight-stationary
  - input-stationary
- 현재 문서는 구조상 weight-stationary에 가까워 보이지만, partial sum 이동 비용까지 포함한 정식 선언이 필요하다.

### 3.5 KCU116 실증 범위와 최종 아키텍처 목표 범위를 분리해야 함

계획서도 일부 인정하고 있지만, M4와 M5의 서술은 여전히 "CE까지 실증 가능"처럼 읽힐 여지가 있다.

공식 문서 기준으로 KU5P는 총 1,824 DSP48E2를 제공하고, 한 column 내 최대 cascade 길이도 제한된다. 계획서의 가정처럼 FP16에서 1 DSP/MAC를 잡으면:

- VE 1개 = 128 DSP
- TE 1개 = 512 DSP
- CE 1개 = 2,048 DSP

즉 KU5P 단일 보드에서 full CE는 FP16 기준으로 물리적으로 수용되지 않는다. 따라서 CE는 RTL/시뮬레이션 목표와 보드 실증 목표를 분리해야 한다.

개선안:

- 문서 상 목표를 아래처럼 둘로 나눠야 한다.
  - 아키텍처 목표: VE → TE → CE 기능 정의 및 RTL 확장 가능성 확보
  - 실증 목표: KU5P 보드에서 1 TE 또는 축소형 다중 VE 실증
- M4 성공 기준도 다음처럼 수정하는 것이 타당하다.
  - TE: 보드 실증 가능
  - CE: RTL 시뮬레이션 및 합성 가능성 확인, 보드 실증은 축소형으로 제한

### 3.6 검증 전략이 맞는 방향이지만 "속도"와 "계약 검증"이 빠져 있음

계획서는 UVM, Python 골든 모델, DPI-C, ILA, CI/CD를 언급한다. 그러나 실제로 일정이 밀리는 지점은 복잡한 계층 검증에서 시뮬레이션 속도가 급감하는 순간이다.

부족한 점:

- 어떤 레벨의 테스트를 어떤 엔진으로 돌릴지 계층화가 없음
- coverage 목표와 assertion 전략이 구체화되지 않음
- post-synthesis / implementation 전환 시 regression subset이 없음

개선안:

- 검증 스택을 역할별로 분리해야 한다.
  - Python/Numpy: 산술 정답 생성
  - cocotb: 랜덤/시나리오 구동과 빠른 연동
  - SystemVerilog TB/UVM: 프로토콜 및 장기 회귀
  - Verilator: 대규모 cycle test와 lint
  - FPGA ILA: 시스템 통합 디버그
- 즉 "모든 것을 UVM로"가 아니라 "산술은 Python에 붙이고, 프로토콜은 SV로, 대량 회귀는 Verilator로" 나누는 편이 현실적이다.

### 3.7 일정이 기능 난이도보다 낙관적임

특히 아래 항목은 일정 리스크가 크다.

- FP16 bit-accurate MAC
- FP8/FP4 packing 검증
- 128 MAC reduction timing closure
- URAM mapping/floorplan
- WP2/WP4 의존 통합

원 계획의 M1~M4 12주 구조는 "RTL 작성 시간" 중심으로 보이며, 실제 물리 구현과 실패 반복 횟수가 반영되어 있지 않다.

개선안:

- 각 마일스톤 안에 `파일럿 합성`과 `탈락 기준(exit criteria)`을 포함해야 한다.
- 예를 들어 M2 진입 전에 "FP8 packing이 독립 MAC 정확도를 만족하지 못하면 FP4를 후순위로 미룸" 같은 의사결정 규칙이 필요하다.

## 4. 개선 연구 방향

### 4.1 Arithmetic Contract 우선 작성

WP1 착수 직후 첫 산출물은 RTL이 아니라 산술 계약 문서여야 한다.

필수 정의:

- FP16/FP8/FP4 포맷
- rounding mode
- saturation/overflow policy
- denormal/subnormal policy
- NaN/Inf propagation
- signed zero rule
- mode transition 시 flush rule

이 문서가 먼저 닫혀야 Python 골든 모델, RTL, 테스트벤치가 동시에 흔들리지 않는다.

### 4.2 FP8/FP4는 "기능 구현"보다 "증명 가능한 packing" 중심으로 재정의

연구 항목:

- guard bit 최소 폭 탐색
- signed/unsigned partial product 분리 방법
- cross-term 제거 조건
- post-normalization LUT 비용
- packed mode의 실제 DSP 절감률 대 LUT/FF 증가율

권장 정책:

- FP16: 제품 기능
- FP8 E4M3: 1차 확장 기능
- FP8 E5M2: 인터페이스 확장 준비
- FP4 E2M1: 연구 기능

### 4.3 VE는 128 MAC 직행보다 축소 VE로 합성 검증 후 확장

권장 순서:

1. 32 MAC VE shell
2. 64 MAC VE
3. 128 MAC VE

각 단계마다 확인할 것:

- Fmax
- LUT/FF/DSP/URAM 사용량
- routing congestion
- local reduction 구조의 타당성

이렇게 해야 128 MAC가 논리적으로만 가능한 구조인지, 실제 배치 가능한 구조인지 빨리 판별할 수 있다.

### 4.4 Reduction 구조는 flat tree보다 locality 중심으로 재설계

권장 대안:

- 8~16 MAC cluster별 partial sum 생성
- cluster 간 상위 reduction
- DSP cascade 활용 가능 구간과 fabric adder 구간 분리
- pipeline register 삽입 위치를 floorplan 기준으로 먼저 정함

즉, RTL 계층과 물리 배치 계층을 분리하지 말고 동시에 설계해야 한다.

### 4.5 메모리 구조는 "용량"보다 "공급 스케줄" 기준으로 재정리

필수 연구 항목:

- weight preload 방식과 streaming 방식 비교
- input vector broadcast 스케줄
- partial sum 저장 위치
- URAM read/write latency 정렬
- bank conflict 가능성
- double-buffering 도입이 실제 성능 향상으로 이어지는 조건

### 4.6 TE/CE 목표를 시뮬레이션 확장성과 보드 실증성으로 분리

권장 목표 정의:

- TE: KU5P 보드 실증 대상
- CE: 상위 구조 검증 및 확장성 검증 대상
- full CE on-board는 차기 보드나 상위 디바이스로 이월 가능성 명시

이렇게 분리하면 문서가 더 정직해지고, 성공 기준도 현실적으로 설정된다.

## 5. 권장 수정 로드맵

아래는 현재 계획서를 더 실행 가능하게 바꾼 권장 순서다.

| 단계 | 기간 제안 | 목표 | 산출물 |
|------|-----------|------|--------|
| R0 | 1~2주 | 산술 계약, bit-accurate 모델, resource/bandwidth 예산 수립 | `arithmetic_contract.md`, Python 모델, sizing sheet |
| R1 | 2주 | FP16 MAC 단일 유닛 + pilot synthesis | `fp16_mac.sv`, `tb_fp16_mac`, 합성 리포트 |
| R2 | 2주 | FP8 E4M3 packing proof + mode switch 검증 | `multi_prec_mac.sv` 일부, packing 분석 리포트 |
| R3 | 2~3주 | 축소형 VE(32/64 MAC) 구현 및 timing 확인 | `ve_top_small.sv`, floorplan 실험 결과 |
| R4 | 2주 | 128 MAC VE 확장 + clustered reduction 안정화 | `ve_top.sv`, congestion/timing 리포트 |
| R5 | 2주 | TE 구현, CE는 RTL 수준 확장 | `te_top.sv`, `ce_top.sv` 초안 |
| R6 | 4주 | KCU116 통합 실증 | bitstream, ILA capture, benchmark |

핵심은 "FP4 포함 full feature"보다 "FP16/FP8 + VE/TE 실증 성공"을 먼저 닫는 것이다.

## 6. 즉시 실행 권장 항목

우선순위 기준으로 바로 시작할 작업은 아래 6개다.

1. `Arithmetic Contract` 문서 작성
2. FP8 E4M3 packing에 대한 Python bit-accurate proof-of-concept 작성
3. 32 MAC 또는 64 MAC VE dummy shell로 200 MHz pilot synthesis 수행
4. URAM bank/latency를 포함한 bandwidth budget 표 작성
5. TE on-board / CE simulation-only 목표를 문서에 명시
6. cocotb + Verilator 기반의 빠른 regression 경로 준비

## 7. 문서 수정 권장 문구

원 계획서 본문도 아래처럼 수정하면 오해를 줄일 수 있다.

- `CE(16 VE) 구현`  
  → `CE는 RTL/시뮬레이션 기준으로 구현하고, KU5P 보드 실증은 TE 또는 축소형 CE로 제한`

- `FP4 4~6 MAC/DSP`  
  → `FP4는 feasibility study 후 채택 여부 결정`

- `VE 128 MAC`  
  → `VE는 32/64 MAC pilot 검증 후 128 MAC로 확장`

- `200 MHz 타이밍 클로저`  
  → `pilot synthesis 기준 200 MHz feasibility 확인 후 full design closure 진행`

## 8. 참고 자료

다음 자료를 기준으로 개선 방향을 정리했다.

- AMD UG579, UltraScale Architecture DSP48E2 Slice  
  - DSP48E2는 27x18 multiplier와 48-bit accumulator/cascade 구조를 제공
  - fabric adder tree는 성능 병목이 되기 쉬우며, cascade 활용이 속도/전력 측면에서 유리
  - KU5P는 총 1,824 DSP48E2, 최대 cascade 길이는 96
- AMD UG573, UltraScale Architecture Memory Resources  
  - UltraRAM은 optional output register(OREG) 등 파이프라인 구성이 가능하므로 RTL latency model과 실제 메모리 latency를 맞춰야 함
- OCP Microscaling Formats (MX) Specification  
  - MXFP8은 E4M3와 E5M2를 모두 포함
  - MXFP4(E2M1), shared scale 개념이 존재하므로 향후 확장 인터페이스 설계에 참고 가능
- Verilator User Guide
- cocotb Quickstart Guide

참고 링크:

- https://docs.amd.com/api/khub/documents/pTysoma4TYgNH95BrY1Sbw/content
- https://www.amd.com/content/dam/xilinx/support/documents/user_guides/ug573-ultrascale-memory-resources.pdf
- https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf
- https://verilator.org/guide/latest/overview.html
- https://docs.cocotb.org/en/development/quickstart.html

## 9. 최종 판단

WP1 계획서는 기술 방향은 옳지만, 현재 형태로는 "RTL 구현 계획서"라기보다 "기능 목표 목록"에 더 가깝다. 실제 성공 확률을 높이려면 다음으로 재정렬해야 한다.

- 기능 우선에서 증명 우선으로
- full-scale 목표에서 board-fit 목표로
- 구조 설명에서 산술 계약과 물리 구현 제약 중심으로

가장 현실적인 성공 경로는 다음 한 줄로 요약된다.

`FP16 안정화 -> FP8 packing 증명 -> 축소 VE 합성 검증 -> 128 MAC 확장 -> TE 보드 실증 -> CE는 시뮬레이션 우선`
