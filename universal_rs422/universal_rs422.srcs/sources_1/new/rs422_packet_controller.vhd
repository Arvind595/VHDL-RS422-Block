library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.rs422_pkg.all;

entity rs422_packet_controller is
    generic (
        CLK_FREQ    : integer := 50_000_000;
        BAUD_RATE   : integer := 115200;
        NUM_BYTES   : integer := 8;
        TIMEOUT_MS  : integer := 5  -- Inter-byte stall recovery threshold
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- Hardware Physical Pins
        rs422_tx        : out std_logic;
        rs422_rx        : in  std_logic;

        -- User Control Interface
        tx_start        : in  std_logic;
        tx_data         : in  byte_array_t(0 to NUM_BYTES-1);
        tx_busy         : out std_logic;
        tx_done         : out std_logic;

        -- User Receive Interface
        rx_data         : out byte_array_t(0 to NUM_BYTES-1);
        rx_valid        : out std_logic;
        rx_timeout_err  : out std_logic;

        -- Hardware Debug Signals
        debug_rx_byte_cnt : out integer range 0 to NUM_BYTES;
        debug_tx_byte_cnt : out integer range 0 to NUM_BYTES
    );
end entity rs422_packet_controller;

architecture rtl of rs422_packet_controller is

    constant TIMEOUT_CYCLES : integer := (CLK_FREQ / 1000) * TIMEOUT_MS;

    -- PHY Interconnect Signals
    signal phy_tx_start : std_logic := '0';
    signal phy_tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    --signal phy_tx_busy  : std_logic;
    signal phy_tx_done  : std_logic;
    signal phy_rx_data  : std_logic_vector(7 downto 0);
    signal phy_rx_valid : std_logic;

    -- Packet Internal Buffers & Counters
    signal tx_buf       : byte_array_t(0 to NUM_BYTES-1);
    signal rx_buf       : byte_array_t(0 to NUM_BYTES-1);
    attribute keep : string;
    attribute keep of rx_buf : signal is "true"; -- Prevents Vivado from optimizing away unused bytes
    signal tx_cnt       : integer range 0 to NUM_BYTES := 0;
    signal rx_cnt       : integer range 0 to NUM_BYTES := 0;

    -- State Machines
    type tx_state_t is (IDLE, SEND_BYTE, WAIT_BYTE_DONE);
    signal tx_state     : tx_state_t := IDLE;

    -- RX Timer
    signal rx_timer     : integer range 0 to TIMEOUT_CYCLES := 0;

begin

    debug_rx_byte_cnt <= rx_cnt;
    debug_tx_byte_cnt <= tx_cnt;

    -- Low-level Byte Engine
    u_uart_phy : entity work.uart_phy
        generic map (
            CLK_FREQ  => CLK_FREQ,
            BAUD_RATE => BAUD_RATE
        )
        port map (
            clk      => clk,
            rst      => rst,
            tx_start => phy_tx_start,
            tx_data  => phy_tx_data,
            tx_busy  => open, --phy_tx_busy, -- <--- Change to 'open' (tells Vivado port is intentionally unused)
            tx_done  => phy_tx_done,
            tx_pin   => rs422_tx,
            rx_pin   => rs422_rx,
            rx_data  => phy_rx_data,
            rx_valid => phy_rx_valid
        );

    -------------------------------------------------------------------------
    -- Packet Transmission FSM
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phy_tx_data  <= (others => '0');
                tx_buf       <= (others => (others => '0'));
                tx_state     <= IDLE;
                phy_tx_start <= '0';
                tx_busy      <= '0';
                tx_done      <= '0';
                tx_cnt       <= 0;
            else
                phy_tx_start <= '0';
                tx_done      <= '0';

                case tx_state is
                    when IDLE =>
                        tx_busy <= '0';
                        if tx_start = '1' then
                            tx_buf   <= tx_data; -- Latch full array
                            tx_cnt   <= 0;
                            tx_busy  <= '1';
                            tx_state <= SEND_BYTE;
                        end if;

                    when SEND_BYTE =>
                        phy_tx_data  <= tx_buf(tx_cnt);
                        phy_tx_start <= '1';
                        tx_state     <= WAIT_BYTE_DONE;

                    when WAIT_BYTE_DONE =>
                        if phy_tx_done = '1' then
                            if tx_cnt = NUM_BYTES - 1 then
                                tx_done  <= '1';
                                tx_busy  <= '0';
                                tx_state <= IDLE;
                            else
                                tx_cnt   <= tx_cnt + 1;
                                tx_state <= SEND_BYTE;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Packet Reception & Inter-Byte Timeout Engine
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_cnt         <= 0;
                rx_valid       <= '0';
                rx_timeout_err <= '0';
                rx_timer       <= 0;
            else
                rx_valid       <= '0';
                rx_timeout_err <= '0';

                -- Inter-byte timeout counter active while collecting frames
                if rx_cnt > 0 then
                    if rx_timer < TIMEOUT_CYCLES then
                        rx_timer <= rx_timer + 1;
                    else
                        -- Frame Stalled: Auto-recover RX State
                        rx_cnt         <= 0;
                        rx_timer       <= 0;
                        rx_timeout_err <= '1'; -- Alert probe
                    end if;
                else
                    rx_timer <= 0;
                end if;

                -- Byte Receiver Engine
                if phy_rx_valid = '1' then
                    rx_timer <= 0; -- Reset timeout counter on incoming byte
                    
                    if rx_cnt = NUM_BYTES - 1 then
                        rx_buf(rx_cnt) <= phy_rx_data;
                        rx_data        <= rx_buf;
                        rx_data(NUM_BYTES - 1) <= phy_rx_data; -- Commit final byte
                        rx_valid       <= '1'; -- 8-byte frame completely received
                        rx_cnt         <= 0;
                    else
                        rx_buf(rx_cnt) <= phy_rx_data;
                        rx_cnt         <= rx_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;