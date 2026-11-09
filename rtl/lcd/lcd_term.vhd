-- lcd_term.vhd : 20x4 terminal engine for the hd44780 (4-bit, write-only, via lcd_driver)
--
--   byte stream in -> [ parser ] -> 20x4 character buffer -> [ refresher ] -> lcd_driver
--
-- * the parser handles one byte per clock and only ever touches the buffer, the cursor and
--   the cursor/blink mode bits. it never waits for the lcd, so a byte can't get lost.
-- * the refresher keeps a second copy ("shown") of what the lcd currently displays and
--   continuously walks over all 80 cells. whenever buffer /= shown it writes that cell
--   (plus a "set address" first if the lcd's address counter isn't already there).
--   so bursts, scrolls and clears are all just "buffer changed, catch up". intermediate
--   screens that were overwritten before the lcd got to them are never drawn.
-- * when everything is in sync the refresher parks the lcd's address counter on the
--   cursor, which is where the hardware cursor (underline / blink block) shows up.
--
-- terminal behaviour
--   0x20..0x7e, 0xa0..0xff   printable, written at the cursor. at col 19 the wrap is
--                            *deferred*: the cursor stays on col 19 until the next printable
--                            char, so a full 20-char bottom row doesn't scroll by itself.
--   \n (0x0a)                col 0 of the next row; on the last row the screen scrolls up
--   \r (0x0d)                col 0, same row     (so \r\n is one newline, like on a real tty)
--   \f (0x0c)                clear screen + home
--   \b (0x08), del (0x7f)    step left and erase
--   esc [ H / esc [ r ; c H  cursor to row r, col c (1-based, clamped; also 'f')
--   esc [ n A / B / C / D    cursor up / down / right / left by n (default 1), no scrolling
--   esc [ n J                0: cursor -> end of screen, 1: start -> cursor, 2: whole screen
--   esc [ n K                0: cursor -> end of row,    1: start of row -> cursor, 2: whole row
--   esc [ ? 25 h / l         hardware cursor (underline) on / off     (was sw0)
--   esc [ ? 12 h / l         blinking block on / off                  (was sw1)
--   everything else is swallowed (unknown escape sequences don't print garbage)
--
-- 'J' and 'K' do not move the cursor. a full clear that also homes is \f  (or esc [ 2 J esc [ H).
--
-- the design is two independent clocked processes that only communicate through signals:
--
--   parser     writes: buf, row, col, wrap_pend, cursor_on, blink_on   (+ its own esc state)
--   refresher  reads : buf, row, col, cursor_on, blink_on, in_valid
--              writes: shown, scan/lcd bookkeeping, and the lcd_* request outputs
--
-- the point of the split is decoupling: the lcd is *slow* (every write takes tens of
-- microseconds, a clear over a millisecond) while the byte stream can deliver one byte per
-- clock. the parser therefore never talks to the lcd. it just edits a 20x4 character array
-- ("buf"). the refresher then compares buf with "shown" (its model of what is physically on
-- the glass) and only sends the difference. consequences worth knowing when defending it:
--
--   * no fifo / no backpressure needed: the only "queue" is the screen buffer itself.
--   * the lcd work is bounded: at most 80 cell writes (+ a few set-address commands) to bring
--     the glass fully up to date, no matter how many bytes were received meanwhile.
--   * a character that was overwritten before the refresher reached it is simply never drawn.
--
-- contract with lcd_driver (it is not part of this file):
--   * lcd_ready = '1' once the driver's power-up / init sequence is finished. the init
--     sequence clears the display, which is why "shown" is reset to blanks while not ready.
--   * a request is only issued while lcd_busy = '0'. lcd_start is a one-clock pulse, with
--     lcd_rs / lcd_data valid in that same clock (rs = '0' command, rs = '1' character).
--   * the driver is assumed to have set the entry mode to "increment, no display shift", so
--     the lcd's address counter moves +1 after every character write. the refresher relies
--     on this to write runs of changed cells without re-sending the address.
--   * the driver must report busy for the whole transfer. this file does not check that.
--
-- screen coordinates: row 0..3, col 0..19. a cell can also be addressed by a flat index
-- "row * cols + col" (0..79), which is what the erase commands use.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lcd_term is
    port (
        clk, rst  : in  std_logic;                       -- rst: synchronous, active high

        -- byte stream: one byte per clock at most, no handshake needed
        in_valid  : in  std_logic;                       -- '1' for one clock when in_data holds a new byte
        in_data   : in  std_logic_vector(7 downto 0);    -- the received byte (e.g. from the uart)

        -- lcd_driver request interface
        lcd_start : out std_logic;                       -- one-clock pulse: "send this byte now"
        lcd_rs    : out std_logic;                       -- '0' = instruction, '1' = character data
        lcd_data  : out std_logic_vector(7 downto 0);    -- the byte to send
        lcd_busy  : in  std_logic;                       -- driver is busy: do not issue a request
        lcd_ready : in  std_logic                        -- driver finished its init sequence
    );
end entity;

architecture rtl of lcd_term is

    -- geometry of the display
    constant rows  : natural := 4;
    constant cols  : natural := 20;
    constant cells : natural := rows * cols;             -- 80 character cells in total

    -- the screen buffer: buf_t(row)(col) holds the 8-bit character code of that cell
    subtype byte_t is std_logic_vector(7 downto 0);
    type row_t is array (0 to cols - 1) of byte_t;
    type buf_t is array (0 to rows - 1) of row_t;

    -- 0x20 is the ascii space, which is also a blank cell in the hd44780 character rom
    constant blank     : byte_t := x"20";
    constant blank_row : row_t  := (others => blank);
    constant blank_buf : buf_t  := (others => blank_row);

    -- screen row -> ddram address of its first character (the "1-3-2-4" layout of 20x4 glass)
    -- (the controller thinks of the display as two 40-char lines; a 20x4 glass splits each
    --  of them in half: row 0 = 0x00.., row 2 = 0x14.. (continues line 1), row 1 = 0x40..,
    --  row 3 = 0x54.. (continues line 2). 0x14 = 20, 0x54 = 0x40 + 20.)
    type base_t is array (0 to rows - 1) of natural;
    constant row_base : base_t := (16#00#, 16#40#, 16#14#, 16#54#);

    -- returns the buffer shifted up by one row: row 1 becomes row 0, and so on, and the
    -- bottom row is blanked. the old row 0 is lost. used when a newline happens on the last row.
    function scroll_up (b : buf_t) return buf_t is
        variable n : buf_t;
    begin
        for i in 0 to rows - 2 loop
            n(i) := b(i + 1);
        end loop;
        n(rows - 1) := blank_row;
        return n;
    end function;

    -- saturating clamp of an integer to 0..255. used while collecting decimal escape-sequence
    -- parameters so that absurdly long numbers ("99999") stick at 255 instead of overflowing
    -- the 0..255 range of the p0 / p1 signals.
    function sat (v : integer) return natural is
    begin
        if v > 255 then
            return 255;
        else
            return v;
        end if;
    end function;

    ---------------------------------------------------------------------------
    -- parser state
    ---------------------------------------------------------------------------
    signal buf       : buf_t := blank_buf;                 -- the screen contents (what *should* be shown)
    signal row       : natural range 0 to rows - 1 := 0;   -- cursor row
    signal col       : natural range 0 to cols - 1 := 0;   -- cursor column
    -- deferred wrap flag: set after a character was written to col 19. the cursor then still
    -- *sits* on col 19 but logically is "past the end of the line"; the wrap (col 0 of the next
    -- row, possibly scrolling) only happens when the next printable character arrives.
    signal wrap_pend : boolean := false;
    signal cursor_on : std_logic := '0';                   -- esc [ ? 25 h/l : underline cursor
    signal blink_on  : std_logic := '0';                   -- esc [ ? 12 h/l : blinking block

    -- escape sequence recogniser (a small state machine):
    --   esc_none : normal text
    --   esc_got  : an ESC (0x1b) was seen, waiting for '['
    --   esc_csi  : inside "ESC [", collecting parameters until the final byte
    type esc_t is (esc_none, esc_got, esc_csi);
    signal esc  : esc_t := esc_none;
    signal p0   : natural range 0 to 255 := 0;             -- first numeric parameter (saturating)
    signal p1   : natural range 0 to 255 := 0;             -- second numeric parameter (after ';')
    signal pidx : natural range 0 to 1   := 0;             -- which parameter the digits go to
    signal priv : boolean := false;                        -- a '?' was seen: private mode sequence

    ---------------------------------------------------------------------------
    -- refresher state
    ---------------------------------------------------------------------------
    signal shown      : buf_t := blank_buf;                -- what the lcd displays right now
    signal scan_r     : natural range 0 to rows - 1 := 0;  -- the cell the refresher is looking at
    signal scan_c     : natural range 0 to cols - 1 := 0;
    signal lcd_r      : natural range 0 to rows - 1 := 0;  -- where the lcd's address counter is
    signal lcd_c      : natural range 0 to cols - 1 := 0;
    signal lcd_valid  : boolean := false;                  -- lcd_r/lcd_c are trustworthy
    signal quiet      : natural range 0 to cells := 0;     -- consecutive cells without a difference
    -- the display on/off/cursor/blink instruction (0000 1DCB) is sent separately from the cells:
    signal disp_valid : boolean := false;                  -- a display-control command was sent since (re)init
    signal disp_sent  : std_logic_vector(1 downto 0) := "00";  -- the (cursor, blink) bits last sent

begin

    ---------------------------------------------------------------------------
    -- parser
    --
    -- one byte per clock. all screen edits for a byte are computed in *variables*
    -- (nb, r, c, wp = "new buffer", "new row", "new col", "new wrap flag"), which start as a
    -- copy of the current signals, get modified step by step (so later steps see the effect of
    -- earlier ones, e.g. scroll then write), and are written back to the signals once at the
    -- very end. this keeps the whole update atomic: the refresher never sees a half-done edit.
    --
    -- the escape-sequence state (esc, p0, p1, pidx, priv) and the mode bits are assigned
    -- directly as signals; that is fine because they are only read on a *later* byte.
    ---------------------------------------------------------------------------
    parser : process (clk)
        variable b      : natural range 0 to 255;
        variable nb     : buf_t;
        variable r      : natural range 0 to rows - 1;
        variable c      : natural range 0 to cols - 1;
        variable wp     : boolean;
        variable n      : natural range 1 to 255;       -- repeat count (0 counts as 1)
        variable cur    : natural range 0 to cells - 1; -- cursor as a cell index
        variable lo, hi : integer;                      -- erase range (inclusive cell indices)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- synchronous reset: blank screen, cursor home, modes off, no pending escape.
                -- (p0 / p1 / pidx / priv need no reset: they are re-initialised on every "ESC [".)
                buf       <= blank_buf;
                row       <= 0;
                col       <= 0;
                wrap_pend <= false;
                cursor_on <= '0';
                blink_on  <= '0';
                esc       <= esc_none;

            elsif in_valid = '1' then
                -- take a working copy of the state for this byte
                b  := to_integer(unsigned(in_data));
                nb := buf;
                r  := row;
                c  := col;
                wp := wrap_pend;

                case esc is

                    -------------------------------------------------------------- plain text
                    when esc_none =>
                        if b = 27 then                                       -- ESC
                            esc <= esc_got;

                        elsif (b >= 32 and b <= 126) or b >= 160 then        -- printable
                            if wp then                                       -- deferred wrap happens now
                                wp := false;
                                c  := 0;
                                if r = rows - 1 then
                                    nb := scroll_up(nb);                     -- on the last row: scroll
                                else
                                    r := r + 1;
                                end if;
                            end if;
                            nb(r)(c) := in_data;                             -- store the character
                            if c = cols - 1 then
                                wp := true;                                  -- stay on col 19, wrap later
                            else
                                c := c + 1;
                            end if;

                        elsif b = 10 then                                    -- \n
                            -- line feed *and* carriage return in one (like a "cooked" tty)
                            wp := false;
                            c  := 0;
                            if r = rows - 1 then
                                nb := scroll_up(nb);
                            else
                                r := r + 1;
                            end if;

                        elsif b = 13 then                                    -- \r
                            wp := false;
                            c  := 0;

                        elsif b = 12 then                                    -- \f
                            nb := blank_buf;
                            wp := false;
                            r  := 0;
                            c  := 0;

                        elsif b = 8 or b = 127 then                          -- backspace / del
                            if wp then
                                -- the cursor is logically past col 19, so "one step left"
                                -- lands on col 19 itself: erase it, but don't move.
                                wp := false;                                 -- cursor was "past" col 19
                                nb(r)(c) := blank;
                            elsif c > 0 then
                                c := c - 1;
                                nb(r)(c) := blank;
                            end if;
                            -- at col 0 nothing happens (no wrapping back to the previous row)
                        end if;
                        -- any other control code (0x00..0x1f, 0x80..0x9f) is ignored

                    -------------------------------------------------------------- after ESC
                    when esc_got =>
                        if b = 91 then                                       -- '['
                            -- start of a CSI sequence: clear the parameter collector
                            esc  <= esc_csi;
                            p0   <= 0;
                            p1   <= 0;
                            pidx <= 0;
                            priv <= false;
                        elsif b /= 27 then
                            -- ESC followed by anything else (except another ESC) is an
                            -- unsupported escape: swallow both bytes and go back to text.
                            -- (ESC ESC stays in esc_got: the second ESC restarts the sequence.)
                            esc <= esc_none;
                        end if;

                    -------------------------------------------------------------- inside ESC [ ...
                    when esc_csi =>
                        if b >= 48 and b <= 57 then                          -- digit
                            -- append the digit to the current parameter: p = p * 10 + digit
                            if pidx = 0 then
                                p0 <= sat(p0 * 10 + (b - 48));
                            else
                                p1 <= sat(p1 * 10 + (b - 48));
                            end if;

                        elsif b = 59 then                                    -- ';'
                            -- switch to the second parameter (further ';' stay on the second one)
                            pidx <= 1;

                        elsif b = 63 then                                    -- '?'
                            priv <= true;

                        elsif b = 27 then                                    -- ESC again: start over
                            esc <= esc_got;

                        elsif b >= 64 and b <= 126 then                      -- final byte: execute
                            -- every command ends with a byte in 0x40..0x7e. it selects the
                            -- action; p0 / p1 (as they are *now*) are its arguments.
                            esc <= esc_none;
                            if p0 = 0 then
                                n := 1;                                      -- missing / 0 means 1
                            else
                                n := p0;
                            end if;
                            cur := r * cols + c;                             -- cursor as a flat cell index

                            case b is
                                when 72 | 102 =>                             -- 'H' / 'f'  cursor position
                                    -- row = p0, col = p1, both 1-based; 0 / missing -> 1, too big -> last
                                    wp := false;
                                    if p0 <= 1 then
                                        r := 0;
                                    elsif p0 >= rows then
                                        r := rows - 1;
                                    else
                                        r := p0 - 1;
                                    end if;
                                    if p1 <= 1 then
                                        c := 0;
                                    elsif p1 >= cols then
                                        c := cols - 1;
                                    else
                                        c := p1 - 1;
                                    end if;

                                -- relative moves: clamped at the screen edge, never scroll
                                when 65 =>                                   -- 'A' up
                                    wp := false;
                                    if r >= n then
                                        r := r - n;
                                    else
                                        r := 0;
                                    end if;
                                when 66 =>                                   -- 'B' down
                                    wp := false;
                                    if r + n >= rows then
                                        r := rows - 1;
                                    else
                                        r := r + n;
                                    end if;
                                when 67 =>                                   -- 'C' right
                                    wp := false;
                                    if c + n >= cols then
                                        c := cols - 1;
                                    else
                                        c := c + n;
                                    end if;
                                when 68 =>                                   -- 'D' left
                                    wp := false;
                                    if c >= n then
                                        c := c - n;
                                    else
                                        c := 0;
                                    end if;

                                when 74 | 75 =>                              -- 'J' / 'K' erase
                                    -- pick the inclusive range lo..hi of flat cell indices to blank.
                                    -- p0 = 0 -> cursor to end, p0 = 1 -> start to cursor (cursor cell
                                    -- included both times), anything else -> everything.
                                    if b = 74 then                           -- J: screen
                                        if p0 = 0 then
                                            lo := cur;
                                            hi := cells - 1;
                                        elsif p0 = 1 then
                                            lo := 0;
                                            hi := cur;
                                        else
                                            lo := 0;
                                            hi := cells - 1;
                                        end if;
                                    else                                     -- K: row
                                        if p0 = 0 then
                                            lo := cur;
                                            hi := r * cols + cols - 1;
                                        elsif p0 = 1 then
                                            lo := r * cols;
                                            hi := cur;
                                        else
                                            lo := r * cols;
                                            hi := r * cols + cols - 1;
                                        end if;
                                    end if;
                                    -- blank the range. written as a loop over all cells with a
                                    -- range test so that it synthesises to constant comparators
                                    -- (no dynamic indexing of the 2-d array needed).
                                    for i in 0 to cells - 1 loop
                                        if i >= lo and i <= hi then
                                            nb(i / cols)(i mod cols) := blank;
                                        end if;
                                    end loop;
                                    -- note: the cursor and the wrap flag are deliberately untouched

                                when 104 | 108 =>                            -- 'h' / 'l' modes (only esc [ ? n h/l)
                                    -- 'h' = set (on), 'l' = reset (off). only the private modes
                                    -- 25 (cursor) and 12 (blink) exist; without the '?' it is ignored.
                                    if priv then
                                        if p0 = 25 then
                                            if b = 104 then
                                                cursor_on <= '1';
                                            else
                                                cursor_on <= '0';
                                            end if;
                                        elsif p0 = 12 then
                                            if b = 104 then
                                                blink_on <= '1';
                                            else
                                                blink_on <= '0';
                                            end if;
                                        end if;
                                    end if;

                                when others => null;                         -- unknown: swallowed
                            end case;
                        end if;
                        -- bytes inside a sequence that are none of the above (e.g. space, ':',
                        -- '<', '=', '>') are silently ignored and the sequence continues.
                end case;

                -- write the working copy back (all four take effect together on the next clock)
                buf       <= nb;
                row       <= r;
                col       <= c;
                wrap_pend <= wp;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- refresher: make the lcd look like 'buf'
    --
    -- every clock in which the driver is idle, exactly one of the following happens
    -- (checked in this priority order, see the if/elsif chain below):
    --   1. (re)send the display-control command if the cursor/blink mode changed
    --   2. the cell under the scan pointer differs from what is shown -> write it
    --      (or, if the lcd's address counter is elsewhere, first set the address)
    --   3. a whole lap over all 80 cells found nothing to do -> park the address counter on
    --      the cursor so the hardware cursor appears in the right place
    --   4. otherwise advance the scan pointer to the next cell
    -- each request goes out as a single one-clock lcd_start pulse; the driver then raises
    -- lcd_busy and nothing else is issued until it is idle again.
    ---------------------------------------------------------------------------
    refresher : process (clk)

        -- send one byte to the driver (only called when lcd_busy = '0')
        -- rs = '0': instruction, rs = '1': character data. lcd_start is cleared again at the
        -- top of the process on the next clock, so it is a one-clock pulse.
        procedure issue (rs : std_logic; d : byte_t) is
        begin
            lcd_start <= '1';
            lcd_rs    <= rs;
            lcd_data  <= d;
        end procedure;

        -- "set ddram address" instruction for screen cell (r, c): 1aaaaaaa, a = row base + col
        function ddram_cmd (r, c : natural) return byte_t is
        begin
            return std_logic_vector(to_unsigned(128 + row_base(r) + c, 8));
        end function;

        variable want : std_logic_vector(1 downto 0);   -- the (cursor, blink) bits we want on the lcd
    begin
        if rising_edge(clk) then
            lcd_start <= '0';                           -- default: no request this clock
            want := cursor_on & blink_on;

            if rst = '1' or lcd_ready = '0' then
                -- (re)initialising: the driver's init sequence clears the lcd, so it shows spaces
                -- everything we believed about the lcd is void -> start from scratch
                shown      <= blank_buf;
                scan_r     <= 0;
                scan_c     <= 0;
                lcd_valid  <= false;
                disp_valid <= false;
                quiet      <= 0;

            elsif lcd_busy = '0' then
                -- the driver can take a request

                if (not disp_valid) or disp_sent /= want then
                    -- display on (+ cursor / blink): 0000 1DCB
                    -- D (display on) is always 1, C / B come from cursor_on / blink_on.
                    -- sent once after every (re)init, and again whenever the modes change.
                    issue('0', "000011" & want);
                    disp_sent  <= want;
                    disp_valid <= true;

                elsif buf(scan_r)(scan_c) /= shown(scan_r)(scan_c) then
                    -- this cell is out of date. any change means the "quiet lap" is broken.
                    quiet <= 0;
                    if lcd_valid and lcd_r = scan_r and lcd_c = scan_c then
                        -- lcd is already at this cell (entry mode: address +1 after each write)
                        issue('1', buf(scan_r)(scan_c));
                        shown(scan_r)(scan_c) <= buf(scan_r)(scan_c);
                        if scan_c = cols - 1 then
                            -- the last column was written: the address counter has run off the
                            -- end of the row. thanks to the 1-3-2-4 layout it is *not* at the
                            -- start of the next screen row (after row 0 it is 0x14 = row 2,
                            -- after row 1 it is 0x54 = row 3, after rows 2 / 3 it is 0x28 /
                            -- 0x68 = invisible), so don't trust it any more.
                            lcd_valid <= false;                 -- the counter now points somewhere else
                            scan_c    <= 0;
                            if scan_r = rows - 1 then
                                scan_r <= 0;
                            else
                                scan_r <= scan_r + 1;
                            end if;
                        else
                            -- stay in sync with the lcd's auto-increment, move to the next cell
                            lcd_c  <= scan_c + 1;
                            scan_c <= scan_c + 1;
                        end if;
                    else
                        -- the address counter is not where we need it (or unknown):
                        -- send "set address" now; scan pointer stays, so next time this cell
                        -- is retried and takes the branch above.
                        issue('0', ddram_cmd(scan_r, scan_c));   -- set address, then retry this cell
                        lcd_r     <= scan_r;
                        lcd_c     <= scan_c;
                        lcd_valid <= true;
                    end if;

                elsif quiet = cells and not (lcd_valid and lcd_r = row and lcd_c = col) then
                    -- everything is drawn: park the address counter (= hardware cursor) on the cursor
                    -- (only when the counter is not already there, otherwise this would repeat forever)
                    issue('0', ddram_cmd(row, col));
                    lcd_r     <= row;
                    lcd_c     <= col;
                    lcd_valid <= true;

                else
                    -- nothing to do for this cell: look at the next one
                    -- "quiet" counts how many cells in a row were already up to date; when it
                    -- reaches 80 a complete lap was clean and the screen is fully in sync.
                    if quiet < cells then
                        quiet <= quiet + 1;
                    end if;
                    if scan_c = cols - 1 then
                        scan_c <= 0;
                        if scan_r = rows - 1 then
                            scan_r <= 0;
                        else
                            scan_r <= scan_r + 1;
                        end if;
                    else
                        scan_c <= scan_c + 1;
                    end if;
                end if;
            end if;

            -- the parser just changed something: a "full quiet pass" has to start over
            -- (this is the last assignment to quiet in the process, so it wins over any
            --  assignment made above in the same clock.)
            if in_valid = '1' then
                quiet <= 0;
            end if;
        end if;
    end process;

end architecture;
