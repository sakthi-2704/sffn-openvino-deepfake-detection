// ============================================================
// conv_3x3_systolic.sv (v2 - corrected)
// 3x3 Convolution Engine
// Fixed: continuous pixel streaming with output pipeline
// ============================================================

import sffn_params::*;

module conv_3x3_systolic #(
    parameter int IN_CH   = 3,
    parameter int OUT_CH  = 32,
    parameter int IMG_H   = 224,
    parameter int IMG_W   = 224,
    parameter int STRIDE  = 1,
    parameter int PADDING = 1
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic signed [7:0]            pixel_in  [0:IN_CH-1],
    input  logic                         pixel_valid,
    input  logic signed [7:0]            weights [0:OUT_CH-1]
                                                  [0:IN_CH-1]
                                                  [0:2][0:2],
    output logic signed [ACCUM_BITS-1:0] pixel_out [0:OUT_CH-1],
    output logic                         out_valid
);

    // ── Line buffer: 3 rows x IMG_W cols x IN_CH channels ────
    logic signed [7:0] line_buf [0:2][0:IMG_W-1][0:IN_CH-1];

    // ── Pixel position tracking ───────────────────────────────
    logic [$clog2(IMG_H)-1:0] in_row;   // row of incoming pixel
    logic [$clog2(IMG_W)-1:0] in_col;   // col of incoming pixel
    logic [$clog2(IMG_H)-1:0] out_row;  // row of output pixel
    logic [$clog2(IMG_W)-1:0] out_col;  // col of output pixel

    // ── How many pixels have been received ───────────────────
    logic [$clog2(IMG_H*IMG_W+1)-1:0] pix_count;

    // ── Active flag ───────────────────────────────────────────
    logic active;

    // ── Accumulators ──────────────────────────────────────────
    logic signed [ACCUM_BITS-1:0] accum [0:OUT_CH-1];

    // ── Kernel position counters ──────────────────────────────
    logic [1:0] kr, kc;
    logic [$clog2(IN_CH)-1:0] ic;
    logic computing;

    // ── Output pixel counter ──────────────────────────────────
    logic [$clog2(IMG_H*IMG_W+1)-1:0] out_count;

    // ─────────────────────────────────────────────────────────
    // Start/active control
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active    <= 1'b0;
            in_row    <= '0;
            in_col    <= '0;
            pix_count <= '0;
        end
        else begin
            if (start) active <= 1'b1;

            if (active && pixel_valid) begin
                // Write pixel to line buffer
                line_buf[in_row % 3][in_col] <= pixel_in;

                // Advance position
                if (in_col == IMG_W - 1) begin
                    in_col <= '0;
                    in_row <= in_row + 1;
                end
                else begin
                    in_col <= in_col + 1;
                end
                pix_count <= pix_count + 1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Compute engine
    // Starts after we have 3 rows buffered (pix_count >= IMG_W*3)
    // Then computes one output pixel per (9*IN_CH) cycles
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            computing <= 1'b0;
            kr        <= '0;
            kc        <= '0;
            ic        <= '0;
            out_row   <= '0;
            out_col   <= '0;
            out_valid <= 1'b0;
            out_count <= '0;
            for (int o = 0; o < OUT_CH; o++)
                accum[o] <= '0;
        end
        else begin
            out_valid <= 1'b0;

            // Start computing when 3 rows are ready
            if (!computing &&
                pix_count >= IMG_W * 2 + 3 &&
                out_count < IMG_H * IMG_W) begin
                computing <= 1'b1;
                kr <= '0;
                kc <= '0;
                ic <= '0;
                // Clear accumulators
                for (int o = 0; o < OUT_CH; o++)
                    accum[o] <= '0;
            end

            if (computing) begin
                // MAC: accum[oc] += window * weight
                for (int o = 0; o < OUT_CH; o++) begin
                    // Get window pixel with zero padding
                    logic signed [7:0] win_pix;
                    logic signed [$clog2(IMG_H+2):0] wr;
                    logic signed [$clog2(IMG_W+2):0] wc;
                    wr = out_row + kr - PADDING;
                    wc = out_col + kc - PADDING;

                    if (wr < 0 || wr >= IMG_H ||
                        wc < 0 || wc >= IMG_W)
                        win_pix = 8'sd0;
                    else
                        win_pix = line_buf[wr % 3][wc][ic];

                    accum[o] <= accum[o] +
                        ACCUM_BITS'(signed'(
                            win_pix * weights[o][ic][kr][kc]
                        ));
                end

                // Step kernel position
                if (kc == 2) begin
                    kc <= '0;
                    if (kr == 2) begin
                        kr <= '0;
                        if (ic == IN_CH - 1) begin
                            // Done with this output pixel
                            ic        <= '0;
                            out_valid <= 1'b1;
                            out_count <= out_count + 1;
                            computing <= 1'b0;

                            // Advance output position
                            if (out_col == IMG_W - 1) begin
                                out_col <= '0;
                                out_row <= out_row + 1;
                            end
                            else begin
                                out_col <= out_col + STRIDE;
                            end

                            // Clear for next pixel
                            for (int o = 0; o < OUT_CH; o++)
                                accum[o] <= '0;
                        end
                        else begin
                            ic <= ic + 1;
                        end
                    end
                    else begin
                        kr <= kr + 1;
                    end
                end
                else begin
                    kc <= kc + 1;
                end
            end
        end
    end

    // ── Connect output ────────────────────────────────────────
    genvar o;
    generate
        for (o = 0; o < OUT_CH; o++) begin : gen_out
            assign pixel_out[o] = accum[o];
        end
    endgenerate

endmodule : conv_3x3_systolic