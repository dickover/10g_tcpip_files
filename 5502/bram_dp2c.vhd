-------------------------------------------------------------
-- Filename:  BRAM_DP2C.VHD
-- Authors: 
-- 	Xilinx UG901 Simple Dual-Port Block RAM with Single Clock (VHDL)
--		Alain Zarembowitch / MSS
-- Version: 0
-- Last modified: 12/21/20

-- Inheritance: 	BRAM_DP2.VHD Rev2 6/29/16
--
-- description:  synthesizable generic dual port RAM. Variant of BRAM_DP2.VHD 
-- single clock, same data width on A/B sides, A-side write, B-side read.
-- Registered output.
-- Inferred block RAM
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity BRAM_DP2C is
	 Generic (
		DATA_WIDTH: integer := 9;	
		ADDR_WIDTH: integer := 11	
	);
    Port ( 
		CLK   : in  std_logic;
		
	    -- Port A
		CSA: in std_logic;	-- chip select, active high
		WEA    : in  std_logic;	-- write enable, active high
		ADDRA  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
		DIA   : in  std_logic_vector(DATA_WIDTH-1 downto 0);

		-- Port B
		CSB: in std_logic;	-- chip select, active high
		ADDRB  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
		DOB  : out std_logic_vector(DATA_WIDTH-1 downto 0)
		);
end entity;

architecture Behavioral of BRAM_DP2C is
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------function
-- inferred
type mem_type is array ( (2**ADDR_WIDTH)-1 downto 0 ) of std_logic_vector(DATA_WIDTH-1 downto 0);
shared variable MEM : mem_type := (others => (others => '0'));
signal DOB_local: std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- Port A write
process(CLK)
begin
	if rising_edge(CLK) then
		if(CSA = '1') then
			if (WEA = '1') then
				mem(to_integer(unsigned(ADDRA))) := DIA;
			end if;
		end if;
	end if;
end process;

-- Port B
process(CLK)
begin
	if rising_edge(CLK) then
		if(CSB = '1') then
			DOB <= mem(to_integer(unsigned(ADDRB)));
		end if;
	end if;
end process;

end Behavioral;
