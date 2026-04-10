// =============================================================================
// FP32 Normalizer + RNE Rounder
// 누산 완료 후 FP32 결과를 최종 정규화 및 반올림
// Arithmetic Contract v1.0: RNE, Saturate-to-max
//
// Latency: 1 cycle
// =============================================================================

module fp32_normalizer
    import s80_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        valid_in,
    input  logic        sign_in,
    input  logic [8:0]  exp_in,       // 9-bit for overflow detection
    input  logic [24:0] mant_in,      // 25-bit (1 guard + 24-bit with implicit 1)
    input  logic        is_nan_in,
    input  logic        is_zero_in,

    output logic [31:0] fp32_out,
    output logic        valid_out
);

    // =========================================================================
    // Leading Zero Detector (priority encoder)
    // =========================================================================

    logic [4:0]  lzc;         // leading zero count
    logic [24:0] shifted_mant;
    logic [8:0]  adjusted_exp;
    logic        guard, round_bit, sticky;
    logic        round_up;
    logic [22:0] rounded_mant;
    logic [8:0]  final_exp;

    // LZD for 25-bit mantissa
    always_comb begin
        lzc = 5'd0;
        if (mant_in[24])      lzc = 5'd0;   // already has carry bit
        else if (mant_in[23]) lzc = 5'd0;   // normal position
        else if (mant_in[22]) lzc = 5'd1;
        else if (mant_in[21]) lzc = 5'd2;
        else if (mant_in[20]) lzc = 5'd3;
        else if (mant_in[19]) lzc = 5'd4;
        else if (mant_in[18]) lzc = 5'd5;
        else if (mant_in[17]) lzc = 5'd6;
        else if (mant_in[16]) lzc = 5'd7;
        else if (mant_in[15]) lzc = 5'd8;
        else if (mant_in[14]) lzc = 5'd9;
        else if (mant_in[13]) lzc = 5'd10;
        else if (mant_in[12]) lzc = 5'd11;
        else if (mant_in[11]) lzc = 5'd12;
        else if (mant_in[10]) lzc = 5'd13;
        else if (mant_in[9])  lzc = 5'd14;
        else if (mant_in[8])  lzc = 5'd15;
        else if (mant_in[7])  lzc = 5'd16;
        else if (mant_in[6])  lzc = 5'd17;
        else if (mant_in[5])  lzc = 5'd18;
        else if (mant_in[4])  lzc = 5'd19;
        else if (mant_in[3])  lzc = 5'd20;
        else if (mant_in[2])  lzc = 5'd21;
        else if (mant_in[1])  lzc = 5'd22;
        else if (mant_in[0])  lzc = 5'd23;
        else                  lzc = 5'd24;  // all zeros
    end

    // =========================================================================
    // Normalization + RNE Rounding (combinational, registered output)
    // =========================================================================

    logic [31:0] result_comb;

    always_comb begin
        result_comb = FP32_POS_ZERO;

        if (is_nan_in) begin
            result_comb = FP32_QNAN;
        end else if (is_zero_in || mant_in == 25'b0) begin
            result_comb = {sign_in, 31'b0};
        end else if (mant_in[24]) begin
            // Carry bit set: shift right by 1
            adjusted_exp = exp_in + 9'd1;
            shifted_mant = mant_in >> 1;

            // RNE on lost bit
            guard     = mant_in[1];
            round_bit = mant_in[0];
            sticky    = 1'b0;
            round_up  = guard & (round_bit | sticky | shifted_mant[0]);

            rounded_mant = shifted_mant[22:0];
            if (round_up) begin
                rounded_mant = shifted_mant[22:0] + 23'd1;
                if (rounded_mant == 23'd0)  // mantissa overflow
                    adjusted_exp = adjusted_exp + 9'd1;
            end

            // Saturate check
            if (adjusted_exp >= 9'h0FF)
                result_comb = sign_in ? FP32_NEG_MAX : FP32_POS_MAX;
            else
                result_comb = {sign_in, adjusted_exp[7:0], rounded_mant};
        end else begin
            // Normalize: shift left by lzc
            if (exp_in > 9'(lzc)) begin
                adjusted_exp = exp_in - 9'(lzc);
                shifted_mant = mant_in << lzc;
                // implicit 1 is now at bit 23
                result_comb = {sign_in, adjusted_exp[7:0], shifted_mant[22:0]};
            end else begin
                // Underflow → FTZ
                result_comb = {sign_in, 31'b0};
            end
        end
    end

    // =========================================================================
    // Output register (1-cycle latency)
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp32_out  <= 32'b0;
            valid_out <= 1'b0;
        end else begin
            fp32_out  <= result_comb;
            valid_out <= valid_in;
        end
    end

    // =========================================================================
    // SVA Assertions
    // =========================================================================

    // synthesis translate_off
    assert property (@(posedge clk) disable iff (!rst_n)
        valid_out |-> (fp32_out[30:23] != 8'hFF) || (fp32_out == FP32_QNAN))
    else $error("Non-NaN infinity generated (should saturate)");
    // synthesis translate_on

endmodule
