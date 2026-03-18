// ============================================================
// tb_conv_3x3_systolic.sv
// Testbench for conv_3x3_systolic
//
// Uses small 4x4 image, 1 input channel, 1 output channel
// for easy manual verification
// ============================================================

`timescale 1ns/1ps

module tb_conv_3x3_systolic;

    // ── Small parameters for easy testing ────────────────────
    localparam IN_CH  = 1;
    localparam OUT_CH = 1;
    localparam IMG_H  = 4;
    localparam IMG_W  = 4;
    localparam STRIDE = 1;
    localparam PAD    = 1;

    // ── DUT signals ───────────────────────────────────────────
    logic        clk, rst_n, start;
    logic signed [7:0]  pixel_in  [0:IN_CH-1];
    logic               pixel_valid;
    logic signed [7:0]  weights [0:OUT_CH-1][0:IN_CH-1][0:2][0:2];
    logic signed [31:0] pixel_out [0:OUT_CH-1];
    logic               out_valid;
    integer col_cnt_check;

    // ── Instantiate DUT ───────────────────────────────────────
    conv_3x3_systolic #(
        .IN_CH (IN_CH),
        .OUT_CH(OUT_CH),
        .IMG_H (IMG_H),
        .IMG_W (IMG_W),
        .STRIDE(STRIDE),
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

    // ── Clock: 200MHz ─────────────────────────────────────────
    initial clk = 0;
    always #2.5 clk = ~clk;

    // ── Test image: 4x4, 1 channel ────────────────────────────
    // Input:          Kernel (all 1s):
    // 1  2  3  4      1 1 1
    // 5  6  7  8      1 1 1
    // 9  10 11 12     1 1 1
    // 13 14 15 16
    //
    // Expected output (with padding=1, stride=1):
    // Top-left pixel (0,0):
    //   0  0  0        pad
    //   0  1  2    x   1 1 1  = 1+2+5+6 = 14
    //   0  5  6        1 1 1
    //                  1 1 1

    logic signed [7:0] test_image [0:IMG_H-1][0:IMG_W-1];
    integer r, c, oc;

    // ── Task: stream image pixels ─────────────────────────────
    task stream_image();
        integer row, col;
        for (row = 0; row < IMG_H; row++) begin
            for (col = 0; col < IMG_W; col++) begin
                @(negedge clk);
                pixel_in[0] = test_image[row][col];
                pixel_valid = 1;
                @(posedge clk);
            end
        end
        @(negedge clk);
        pixel_valid = 0;
    endtask

    // ── Main test ─────────────────────────────────────────────
    initial begin
        // Initialize
        col_cnt_check=0;
        rst_n       = 0;
        start       = 0;
        pixel_valid = 0;
        pixel_in    = '{default: 8'sd0};

        // Fill test image
        test_image[0] = '{8'sd1,  8'sd2,  8'sd3,  8'sd4};
        test_image[1] = '{8'sd5,  8'sd6,  8'sd7,  8'sd8};
        test_image[2] = '{8'sd9,  8'sd10, 8'sd11, 8'sd12};
        test_image[3] = '{8'sd13, 8'sd14, 8'sd15, 8'sd16};

        // All-ones kernel
        for (oc = 0; oc < OUT_CH; oc++)
            for (r = 0; r < 3; r++)
                for (c = 0; c < 3; c++)
                    weights[oc][0][r][c] = 8'sd1;

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n========================================");
        $display("  CONV 3x3 SYSTOLIC TESTBENCH");
        $display("  %0dx%0d image, IN=%0d OUT=%0d",
                  IMG_H, IMG_W, IN_CH, OUT_CH);
        $display("  Kernel: all 1s, Padding=%0d", PAD);
        $display("========================================\n");

        $display("Input image:");
        for (r = 0; r < IMG_H; r++) begin
            for (c = 0; c < IMG_W; c++)
                $write("%4d", test_image[r][c]);
            $display("");
        end
        $display("\nExpected output (sum of 3x3 neighborhood):");
        $display("  14  24  30  22");
        $display("  33  54  63  45");
        $display("  57  90  99  69");
        $display("  46  72  78  54");

        // Start convolution
        @(negedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Stream all pixels
        stream_image();

        // Collect outputs
        $display("\nActual output:");
        repeat(IMG_H * IMG_W) begin
            @(posedge out_valid);
            @(negedge clk);
            $write("%4d", pixel_out[0]);
            if (((col_cnt_check) % IMG_W) == IMG_W-1)
                $display("");
        end

        $display("\n========================================");
        $display("  TESTBENCH COMPLETE");
        $display("========================================\n");

        #100;
        $stop;
    end

    // ── Column counter for display formatting ─────────────────
    always @(posedge out_valid) begin
        col_cnt_check = col_cnt_check + 1;
    end

    // ── Timeout ───────────────────────────────────────────────
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule : tb_conv_3x3_systolic