// ============================================================
// tb_depthwise_filter.sv
//
// Verification plan:
//   Test 1: 3x3 kernel, all-ones weights
//           Each channel output = sum of 3x3 neighborhood
//   Test 2: 5x5 kernel, all-ones weights
//           Each channel output = sum of 5x5 neighborhood
//   Test 3: Identity kernel (center=1)
//           Output should equal input per channel
//   Test 4: Each channel has different weights
//           Verifies channel independence
// ============================================================

`timescale 1ns/1ps

module tb_depthwise_filter;

    // ── Parameters ────────────────────────────────────────────
    localparam CHANNELS = 2;      // small for easy verification
    localparam KS       = 3;      // test 3x3 first
    localparam IMG_H    = 4;
    localparam IMG_W    = 4;
    localparam STRIDE   = 1;
    localparam PAD      = 1;
    localparam NPIX     = IMG_H * IMG_W;
    localparam KS2      = KS * KS;

    // ── DUT ports ─────────────────────────────────────────────
    logic                                  clk;
    logic                                  rst_n;
    logic                                  start;
    logic [CHANNELS*8-1:0]                 pixel_in_flat;
    logic                                  pixel_valid;
    logic [CHANNELS*KS2*8-1:0]             weights_flat;
    logic [CHANNELS*32-1:0]                pixel_out_flat;
    logic                                  out_valid;

    // ── DUT instantiation ─────────────────────────────────────
    depthwise_filter #(
        .CHANNELS   (CHANNELS),
        .KERNEL_SIZE(KS),
        .IMG_H      (IMG_H),
        .IMG_W      (IMG_W),
        .STRIDE     (STRIDE),
        .PADDING    (PAD)
    ) DUT (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .pixel_in_flat (pixel_in_flat),
        .pixel_valid   (pixel_valid),
        .weights_flat  (weights_flat),
        .pixel_out_flat(pixel_out_flat),
        .out_valid     (out_valid)
    );

    // ── Clock 200MHz ──────────────────────────────────────────
    initial clk = 0;
    always #2.5 clk = ~clk;

    // ── Test infrastructure ───────────────────────────────────
    integer pass_count;
    integer fail_count;
    integer out_idx;
    integer r, c, k, ch;

    // Storage
    reg [7:0]         img_ch0      [0:NPIX-1];
    reg [7:0]         img_ch1      [0:NPIX-1];
    reg signed [7:0]  krnl_ch0     [0:KS2-1];
    reg signed [7:0]  krnl_ch1     [0:KS2-1];
    reg signed [31:0] got_ch0      [0:NPIX-1];
    reg signed [31:0] got_ch1      [0:NPIX-1];
    reg signed [31:0] exp_ch0      [0:NPIX-1];
    reg signed [31:0] exp_ch1      [0:NPIX-1];

    // ── Output capture ────────────────────────────────────────
    always @(posedge out_valid) begin
        @(negedge clk);
        got_ch0[out_idx] = $signed(pixel_out_flat[31:0]);
        got_ch1[out_idx] = $signed(pixel_out_flat[63:32]);
        out_idx          = out_idx + 1;
    end

    // ── Task: load weights for both channels ──────────────────
    task load_weights_both(
        input reg signed [7:0] w0 [0:KS2-1],  // ch0 weights
        input reg signed [7:0] w1 [0:KS2-1]   // ch1 weights
    );
        integer i;
        for (i = 0; i < KS2; i++) begin
            // ch0 weights at index i
            weights_flat[i*8+:8] = w0[i];
            // ch1 weights at index KS2+i
            weights_flat[(KS2+i)*8+:8] = w1[i];
        end
    endtask

    // ── Task: software reference model ────────────────────────
    task compute_expected_dw(
        input reg [7:0]        image  [0:NPIX-1],
        input reg signed [7:0] kernel [0:KS2-1],
        output reg signed [31:0] result [0:NPIX-1]
    );
        integer row, col, kr2, kc2, sr, sc;
        reg signed [31:0] sum;
        reg signed [7:0]  pix;

        for (row = 0; row < IMG_H; row++) begin
            for (col = 0; col < IMG_W; col++) begin
                sum = 32'sd0;
                for (kr2 = 0; kr2 < KS; kr2++) begin
                    for (kc2 = 0; kc2 < KS; kc2++) begin
                        sr = row + kr2 - PAD;
                        sc = col + kc2 - PAD;
                        if (sr < 0 || sr >= IMG_H ||
                            sc < 0 || sc >= IMG_W)
                            pix = 8'sd0;
                        else
                            pix = $signed(
                                {1'b0,image[sr*IMG_W+sc]});
                        sum = sum + ($signed(pix) *
                              $signed(kernel[kr2*KS+kc2]));
                    end
                end
                result[row*IMG_W+col] = sum;
            end
        end
    endtask

    // ── Task: stream and run ──────────────────────────────────
    task stream_and_run();
        integer p;
        out_idx = 0;

        // Reset between tests
        @(negedge clk);
        rst_n = 0;
        repeat(3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // Start pulse
        @(negedge clk);
        start = 1;
        @(posedge clk);
        @(negedge clk);
        start = 0;

        // Stream pixels: both channels interleaved in flat bus
        for (p = 0; p < NPIX; p++) begin
            @(negedge clk);
            pixel_in_flat[7:0]  = img_ch0[p];
            pixel_in_flat[15:8] = img_ch1[p];
            pixel_valid         = 1;
            @(posedge clk);
        end
        @(negedge clk);
        pixel_valid = 0;

        // Wait for all outputs
        wait(out_idx == NPIX);
        @(negedge clk);
    endtask

    // ── Task: check both channels ─────────────────────────────
    task check_results(input string test_name);
        integer p;
        integer local_pass, local_fail;
        local_pass = 0;
        local_fail = 0;

        $display("\n[%s]", test_name);
        $display("  Pix  Exp_CH0  Got_CH0  Exp_CH1  Got_CH1  Status");
        $display("  ─────────────────────────────────────────");

        for (p = 0; p < NPIX; p++) begin
            if (got_ch0[p] === exp_ch0[p] &&
                got_ch1[p] === exp_ch1[p]) begin
                $display(
                    "  [%2d]  %6d   %6d   %6d   %6d   PASS",
                    p, exp_ch0[p], got_ch0[p],
                       exp_ch1[p], got_ch1[p]);
                local_pass = local_pass + 1;
                pass_count = pass_count + 1;
            end
            else begin
                $display(
                    "  [%2d]  %6d   %6d   %6d   %6d   FAIL<<<",
                    p, exp_ch0[p], got_ch0[p],
                       exp_ch1[p], got_ch1[p]);
                local_fail = local_fail + 1;
                fail_count = fail_count + 1;
            end
        end

        $display("  ─────────────────────────────────────────");
        $display("  %s: %0d/%0d PASS",
            test_name, local_pass,
            local_pass+local_fail);
    endtask

    // ── MAIN TEST SEQUENCE ────────────────────────────────────
    initial begin
        rst_n         = 0;
        start         = 0;
        pixel_valid   = 0;
        pixel_in_flat = 0;
        weights_flat  = 0;
        pass_count    = 0;
        fail_count    = 0;
        out_idx       = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("\n");
        $display("============================================");
        $display("  DEPTHWISE FILTER - VERIFICATION SUITE");
        $display("  %0dx%0d  CH=%0d  KS=%0d  PAD=%0d",
                  IMG_H, IMG_W, CHANNELS, KS, PAD);
        $display("============================================");

        // Build test images
        // CH0: 1..16  CH1: 17..32
        for (r = 0; r < NPIX; r++) begin
            img_ch0[r] = r + 1;
            img_ch1[r] = r + 17;
        end

        // ══════════════════════════════════════════════════════
        // TEST 1: All-ones kernel, both channels
        // Verifies basic accumulation
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 1: All-ones kernel (3x3) ==");

        for (k = 0; k < KS2; k++) begin
            krnl_ch0[k] = 8'sd1;
            krnl_ch1[k] = 8'sd1;
        end
        load_weights_both(krnl_ch0, krnl_ch1);
        compute_expected_dw(img_ch0, krnl_ch0, exp_ch0);
        compute_expected_dw(img_ch1, krnl_ch1, exp_ch1);
        stream_and_run();
        check_results("ALL-ONES BOTH CH");

        // ══════════════════════════════════════════════════════
        // TEST 2: Identity kernel
        // Output should equal input per channel
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 2: Identity kernel ==");

        for (k = 0; k < KS2; k++) begin
            krnl_ch0[k] = 8'sd0;
            krnl_ch1[k] = 8'sd0;
        end
        krnl_ch0[4] = 8'sd1;  // center
        krnl_ch1[4] = 8'sd1;  // center
        load_weights_both(krnl_ch0, krnl_ch1);
        compute_expected_dw(img_ch0, krnl_ch0, exp_ch0);
        compute_expected_dw(img_ch1, krnl_ch1, exp_ch1);
        stream_and_run();
        check_results("IDENTITY BOTH CH");

        // ══════════════════════════════════════════════════════
        // TEST 3: DIFFERENT weights per channel
        // CH0: all 1s   CH1: all -1s
        // Proves channel independence — the KEY DWConv property
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 3: Different weights per channel ==");
        $display("  CH0: all +1   CH1: all -1");
        $display("  Proves channels are fully independent");

        for (k = 0; k < KS2; k++) begin
            krnl_ch0[k] =  8'sd1;   // ch0: sum
            krnl_ch1[k] = -8'sd1;   // ch1: negative sum
        end
        load_weights_both(krnl_ch0, krnl_ch1);
        compute_expected_dw(img_ch0, krnl_ch0, exp_ch0);
        compute_expected_dw(img_ch1, krnl_ch1, exp_ch1);
        stream_and_run();
        check_results("DIFF WEIGHTS PER CH");

        // ══════════════════════════════════════════════════════
        // TEST 4: Edge detection on CH0, blur on CH1
        // Real-world scenario — different operations per channel
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 4: Edge (CH0) + Blur (CH1) ==");

        // CH0: edge detection
        krnl_ch0[0]=-8'sd1; krnl_ch0[1]=-8'sd1;
        krnl_ch0[2]=-8'sd1; krnl_ch0[3]=-8'sd1;
        krnl_ch0[4]= 8'sd8; krnl_ch0[5]=-8'sd1;
        krnl_ch0[6]=-8'sd1; krnl_ch0[7]=-8'sd1;
        krnl_ch0[8]=-8'sd1;

        // CH1: all ones (blur/sum)
        for (k = 0; k < KS2; k++)
            krnl_ch1[k] = 8'sd1;

        load_weights_both(krnl_ch0, krnl_ch1);
        compute_expected_dw(img_ch0, krnl_ch0, exp_ch0);
        compute_expected_dw(img_ch1, krnl_ch1, exp_ch1);
        stream_and_run();
        check_results("EDGE+BLUR PER CH");

        // ── SUMMARY ───────────────────────────────────────────
        $display("\n");
        $display("============================================");
        $display("         VERIFICATION SUMMARY");
        $display("============================================");
        $display("  Total  : %0d pixels x 2 ch x 4 tests = %0d",
                  NPIX, NPIX*2*4);
        $display("  PASS   : %3d / %3d",
                  pass_count, pass_count+fail_count);
        $display("  FAIL   : %3d", fail_count);
        if (fail_count == 0)
            $display("  STATUS : ALL TESTS PASSED");
        else
            $display("  STATUS : FAILURES DETECTED");
        $display("============================================");

        #100;
        $stop;
    end

    // ── Watchdog ──────────────────────────────────────────────
    initial begin
        #5000000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule : tb_depthwise_filter