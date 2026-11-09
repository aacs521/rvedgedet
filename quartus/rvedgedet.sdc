create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty

# button / uart rx are asynchronous, leds / uart tx are not timing critical
set_false_path -from [get_ports {rstn uart_rx}]
set_false_path -to   [get_ports {led[*] uart_tx}]
