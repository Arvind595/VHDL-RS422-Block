library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_phy is
    generic (
        CLK_FREQ  : integer := 50_000_000;
        BAUD_RATE : integer := 115200
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        
        -- TX Interface
        tx_start  : in  std_logic;
        tx_data   : in  std_logic_vector(7 downto 0);
        tx_busy   : out std_logic;
        tx_done   : out std_logic;
        tx_pin    : out std_logic;

        -- RX Interface
        rx_pin    : in  std_logic;
        rx_data   : out std_logic_vector(7 downto 0);
        rx_valid  : out std_logic
    );
end entity uart_phy;

architecture rtl of uart_phy is
    constant CLKS_PER_BIT : integer := CLK_FREQ / BAUD_RATE;

    -- RX Synchronizer (Prevents metastability)
    signal rx_sync_reg    : std_logic_vector(1 downto 0) := "11";
    signal rx_sync        : std_logic;

    -- TX Signals
    type tx_state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal tx_state       : tx_state_t := IDLE;
    signal tx_clk_cnt     : integer range 0 to CLKS_PER_BIT := 0;
    signal tx_bit_idx     : integer range 0 to 7 := 0;
    signal tx_shift_reg   : std_logic_vector(7 downto 0) := (others => '0');

    -- RX Signals
    type rx_state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal rx_state       : rx_state_t := IDLE;
    signal rx_clk_cnt     : integer range 0 to CLKS_PER_BIT := 0;
    signal rx_bit_idx     : integer range 0 to 7 := 0;
    signal rx_shift_reg   : std_logic_vector(7 downto 0) := (others => '0');

begin

    -- Synchronize asynchronous RX pin to FPGA system clock
    process(clk)
    begin
        if rising_edge(clk) then
            rx_sync_reg <= rx_sync_reg(0) & rx_pin;
        end if;
    end process;
    rx_sync <= rx_sync_reg(1);

    -------------------------------------------------------------------------
    -- Transmitter FSM
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_shift_reg <= (others => '1');
                tx_state   <= IDLE;
                tx_pin     <= '1';
                tx_busy    <= '0';
                tx_done    <= '0';
                tx_clk_cnt <= 0;
                tx_bit_idx <= 0;
            else
                tx_done <= '0'; -- Single-clock pulse

                case tx_state is
                    when IDLE =>
                        tx_pin  <= '1';
                        tx_busy <= '0';
                        if tx_start = '1' then
                            tx_shift_reg <= tx_data;
                            tx_busy      <= '1';
                            tx_clk_cnt   <= 0;
                            tx_state     <= START_BIT;
                        end if;

                    when START_BIT =>
                        tx_pin <= '0'; -- Start bit = Logic '0'
                        if tx_clk_cnt < CLKS_PER_BIT - 1 then
                            tx_clk_cnt <= tx_clk_cnt + 1;
                        else
                            tx_clk_cnt <= 0;
                            tx_bit_idx <= 0;
                            tx_state   <= DATA_BITS;
                        end if;

                    when DATA_BITS =>
                        tx_pin <= tx_shift_reg(tx_bit_idx);
                        if tx_clk_cnt < CLKS_PER_BIT - 1 then
                            tx_clk_cnt <= tx_clk_cnt + 1;
                        else
                            tx_clk_cnt <= 0;
                            if tx_bit_idx < 7 then
                                tx_bit_idx <= tx_bit_idx + 1;
                            else
                                tx_state <= STOP_BIT;
                            end if;
                        end if;

                    when STOP_BIT =>
                        tx_pin <= '1'; -- Stop bit = Logic '1'
                        if tx_clk_cnt < CLKS_PER_BIT - 1 then
                            tx_clk_cnt <= tx_clk_cnt + 1;
                        else
                            tx_clk_cnt <= 0;
                            tx_done    <= '1';
                            tx_busy    <= '0';
                            tx_state   <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Receiver FSM
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_state   <= IDLE;
                rx_valid   <= '0';
                rx_clk_cnt <= 0;
                rx_bit_idx <= 0;
                rx_data    <= (others => '0');
                rx_shift_reg <= (others => '0');
            else
                rx_valid <= '0'; -- Single-clock pulse

                case rx_state is
                    when IDLE =>
                        rx_clk_cnt <= 0;
                        if rx_sync = '0' then -- Falling edge of Start bit
                            rx_state <= START_BIT;
                        end if;

                    when START_BIT =>
                        -- Mid-bit sampling point
                        if rx_clk_cnt = (CLKS_PER_BIT / 2) then
                            if rx_sync = '0' then -- Valid Start Bit verified
                                rx_clk_cnt <= 0;
                                rx_bit_idx <= 0;
                                rx_state   <= DATA_BITS;
                            else
                                rx_state   <= IDLE; -- Glitch / False Start
                            end if;
                        else
                            rx_clk_cnt <= rx_clk_cnt + 1;
                        end if;

                    when DATA_BITS =>
                        if rx_clk_cnt < CLKS_PER_BIT - 1 then
                            rx_clk_cnt <= rx_clk_cnt + 1;
                        else
                            rx_clk_cnt <= 0;
                            rx_shift_reg(rx_bit_idx) <= rx_sync;
                            if rx_bit_idx < 7 then
                                rx_bit_idx <= rx_bit_idx + 1;
                            else
                                rx_state <= STOP_BIT;
                            end if;
                        end if;

                    when STOP_BIT =>
                        if rx_clk_cnt < CLKS_PER_BIT - 1 then
                            rx_clk_cnt <= rx_clk_cnt + 1;
                        else
                            rx_clk_cnt <= 0;
                            if rx_sync = '1' then -- Stop bit valid
                                rx_data  <= rx_shift_reg;
                                rx_valid <= '1';
                            end if;
                            rx_state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;