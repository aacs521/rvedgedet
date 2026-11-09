foreach {sig pin std} {
    clk         PIN_R20     "3.3-V LVTTL"
    rstn        PIN_P11     "1.2-V"
    led[0]      PIN_L7      "2.5-V"
    led[1]      PIN_K6      "2.5-V"
    led[2]      PIN_D8      "2.5-V"
    led[3]      PIN_E9      "2.5-V"
    led[4]      PIN_A5      "2.5-V"
    led[5]      PIN_B6      "2.5-V"
    led[6]      PIN_H8      "2.5-V"
    led[7]      PIN_H9      "2.5-V"
    uart_rx     PIN_M9      "2.5-V"
    uart_tx     PIN_L9      "2.5-V"
} {
    set_location_assignment $pin -to $sig
    set_instance_assignment -name IO_STANDARD $std -to $sig
}
