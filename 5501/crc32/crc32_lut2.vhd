-------------------------------------------------------------
-- Filename:  CRC32_LUT2.VHD
-- Authors: 
--		Alain Zarembowitch / MSS
-- Version: Rev 0
-- Last modified: 2/25/17
-- Inheritance: 	n/a
--
-- description:  32-bit CRC lookup table for x^32.DATA_IN (in other words, the upper 32-bits of a 64-bit word)
-- Actually comprised of 4 small (256 entries) tables, one for each input byte
-- Data bit order: MSb of MSB is first sent/received
-- Algorithm based on seminal paper "High Performance Table-Based Algorithm for Pipelined CRC Calculation",
-- by Yan Sun and Min Sik Kim
-- CRC_OUT only depends on DATA_IN. The algorithm is thus memoryless.
-- Verified by comparing with the crc calculator at http://www.sunshine2k.de/coding/javascript/crc/crc_js.html
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity CRC32_LUT2 is
    Port ( 
		CLK : IN std_logic;
		DATA_IN: in std_logic_vector(31 downto 0);
			-- Natural order (as if input to a standard LFSR), i.e. not inverted, not reversed.
			-- order: MSb of MSB is first serialized bit
		SAMPLE_CLK_IN: in std_logic;
			-- read DATA_IN at the rising_edge of CLK when SAMPLE_CLK_IN = '1'
		CRC_OUT: out std_logic_vector(31 downto 0);
			-- Natural order (as if the flip-flop values of a standard LFSR), i.e. not inverted, not reversed.
		SAMPLE_CLK_OUT: out std_logic
			-- latency 1 CLK after SAMPLE_CLK_IN
		);
end entity;

architecture Behavioral of CRC32_LUT2 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT CRC32_LUT2ab
	GENERIC (
		DATA_WIDTH: integer;	
		ADDR_WIDTH: integer
	);
	PORT(
		ADDRA : IN std_logic_vector(8 downto 0);
		ADDRB : IN std_logic_vector(8 downto 0);          
		DOA : OUT std_logic_vector(31 downto 0);
		DOB : OUT std_logic_vector(31 downto 0)
		);
	END COMPONENT;

	COMPONENT CRC32_LUT2cd
	GENERIC (
		DATA_WIDTH: integer;	
		ADDR_WIDTH: integer
	);
	PORT(
		ADDRA : IN std_logic_vector(8 downto 0);
		ADDRB : IN std_logic_vector(8 downto 0);          
		DOA : OUT std_logic_vector(31 downto 0);
		DOB : OUT std_logic_vector(31 downto 0)
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal ADDR0: std_logic_vector(8 downto 0) := (others => '0');
signal ADDR1: std_logic_vector(8 downto 0) := (others => '0');
signal ADDR2: std_logic_vector(8 downto 0) := (others => '0');
signal ADDR3: std_logic_vector(8 downto 0) := (others => '0');
signal CRC0: std_logic_vector(31 downto 0) := (others => '0');
signal CRC1: std_logic_vector(31 downto 0) := (others => '0');
signal CRC2: std_logic_vector(31 downto 0) := (others => '0');
signal CRC3: std_logic_vector(31 downto 0) := (others => '0');
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- input bytes 0(A-side) and 1 (B-side)
-- Latency: 0 CLK after
ADDR0 <= '0' & DATA_IN(7 downto 0);	-- order: LSB (last received)
ADDR1 <= '1' & DATA_IN(15 downto 8);
CRC32_LUT2ab_001: CRC32_LUT2ab 
GENERIC MAP(
	DATA_WIDTH => 32,
	ADDR_WIDTH => 9)
PORT MAP(
	ADDRA => ADDR0,
	DOA => CRC0,
	ADDRB => ADDR1,
	DOB => CRC1
);

ADDR2 <= '0' & DATA_IN(23 downto 16);
ADDR3 <= '1' & DATA_IN(31 downto 24);	-- order: MSb of MSB received first
CRC32_LUT2cd_001: CRC32_LUT2cd 
GENERIC MAP(
	DATA_WIDTH => 32,
	ADDR_WIDTH => 9)
PORT MAP(
	ADDRA => ADDR2,
	DOA => CRC2,
	ADDRB => ADDR3,
	DOB => CRC3
);


RECLOCK_001: process(CLK)
begin
	if rising_edge(CLK) then
		CRC_OUT <= CRC0 xor CRC1 xor CRC2 xor CRC3;
		SAMPLE_CLK_OUT <= SAMPLE_CLK_IN;
	end if;
end process;

end Behavioral;
