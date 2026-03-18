// ============================================================
// tb_conv_1x1_engine.sv
// Testbench for conv_1x1_engine
//
// Tests:
//   1. Single pixel, small channels (verify dot product)
//   2. Known weight pattern (all 1s)
//   3. Negative weights
//   4. Zero input (should output 0)
// ============================================================

`timescale 1ns/1ps

module tb_conv_1x1_engine;

    // ── Parameters for this test ──────────────────────────────
    // Use small channels for easy verification
    localparam IN_CH  = 4;
    localparam OUT_CH = 2;

    // ── DUT signals ───────────────────────────────────────────
    logic        clk, rst_n, start;
    logic signed [7:0] feat_in  [0:IN_CH-1];
    logic signed [7:0] weights  [0:OUT_CH-1][0:IN_CH-1];
    logic signed [31:0] feat_out [0:OUT_CH-1];
    logic        valid_out;

    // ── Instantiate DUT ───────────────────────────────────────
    conv_1x1_engine #(
        .IN_CH (IN_CH),
        .OUT_CH(OUT_CH)
    ) DUT (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .feat_in  (feat_in),
        .weights  (weights),
        .feat_out (feat_out),
        .valid_out(valid_out)
    );

    // ── Clock: 200MHz ─────────────────────────────────────────
    initial clk = 0;
    always #2.5 clk = ~clk;

    // ── Task: run one convolution and check ───────────────────
    task run_conv(
        input logic signed [7:0] fin  [0:IN_CH-1],
        input logic signed [7:0] w    [0:OUT_CH-1][0:IN_CH-1],
        input logic signed [31:0] exp [0:OUT_CH-1],
        input string label
    );
        integer oc;
        // Load inputs
        @(negedge clk);
        feat_in = fin;
        weights = w;
        start   = 1;
        @(posedge clk);
        start = 0;

        // Wait for valid_out
        @(posedge valid_out);
        @(negedge clk);

        // Check all output channels
        $display("\n[%s]", label);
        for (oc = 0; oc < OUT_CH; oc++) begin
            $display("  out[%0d] = %0d | expected = %0d | %s",
                oc, feat_out[oc], exp[oc],
                (feat_out[oc] == exp[oc]) ? "PASS" : "FAIL"
            );
        end
    endtask

    // ── Test sequence ─────────────────────────────────────────
    initial begin
        // Initialize
        rst_n   = 0;
        start   = 0;
        feat_in = '{default: '0};
        weights = '{default: '{default: '0}};

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n========================================");
        $display("  CONV 1x1 ENGINE TESTBENCH");
        $display("  IN_CH=%0d  OUT_CH=%0d", IN_CH, OUT_CH);
        $display("========================================\n");

        // ── Test 1: All weights = 1, input = [1,2,3,4] ───────
        // Expected: out[0] = 1+2+3+4 = 10
        //           out[1] = 1+2+3+4 = 10
        begin
            logic signed [7:0] fin  [0:IN_CH-1];
            logic signed [7:0] w    [0:OUT_CH-1][0:IN_CH-1];
            logic signed [31:0] exp [0:OUT_CH-1];

            fin  = '{8'd1, 8'd2, 8'd3, 8'd4};
            w[0] = '{8'd1, 8'd1, 8'd1, 8'd1};
            w[1] = '{8'd1, 8'd1, 8'd1, 8'd1};
            exp  = '{32'd10, 32'd10};
            run_conv(fin, w, exp, "ALL WEIGHTS=1");
        end

        // ── Test 2: Different weights per output channel ──────
        // out[0] = 1*1 + 2*2 + 3*3 + 4*4 = 1+4+9+16 = 30
        // out[1] = 1*4 + 2*3 + 3*2 + 4*1 = 4+6+6+4  = 20
        begin
            logic signed [7:0] fin  [0:IN_CH-1];
            logic signed [7:0] w    [0:OUT_CH-1][0:IN_CH-1];
            logic signed [31:0] exp [0:OUT_CH-1];

            fin  = '{8'd1, 8'd2, 8'd3, 8'd4};
            w[0] = '{8'd1, 8'd2, 8'd3, 8'd4};
            w[1] = '{8'd4, 8'd3, 8'd2, 8'd1};
            exp  = '{32'd30, 32'd20};
            run_conv(fin, w, exp, "DIFFERENT WEIGHTS");
        end

        // ── Test 3: Negative weights ──────────────────────────
        // out[0] = 1*(-1) + 2*(-2) + 3*(-3) + 4*(-4) = -30
        // out[1] = 1*(-4) + 2*(-3) + 3*(-2) + 4*(-1) = -20
        begin
            logic signed [7:0] fin  [0:IN_CH-1];
            logic signed [7:0] w    [0:OUT_CH-1][0:IN_CH-1];
            logic signed [31:0] exp [0:OUT_CH-1];

            fin  = '{8'd1,  8'd2,  8'd3,  8'd4};
            w[0] = '{-8'd1, -8'd2, -8'd3, -8'd4};
            w[1] = '{-8'd4, -8'd3, -8'd2, -8'd1};
            exp  = '{-32'd30, -32'd20};
            run_conv(fin, w, exp, "NEGATIVE WEIGHTS");
        end

        // ── Test 4: Zero input ────────────────────────────────
        begin
            logic signed [7:0] fin  [0:IN_CH-1];
            logic signed [7:0] w    [0:OUT_CH-1][0:IN_CH-1];
            logic signed [31:0] exp [0:OUT_CH-1];

            fin  = '{8'd0, 8'd0, 8'd0, 8'd0};
            w[0] = '{8'd5, 8'd6, 8'd7, 8'd8};
            w[1] = '{8'd1, 8'd2, 8'd3, 8'd4};
            exp  = '{32'd0, 32'd0};
            run_conv(fin, w, exp, "ZERO INPUT");
        end

        // ── Test 5: Mixed positive/negative input ─────────────
        // out[0] = (-1)*1 + 2*1 + (-3)*1 + 4*1 = 2
        // out[1] = (-1)*1 + 2*1 + (-3)*1 + 4*1 = 2
        begin
            logic signed [7:0] fin  [0:IN_CH-1];
            logic signed [7:0] w    [0:OUT_CH-1][0:IN_CH-1];
            logic signed [31:0] exp [0:OUT_CH-1];

            fin  = '{-8'd1, 8'd2, -8'd3, 8'd4};
            w[0] = '{8'd1,  8'd1,  8'd1, 8'd1};
            w[1] = '{8'd1,  8'd1,  8'd1, 8'd1};
            exp  = '{32'd2, 32'd2};
            run_conv(fin, w, exp, "MIXED INPUT");
        end

        $display("\n========================================");
        $display("  TESTBENCH COMPLETE");
        $display("========================================\n");

        #50;
        $stop;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule : tb_conv_1x1_engine