-- lcd_terminal.vhd : serial terminal for a 20x4 hd44780
--
--   rxd (8n1) -> uart_rx -> lcd_term -> lcd_driver -> lcd pins
--
-- hook rxd to neorv32's uart1_txd_o and print from c (see lcd.h). the reset is
-- active low and asynchronous (same button as the cpu); it is synchronised in here.
--
-- no fifo: lcd_term takes a byte per clock and the screen buffer absorbs bursts, so
-- characters can't overflow, they just show up a few milliseconds later.
--
-- this is the top level of the lcd terminal. it contains almost no logic of its own, it only
-- wires three sub-blocks into a chain and adds a reset synchroniser and a sticky error flag:
--
--   rxd --> [ uart_rx ] --byte,valid--> [ lcd_term ] --start,rs,data--> [ lcd_driver ] --> lcd
--                                            ^                                 |
--                                            +----------- busy, ready ---------+
--
--   uart_rx    : deserialises the 8n1 serial line into bytes (one 'valid' pulse per byte) and
--                flags frame errors (stop bit not '1').
--   lcd_term   : the terminal engine (escape sequences, screen buffer, refresh logic).
--   lcd_driver : the hd44780 4-bit protocol (power-up wait, init sequence, e-pin timing).
--
-- uart_rx and lcd_driver live in their own files and are not documented here.

library ieee;
use ieee.std_logic_1164.all;

entity lcd_terminal is
    generic (
        clk_hz     : positive := 50_000_000;        -- frequency of 'clk' in hz (used for all timing)
        baud       : positive := 115_200;           -- must match neorv32_uart_setup(UART1, baud, 0)
        powerup_us : natural  := 50_000             -- wait after power-up before talking to the lcd
    );
    port (
        clk       : in  std_logic;
        rstn      : in  std_logic;                   -- active low, may be asynchronous
        rxd       : in  std_logic;                   -- serial input, idles high

        lcd_rs    : out std_logic;                   -- hd44780 register select (0 = instruction, 1 = data)
        lcd_rw    : out std_logic;                   -- hd44780 read/write (the driver only writes)
        lcd_e     : out std_logic;                   -- hd44780 enable strobe
        lcd_d     : out std_logic_vector(7 downto 4);  -- hd44780 data pins d7..d4 (4-bit mode)

        ready     : out std_logic;                   -- lcd init finished
        frame_err : out std_logic                    -- sticky: wrong baud rate / parity setting
    );
end entity;

architecture rtl of lcd_terminal is
    -- reset synchroniser: a 3-stage shift register. it is initialised to all '1' so the whole
    -- design is held in reset right after configuration / power-up, even before the first clock.
    signal rst_sync  : std_logic_vector(2 downto 0) := (others => '1');   -- power-on reset
    signal rst       : std_logic;                                         -- synchronous, active high

    -- uart_rx -> lcd_term
    signal rx_data   : std_logic_vector(7 downto 0);
    signal rx_valid  : std_logic;
    signal rx_ferr   : std_logic;                    -- one-clock pulse on a framing error
    signal ferr_seen : std_logic := '0';             -- latched version of rx_ferr

    -- lcd_term <-> lcd_driver
    signal start, rs, busy, rdy : std_logic;
    signal data      : std_logic_vector(7 downto 0);
begin

    -- reset synchroniser and framing error latch
    process (clk)
    begin
        if rising_edge(clk) then
            -- shift the (inverted, so active high) external reset through three flip-flops;
            -- this removes metastability and makes rst a clean synchronous signal. note that
            -- the *assertion* is delayed by three clocks as well, which is irrelevant here.
            rst_sync <= rst_sync(1 downto 0) & (not rstn);

            -- sticky error flag: set on the first framing error ...
            if rx_ferr = '1' then
                ferr_seen <= '1';
            end if;
            -- ... and cleared by reset. this comes later in the process, so if both happen in
            -- the same clock the reset wins (last assignment wins in vhdl).
            if rst = '1' then
                ferr_seen <= '0';
            end if;
        end if;
    end process;
    rst <= rst_sync(2);

    -- serial receiver: rxd -> bytes
    u_rx : entity work.uart_rx
        generic map (clk_hz => clk_hz, baud => baud)
        port map (clk => clk, rst => rst, rx => rxd,
                  data => rx_data, valid => rx_valid, frame_err => rx_ferr);

    -- terminal engine: bytes -> lcd requests
    u_term : entity work.lcd_term
        port map (clk => clk, rst => rst,
                  in_valid => rx_valid, in_data => rx_data,
                  lcd_start => start, lcd_rs => rs, lcd_data => data,
                  lcd_busy => busy, lcd_ready => rdy);

    -- hd44780 driver: lcd requests -> pins (also generates the init sequence and 'ready')
    u_lcd : entity work.lcd_driver
        generic map (clk_hz => clk_hz, powerup_us => powerup_us)
        port map (clk => clk, rst => rst,
                  start => start, rs => rs, data => data,
                  busy => busy, ready => rdy,
                  lcd_rs => lcd_rs, lcd_rw => lcd_rw, lcd_e => lcd_e, lcd_d => lcd_d);

    ready     <= rdy;
    frame_err <= ferr_seen;

end architecture;
