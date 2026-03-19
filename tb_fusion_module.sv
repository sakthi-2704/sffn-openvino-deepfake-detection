// ============================================================
// tb_fusion_module.sv (FINAL v2)
//
// Verification plan:
//   Test 1: All-ones features + weights
//   Test 2: Zero inputs
//   Test 3: Known values end to end
//   Test 4: Negative weights
// ============================================================

`timescale 1ns/1ps

module tb_fusion_module;

    // ── Small parameters for verification ─────────────────────
    localparam SPATIAL_CH  = 4;
    localparam FREQ_CH     = 2;
    localparam FUSED_CH    = 2;
    localparam SPATIAL_HW  = 2;
    localparam FREQ_HW     = 2;
    localparam CONCAT_CH   = SPATIAL_CH + FREQ_CH;
    localparam SPATIAL_PIX = SPATIAL_HW * SPATIAL_HW;
    localparam FREQ_PIX    = FREQ_HW    * FREQ_HW;

    // ── DUT ports ─────────────────────────────────────────────
    logic                              clk, rst_n;
    logic                              start;
    logic [SPATIAL_CH*32-1:0]          spatial_feat_flat;
    logic                              spatial_valid;
    logic [FREQ_CH*32-1:0]             freq_feat_flat;
    logic                              freq_valid;
    logic [FUSED_CH*CONCAT_CH*8-1:0]   fc_weights_flat;
    logic [FUSED_CH*32-1:0]            fused_out_flat;
    logic                              fused_valid;
    logic                              done;

    // ── DUT instantiation ─────────────────────────────────────
    fusion_module #(
        .SPATIAL_CH (SPATIAL_CH),
        .FREQ_CH    (FREQ_CH),
        .FUSED_CH   (FUSED_CH),
        .SPATIAL_HW (SPATIAL_HW),
        .FREQ_HW    (FREQ_HW)
    ) DUT (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .spatial_feat_flat(spatial_feat_flat),
        .spatial_valid    (spatial_valid),
        .freq_feat_flat   (freq_feat_flat),
        .freq_valid       (freq_valid),
        .fc_weights_flat  (fc_weights_flat),
        .fused_out_flat   (fused_out_flat),
        .fused_valid      (fused_valid),
        .done             (done)
    );

    // ── Clock 200MHz ──────────────────────────────────────────
    initial clk = 0;
    always #2.5 clk = ~clk;

    // ── Test infrastructure ───────────────────────────────────
    integer pass_count;
    integer fail_count;
    integer i, p2, c2;

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

    // ── Task: reset DUT ───────────────────────────────────────
    task reset_dut();
        @(negedge clk);
        rst_n = 0;
        spatial_valid = 0;
        freq_valid    = 0;
        start         = 0;
        repeat(3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
    endtask

    // ── Task: stream spatial features (sequential) ────────────
    task stream_spatial(
        input reg signed [31:0] feat [0:3][0:3]
    );
        integer p, c;
        for (p = 0; p < SPATIAL_PIX; p++) begin
            @(negedge clk);
            for (c = 0; c < SPATIAL_CH; c++)
                spatial_feat_flat[c*32 +: 32] = feat[p][c];
            spatial_valid = 1;
            @(posedge clk);
        end
        @(negedge clk);
        spatial_valid = 0;
    endtask

    // ── Task: stream freq features (sequential) ───────────────
    task stream_freq(
        input reg signed [31:0] feat [0:3][0:1]
    );
        integer p, c;
        for (p = 0; p < FREQ_PIX; p++) begin
            @(negedge clk);
            for (c = 0; c < FREQ_CH; c++)
                freq_feat_flat[c*32 +: 32] = feat[p][c];
            freq_valid = 1;
            @(posedge clk);
        end
        @(negedge clk);
        freq_valid = 0;
    endtask

    // ── Task: load FC weights ─────────────────────────────────
    task load_fc_weights(input reg signed [7:0] w_val);
        integer idx;
        for (idx = 0; idx < FUSED_CH*CONCAT_CH; idx++)
            fc_weights_flat[idx*8+:8] = w_val;
    endtask

    // ── Task: run one full fusion test ────────────────────────
    task run_fusion_test(
        input reg signed [31:0] sp [0:3][0:3],
        input reg signed [31:0] fr [0:3][0:1],
        input reg signed [7:0]  w_val,
        input integer            exp0,
        input integer            exp1,
        input string             label
    );
        // Send start pulse
        @(negedge clk);
        start = 1;
        @(posedge clk);
        @(negedge clk);
        start = 0;

        // Stream spatial FIRST (FSM: S_GAP_SP)
        stream_spatial(sp);

        // Stream freq SECOND (FSM: S_GAP_FR)
        stream_freq(fr);

        // Wait for done
        @(posedge done);
        @(negedge clk);

        // Check outputs
        check_val($signed(fused_out_flat[31:0]),
                  exp0, {label, " out[0]"});
        check_val($signed(fused_out_flat[63:32]),
                  exp1, {label, " out[1]"});
    endtask

    // ── MAIN TEST SEQUENCE ────────────────────────────────────
    initial begin
        rst_n             = 0;
        start             = 0;
        spatial_valid     = 0;
        freq_valid        = 0;
        spatial_feat_flat = 0;
        freq_feat_flat    = 0;
        fc_weights_flat   = 0;
        pass_count        = 0;
        fail_count        = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("\n");
        $display("============================================");
        $display("  FUSION MODULE - VERIFICATION SUITE");
        $display("  SP_CH=%0d  FR_CH=%0d  FUSED=%0d",
                  SPATIAL_CH, FREQ_CH, FUSED_CH);
        $display("  SP_HW=%0d  FR_HW=%0d",
                  SPATIAL_HW, FREQ_HW);
        $display("============================================");

        // ══════════════════════════════════════════════════════
        // TEST 1: All-ones features + all-ones weights
        //
        // Spatial: all pixels all channels = 1
        //   GAP = [4,4,4,4] (sum over 4 pixels)
        //
        // Freq: all pixels all channels = 1
        //   GAP = [4,4]
        //
        // Concat = [4,4,4,4,4,4]
        // FC weights = all 1s
        //   out[0] = 4+4+4+4+4+4 = 24
        //   out[1] = 24
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 1: All-ones features + weights ==");
        $display("  Expected: out[0]=24  out[1]=24");

        begin
            reg signed [31:0] sp [0:3][0:3];
            reg signed [31:0] fr [0:3][0:1];

            for (p2 = 0; p2 < SPATIAL_PIX; p2++)
                for (c2 = 0; c2 < SPATIAL_CH; c2++)
                    sp[p2][c2] = 32'sd1;

            for (p2 = 0; p2 < FREQ_PIX; p2++)
                for (c2 = 0; c2 < FREQ_CH; c2++)
                    fr[p2][c2] = 32'sd1;

            load_fc_weights(8'sd1);
            run_fusion_test(sp, fr, 8'sd1, 24, 24,
                            "ALL-ONES");
        end

        reset_dut();

        // ══════════════════════════════════════════════════════
        // TEST 2: Zero inputs
        // All features = 0 → output must be 0
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 2: Zero inputs ==");
        $display("  Expected: out[0]=0   out[1]=0");

        begin
            reg signed [31:0] sp [0:3][0:3];
            reg signed [31:0] fr [0:3][0:1];

            for (p2 = 0; p2 < SPATIAL_PIX; p2++)
                for (c2 = 0; c2 < SPATIAL_CH; c2++)
                    sp[p2][c2] = 32'sd0;

            for (p2 = 0; p2 < FREQ_PIX; p2++)
                for (c2 = 0; c2 < FREQ_CH; c2++)
                    fr[p2][c2] = 32'sd0;

            load_fc_weights(8'sd1);
            run_fusion_test(sp, fr, 8'sd1, 0, 0,
                            "ZERO-IN");
        end

        reset_dut();

        // ══════════════════════════════════════════════════════
        // TEST 3: Known values
        //
        // Spatial: each pixel = [1,2,3,4]
        //   GAP = [4,8,12,16]
        //
        // Freq: each pixel = [1,2]
        //   GAP = [4,8]
        //
        // Concat = [4,8,12,16,4,8]
        // FC weights = all 1s
        //   out[0] = 4+8+12+16+4+8 = 52
        //   out[1] = 52
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 3: Known values end-to-end ==");
        $display("  Spatial GAP=[4,8,12,16]  Freq GAP=[4,8]");
        $display("  Expected: out[0]=52  out[1]=52");

        begin
            reg signed [31:0] sp [0:3][0:3];
            reg signed [31:0] fr [0:3][0:1];

            for (p2 = 0; p2 < SPATIAL_PIX; p2++)
                for (c2 = 0; c2 < SPATIAL_CH; c2++)
                    sp[p2][c2] = c2 + 1;

            for (p2 = 0; p2 < FREQ_PIX; p2++)
                for (c2 = 0; c2 < FREQ_CH; c2++)
                    fr[p2][c2] = c2 + 1;

            load_fc_weights(8'sd1);
            run_fusion_test(sp, fr, 8'sd1, 52, 52,
                            "KNOWN-VAL");
        end

        reset_dut();

        // ══════════════════════════════════════════════════════
        // TEST 4: Negative weights
        // Same inputs as Test 3, FC weights = -1
        //   out[0] = -52
        //   out[1] = -52
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 4: Negative weights ==");
        $display("  Same as Test 3 but weights=-1");
        $display("  Expected: out[0]=-52  out[1]=-52");

        begin
            reg signed [31:0] sp [0:3][0:3];
            reg signed [31:0] fr [0:3][0:1];

            for (p2 = 0; p2 < SPATIAL_PIX; p2++)
                for (c2 = 0; c2 < SPATIAL_CH; c2++)
                    sp[p2][c2] = c2 + 1;

            for (p2 = 0; p2 < FREQ_PIX; p2++)
                for (c2 = 0; c2 < FREQ_CH; c2++)
                    fr[p2][c2] = c2 + 1;

            load_fc_weights(-8'sd1);
            run_fusion_test(sp, fr, -8'sd1, -52, -52,
                            "NEG-WEIGHT");
        end

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
        $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────
    initial begin
        #2000000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule : tb_fusion_module