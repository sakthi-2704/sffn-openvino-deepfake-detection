`timescale 1ns/1ps

module tb_conv_3x3_systolic;

    localparam IN_CH  = 1;
    localparam OUT_CH = 1;
    localparam IMG_H  = 4;
    localparam IMG_W  = 4;
    localparam STRIDE = 1;
    localparam PAD    = 1;

    logic        clk, rst_n, start;
    logic signed [7:0]  pixel_in  [0:IN_CH-1];
    logic               pixel_valid;
    logic signed [7:0]  weights [0:OUT_CH-1][0:IN_CH-1][0:2][0:2];
    logic signed [31:0] pixel_out [0:OUT_CH-1];
    logic               out_valid;
    integer             col_cnt_check;

    conv_3x3_systolic #(
        .IN_CH  (IN_CH),
        .OUT_CH (OUT_CH),
        .IMG_H  (IMG_H),
        .IMG_W  (IMG_W),
        .STRIDE (STRIDE),
        .PADDING(PAD)
    ) DUT (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .pixel_in   (pixel_in),
        .pixel_valid(pixel_valid),
        .weights    (weights),
        .pixel_out  (pixel_out),
        .out_valid  (out_valid)
    );

    // 200MHz clock
    initial clk = 0;
    always #2.5 clk = ~clk;

    // Output collector
    always @(posedge out_valid) begin
        @(negedge clk);
        $write("%4d", pixel_out[0]);
        col_cnt_check = col_cnt_check + 1;
        if (col_cnt_check % IMG_W == 0)
            $display("");
    end

    integer r, c;

    initial begin
        rst_n         = 0;
        start         = 0;
        pixel_valid   = 0;
        pixel_in      = '{default: 8'sd0};
        col_cnt_check = 0;

        // All-ones kernel
        for (r = 0; r < 3; r++)
            for (c = 0; c < 3; c++)
                weights[0][0][r][c] = 8'sd1;

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n========================================");
        $display("  CONV 3x3 SYSTOLIC TESTBENCH");
        $display("  %0dx%0d image IN=%0d OUT=%0d",
                  IMG_H, IMG_W, IN_CH, OUT_CH);
        $display("  Kernel: all 1s  Padding=%0d", PAD);
        $display("========================================");
        $display("\nInput image:");
        $display("   1   2   3   4");
        $display("   5   6   7   8");
        $display("   9  10  11  12");
        $display("  13  14  15  16");
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

        // Stream all 16 pixels
        begin
            logic signed [7:0] img [0:IMG_H-1][0:IMG_W-1];
            img[0] = '{8'sd1,  8'sd2,  8'sd3,  8'sd4};
            img[1] = '{8'sd5,  8'sd6,  8'sd7,  8'sd8};
            img[2] = '{8'sd9,  8'sd10, 8'sd11, 8'sd12};
            img[3] = '{8'sd13, 8'sd14, 8'sd15, 8'sd16};

            for (r = 0; r < IMG_H; r++) begin
                for (c = 0; c < IMG_W; c++) begin
                    @(negedge clk);
                    pixel_in[0] = img[r][c];
                    pixel_valid = 1;
                    @(posedge clk);
                end
            end
            @(negedge clk);
            pixel_valid = 0;
        end

        // Wait for all outputs
        wait(col_cnt_check == IMG_H * IMG_W);
        #50;

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