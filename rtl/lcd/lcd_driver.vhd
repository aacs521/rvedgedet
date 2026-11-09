-- lcd_driver.vhd : hd44780 4-bit write-only driver
--
-- what it does: power-up init, then send one byte (rs + 8 bits) on request.
-- what it does NOT do: read the busy flag. rw is held low forever and we simply wait
-- the datasheet's worst-case execution time after every byte. reasons:
--   * simpler fsm (nothing to turn around, no bidirectional pins)
--   * safe: with rw = 0 the lcd never drives d4..d7, so a 5 v module can never push
--     5 v into the 3.3 v fpga pins.
--
-- time base: everything is counted in microseconds (us_tick = 1 pulse per us).
-- "wait n us" = load timer with n, then wait for a tick while timer = 0. the real wait
-- is between n and n+1 us, i.e. never shorter than n, which is what datasheet minimums need.
--
-- one nibble on the wire (all three phases >= 1 us; datasheet needs setup >= 80 ns,
-- e high >= 230 ns, cycle >= 500 ns, so we are ~4x over everywhere):
--
--   rs/d  ====<   valid   >====
--   e     ___________/‾‾‾‾‾\______
--         [  setup  ][ e hi ][ e lo ]
--
-- the lcd latches on the FALLING edge of e.
--
-- the driver is one state machine plus a microsecond timer. the hd44780 is used in 4-bit mode,
-- so every byte is sent as two nibbles (high nibble first), each nibble being one pulse on e:
--
--   s_powerup   wait powerup_us after reset (lcd needs time to come out of its own power-on reset)
--   s_load_step (init only) fetch entry 'step' of init_rom, put its high nibble on the pins
--   s_setup     rs / d are on the pins, wait >= 1 us (setup time), then raise e
--   s_e_high    wait >= 1 us (e pulse width), then drop e: the lcd latches the nibble now
--   s_e_low     wait >= 1 us (e low time). low nibble still pending? -> put it on the pins and
--               go back to s_setup. otherwise the byte is complete -> s_post
--   s_post      wait for the lcd to execute the instruction (post_us, worst case, since we never
--               read its busy flag). during init: continue with the next rom entry, or finish
--   s_idle      init finished and nothing to do; a 'start' pulse loads the byte and goes to s_setup
--
-- the init rom is walked once after every reset. while it runs 'ready' is '0'. after the last
-- entry 'ready' goes to '1' and the driver accepts requests through start / rs / data.
-- note that the init sequence leaves the display *off* (0x08); the user of this driver (lcd_term)
-- is expected to send the "display on" instruction itself once 'ready' is high.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lcd_driver is
    generic (
        clk_hz     : positive := 50_000_000;     -- frequency of clk in hz (must be a multiple of 1 mhz)
        powerup_us : natural  := 50_000          -- datasheet: > 15 ms (> 40 ms if vcc < 4.5 v). shrink for sim.
                                                 -- (loaded into a 16-bit timer: max 65535 us)
    );
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;                  -- synchronous, active high

        -- request interface:  wait for busy = '0', put rs/data on the bus, pulse start for 1 clk
        start  : in  std_logic;                  -- one-clock pulse: take rs / data and send them
        rs     : in  std_logic;                  -- '0' = instruction, '1' = character data
        data   : in  std_logic_vector(7 downto 0);
        busy   : out std_logic;                  -- '1' = do not issue a request (see below)
        ready  : out std_logic;                  -- init sequence finished

        -- pins to the lcd
        lcd_rs : out std_logic;
        lcd_rw : out std_logic;
        lcd_e  : out std_logic;
        lcd_d  : out std_logic_vector(7 downto 4)
    );
end entity;

architecture rtl of lcd_driver is
    ---------------------------------------------------------------------------
    -- init sequence (hd44780u datasheet, "initializing by instruction", 4-bit)
    ---------------------------------------------------------------------------
    -- one rom entry = one thing to send during init
    type init_step_t is record
        nibble_only : std_logic;                 -- '1': only the high nibble goes out (lcd still in 8-bit mode)
        value       : std_logic_vector(7 downto 0);
        wait_us     : natural;                   -- how long to wait afterwards
    end record;
    type init_rom_t is array (natural range <>) of init_step_t;

    constant init_rom : init_rom_t(0 to 7) := (
        ('1', x"30", 4500),    -- 0x3, "function set 8-bit".  wait > 4.1 ms
        ('1', x"30", 150),     -- 0x3 again.                  wait > 100 us
        ('1', x"30", 150),     -- 0x3 a third time
        ('1', x"20", 150),     -- 0x2 -> lcd switches to 4-bit mode (this is the last "single nibble")
        ('0', x"28", 50),      -- function set: 4-bit, 2 lines (4-line modules count as 2), 5x8 font
        ('0', x"08", 50),      -- display off
        ('0', x"01", 2000),    -- clear display (takes 1.52 ms)
        ('0', x"06", 50)       -- entry mode: address +1 after each write, no display shift
    );
    -- the repeated 0x3 is not a typo: it forces the lcd into a known state from ANY
    -- previous state (8-bit, 4-bit, half a byte received...), so pressing reset mid-write is fine.

    ---------------------------------------------------------------------------
    -- main fsm
    type state_t is (s_powerup, s_load_step, s_setup, s_e_high, s_e_low, s_post, s_idle);
    signal state : state_t := s_powerup;

    -- microsecond tick generator: us_cnt counts clocks, us_tick is a one-clock pulse every 1 us
    signal us_cnt    : integer range 0 to clk_hz / 1_000_000 - 1 := 0;
    signal us_tick   : std_logic := '0';
    -- down counter in microseconds; the fsm waits for it to hit 0 (see tmr_done)
    signal timer     : unsigned(15 downto 0) := (others => '0');     -- microseconds left
    signal tmr_done  : std_logic;
    -- init rom position and "init finished" flag (this is also the 'ready' output)
    signal step      : integer range 0 to init_rom'length - 1 := 0;
    signal init_done : std_logic := '0';
    -- the byte currently being sent: the low nibble waits here while the high nibble is on the wire
    signal lo_nib    : std_logic_vector(3 downto 0) := (others => '0');
    signal lo_pend   : std_logic := '0';                             -- low nibble still to send
    signal post_us   : unsigned(15 downto 0) := (others => '0');     -- wait after the whole byte
    -- registered lcd pins (glitch free outputs)
    signal rs_o      : std_logic := '0';
    signal e_o       : std_logic := '0';
    signal d_o       : std_logic_vector(3 downto 0) := (others => '0');

begin

    lcd_rs <= rs_o;
    lcd_rw <= '0';                             -- write-only, see header
    lcd_e  <= e_o;
    lcd_d  <= d_o;
    ready  <= init_done;

    -- busy is already '1' in the same clk where start = '1' (so the caller never sees a
    -- one-clock "busy = 0" hole between its start pulse and our state change)
    -- (this is a combinational output: it makes a requester that only issues while busy = '0'
    --  safe against back-to-back requests. 'start' is only acted on in s_idle; in every other
    --  state it is ignored.)
    busy <= '0' when state = s_idle and start = '0' else '1';

    -- 1 us tick
    -- counts clk_hz / 1e6 clocks (50 at 50 mhz) and emits one tick per round. free running:
    -- it is not reset, so the phase of the tick relative to a wait that was just loaded is
    -- arbitrary. that is exactly what the "n .. n+1 us" rule in the header accounts for.
    process (clk)
    begin
        if rising_edge(clk) then
            if us_cnt = clk_hz / 1_000_000 - 1 then
                us_cnt  <= 0;
                us_tick <= '1';
            else
                us_cnt  <= us_cnt + 1;
                us_tick <= '0';
            end if;
        end if;
    end process;

    -- "the timer has expired": it reached 0 *and* a new us tick arrives. so a wait of n us
    -- takes n ticks to count down plus one more tick to notice it, i.e. n .. n+1 us.
    tmr_done <= '1' when us_tick = '1' and timer = 0 else '0';

    process (clk)
        variable stp : init_step_t;
    begin
        if rising_edge(clk) then

            -- countdown. any "timer <= n" further down overrides this (last assignment wins)
            if us_tick = '1' and timer /= 0 then
                timer <= timer - 1;
            end if;

            case state is

                -- wait out the power-up delay (the reset branch at the end loaded the timer)
                when s_powerup =>
                    if tmr_done = '1' then
                        step  <= 0;
                        state <= s_load_step;
                    end if;

                -- fetch init rom entry #step and start sending it
                when s_load_step =>
                    stp     := init_rom(step);
                    rs_o    <= '0';                             -- init always uses instructions
                    d_o     <= stp.value(7 downto 4);           -- high nibble goes out first
                    e_o     <= '0';
                    lo_nib  <= stp.value(3 downto 0);
                    lo_pend <= not stp.nibble_only;             -- 8-bit-mode steps have no second nibble
                    post_us <= to_unsigned(stp.wait_us, 16);
                    timer   <= to_unsigned(1, 16);              -- setup time
                    state   <= s_setup;

                -- rs/d have been stable for >= 1 us -> raise e
                when s_setup =>
                    if tmr_done = '1' then
                        e_o   <= '1';
                        timer <= to_unsigned(1, 16);
                        state <= s_e_high;
                    end if;

                -- e was high >= 1 us -> drop e (lcd latches the nibble NOW)
                when s_e_high =>
                    if tmr_done = '1' then
                        e_o   <= '0';
                        timer <= to_unsigned(1, 16);
                        state <= s_e_low;
                    end if;

                -- e low for >= 1 us. second nibble, or done with this byte?
                when s_e_low =>
                    if tmr_done = '1' then
                        if lo_pend = '1' then
                            -- present the low nibble (rs_o is unchanged: both nibbles share rs)
                            d_o     <= lo_nib;
                            lo_pend <= '0';
                            timer   <= to_unsigned(1, 16);
                            state   <= s_setup;
                        else
                            timer <= post_us;                -- let the lcd chew on it
                            state <= s_post;
                        end if;
                    end if;

                -- the lcd is executing the instruction; once its worst-case time has passed
                -- either go on with the init sequence or become idle
                when s_post =>
                    if tmr_done = '1' then
                        if init_done = '0' then
                            if step = init_rom'length - 1 then
                                init_done <= '1';            -- that was the last init step
                                state     <= s_idle;
                            else
                                step  <= step + 1;
                                state <= s_load_step;
                            end if;
                        else
                            state <= s_idle;
                        end if;
                    end if;

                -- accept a request: latch it and start with the high nibble
                when s_idle =>
                    if start = '1' then
                        rs_o    <= rs;
                        d_o     <= data(7 downto 4);
                        e_o     <= '0';
                        lo_nib  <= data(3 downto 0);
                        lo_pend <= '1';
                        -- clear (0x01) and home (0x02) are the slow ones: 1.52 ms. everything else <= 37 us.
                        -- (the test also matches 0x00 and 0x03, harmless: they just wait a bit longer)
                        if rs = '0' and data(7 downto 2) = "000000" then
                            post_us <= to_unsigned(2000, 16);
                        else
                            post_us <= to_unsigned(50, 16);
                        end if;
                        timer <= to_unsigned(1, 16);
                        state <= s_setup;
                    end if;

            end case;

            -- synchronous reset, placed last so that it overrides everything above, in
            -- particular it can interrupt a transfer in progress. restarts the power-up wait and
            -- the whole init sequence (that is what makes the repeated 0x3 steps necessary).
            if rst = '1' then
                state     <= s_powerup;
                timer     <= to_unsigned(powerup_us, 16);
                init_done <= '0';
                e_o       <= '0';
                rs_o      <= '0';
                d_o       <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
