`timescale 1ns/1ps

module tb_conv_3x3_systolic;

    localparam IN_CH  = 1;
    localparam OUT_CH = 1;
    localparam IMG_H  = 4;
    localparam IMG_W  = 4;
    localparam STRIDE = 1;
    localparam PAD    = 1;

    logic        clk, rst_n, start;
    logic [IN_CH*8-1:0]         pixel_in_flat;
    logic                       pixel_valid;
    logic [OUT_CH*IN_CH*9*8-1:0] weights_flat;
    logic [OUT_CH*32-1:0]        pixel_out_flat;
    logic                        out_valid;
    integer                      col_cnt_check;

    // DUT
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

    // 200MHz clock
    initial clk = 0;
    always #2.5 clk = ~clk;

    // Output display
    always @(posedge out_valid) begin
        @(negedge clk);
        $write("%4d", $signed(pixel_out_flat[31:0]));
        col_cnt_check = col_cnt_check + 1;
        if (col_cnt_check % IMG_W == 0)
            $display("");
    end

    // Build flat weights (all 1s)
    integer r, c, task_r, task_c;

    initial begin
        rst_n         = 0;
        start         = 0;
        pixel_valid   = 0;
        pixel_in_flat = 0;
        col_cnt_check = 0;
        weights_flat  = 0;

        // Fill all 9 weights with 1
        for (r = 0; r < 9; r++)
            weights_flat[r*8 +: 8] = 8'sd1;

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n========================================");
        $display("  CONV 3x3 SYSTOLIC TESTBENCH v4");
        $display("  %0dx%0d IN=%0d OUT=%0d PAD=%0d",
                  IMG_H, IMG_W, IN_CH, OUT_CH, PAD);
        $display("========================================");
        $display("\nExpected:");
        $display("  14  24  30  22");
        $display("  33  54  63  45");
        $display("  57  90  99  69");
        $display("  46  72  78  54");
        $display("\nActual:");

        // Start
        @(negedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Stream pixels row by row
        begin
            reg [7:0] img [0:15];
            img[0]  = 1;  img[1]  = 2;  img[2]  = 3;  img[3]  = 4;
            img[4]  = 5;  img[5]  = 6;  img[6]  = 7;  img[7]  = 8;
            img[8]  = 9;  img[9]  = 10; img[10] = 11; img[11] = 12;
            img[12] = 13; img[13] = 14; img[14] = 15; img[15] = 16;

            for (task_r = 0; task_r < IMG_H*IMG_W; task_r++) begin
                @(negedge clk);
                pixel_in_flat = img[task_r];
                pixel_valid   = 1;
                @(posedge clk);
            end
            @(negedge clk);
            pixel_valid = 0;
        end

        // Wait for all outputs
        wait(col_cnt_check == IMG_H * IMG_W);
        #100;

        $display("\n========================================");
        $display("  TESTBENCH COMPLETE");
        $display("========================================\n");
        $stop;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule : tb_conv_3x3_systolic