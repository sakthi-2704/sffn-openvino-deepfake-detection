// ============================================================
// dual_stream_controller.sv
//
// Master Controller for SFFN Dual-Stream Pipeline
//
// Responsibilities:
//   1. Accept input image (spatial_in + freq_in)
//   2. Launch both streams simultaneously
//   3. Monitor completion of both streams
//   4. Synchronize outputs before fusion
//   5. Signal fusion module when both streams ready
//
// Stream architecture:
//   ┌─────────────────────────────────────────┐
//   │  spatial_in [1,3,224,224]               │
//   │       ↓                                 │
//   │  [Spatial Stream - EfficientNet-B0]     │
//   │       ↓                                 │
//   │  spatial_feat [1,1280,7,7]  ──────┐     │
//   │                               [FUSION]  │
//   │  freq_in [1,2,224,224]        [MODULE]  │
//   │       ↓                           │     │
//   │  [Frequency Stream]               │     │
//   │       ↓                           │     │
//   │  freq_feat [1,64,28,28] ──────────┘     │
//   └─────────────────────────────────────────┘
//
// State machine:
//   IDLE → LAUNCH → SPATIAL_RUNNING+FREQ_RUNNING
//        → WAIT_SPATIAL → WAIT_FREQ → BOTH_DONE
//        → FUSION → IDLE
//
// From our benchmark analysis:
//   Spatial stream: ~5.2ms (dominant — 99.5% of params)
//   Freq stream:    ~0.3ms (lightweight — 0.5% of params)
//   Controller must wait for BOTH before fusion
// ============================================================

import sffn_params::*;

module dual_stream_controller #(
    parameter SPATIAL_LAYERS = 81,   // backbone layers
    parameter FREQ_LAYERS    = 2,    // frequency layers
    parameter FEAT_SPATIAL   = 1280, // spatial output channels
    parameter FEAT_FREQ      = 64    // frequency output channels
)(
    input  logic        clk,
    input  logic        rst_n,

    // Top-level control
    input  logic        frame_start,    // pulse: new frame ready
    output logic        frame_done,     // pulse: frame processed

    // Spatial stream interface
    output logic        spatial_start,  // launch spatial stream
    input  logic        spatial_done,   // spatial stream complete
    output logic        spatial_flush,  // reset spatial stream

    // Frequency stream interface
    output logic        freq_start,     // launch freq stream
    input  logic        freq_done,      // freq stream complete
    output logic        freq_flush,     // reset freq stream

    // Fusion interface
    output logic        fusion_start,   // launch fusion module
    input  logic        fusion_done,    // fusion complete

    // Status outputs
    output logic        spatial_active, // spatial running
    output logic        freq_active,    // freq running
    output logic        fusion_active,  // fusion running

    // Performance counters (for thesis benchmarking)
    output logic [31:0] spatial_cycles, // cycles for spatial
    output logic [31:0] freq_cycles,    // cycles for freq
    output logic [31:0] total_cycles,   // total frame cycles
    output logic [31:0] frame_count     // frames processed
);

    // ── FSM states ────────────────────────────────────────────
    localparam S_IDLE          = 3'd0;
    localparam S_LAUNCH        = 3'd1;
    localparam S_RUNNING       = 3'd2;  // both streams running
    localparam S_WAIT_SPATIAL  = 3'd3;  // freq done, wait spatial
    localparam S_WAIT_FREQ     = 3'd4;  // spatial done, wait freq
    localparam S_FUSION        = 3'd5;  // both done, run fusion
    localparam S_DONE          = 3'd6;  // frame complete

    reg [2:0] state;

    // ── Completion flags ──────────────────────────────────────
    reg spatial_done_reg;
    reg freq_done_reg;

    // ── Cycle counters ────────────────────────────────────────
    reg [31:0] spatial_timer;
    reg [31:0] freq_timer;
    reg [31:0] total_timer;

    // ─────────────────────────────────────────────────────────
    // Main FSM
    // ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            spatial_start   <= 1'b0;
            freq_start      <= 1'b0;
            spatial_flush   <= 1'b0;
            freq_flush      <= 1'b0;
            fusion_start    <= 1'b0;
            frame_done      <= 1'b0;
            spatial_active  <= 1'b0;
            freq_active     <= 1'b0;
            fusion_active   <= 1'b0;
            spatial_done_reg<= 1'b0;
            freq_done_reg   <= 1'b0;
            spatial_timer   <= 32'd0;
            freq_timer      <= 32'd0;
            total_timer     <= 32'd0;
            spatial_cycles  <= 32'd0;
            freq_cycles     <= 32'd0;
            total_cycles    <= 32'd0;
            frame_count     <= 32'd0;
        end
        else begin
            // Default deassert
            spatial_start <= 1'b0;
            freq_start    <= 1'b0;
            spatial_flush <= 1'b0;
            freq_flush    <= 1'b0;
            fusion_start  <= 1'b0;
            frame_done    <= 1'b0;

            case (state)

                // ── Wait for new frame ────────────────────────
                S_IDLE: begin
                    spatial_active   <= 1'b0;
                    freq_active      <= 1'b0;
                    fusion_active    <= 1'b0;
                    spatial_done_reg <= 1'b0;
                    freq_done_reg    <= 1'b0;
                    spatial_timer    <= 32'd0;
                    freq_timer       <= 32'd0;
                    total_timer      <= 32'd0;

                    if (frame_start) begin
                        state <= S_LAUNCH;
                    end
                end

                // ── Launch both streams simultaneously ────────
                // Key feature: PARALLEL execution
                // Both streams start on the SAME clock cycle
                S_LAUNCH: begin
                    spatial_start  <= 1'b1;   // launch spatial
                    freq_start     <= 1'b1;   // launch freq
                    spatial_active <= 1'b1;
                    freq_active    <= 1'b1;
                    state          <= S_RUNNING;
                end

                // ── Both streams running in parallel ──────────
                S_RUNNING: begin
                    // Count cycles for both timers
                    total_timer   <= total_timer + 32'd1;
                    spatial_timer <= spatial_timer + 32'd1;
                    freq_timer    <= freq_timer + 32'd1;

                    // Check completion
                    if (spatial_done && freq_done) begin
                        // Both done simultaneously
                        spatial_active   <= 1'b0;
                        freq_active      <= 1'b0;
                        spatial_cycles   <= spatial_timer + 1;
                        freq_cycles      <= freq_timer + 1;
                        state            <= S_FUSION;
                    end
                    else if (spatial_done && !freq_done) begin
                        // Spatial faster (unusual)
                        spatial_active   <= 1'b0;
                        spatial_cycles   <= spatial_timer + 1;
                        spatial_done_reg <= 1'b1;
                        state            <= S_WAIT_FREQ;
                    end
                    else if (freq_done && !spatial_done) begin
                        // Freq faster (expected — 0.5% of params)
                        freq_active      <= 1'b0;
                        freq_cycles      <= freq_timer + 1;
                        freq_done_reg    <= 1'b1;
                        state            <= S_WAIT_SPATIAL;
                    end
                end

                // ── Freq done, waiting for spatial ────────────
                // Expected state: freq stream is much smaller
                // so it typically finishes first
                S_WAIT_SPATIAL: begin
                    total_timer   <= total_timer + 32'd1;
                    spatial_timer <= spatial_timer + 32'd1;

                    if (spatial_done) begin
                        spatial_active <= 1'b0;
                        spatial_cycles <= spatial_timer + 1;
                        state          <= S_FUSION;
                    end
                end

                // ── Spatial done, waiting for freq ────────────
                S_WAIT_FREQ: begin
                    total_timer <= total_timer + 32'd1;
                    freq_timer  <= freq_timer + 32'd1;

                    if (freq_done) begin
                        freq_active <= 1'b0;
                        freq_cycles <= freq_timer + 1;
                        state       <= S_FUSION;
                    end
                end

                // ── Both streams done — launch fusion ─────────
                S_FUSION: begin
                    fusion_start  <= 1'b1;
                    fusion_active <= 1'b1;
                    total_timer   <= total_timer + 32'd1;
                    state         <= S_DONE;
                end

                // ── Wait for fusion to complete ───────────────
                S_DONE: begin
                    total_timer <= total_timer + 32'd1;

                    if (fusion_done) begin
                        fusion_active <= 1'b0;
                        total_cycles  <= total_timer + 1;
                        frame_count   <= frame_count + 32'd1;
                        frame_done    <= 1'b1;
                        state         <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule : dual_stream_controller