// =============================================================================
// FP16 Unpacker
// Arithmetic Contract v1.0: FTZ (subnormal → zero), NaN detection
// =============================================================================

module fp16_unpack
    import s80_pkg::*;
(
    input  logic [15:0] fp16_in,

    output logic        sign,
    output logic [4:0]  exponent,
    output logic [10:0] mantissa,     // implicit 1 포함 (11-bit)
    output logic        is_zero,
    output logic        is_nan,
    output logic        is_inf,
    output logic        is_subnorm
);

    logic [4:0]  raw_exp;
    logic [9:0]  raw_mant;

    assign sign     = fp16_in[15];
    assign raw_exp  = fp16_in[14:10];
    assign raw_mant = fp16_in[9:0];

    always_comb begin
        // Defaults
        exponent   = raw_exp;
        mantissa   = 11'b0;
        is_zero    = 1'b0;
        is_nan     = 1'b0;
        is_inf     = 1'b0;
        is_subnorm = 1'b0;

        if (raw_exp == 5'b0) begin
            // Zero or subnormal
            if (raw_mant == 10'b0) begin
                // Zero
                is_zero = 1'b1;
            end else begin
                // Subnormal → FTZ: treat as zero
                is_subnorm = 1'b1;
                is_zero    = 1'b1;  // FTZ forces zero
            end
            exponent = 5'b0;
            mantissa = 11'b0;
        end else if (raw_exp == 5'h1F) begin
            // Inf or NaN
            if (raw_mant == 10'b0) begin
                is_inf = 1'b1;
            end else begin
                is_nan = 1'b1;
            end
            exponent = raw_exp;
            mantissa = {1'b0, raw_mant};
        end else begin
            // Normal: prepend implicit 1
            exponent = raw_exp;
            mantissa = {1'b1, raw_mant};
        end
    end

    // =========================================================================
    // SVA Assertions
    // =========================================================================

    // Subnormal 입력은 항상 zero로 처리
    // synthesis translate_off
    assert property (@(posedge is_subnorm) is_zero)
    else $error("FTZ violation: subnormal not flushed to zero");

    // Zero일 때 mantissa는 0
    assert property (@(posedge is_zero) mantissa == 11'b0)
    else $error("Zero with non-zero mantissa");

    // Normal일 때 mantissa MSB는 1
    assert property (@(posedge (!is_zero && !is_nan && !is_inf)) mantissa[10] == 1'b1)
    else $error("Normal number missing implicit 1");
    // synthesis translate_on

endmodule
