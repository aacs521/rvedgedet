#ifndef LCD_H
#define LCD_H

#include <stdbool.h>
#include <stdint.h>
#include <neorv32.h>

#define LCD_UART    NEORV32_UART1
#define LCD_BAUD    115200u       // must match the "baud" generic of lcd_terminal in rtl/top.vhd
#define LCD_ROWS    4
#define LCD_COLS    20

#define lcd_printf(...)    neorv32_uart_printf(LCD_UART, __VA_ARGS__)

static inline void lcd_putc(char c) { neorv32_uart_putc(LCD_UART, c); }

static inline void lcd_puts(const char *s) {            // raw: no \n -> \r\n conversion needed
    while (*s) { neorv32_uart_putc(LCD_UART, *s++); }
}

static inline void lcd_clear(void)                 { lcd_puts("\f"); }           // clear + home
static inline void lcd_home(void)                  { lcd_puts("\033[H"); }
static inline void lcd_goto(unsigned row, unsigned col) { lcd_printf("\033[%u;%uH", row + 1u, col + 1u); }
static inline void lcd_clear_eol(void)             { lcd_puts("\033[K"); }       // cursor -> end of row
static inline void lcd_clear_row(unsigned row)     { lcd_goto(row, 0); lcd_puts("\033[2K"); }
static inline void lcd_cursor(bool on)             { lcd_puts(on ? "\033[?25h" : "\033[?25l"); }  // underline
static inline void lcd_blink(bool on)              { lcd_puts(on ? "\033[?12h" : "\033[?12l"); }  // blinking block

static inline void lcd_print_at(unsigned row, unsigned col, const char *s) { lcd_goto(row, col); lcd_puts(s); }

static inline void lcd_init(void) {
    neorv32_uart_setup(LCD_UART, LCD_BAUD, 0);
    lcd_clear();
}

#endif
