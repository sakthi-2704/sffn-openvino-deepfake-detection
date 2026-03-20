`timescale 1ns/1ps

module tb_sffn_top;

    localparam CLK_PERIOD   = 10;
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

    sffn_top dut (
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
        $display("\n== TEST 3: Stream 4x4 pixels ==");
        for (i = 0; i < FRAME_PIXELS; i = i + 1) begin
            @(posedge clk);
            in_valid      = 1;
            spatial_in[0] = $urandom_range(1, 255);
            spatial_in[1] = $urandom_range(1, 255);
            spatial_in[2] = $urandom_range(1, 255);
            freq_in[0]    = $urandom_range(1, 255);
            freq_in[1]    = $urandom_range(1, 255);
            spatial_count = spatial_count + 1;
            $display("[DEBUG] Pixel=%0d/%0d", spatial_count, FRAME_PIXELS);
        end
        @(posedge clk);
        in_valid = 0;
        $display("  Streaming complete");
    endtask

    always @(posedge clk) begin
        if (out_valid) begin
            freq_count = freq_count + 1;
            $display("[DEBUG] Fusion output @ %t value=%0d",
                      $time, out_data);
        end
    end

    initial begin
        integer timeout;

        $display("============================================");
        $display("  SFFN TOP - INTEGRATION VERIFICATION");
        $display("============================================");

        spatial_count = 0;
        freq_count    = 0;

        reset_dut();

        // ── TEST 1: Reset state ───────────────────────────────
        $display("\n== TEST 1: Reset state ==");
        if (!out_valid)
            $display("  [PASS] Output invalid");
        else
            $display("  [FAIL] Output valid after reset");
        if (!frame_done)
            $display("  [PASS] Frame done low");
        else
            $display("  [FAIL] Frame done high at reset");

        // ── TEST 2: Frame start ───────────────────────────────
        $display("\n== TEST 2: Frame start ==");
        @(posedge clk);
        frame_start = 1;
        @(posedge clk);
        // Conv modules now in S_RECV — give 1 extra cycle
        // before first pixel to ensure S_RECV is stable
        frame_start = 0;
        @(posedge clk);   // ← extra cycle for S_RECV stability
        $display("  [PASS] Frame start issued");

        // ── TEST 3: Stream pixels ─────────────────────────────
        stream_frame();

        // ── TEST 4: Wait for frame_done ───────────────────────
        $display("\n== TEST 4: Wait for frame_done ==");
        timeout = 0;
        while (!frame_done && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (frame_done)
            $display("  [PASS] frame_done after %0d cycles", timeout);
        else begin
            $display("  [FAIL] frame_done timeout %0d cycles", timeout);
            $display("  [INFO] out_valid=%0b frame_done=%0b",
                      out_valid, frame_done);
        end

        // ── TEST 5: Output activity ───────────────────────────
        $display("\n== TEST 5: Output activity ==");
        if (freq_count > 0)
            $display("  [PASS] Fusion outputs seen: %0d", freq_count);
        else
            $display("  [FAIL] No fusion output");

        // ── SUMMARY ───────────────────────────────────────────
        $display("\n============================================");
        $display("          TEST SUMMARY");
        $display("============================================");
        if (frame_done && freq_count > 0)
            $display("STATUS: ALL TESTS PASSED");
        else
            $display("STATUS: FAILURES DETECTED");
        $display("============================================");

        $finish;
    end

endmodule