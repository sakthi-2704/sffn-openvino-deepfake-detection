vlog -sv sffn_params_pkg.sv
vlog -sv mac_unit_int8.sv
vlog -sv conv_3x3_systolic.sv
vlog -sv tb_conv_3x3_systolic.sv
vsim -t 1ps work.tb_conv_3x3_systolic
add wave *
run -all
wave zoom full
