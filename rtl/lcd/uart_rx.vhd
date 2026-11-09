-- uart_rx.vhd : 8n1 uart receiver
--
-- idea: the line idles high. a start bit (low) tells us where a byte begins.
-- we then look at the line once per bit time, always in the *middle* of the bit
-- (that is where the signal is most stable), lsb first, and finish with a stop bit (high).
--
-- frame format 8n1: 1 start bit (0), 8 data bits (lsb first), no parity, 1 stop bit (1).
--
--   rx      idle  _____       _______ _______ _______       _______ ____
--                      \_____/ d0    X d1    X  ...  X d7    X stop
--                      start
--   sampled          ^     ^       ^       ^           ^       ^
--                    |  middle of  middle of each data bit   middle of stop bit
--                    |  start bit  (one full bit time apart)
--                    falling edge seen
--
-- the receiver is a four-state machine driven by one clock counter ('cnt') that counts clocks
-- inside the current bit:
--
--   s_idle   wait for the line to go low
--   s_start  count half a bit time to land in the middle of the start bit and check that the
--            line is still low (otherwise it was a glitch, back to idle)
--   s_data   every full bit time (= the middle of the next bit) shift one bit into 'shreg'
--   s_stop   one more bit time later: high = good byte ('valid' pulse), low = 'frame_err' pulse
--
-- the state machine goes back to s_idle right in the middle of the stop bit, which leaves half
-- a bit time of margin to catch the next start bit even if the sender is slightly fast.

library ieee;
use ieee.std_logic_1164.all;

entity uart_rx is
    generic (
        clk_hz : positive := 50_000_000;                    -- system clock in hz
        baud   : positive := 115_200                        -- bit rate; clk_hz / baud is rounded down
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;                      -- synchronous, active high
        rx        : in  std_logic;                      -- serial input, asynchronous to clk
        data      : out std_logic_vector(7 downto 0);   -- valid while 'valid' = '1'
        valid     : out std_logic;                      -- 1-clk pulse: a byte arrived
        frame_err : out std_logic                       -- 1-clk pulse: stop bit was low
    );
end entity;

architecture rtl of uart_rx is
    constant clks_per_bit : positive := clk_hz / baud;        -- 434 @ 50 mhz / 115200

    type state_t is (s_idle, s_start, s_data, s_stop);
    signal state : state_t := s_idle;

    signal rx_sync : std_logic_vector(1 downto 0) := "11";    -- 2-ff synchroniser (rx is async!)
    signal cnt     : integer range 0 to clks_per_bit - 1 := 0;     -- clocks elapsed inside the current bit
    signal bit_i   : integer range 0 to 7 := 0;                    -- index of the data bit being received
    signal shreg   : std_logic_vector(7 downto 0) := (others => '0');   -- receive shift register
begin

    process (clk)
    begin
        if rising_edge(clk) then
            -- two flip-flops in series so that a transition of the asynchronous rx input can't
            -- leave a metastable value in the state machine. only rx_sync(1) is ever used below.
            rx_sync   <= rx_sync(0) & rx;
            -- 'valid' and 'frame_err' are pulses: default to '0' every clock, the s_stop state
            -- overrides one of them for a single clock (last assignment wins)
            valid     <= '0';
            frame_err <= '0';

            case state is

                when s_idle =>
                    if rx_sync(1) = '0' then               -- falling edge: start bit begins
                        cnt   <= 0;
                        state <= s_start;
                    end if;

                when s_start =>                          -- walk to the middle of the start bit
                    if cnt = clks_per_bit / 2 - 1 then
                        cnt <= 0;                        -- restart the count: from here on it measures whole bits
                        if rx_sync(1) = '0' then             -- still low -> real start bit
                            bit_i <= 0;
                            state <= s_data;
                        else                                 -- it was a glitch
                            state <= s_idle;
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;

                when s_data =>                           -- one full bit later = middle of data bit
                    if cnt = clks_per_bit - 1 then
                        cnt   <= 0;
                        shreg <= rx_sync(1) & shreg(7 downto 1);   -- shift in from the top: lsb ends up at bit 0
                        -- (after 8 shifts the first received bit has travelled down to shreg(0))
                        if bit_i = 7 then
                            state <= s_stop;
                        else
                            bit_i <= bit_i + 1;
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;

                when s_stop =>                           -- middle of the stop bit
                    if cnt = clks_per_bit - 1 then
                        cnt   <= 0;
                        state <= s_idle;
                        -- the byte is complete in shreg. a correct stop bit is '1'; a '0' means
                        -- the line is not 8n1 at this baud rate (or a break): report an error
                        -- instead of delivering a byte that is probably garbage.
                        if rx_sync(1) = '1' then
                            valid <= '1';
                        else
                            frame_err <= '1';
                        end if;
                    else
                        cnt <= cnt + 1;
                    end if;

            end case;

            -- synchronous reset: abandon any frame in progress. only the state needs it, the
            -- counters are re-initialised on the way through s_idle / s_start.
            if rst = '1' then
                state <= s_idle;
            end if;
        end if;
    end process;

    -- the received byte is simply the shift register; it is only meaningful in the clock
    -- where 'valid' is '1' (it stays stable until the next frame's first data bit is shifted in)
    data <= shreg;

end architecture;
