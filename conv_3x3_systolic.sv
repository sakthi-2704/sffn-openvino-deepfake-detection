// ============================================================
// conv_3x3_systolic.sv (v3 - ModelSim 10.5b compatible)
// ============================================================

import sffn_params::*;

module conv_3x3_systolic #(
    parameter int IN_CH   = 1,
    parameter int OUT_CH  = 1,
    parameter int IMG_H   = 4,
    parameter int IMG_W   = 4,
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

    // ── Line buffer ───────────────────────────────────────────
    logic signed [7:0] line_buf [0:2][0:IMG_W-1][0:IN_CH-1];

    // ── Input position ────────────────────────────────────────
    logic [7:0] in_row, in_col;
    logic [9:0] pix_count;

    // ── Output position ───────────────────────────────────────
    logic [7:0] out_row, out_col;
    logic [9:0] out_count;

    // ── Compute control ───────────────────────────────────────
    logic        computing;
    logic [1:0]  kr, kc;
    logic [7:0]  ic;

    // ── Accumulators ──────────────────────────────────────────
    logic signed [ACCUM_BITS-1:0] accum [0:OUT_CH-1];

    // ── Window pixel (no local vars in always_ff) ─────────────
    logic signed [7:0]  win_pix;
    logic signed [8:0]  wr_s, wc_s;  // signed row/col for boundary check

    // ── State machine states ──────────────────────────────────
    typedef enum logic [1:0] {
        S_IDLE    = 2'd0,
        S_FILL    = 2'd1,
        S_COMPUTE = 2'd2,
        S_OUTPUT  = 2'd3
    } state_t;

    state_t state;

    // ── Active flag ───────────────────────────────────────────
    logic active;

    // ─────────────────────────────────────────────────────────
    // Input: write pixels to line buffer
    // ─────────────────────────────────────────────────────────
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active    <= 1'b0;
            in_row    <= '0;
            in_col    <= '0;
            pix_count <= '0;
        end
        else begin
            if (start) begin
                active    <= 1'b1;
                in_row    <= '0;
                in_col    <= '0;
                pix_count <= '0;
            end

            if (active && pixel_valid) begin
                // Write all channels to line buffer
                for (i = 0; i < IN_CH; i++) begin
                    line_buf[in_row % 3][in_col][i] <= pixel_in[i];
                end

                pix_count <= pix_count + 1;

                if (in_col == IMG_W - 1) begin
                    in_col <= '0;
                    in_row <= in_row + 1;
                end
                else begin
                    in_col <= in_col + 1;
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Compute state machine
    // ─────────────────────────────────────────────────────────
    integer o;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            computing <= 1'b0;
            kr        <= '0;
            kc        <= '0;
            ic        <= '0;
            out_row   <= '0;
            out_col   <= '0;
            out_count <= '0;
            out_valid <= 1'b0;
            for (o = 0; o < OUT_CH; o++)
                accum[o] <= '0;
        end
        else begin
            out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state     <= S_FILL;
                        out_row   <= '0;
                        out_col   <= '0;
                        out_count <= '0;
                        kr        <= '0;
                        kc        <= '0;
                        ic        <= '0;
                        for (o = 0; o < OUT_CH; o++)
                            accum[o] <= '0;
                    end
                end

                // Wait until 3 rows are buffered
                S_FILL: begin
                    if (pix_count >= (IMG_W * 2 + out_col + 1)) begin
                        state <= S_COMPUTE;
                        kr    <= '0;
                        kc    <= '0;
                        ic    <= '0;
                        for (o = 0; o < OUT_CH; o++)
                            accum[o] <= '0;
                    end
                end

                // Compute one output pixel
                S_COMPUTE: begin
                    // Accumulate kernel position [kr][kc][ic]
                    for (o = 0; o < OUT_CH; o++) begin
                        accum[o] <= accum[o] +
                            ACCUM_BITS'(signed'(win_pix *
                                weights[o][ic][kr][kc]));
                    end

                    // Step through kernel
                    if (kc == 2) begin
                        kc <= '0;
                        if (kr == 2) begin
                            kr <= '0;
                            if (ic == IN_CH - 1) begin
                                ic    <= '0;
                                state <= S_OUTPUT;
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

                // Output pixel and advance position
                S_OUTPUT: begin
                    out_valid <= 1'b1;
                    out_count <= out_count + 1;

                    if (out_col == IMG_W - 1) begin
                        out_col <= '0;
                        out_row <= out_row + 1;
                    end
                    else begin
                        out_col <= out_col + STRIDE;
                    end

                    // Clear accumulator
                    for (o = 0; o < OUT_CH; o++)
                        accum[o] <= '0;

                    // Done with all pixels?
                    if (out_count == IMG_H * IMG_W - 1) begin
                        state <= S_IDLE;
                    end
                    else begin
                        state <= S_FILL;
                        kr    <= '0;
                        kc    <= '0;
                        ic    <= '0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ─────────────────────────────────────────────────────────
    // Window pixel extraction (combinational, no local vars)
    // ─────────────────────────────────────────────────────────
    always_comb begin
        wr_s = signed'({1'b0, out_row}) + signed'({1'b0, kr}) - PADDING;
        wc_s = signed'({1'b0, out_col}) + signed'({1'b0, kc}) - PADDING;

        if (wr_s < 0 || wr_s >= IMG_H || wc_s < 0 || wc_s >= IMG_W)
            win_pix = 8'sd0;
        else
            win_pix = line_buf[wr_s % 3][wc_s][ic];
    end

    // ── Outputs ───────────────────────────────────────────────
    genvar gv;
    generate
        for (gv = 0; gv < OUT_CH; gv++) begin : gen_out
            assign pixel_out[gv] = accum[gv];
        end
    endgenerate

endmodule : conv_3x3_systolic