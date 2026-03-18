vlog -sv sffn_params_pkg.sv
vlog -sv mac_unit_int8.sv
vlog -sv conv_1x1_engine.sv
vlog -sv tb_conv_1x1_engine.sv
vsim -t 1ps work.tb_conv_1x1_engine
add wave *
run -all
wave zoom full
