----------------------------------------------
-- MSS copyright 2001-2017
-- Filename: LFSR11P.VHD
-- Authors: 
--		Angela Baran / MSS
--		Alain Zarembowitch / MSS
-- Inheritance: BER2.vhd 8-5-09, LFSR11C.VHD 9/28/05
-- Edit date: 4/26/17
-- Revision: 5
-- Description: 
--		pseudo random bit generation. based on 11-bit linear feedback
-- 	shift register. A synchronous reset is provided to reset
--		the PN sequence at frame boundaries.
-- 	8-bit parallel output for higher data rate.   
--
-- Device Utilization Summary (estimated values)
-- Number of Slice Registers 22
-- Number of Slice LUTs 369 (depends on how the ROM is inferred)
-- Number of RAM blocks 0 (depends on how the ROM is inferred)
-- Minimum period: 4.513ns (Maximum Frequency: 221.603MHz) on Xilinx Artix7 -1 speed grade 
-- 
-- Rev 2. 10-16-09 AZ
-- Prevent output at the time of reset. Cleaner simulations.
--
-- Rev 3 7-19-11 AZ
-- upon reset, move read pointer one notch earlier so as to start with 11 zeros as expected.
--
-- Rev 4 8/13/11 AZ
-- Added signals initialization for simulation
--
-- Rev 5 4/26/17 AZ
-- Made it portable using inferred ROM.
-- Switched to numeric_std library
---------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity LFSR11P is
  port (
	CLK: in  std_logic;   
		-- clock synchronous
	SYNC_RESET: in std_logic;
		-- synchronous reset, active high

	DATA_OUT: out std_logic_vector(7 downto 0);
		-- Output test sequence. Read at rising edge of CLK when SAMPLE_CLK_OUT = '1'
		-- MSb is first.
	SAMPLE_CLK_OUT: out std_logic;
		-- one CLK wide pulse indicating that the DATA_OUT is ready. 
		-- Latency w.r.t. SAMPLE_CLK_OUT_REQ is two CLKs. 
	SOF_OUT: out std_logic;
		-- one CLK wide pulse indicating start of frame
		-- (i.e. '1' when LFSR register matches the SEED). 
		-- aligned with SAMPLE_CLK_OUT.
	SAMPLE_CLK_OUT_REQ: in std_logic
		-- flow control
    );
end entity;

architecture behavior of LFSR11P is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT LFSR11PROM
	PORT(
		CLKA : IN std_logic;
		CSA : IN std_logic;
		OEA : IN std_logic;
		ADDRA : IN std_logic_vector(10 downto 0);
		CLKB : IN std_logic;
		CSB : IN std_logic;
		OEB : IN std_logic;
		ADDRB : IN std_logic_vector(10 downto 0);          
		DOA : OUT std_logic_vector(7 downto 0);
		DOB : OUT std_logic_vector(7 downto 0)
		);
	END COMPONENT;

-----------------------------------------------------------------
-- SIGNALS
-----------------------------------------------------------------
--// SEQUENCE PRBS11SEQ -------------------------------
signal ADDR: unsigned(10 downto 0) := (others => '0');
signal ADDR_INC: unsigned(10 downto 0) := (others => '0');
signal SAMPLE_CLK_OUT_REQ_D: std_logic  := '0';
signal SAMPLE_CLK_OUT_REQ_D2: std_logic := '0';
-----------------------------------------------------------------
-- IMPLEMENTATION
-----------------------------------------------------------------
begin

-- Stores 8 contiguous PRBS-11 sequence in DATA_OUT(7:0). Period is 8*2047 bits.	
-- SOF is placed in DATA_OUT(8)
LFSR11PROM_001: LFSR11PROM PORT MAP(
	CLKA => CLK,
	CSA => '1',
	OEA => '1',
	ADDRA => std_logic_vector(ADDR),  -- 11-bit Address Input
	DOA => DATA_OUT,      -- 8-bit Data Output
	CLKB => CLK,
	CSB => '0',
	OEB => '0',
	ADDRB => (others => '0'),
	DOB => open
);
	
 -- PRBS11 sequence read pointer management
 -- modulo 8 * 2047 bits.
ADDR_INC <= ADDR + 1;
ADDR_GEN_001: 	process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then  
			SAMPLE_CLK_OUT_REQ_D <= '0'; 
			SAMPLE_CLK_OUT_REQ_D2 <= '0';
		else
			SAMPLE_CLK_OUT_REQ_D <= SAMPLE_CLK_OUT_REQ;  -- 1 CLK delay to get ADDR
			SAMPLE_CLK_OUT_REQ_D2 <= SAMPLE_CLK_OUT_REQ_D;  -- 1 CLK delay to extract data from RAMB
		end if;
				
		if(SYNC_RESET = '1') then
			ADDR <= to_unsigned(2046, ADDR'length);	-- preposition one notch before first byte
		elsif(SAMPLE_CLK_OUT_REQ = '1') then
			if(ADDR_INC = 2047) then
				ADDR <= (others => '0');  -- modulo 8 * 2047 bits.
			else
				ADDR <= ADDR_INC;
			end if;
		end if;
	end if;
end process;   

SOF_GEN_001: 	process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then  
			SOF_OUT <= '0';
		elsif(ADDR(7 downto 0) = 0) and (SAMPLE_CLK_OUT_REQ_D = '1') then
			SOF_OUT <= '1';
		else
			SOF_OUT <= '0';
		end if;
	end if;
end process;
			

SAMPLE_CLK_OUT <= SAMPLE_CLK_OUT_REQ_D2;

  
end behavior;

