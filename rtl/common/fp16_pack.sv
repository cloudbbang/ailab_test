// =============================================================================
// FP16 Packer (FP32 → FP16 conversion)
// Arithmetic Contract v1.0: RNE rounding, Saturate-to-max
// =============================================================================

module fp16_pack
    import s80_pkg::*;
(
    input  logic        sign,
    input  logic [7:0]  fp32_exp,
    input  logic [22:0] fp32_mant,    // FP32 mantissa (implicit 1 제외)
    input  logic        is_nan,
    input  logic        is_zero,

    output logic [15:0] fp16_out
);

    logic [4:0]  fp16_exp;
    logic [9:0]  fp16_mant;
    logic        guard, round_bit, sticky;
    logic        round_up;
    logic signed [8:0] exp_rebias;  // signed for underflow check

    always_comb begin
        fp16_out = FP16_POS_ZERO;

        if (is_nan) begin
            fp16_out = FP16_QNAN;
        end else if (is_zero) begin
            fp16_out = {sign, 15'b0};
        end else begin
            // Rebias exponent: FP32 bias=127 → FP16 bias=15
            exp_rebias = 9'(signed'({1'b0, fp32_exp})) - 9'sd127 + 9'sd15;

            if (exp_rebias >= 9'sd31) begin
                // Overflow → Saturate to max
                fp16_out = sign ? FP16_NEG_MAX : FP16_POS_MAX;
            end else if (exp_rebias <= 9'sd0) begin
                // Underflow → FTZ
                fp16_out = {sign, 15'b0};
            end else begin
                fp16_exp = exp_rebias[4:0];

                // Mantissa: 23-bit → 10-bit with RNE
                fp16_mant  = fp32_mant[22:13];
                guard      = fp32_mant[12];
                round_bit  = fp32_mant[11];
                sticky     = |fp32_mant[10:0];

                // RNE rounding
                round_up = guard & (round_bit | sticky | fp16_mant[0]);

                if (round_up) begin
                    {fp16_exp, fp16_mant} = {fp16_exp, fp16_mant} + 15'b1;
                    // Mantissa overflow → exponent increment already handled
                    if (fp16_exp >= 5'd31) begin
                        fp16_out = sign ? FP16_NEG_MAX : FP16_POS_MAX;
                    end else begin
                        fp16_out = {sign, fp16_exp, fp16_mant};
                    end
                end else begin
                    fp16_out = {sign, fp16_exp, fp16_mant};
                end
            end
        end
    end

endmodule
