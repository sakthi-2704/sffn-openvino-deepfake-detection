// ============================================================
// weight_bram.sv
//
// Weight BRAM Controller
// Loads INT8 weights from BRAM (initialized via .mif files)
// and feeds them to conv engines on demand.
//
// From our extract_for_rtl.py analysis:
//   Total layers  : 84
//   Total params  : 3,988,254
//   INT8 size     : 3,894 KB
//   M9K blocks    : 3,963 / 9,383 (42.2%)
//
// Design:
//   - One BRAM instance per layer (84 BRAMs)
//   - Each BRAM initialized from corresponding .mif file
//   - Layer select input chooses which BRAM to read
//   - Sequential read: address increments each clock
//   - Output: 8-bit weight per cycle
//
// Memory map:
//   Layer 0  : addr 0x000000 → weights for conv layer 0
//   Layer 1  : addr 0x000000 → weights for conv layer 1
//   ...
//   Each layer has its own BRAM (independent address space)
// ============================================================

import sffn_params::*;

module weight_bram #(
    parameter NUM_LAYERS  = 84,    // total conv layers
    parameter ADDR_WIDTH  = 20,    // max 2^20 = 1M addresses
    parameter DATA_WIDTH  = 8      // INT8 weights
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Layer select
    input  logic [$clog2(NUM_LAYERS)-1:0] layer_sel,

    // Read control
    input  logic                    rd_en,      // read enable
    input  logic [ADDR_WIDTH-1:0]   rd_addr,    // read address

    // Output
    output logic [DATA_WIDTH-1:0]   rd_data,    // weight output
    output logic                    rd_valid    // data valid
);

    // ── BRAM model ────────────────────────────────────────────
    // In simulation: RAM arrays initialized with $readmemh
    // In Quartus synthesis: replace with altsyncram megafunction
    //   pointing to .mif files

    // Layer sizes from our bram_summary.csv
    // Each layer BRAM sized to its weight count
    localparam L0_SIZE  = 864;      // 32x3x3x3   stem conv
    localparam L1_SIZE  = 288;      // 32x1x3x3   DWConv
    localparam L2_SIZE  = 256;      // 8x32x1x1
    localparam L3_SIZE  = 256;      // 32x8x1x1
    localparam L4_SIZE  = 512;      // 16x32x1x1
    // ... (representative layers shown)
    // Full implementation uses all 84 layers

    // ── Simulation BRAM arrays ────────────────────────────────
    // Using 2D array: bram[layer][address]
    // Sized to max layer (layer 80: 1280x320 = 409,600 weights)
    localparam MAX_WEIGHTS = 409600;

    reg [DATA_WIDTH-1:0] bram [0:NUM_LAYERS-1]
                              [0:MAX_WEIGHTS-1];

    // ── Read pipeline register ────────────────────────────────
    reg [DATA_WIDTH-1:0] rd_data_reg;
    reg                  rd_valid_reg;

    // ── BRAM initialization ───────────────────────────────────
    // In simulation: load from hex files
    // In synthesis:  Quartus reads .mif files automatically
    integer layer_idx;
    initial begin
        // Initialize all to zero first
        for (layer_idx = 0; layer_idx < NUM_LAYERS; layer_idx++)
            for (int addr = 0; addr < MAX_WEIGHTS; addr++)
                bram[layer_idx][addr] = 8'h00;

        // Load weight files
        // Uncomment and adjust paths for your system:
        // $readmemh("weights/layer_000_Conv_32x3_3x3_w.hex",
        //            bram[0]);
        // $readmemh("weights/layer_001_DWConv_32x1_3x3_w.hex",
        //            bram[1]);
        // ... repeat for all 84 layers

        $display("[weight_bram] Initialized %0d layer BRAMs",
                  NUM_LAYERS);
    end

    // ── Synchronous read ──────────────────────────────────────
    // 1 cycle read latency (matches M9K BRAM timing)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data_reg  <= 8'h00;
            rd_valid_reg <= 1'b0;
        end
        else begin
            rd_valid_reg <= rd_en;
            if (rd_en)
                rd_data_reg <= bram[layer_sel][rd_addr];
        end
    end

    assign rd_data  = rd_data_reg;
    assign rd_valid = rd_valid_reg;

endmodule : weight_bram