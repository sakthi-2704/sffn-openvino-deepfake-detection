// ============================================================
// fusion_module.sv (FINAL - with S_BUILD_CONCAT fix)
//
// Purpose:
//   Combines spatial and frequency stream outputs into
//   a single fused feature vector for the classifier.
//
// Pipeline:
//   1. GAP spatial features  → [SPATIAL_CH] vector
//   2. GAP freq features     → [FREQ_CH] vector
//   3. Build concat vector   → [SPATIAL_CH + FREQ_CH]
//   4. FC layer              → [FUSED_CH] output
//   5. Output valid pulse
//
// From SFFN model:
//   Spatial output : [1, 1280, 7, 7]
//   Freq output    : [1, 64,  28, 28]
//   Fused output   : [1, 512]
// ============================================================

import sffn_params::*;

module fusion_module #(
    parameter SPATIAL_CH  = 1280,
    parameter FREQ_CH     = 64,
    parameter FUSED_CH    = 512,
    parameter SPATIAL_HW  = 7,
    parameter FREQ_HW     = 28
)(
    input  logic                                       clk,
    input  logic                                       rst_n,
    input  logic                                       start,

    // Spatial features: SPATIAL_CH * 32 bits
    input  logic [SPATIAL_CH*32-1:0]                   spatial_feat_flat,
    input  logic                                       spatial_valid,

    // Freq features: FREQ_CH * 32 bits
    input  logic [FREQ_CH*32-1:0]                      freq_feat_flat,
    input  logic                                       freq_valid,

    // FC weights: FUSED_CH * (SPATIAL_CH+FREQ_CH) * 8 bits
    input  logic [FUSED_CH*(SPATIAL_CH+FREQ_CH)*8-1:0] fc_weights_flat,

    // Output
    output logic [FUSED_CH*32-1:0]                     fused_out_flat,
    output logic                                       fused_valid,
    output logic                                       done
);

    // ── Derived parameters ────────────────────────────────────
    localparam CONCAT_CH   = SPATIAL_CH + FREQ_CH;
    localparam SPATIAL_PIX = SPATIAL_HW * SPATIAL_HW;
    localparam FREQ_PIX    = FREQ_HW    * FREQ_HW;

    // ── FSM states ────────────────────────────────────────────
    localparam S_IDLE         = 3'd0;
    localparam S_GAP_SP       = 3'd1;  // GAP spatial stream
    localparam S_GAP_FR       = 3'd2;  // GAP freq stream
    localparam S_BUILD_CONCAT = 3'd3;  // build concat vector
    localparam S_FC           = 3'd4;  // FC layer compute
    localparam S_OUTPUT       = 3'd5;  // pulse fused_valid
    localparam S_DONE         = 3'd6;  // pulse done

    reg [2:0] state;

    // ── GAP accumulators ──────────────────────────────────────
    reg signed [31:0] gap_spatial [0:SPATIAL_CH-1];
    reg signed [31:0] gap_freq    [0:FREQ_CH-1];

    // ── Concatenated vector ───────────────────────────────────
    reg signed [31:0] concat_vec  [0:CONCAT_CH-1];

    // ── FC output ─────────────────────────────────────────────
    reg signed [31:0] fc_out      [0:FUSED_CH-1];

    // ── Counters ──────────────────────────────────────────────
    reg [9:0]  sp_pix_cnt;
    reg [9:0]  fr_pix_cnt;
    reg [10:0] fc_in_cnt;

    // ── Loop variables ────────────────────────────────────────
    integer ch, oc;

    // ─────────────────────────────────────────────────────────
    // Main FSM
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sp_pix_cnt  <= '0;
            fr_pix_cnt  <= '0;
            fc_in_cnt   <= '0;
            fused_valid <= 1'b0;
            done        <= 1'b0;
            for (ch = 0; ch < SPATIAL_CH; ch++)
                gap_spatial[ch] <= 32'sd0;
            for (ch = 0; ch < FREQ_CH; ch++)
                gap_freq[ch] <= 32'sd0;
            for (ch = 0; ch < CONCAT_CH; ch++)
                concat_vec[ch] <= 32'sd0;
            for (oc = 0; oc < FUSED_CH; oc++)
                fc_out[oc] <= 32'sd0;
        end
        else begin
            fused_valid <= 1'b0;
            done        <= 1'b0;

            case (state)

                // ── Wait for start pulse ──────────────────────
                S_IDLE: begin
                    if (start) begin
                        state      <= S_GAP_SP;
                        sp_pix_cnt <= '0;
                        fr_pix_cnt <= '0;
                        fc_in_cnt  <= '0;
                        for (ch = 0; ch < SPATIAL_CH; ch++)
                            gap_spatial[ch] <= 32'sd0;
                        for (ch = 0; ch < FREQ_CH; ch++)
                            gap_freq[ch] <= 32'sd0;
                        for (ch = 0; ch < CONCAT_CH; ch++)
                            concat_vec[ch] <= 32'sd0;
                        for (oc = 0; oc < FUSED_CH; oc++)
                            fc_out[oc] <= 32'sd0;
                    end
                end

                // ── GAP Spatial ───────────────────────────────
                // Accumulate all spatial channels per pixel
                // One pixel per clock when spatial_valid=1
                S_GAP_SP: begin
                    if (spatial_valid) begin
                        for (ch = 0; ch < SPATIAL_CH; ch++)
                            gap_spatial[ch] <= gap_spatial[ch] +
                                $signed(spatial_feat_flat[
                                    ch*32 +: 32]);

                        if (sp_pix_cnt == SPATIAL_PIX - 1) begin
                            state <= S_GAP_FR;
                        end
                        else
                            sp_pix_cnt <= sp_pix_cnt + 1;
                    end
                end

                // ── GAP Freq ──────────────────────────────────
                // Accumulate all freq channels per pixel
                // One pixel per clock when freq_valid=1
                S_GAP_FR: begin
                    if (freq_valid) begin
                        for (ch = 0; ch < FREQ_CH; ch++)
                            gap_freq[ch] <= gap_freq[ch] +
                                $signed(freq_feat_flat[
                                    ch*32 +: 32]);

                        if (fr_pix_cnt == FREQ_PIX - 1) begin
                            // Last pixel received
                            // Move to BUILD_CONCAT so gap_freq
                            // is fully registered before use
                            state <= S_BUILD_CONCAT;
                        end
                        else
                            fr_pix_cnt <= fr_pix_cnt + 1;
                    end
                end

                // ── Build Concat Vector ───────────────────────
                // Wait one cycle after last freq pixel so
                // gap_freq is fully accumulated in registers
                // Then build: [gap_spatial | gap_freq]
                S_BUILD_CONCAT: begin
                    for (ch = 0; ch < SPATIAL_CH; ch++)
                        concat_vec[ch] <= gap_spatial[ch];
                    for (ch = 0; ch < FREQ_CH; ch++)
                        concat_vec[SPATIAL_CH+ch] <=
                            gap_freq[ch];
                    fc_in_cnt <= '0;
                    for (oc = 0; oc < FUSED_CH; oc++)
                        fc_out[oc] <= 32'sd0;
                    state <= S_FC;
                end

                // ── FC Layer ──────────────────────────────────
                // fc_out[oc] += concat_vec[ic] * weight[oc][ic]
                // All output channels MAC in parallel
                // One input channel per clock
                S_FC: begin
                    for (oc = 0; oc < FUSED_CH; oc++) begin
                        fc_out[oc] <= fc_out[oc] +
                            $signed(concat_vec[fc_in_cnt]) *
                            $signed(fc_weights_flat[
                                (oc*CONCAT_CH + fc_in_cnt)
                                *8 +: 8]);
                    end

                    if (fc_in_cnt == CONCAT_CH - 1) begin
                        fc_in_cnt <= '0;
                        state     <= S_OUTPUT;
                    end
                    else
                        fc_in_cnt <= fc_in_cnt + 1;
                end

                // ── Output ────────────────────────────────────
                S_OUTPUT: begin
                    fused_valid <= 1'b1;
                    state       <= S_DONE;
                end

                // ── Done ──────────────────────────────────────
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // ── Pack FC output ────────────────────────────────────────
    genvar go;
    generate
        for (go = 0; go < FUSED_CH; go++) begin : g_out
            assign fused_out_flat[go*32+31 : go*32] =
                fc_out[go];
        end
    endgenerate

endmodule : fusion_module