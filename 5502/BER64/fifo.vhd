-------------------------------------------------------------
-- Filename:  FIFO.VHD
-- Authors: 
--		Alain Zarembowitch / MSS
-- Version: Rev 1
-- Last modified: 8/25/20

-- Inheritance: 	N/A
--
-- description:  synthesizable generic FIFO
-- generally synthesized as LUTs, LUTRAMs (not BRAM)
-- Use delay.vhd for large delays implemented as BRAMs.
--
-- Rev1 8/25/20 AZ
-- Added SYNC_RESET 
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity FIFO is
	 Generic (
		DATA_WIDTH: integer := 8;	
		DEPTH: integer := 32
	);
    Port ( 
		CLK   : in  std_logic;
		SYNC_RESET   : in  std_logic;
		DATA_IN   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
		DATA_IN_VALID  : in std_logic;
		DATA_OUT   : out  std_logic_vector(DATA_WIDTH-1 downto 0);
		DATA_OUT_VALID  : out std_logic
			-- 1 CLK latency w.r.t. DATA_IN_VALID
		);
end entity;

architecture Behavioral of FIFO is
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
type FIFOtype is array (0 to DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
signal DATA1: FIFOtype := (others => (others => '0'));
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

FIFO_001: process(CLK)
begin
	if rising_edge(CLK) then
		DATA_OUT_VALID <= DATA_IN_VALID;
		if(SYNC_RESET = '1') then	-- *082520
			DATA1 <= (others => (others => '0'));
		elsif(DATA_IN_VALID = '1') then
			DATA1(0) <= DATA_IN;
			for I in 1 to DEPTH-1 loop
				DATA1(I) <= DATA1(I-1);
			end loop;
		end if;
	end if;
end process;

DATA_OUT <= DATA1(DEPTH-1);

end Behavioral;
