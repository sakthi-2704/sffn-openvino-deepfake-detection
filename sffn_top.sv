`timescale 1ns/1ps
import sffn_params::*;

module sffn_top (
    input  logic clk,
    input  logic rst_n,
    input  logic frame_start,
    input  logic in_valid,
    input  logic [7:0] spatial_in [0:2],
    input  logic [7:0] freq_in    [0:1],
    output logic [15:0] out_data,
    output logic        out_valid,
    output logic        frame_done
);

    // ── FSM ───────────────────────────────────────────────────
    typedef enum logic [2:0] {
        IDLE,
        LOAD,
        COMPUTE,
        WAIT_CONV,    // wait for conv modules to finish
        FUSION,
        WAIT_FUSION,  // wait for fusion to finish
        DONE
    } state_t;

    state_t state;

    // ── Signals ───────────────────────────────────────────────
    logic spatial_start_pulse, freq_start_pulse;
    logic fusion_start_pulse;
    logic started_conv, started_fusion;

    logic [7:0]    spatial_pixel;
    logic [255:0]  freq_pixel;

    logic conv_rd_en;
    logic [7:0]  conv_rd_addr;
    logic [71:0] conv_weights;
    logic conv_rd_valid;

    logic [2303:0]    dw_weights;
    logic [5505023:0] fc_weights;

    logic [31:0]  spatial_out;
    logic [1023:0] freq_mid;
    logic [31:0]  freq_out;

    logic spatial_out_valid;
    logic freq_mid_valid;
    logic freq_out_valid;

    logic [40959:0] spatial_big;
    logic [2047:0]  freq_big;
    logic [16383:0] fused_out;

    logic fusion_valid;
    logic fusion_done_sig;

    // Pixel counters for done detection
    logic [7:0] sp_pix_cnt;
    logic [7:0] fr_pix_cnt;
    logic       sp_conv_done;
    logic       fr_conv_done;

    // ── FSM ───────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            started_conv   <= 1'b0;
            started_fusion <= 1'b0;
            frame_done     <= 1'b0;
            out_valid      <= 1'b0;
        end
        else begin
            frame_done <= 1'b0;
            out_valid  <= fusion_valid;

            case (state)
                IDLE: begin
                    started_conv   <= 1'b0;
                    started_fusion <= 1'b0;
                    if (frame_start)
                        state <= LOAD;
                end

                // Wait for first pixel to arrive
                LOAD: begin
                    if (in_valid)
                        state <= COMPUTE;
                end

                // Stream all pixels — stay here until all received
                COMPUTE: begin
                    if (in_valid && !started_conv)
                        started_conv <= 1'b1;
                    // Transition when both conv streams done
                    if (sp_conv_done && fr_conv_done)
                        state <= FUSION;
                end

                // Start fusion, wait for it to complete
                FUSION: begin
                    if (!started_fusion)
                        started_fusion <= 1'b1;
                    if (fusion_done_sig)
                        state <= DONE;
                end

                DONE: begin
                    frame_done <= 1'b1;
                    state      <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ── Pixel counters ────────────────────────────────────────
    // Count out_valid from spatial conv
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_pix_cnt  <= '0;
            sp_conv_done <= 1'b0;
        end
        else begin
            sp_conv_done <= 1'b0;
            if (frame_start)
                sp_pix_cnt <= '0;
            else if (spatial_out_valid) begin
                if (sp_pix_cnt == 15) begin
                    sp_pix_cnt   <= '0;
                    sp_conv_done <= 1'b1;
                    $display("[DEBUG] Spatial conv DONE");
                end
                else
                    sp_pix_cnt <= sp_pix_cnt + 1;
            end
        end
    end

    // Count out_valid from freq conv
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fr_pix_cnt  <= '0;
            fr_conv_done <= 1'b0;
        end
        else begin
            fr_conv_done <= 1'b0;
            if (frame_start)
                fr_pix_cnt <= '0;
            else if (freq_out_valid) begin
                if (fr_pix_cnt == 15) begin
                    fr_pix_cnt   <= '0;
                    fr_conv_done <= 1'b1;
                    $display("[DEBUG] Freq conv DONE");
                end
                else begin
                    fr_pix_cnt <= fr_pix_cnt + 1;
                    $display("[DEBUG] Freq pix=%0d/16", fr_pix_cnt+1);
                end
            end
        end
    end

    // ── Start pulses ──────────────────────────────────────────
    // Single cycle pulses for submodule starts
    assign spatial_start_pulse = (state == LOAD && in_valid);
    assign freq_start_pulse    = (state == LOAD && in_valid);
    assign fusion_start_pulse  = (state == FUSION && !started_fusion);

    // ── Input latch ───────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spatial_pixel <= '0;
            freq_pixel    <= '0;
        end
        else if (in_valid) begin
            spatial_pixel <= spatial_in[0];
            freq_pixel    <= '0;
        end
    end

    // ── BRAM ──────────────────────────────────────────────────
    assign conv_rd_en = (state == COMPUTE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            conv_rd_addr <= '0;
        else if (conv_rd_en)
            conv_rd_addr <= conv_rd_addr + 1;
    end

    weight_bram u_conv_bram (
        .clk      (clk),
        .rst_n    (rst_n),
        .layer_sel(2'd0),
        .rd_en    (conv_rd_en),
        .rd_addr  (conv_rd_addr),
        .rd_data  (conv_weights),
        .rd_valid (conv_rd_valid)
    );

    assign dw_weights = '0;
    assign fc_weights = '0;

    // ── Spatial Conv ──────────────────────────────────────────
    conv_3x3_systolic u_spatial (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (spatial_start_pulse),
        .pixel_in_flat (spatial_pixel),
        .pixel_valid   (in_valid),
        .weights_flat  (conv_weights),
        .pixel_out_flat(spatial_out),
        .out_valid     (spatial_out_valid)
    );

    // ── Depthwise Conv ────────────────────────────────────────
    depthwise_filter u_freq0 (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (freq_start_pulse),
        .pixel_in_flat (freq_pixel),
        .pixel_valid   (in_valid),
        .weights_flat  (dw_weights),
        .pixel_out_flat(freq_mid),
        .out_valid     (freq_mid_valid)
    );

    // ── Second Conv ───────────────────────────────────────────
    // Start when first pixel from depthwise arrives
    logic freq1_start;
    logic freq1_started;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            freq1_start   <= 1'b0;
            freq1_started <= 1'b0;
        end
        else begin
            freq1_start <= 1'b0;
            if (frame_start)
                freq1_started <= 1'b0;
            else if (freq_mid_valid && !freq1_started) begin
                freq1_start   <= 1'b1;
                freq1_started <= 1'b1;
            end
        end
    end

    // Delay freq_mid by 1 cycle for timing
    logic [1023:0] freq_mid_d1;
    logic          freq_mid_valid_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            freq_mid_d1       <= '0;
            freq_mid_valid_d1 <= 1'b0;
        end
        else begin
            freq_mid_d1       <= freq_mid;
            freq_mid_valid_d1 <= freq_mid_valid;
        end
    end

    conv_3x3_systolic u_freq1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (freq1_start),
        .pixel_in_flat (freq_mid_d1[7:0]),
        .pixel_valid   (freq_mid_valid_d1),
        .weights_flat  (conv_weights),
        .pixel_out_flat(freq_out),
        .out_valid     (freq_out_valid)
    );

    // ── Feature packing ───────────────────────────────────────
    always_comb begin
        spatial_big       = '0;
        freq_big          = '0;
        spatial_big[31:0] = spatial_out;
        freq_big[31:0]    = freq_out;
    end

    // ── Fusion ────────────────────────────────────────────────
    fusion_module u_fusion (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (fusion_start_pulse),
        .spatial_feat_flat(spatial_big),
        .spatial_valid    (spatial_out_valid),
        .freq_feat_flat   (freq_big),
        .freq_valid       (freq_out_valid),
        .fc_weights_flat  (fc_weights),
        .fused_out_flat   (fused_out),
        .fused_valid      (fusion_valid),
        .done             (fusion_done_sig)
    );

    // ── Output ────────────────────────────────────────────────
    assign out_data = fused_out[15:0];

endmodule