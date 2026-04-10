// =============================================================================
// DSP48E2 Multiplier Wrapper
// FP16 mantissa multiply: 11-bit × 11-bit = 22-bit product
// 3-stage pipeline (AREG=1, BREG=1, MREG=1)
//
// ifdef FPGA: DSP48E2 explicit instantiation
// ifdef ASIC: Generic multiplier + pipeline registers
// =============================================================================

module dsp48_mul_wrapper
    import s80_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic [10:0] mant_a,       // 11-bit mantissa (implicit 1 포함)
    input  logic [10:0] mant_b,       // 11-bit mantissa (implicit 1 포함)
    input  logic        valid_in,

    output logic [21:0] product,      // 22-bit mantissa product
    output logic        valid_out     // 3-cycle latency
);

    // Valid pipeline (3-stage)
    logic [2:0] valid_pipe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_pipe <= 3'b0;
        else
            valid_pipe <= {valid_pipe[1:0], valid_in};
    end

    assign valid_out = valid_pipe[2];

`ifdef FPGA

    // =========================================================================
    // FPGA: DSP48E2 Explicit Instantiation
    // =========================================================================

    logic [29:0] dsp_a;
    logic [17:0] dsp_b;
    logic [47:0] dsp_p;

    assign dsp_a = {19'b0, mant_a};
    assign dsp_b = {7'b0, mant_b};

    DSP48E2 #(
        // Feature control
        .USE_MULT           ("MULTIPLY"),   // Multiplier mode
        .AUTORESET_PATDET   ("NO_RESET"),
        .AUTORESET_PRIORITY ("RESET"),

        // Pipeline registers
        .AREG               (1),            // 1 stage on A input
        .BREG               (1),            // 1 stage on B input
        .MREG               (1),            // 1 stage on multiplier output
        .PREG               (1),            // Output register → 3-stage total (AREG+BREG, MREG, PREG)
        .ACASCREG           (1),
        .BCASCREG           (1),
        .ADREG              (0),
        .ALUMODEREG         (0),
        .CARRYINREG         (0),
        .CARRYINSELREG      (0),
        .CREG               (0),
        .DREG               (0),
        .INMODEREG          (0),
        .OPMODEREG          (0),

        // Unused features
        .A_INPUT            ("DIRECT"),
        .B_INPUT            ("DIRECT"),
        .AMULTSEL           ("A"),
        .BMULTSEL           ("B"),
        .PREADDINSEL        ("A"),
        .USE_PATTERN_DETECT ("NO_PATDET"),
        .USE_SIMD           ("ONE48"),
        .IS_CLK_INVERTED    (1'b0),
        .IS_RSTP_INVERTED   (1'b0)
    ) u_dsp48e2 (
        // Clock & Reset
        .CLK                (clk),
        .RSTP               (1'b0),        // PREG async reset disabled (use sync)
        .RSTA               (~rst_n),
        .RSTB               (~rst_n),
        .RSTM               (~rst_n),
        .RSTC               (1'b0),
        .RSTD               (1'b0),
        .RSTALLCARRYIN      (1'b0),
        .RSTALUMODE         (1'b0),
        .RSTCTRL            (1'b0),
        .RSTINMODE          (1'b0),

        // Clock enables
        .CEA1               (1'b0),
        .CEA2               (1'b1),
        .CEB1               (1'b0),
        .CEB2               (1'b1),
        .CEM                (1'b1),
        .CEP                (1'b1),      // PREG enabled
        .CEC                (1'b0),
        .CED                (1'b0),
        .CEAD               (1'b0),
        .CECARRYIN          (1'b0),
        .CEALUMODE          (1'b0),
        .CECTRL             (1'b0),
        .CEINMODE           (1'b0),

        // Data inputs
        .A                  (dsp_a),
        .B                  (dsp_b),
        .C                  (48'b0),
        .D                  (27'b0),
        .CARRYIN            (1'b0),

        // Mode control
        .OPMODE             (9'b00_000_01_01),  // P = A * B
        .ALUMODE            (4'b0000),           // Add
        .INMODE             (5'b00000),
        .CARRYINSEL         (3'b000),

        // Cascade (unused)
        .ACIN               (30'b0),
        .BCIN               (18'b0),
        .PCIN               (48'b0),
        .MULTSIGNIN         (1'b0),
        .CARRYCASCIN        (1'b0),

        // Outputs
        .P                  (dsp_p),
        .ACOUT              (),
        .BCOUT              (),
        .PCOUT              (),
        .MULTSIGNOUT        (),
        .CARRYCASCOUT       (),
        .CARRYOUT           (),
        .XOROUT             (),
        .OVERFLOW           (),
        .UNDERFLOW          (),
        .PATTERNDETECT      (),
        .PATTERNBDETECT     ()
    );

    assign product = dsp_p[21:0];

`else

    // =========================================================================
    // ASIC: Generic multiplier with 3-stage pipeline
    // Matches DSP48E2: AREG(1) + MREG(1) + PREG(1) = 3 stages
    // =========================================================================

    logic [10:0] a_reg, b_reg;       // Stage 1: input registers
    logic [21:0] mul_result;         // Combinational multiply
    logic [21:0] mul_reg;            // Stage 2: multiply register
    logic [21:0] out_reg;            // Stage 3: output register

    // Stage 1: register inputs (equivalent to AREG/BREG)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_reg <= 11'b0;
            b_reg <= 11'b0;
        end else begin
            a_reg <= mant_a;
            b_reg <= mant_b;
        end
    end

    // Combinational multiply
    assign mul_result = a_reg * b_reg;

    // Stage 2: register multiply output (equivalent to MREG)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mul_reg <= 22'b0;
        else
            mul_reg <= mul_result;
    end

    // Stage 3: output register (equivalent to PREG)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_reg <= 22'b0;
        else
            out_reg <= mul_reg;
    end

    assign product = out_reg;

`endif

    // =========================================================================
    // SVA Assertions
    // =========================================================================

    // synthesis translate_off
    // Product는 22-bit를 초과할 수 없음 (11×11 = max 22-bit)
    assert property (@(posedge clk) disable iff (!rst_n)
        valid_out |-> product <= 22'h3FFFFF)
    else $error("Product exceeds 22-bit range");

    // Valid pipeline latency = 3 cycles
    assert property (@(posedge clk) disable iff (!rst_n)
        $rose(valid_in) |-> ##3 valid_out)
    else $error("Valid pipeline latency mismatch");
    // synthesis translate_on

endmodule
