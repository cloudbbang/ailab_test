// =============================================================================
// FP16 MAC Testbench for Vivado xsim
// Arithmetic Contract v1.0 검증
// =============================================================================

`timescale 1ns / 1ps

module tb_fp16_mac;

    // =========================================================================
    // Clock & Reset
    // =========================================================================

    logic        clk;
    logic        rst_n;

    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // DUT signals
    // =========================================================================

    logic        clear;
    logic        valid_in;
    logic [15:0] fp16_a;
    logic [15:0] fp16_b;
    logic        last;
    logic [31:0] fp32_result;
    logic        result_valid;

    fp16_mac u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .clear       (clear),
        .valid_in    (valid_in),
        .fp16_a      (fp16_a),
        .fp16_b      (fp16_b),
        .last        (last),
        .fp32_result (fp32_result),
        .result_valid(result_valid)
    );

    // =========================================================================
    // FP16 constants
    // =========================================================================

    localparam logic [15:0] FP16_ONE      = 16'h3C00;  // 1.0
    localparam logic [15:0] FP16_TWO      = 16'h4000;  // 2.0
    localparam logic [15:0] FP16_THREE    = 16'h4200;  // 3.0
    localparam logic [15:0] FP16_HALF     = 16'h3800;  // 0.5
    localparam logic [15:0] FP16_NEG_ONE  = 16'hBC00;  // -1.0
    localparam logic [15:0] FP16_ZERO     = 16'h0000;  // +0
    localparam logic [15:0] FP16_NEG_ZERO = 16'h8000;  // -0
    localparam logic [15:0] FP16_QNAN     = 16'h7E00;  // quiet NaN
    localparam logic [15:0] FP16_SUBNORM  = 16'h0001;  // smallest subnormal
    localparam logic [15:0] FP16_MAX      = 16'h7BFF;  // 65504

    // FP32 expected values
    localparam logic [31:0] FP32_ONE   = 32'h3F800000;  // 1.0
    localparam logic [31:0] FP32_TWO   = 32'h40000000;  // 2.0
    localparam logic [31:0] FP32_SIX   = 32'h40C00000;  // 6.0
    localparam logic [31:0] FP32_ZERO  = 32'h00000000;  // 0.0
    localparam logic [31:0] FP32_NEG1  = 32'hBF800000;  // -1.0

    // =========================================================================
    // Test counters
    // =========================================================================

    int pass_count = 0;
    int fail_count = 0;
    int test_num   = 0;

    // =========================================================================
    // Helper tasks
    // =========================================================================

    task automatic do_reset();
        rst_n    <= 0;
        clear    <= 0;
        valid_in <= 0;
        fp16_a   <= 16'b0;
        fp16_b   <= 16'b0;
        last     <= 0;
        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);
    endtask

    task automatic do_clear();
        clear <= 1;
        @(posedge clk);
        clear <= 0;
        @(posedge clk);
    endtask

    // Run single MAC: a × b, wait for result
    task automatic run_single_mac(
        input  logic [15:0] a,
        input  logic [15:0] b,
        output logic [31:0] result,
        output logic        got_result
    );
        do_clear();

        // Send input
        valid_in <= 1;
        fp16_a   <= a;
        fp16_b   <= b;
        last     <= 1;
        @(posedge clk);
        valid_in <= 0;
        last     <= 0;

        // Wait for result
        got_result = 0;
        repeat(15) begin
            @(posedge clk);
            if (result_valid) begin
                result = fp32_result;
                got_result = 1;
                return;
            end
        end
    endtask

    // Run N-element MAC
    task automatic run_mac_vector(
        input  logic [15:0] a_vec [],
        input  logic [15:0] b_vec [],
        input  int          n,
        output logic [31:0] result,
        output logic        got_result
    );
        do_clear();

        for (int i = 0; i < n; i++) begin
            valid_in <= 1;
            fp16_a   <= a_vec[i];
            fp16_b   <= b_vec[i];
            last     <= (i == n - 1) ? 1 : 0;
            @(posedge clk);
        end
        valid_in <= 0;
        last     <= 0;

        // Wait for result
        got_result = 0;
        repeat(15) begin
            @(posedge clk);
            if (result_valid) begin
                result = fp32_result;
                got_result = 1;
                return;
            end
        end
    endtask

    // FP32 bits → real conversion
    function automatic real fp32_to_real(logic [31:0] bits);
        real r;
        logic [31:0] b;
        b = bits;
        // Use $bitstoreal approach via shortreal
        r = $bitstoshortreal(b);
        return real'(r);
    endfunction

    // Check result with tolerance
    task automatic check_result(
        input string     test_name,
        input logic [31:0] result,
        input logic [31:0] expected,
        input logic        got_result,
        input int          max_ulp = 2
    );
        int ulp;
        real r_result, r_expected;

        test_num++;

        if (!got_result) begin
            $display("FAIL [%0d] %s: TIMEOUT - no result_valid", test_num, test_name);
            fail_count++;
            return;
        end

        // Simple ULP calculation
        if (result == expected) begin
            ulp = 0;
        end else begin
            // Signed magnitude ULP
            logic signed [31:0] r_signed, e_signed;
            r_signed = result[31] ? -(result & 32'h7FFFFFFF) : result;
            e_signed = expected[31] ? -(expected & 32'h7FFFFFFF) : expected;
            ulp = (r_signed > e_signed) ? int'(r_signed - e_signed)
                                        : int'(e_signed - r_signed);
        end

        r_result   = fp32_to_real(result);
        r_expected = fp32_to_real(expected);

        if (ulp <= max_ulp) begin
            $display("PASS [%0d] %s: result=%.6f (0x%08H), expected=%.6f (0x%08H), ULP=%0d",
                     test_num, test_name, r_result, result, r_expected, expected, ulp);
            pass_count++;
        end else begin
            $display("FAIL [%0d] %s: result=%.6f (0x%08H), expected=%.6f (0x%08H), ULP=%0d > %0d",
                     test_num, test_name, r_result, result, r_expected, expected, ulp, max_ulp);
            fail_count++;
        end
    endtask

    // Check NaN result
    task automatic check_nan(
        input string     test_name,
        input logic [31:0] result,
        input logic        got_result
    );
        test_num++;
        if (!got_result) begin
            $display("FAIL [%0d] %s: TIMEOUT", test_num, test_name);
            fail_count++;
            return;
        end

        if (result[30:23] == 8'hFF && result[22:0] != 0) begin
            $display("PASS [%0d] %s: NaN detected (0x%08H)", test_num, test_name, result);
            pass_count++;
        end else begin
            $display("FAIL [%0d] %s: expected NaN, got 0x%08H", test_num, test_name, result);
            fail_count++;
        end
    endtask

    // Check zero result
    task automatic check_zero(
        input string     test_name,
        input logic [31:0] result,
        input logic        got_result
    );
        test_num++;
        if (!got_result) begin
            $display("FAIL [%0d] %s: TIMEOUT", test_num, test_name);
            fail_count++;
            return;
        end

        if (result[30:0] == 31'b0) begin
            $display("PASS [%0d] %s: zero result (0x%08H)", test_num, test_name, result);
            pass_count++;
        end else begin
            $display("FAIL [%0d] %s: expected zero, got 0x%08H (%.6e)",
                     test_num, test_name, result, fp32_to_real(result));
            fail_count++;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================

    logic [31:0] result;
    logic        got_result;

    initial begin
        $display("==============================================");
        $display("  S80 FP16 MAC Testbench - xsim");
        $display("  Arithmetic Contract v1.0");
        $display("==============================================");
        $display("");

        do_reset();

        // -----------------------------------------------------------------
        // Test Group 1: Basic single multiply
        // -----------------------------------------------------------------
        $display("--- Group 1: Basic Single Multiply ---");

        run_single_mac(FP16_ONE, FP16_ONE, result, got_result);
        check_result("1.0 * 1.0 = 1.0", result, FP32_ONE, got_result);

        run_single_mac(FP16_TWO, FP16_THREE, result, got_result);
        check_result("2.0 * 3.0 = 6.0", result, FP32_SIX, got_result);

        run_single_mac(FP16_NEG_ONE, FP16_ONE, result, got_result);
        check_result("-1.0 * 1.0 = -1.0", result, FP32_NEG1, got_result);

        run_single_mac(FP16_HALF, FP16_TWO, result, got_result);
        check_result("0.5 * 2.0 = 1.0", result, FP32_ONE, got_result);

        // -----------------------------------------------------------------
        // Test Group 2: Special values
        // -----------------------------------------------------------------
        $display("");
        $display("--- Group 2: Special Values ---");

        run_single_mac(FP16_ZERO, FP16_ONE, result, got_result);
        check_zero("0 * 1 = 0", result, got_result);

        run_single_mac(FP16_ONE, FP16_ZERO, result, got_result);
        check_zero("1 * 0 = 0", result, got_result);

        run_single_mac(FP16_NEG_ZERO, FP16_ONE, result, got_result);
        check_zero("-0 * 1 = 0", result, got_result);

        run_single_mac(FP16_QNAN, FP16_ONE, result, got_result);
        check_nan("NaN * 1 = NaN", result, got_result);

        run_single_mac(FP16_ONE, FP16_QNAN, result, got_result);
        check_nan("1 * NaN = NaN", result, got_result);

        run_single_mac(FP16_SUBNORM, FP16_ONE, result, got_result);
        check_zero("subnorm * 1 = 0 (FTZ)", result, got_result);

        // -----------------------------------------------------------------
        // Test Group 3: Multi-element accumulation
        // -----------------------------------------------------------------
        $display("");
        $display("--- Group 3: Accumulation ---");

        // 1.0*1.0 + 1.0*1.0 = 2.0
        begin
            automatic logic [15:0] av2[2] = '{FP16_ONE, FP16_ONE};
            automatic logic [15:0] bv2[2] = '{FP16_ONE, FP16_ONE};
            run_mac_vector(av2, bv2, 2, result, got_result);
            check_result("1*1 + 1*1 = 2.0", result, FP32_TWO, got_result);
        end

        // 2.0*3.0 + (-1.0)*1.0 = 6.0 - 1.0 = 5.0
        // Use explicit 2-step MAC to avoid array scoping issues
        begin
            do_clear();
            // Element 0: 2.0 * 3.0
            valid_in <= 1;
            fp16_a   <= FP16_TWO;
            fp16_b   <= FP16_THREE;
            last     <= 0;
            @(posedge clk);
            // Element 1: -1.0 * 1.0
            fp16_a   <= FP16_NEG_ONE;
            fp16_b   <= FP16_ONE;
            last     <= 1;
            @(posedge clk);
            valid_in <= 0;
            last     <= 0;
            // Wait for result
            got_result = 0;
            repeat(15) begin
                @(posedge clk);
                if (result_valid) begin
                    result = fp32_result;
                    got_result = 1;
                    break;
                end
            end
            check_result("2*3 + (-1)*1 = 5.0", result, 32'h40A00000, got_result);
        end

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        $display("");
        $display("==============================================");
        $display("  Results: %0d PASSED, %0d FAILED out of %0d tests",
                 pass_count, fail_count, test_num);
        $display("==============================================");

        if (fail_count == 0)
            $display("  >>> ALL TESTS PASSED <<<");
        else
            $display("  >>> SOME TESTS FAILED <<<");

        $display("");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100_000;
        $display("ERROR: Global timeout at 100us");
        $finish;
    end

endmodule
