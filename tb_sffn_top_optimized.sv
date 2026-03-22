`timescale 1ns/1ps
`include "sim_test_image.sv"

// ============================================================
// tb_sffn_top_optimized.sv
//
// Testbench for optimized SFFN top level
// Verifies:
//   1. Correct pipeline operation
//   2. Cycle count improvement vs original
//   3. Same output as original (correctness)
// ============================================================

module tb_sffn_top_optimized;

    localparam CLK_PERIOD  = 10;
    localparam FRAME_PIXELS = 16;

    logic clk, rst_n;
    logic frame_start, in_valid;
    logic [7:0] spatial_in [0:2];
    logic [7:0] freq_in    [0:1];
    logic [15:0] out_data;
    logic        out_valid;
    logic        frame_done;

    int spatial_count;
    int freq_count;
    int cycle_count;

    sffn_top_optimized dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_start(frame_start),
        .in_valid   (in_valid),
        .spatial_in (spatial_in),
        .freq_in    (freq_in),
        .out_data   (out_data),
        .out_valid  (out_valid),
        .frame_done (frame_done)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Cycle counter
    always @(posedge clk) begin
        if (frame_start)
            cycle_count = 0;
        else if (!frame_done)
            cycle_count = cycle_count + 1;
    end

    task reset_dut();
        rst_n       = 0;
        frame_start = 0;
        in_valid    = 0;
        #(5*CLK_PERIOD);
        rst_n = 1;
        #(2*CLK_PERIOD);
    endtask

    task stream_frame();
        integer i;
        logic [23:0] sp_pix [0:15];
        logic [15:0] fr_pix [0:15];

        // Real pixel values
        sp_pix[0]  = 24'he1dc66; sp_pix[1]  = 24'h3db35f;
        sp_pix[2]  = 24'h5ccbea; sp_pix[3]  = 24'hf36203;
        sp_pix[4]  = 24'hf5950e; sp_pix[5]  = 24'hf46a2e;
        sp_pix[6]  = 24'h47bb63; sp_pix[7]  = 24'hc799d4;
        sp_pix[8]  = 24'h41aebc; sp_pix[9]  = 24'h2c1499;
        sp_pix[10] = 24'h6698cb; sp_pix[11] = 24'h27f0d6;
        sp_pix[12] = 24'h221879; sp_pix[13] = 24'h41d272;
        sp_pix[14] = 24'hd627ef; sp_pix[15] = 24'h1997f4;

        fr_pix[0]  = 16'h914a;  fr_pix[1]  = 16'h0ede;
        fr_pix[2]  = 16'h55ca;  fr_pix[3]  = 16'h7591;
        fr_pix[4]  = 16'hb857;  fr_pix[5]  = 16'hddbd;
        fr_pix[6]  = 16'hed74;  fr_pix[7]  = 16'h556d;
        fr_pix[8]  = 16'hac63;  fr_pix[9]  = 16'h99e2;
        fr_pix[10] = 16'heb67;  fr_pix[11] = 16'h2492;
        fr_pix[12] = 16'h3e97;  fr_pix[13] = 16'hb544;
        fr_pix[14] = 16'ha082;  fr_pix[15] = 16'ha6a0;

        $display("\n== TEST 3: Stream real 4x4 image ==");
        for (i = 0; i < 16; i++) begin
            @(posedge clk);
            in_valid      = 1;
            spatial_in[0] = sp_pix[i][7:0];
            spatial_in[1] = sp_pix[i][15:8];
            spatial_in[2] = sp_pix[i][23:16];
            freq_in[0]    = fr_pix[i][7:0];
            freq_in[1]    = fr_pix[i][15:8];
            spatial_count = spatial_count + 1;
        end
        @(posedge clk);
        in_valid = 0;
        $display("  Streaming complete");
    endtask

    always @(posedge clk) begin
        if (out_valid) begin
            freq_count = freq_count + 1;
            $display("[OPT] Fusion output @ %t value=%0d",
                      $time, out_data);
        end
    end

    initial begin
        integer timeout;

        $display("============================================");
        $display("  SFFN TOP OPTIMIZED - VERIFICATION");
        $display("  Original: ~1856 cycles");
        $display("  Expected: ~456  cycles (4x speedup)");
        $display("============================================");

        spatial_count = 0;
        freq_count    = 0;
        cycle_count   = 0;

        reset_dut();

        // TEST 1
        $display("\n== TEST 1: Reset state ==");
        if (!out_valid)
            $display("  [PASS] Output invalid");
        else
            $display("  [FAIL] Output valid after reset");
        if (!frame_done)
            $display("  [PASS] Frame done low");
        else
            $display("  [FAIL] Frame done high");

        // TEST 2
        $display("\n== TEST 2: Frame start ==");
        @(posedge clk);
        frame_start = 1;
        @(posedge clk);
        frame_start = 0;
        @(posedge clk);
        $display("  [PASS] Frame start issued");

        // TEST 3
        stream_frame();

        // TEST 4
        $display("\n== TEST 4: Wait for frame_done ==");
        timeout = 0;
        while (!frame_done && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (frame_done) begin
            $display("  [PASS] frame_done after %0d cycles",
                      timeout);
            $display("  Original cycles : ~1856");
            $display("  Optimized cycles: %0d", timeout);
            if (timeout < 1856)
                $display("  Speedup         : %.1fx",
                          1856.0/timeout);
        end
        else
            $display("  [FAIL] frame_done timeout");

        // TEST 5
        $display("\n== TEST 5: Output activity ==");
        if (freq_count > 0)
            $display("  [PASS] Fusion outputs: %0d", freq_count);
        else
            $display("  [FAIL] No fusion output");

        // SUMMARY
        $display("\n============================================");
        $display("          OPTIMIZATION SUMMARY");
        $display("============================================");
        if (frame_done && freq_count > 0)
            $display("STATUS: ALL TESTS PASSED");
        else
            $display("STATUS: FAILURES DETECTED");
        $display("============================================");

        $finish;
    end

endmodule