library ieee;
use ieee.std_logic_1164.all;

library neorv32;

entity rvedgedet is
    port (
        clk     : in  std_ulogic;                       -- 50 mhz
        rstn    : in  std_ulogic;                       -- KEY0, active low
        led     : out std_ulogic_vector(7 downto 0);    -- LEDG[7:0]
        uart_tx : out std_ulogic;
        uart_rx : in  std_ulogic
    );
end entity rvedgedet;

architecture rtl of rvedgedet is
    signal gpio : std_ulogic_vector(31 downto 0);
begin
    u_cpu : entity neorv32.neorv32_top
        generic map (
            CLOCK_FREQUENCY  => 50_000_000,
            BOOT_MODE_SELECT => 0,          -- uart bootloader
            RISCV_ISA_C      => true,
            RISCV_ISA_M      => true,
            RISCV_ISA_Zicntr => true,
            IMEM_EN          => true,
            IMEM_SIZE        => 32*1024,    -- keep in sync with sw/*/Makefile
            DMEM_EN          => true,
            DMEM_SIZE        => 16*1024,    -- keep in sync with sw/*/Makefile
            IO_GPIO_NUM      => 8,
            IO_CLINT_EN      => true,
            IO_UART0_RX_FIFO => 64,         -- power of two
            IO_UART0_EN      => true
        )
        port map (
            clk_i       => clk,
            rstn_i      => rstn,
            gpio_o      => gpio,
            uart0_txd_o => uart_tx,
            uart0_rxd_i => uart_rx
        );

    led <= gpio(7 downto 0);
end architecture rtl;
