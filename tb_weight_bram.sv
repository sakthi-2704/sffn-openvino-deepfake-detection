// ============================================================
// tb_weight_bram.sv
//
// Verification plan:
//   Test 1: Write known pattern, read back, verify
//   Test 2: Read different layers independently
//   Test 3: Verify 1-cycle read latency
//   Test 4: Sequential burst read
//   Test 5: Layer switch mid-read
// ============================================================

`timescale 1ns/1ps

module tb_weight_bram;

    // ── Parameters ────────────────────────────────────────────
    localparam NUM_LAYERS = 4;     // small for testing
    localparam ADDR_WIDTH = 10;    // 1024 addresses
    localparam DATA_WIDTH = 8;

    // ── DUT ports ─────────────────────────────────────────────
    logic                              clk;
    logic                              rst_n;
    logic [$clog2(NUM_LAYERS)-1:0]     layer_sel;
    logic                              rd_en;
    logic [ADDR_WIDTH-1:0]             rd_addr;
    logic [DATA_WIDTH-1:0]             rd_data;
    logic                              rd_valid;

    // ── DUT instantiation ─────────────────────────────────────
    weight_bram #(
        .NUM_LAYERS (NUM_LAYERS),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) DUT (
        .clk      (clk),
        .rst_n    (rst_n),
        .layer_sel(layer_sel),
        .rd_en    (rd_en),
        .rd_addr  (rd_addr),
        .rd_data  (rd_data),
        .rd_valid (rd_valid)
    );

    // ── Clock 200MHz ──────────────────────────────────────────
    initial clk = 0;
    always #2.5 clk = ~clk;

    // ── Test infrastructure ───────────────────────────────────
    integer pass_count;
    integer fail_count;
    integer i, l;

    // ── Task: single read ─────────────────────────────────────
    task read_word(
        input  integer             lyr,
        input  integer             addr,
        output logic [7:0]         data
    );
        @(negedge clk);
        layer_sel = lyr;
        rd_addr   = addr;
        rd_en     = 1;
        @(posedge clk);
        @(negedge clk);
        rd_en = 0;
        // Wait 1 cycle for rd_valid
        @(posedge clk);
        @(negedge clk);
        data = rd_data;
    endtask

    // ── Task: check ───────────────────────────────────────────
    task check(
        input logic [7:0] got,
        input logic [7:0] exp,
        input string      label
    );
        if (got === exp) begin
            $display("  [PASS] %s: got=0x%02h exp=0x%02h",
                      label, got, exp);
            pass_count = pass_count + 1;
        end
        else begin
            $display("  [FAIL] %s: got=0x%02h exp=0x%02h",
                      label, got, exp);
            fail_count = fail_count + 1;
        end
    endtask

    // ── MAIN TEST ─────────────────────────────────────────────
    logic [7:0] read_result;

    initial begin
        rst_n     = 0;
        rd_en     = 0;
        rd_addr   = 0;
        layer_sel = 0;
        pass_count = 0;
        fail_count = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("\n");
        $display("============================================");
        $display("  WEIGHT BRAM - VERIFICATION SUITE");
        $display("  LAYERS=%0d  ADDR_W=%0d  DATA_W=%0d",
                  NUM_LAYERS, ADDR_WIDTH, DATA_WIDTH);
        $display("============================================");

        // ── Pre-load known test patterns into BRAM ────────────
        // Directly force values into BRAM array for testing
        // In real use these come from .mif files
        $display("\n-- Loading test patterns into BRAM --");
        for(i=0;i<128;i++) begin
            DUT.bram[0][i] = i[7:0];    //Layer 0: sequential
            DUT.bram[1][i] = ~i[7:0];   //Layer 2: inverted
            DUT.bram[2][i] = 8'hAA;     //Layer 3: alternating
        end

        begin
            integer temp;
            for(i=0;i<128;i++) begin
                temp=i*2;
                DUT.bram[3][i] = temp[7:0];    //Layer 3: doubled
            end
        end 

        @(posedge clk);
        $display(" Test Patterns Loaded");

        // ══════════════════════════════════════════════════════
        // TEST 1: Basic read from layer 0
        // Expected: addr[i] = i
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 1: Basic read layer 0 ==");

        for (i = 0; i < 8; i++) begin
            read_word(0, i, read_result);
            check(read_result, i[7:0], $sformatf("L0[%0d]", i));
        end

        // ══════════════════════════════════════════════════════
        // TEST 2: Read from layer 1 (inverted pattern)
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 2: Read layer 1 (inverted) ==");

        for (i = 0; i < 8; i++) begin
            read_word(1, i, read_result);
            check(read_result, ~i[7:0],
                  $sformatf("L1[%0d]", i));
        end

        // ══════════════════════════════════════════════════════
        // TEST 3: Verify 1-cycle read latency
$display("\n== TEST 3: Read latency verification ==");

// Ensure clean state
@(negedge clk);
rd_en = 1'b0;
repeat(2) @(posedge clk);

// Assert rd_en
@(negedge clk);
rd_en     = 1'b1;
rd_addr   = 10'd5;
layer_sel = 0;
@(posedge clk);   // posedge: rd_valid_reg <= rd_en = 1
@(negedge clk);

// rd_valid should be HIGH now (same cycle as rd_en registered)
if (rd_valid === 1'b1) begin
    $display("  [PASS] rd_valid HIGH when rd_en HIGH (correct)");
    pass_count = pass_count + 1;
end
else begin
    $display("  [FAIL] rd_valid should be HIGH");
    fail_count = fail_count + 1;
end

// Deassert rd_en
rd_en = 1'b0;
@(posedge clk);   // posedge: rd_valid_reg <= rd_en = 0
@(negedge clk);

// rd_valid should be LOW now
if (rd_valid === 1'b0) begin
    $display("  [PASS] rd_valid LOW when rd_en LOW (correct)");
    pass_count = pass_count + 1;
end
else begin
    $display("  [FAIL] rd_valid should be LOW");
    fail_count = fail_count + 1;
end

// Verify data is correct
check(rd_data, 8'd5, "Latency data check");

        // ══════════════════════════════════════════════════════
        // TEST 4: Burst sequential read
        // Read 16 consecutive addresses from layer 2
        // All should be 0xAA
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 4: Burst read layer 2 (0xAA) ==");

        for (i = 0; i < 16; i++) begin
            @(negedge clk);
            layer_sel = 2'd2;
            rd_addr   = i[ADDR_WIDTH-1:0];
            rd_en     = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rd_en = 1'b0;
            @(posedge clk);
            @(negedge clk);
            check(rd_data, 8'hAA,
                  $sformatf("Burst L2[%0d]", i));
        end

        // ══════════════════════════════════════════════════════
        // TEST 5: Layer switch
        // Switch between layers mid-sequence
        // Verify correct data from each layer
        // ══════════════════════════════════════════════════════
        $display("\n== TEST 5: Layer switch test ==");

        // Read layer 0 addr 10 = 0x0A
        read_word(0, 10, read_result);
        check(read_result, 8'h0A, "Switch L0[10]");

        // Switch to layer 3 addr 5 = 5*2 = 10
        read_word(3, 5, read_result);
        check(read_result, 8'd10, "Switch L3[5]");

        // Switch back to layer 0 addr 20 = 0x14
        read_word(0, 20, read_result);
        check(read_result, 8'h14, "Switch back L0[20]");

        // Switch to layer 1 addr 3 = ~3 = 0xFC
        read_word(1, 3, read_result);
        check(read_result, 8'hFC, "Switch L1[3]");

        // ── SUMMARY ───────────────────────────────────────────
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
        #100000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule : tb_weight_bram