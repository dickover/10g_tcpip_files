-------------------------------------------------------------
-- Filename:  CRC32.VHD
-- Authors: 
--		Alain Zarembowitch / MSS
-- Version: Rev 0
-- Last modified: 2/26/17
-- Inheritance: 	n/a
--
-- description:  high-speed generation of 32-bit CRC32 (optimized for 10G Ethernet 64-bit words)
-- Data bit order: MSb of MSB is first sent/received
-- Algorithm based on seminal paper "High Performance Table-Based Algorithm for Pipelined CRC Calculation",
-- by Yan Sun and Min Sik Kim
-- Verified by comparing with the crc calculator at http://www.sunshine2k.de/coding/javascript/crc/crc_js.html
--
-- Utilization:
-- FF: 188
-- LUT: 728
-- 18Kb block RAMs: 0
-- DSP: 0
-- GCLK: 1
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity CRC32 is
    Port ( 
		CLK : IN std_logic;
		DATA_IN: in std_logic_vector(63 downto 0);
			-- Natural order (as if input to a standard LFSR), i.e. not inverted, not reversed.
			-- order: MSb of MSB is first serialized bit
			-- Special case: when last word is less than 8 bytes, bytes are left-aligned (MSB first) and lower byte(s) are ignored.
		SAMPLE_CLK_IN: in std_logic;
			-- read DATA_IN at the rising_edge of CLK when SAMPLE_CLK_IN = '1'
		SOF_IN: in std_logic;
			-- 1-CLK wide pulse marks the first word in a message. Initializes the CRC to all zero
			-- aligned with SAMPLE_CLK_IN
		DATA_VALID_IN : IN  std_logic_vector(7 downto 0);
			-- Valid bytes in DATA_IN. 
			-- Valid inputs: 0x00,80 (one MSB byte),C0,E0,F0,F8,FC,FE,FF (8 bytes)
		CRC_INITIALIZATION: in std_logic_vector(31 downto 0);
			-- typically 0xFFFFFFFF. Read at SOF_IN = '1'
		CRC_OUT: out std_logic_vector(31 downto 0);
			-- Natural order (as in the flip-flop values of a standard LFSR), i.e. not inverted, not reversed.
		SAMPLE_CLK_OUT: out std_logic
			-- latency 1 CLKs after SAMPLE_CLK_IN
		);
end entity;

architecture Behavioral of CRC32 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
    COMPONENT CRC32_LUT1
    PORT(
         CLK : IN  std_logic;
         DATA_IN : IN  std_logic_vector(31 downto 0);
         SAMPLE_CLK_IN : IN  std_logic;
         CRC_OUT : OUT  std_logic_vector(31 downto 0);
         SAMPLE_CLK_OUT : OUT  std_logic
        );
    END COMPONENT;

    COMPONENT CRC32_LUT2
    PORT(
         CLK : IN  std_logic;
         DATA_IN : IN  std_logic_vector(31 downto 0);
         SAMPLE_CLK_IN : IN  std_logic;
         CRC_OUT : OUT  std_logic_vector(31 downto 0);
         SAMPLE_CLK_OUT : OUT  std_logic
        );
    END COMPONENT;
	 
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal DATA1: std_logic_vector(63 downto 0) := (others => '0');
signal DATA1_D: std_logic_vector(63 downto 0) := (others => '0');
signal DATA2: std_logic_vector(63 downto 0) := (others => '0');
signal DATA12: std_logic_vector(63 downto 0) := (others => '0');
signal SAMPLE1_CLK: std_logic := '0';
signal SAMPLE1_CLK_D: std_logic := '0';
signal SAMPLE1_CLK_D2: std_logic := '0';
signal SOF1: std_logic := '0';
signal SOF1_D: std_logic := '0';
signal CRC1: std_logic_vector(31 downto 0) := (others => '0');
signal CRC2: std_logic_vector(31 downto 0) := (others => '0');
signal CRC12: std_logic_vector(31 downto 0) := (others => '0');
signal CRC12_D: std_logic_vector(31 downto 0) := (others => '0');
signal CRC12_FROZEN: std_logic_vector(31 downto 0) := (others => '0');



signal CRC3: std_logic_vector(31 downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- Special case: when last word is less than 8 bytes, input bytes are left-aligned (MSB first) and lower byte(s) are ignored.
-- partial last word case: reorder last word so that bytes are right aligned
REORDER_001: process(DATA_IN, SAMPLE_CLK_IN, DATA_VALID_IN)
begin
	if(SAMPLE_CLK_IN = '1') then
        if(DATA_VALID_IN(7) = '0') then
            DATA1 <= (others => '0');
        elsif(DATA_VALID_IN(6) = '0') then
            DATA1 <= x"00000000000000" & DATA_IN(63 downto 56);	-- last word contains 1 byte
        elsif(DATA_VALID_IN(5) = '0') then
			DATA1 <= x"000000000000" & DATA_IN(63 downto 48);	-- last word
        elsif(DATA_VALID_IN(4) = '0') then
			DATA1 <= x"0000000000" & DATA_IN(63 downto 40);	-- last word
        elsif(DATA_VALID_IN(3) = '0') then
			DATA1 <= x"00000000" & DATA_IN(63 downto 32);	-- last word	
        elsif(DATA_VALID_IN(2) = '0') then
			DATA1 <= x"000000" & DATA_IN(63 downto 24);	-- last word
        elsif(DATA_VALID_IN(1) = '0') then
			DATA1 <= x"0000" & DATA_IN(63 downto 16);	-- last word
        elsif(DATA_VALID_IN(0) = '0') then
			DATA1 <= x"00" & DATA_IN(63 downto 8);	-- last word
		else
    		DATA1 <= DATA_IN(63 downto 0);	-- full 8-byte input word
        end if;	   
	else
		DATA1 <= DATA1_D;
	end if;
end process;
SAMPLE1_CLK <= SAMPLE_CLK_IN;	
SOF1 <= SOF_IN;

FREEZE_DATA1_001: process(CLK)
begin
	if rising_edge(CLK) then
		SOF1_D <= SOF1;
		if(SAMPLE1_CLK = '1') then
			DATA1_D <= DATA1;
		end if;
	end if;
end process;

-- CRC32 look-up table
-- Latency: 1 CLK (from table address DATA_IN to table output CRC_OUT)
-- lower 32-bits
LUT1_001: CRC32_LUT1 PORT MAP (
		 CLK => CLK,
		 DATA_IN => DATA12(31 downto 0),
		 SAMPLE_CLK_IN => SAMPLE1_CLK,
		 CRC_OUT => CRC1,
		 SAMPLE_CLK_OUT => SAMPLE1_CLK_D	
	  );
-- upper 32-bits. LUT2 shifts the input by x^32
-- Latency: 1 CLK (from table address DATA_IN to table output CRC_OUT)
LUT2_001: CRC32_LUT2 PORT MAP (
		 CLK => CLK,
		 DATA_IN => DATA12(63 downto 32),
		 SAMPLE_CLK_IN => SAMPLE1_CLK,
		 CRC_OUT => CRC2,
		 SAMPLE_CLK_OUT => open
	  );
CRC12 <= CRC1 xor CRC2;	-- this is the CRC[DATA_IN(63:0)] 

-- freeze CRC12 (otherwise algorithm runs amok) immediately at the LUT output (without waiting for next rising edge)
FREEZE_CRC12_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SAMPLE1_CLK_D = '1') then
			CRC12_D <= CRC12;
		end if;
	end if;
end process;
CRC12_FROZEN <= 	CRC_INITIALIZATION when (SOF1 = '1') else  -- initialize CRC to zero at the first input word
						CRC12 when (SAMPLE1_CLK_D = '1') else 
						CRC12_D;

-- last word special case. Add left-over bytes from last word CRC
DATA2_GEN_001: process(CRC12_FROZEN, DATA_VALID_IN)
begin
    if(DATA_VALID_IN(7) = '0') then
        DATA2 <= (others => '0');
    elsif(DATA_VALID_IN(6) = '0') then
        DATA2 <= x"00000000000000" & CRC12_FROZEN(31 downto 24); -- last input word contains 1 byte
    elsif(DATA_VALID_IN(5) = '0') then
        DATA2 <= x"000000000000" & CRC12_FROZEN(31 downto 16); -- last input word contains 2 bytes
    elsif(DATA_VALID_IN(4) = '0') then
        DATA2 <= x"0000000000" & CRC12_FROZEN(31 downto 8); -- last input word contains 3 bytes
    elsif(DATA_VALID_IN(3) = '0') then
        DATA2 <= x"00000000" & CRC12_FROZEN(31 downto 0); 
    elsif(DATA_VALID_IN(2) = '0') then
        DATA2 <= x"000000" & CRC12_FROZEN(31 downto 0) & x"00"; 
    elsif(DATA_VALID_IN(1) = '0') then
        DATA2 <= x"0000" & CRC12_FROZEN(31 downto 0) & x"0000";  
    elsif(DATA_VALID_IN(0) = '0') then
        DATA2 <= x"00" & CRC12_FROZEN(31 downto 0) & x"000000"; 
    else
        DATA2 <= CRC12_FROZEN(31 downto 0) & x"00000000";   
    end if;       
end process;

DATA12 <= DATA1 xor DATA2;


CRC3_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SAMPLE_CLK_IN = '1') then
            if(DATA_VALID_IN(7) = '0') then
				CRC3 <= (others => '0');
            elsif(DATA_VALID_IN(6) = '0') then
				CRC3 <= CRC12_FROZEN(23 downto 0) & x"00"; -- last input word contains 1 byte
            elsif(DATA_VALID_IN(5) = '0') then
				CRC3 <= CRC12_FROZEN(15 downto 0) & x"0000"; -- last input word contains 2 bytes
            elsif(DATA_VALID_IN(4) = '0') then
				CRC3 <= CRC12_FROZEN(7 downto 0) & x"000000"; -- last input word contains 3 bytes
            else
				CRC3 <= (others => '0');
            end if;       
		end if;
	end if;
end process;

-- outputs
CRC_OUT <= CRC12_FROZEN xor CRC3;
SAMPLE_CLK_OUT <= SAMPLE1_CLK_D;

end Behavioral;
