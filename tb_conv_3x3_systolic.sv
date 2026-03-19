// ============================================================
// tb_conv_3x3_systolic.sv (FINAL - with out_reg fix)
// ============================================================

`timescale 1ns/1ps

module tb_conv_3x3_systolic;

    // ── Parameters ────────────────────────────────────────────
    localparam IN_CH  = 1;
    localparam OUT_CH = 1;
    localparam IMG_H  = 4;
    localparam IMG_W  = 4;
    localparam STRIDE = 1;
    localparam PAD    = 1;
    localparam NPIX   = IMG_H * IMG_W;

    // ── DUT ports ─────────────────────────────────────────────
    logic                        clk;
    logic                        rst_n;
    logic                        start;
    logic [IN_CH*8-1:0]          pixel_in_flat;
    logic                        pixel_valid;
    logic [OUT_CH*IN_CH*9*8-1:0] weights_flat;
    logic [OUT_CH*32-1:0]        pixel_out_flat;
    logic                        out_valid;

    // ── DUT instantiation ─────────────────────────────────────
    conv_3x3_systolic #(
        .IN_CH  (IN_CH),
        .OUT_CH (OUT_CH),
        .IMG_H  (IMG_H),
        .IMG_W  (IMG_W),
        .STRIDE (STRIDE),
        .PADDING(PAD)
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
    integer r, c, k;

    reg [7:0]        img         [0:NPIX-1];
    reg signed [7:0] krnl        [0:8];
    reg signed [31:0] got        [0:NPIX-1];
    reg signed [31:0] expected_out [0:NPIX-1];

    // ── Output capture ────────────────────────────────────────
    // Capture on posedge out_valid using blocking assignment
    // out_reg in DUT holds stable value here
    always @(posedge out_valid) begin
        @(negedge clk);
        got[out_idx] = $signed(pixel_out_flat[31:0]);
        out_idx      = out_idx + 1;
    end

    // ── Task: load weights ────────────────────────────────────
    task load_weights(
        input reg signed [7:0] k0, k1, k2,
                               k3, k4, k5,
                               k6, k7, k8
    );
        weights_flat[0*8+:8] = k0;
        weights_flat[1*8+:8] = k1;
        weights_flat[2*8+:8] = k2;
        weights_flat[3*8+:8] = k3;
        weights_flat[4*8+:8] = k4;
        weights_flat[5*8+:8] = k5;
        weights_flat[6*8+:8] = k6;
        weights_flat[7*8+:8] = k7;
        weights_flat[8*8+:8] = k8;
    endtask

    // ── Task: stream image and wait for outputs ───────────────
    task stream_and_run();
        integer p;
        out_idx = 0;

        // Reset DUT between tests
        @(negedge clk);
        rst_n = 0;
        repeat(3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // Send start pulse
        @(negedge clk);
        start = 1;
        @(posedge clk);
        @(negedge clk);
        start = 0;

        // Stream all pixels one per clock
        for (p = 0; p < NPIX; p++) begin
            @(negedge clk);
            pixel_in_flat = img[p];
            pixel_valid   = 1;
            @(posedge clk);
        end
        @(negedge clk);
        pixel_valid = 0;

        // Wait for all NPIX outputs
        wait(out_idx == NPIX);
        @(negedge clk);
    endtask

    // ── Task: software reference model ────────────────────────
    task compute_expected_out(
        input reg [7:0]        image  [0:NPIX-1],
        input reg signed [7:0] kernel [0:8]
    );
        integer row, col, kr2, kc2, sr, sc;
        reg signed [31:0] sum;
        reg signed [7:0]  pix;

        for (row = 0; row < IMG_H; row++) begin
            for (col = 0; col < IMG_W; col++) begin
                sum = 32'sd0;
                for (kr2 = 0; kr2 < 3; kr2++) begin
                    for (kc2 = 0; kc2 < 3; kc2++) begin
                        sr = row + kr2 - PAD;
                        sc = col + kc2 - PAD;
                        if (sr < 0 || sr >= IMG_H ||
                            sc < 0 || sc >= IMG_W)
                            pix = 8'sd0;
                        else
                            pix = $signed(
                                {1'b0, image[sr*IMG_W+sc]});
                        sum = sum +
                            ($signed(pix) *
                             $signed(kernel[kr2*3+kc2]));
                    end
                end
                expected_out[row*IMG_W+col] = sum;
            end
        end
    endtask

    // ── Task: check and display results ───────────────────────
    task check_results(input string test_name);
        integer p;
        integer local_pass;
        integer local_fail;
        local_pass = 0;
        local_fail = 0;

        $display("\n[%s] Results:", test_name);
        $display("  Pixel  Expected    Got       Status");
        $display("  -------------------------------------");

        for (p = 0; p < NPIX; p++) begin
            if (got[p] === expected_out[p]) begin
                $display("  [%2d]   %6d     %6d    PASS",
                    p, expected_out[p], got[p]);
                local_pass = local_pass + 1;
                pass_count = pass_count + 1;
            end
            else begin
                $display("  [%2d]   %6d     %6d    FAIL <<<",
                    p, expected_out[p], got[p]);
                local_fail = local_fail + 1;
                fail_count = fail_count + 1;
            end
        end

        $display("  -------------------------------------");
        $display("  %s: %0d/%0d PASS",
            test_name,
            local_pass,
            local_pass + local_fail
        );
    endtask

    // ── MAIN TEST SEQUENCE ────────────────────────────────────
    initial begin
        // Initialize all signals
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
        $display("  CONV 3x3 SYSTOLIC - VERIFICATION SUITE");
        $display("  %0dx%0d image IN_CH=%0d OUT_CH=%0d PAD=%0d",
                  IMG_H, IMG_W, IN_CH, OUT_CH, PAD);
        $display("============================================");

        // ── Build test image 1..16 ────────────────────────────
        for (r = 0; r < NPIX; r++)
            img[r] = r + 1;

        // ══════════════════════════════════════════════════════
        // TEST 1: All-ones kernel
        // Expected: sum of 3x3 neighborhood with zero padding
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 1: All-ones kernel ==");
        $display("  Image:");
        for (r = 0; r < IMG_H; r++) begin
            $write("  ");
            for (c = 0; c < IMG_W; c++)
                $write("%4d", img[r*IMG_W+c]);
            $display("");
        end

        for (k = 0; k < 9; k++) krnl[k] = 8'sd1;
        load_weights(
            8'sd1, 8'sd1, 8'sd1,
            8'sd1, 8'sd1, 8'sd1,
            8'sd1, 8'sd1, 8'sd1
        );
        compute_expected_out(img, krnl);

        $display("  Expected:");
        for (r = 0; r < IMG_H; r++) begin
            $write("  ");
            for (c = 0; c < IMG_W; c++)
                $write("%4d", expected_out[r*IMG_W+c]);
            $display("");
        end

        stream_and_run();
        check_results("ALL-ONES KERNEL");

        // ══════════════════════════════════════════════════════
        // TEST 2: Identity kernel
        // center=1 rest=0
        // Output should equal input
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 2: Identity kernel ==");

        for (k = 0; k < 9; k++) krnl[k] = 8'sd0;
        krnl[4] = 8'sd1;
        load_weights(
            8'sd0, 8'sd0, 8'sd0,
            8'sd0, 8'sd1, 8'sd0,
            8'sd0, 8'sd0, 8'sd0
        );
        compute_expected_out(img, krnl);
        stream_and_run();
        check_results("IDENTITY KERNEL");

        // ══════════════════════════════════════════════════════
        // TEST 3: Negative kernel
        // All -1s — output should be negative of all-ones
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 3: Negative kernel ==");

        for (k = 0; k < 9; k++) krnl[k] = -8'sd1;
        load_weights(
           -8'sd1, -8'sd1, -8'sd1,
           -8'sd1, -8'sd1, -8'sd1,
           -8'sd1, -8'sd1, -8'sd1
        );
        compute_expected_out(img, krnl);
        stream_and_run();
        check_results("NEGATIVE KERNEL");

        // ══════════════════════════════════════════════════════
        // TEST 4: Edge detection kernel
        // [-1,-1,-1,-1,8,-1,-1,-1,-1]
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 4: Edge detection kernel ==");

        krnl[0]=-8'sd1; krnl[1]=-8'sd1; krnl[2]=-8'sd1;
        krnl[3]=-8'sd1; krnl[4]= 8'sd8; krnl[5]=-8'sd1;
        krnl[6]=-8'sd1; krnl[7]=-8'sd1; krnl[8]=-8'sd1;
        load_weights(
           -8'sd1, -8'sd1, -8'sd1,
           -8'sd1,  8'sd8, -8'sd1,
           -8'sd1, -8'sd1, -8'sd1
        );
        compute_expected_out(img, krnl);
        stream_and_run();
        check_results("EDGE DETECTION");

        // ══════════════════════════════════════════════════════
        // FINAL SUMMARY
        // ══════════════════════════════════════════════════════
        $display("\n");
        $display("============================================");
        $display("        VERIFICATION SUMMARY");
        $display("============================================");
        $display("  Total pixels   : %0d x 4 tests = %0d",
                  NPIX, NPIX*4);
        $display("  PASS           : %3d / %3d",
                  pass_count, pass_count+fail_count);
        $display("  FAIL           : %3d", fail_count);
        if (fail_count == 0)
            $display("  STATUS         : ALL TESTS PASSED");
        else
            $display("  STATUS         : FAILURES DETECTED");
        $display("============================================");

        #100;
        $stop;
    end

    // ── Watchdog ──────────────────────────────────────────────
    initial begin
        #5000000;
        $display("WATCHDOG TIMEOUT - FSM may be stuck");
        $finish;
    end

endmodule : tb_conv_3x3_systolic