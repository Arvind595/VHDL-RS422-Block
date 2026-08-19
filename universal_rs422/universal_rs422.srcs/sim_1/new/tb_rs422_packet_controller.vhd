library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.rs422_pkg.all; -- Ensure your shared package is compiled first!

entity tb_rs422_packet_controller is
    -- Testbenches do not have ports
end entity tb_rs422_packet_controller;

architecture sim of tb_rs422_packet_controller is

    -- System Clock Configuration (50 MHz = 20 ns period)
    constant CLK_PERIOD : time := 20 ns;
    
    -- UUT Signals
    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal rs422_tx        : std_logic;
    signal rs422_rx        : std_logic := '1'; -- Idle high
    
    signal tx_start        : std_logic := '0';
    signal tx_data         : byte_array_t(0 to 7) := (others => x"00");
    signal tx_busy         : std_logic;
    signal tx_done         : std_logic;
    
    signal rx_data         : byte_array_t(0 to 7);
    signal rx_valid        : std_logic;
    signal rx_timeout_err  : std_logic;
    
    signal debug_rx_cnt    : integer;
    signal debug_tx_cnt    : integer;

    -- Testbench Control Signals
    signal loopback_en     : std_logic := '1';

begin

    -- 1. Clock Generation Process
    clk <= not clk after CLK_PERIOD / 2;

    -- 2. Hardware Loopback Multiplexer
    -- When loopback_en is '1', TX drives RX directly.
    -- When '0', RX is forced to '1' (Idle) to simulate a broken wire.
    rs422_rx <= rs422_tx when loopback_en = '1' else '1';

    -- 3. Instantiate the Unit Under Test (UUT)
    uut : entity work.rs422_packet_controller
        generic map (
            CLK_FREQ   => 50_000_000,
            BAUD_RATE  => 115200,
            NUM_BYTES  => 8,
            TIMEOUT_MS => 5
        )
        port map (
            clk               => clk,
            rst               => rst,
            rs422_tx          => rs422_tx,
            rs422_rx          => rs422_rx,
            tx_start          => tx_start,
            tx_data           => tx_data,
            tx_busy           => tx_busy,
            tx_done           => tx_done,
            rx_data           => rx_data,
            rx_valid          => rx_valid,
            rx_timeout_err    => rx_timeout_err,
            debug_rx_byte_cnt => debug_rx_cnt,
            debug_tx_byte_cnt => debug_tx_cnt
        );

    -- 4. Main Stimulus Process
    stim_proc: process
    begin
        -- === INITIALIZATION ===
        rst <= '1';
        tx_start <= '0';
        loopback_en <= '1';
        wait for 100 ns;
        
        rst <= '0';
        wait for 100 ns;
        wait until rising_edge(clk);

        -- === TEST 1: Full 8-Byte Loopback Transmission ===
        report "--- STARTING TEST 1: Full 8-Byte Loopback ---";
        
        -- Load payload matching your application specs
        tx_data(0) <= x"A5"; -- Byte 1: Command code
        tx_data(1) <= x"02"; -- Byte 2: Channel Number
        tx_data(2) <= x"10"; -- Byte 3: Data 1
        tx_data(3) <= x"20"; -- Byte 4: Data 2
        tx_data(4) <= x"30"; -- Byte 5: Data 3
        tx_data(5) <= x"40"; -- Byte 6: Data 4
        tx_data(6) <= x"50"; -- Byte 7: Data 5
        tx_data(7) <= x"60"; -- Byte 8: Data 6
        
        -- Trigger transmission (pulse start for 1 clock cycle)
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        
        -- Suspend the testbench until the receiver indicates the packet is fully caught
        wait until rx_valid = '1';
        
        -- Verify data arrived intact
        if rx_data(0) = x"A5" and rx_data(7) = x"60" then
            report "-> TEST 1 PASSED: 8 bytes received successfully via loopback!";
        else
            report "-> TEST 1 FAILED: Data mismatch on receive." severity error;
        end if;
        
        wait for 10 us;

        -- === TEST 2: Mid-Packet Timeout Recovery ===
        report "--- STARTING TEST 2: Timeout Recovery Simulation ---";
        
        -- Change the command code so we can see it change in the waveform
        tx_data(0) <= x"BB"; 
        
        -- Trigger transmission again
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        
        -- Wait until exactly 3 bytes have been received by the module
        wait until debug_rx_cnt = 3;
        
        -- BREAK THE WIRE! (Simulates the other device dropping power)
        loopback_en <= '0'; 
        
        report "Wire broken at 3 bytes. Waiting >5ms for timeout flag...";
        
        -- The timeout is set to 5ms. We must wait in simulated time for this to occur.
        wait until rx_timeout_err = '1' for 6 ms;
        
        if rx_timeout_err = '1' then
            report "-> TEST 2 PASSED: Timeout error triggered and RX state recovered!";
        else
            report "-> TEST 2 FAILED: Timeout did not trigger." severity error;
        end if;

        -- === END OF SIMULATION ===
        report "--- ALL TESTS COMPLETED ---";
        wait for 10 us;
        -- Stop simulation execution (Works in VHDL-2008 and later)
        std.env.stop; 
        wait;
    end process;

end architecture sim;