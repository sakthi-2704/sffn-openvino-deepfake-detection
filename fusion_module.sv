// ============================================================
// fusion_module.sv (FINAL v2 - with gap_sp_done signal)
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
    input  logic [SPATIAL_CH*32-1:0]                   spatial_feat_flat,
    input  logic                                       spatial_valid,
    input  logic [FREQ_CH*32-1:0]                      freq_feat_flat,
    input  logic                                       freq_valid,
    input  logic [FUSED_CH*(SPATIAL_CH+FREQ_CH)*8-1:0] fc_weights_flat,
    output logic [FUSED_CH*32-1:0]                     fused_out_flat,
    output logic                                       fused_valid,
    output logic                                       done,
    output logic                                       gap_sp_done  // NEW
);

    localparam CONCAT_CH   = SPATIAL_CH + FREQ_CH;
    localparam SPATIAL_PIX = SPATIAL_HW * SPATIAL_HW;
    localparam FREQ_PIX    = FREQ_HW    * FREQ_HW;

    localparam S_IDLE         = 3'd0;
    localparam S_GAP_SP       = 3'd1;
    localparam S_GAP_FR       = 3'd2;
    localparam S_BUILD_CONCAT = 3'd3;
    localparam S_FC           = 3'd4;
    localparam S_OUTPUT       = 3'd5;
    localparam S_DONE         = 3'd6;

    reg [2:0] state;

    reg signed [31:0] gap_spatial [0:SPATIAL_CH-1];
    reg signed [31:0] gap_freq    [0:FREQ_CH-1];
    reg signed [31:0] concat_vec  [0:CONCAT_CH-1];
    reg signed [31:0] fc_out      [0:FUSED_CH-1];

    reg [9:0]  sp_pix_cnt;
    reg [9:0]  fr_pix_cnt;
    reg [10:0] fc_in_cnt;

    integer ch, oc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sp_pix_cnt  <= '0;
            fr_pix_cnt  <= '0;
            fc_in_cnt   <= '0;
            fused_valid <= 1'b0;
            done        <= 1'b0;
            gap_sp_done <= 1'b0;
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
            gap_sp_done <= 1'b0;  // default deassert

            case (state)

                S_IDLE: begin
                    if (start) begin
                        $display("[FUSION] start received → S_GAP_SP");
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

                S_GAP_SP: begin
                    if (spatial_valid) begin
                        $display("[FUSION] GAP_SP pix=%0d/%0d",
                                  sp_pix_cnt, SPATIAL_PIX-1);
                        for (ch = 0; ch < SPATIAL_CH; ch++)
                            gap_spatial[ch] <= gap_spatial[ch] +
                                $signed(spatial_feat_flat[ch*32 +: 32]);

                        if (sp_pix_cnt == SPATIAL_PIX - 1) begin
                            $display("[FUSION] GAP_SP done → S_GAP_FR");
                            gap_sp_done <= 1'b1;  // pulse to trigger freq replay
                            state       <= S_GAP_FR;
                        end
                        else
                            sp_pix_cnt <= sp_pix_cnt + 1;
                    end
                end

                S_GAP_FR: begin
                    if (freq_valid) begin
                        $display("[FUSION] GAP_FR pix=%0d/%0d",
                                  fr_pix_cnt, FREQ_PIX-1);
                        for (ch = 0; ch < FREQ_CH; ch++)
                            gap_freq[ch] <= gap_freq[ch] +
                                $signed(freq_feat_flat[ch*32 +: 32]);

                        if (fr_pix_cnt == FREQ_PIX - 1) begin
                            $display("[FUSION] GAP_FR done → S_BUILD_CONCAT");
                            state <= S_BUILD_CONCAT;
                        end
                        else
                            fr_pix_cnt <= fr_pix_cnt + 1;
                    end
                end

                S_BUILD_CONCAT: begin
                    $display("[FUSION] BUILD_CONCAT → S_FC");
                    for (ch = 0; ch < SPATIAL_CH; ch++)
                        concat_vec[ch] <= gap_spatial[ch];
                    for (ch = 0; ch < FREQ_CH; ch++)
                        concat_vec[SPATIAL_CH+ch] <= gap_freq[ch];
                    fc_in_cnt <= '0;
                    for (oc = 0; oc < FUSED_CH; oc++)
                        fc_out[oc] <= 32'sd0;
                    state <= S_FC;
                end

                S_FC: begin
                    if (fc_in_cnt == 0)
                        $display("[FUSION] FC started CONCAT_CH=%0d",
                                  CONCAT_CH);
                    for (oc = 0; oc < FUSED_CH; oc++) begin
                        fc_out[oc] <= fc_out[oc] +
                            $signed(concat_vec[fc_in_cnt]) *
                            $signed(fc_weights_flat[
                                (oc*CONCAT_CH + fc_in_cnt)*8 +: 8]);
                    end
                    if (fc_in_cnt == CONCAT_CH - 1) begin
                        $display("[FUSION] FC done → S_OUTPUT");
                        fc_in_cnt <= '0;
                        state     <= S_OUTPUT;
                    end
                    else
                        fc_in_cnt <= fc_in_cnt + 1;
                end

                S_OUTPUT: begin
                    $display("[FUSION] OUTPUT → S_DONE");
                    fused_valid <= 1'b1;
                    state       <= S_DONE;
                end

                S_DONE: begin
                    $display("[FUSION] DONE");
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    genvar go;
    generate
        for (go = 0; go < FUSED_CH; go++) begin : g_out
            assign fused_out_flat[go*32+31 : go*32] = fc_out[go];
        end
    endgenerate

endmodule : fusion_module