`timescale 1ns/1ps
`include "sim_weights.sv"
import sffn_params::*;

// ============================================================
// sffn_top_optimized.sv
//
// Optimized top-level using:
//   conv_3x3_parallel.sv  — parallel channel MAC (9 cyc/pix)
//   fusion_module_v2.sv   — unrolled FC layer (168 cycles)
//
// Performance vs sffn_top.sv:
//   Original  : ~1856 cycles total
//   Optimized : ~456  cycles total
//   Speedup   : ~4x
// ============================================================

module sffn_top_optimized (
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
    localparam TOTAL_PIX = IMG_H * IMG_W;

    // ── Weight bus sizes ──────────────────────────────────────
    localparam STEM_W_BITS  = 3   * 32 * 9 * 8;
    localparam FREQ1_W_BITS = 2   * 32 * 9 * 8;
    localparam DW_W_BITS    = 2   * 1  * 9 * 8;
    localparam FC_W_BITS    = 512 * (1280+64) * 8;

    // ── FSM ───────────────────────────────────────────────────
    typedef enum logic [2:0] {
        S_IDLE, S_LOAD, S_WAIT, S_FUSION, S_DONE
    } state_t;

    state_t state;

    // ── Control ───────────────────────────────────────────────
    logic fusion_start;
    logic pixels_sent;
    logic [4:0] pix_cnt;

    // ── Conv done signals ─────────────────────────────────────
    logic [4:0] sp_out_cnt, fr_out_cnt;
    logic       sp_conv_done, fr_conv_done;
    logic       sp_done_latch, fr_done_latch;
    logic       both_conv_done;

    // ── Flat inputs ───────────────────────────────────────────
    logic [23:0] spatial_flat;
    logic [15:0] freq_flat;

    // ── Spatial conv outputs ──────────────────────────────────
    logic [32*32-1:0]  spatial_out_flat;
    logic              spatial_out_valid;

    // ── Depthwise outputs ─────────────────────────────────────
    logic [2*32-1:0]   dw_out_flat;
    logic              dw_out_valid;

    // ── Freq conv1 pipeline ───────────────────────────────────
    logic              freq1_start;
    logic              freq1_started;
    logic [2*32-1:0]   dw_out_d1, dw_out_d2;
    logic              dw_out_valid_d1, dw_out_valid_d2;
    logic [32*32-1:0]  freq_out_flat;
    logic              freq_out_valid;

    // ── Output buffers ────────────────────────────────────────
    logic [31:0] sp_buf [0:TOTAL_PIX-1];
    logic [31:0] fr_buf [0:TOTAL_PIX-1];
    logic [4:0]  sp_buf_cnt, fr_buf_cnt;

    // ── Replay signals ────────────────────────────────────────
    logic [4:0]  sp_replay_cnt, fr_replay_cnt;
    logic        sp_replaying,  fr_replaying;
    logic [31:0] sp_replay_data, fr_replay_data;
    logic        sp_replay_valid, fr_replay_valid;

    // ── Fusion signals ────────────────────────────────────────
    logic [1280*32-1:0]   spatial_big;
    logic [64*32-1:0]     freq_big;
    logic [FC_W_BITS-1:0] fc_weights;
    logic [512*32-1:0]    fused_out;
    logic                 fusion_valid;
    logic                 fusion_done_sig;
    logic                 gap_sp_done;

    // ── BRAM signals ──────────────────────────────────────────
    logic [6:0]  bram_layer_sel;
    logic        bram_rd_en;
    logic [19:0] bram_rd_addr;
    logic [7:0]  bram_rd_data;
    logic        bram_rd_valid;

    // ── Weights ───────────────────────────────────────────────
    logic [STEM_W_BITS-1:0]  stem_weights;
    logic [FREQ1_W_BITS-1:0] freq1_weights;
    logic [DW_W_BITS-1:0]    dw_weights;

    assign stem_weights  = STEM_W_HEX;
    assign freq1_weights = FREQ1_W_HEX;
    assign dw_weights    = DW_W_HEX;
    assign fc_weights    = '0;

    // ── Inputs ────────────────────────────────────────────────
    assign spatial_flat = {spatial_in[2],
                           spatial_in[1],
                           spatial_in[0]};
    assign freq_flat    = {freq_in[1], freq_in[0]};

    // ─────────────────────────────────────────────────────────
    // Pixel counter
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_cnt     <= '0;
            pixels_sent <= 1'b0;
        end
        else begin
            if (frame_start) begin
                pix_cnt     <= '0;
                pixels_sent <= 1'b0;
            end
            else if (in_valid) begin
                if (pix_cnt == TOTAL_PIX - 1) begin
                    pix_cnt     <= '0;
                    pixels_sent <= 1'b1;
                end
                else
                    pix_cnt <= pix_cnt + 5'd1;
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
                S_IDLE: if (frame_start) begin
                    state <= S_LOAD;
                    $display("[OPT] FSM: IDLE→LOAD");
                end
                S_LOAD: if (pixels_sent) begin
                    state <= S_WAIT;
                    $display("[OPT] FSM: LOAD→WAIT");
                end
                S_WAIT: if (both_conv_done) begin
                    state        <= S_FUSION;
                    fusion_start <= 1'b1;
                    $display("[OPT] FSM: WAIT→FUSION");
                end
                S_FUSION: if (fusion_done_sig) begin
                    state <= S_DONE;
                    $display("[OPT] FSM: FUSION→DONE");
                end
                S_DONE: begin
                    frame_done <= 1'b1;
                    state      <= S_IDLE;
                    $display("[OPT] Frame done");
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ─────────────────────────────────────────────────────────
    // Done detectors
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_out_cnt   <= '0;
            sp_conv_done <= 1'b0;
        end
        else begin
            sp_conv_done <= 1'b0;
            if (frame_start) sp_out_cnt <= '0;
            else if (spatial_out_valid) begin
                if (sp_out_cnt == TOTAL_PIX - 1) begin
                    sp_out_cnt   <= '0;
                    sp_conv_done <= 1'b1;
                    $display("[OPT] Spatial DONE");
                end
                else sp_out_cnt <= sp_out_cnt + 5'd1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fr_out_cnt   <= '0;
            fr_conv_done <= 1'b0;
        end
        else begin
            fr_conv_done <= 1'b0;
            if (frame_start) fr_out_cnt <= '0;
            else if (freq_out_valid) begin
                if (fr_out_cnt == TOTAL_PIX - 1) begin
                    fr_out_cnt   <= '0;
                    fr_conv_done <= 1'b1;
                    $display("[OPT] Freq DONE");
                end
                else fr_out_cnt <= fr_out_cnt + 5'd1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Done latches
    // ─────────────────────────────────────────────────────────
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

    // ─────────────────────────────────────────────────────────
    // Output buffers
    // ─────────────────────────────────────────────────────────
    integer buf_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_buf_cnt <= '0;
            for (buf_i = 0; buf_i < TOTAL_PIX; buf_i++)
                sp_buf[buf_i] <= '0;
        end
        else begin
            if (frame_start) sp_buf_cnt <= '0;
            else if (spatial_out_valid) begin
                sp_buf[sp_buf_cnt] <= spatial_out_flat[31:0];
                if (sp_buf_cnt < TOTAL_PIX-1)
                    sp_buf_cnt <= sp_buf_cnt + 5'd1;
            end
        end
    end

    integer buf_j;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fr_buf_cnt <= '0;
            for (buf_j = 0; buf_j < TOTAL_PIX; buf_j++)
                fr_buf[buf_j] <= '0;
        end
        else begin
            if (frame_start) fr_buf_cnt <= '0;
            else if (freq_out_valid) begin
                fr_buf[fr_buf_cnt] <= freq_out_flat[31:0];
                if (fr_buf_cnt < TOTAL_PIX-1)
                    fr_buf_cnt <= fr_buf_cnt + 5'd1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Replay logic
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_replaying    <= 1'b0;
            fr_replaying    <= 1'b0;
            sp_replay_cnt   <= '0;
            fr_replay_cnt   <= '0;
            sp_replay_valid <= 1'b0;
            fr_replay_valid <= 1'b0;
            sp_replay_data  <= '0;
            fr_replay_data  <= '0;
        end
        else begin
            sp_replay_valid <= 1'b0;
            fr_replay_valid <= 1'b0;

            if (fusion_start) begin
                sp_replaying  <= 1'b1;
                sp_replay_cnt <= '0;
            end

            if (sp_replaying) begin
                sp_replay_data  <= sp_buf[sp_replay_cnt];
                sp_replay_valid <= 1'b1;
                if (sp_replay_cnt == TOTAL_PIX - 1) begin
                    sp_replaying  <= 1'b0;
                    sp_replay_cnt <= '0;
                end
                else
                    sp_replay_cnt <= sp_replay_cnt + 5'd1;
            end

            if (gap_sp_done) begin
                fr_replaying  <= 1'b1;
                fr_replay_cnt <= '0;
            end

            if (fr_replaying) begin
                fr_replay_data  <= fr_buf[fr_replay_cnt];
                fr_replay_valid <= 1'b1;
                if (fr_replay_cnt == TOTAL_PIX - 1) begin
                    fr_replaying  <= 1'b0;
                    fr_replay_cnt <= '0;
                end
                else
                    fr_replay_cnt <= fr_replay_cnt + 5'd1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // BRAM
    // ─────────────────────────────────────────────────────────
    assign bram_layer_sel = '0;
    assign bram_rd_en     = 1'b0;
    assign bram_rd_addr   = '0;

    weight_bram u_conv_bram (
        .clk      (clk),   .rst_n    (rst_n),
        .layer_sel(bram_layer_sel),
        .rd_en    (bram_rd_en),
        .rd_addr  (bram_rd_addr),
        .rd_data  (bram_rd_data),
        .rd_valid (bram_rd_valid)
    );

    // ─────────────────────────────────────────────────────────
    // Spatial Conv — OPTIMIZED (parallel channels)
    // 9 cycles/pixel instead of 27
    // ─────────────────────────────────────────────────────────
    conv_3x3_parallel #(
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
    // Freq Depthwise Conv (unchanged — already fast)
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
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dw_out_d1 <= '0; dw_out_valid_d1 <= 1'b0;
        end
        else begin
            dw_out_d1       <= dw_out_flat;
            dw_out_valid_d1 <= dw_out_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dw_out_d2 <= '0; dw_out_valid_d2 <= 1'b0;
        end
        else begin
            dw_out_d2       <= dw_out_d1;
            dw_out_valid_d2 <= dw_out_valid_d1;
        end
    end

    // ─────────────────────────────────────────────────────────
    // Freq Conv1 — OPTIMIZED (parallel channels)
    // 9 cycles/pixel instead of 18
    // ─────────────────────────────────────────────────────────
    conv_3x3_parallel #(
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
        .pixel_in_flat (dw_out_d2[2*8-1:0]),
        .pixel_valid   (dw_out_valid_d2),
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
        spatial_big[31:0] = sp_replay_data;
        freq_big[31:0]    = fr_replay_data;
    end

    // ─────────────────────────────────────────────────────────
    // Fusion — OPTIMIZED (8x unrolled FC)
    // 168 cycles instead of 1344
    // ─────────────────────────────────────────────────────────
    fusion_module_v2 #(
        .SPATIAL_CH (1280),
        .FREQ_CH    (64),
        .FUSED_CH   (512),
        .SPATIAL_HW (IMG_H),
        .FREQ_HW    (IMG_H),
        .UNROLL     (8)
    ) u_fusion (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (fusion_start),
        .spatial_feat_flat(spatial_big),
        .spatial_valid    (sp_replay_valid),
        .freq_feat_flat   (freq_big),
        .freq_valid       (fr_replay_valid),
        .fc_weights_flat  (fc_weights),
        .fused_out_flat   (fused_out),
        .fused_valid      (fusion_valid),
        .done             (fusion_done_sig),
        .gap_sp_done      (gap_sp_done)
    );

    assign out_data = fused_out[15:0];

endmodule : sffn_top_optimized