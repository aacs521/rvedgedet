foreach {sig pin std} {
    clk         PIN_R20     "3.3-V LVTTL"
    rstn        PIN_AB24    "3.3-V LVTTL"
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
    ledr[0]     PIN_F7      "2.5-V"
    ledr[1]     PIN_F6      "2.5-V"
    lcd_rs      PIN_D26     "3.3-V LVTTL"
    lcd_rw      PIN_E26     "3.3-V LVTTL"
    lcd_e       PIN_K26     "3.3-V LVTTL"
    lcd_d[4]    PIN_M26     "3.3-V LVTTL"
    lcd_d[5]    PIN_M21     "3.3-V LVTTL"
    lcd_d[6]    PIN_P20     "3.3-V LVTTL"
    lcd_d[7]    PIN_T22     "3.3-V LVTTL"


} {
    set_location_assignment $pin -to $sig
    set_instance_assignment -name IO_STANDARD $std -to $sig
}
