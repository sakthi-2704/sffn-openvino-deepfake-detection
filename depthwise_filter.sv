// ============================================================
// depthwise_filter.sv
//
// Depthwise Convolution Engine
// Handles 13 DWConv layers in SFFN:
//
//   Layer  Channels  Kernel
//   [001]    32       3x3
//   [006]    96       3x3
//   [011]   144       3x3
//   [016]   144       5x5
//   [021]   240       5x5
//   [026]   240       3x3
//   [031]   480       3x3
//   [036]   480       3x3
//   [041]   480       5x5
//   [046]   672       5x5
//   [051]   672       5x5
//   [056]   672       5x5
//   [061]  1152       5x5
//
// Key difference from standard conv:
//   Standard conv : out[oc] = sum over ALL input channels
//   Depthwise conv: out[ch] = filter[ch] * input[ch] ONLY
//                  groups = channels (each channel independent)
//
// Hardware advantage:
//   Each channel has its OWN dedicated filter
//   All channels compute IN PARALLEL
//   No inter-channel data dependencies
//   Minimal weight storage (CH x K x K vs CH x CH x K x K)
//
// Architecture:
//   - Full image buffer (same as 3x3 systolic)
//   - Configurable kernel: 3x3 or 5x5 via KERNEL_SIZE param
//   - One MAC per clock per channel (all channels parallel)
//   - Output register for stable valid signal
// ============================================================

import sffn_params::*;

module depthwise_filter #(
    parameter CHANNELS    = 32,    // number of channels (in=out)
    parameter KERNEL_SIZE = 3,     // 3 or 5
    parameter IMG_H       = 224,   // input height
    parameter IMG_W       = 224,   // input width
    parameter STRIDE      = 1,     // stride
    parameter PADDING     = 1      // 1 for 3x3, 2 for 5x5
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          start,

    // Flat pixel input: CHANNELS * 8 bits
    input  logic [CHANNELS*8-1:0]         pixel_in_flat,
    input  logic                          pixel_valid,

    // Flat weights: CHANNELS * KERNEL_SIZE * KERNEL_SIZE * 8
    // Order: [ch][kr][kc] flattened
    input  logic [CHANNELS*KERNEL_SIZE*KERNEL_SIZE*8-1:0]
                                          weights_flat,

    // Flat output: CHANNELS * 32 bits
    output logic [CHANNELS*32-1:0]        pixel_out_flat,
    output logic                          out_valid
);

    // ── Derived parameters ────────────────────────────────────
    localparam KS      = KERNEL_SIZE;
    localparam KS2     = KS * KS;        // kernel area
    localparam HALF_K  = KS / 2;         // = PADDING

    // ── FSM states ────────────────────────────────────────────
    localparam S_IDLE    = 2'd0;
    localparam S_RECV    = 2'd1;
    localparam S_COMPUTE = 2'd2;
    localparam S_OUTPUT  = 2'd3;

    reg [1:0] state;

    // ── Full image buffer ─────────────────────────────────────
    // img_buf[row][col][channel]
    reg signed [7:0] img_buf [0:IMG_H-1]
                             [0:IMG_W-1]
                             [0:CHANNELS-1];

    // ── Input tracking ────────────────────────────────────────
    reg [7:0] in_row, in_col;

    // ── Output tracking ───────────────────────────────────────
    reg [7:0] out_row, out_col;
    reg [9:0] out_count;

    // ── Kernel counters ───────────────────────────────────────
    reg [2:0] kr;    // kernel row 0..KS-1
    reg [2:0] kc;    // kernel col 0..KS-1

    // ── Accumulators (one per channel — all parallel) ─────────
    reg signed [31:0] accum   [0:CHANNELS-1];
    reg signed [31:0] out_reg [0:CHANNELS-1];

    // ── Window and weight signals ─────────────────────────────
    reg signed [8:0] wr_s, wc_s;
    reg signed [7:0] win_pix  [0:CHANNELS-1];
    reg signed [7:0] w_val    [0:CHANNELS-1];
    reg signed [31:0] product [0:CHANNELS-1];

    // ── Loop variables ────────────────────────────────────────
    integer ch;
    integer ii;
    integer lch;

    // ─────────────────────────────────────────────────────────
    // COMBINATIONAL: window pixel extraction for all channels
    // ─────────────────────────────────────────────────────────
    always @(*) begin
        wr_s = $signed({1'b0, out_row}) +
               $signed({1'b0, kr})      -
               $signed(9'd0 + PADDING);
        wc_s = $signed({1'b0, out_col}) +
               $signed({1'b0, kc})      -
               $signed(9'd0 + PADDING);

        for (ch = 0; ch < CHANNELS; ch++) begin
            // Zero padding at borders
            if (wr_s < 0 || wr_s >= IMG_H ||
                wc_s < 0 || wc_s >= IMG_W)
                win_pix[ch] = 8'sd0;
            else
                win_pix[ch] =
                    img_buf[wr_s[2:0]][wc_s[2:0]][ch];

            // Weight for this channel at position [kr][kc]
            // Index = (ch * KS2 + kr * KS + kc) * 8
            w_val[ch] = $signed(
                weights_flat[
                    (ch*KS2 + kr*KS + kc)*8 +: 8
                ]
            );

            // Product
            product[ch] = $signed(win_pix[ch]) *
                          $signed(w_val[ch]);
        end
    end

    // ─────────────────────────────────────────────────────────
    // SEQUENTIAL: FSM
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            in_row    <= 8'd0;
            in_col    <= 8'd0;
            out_row   <= 8'd0;
            out_col   <= 8'd0;
            out_count <= 10'd0;
            kr        <= 3'd0;
            kc        <= 3'd0;
            out_valid <= 1'b0;
            for (lch = 0; lch < CHANNELS; lch++) begin
                accum  [lch] <= 32'sd0;
                out_reg[lch] <= 32'sd0;
            end
        end
        else begin
            out_valid <= 1'b0;

            case (state)

                // ── Wait for start ────────────────────────────
                S_IDLE: begin
                    if (start) begin
                        state     <= S_RECV;
                        in_row    <= 8'd0;
                        in_col    <= 8'd0;
                        out_row   <= 8'd0;
                        out_col   <= 8'd0;
                        out_count <= 10'd0;
                        kr        <= 3'd0;
                        kc        <= 3'd0;
                        for (lch = 0; lch < CHANNELS; lch++) begin
                            accum  [lch] <= 32'sd0;
                            out_reg[lch] <= 32'sd0;
                        end
                    end
                end

                // ── Receive all pixels into buffer ────────────
                S_RECV: begin
                    if (pixel_valid) begin
                        // Write all channels simultaneously
                        for (ii = 0; ii < CHANNELS; ii++)
                            img_buf[in_row][in_col][ii] <=
                                $signed(pixel_in_flat[ii*8+:8]);

                        if (in_col == IMG_W - 1) begin
                            in_col <= 8'd0;
                            if (in_row == IMG_H - 1) begin
                                // All pixels received
                                state  <= S_COMPUTE;
                                in_row <= 8'd0;
                                kr     <= 3'd0;
                                kc     <= 3'd0;
                                for (lch = 0; lch < CHANNELS; lch++)
                                    accum[lch] <= 32'sd0;
                            end
                            else
                                in_row <= in_row + 8'd1;
                        end
                        else
                            in_col <= in_col + 8'd1;
                    end
                end

                // ── Compute: one MAC per clock all channels ───
                // ALL channels accumulate simultaneously
                // This is the key FPGA efficiency advantage
                S_COMPUTE: begin
                    // MAC all channels in parallel
                    for (lch = 0; lch < CHANNELS; lch++)
                        accum[lch] <= accum[lch] + product[lch];

                    // Advance kernel position
                    if (kc == KS - 1) begin
                        kc <= 3'd0;
                        if (kr == KS - 1) begin
                            // All kernel positions done
                            kr <= 3'd0;

                            // Capture to output register
                            // BEFORE clearing accum
                            for (lch = 0; lch < CHANNELS; lch++)
                                out_reg[lch] <= accum[lch] +
                                               product[lch];

                            state <= S_OUTPUT;
                        end
                        else
                            kr <= kr + 3'd1;
                    end
                    else
                        kc <= kc + 3'd1;
                end

                // ── Output: pulse valid, advance position ─────
                S_OUTPUT: begin
                    out_valid <= 1'b1;
                    out_count <= out_count + 10'd1;

                    // Advance output position
                    if (out_col == IMG_W - 1) begin
                        out_col <= 8'd0;
                        out_row <= out_row + 8'd1;
                    end
                    else
                        out_col <= out_col + STRIDE;

                    // Clear accumulator for next pixel
                    for (lch = 0; lch < CHANNELS; lch++)
                        accum[lch] <= 32'sd0;

                    // All pixels done?
                    if (out_row == IMG_H - 1 &&
                        out_col == IMG_W - 1) begin
                        state <= S_IDLE;
                    end
                    else begin
                        state <= S_COMPUTE;
                        kr    <= 3'd0;
                        kc    <= 3'd0;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // ── Pack outputs ──────────────────────────────────────────
    genvar go;
    generate
        for (go = 0; go < CHANNELS; go++) begin : g_out
            assign pixel_out_flat[go*32+31 : go*32] =
                out_reg[go];
        end
    endgenerate

endmodule : depthwise_filter