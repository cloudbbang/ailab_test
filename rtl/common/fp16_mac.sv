// =============================================================================
// FP16 MAC (Multiply-Accumulate) Unit
// Top-level: FP16 × FP16 → FP32 누산
//
// Pipeline:
//   Cycle 0:   Unpack A, B (combinational)
//   Cycle 1-3: DSP48E2 mantissa multiply (3-stage)
//              + exponent add (parallel, registered)
//   Cycle 4:   FP32 accumulation (alignment + add)
//   Cycle 5:   (last only) Normalize → result output
//
// Arithmetic Contract v1.0:
//   - RNE rounding, Saturate-to-max, FTZ, NaN propagation
// =============================================================================

module fp16_mac
    import s80_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        clear,          // 누산기 리셋 (새 벡터 시작)
    input  logic        valid_in,       // 입력 유효
    input  logic [15:0] fp16_a,         // FP16 입력 A (weight)
    input  logic [15:0] fp16_b,         // FP16 입력 B (activation)
    input  logic        last,           // 마지막 입력 (결과 출력 트리거)

    // Output
    output logic [31:0] fp32_result,    // FP32 누산 결과
    output logic        result_valid    // 결과 유효
);

    // =========================================================================
    // Stage 0: Unpack (combinational)
    // =========================================================================

    logic        a_sign, b_sign;
    logic [4:0]  a_exp,  b_exp;
    logic [10:0] a_mant, b_mant;
    logic        a_zero, b_zero;
    logic        a_nan,  b_nan;
    logic        a_inf,  b_inf;
    logic        a_sub,  b_sub;

    fp16_unpack u_unpack_a (
        .fp16_in   (fp16_a),
        .sign      (a_sign),
        .exponent  (a_exp),
        .mantissa  (a_mant),
        .is_zero   (a_zero),
        .is_nan    (a_nan),
        .is_inf    (a_inf),
        .is_subnorm(a_sub)
    );

    fp16_unpack u_unpack_b (
        .fp16_in   (fp16_b),
        .sign      (b_sign),
        .exponent  (b_exp),
        .mantissa  (b_mant),
        .is_zero   (b_zero),
        .is_nan    (b_nan),
        .is_inf    (b_inf),
        .is_subnorm(b_sub)
    );

    // =========================================================================
    // Stage 1-3: DSP48E2 Mantissa Multiply (3-cycle)
    // =========================================================================

    logic [21:0] product_mant;
    logic        mul_valid;

    dsp48_mul_wrapper u_mul (
        .clk       (clk),
        .rst_n     (rst_n),
        .mant_a    (a_mant),
        .mant_b    (b_mant),
        .valid_in  (valid_in),
        .product   (product_mant),
        .valid_out (mul_valid)
    );

    // =========================================================================
    // Exponent + sign path (parallel with DSP, 3-stage pipeline to match)
    // =========================================================================

    // Stage 1 registers
    logic        sign_s1;
    logic [9:0]  exp_sum_s1;
    logic        is_zero_s1;
    logic        is_nan_s1;
    logic        last_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sign_s1    <= 1'b0;
            exp_sum_s1 <= 10'b0;
            is_zero_s1 <= 1'b0;
            is_nan_s1  <= 1'b0;
            last_s1    <= 1'b0;
        end else begin
            sign_s1    <= a_sign ^ b_sign;
            exp_sum_s1 <= {1'b0, a_exp} + {1'b0, b_exp} - 10'(FP16_BIAS);
            is_zero_s1 <= a_zero | b_zero;
            is_nan_s1  <= a_nan | b_nan;
            last_s1    <= last;
        end
    end

    // Stage 2 registers
    logic        sign_s2;
    logic [9:0]  exp_sum_s2;
    logic        is_zero_s2;
    logic        is_nan_s2;
    logic        last_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sign_s2    <= 1'b0;
            exp_sum_s2 <= 10'b0;
            is_zero_s2 <= 1'b0;
            is_nan_s2  <= 1'b0;
            last_s2    <= 1'b0;
        end else begin
            sign_s2    <= sign_s1;
            exp_sum_s2 <= exp_sum_s1;
            is_zero_s2 <= is_zero_s1;
            is_nan_s2  <= is_nan_s1;
            last_s2    <= last_s1;
        end
    end

    // Stage 3 registers
    logic        sign_s3;
    logic [9:0]  exp_sum_s3;
    logic        is_zero_s3;
    logic        is_nan_s3;
    logic        last_s3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sign_s3    <= 1'b0;
            exp_sum_s3 <= 10'b0;
            is_zero_s3 <= 1'b0;
            is_nan_s3  <= 1'b0;
            last_s3    <= 1'b0;
        end else begin
            sign_s3    <= sign_s2;
            exp_sum_s3 <= exp_sum_s2;
            is_zero_s3 <= is_zero_s2;
            is_nan_s3  <= is_nan_s2;
            last_s3    <= last_s2;
        end
    end

    // =========================================================================
    // Stage 4: FP32 Accumulator
    // =========================================================================

    logic [31:0] acc_out;
    logic        acc_valid;
    logic        acc_nan;

    fp32_accumulator u_acc (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (clear),
        .valid_in     (mul_valid),
        .prod_sign    (sign_s3),
        .prod_exp     (exp_sum_s3),
        .prod_mant    (product_mant),
        .prod_is_zero (is_zero_s3),
        .prod_is_nan  (is_nan_s3),
        .acc_result   (acc_out),
        .acc_valid    (acc_valid),
        .acc_is_nan   (acc_nan)
    );

    // =========================================================================
    // Stage 5: Normalize (triggered on 'last')
    // =========================================================================

    // last 신호 pipeline: accumulator 처리 후 1 cycle 뒤에 normalize 트리거
    logic last_s4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            last_s4 <= 1'b0;
        else
            last_s4 <= last_s3 & mul_valid;
    end

    // Accumulator 내부 상태에서 직접 normalizer로 전달
    logic        norm_valid_in;
    logic        norm_sign;
    logic [8:0]  norm_exp;
    logic [24:0] norm_mant;
    logic        norm_is_nan;
    logic        norm_is_zero;

    assign norm_valid_in = last_s4;
    assign norm_sign     = acc_out[31];
    assign norm_exp      = {1'b0, acc_out[30:23]};
    assign norm_mant     = {1'b0, 1'b1, acc_out[22:0]};  // restore implicit 1
    assign norm_is_nan   = acc_nan;
    assign norm_is_zero  = (acc_out[30:0] == 31'b0);

    fp32_normalizer u_norm (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (norm_valid_in),
        .sign_in    (norm_sign),
        .exp_in     (norm_exp),
        .mant_in    (norm_mant),
        .is_nan_in  (norm_is_nan),
        .is_zero_in (norm_is_zero),
        .fp32_out   (fp32_result),
        .valid_out  (result_valid)
    );

    // =========================================================================
    // SVA Assertions
    // =========================================================================

    // synthesis translate_off
    // clear와 valid_in 동시 발생 불가
    assert property (@(posedge clk) disable iff (!rst_n)
        !(clear && valid_in))
    else $error("clear and valid_in must not be simultaneous");

    // result_valid 후 fp32_result 안정 (1 cycle)
    assert property (@(posedge clk) disable iff (!rst_n)
        result_valid |=> $stable(fp32_result) || result_valid)
    else $warning("fp32_result changed after result_valid without new result");

    // NaN 입력 시 결과에 NaN 전파
    assert property (@(posedge clk) disable iff (!rst_n)
        (valid_in && (a_nan || b_nan)) |-> ##[4:6] (acc_nan))
    else $error("NaN not propagated to accumulator");
    // synthesis translate_on

endmodule
