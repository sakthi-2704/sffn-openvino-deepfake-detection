vlib work
vlog -sv sffn_params_pkg.sv
vlog -sv mac_unit_int8.sv
vlog -sv tb_mac_unit_int8.sv

vsim -t 1ps tb_mac_unit_int8

add wave -divider "CONTROL"
add wave -radix binary  /tb_mac_unit_int8/clk
add wave -radix binary  /tb_mac_unit_int8/rst_n
add wave -radix binary  /tb_mac_unit_int8/en

add wave -divider "INPUTS"
add wave -radix decimal /tb_mac_unit_int8/a
add wave -radix decimal /tb_mac_unit_int8/b
add wave -radix decimal /tb_mac_unit_int8/acc_in

add wave -divider "OUTPUT"
add wave -radix decimal /tb_mac_unit_int8/acc_out

add wave -divider "DUT INTERNALS"
add wave -radix decimal /tb_mac_unit_int8/DUT/product_reg
add wave -radix decimal /tb_mac_unit_int8/DUT/product_ext

run -all
wave zoom full
