// ============================================================
// conv_3x3_systolic.sv
// 3x3 Convolution using Systolic Array Architecture
//
// Handles 4 layers in SFFN:
//   [000] stem conv     : in=3,   out=32,  stride=2
//   [081] freq stream 0 : in=2,   out=32,  stride=1
//   [082] freq stream 1 : in=32,  out=64,  stride=1
//   [083] recon head    : in=128, out=2,   stride=1
//
// How it works:
//   1. Line buffer stores 3 rows of input
//   2. 3x3 window slides across input feature map
//   3. 3x3 = 9 MAC units compute one output pixel per pass
//   4. Accumulates over all input channels
//
// Architecture:
//   ┌─────────────────────────────┐
//   │  Input → Line Buffer        │
//   │          ↓                  │
//   │  3x3 Window Extractor       │
//   │          ↓                  │
//   │  9 MAC Units (Systolic)     │
//   │          ↓                  │
//   │  Accumulator → Output       │
//   └─────────────────────────────┘
// ============================================================

import sffn_params::*;

module conv_3x3_systolic #(
    parameter int IN_CH     = 3,      // input channels
    parameter int OUT_CH    = 32,     // output channels
    parameter int IMG_H     = 224,    // input height
    parameter int IMG_W     = 224,    // input width
    parameter int STRIDE    = 1,      // stride (1 or 2)
    parameter int PADDING   = 1       // zero padding (keep size)
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          start,

    // Input pixel stream (one pixel per clock, all channels)
    input  logic signed [7:0]             pixel_in  [0:IN_CH-1],
    input  logic                          pixel_valid,  // pixel_in is valid

    // Weights: [out_ch][in_ch][3][3]
    input  logic signed [7:0]             weights [0:OUT_CH-1]
                                                   [0:IN_CH-1]
                                                   [0:2][0:2],

    // Output
    output logic signed [ACCUM_BITS-1:0]  pixel_out [0:OUT_CH-1],
    output logic                          out_valid
);

    // ── Derived parameters ────────────────────────────────────
    localparam OUT_H = (IMG_H + 2*PADDING - 3) / STRIDE + 1;
    localparam OUT_W = (IMG_W + 2*PADDING - 3) / STRIDE + 1;

    // ── Line buffers ──────────────────────────────────────────
    // Store 3 rows of input for sliding window
    // line_buf[row][col][channel]
    logic signed [7:0] line_buf [0:2][0:IMG_W+1][0:IN_CH-1];

    // ── 3x3 window ────────────────────────────────────────────
    // Extracted 3x3 patch for current position
    logic signed [7:0] window [0:2][0:2][0:IN_CH-1];

    // ── Position counters ─────────────────────────────────────
    logic [$clog2(IMG_H+2)-1:0] row_cnt;  // current row
    logic [$clog2(IMG_W+2)-1:0] col_cnt;  // current col
    logic [$clog2(IN_CH)-1:0]   ic_cnt;   // input channel counter

    // ── Accumulators ──────────────────────────────────────────
    logic signed [ACCUM_BITS-1:0] accum [0:OUT_CH-1];

    // ── State machine ─────────────────────────────────────────
    typedef enum logic [2:0] {
        IDLE      = 3'b000,
        FILL_BUF  = 3'b001,   // fill line buffer
        COMPUTE   = 3'b010,   // compute 3x3 conv
        ACC_IC    = 3'b011,   // accumulate input channels
        OUT_PIXEL = 3'b100    // output result
    } state_t;

    state_t state;

    // ── Kernel position counters (for 9 MAC ops) ──────────────
    logic [1:0] kr, kc;  // kernel row, col (0,1,2)
    logic       mac_en;

    // ── State machine ─────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            row_cnt <= '0;
            col_cnt <= '0;
            ic_cnt  <= '0;
            kr      <= '0;
            kc      <= '0;
            mac_en  <= 1'b0;
            out_valid <= 1'b0;
        end
        else begin
            case (state)

                IDLE: begin
                    out_valid <= 1'b0;
                    if (start) begin
                        state   <= FILL_BUF;
                        row_cnt <= '0;
                        col_cnt <= '0;
                    end
                end

                // Fill line buffer with incoming pixels
                FILL_BUF: begin
                    if (pixel_valid) begin
                        // Shift rows when col wraps
                        if (col_cnt == IMG_W - 1) begin
                            col_cnt <= '0;
                            row_cnt <= row_cnt + 1;
                        end
                        else begin
                            col_cnt <= col_cnt + 1;
                        end

                        // Have at least 3 rows? Start computing
                        if (row_cnt >= 2 && col_cnt >= 2) begin
                            state <= COMPUTE;
                        end
                    end
                end

                // Extract 3x3 window and start MAC
                COMPUTE: begin
                    ic_cnt <= '0;
                    kr     <= '0;
                    kc     <= '0;
                    mac_en <= 1'b1;
                    state  <= ACC_IC;
                end

                // Accumulate all kernel positions and input channels
                ACC_IC: begin
                    // Step through kernel positions
                    if (kc == 2) begin
                        kc <= '0;
                        if (kr == 2) begin
                            kr <= '0;
                            // Done with one input channel
                            if (ic_cnt == IN_CH - 1) begin
                                mac_en <= 1'b0;
                                state  <= OUT_PIXEL;
                            end
                            else begin
                                ic_cnt <= ic_cnt + 1;
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

                // Output pixel result
                OUT_PIXEL: begin
                    out_valid <= 1'b1;
                    state     <= FILL_BUF;  // ready for next pixel
                end

                default: state <= IDLE;

            endcase
        end
    end

    // ── Line buffer write ─────────────────────────────────────
    // Write incoming pixels into circular line buffer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear line buffer
        end
        else if (pixel_valid) begin
            // Write to current row position
            line_buf[row_cnt % 3][col_cnt] <= pixel_in;
        end
    end

    // ── Window extraction ─────────────────────────────────────
    // Extract 3x3 neighborhood from line buffer
    genvar gr, gc;
    generate
        for (gr = 0; gr < 3; gr++) begin : gen_wr
            for (gc = 0; gc < 3; gc++) begin : gen_wc
                always_comb begin
                    // Handle zero padding at borders
                    if ((row_cnt + gr < PADDING) ||
                        (row_cnt + gr >= IMG_H + PADDING) ||
                        (col_cnt + gc < PADDING) ||
                        (col_cnt + gc >= IMG_W + PADDING))
                        window[gr][gc] = '{default: 8'sd0};
                    else
                        window[gr][gc] =
                            line_buf[(row_cnt + gr) % 3]
                                    [col_cnt + gc - PADDING];
                end
            end
        end
    endgenerate

    // ── MAC accumulation ──────────────────────────────────────
    // For each output channel accumulate:
    //   accum[oc] += window[kr][kc][ic] * weights[oc][ic][kr][kc]
    genvar oc;
    generate
        for (oc = 0; oc < OUT_CH; oc++) begin : gen_oc
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    accum[oc] <= '0;
                end
                else if (state == COMPUTE) begin
                    // Clear accumulator for new pixel
                    accum[oc] <= '0;
                end
                else if (mac_en) begin
                    // Accumulate kernel position [kr][kc] for channel ic
                    accum[oc] <= accum[oc] +
                        ACCUM_BITS'(signed'(
                            window[kr][kc][ic_cnt] *
                            weights[oc][ic_cnt][kr][kc]
                        ));
                end
            end

            // Connect to output
            assign pixel_out[oc] = accum[oc];
        end
    endgenerate

endmodule : conv_3x3_systolic