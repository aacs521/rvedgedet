-- board top level: neorv32 + uart bootloader, gpio -> green leds, uart0 -> usb-uart,
-- uart1 -> lcd terminal (20x4 hd44780)
--
-- this is the top level of the fpga design. it contains no logic of its own, it only
-- instantiates the two big blocks and wires them to the board pins:
--
--   key0 (rstn) ----+------------------------------+
--                   v                              v
--             [ neorv32_top ]                [ lcd_terminal ]
--              risc-v cpu + peripherals       (uart_rx -> lcd_term -> lcd_driver)
--                |   |   |    |                    ^                  |
--     gpio[7:0]--+   |   |    +-- uart1_txd -------+                  +--> lcd_rs/rw/e/d[7:4]
--       -> LEDG      |   |         (internal wire, 115200 8n1)         |
--           uart0 tx-+   +-- uart0 rx                                  +--> LEDR0 ready, LEDR1 frame error
--           (usb-uart)      (usb-uart)
--
-- * the cpu boots from its uart bootloader (uart0), so programs are uploaded over the usb-uart.
-- * software drives the leds by writing the gpio output register.
-- * software prints on the lcd by writing characters (and escape sequences) to uart1; the
--   bit stream never leaves the chip, it goes straight into the lcd_terminal's receiver.
-- * the baud rate of uart1 in software (neorv32_uart_setup(UART1, 115200, 0), see lcd.h) and the
--   'baud' generic of lcd_terminal below have to be the same, or the lcd shows garbage and
--   LEDR1 (framing error) lights up.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;

entity rvedgedet is
    port (
        clk     : in  std_ulogic;                       -- 50 mhz
        rstn    : in  std_ulogic;                       -- KEY0, active low
        led     : out std_ulogic_vector(7 downto 0);    -- LEDG[7:0]
        ledr    : out std_ulogic_vector(1 downto 0);    -- LEDR0 = lcd ready, LEDR1 = uart1 framing error
        uart_tx : out std_ulogic;                       -- uart0 transmit -> usb-uart (bootloader / console)
        uart_rx : in  std_ulogic;                       -- uart0 receive  <- usb-uart

        -- hd44780 lcd, 4-bit interface (rw is always '0' = write only; d3..d0 are not connected)
        lcd_rs  : out std_ulogic;
        lcd_rw  : out std_ulogic;
        lcd_e   : out std_ulogic;
        lcd_d   : out std_ulogic_vector(7 downto 4)
    );
end entity rvedgedet;

architecture rtl of rvedgedet is
    -- the cpu's 32-bit gpio output port; only the low 8 bits are used (IO_GPIO_NUM = 8)
    signal gpio      : std_ulogic_vector(31 downto 0);
    -- serial line from the cpu's uart1 transmitter to the lcd terminal's receiver
    signal uart1_txd : std_ulogic;

    -- the lcd_terminal entity uses std_logic ports, the board pins are std_ulogic, so the
    -- signals going to / coming from lcd_terminal are declared as std_logic here and
    -- converted at the boundary below
    signal lcd_rxd   : std_logic;
    signal lcd_rs_i, lcd_rw_i, lcd_e_i : std_logic;
    signal lcd_d_i   : std_logic_vector(7 downto 4);
    signal lcd_ready, lcd_ferr : std_logic;
begin
    -- the soc: risc-v cpu with instruction / data memory, gpio, clint timer and two uarts
    u_cpu : entity neorv32.neorv32_top
        generic map (
            CLOCK_FREQUENCY  => 50_000_000,             -- hz; the uart baud generators derive from this
            BOOT_MODE_SELECT => 0,                      -- uart bootloader
            RISCV_ISA_C      => true,                   -- compressed instructions
            RISCV_ISA_M      => true,                   -- hardware multiply / divide
            RISCV_ISA_Zicntr => true,                   -- cycle / instret counters
            IMEM_EN          => true,                   -- internal instruction memory
            IMEM_SIZE        => 32*1024,                -- keep in sync with sw/*/Makefile
            DMEM_EN          => true,                   -- internal data memory
            DMEM_SIZE        => 256*1024,               -- keep in sync with sw/*/Makefile
            IO_GPIO_NUM      => 8,                      -- 8 gpio pins (-> the green leds)
            IO_CLINT_EN      => true,                   -- machine timer (and software interrupt)
            IO_UART0_RX_FIFO => 64,                     -- power of two
            IO_UART0_EN      => true,                   -- uart0: bootloader / console
            IO_UART1_EN      => true,                   -- lcd
            IO_UART1_TX_FIFO => 64                      -- cpu doesn't wait per character
        )
        port map (
            clk_i       => clk,
            rstn_i      => rstn,
            gpio_o      => gpio,
            uart0_txd_o => uart_tx,
            uart0_rxd_i => uart_rx,
            uart1_txd_o => uart1_txd,
            uart1_rxd_i => '1'                          -- unused, keep it idle (default is 'L')
        );

    -- gpio bits 7..0 drive the green leds (bits 31..8 are not connected)
    led <= gpio(7 downto 0);

    -- the lcd terminal listens directly to the cpu's uart1 transmit line
    lcd_rxd <= uart1_txd;
    u_lcd : entity work.lcd_terminal
        generic map (clk_hz => 50_000_000, baud => 115_200)   -- baud: same as lcd.h
        port map (clk => clk, rstn => rstn, rxd => lcd_rxd,
                  lcd_rs => lcd_rs_i, lcd_rw => lcd_rw_i, lcd_e => lcd_e_i, lcd_d => lcd_d_i,
                  ready => lcd_ready, frame_err => lcd_ferr);

    -- std_logic -> std_ulogic at the pins (lcd_d needs an explicit vector type conversion)
    lcd_rs  <= lcd_rs_i;
    lcd_rw  <= lcd_rw_i;
    lcd_e   <= lcd_e_i;
    lcd_d   <= std_ulogic_vector(lcd_d_i);
    -- status leds: red 0 = the lcd finished its init sequence, red 1 = uart1 framing error seen
    -- (sticky until the next reset; means the baud rates of software and hardware differ)
    ledr(0) <= lcd_ready;
    ledr(1) <= lcd_ferr;
end architecture rtl;
