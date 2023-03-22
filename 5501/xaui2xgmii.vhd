-------------------------------------------------------------
-- Filename:  XAUI2XGMII.VHD
-- Authors: 
--		Alain Zarembowitch / MSS
-- Version: Rev 0
-- Last modified: 10/24/20
-- Inheritance: 	N/A
--
-- description:  XAUI to XGMII translation
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
--use ieee.numeric_std.all;

entity XAUI2XGMII is
--	 Generic (
--	);
    Port ( 
		SYNC_RESET: in std_logic;
		CLK: in std_logic;

		XAUI_RXD: in std_logic_vector(31 downto 0);
		XAUI_RXCHARISK: in std_logic_vector(3 downto 0);
			-- K character detected 
		XAUI_RXDISPERR: in std_logic_vector(3 downto 0);
			-- data with disparity error 
		XAUI_RXNOTINTABLE: in std_logic_vector(3 downto 0);
			-- out-of-table character 

		XGMII_RXD: out std_logic_vector(31 downto 0);
		XGMII_RXC: out std_logic_vector(3 downto 0)
			-- Single data rate receive interface 
			-- LSb of LSB is received first
			-- Start character 0xFB is in byte 0
			-- XGMII_RXC control bit is '0' for valid data byte
		);
end entity;

architecture Behavioral of XAUI2XGMII is
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--  XAUI 8b/10b to XGMII Code Mapping
MAP_001: process(CLK)
begin
	if rising_edge(CLK) then
		XGMII_RXC <= XAUI_RXCHARISK or XAUI_RXDISPERR or XAUI_RXNOTINTABLE;
			-- XGMII control: 0 for data, 1 otherwise
	
		for I in 0 to 3 loop
			if(XAUI_RXCHARISK(I) = '1') then
				if (XAUI_RXD(8*(I+1)-1 downto 8*I) = x"FB") or 
					(XAUI_RXD(8*(I+1)-1 downto 8*I) = x"FD") or
					(XAUI_RXD(8*(I+1)-1 downto 8*I) = x"FE") or
					(XAUI_RXD(8*(I+1)-1 downto 8*I) = x"9C") then
					-- Start, terminate, error, ordered set
					XGMII_RXD(8*(I+1)-1 downto 8*I) <= XAUI_RXD(8*(I+1)-1 downto 8*I);
				elsif (XAUI_RXD(8*(I+1)-1 downto 8*I) = x"BC") or 
					(XAUI_RXD(8*(I+1)-1 downto 8*I) = x"7C") or
					(XAUI_RXD(8*(I+1)-1 downto 8*I) = x"1C") then
					-- K28.5, K28.3, K28.0
					XGMII_RXD(8*(I+1)-1 downto 8*I) <= x"07";	-- idle
				else
					XGMII_RXD(8*(I+1)-1 downto 8*I) <= x"07";	-- idle ? or error ? (TBC)
				end if;
			elsif(XAUI_RXDISPERR(I) = '1') or (XAUI_RXNOTINTABLE(I) = '1') then
				XGMII_RXD(8*(I+1)-1 downto 8*I) <= x"07";	-- idle ? or error ? (TBC)
			else
				-- valid data 
				XGMII_RXD(8*(I+1)-1 downto 8*I) <= XAUI_RXD(8*(I+1)-1 downto 8*I);
			end if;
		end loop;
	end if;
end process;


end Behavioral;
