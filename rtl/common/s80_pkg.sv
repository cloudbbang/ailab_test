// =============================================================================
// S80 NPU Global Package
// Arithmetic Contract v1.0
// =============================================================================

package s80_pkg;

    // =========================================================================
    // FP16 (IEEE 754 Half-Precision)
    // =========================================================================
    parameter int FP16_WIDTH     = 16;
    parameter int FP16_EXP_WIDTH = 5;
    parameter int FP16_MAN_WIDTH = 10;
    parameter int FP16_BIAS      = 15;
    parameter int FP16_EXP_MAX   = 31;    // reserved for Inf/NaN
    parameter int FP16_MAN_FULL  = 11;    // implicit 1 포함

    // FP16 special bit patterns
    parameter logic [15:0] FP16_POS_ZERO = 16'h0000;
    parameter logic [15:0] FP16_NEG_ZERO = 16'h8000;
    parameter logic [15:0] FP16_QNAN     = 16'h7E00;  // canonical quiet NaN
    parameter logic [15:0] FP16_POS_MAX  = 16'h7BFF;  // 65504
    parameter logic [15:0] FP16_NEG_MAX  = 16'hFBFF;  // -65504
    parameter logic [15:0] FP16_POS_INF  = 16'h7C00;  // (입력 감지용)

    // =========================================================================
    // FP32 (IEEE 754 Single-Precision)
    // =========================================================================
    parameter int FP32_WIDTH     = 32;
    parameter int FP32_EXP_WIDTH = 8;
    parameter int FP32_MAN_WIDTH = 23;
    parameter int FP32_BIAS      = 127;

    parameter logic [31:0] FP32_POS_ZERO = 32'h00000000;
    parameter logic [31:0] FP32_QNAN     = 32'h7FC00000;
    parameter logic [31:0] FP32_POS_MAX  = 32'h7F7FFFFF;
    parameter logic [31:0] FP32_NEG_MAX  = 32'hFF7FFFFF;

    // =========================================================================
    // FP8 constants (M2 확장용 예비)
    // =========================================================================
    parameter int FP8_E4M3_EXP   = 4;
    parameter int FP8_E4M3_MAN   = 3;
    parameter int FP8_E5M2_EXP   = 5;
    parameter int FP8_E5M2_MAN   = 2;

    // =========================================================================
    // MAC / VE pipeline parameters
    // =========================================================================
    parameter int MAC_DSP_LATENCY = 3;    // DSP48E2 내부 파이프라인 (AREG+BREG+MREG)
    parameter int MAC_ACC_LATENCY = 1;    // 정렬 + 가산
    parameter int MAC_TOTAL_LATENCY = MAC_DSP_LATENCY + MAC_ACC_LATENCY + 1;  // +1 for normalize

    // VE parameters (M3 이후 사용)
    parameter int VE_MAC_COUNT   = 128;
    parameter int VE_WF_ROWS     = 128;
    parameter int VE_WF_COLS     = 128;
    parameter int VE_PIPELINE    = 14;    // URAM OREG 반영
    parameter int VE_CLUSTER_SZ  = 8;     // Adder cluster 크기

    // Hierarchy parameters (M4 이후 사용)
    parameter int TE_VE_COUNT    = 4;
    parameter int CE_TE_COUNT    = 4;
    parameter int CM_CE_COUNT    = 4;

    // =========================================================================
    // Precision mode (M2 확장용 예비)
    // =========================================================================
    typedef enum logic [1:0] {
        PREC_FP16    = 2'b00,
        PREC_FP8_E4  = 2'b01,
        PREC_FP8_E5  = 2'b10,
        PREC_FP4     = 2'b11   // 연구 예비
    } precision_mode_t;

endpackage
