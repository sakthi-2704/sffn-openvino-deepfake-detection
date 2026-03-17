`timescale 1ns/1ps

module tb_mac_unit_int8;

    logic        clk, rst_n, en;
    logic signed [7:0]  a, b;
    logic signed [31:0] acc_in;
    logic signed [31:0] acc_out;

    // Instantiate DUT
    mac_unit_int8 DUT (
        .clk    (clk),
        .rst_n  (rst_n),
        .en     (en),
        .a      (a),
        .b      (b),
        .acc_in (acc_in),
        .acc_out(acc_out)
    );

    // 200MHz clock
    initial clk = 0;
    always #2.5 clk = ~clk;

    // Task: apply one MAC and check result
    task apply_mac(
        input logic signed [7:0]  ta, tb,
        input logic signed [31:0] tacc,
        input string              label
    );
        @(negedge clk);
        a      = ta;
        b      = tb;
        acc_in = tacc;
        en     = 1;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        $display("[%s] a=%0d b=%0d acc_in=%0d | acc_out=%0d | expected=%0d | %s",
            label, ta, tb, tacc,
            acc_out,
            tacc + (ta * tb),
            (acc_out == tacc + (ta * tb)) ? "PASS" : "FAIL"
        );
    endtask

    initial begin
        rst_n = 0; en = 0;
        a = 0; b = 0; acc_in = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n========================================");
        $display("  MAC UNIT INT8 TESTBENCH");
        $display("========================================\n");

        apply_mac( 8'd5,   8'd3,   32'd0,   "POS x POS ");
        apply_mac(-8'd4,   8'd7,   32'd0,   "NEG x POS ");
        apply_mac(-8'd6,  -8'd6,   32'd0,   "NEG x NEG ");
        apply_mac( 8'd10,  8'd10,  32'd500, "ACCUM     ");
        apply_mac( 8'd127, 8'd127, 32'd0,   "MAX x MAX ");
        apply_mac(-8'd128, 8'd127, 32'd0,   "MIN x MAX ");
        apply_mac( 8'd0,   8'd99,  32'd100, "ZERO x VAL");

        $display("\n--- Dot Product Test (4 MACs) ---");
        en = 1;
        a = 8'd2;  b = 8'd3;  acc_in = 32'd0;
        @(posedge clk); @(posedge clk); @(negedge clk);  // wait for stable
        a = 8'd4;  b = 8'd5;  acc_in = acc_out;           // read stable acc_out
        @(posedge clk); @(posedge clk); @(negedge clk);
        a = 8'd1;  b = 8'd6;  acc_in = acc_out;
        @(posedge clk); @(posedge clk); @(negedge clk);
        a = 8'd3;  b = 8'd3;  acc_in = acc_out;
        @(posedge clk); @(posedge clk); @(negedge clk);
        $display("[DOT PRODUCT] result=%0d | expected=41 | %s",
            acc_out,
            (acc_out == 32'd41) ? "PASS" : "FAIL"
        );

        $display("\n========================================");
        $display("  TESTBENCH COMPLETE");
        $display("========================================\n");
        $stop;
    end

    initial begin
        #10000;
        $display("TIMEOUT");
        $finish;
    end

endmodule : tb_mac_unit_int8