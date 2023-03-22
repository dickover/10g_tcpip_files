-------------------------------------------------------------
-- MSS copyright 2021
-- Filename:  TCP_RXOPTIONS_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0
--	Date last modified: 1/19/21
-- Inheritance: 	n/a
--
-- description:  
-- Decode TCPv4 option upon receiving SYN message from client. 
-- 10Gbits/s.
-- Supports IPv4 and IPv6. 
-- Portable VHDL
--
-- Device utilization (ADDR_WIDTH = 10, UDP_CKSUM_ENABLED='1',IPv6_ENABLED='1')
-- FF: 39
-- LUT: 
-- DSP48: 0
-- 18Kb BRAM: 
-- BUFG: 
-- Minimum period:  Artix7-100T -1 speed grade
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity TCP_RXOPTIONS_10G is
    Port ( 
		CLK: in std_logic;
			 -- CLK must be a global clock 156.25 MHz or faster to match the 10Gbps MAC speed.
		SYNC_RESET: in std_logic;
			-- CLK-synchronous reset

		-- inputs
		RX_TCP_DATA_OFFSET: in std_logic_vector(3 downto 0);
			-- 5 = no option
			-- 6 = 4 Bytes of options
			-- 7 = 8 Bytes of options, ... etc
		IP_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		IP_PAYLOAD_WORD_VALID: in std_logic;
		IP_PAYLOAD_WORD_COUNT: in std_logic_vector(10 downto 0);    

		--// Decoded options
		TCP_OPTION_MSS: out std_logic_vector(15 downto 0);
		TCP_OPTION_MSS_VALID: out std_logic;
		TCP_OPTION_WINDOW_SCALE: out std_logic_vector(3 downto 0);
		TCP_OPTION_WINDOW_SCALE_VALID: out std_logic;
		TCP_OPTION_SACK_PERMITTED: out std_logic;
		TCP_OPTION_SACK_PERMITTED_VALID: out std_logic;
			-- read the options at EVENT1 = one clock after IP_PAYLOAD_EOF
			-- _VALID is '0' if option was not received

		--// TEST POINTS 
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_RXOPTIONS_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal IP_PAYLOAD_WORD_COUNTx2: unsigned(3 downto 0) := x"0";
signal EVEN_OPTION: std_logic := '0';
signal ODD_OPTION: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin
IP_PAYLOAD_WORD_COUNTx2 <= unsigned(IP_PAYLOAD_WORD_COUNT(2 downto 0) & "0");

-- option in even-count TCP data offset (starting at 6)
EVEN_OPTION <= IP_PAYLOAD_WORD_VALID when (unsigned(IP_PAYLOAD_WORD_COUNT(10 downto 3)) = 0) and (unsigned(IP_PAYLOAD_WORD_COUNT(2 downto 0)) > 2) and (IP_PAYLOAD_WORD_COUNTx2 <= unsigned(RX_TCP_DATA_OFFSET)) else '0';
ODD_OPTION <= IP_PAYLOAD_WORD_VALID when (unsigned(IP_PAYLOAD_WORD_COUNT(10 downto 3)) = 0) and (unsigned(IP_PAYLOAD_WORD_COUNT(2 downto 0)) > 3) and (IP_PAYLOAD_WORD_COUNTx2 <= unsigned(RX_TCP_DATA_OFFSET)+1) else '0';

-- decode even-count TCP options
-- MSS option
TCP_OPTION_MSS_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TCP_OPTION_MSS <= (others => '0');
			TCP_OPTION_MSS_VALID <= '0';
		elsif(EVEN_OPTION = '1') and (IP_PAYLOAD_DATA(31 downto 24) = x"02") then
			-- MSS option
			TCP_OPTION_MSS <= IP_PAYLOAD_DATA(15 downto 0);
			TCP_OPTION_MSS_VALID <= '1';
		elsif(ODD_OPTION = '1') and (IP_PAYLOAD_DATA(63 downto 56) = x"02") then
			-- MSS option
			TCP_OPTION_MSS <= IP_PAYLOAD_DATA(47 downto 32);
			TCP_OPTION_MSS_VALID <= '1';
		end if;
	end if;
end process;

TCP_OPTION_WINDOW_SCALE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TCP_OPTION_WINDOW_SCALE <= (others => '0');
			TCP_OPTION_WINDOW_SCALE_VALID <= '0';
		elsif(EVEN_OPTION = '1')and (IP_PAYLOAD_DATA(31 downto 16) = x"0103") then
			-- Window Scale option
			TCP_OPTION_WINDOW_SCALE <= IP_PAYLOAD_DATA(3 downto 0);
			TCP_OPTION_WINDOW_SCALE_VALID <= '1';
		elsif(ODD_OPTION = '1') and (IP_PAYLOAD_DATA(63 downto 48) = x"0103") then
			-- Window Scale option
			TCP_OPTION_WINDOW_SCALE <= IP_PAYLOAD_DATA(35 downto 32);
			TCP_OPTION_WINDOW_SCALE_VALID <= '1';
		end if;
	end if;
end process;

TCP_OPTION_SACK_PERMITTED_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TCP_OPTION_SACK_PERMITTED <= '0';
			TCP_OPTION_SACK_PERMITTED_VALID <= '0';
		elsif(EVEN_OPTION = '1') and (IP_PAYLOAD_DATA(31 downto 8) = x"010104") then
			-- SACK permitted option
			TCP_OPTION_SACK_PERMITTED <= '1';
			TCP_OPTION_SACK_PERMITTED_VALID <= '1';
		elsif(ODD_OPTION = '1') and (IP_PAYLOAD_DATA(63 downto 40) = x"010104") then
			-- SACK permitted option
			TCP_OPTION_SACK_PERMITTED <= '1';
			TCP_OPTION_SACK_PERMITTED_VALID <= '1';
		end if;
	end if;
end process;

--//-- TEST POINTS ---------------------------------
TP(10 downto 1) <= (others => '0');

end Behavioral;
