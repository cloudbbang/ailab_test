// =============================================================================
// FP32 Accumulator
// FP16 곱셈 결과(22-bit product)를 FP32로 변환 후 누산
// Arithmetic Contract v1.0: Saturate-to-max, NaN propagation, FTZ
//
// Latency: 1 cycle (alignment + add + re-normalize)
// =============================================================================

module fp32_accumulator
    import s80_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        clear,          // 누산기 리셋 (새 벡터 시작)

    // Product input (from DSP multiplier + exponent path)
    input  logic        valid_in,
    input  logic        prod_sign,
    input  logic [9:0]  prod_exp,       // exp_a + exp_b - bias (biased FP16 domain)
    input  logic [21:0] prod_mant,      // 22-bit mantissa product
    input  logic        prod_is_zero,   // skip accumulation
    input  logic        prod_is_nan,    // NaN propagation

    // Accumulated result
    output logic [31:0] acc_result,     // FP32 bit pattern
    output logic        acc_valid,      // result ready
    output logic        acc_is_nan      // NaN flag
);

    // =========================================================================
    // Internal accumulator state
    // =========================================================================

    logic        acc_sign;
    logic [8:0]  acc_exp;       // 9-bit to detect overflow
    logic [24:0] acc_mant;      // 25-bit (1 guard + 24-bit with implicit 1)
    logic        acc_zero;
    logic        nan_flag;

    // =========================================================================
    // Product → FP32 conversion
    // =========================================================================

    logic [4:0]  prod_msb;      // MSB position of product mantissa
    logic [23:0] prod_fp32_mant; // 24-bit (implicit 1 at bit 23)
    logic [8:0]  prod_fp32_exp;  // FP32 biased exponent

    // Leading bit detector for 22-bit product
    // 11×11: MSB is at position 20 or 21
    always_comb begin
        prod_msb = 5'd0;
        for (int i = 21; i >= 0; i--) begin
            if (prod_mant[i] && prod_msb == 5'd0)
                prod_msb = 5'(i);
        end
    end

    always_comb begin
        // Shift mantissa so implicit 1 is at bit 23
        if (prod_msb <= 5'd23)
            prod_fp32_mant = 24'(prod_mant) << (5'd23 - prod_msb);
        else
            prod_fp32_mant = 24'(prod_mant >> (prod_msb - 5'd23));

        // Convert exponent: FP16 domain → FP32 domain
        // Value = 2^(prod_exp - FP16_BIAS) × (prod_mant / 2^(2*FP16_MAN_WIDTH))
        // FP32: 2^(fp32_exp - FP32_BIAS) × (fp32_mant / 2^23)
        // fp32_exp = prod_exp + (msb_pos - 2*10) + (127 - 15)
        prod_fp32_exp = 9'(prod_exp) + 9'(prod_msb) - 9'd20 + 9'd112;
    end

    // =========================================================================
    // Accumulation logic
    // =========================================================================

    logic [8:0]  result_exp;
    logic [25:0] result_mant_wide;  // extra bit for carry
    logic        result_sign;
    logic signed [9:0] exp_diff;

    // Aligned mantissas for addition
    logic [24:0] aligned_a;
    logic [24:0] aligned_b;

    // Re-normalization
    logic [4:0]  norm_shift;
    logic [24:0] norm_mant;
    logic [8:0]  norm_exp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_sign   <= 1'b0;
            acc_exp    <= 9'b0;
            acc_mant   <= 25'b0;
            acc_zero   <= 1'b1;
            nan_flag   <= 1'b0;
            acc_valid  <= 1'b0;
        end else if (clear) begin
            acc_sign   <= 1'b0;
            acc_exp    <= 9'b0;
            acc_mant   <= 25'b0;
            acc_zero   <= 1'b1;
            nan_flag   <= 1'b0;
            acc_valid  <= 1'b0;
        end else if (valid_in) begin
            acc_valid <= 1'b1;

            if (prod_is_nan || nan_flag) begin
                // NaN propagation
                nan_flag   <= 1'b1;
                acc_sign   <= 1'b0;
                acc_exp    <= 9'h0FF;
                acc_mant   <= 25'h1000000;  // quiet NaN pattern
                acc_zero   <= 1'b0;
            end else if (prod_is_zero) begin
                // Product is zero → accumulator unchanged
            end else if (acc_zero) begin
                // First non-zero product → initialize accumulator
                acc_sign <= prod_sign;
                acc_exp  <= prod_fp32_exp;
                acc_mant <= {1'b0, prod_fp32_mant};
                acc_zero <= 1'b0;
                // synthesis translate_off
                $display("[ACC_INIT @%0t] prod_mant=0x%06H msb=%0d fp32_mant=0x%06H fp32_exp=%0d → acc_mant=0x%07H",
                         $time, prod_mant, prod_msb, prod_fp32_mant, prod_fp32_exp,
                         {1'b0, prod_fp32_mant});
                // synthesis translate_on
            end else begin
                // Normal accumulation
                exp_diff = 10'(signed'(prod_fp32_exp)) - 10'(signed'(acc_exp));

                if (exp_diff > 10'sd24) begin
                    // Accumulator negligible compared to product
                    acc_sign <= prod_sign;
                    acc_exp  <= prod_fp32_exp;
                    acc_mant <= {1'b0, prod_fp32_mant};
                end else if (exp_diff < -10'sd24) begin
                    // Product negligible → keep accumulator
                end else begin
                    // Alignment
                    if (exp_diff >= 0) begin
                        aligned_a = {1'b0, prod_fp32_mant};
                        aligned_b = {1'b0, acc_mant[23:0]} >> exp_diff[4:0];
                        result_exp = prod_fp32_exp;
                    end else begin
                        aligned_a = {1'b0, acc_mant[23:0]};
                        aligned_b = {1'b0, prod_fp32_mant} >> (-exp_diff[4:0]);
                        result_exp = acc_exp;
                    end

                    // Add or subtract based on signs
                    // aligned_a = larger-exponent side, aligned_b = shifted smaller side
                    // exp_diff >= 0: aligned_a = product, aligned_b = acc (shifted)
                    // exp_diff <  0: aligned_a = acc,     aligned_b = product (shifted)
                    if (prod_sign == acc_sign) begin
                        result_mant_wide = {1'b0, aligned_a} + {1'b0, aligned_b};
                        result_sign = acc_sign;
                    end else begin
                        // Different signs: subtract smaller magnitude from larger
                        if (aligned_a >= aligned_b) begin
                            result_mant_wide = {1'b0, aligned_a} - {1'b0, aligned_b};
                            // Sign of the larger magnitude
                            result_sign = (exp_diff >= 0) ? prod_sign : acc_sign;
                        end else begin
                            result_mant_wide = {1'b0, aligned_b} - {1'b0, aligned_a};
                            result_sign = (exp_diff >= 0) ? acc_sign : prod_sign;
                        end
                    end

                    // Re-normalize
                    if (result_mant_wide == 0) begin
                        acc_sign <= 1'b0;
                        acc_exp  <= 9'b0;
                        acc_mant <= 25'b0;
                        acc_zero <= 1'b1;
                    end else if (result_mant_wide[25]) begin
                        // Carry overflow: shift right 2
                        acc_mant <= result_mant_wide[25:1];
                        acc_exp  <= result_exp + 9'd2;
                        acc_sign <= result_sign;
                    end else if (result_mant_wide[24]) begin
                        // Carry: shift right 1
                        acc_mant <= result_mant_wide[24:0];
                        acc_exp  <= result_exp + 9'd1;
                        acc_sign <= result_sign;
                    end else begin
                        // Need to find leading 1 and shift left
                        norm_shift = 5'd0;
                        norm_mant  = result_mant_wide[24:0];
                        norm_exp   = result_exp;

                        // Priority encoder for leading zero count
                        // Max shift needed: 24 (for smallest denorm-like result)
                        for (int i = 23; i >= 0; i--) begin
                            if (!result_mant_wide[i] && norm_shift == 5'd0 && i < 24) begin
                                // Continue counting
                            end else if (result_mant_wide[i]) begin
                                norm_shift = 5'(23 - i);
                                break;
                            end
                        end

                        if (norm_exp > 9'(norm_shift)) begin
                            acc_mant <= result_mant_wide[24:0] << norm_shift;
                            acc_exp  <= norm_exp - 9'(norm_shift);
                        end else begin
                            // Underflow → zero
                            acc_sign <= 1'b0;
                            acc_exp  <= 9'b0;
                            acc_mant <= 25'b0;
                            acc_zero <= 1'b1;
                        end
                        acc_sign <= result_sign;
                    end

                    // Saturate check
                    if (result_exp + 9'd1 >= 9'h0FF) begin
                        acc_sign <= result_sign;
                        acc_exp  <= 9'h0FE;
                        acc_mant <= 25'h1FFFFFF;
                    end
                end
            end
        end else begin
            acc_valid <= 1'b0;
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (valid_in && !prod_is_zero && !prod_is_nan && !acc_zero && !nan_flag) begin
            $display("[ACC @%0t] prod: sign=%b exp=%0d mant=0x%06H | fp32: exp=%0d mant=0x%06H",
                     $time, prod_sign, prod_exp, prod_mant,
                     prod_fp32_exp, prod_fp32_mant);
            $display("[ACC @%0t] acc:  sign=%b exp=%0d mant=0x%07H zero=%b",
                     $time, acc_sign, acc_exp, acc_mant, acc_zero);
            $display("[ACC @%0t] diff=%0d aligned_a=0x%07H aligned_b=0x%07H",
                     $time, exp_diff, aligned_a, aligned_b);
            $display("[ACC @%0t] result: sign=%b exp=%0d mant_wide=0x%07H",
                     $time, result_sign, result_exp, result_mant_wide);
        end
    end
    // synthesis translate_on

    // =========================================================================
    // Output: accumulator → FP32 bit pattern
    // =========================================================================

    always_comb begin
        if (nan_flag) begin
            acc_result = FP32_QNAN;
        end else if (acc_zero) begin
            acc_result = {acc_sign, 31'b0};
        end else if (acc_exp >= 9'h0FF) begin
            // Saturate
            acc_result = acc_sign ? FP32_NEG_MAX : FP32_POS_MAX;
        end else begin
            acc_result = {acc_sign, acc_exp[7:0], acc_mant[22:0]};
        end
    end

    assign acc_is_nan = nan_flag;

    // =========================================================================
    // SVA Assertions
    // =========================================================================

    // synthesis translate_off
    // clear와 valid_in 동시 불가
    assert property (@(posedge clk) disable iff (!rst_n)
        !(clear && valid_in))
    else $error("clear and valid_in asserted simultaneously");

    // NaN flag가 set되면 이후 clear까지 유지
    assert property (@(posedge clk) disable iff (!rst_n)
        nan_flag && !clear |=> nan_flag)
    else $error("NaN flag cleared without explicit clear");

    // acc_exp는 overflow 시 saturate
    assert property (@(posedge clk) disable iff (!rst_n)
        acc_valid |-> acc_exp <= 9'h0FE || nan_flag)
    else $error("Exponent overflow without saturation");
    // synthesis translate_on

endmodule
