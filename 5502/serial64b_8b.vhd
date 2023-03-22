-------------------------------------------------------------
-- MSS copyright 2018-2019
-- Filename:  SERIAL_64b_8b.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 1b
-- Date last modified: 4/19/19
-- Inheritance: 	n/a
--
-- description: Specialized component to get 8-byte data words (typically from the COM5502 TCP receive interface)
-- and queues the bytes into a simpler output buffer.
-- Flow control is used from sink to source.
-- The main reason for this component is the complexity of the 64-bit TCP rx interface.
-- Simplicity comes at the price of throughput as the byte-wide interface is 8 times slower than the 64-bit interface.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SERIAL_64b_8b is
	generic (
		LOOK_AHEAD: std_logic := '1'
			-- '1' is DATA_OUT is ready before output request CTS_IN (CTS_IN then means 'move to the next byte')
			-- '0' if DATA_OUT follows CTS_IN
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;		-- synchronous clock
			-- Must be a global clocks. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;

		--// INPUT PACKETS
		DATA_IN: in std_logic_vector(63 downto 0);
			-- packed MSB first
		DATA_VALID_IN: in std_logic_vector(7 downto 0);
			-- MSb first
			-- FF indicates that DATA_IN contains a complete 8-byte word (one CLK pulse only)
			-- 80,C0,E0,F0,F8,FC,FE indicate a partially fully DATA_IN (can last more than one clock until the word becomes full)
		RTS_IN: in std_logic;	-- Ready To Send
		CTS_OUT: out std_logic;	-- Clear To Send
		CTS_OUT_ACK: in std_logic;	-- CTS_OUT accepted. New (partial) word at the next clock


		--// OUTPUT STREAM
		DATA_OUT: out std_logic_vector(7 downto 0);
		DATA_VALID_OUT: out std_logic;
		CTS_IN: in std_logic; 	-- flow control, clear-to-send (1 clk pulse requesting a byte)
		RTS_OUT: out std_logic;	-- indicates at least one byte awaiting to be read. User must raise CTS_IN for 1 clk to get it.
	
		--// TEST POINTS, MONITORING
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of SERIAL_64b_8b is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates a one CLK early version of the net with the same name
-- Suffix _X indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

signal SERIALIZING_IN_PROGRESS: std_logic := '0';
signal DATA_VALID_IN_EXTENDED: std_logic := '0';
signal DATA_VALID_IN_D: std_logic_vector(7 downto 0) := (others => '0');
signal NEED_NEXT_WORD: std_logic := '0';
signal CTS_OUT_local: std_logic := '0';
signal CTS_OUT_D: std_logic := '0';
signal NEXT_BYTE: std_logic_vector(7 downto 0) := (others => '0');
signal RTS_OUT_local: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- flow control
SERIALIZING_IN_PROGRESS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			SERIALIZING_IN_PROGRESS <= '0';
		elsif(CTS_OUT_ACK = '1') then
			-- new incoming word (partial or full)
			SERIALIZING_IN_PROGRESS <= '1';
		elsif(NEXT_BYTE(0) = '1') and (CTS_IN = '1') then
			SERIALIZING_IN_PROGRESS <= '0';
		end if;
	end if;
end process;

-- extend the DATA_VALID_IN=xFF (a single clk pulse) until the next byte (first in next word) is received
EXTEND_DATA_VALID_IN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			DATA_VALID_IN_EXTENDED <= '0';
		elsif(NEXT_BYTE(0) = '1') and (CTS_IN = '1') then
			-- reading the last byte in a word. clear
			DATA_VALID_IN_EXTENDED <= '0';
		elsif(DATA_VALID_IN = x"FF") then
			DATA_VALID_IN_EXTENDED <= '1';
		end if;
	end if;
end process;

-- need next word
NEED_NEXT_WORD <= '1' when (NEXT_BYTE = x"80")  else '0';

-- send request for next word
CTS_OUT_local <= RTS_IN and (not SERIALIZING_IN_PROGRESS) and  NEED_NEXT_WORD and not(CTS_OUT_D);
CTS_OUT <= CTS_OUT_local;

-- flow control
CTS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		CTS_OUT_D <= CTS_OUT_local;
	end if;
end process;

-- byte pointer. Indicates the next byte to read. 
NEXT_BYTE_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			-- Point to first byte (MSB)
			NEXT_BYTE <= "10000000";
		elsif(CTS_IN = '1') and (RTS_OUT_local = '1') then
			-- sink requests the next byte and it is available
			-- circular shift of a single '1' from left to right
			NEXT_BYTE <= NEXT_BYTE(0) & NEXT_BYTE(7 downto 1);
		end if;
	end if;
end process;

LH0: if (LOOK_AHEAD = '0') generate
	DATA_OUT_GEN: process(CLK) 
	begin
		if rising_edge(CLK) then
			DATA_VALID_OUT <= RTS_OUT_local and CTS_IN;
		
			if(SYNC_RESET = '1') then
				DATA_OUT <= (others => '0');
			elsif(CTS_IN = '1') then
				if (NEXT_BYTE(7) = '1') then	-- MSB first
					DATA_OUT <= DATA_IN(63 downto 56);
				elsif (NEXT_BYTE(6) = '1') then	
					DATA_OUT <= DATA_IN(55 downto 48);
				elsif (NEXT_BYTE(5) = '1') then	
					DATA_OUT <= DATA_IN(47 downto 40);
				elsif (NEXT_BYTE(4) = '1') then	
					DATA_OUT <= DATA_IN(39 downto 32);
				elsif (NEXT_BYTE(3) = '1') then	
					DATA_OUT <= DATA_IN(31 downto 24);
				elsif (NEXT_BYTE(2) = '1') then	
					DATA_OUT <= DATA_IN(23 downto 16);
				elsif (NEXT_BYTE(1) = '1') then	
					DATA_OUT <= DATA_IN(15 downto 8);
				else
				--elsif (NEXT_BYTE(0) = '1') then	
					DATA_OUT <= DATA_IN(7 downto 0);
				end if;
			end if;
		end if;
	end process;
	
	RTS_OUT_local <= 	'1' when ((NEXT_BYTE and DATA_VALID_IN) /= x"00")  or (DATA_VALID_IN_EXTENDED = '1') else '0';
end generate;

LH1: if (LOOK_AHEAD = '1') generate
	DATA_OUT_GEN: process(NEXT_BYTE, DATA_IN) 
	begin
		if (NEXT_BYTE(7) = '1') then	-- MSB first
			DATA_OUT <= DATA_IN(63 downto 56);
		elsif (NEXT_BYTE(6) = '1') then	
			DATA_OUT <= DATA_IN(55 downto 48);
		elsif (NEXT_BYTE(5) = '1') then	
			DATA_OUT <= DATA_IN(47 downto 40);
		elsif (NEXT_BYTE(4) = '1') then	
			DATA_OUT <= DATA_IN(39 downto 32);
		elsif (NEXT_BYTE(3) = '1') then	
			DATA_OUT <= DATA_IN(31 downto 24);
		elsif (NEXT_BYTE(2) = '1') then	
			DATA_OUT <= DATA_IN(23 downto 16);
		elsif (NEXT_BYTE(1) = '1') then	
			DATA_OUT <= DATA_IN(15 downto 8);
		else
		--elsif (NEXT_BYTE(0) = '1') then	
			DATA_OUT <= DATA_IN(7 downto 0);
		end if;
	end process;

	DATA_VALID_OUT <= RTS_OUT_local and CTS_IN;
	
	RTS_OUT_local <= 	'1' when ((NEXT_BYTE and DATA_VALID_IN) /= x"00")  or (DATA_VALID_IN_EXTENDED = '1') else '0';
	
end generate;

RTS_OUT <= RTS_OUT_local;
end Behavioral;
