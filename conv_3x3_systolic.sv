// ============================================================
// conv_3x3_systolic.sv (v4 - pure compatible syntax)
// Uses flat arrays instead of multidimensional
// Compatible with ModelSim 10.5b
// ============================================================

import sffn_params::*;

module conv_3x3_systolic #(
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

    // Flattened inputs: pixel_in[ch] → pixel_in_flat[ch*8+7:ch*8]
    input  logic [IN_CH*8-1:0]           pixel_in_flat,
    input  logic                         pixel_valid,

    // Flattened weights: [oc][ic][kr][kc]
    // Total = OUT_CH * IN_CH * 9 weights
    input  logic [OUT_CH*IN_CH*9*8-1:0]  weights_flat,

    // Flattened output
    output logic [OUT_CH*32-1:0]         pixel_out_flat,
    output logic                         out_valid
);

    // ── Unpack pixel input ────────────────────────────────────
    wire signed [7:0] pixel_in [0:IN_CH-1];
    genvar gi;
    generate
        for (gi = 0; gi < IN_CH; gi++) begin : unpack_in
            assign pixel_in[gi] = pixel_in_flat[gi*8+7 : gi*8];
        end
    endgenerate

    // ── Unpack weights ────────────────────────────────────────
    // weights[oc][ic][kr][kc] at index:
    // (oc*IN_CH*9 + ic*9 + kr*3 + kc) * 8
    wire signed [7:0] w [0:OUT_CH-1][0:IN_CH-1][0:2][0:2];
    genvar goc, gic, gkr, gkc;
    generate
        for (goc = 0; goc < OUT_CH; goc++) begin : unpack_oc
            for (gic = 0; gic < IN_CH; gic++) begin : unpack_ic
                for (gkr = 0; gkr < 3; gkr++) begin : unpack_kr
                    for (gkc = 0; gkc < 3; gkc++) begin : unpack_kc
                        localparam IDX =
                            (goc*IN_CH*9 + gic*9 + gkr*3 + gkc)*8;
                        assign w[goc][gic][gkr][gkc] =
                            weights_flat[IDX+7 : IDX];
                    end
                end
            end
        end
    endgenerate

    // ── Line buffer (flat) ────────────────────────────────────
    // 3 rows x IMG_W cols x IN_CH channels x 8 bits
    reg signed [7:0] lbuf [0:2][0:IMG_W-1][0:IN_CH-1];

    // ── Counters ──────────────────────────────────────────────
    reg [7:0] in_row,  in_col;
    reg [7:0] out_row, out_col;
    reg [9:0] pix_count;
    reg [9:0] out_count;

    // ── Kernel counters ───────────────────────────────────────
    reg [1:0] kr, kc;
    reg [7:0] ic;

    // ── Accumulators ──────────────────────────────────────────
    reg signed [31:0] accum [0:OUT_CH-1];

    // ── Window pixel ──────────────────────────────────────────
    reg signed [7:0] win_pix;
    reg signed [8:0] wr_s, wc_s;

    // ── State ─────────────────────────────────────────────────
    reg [1:0] state;
    localparam S_IDLE    = 2'd0;
    localparam S_FILL    = 2'd1;
    localparam S_COMPUTE = 2'd2;
    localparam S_OUTPUT  = 2'd3;

    reg active;
    integer ii, oo;

    // ─────────────────────────────────────────────────────────
    // Input line buffer write
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active    <= 0;
            in_row    <= 0;
            in_col    <= 0;
            pix_count <= 0;
        end
        else begin
            if (start) begin
                active    <= 1;
                in_row    <= 0;
                in_col    <= 0;
                pix_count <= 0;
            end
            if (active && pixel_valid) begin
                for (ii = 0; ii < IN_CH; ii++)
                    lbuf[in_row % 3][in_col][ii] <= pixel_in[ii];

                pix_count <= pix_count + 1;

                if (in_col == IMG_W - 1) begin
                    in_col <= 0;
                    in_row <= in_row + 1;
                end
                else
                    in_col <= in_col + 1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Window pixel extraction (combinational)
    // ─────────────────────────────────────────────────────────
    always @(*) begin
        wr_s = $signed({1'b0, out_row}) + $signed({1'b0, kr})
               - $signed(PADDING);
        wc_s = $signed({1'b0, out_col}) + $signed({1'b0, kc})
               - $signed(PADDING);

        if (wr_s < 0 || wr_s >= IMG_H || wc_s < 0 || wc_s >= IMG_W)
            win_pix = 8'sd0;
        else
            win_pix = lbuf[wr_s[1:0] % 3][wc_s[2:0]][ic];
    end

    // ─────────────────────────────────────────────────────────
    // Compute state machine
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            kr        <= 0;
            kc        <= 0;
            ic        <= 0;
            out_row   <= 0;
            out_col   <= 0;
            out_count <= 0;
            out_valid <= 0;
            for (oo = 0; oo < OUT_CH; oo++)
                accum[oo] <= 0;
        end
        else begin
            out_valid <= 0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state     <= S_FILL;
                        out_row   <= 0;
                        out_col   <= 0;
                        out_count <= 0;
                        kr <= 0; kc <= 0; ic <= 0;
                        for (oo = 0; oo < OUT_CH; oo++)
                            accum[oo] <= 0;
                    end
                end

                S_FILL: begin
                    // Wait until enough pixels buffered
                    if (pix_count >= (out_row * IMG_W +
                                      out_col + IMG_W + 1)) begin
                        state <= S_COMPUTE;
                        kr <= 0; kc <= 0; ic <= 0;
                        for (oo = 0; oo < OUT_CH; oo++)
                            accum[oo] <= 0;
                    end
                end

                S_COMPUTE: begin
                    // MAC all output channels simultaneously
                    for (oo = 0; oo < OUT_CH; oo++)
                        accum[oo] <= accum[oo] +
                            $signed(win_pix) * $signed(w[oo][ic][kr][kc]);

                    // Step kernel position
                    if (kc == 2) begin
                        kc <= 0;
                        if (kr == 2) begin
                            kr <= 0;
                            if (ic == IN_CH - 1) begin
                                ic    <= 0;
                                state <= S_OUTPUT;
                            end
                            else
                                ic <= ic + 1;
                        end
                        else
                            kr <= kr + 1;
                    end
                    else
                        kc <= kc + 1;
                end

                S_OUTPUT: begin
                    out_valid <= 1;
                    out_count <= out_count + 1;

                    if (out_col == IMG_W - 1) begin
                        out_col <= 0;
                        out_row <= out_row + 1;
                    end
                    else
                        out_col <= out_col + STRIDE;

                    for (oo = 0; oo < OUT_CH; oo++)
                        accum[oo] <= 0;

                    if (out_count == IMG_H * IMG_W - 1)
                        state <= S_IDLE;
                    else begin
                        state <= S_FILL;
                        kr <= 0; kc <= 0; ic <= 0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ── Pack outputs ──────────────────────────────────────────
    genvar go;
    generate
        for (go = 0; go < OUT_CH; go++) begin : pack_out
            assign pixel_out_flat[go*32+31 : go*32] = accum[go];
        end
    endgenerate

endmodule : conv_3x3_systolic