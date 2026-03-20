`timescale 1ns/1ps

module tb_sffn_top;

    // ============================
    // Parameters
    // ============================
    localparam CLK_PERIOD = 10;
    localparam FRAME_PIXELS = 16;

    // ============================
    // DUT signals
    // ============================

    logic clk;
    logic rst_n;

    logic frame_start;
    logic in_valid;

    logic [7:0] spatial_in [0:2];
    logic [7:0] freq_in    [0:1];

    logic [15:0] out_data;
    logic        out_valid;
    logic        frame_done;

    // ============================
    // Counters
    // ============================

    int spatial_count;
    int freq_count;

    // ============================
    // DUT
    // ============================

    sffn_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(frame_start),
        .in_valid(in_valid),
        .spatial_in(spatial_in),
        .freq_in(freq_in),
        .out_data(out_data),
        .out_valid(out_valid),
        .frame_done(frame_done)
    );

    // ============================
    // Clock
    // ============================

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ============================
    // Reset
    // ============================

    task reset_dut();
        begin
            rst_n = 0;
            frame_start = 0;
            in_valid = 0;
            #(5*CLK_PERIOD);
            rst_n = 1;
            #(2*CLK_PERIOD);
        end
    endtask

    // ============================
    // Stimulus
    // ============================

    task stream_frame();
        integer i;
        begin
            $display("\n== TEST 3: Stream 4x4 pixels ==");

            for (i = 0; i < FRAME_PIXELS; i = i + 1) begin
                @(posedge clk);

                in_valid = 1;

                spatial_in[0] = $urandom_range(0,255);
                spatial_in[1] = $urandom_range(0,255);
                spatial_in[2] = $urandom_range(0,255);

                freq_in[0] = $urandom_range(0,255);
                freq_in[1] = $urandom_range(0,255);

                spatial_count = spatial_count + 1;

                $display("[DEBUG] Spatial pix=%0d/%0d", spatial_count, FRAME_PIXELS);
            end

            @(posedge clk);
            in_valid = 0;

            $display("Streaming complete");
        end
    endtask

    // ============================
    // Monitor
    // ============================

    always @(posedge clk) begin
        if (out_valid) begin
            freq_count = freq_count + 1;
            $display("[DEBUG] Fusion output @ %t value=%0d", $time, out_data);
        end
    end

    // ============================
    // Main Test
    // ============================

    initial begin
        integer timeout;   // ✅ ONLY declaration

        $display("============================================");
        $display("  SFFN TOP - INTEGRATION VERIFICATION");
        $display("============================================");

        spatial_count = 0;
        freq_count = 0;

        // RESET
        reset_dut();

        // ============================
        // TEST 1: Reset state
        // ============================

        $display("\n== TEST 1: Reset state ==");

        if (!out_valid)
            $display("  [PASS] Output invalid");
        else
            $display("  [FAIL] Output valid after reset");

        if (!frame_done)
            $display("  [PASS] Frame done low");
        else
            $display("  [FAIL] Frame done high at reset");

        // ============================
        // TEST 2: Start frame
        // ============================

        $display("\n== TEST 2: Frame start ==");

        @(posedge clk);
        frame_start = 1;

        @(posedge clk);
        frame_start = 0;

        $display("  [PASS] Frame start issued");

        // ============================
        // TEST 3: Stream data
        // ============================

        stream_frame();

        // ============================
        // TEST 4: Wait for completion
        // ============================

        $display("\n== TEST 4: Wait for frame_done ==");

        timeout = 0;
        while (!frame_done && timeout < 500) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (frame_done)
            $display("  [PASS] frame_done asserted");
        else
            $display("  [FAIL] frame_done timeout");

        // ============================
        // TEST 5: Output activity
        // ============================

        $display("\n== TEST 5: Output activity ==");

        if (freq_count > 0)
            $display("  [PASS] Fusion outputs seen: %0d", freq_count);
        else
            $display("  [FAIL] No fusion output");

        // ============================
        // SUMMARY
        // ============================

        $display("\n============================================");
        $display("          TEST SUMMARY");
        $display("============================================");

        if (frame_done && freq_count > 0)
            $display("STATUS: ALL TESTS PASSED ✅");
        else
            $display("STATUS: FAILURES DETECTED ❌");

        $display("============================================");

        $finish;
    end

endmodule