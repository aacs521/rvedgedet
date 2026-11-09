#include <neorv32.h>
#include <lcd.h>

static void wait_ms(uint32_t ms) {
    neorv32_aux_delay_ms(neorv32_sysinfo_get_clk(), ms);
}

int main(void) {

    lcd_init();

    // 1. positioned text
    lcd_print_at(0, 0, "neorv32 + lcd");
    lcd_print_at(1, 0, "uart1 -> terminal");
    lcd_print_at(3, 0, "cursor: off");

    // 2. in-place counter on row 2, cursor modes on row 3
    for (uint32_t i = 0, c = 0; ; i++) {
        lcd_goto(2, 0);
        lcd_printf("count: %u", (unsigned)i);
        lcd_clear_eol();
        wait_ms(500);
        if (i % 3 == 0) c = (c + 1) & 2;
        if (c == 0) { lcd_cursor(true);  lcd_blink(false);  lcd_print_at(3, 8, "line     "); }
        if (c == 1) { lcd_cursor(false); lcd_blink(true);   lcd_print_at(3, 8, "blink    "); }
        if (c == 2) { lcd_cursor(true);  lcd_blink(true);   lcd_print_at(3, 8, "both     "); }
    }
    lcd_cursor(false);
    lcd_blink(false);

    // 3. bye bye! (never reached actually)
    for(;;) {}
}
