// ============================================================
// tb_dual_stream_controller.sv (FINAL v2)
//
// Verification plan:
//   Test 1: Normal — freq finishes first
//   Test 2: Both streams finish same cycle
//   Test 3: Spatial finishes first (unusual case)
//   Test 4: Multiple frames back to back
//   Test 5: Active flag verification
// ============================================================

`timescale 1ns/1ps

module tb_dual_stream_controller;

    // ── DUT ports ─────────────────────────────────────────────
    logic        clk, rst_n;
    logic        frame_start;
    logic        frame_done;
    logic        spatial_start, spatial_done, spatial_flush;
    logic        freq_start,    freq_done,    freq_flush;
    logic        fusion_start,  fusion_done;
    logic        spatial_active, freq_active, fusion_active;
    logic [31:0] spatial_cycles, freq_cycles;
    logic [31:0] total_cycles,   frame_count;

    // ── DUT instantiation ─────────────────────────────────────
    dual_stream_controller DUT (
        .clk           (clk),
        .rst_n         (rst_n),
        .frame_start   (frame_start),
        .frame_done    (frame_done),
        .spatial_start (spatial_start),
        .spatial_done  (spatial_done),
        .spatial_flush (spatial_flush),
        .freq_start    (freq_start),
        .freq_done     (freq_done),
        .freq_flush    (freq_flush),
        .fusion_start  (fusion_start),
        .fusion_done   (fusion_done),
        .spatial_active(spatial_active),
        .freq_active   (freq_active),
        .fusion_active (fusion_active),
        .spatial_cycles(spatial_cycles),
        .freq_cycles   (freq_cycles),
        .total_cycles  (total_cycles),
        .frame_count   (frame_count)
    );

    // ── Clock 200MHz ──────────────────────────────────────────
    initial clk = 0;
    always #2.5 clk = ~clk;

    // ── Test infrastructure ───────────────────────────────────
    integer pass_count;
    integer fail_count;

    // ── Task: check logic signal ──────────────────────────────
    task check(
        input logic   got,
        input logic   exp,
        input string  label
    );
        if (got === exp) begin
            $display("  [PASS] %s", label);
            pass_count = pass_count + 1;
        end
        else begin
            $display("  [FAIL] %s: got=%0b exp=%0b",
                      label, got, exp);
            fail_count = fail_count + 1;
        end
    endtask

    // ── Task: check integer value ─────────────────────────────
    task check_val(
        input integer got,
        input integer exp,
        input string  label
    );
        if (got === exp) begin
            $display("  [PASS] %s = %0d", label, got);
            pass_count = pass_count + 1;
        end
        else begin
            $display("  [FAIL] %s: got=%0d exp=%0d",
                      label, got, exp);
            fail_count = fail_count + 1;
        end
    endtask

    // ── Task: send frame start pulse ──────────────────────────
    task send_frame_start();
        @(negedge clk);
        frame_start = 1;
        @(posedge clk);
        @(negedge clk);
        frame_start = 0;
    endtask

    // ── Task: simulate spatial stream ─────────────────────────
    // No wait for start pulse — already launched by controller
    task run_spatial(input integer latency);
        repeat(latency) @(posedge clk);
        @(negedge clk);
        spatial_done = 1;
        @(posedge clk);
        @(negedge clk);
        spatial_done = 0;
    endtask

    // ── Task: simulate freq stream ────────────────────────────
    // No wait for start pulse — already launched by controller
    task run_freq(input integer latency);
        repeat(latency) @(posedge clk);
        @(negedge clk);
        freq_done = 1;
        @(posedge clk);
        @(negedge clk);
        freq_done = 0;
    endtask

    // ── Task: simulate fusion ─────────────────────────────────
    // Waits for fusion_start — fires AFTER both streams done
    task run_fusion(input integer latency);
        @(posedge fusion_start);
        repeat(latency) @(posedge clk);
        @(negedge clk);
        fusion_done = 1;
        @(posedge clk);
        @(negedge clk);
        fusion_done = 0;
    endtask

    // ── Task: run complete frame ──────────────────────────────
    task run_frame(
        input integer sp_lat,
        input integer fr_lat,
        input integer fu_lat
    );
        fork
            run_spatial(sp_lat);
            run_freq   (fr_lat);
            run_fusion (fu_lat);
            @(posedge frame_done);
        join
        @(negedge clk);
    endtask

    // ── MAIN TEST SEQUENCE ────────────────────────────────────
    initial begin
        rst_n        = 0;
        frame_start  = 0;
        spatial_done = 0;
        freq_done    = 0;
        fusion_done  = 0;
        pass_count   = 0;
        fail_count   = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("\n");
        $display("============================================");
        $display("  DUAL STREAM CONTROLLER - VERIFICATION");
        $display("============================================");

        // ══════════════════════════════════════════════════════
        // TEST 1: Normal — freq finishes first
        // Reflects real SFFN:
        //   Freq  = 0.5% params → finishes fast
        //   Spatial = 99.5% params → takes longer
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 1: Normal (freq faster) ==");
        $display("  Spatial=100 cycles  Freq=10 cycles");

        send_frame_start();

        // Catch launch pulses on next cycle (S_LAUNCH state)
        @(posedge clk);
        @(negedge clk);
        check(spatial_start, 1'b1, "Spatial launched");
        check(freq_start,    1'b1, "Freq launched");

        // Run frame — streams already launched
        run_frame(100, 10, 5);

        check_val(frame_count, 1,   "Frame count = 1");
        $display("  Spatial cycles : %0d", spatial_cycles);
        $display("  Freq cycles    : %0d", freq_cycles);
        $display("  Total cycles   : %0d", total_cycles);

        repeat(3) @(posedge clk);

        // ══════════════════════════════════════════════════════
        // TEST 2: Both streams finish same cycle
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 2: Both finish simultaneously ==");
        $display("  Spatial=20 cycles  Freq=20 cycles");

        send_frame_start();
        run_frame(20, 20, 5);

        check_val(frame_count, 2, "Frame count = 2");
        $display("  Spatial cycles : %0d", spatial_cycles);
        $display("  Freq cycles    : %0d", freq_cycles);
        $display("  Total cycles   : %0d", total_cycles);

        repeat(3) @(posedge clk);

        // ══════════════════════════════════════════════════════
        // TEST 3: Spatial finishes first (unusual case)
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 3: Spatial faster (unusual) ==");
        $display("  Spatial=5 cycles  Freq=30 cycles");

        send_frame_start();
        run_frame(5, 30, 5);

        check_val(frame_count, 3, "Frame count = 3");
        $display("  Spatial cycles : %0d", spatial_cycles);
        $display("  Freq cycles    : %0d", freq_cycles);
        $display("  Total cycles   : %0d", total_cycles);

        repeat(3) @(posedge clk);

        // ══════════════════════════════════════════════════════
        // TEST 4: 3 frames back to back
        // Verifies controller resets between frames
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 4: 3 frames back to back ==");

        begin
            integer f;
            for (f = 0; f < 3; f++) begin
                send_frame_start();
                run_frame(50, 8, 3);
                $display("  Frame %0d done — total=%0d cycles",
                          f+4, total_cycles);
                repeat(2) @(posedge clk);
            end
        end

        check_val(frame_count, 6, "Frame count = 6");

        repeat(3) @(posedge clk);

        // ══════════════════════════════════════════════════════
        // TEST 5: Active flag verification
        // Manually control each stream to verify flags
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 5: Active flag verification ==");

        send_frame_start();

        // Check flags immediately after launch
        @(posedge clk);
        @(negedge clk);
        check(spatial_active, 1'b1, "Spatial active after launch");
        check(freq_active,    1'b1, "Freq active after launch");
        check(fusion_active,  1'b0, "Fusion NOT active yet");

        // Run streams with different latencies
        // Freq=5 cycles (finishes first)
        // Spatial=30 cycles (finishes later)
        fork
            // ── Spatial thread ────────────────────────────────
            begin
                repeat(30) @(posedge clk);
                @(negedge clk);
                spatial_done = 1;
                @(posedge clk);
                @(negedge clk);
                spatial_done = 0;
            end

            // ── Freq thread ───────────────────────────────────
            begin
                repeat(5) @(posedge clk);
                @(negedge clk);
                freq_done = 1;
                @(posedge clk);
                @(negedge clk);
                freq_done = 0;

                // After freq done — check flags
                repeat(2) @(posedge clk);
                @(negedge clk);
                check(freq_active,    1'b0,
                      "Freq inactive after done");
                check(spatial_active, 1'b1,
                      "Spatial still active");
                check(fusion_active,  1'b0,
                      "Fusion not started yet");
            end

            // ── Fusion thread ─────────────────────────────────
            begin
                @(posedge fusion_start);
                @(negedge clk);
                check(fusion_active,  1'b1,
                      "Fusion active");
                check(spatial_active, 1'b0,
                      "Spatial inactive at fusion");
                check(freq_active,    1'b0,
                      "Freq inactive at fusion");

                // Complete fusion
                repeat(3) @(posedge clk);
                @(negedge clk);
                fusion_done = 1;
                @(posedge clk);
                @(negedge clk);
                fusion_done = 0;
            end

            // ── Frame done monitor ────────────────────────────
            @(posedge frame_done);
        join

        // After frame done
        @(posedge clk);
        @(negedge clk);
        check(fusion_active,  1'b0, "Fusion inactive after done");
        check(spatial_active, 1'b0, "Spatial inactive at end");
        check(freq_active,    1'b0, "Freq inactive at end");
        check_val(frame_count, 7,   "Frame count = 7");

        // ── FINAL SUMMARY ─────────────────────────────────────
        $display("\n");
        $display("============================================");
        $display("         VERIFICATION SUMMARY");
        $display("============================================");
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
        #1000000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule : tb_dual_stream_controller