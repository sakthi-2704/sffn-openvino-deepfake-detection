// ============================================================
// conv_1x1_engine.sv
// 1x1 Pointwise Convolution Engine
//
// What 1x1 conv does:
//   For each pixel position (h,w):
//     For each output channel (oc):
//       out[oc,h,w] = sum over ic of (in[ic,h,w] * weight[oc,ic])
//
// Since kernel = 1x1, no sliding window needed.
// Just a channel-wise dot product at each pixel.
//
// Architecture:
//   - 8 parallel MAC units (processes 8 output channels at once)
//   - Accumulates over all input channels
//   - Configurable in/out channels via parameters
//
// From our layer analysis:
//   Max out_ch = 1152
//   Max in_ch  = 192
//   All weights = INT8
// ============================================================

import sffn_params::*;

module conv_1x1_engine #(
    parameter int IN_CH      = 32,    // input channels
    parameter int OUT_CH     = 64,    // output channels
    parameter int PARALLELISM = 8     // MAC units running in parallel
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,      // pulse to start conv
    
    // Input feature map (one pixel at a time, all channels)
    input  logic signed [7:0]            feat_in  [0:IN_CH-1],
    
    // Weights (OUT_CH x IN_CH, loaded from BRAM)
    input  logic signed [7:0]            weights  [0:OUT_CH-1][0:IN_CH-1],
    
    // Output
    output logic signed [ACCUM_BITS-1:0] feat_out [0:OUT_CH-1],
    output logic                         valid_out  // HIGH when output ready
);

    // ── State machine ─────────────────────────────────────────
    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        COMPUTE = 2'b01,
        OUTPUT  = 2'b10
    } state_t;

    state_t state;

    // ── Internal signals ──────────────────────────────────────
    // Accumulator for each output channel
    logic signed [ACCUM_BITS-1:0] accum [0:OUT_CH-1];

    // Input channel counter
    logic [$clog2(IN_CH)-1:0] ic_cnt;

    // MAC enable
    logic mac_en;

    // ── State machine controller ──────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            ic_cnt    <= '0;
            valid_out <= 1'b0;
            mac_en    <= 1'b0;
        end
        else begin
            case (state)
                // Wait for start pulse
                IDLE: begin
                    valid_out <= 1'b0;
                    ic_cnt    <= '0;
                    if (start) begin
                        state  <= COMPUTE;
                        mac_en <= 1'b1;
                    end
                end

                // Accumulate over all input channels
                COMPUTE: begin
                    if (ic_cnt == IN_CH - 1) begin
                        state     <= OUTPUT;
                        mac_en    <= 1'b0;
                        ic_cnt    <= '0;
                    end
                    else begin
                        ic_cnt <= ic_cnt + 1;
                    end
                end

                // Output is ready
                OUTPUT: begin
                    valid_out <= 1'b1;
                    state     <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ── Accumulation logic ────────────────────────────────────
    // For each output channel, accumulate:
    //   accum[oc] += feat_in[ic] * weights[oc][ic]
    // ic_cnt steps through all input channels

    genvar oc;
    generate
        for (oc = 0; oc < OUT_CH; oc++) begin : gen_accum
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    accum[oc] <= '0;
                end
                else if (start) begin
                    // Clear accumulator on new pixel
                    accum[oc] <= '0;
                end
                else if (mac_en) begin
                    // Accumulate: signed 8x8 = 16-bit, sign-extend to 32-bit
                    accum[oc] <= accum[oc] +
                        ACCUM_BITS'(signed'(
                            feat_in[ic_cnt] * weights[oc][ic_cnt]
                        ));
                end
            end

            // Connect accumulator to output
            assign feat_out[oc] = accum[oc];
        end
    endgenerate

endmodule : conv_1x1_engine