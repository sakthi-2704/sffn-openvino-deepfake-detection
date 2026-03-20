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

    // ── Parameters ────────────────────────────────────────────
    localparam IMG_H     = 4;
    localparam IMG_W     = 4;
    localparam TOTAL_PIX = IMG_H * IMG_W;  // 16

    // ── Weight bus sizes ──────────────────────────────────────
    localparam STEM_W_BITS  = 3  * 32 * 9 * 8;   // 6912
    localparam FREQ1_W_BITS = 2  * 32 * 9 * 8;   // 4608
    localparam DW_W_BITS    = 2  * 1  * 9 * 8;   // 144
    localparam FC_W_BITS    = 512 * (1280+64) * 8;

    // ── FSM ───────────────────────────────────────────────────
    typedef enum logic [2:0] {
        S_IDLE,
        S_LOAD,
        S_WAIT,
        S_FUSION,
        S_DONE
    } state_t;

    state_t state;

    // ── Control signals ───────────────────────────────────────
    logic fusion_start;
    logic started;
    logic pixels_sent;
    logic [4:0] pix_cnt;

    // ── Conv done signals ─────────────────────────────────────
    logic [4:0] sp_out_cnt;
    logic [4:0] fr_out_cnt;
    logic       sp_conv_done;
    logic       fr_conv_done;
    logic       sp_done_latch;
    logic       fr_done_latch;
    logic       both_conv_done;

    // ── Flat inputs ───────────────────────────────────────────
    logic [23:0] spatial_flat;
    logic [15:0] freq_flat;

    // ── Conv outputs ──────────────────────────────────────────
    logic [32*32-1:0]  spatial_out_flat;
    logic              spatial_out_valid;

    logic [2*32-1:0]   dw_out_flat;
    logic              dw_out_valid;

    logic              freq1_start;
    logic              freq1_started;
    logic [2*32-1:0]   dw_out_d1;
    logic              dw_out_valid_d1;
    logic [32*32-1:0]  freq_out_flat;
    logic              freq_out_valid;

    // ── Fusion signals ────────────────────────────────────────
    logic [1280*32-1:0]   spatial_big;
    logic [64*32-1:0]     freq_big;
    logic [FC_W_BITS-1:0] fc_weights;
    logic [512*32-1:0]    fused_out;
    logic                 fusion_valid;
    logic                 fusion_done_sig;

    // ── BRAM signals ──────────────────────────────────────────
    logic [6:0]  bram_layer_sel;
    logic        bram_rd_en;
    logic [19:0] bram_rd_addr;
    logic [7:0]  bram_rd_data;
    logic        bram_rd_valid;

    // ── Weight buses ──────────────────────────────────────────
    logic [STEM_W_BITS-1:0]  stem_weights;
    logic [FREQ1_W_BITS-1:0] freq1_weights;
    logic [DW_W_BITS-1:0]    dw_weights;

    assign stem_weights  = '0;
    assign freq1_weights = '0;
    assign dw_weights    = '0;
    assign fc_weights    = '0;

    // ── Pack flat inputs ──────────────────────────────────────
    assign spatial_flat = {spatial_in[2], spatial_in[1], spatial_in[0]};
    assign freq_flat    = {freq_in[1], freq_in[0]};

    // ─────────────────────────────────────────────────────────
    // Pixel counter
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_cnt     <= '0;
            started     <= 1'b0;
            pixels_sent <= 1'b0;
        end
        else begin
            if (frame_start) begin
                pix_cnt     <= '0;
                started     <= 1'b0;
                pixels_sent <= 1'b0;
            end
            else if (in_valid) begin
                started <= 1'b1;
                if (pix_cnt == TOTAL_PIX - 1) begin
                    pix_cnt     <= '0;
                    pixels_sent <= 1'b1;
                end
                else
                    pix_cnt <= pix_cnt + 1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // FSM
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            frame_done   <= 1'b0;
            out_valid    <= 1'b0;
            fusion_start <= 1'b0;
        end
        else begin
            frame_done   <= 1'b0;
            out_valid    <= fusion_valid;
            fusion_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (frame_start) begin
                        state <= S_LOAD;
                        $display("[DEBUG] FSM: IDLE→LOAD");
                    end
                end

                S_LOAD: begin
                    if (pixels_sent) begin
                        state <= S_WAIT;
                        $display("[DEBUG] FSM: LOAD→WAIT");
                    end
                end

                S_WAIT: begin
                    if (both_conv_done) begin
                        state        <= S_FUSION;
                        fusion_start <= 1'b1;
                        $display("[DEBUG] FSM: WAIT→FUSION");
                    end
                end

                S_FUSION: begin
                    if (fusion_done_sig) begin
                        state <= S_DONE;
                        $display("[DEBUG] FSM: FUSION→DONE");
                    end
                end

                S_DONE: begin
                    frame_done <= 1'b1;
                    state      <= S_IDLE;
                    $display("[DEBUG] FSM: DONE frame_done=1");
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ─────────────────────────────────────────────────────────
    // Spatial done detector
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_out_cnt   <= '0;
            sp_conv_done <= 1'b0;
        end
        else begin
            sp_conv_done <= 1'b0;
            if (frame_start)
                sp_out_cnt <= '0;
            else if (spatial_out_valid) begin
                $display("[DEBUG] Spatial out_valid pix=%0d",
                          sp_out_cnt);
                if (sp_out_cnt == TOTAL_PIX - 1) begin
                    sp_out_cnt   <= '0;
                    sp_conv_done <= 1'b1;
                    $display("[DEBUG] Spatial conv DONE");
                end
                else
                    sp_out_cnt <= sp_out_cnt + 1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Freq done detector
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fr_out_cnt   <= '0;
            fr_conv_done <= 1'b0;
        end
        else begin
            fr_conv_done <= 1'b0;
            if (frame_start)
                fr_out_cnt <= '0;
            else if (freq_out_valid) begin
                $display("[DEBUG] Freq out_valid pix=%0d",
                          fr_out_cnt);
                if (fr_out_cnt == TOTAL_PIX - 1) begin
                    fr_out_cnt   <= '0;
                    fr_conv_done <= 1'b1;
                    $display("[DEBUG] Freq conv DONE");
                end
                else
                    fr_out_cnt <= fr_out_cnt + 1;
            end
        end
    end

    // ── Done latches ──────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_done_latch <= 1'b0;
            fr_done_latch <= 1'b0;
        end
        else begin
            if (frame_start) begin
                sp_done_latch <= 1'b0;
                fr_done_latch <= 1'b0;
            end
            else begin
                if (sp_conv_done) sp_done_latch <= 1'b1;
                if (fr_conv_done) fr_done_latch <= 1'b1;
            end
        end
    end

    assign both_conv_done = sp_done_latch && fr_done_latch;

    // ── Debug monitors ────────────────────────────────────────
    always @(posedge dw_out_valid)
        $display("[DEBUG] DW out_valid fired at %0t", $time);

    always @(posedge freq1_start)
        $display("[DEBUG] freq1_start fired at %0t", $time);

    always @(posedge freq_out_valid)
        $display("[DEBUG] freq_out_valid fired at %0t", $time);

    // ─────────────────────────────────────────────────────────
    // BRAM
    // ─────────────────────────────────────────────────────────
    assign bram_layer_sel = '0;
    assign bram_rd_en     = 1'b0;
    assign bram_rd_addr   = '0;

    weight_bram u_conv_bram (
        .clk      (clk),
        .rst_n    (rst_n),
        .layer_sel(bram_layer_sel),
        .rd_en    (bram_rd_en),
        .rd_addr  (bram_rd_addr),
        .rd_data  (bram_rd_data),
        .rd_valid (bram_rd_valid)
    );

    // ─────────────────────────────────────────────────────────
    // Spatial Conv (stem)
    // IN=3, OUT=32, 3x3
    // ─────────────────────────────────────────────────────────
    conv_3x3_systolic #(
        .IN_CH   (3),
        .OUT_CH  (32),
        .IMG_H   (IMG_H),
        .IMG_W   (IMG_W),
        .STRIDE  (1),
        .PADDING (1)
    ) u_spatial (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (frame_start),
        .pixel_in_flat (spatial_flat),
        .pixel_valid   (in_valid),
        .weights_flat  (stem_weights),
        .pixel_out_flat(spatial_out_flat),
        .out_valid     (spatial_out_valid)
    );

    // ─────────────────────────────────────────────────────────
    // Freq Depthwise Conv
    // CHANNELS=2, 3x3
    // ─────────────────────────────────────────────────────────
    depthwise_filter #(
        .CHANNELS    (2),
        .KERNEL_SIZE (3),
        .IMG_H       (IMG_H),
        .IMG_W       (IMG_W),
        .STRIDE      (1),
        .PADDING     (1)
    ) u_freq0 (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (frame_start),
        .pixel_in_flat (freq_flat),
        .pixel_valid   (in_valid),
        .weights_flat  (dw_weights),
        .pixel_out_flat(dw_out_flat),
        .out_valid     (dw_out_valid)
    );

    // ─────────────────────────────────────────────────────────
    // Freq Conv1 start generator
    // Fires once when first dw_out_valid arrives
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            freq1_start   <= 1'b0;
            freq1_started <= 1'b0;
        end
        else begin
            freq1_start <= 1'b0;
            if (frame_start)
                freq1_started <= 1'b0;
            else if (dw_out_valid && !freq1_started) begin
                freq1_start   <= 1'b1;
                freq1_started <= 1'b1;
                $display("[DEBUG] freq1_start generated");
            end
        end
    end

    // Delay dw output by 1 cycle for timing
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dw_out_d1       <= '0;
            dw_out_valid_d1 <= 1'b0;
        end
        else begin
            dw_out_d1       <= dw_out_flat;
            dw_out_valid_d1 <= dw_out_valid;
        end
    end

    // ─────────────────────────────────────────────────────────
    // Freq Conv1
    // IN=2, OUT=32, 3x3
    // ─────────────────────────────────────────────────────────
    conv_3x3_systolic #(
        .IN_CH   (2),
        .OUT_CH  (32),
        .IMG_H   (IMG_H),
        .IMG_W   (IMG_W),
        .STRIDE  (1),
        .PADDING (1)
    ) u_freq1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (freq1_start),
        .pixel_in_flat (dw_out_d1[2*8-1:0]),
        .pixel_valid   (dw_out_valid_d1),
        .weights_flat  (freq1_weights),
        .pixel_out_flat(freq_out_flat),
        .out_valid     (freq_out_valid)
    );

    // ─────────────────────────────────────────────────────────
    // Feature packing
    // ─────────────────────────────────────────────────────────
    always_comb begin
        spatial_big       = '0;
        freq_big          = '0;
        spatial_big[31:0] = spatial_out_flat[31:0];
        freq_big[31:0]    = freq_out_flat[31:0];
    end

    // ─────────────────────────────────────────────────────────
    // Fusion
    // ─────────────────────────────────────────────────────────
    fusion_module #(
        .SPATIAL_CH (1280),
        .FREQ_CH    (64),
        .FUSED_CH   (512),
        .SPATIAL_HW (IMG_H),
        .FREQ_HW    (IMG_H)
    ) u_fusion (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (fusion_start),
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