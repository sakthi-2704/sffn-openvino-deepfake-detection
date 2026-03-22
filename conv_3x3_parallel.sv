// ============================================================
// conv_3x3_parallel.sv
//
// Optimized version of conv_3x3_systolic.sv
// Key optimization: All input channels processed in parallel
// per kernel position → IN_CH times faster than original
//
// Original:  IN_CH × 9 cycles per pixel
// Optimized: 9 cycles per pixel (regardless of IN_CH)
//
// Performance vs original:
//   Stem  (IN_CH=3):  27→9 cycles/pixel  (3x speedup)
//   Freq1 (IN_CH=2):  18→9 cycles/pixel  (2x speedup)
// ============================================================

import sffn_params::*;

module conv_3x3_parallel #(
    parameter IN_CH   = 1,
    parameter OUT_CH  = 1,
    parameter IMG_H   = 4,
    parameter IMG_W   = 4,
    parameter STRIDE  = 1,
    parameter PADDING = 1
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [IN_CH*8-1:0]           pixel_in_flat,
    input  logic                         pixel_valid,
    input  logic [OUT_CH*IN_CH*9*8-1:0]  weights_flat,
    output logic [OUT_CH*32-1:0]         pixel_out_flat,
    output logic                         out_valid
);

    // ── FSM ───────────────────────────────────────────────────
    localparam S_IDLE    = 2'd0;
    localparam S_RECV    = 2'd1;
    localparam S_COMPUTE = 2'd2;
    localparam S_OUTPUT  = 2'd3;

    reg [1:0] state;

    // ── Image buffer ──────────────────────────────────────────
    reg signed [7:0] img_buf [0:IMG_H-1][0:IMG_W-1][0:IN_CH-1];

    // ── Position tracking ─────────────────────────────────────
    reg [7:0] in_row,  in_col;
    reg [7:0] out_row, out_col;
    reg [1:0] kr, kc;   // kernel position

    // ── Accumulators ──────────────────────────────────────────
    reg signed [31:0] accum   [0:OUT_CH-1];
    reg signed [31:0] out_reg [0:OUT_CH-1];

    // ── Window pixel computation ──────────────────────────────
    reg signed [8:0] wr_signed, wc_signed;

    // ── Parallel channel accumulation ─────────────────────────
    // KEY OPTIMIZATION: sum all IN_CH channels at once
    // for current kernel position (kr, kc)
    reg signed [31:0] ch_sum [0:OUT_CH-1];

    // ── Loop variables ────────────────────────────────────────
    integer oo, ii, ch;

    // ─────────────────────────────────────────────────────────
    // Parallel channel sum for current kernel position
    // Computes: sum over ic of (img[wr][wc][ic] * weight[oc][ic][kr][kc])
    // All IN_CH channels in one cycle
    // ─────────────────────────────────────────────────────────
    always @(*) begin
        wr_signed = $signed({1'b0, out_row}) +
                    $signed({1'b0, kr}) -
                    $signed(9'd0 + PADDING);
        wc_signed = $signed({1'b0, out_col}) +
                    $signed({1'b0, kc}) -
                    $signed(9'd0 + PADDING);

        for (oo = 0; oo < OUT_CH; oo++) begin
            ch_sum[oo] = 32'sd0;
            // Sum ALL input channels simultaneously
            for (ii = 0; ii < IN_CH; ii++) begin
                if (wr_signed < 0 ||
                    wr_signed >= $signed(9'd0 + IMG_H) ||
                    wc_signed < 0 ||
                    wc_signed >= $signed(9'd0 + IMG_W))
                begin
                    // Zero padding
                    ch_sum[oo] = ch_sum[oo];
                end
                else begin
                    ch_sum[oo] = ch_sum[oo] +
                        $signed(img_buf
                            [wr_signed[2:0]]
                            [wc_signed[2:0]]
                            [ii]) *
                        $signed(weights_flat[
                            (oo*IN_CH*9 +
                             ii*9 +
                             kr*3 +
                             kc)*8 +: 8]);
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Main FSM
    // Now iterates only over kr,kc (9 positions)
    // Not over ic (all channels done in parallel above)
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            in_row    <= '0;
            in_col    <= '0;
            out_row   <= '0;
            out_col   <= '0;
            kr        <= '0;
            kc        <= '0;
            out_valid <= 1'b0;
            for (oo = 0; oo < OUT_CH; oo++) begin
                accum[oo]   <= 32'sd0;
                out_reg[oo] <= 32'sd0;
            end
        end
        else begin
            out_valid <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        state   <= S_RECV;
                        in_row  <= '0;
                        in_col  <= '0;
                        out_row <= '0;
                        out_col <= '0;
                        kr      <= '0;
                        kc      <= '0;
                        for (oo = 0; oo < OUT_CH; oo++)
                            accum[oo] <= 32'sd0;
                    end
                end

                S_RECV: begin
                    if (pixel_valid) begin
                        for (ii = 0; ii < IN_CH; ii++)
                            img_buf[in_row][in_col][ii] <=
                                pixel_in_flat[ii*8 +: 8];

                        if (in_col == IMG_W - 1) begin
                            in_col <= '0;
                            if (in_row == IMG_H - 1) begin
                                state  <= S_COMPUTE;
                                in_row <= '0;
                                kr     <= '0;
                                kc     <= '0;
                                for (oo = 0; oo < OUT_CH; oo++)
                                    accum[oo] <= 32'sd0;
                            end
                            else
                                in_row <= in_row + 8'd1;
                        end
                        else
                            in_col <= in_col + 8'd1;
                    end
                end

                // ── KEY OPTIMIZATION ──────────────────────────
                // Each cycle: accumulate ALL input channels
                // for current (kr,kc) kernel position
                // Only iterate over kr,kc → 9 cycles per pixel
                S_COMPUTE: begin
                    // Add parallel channel sum to accumulator
                    for (oo = 0; oo < OUT_CH; oo++)
                        accum[oo] <= accum[oo] + ch_sum[oo];

                    // Advance kernel position (kc → kr only)
                    if (kc == 2'd2) begin
                        kc <= 2'd0;
                        if (kr == 2'd2) begin
                            // All 9 kernel positions done
                            kr <= 2'd0;
                            for (oo = 0; oo < OUT_CH; oo++)
                                out_reg[oo] <= accum[oo] +
                                               ch_sum[oo];
                            state <= S_OUTPUT;
                        end
                        else
                            kr <= kr + 2'd1;
                    end
                    else
                        kc <= kc + 2'd1;
                end

                S_OUTPUT: begin
                    out_valid <= 1'b1;

                    if (out_col == IMG_W - 1) begin
                        out_col <= '0;
                        out_row <= out_row + 8'd1;
                    end
                    else
                        out_col <= out_col + STRIDE;

                    for (oo = 0; oo < OUT_CH; oo++)
                        accum[oo] <= 32'sd0;

                    if (out_row == IMG_H - 1 &&
                        out_col == IMG_W - 1)
                        state <= S_IDLE;
                    else begin
                        state <= S_COMPUTE;
                        kr    <= 2'd0;
                        kc    <= 2'd0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ── Output packing ────────────────────────────────────────
    genvar go;
    generate
        for (go = 0; go < OUT_CH; go++) begin : g_out
            assign pixel_out_flat[go*32+31 : go*32] =
                out_reg[go];
        end
    endgenerate

endmodule : conv_3x3_parallel