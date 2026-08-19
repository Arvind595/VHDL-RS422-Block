library ieee;
use ieee.std_logic_1164.all;

package rs422_pkg is
    -- Unconstrained array: dynamically sized based on NUM_BYTES generic
    type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
end package rs422_pkg;