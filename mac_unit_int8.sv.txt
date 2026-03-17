import sffn_params::*;

module mac_unit_int8 #(
    parameter int W_BITS = WEIGHT_BITS,
    parameter int A_BITS = ACCUM_BITS
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     en,
    input  logic signed [W_BITS-1:0] a,
    input  logic signed [W_BITS-1:0] b,
    input  logic signed [A_BITS-1:0] acc_in,
    output logic signed [A_BITS-1:0] acc_out
);

    // Stage 1: registered multiply (maps to DSP block)
    logic signed [2*W_BITS-1:0] product_reg;

    // Stage 2: sign extended product
    logic signed [A_BITS-1:0] product_ext;

    // Stage 1 — multiply
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            product_reg <= '0;
        else if (en)
            product_reg <= a * b;
    end

    // Combinational sign extension
    always_comb begin
        product_ext = A_BITS'(signed'(product_reg));
    end

    // Stage 2 — accumulate
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc_out <= '0;
        else if (en)
            acc_out <= acc_in + product_ext;
    end

endmodule : mac_unit_int8