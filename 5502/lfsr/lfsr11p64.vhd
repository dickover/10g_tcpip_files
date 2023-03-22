----------------------------------------------
-- MSS copyright 2021
-- Filename: LFSR11P64.VHD
-- Authors: 
--		Angela Baran / MSS
--		Alain Zarembowitch / MSS
-- Inheritance: n/a
-- Edit date: 1/11/21
-- Revision: 0
-- Description: 
--		pseudo random bit generation. based on 11-bit linear feedback
-- 	shift register. A synchronous reset is provided to reset
--		the PN sequence at frame boundaries.
-- 	64-bit parallel output for higher data rate.   
--
-- Device Utilization Summary (estimated values)
-- Number of Slice Registers 79
-- Number of Slice LUTs 719 (depends on how the ROM is inferred)
-- Number of 36kb RAM blocks 2 (depends on how the ROM is inferred)
-- Minimum period: 4.220ns (Maximum Frequency: 236.967MHz) on Xilinx Artix7 -1 speed grade 
---------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity LFSR11P64 is
Generic (
	MSB_FIRST: std_logic := '0'
		-- '1' for MSb first, '0' for LSb first
);
port (
	CLK: in  std_logic;   
		-- clock synchronous
	SYNC_RESET: in std_logic;
		-- synchronous reset, active high. MANDATORY

	DATA_OUT: out std_logic_vector(63 downto 0);
		-- Output test sequence. Read at rising edge of CLK when SAMPLE_CLK_OUT = '1'
		-- MSb or LSb first depending on MSB_FIRST.
	SAMPLE_CLK_OUT: out std_logic;
		-- one CLK wide pulse indicating that the DATA_OUT is ready. 
		-- Latency w.r.t. SAMPLE_CLK_OUT_REQ is two CLKs. 
	SOF_OUT: out std_logic;
		-- one CLK wide pulse indicating start of frame
		-- (i.e. '1' when LFSR register matches the SEED). 
		-- aligned with SAMPLE_CLK_OUT.
		-- period = 64*2047 bits = 2047 output 64-bit samples
	SAMPLE_CLK_OUT_REQ: in std_logic
		-- flow control
    );
end entity;

architecture behavior of LFSR11P64 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT LFSR11P64ROM
	GENERIC (
		DATA_WIDTH: integer;	
		ADDR_WIDTH: integer
	);
	PORT(
		CLK : IN std_logic;
		ADDRA : IN std_logic_vector(4 downto 0);
		DOA : OUT std_logic_vector(63 downto 0);
		ADDRB : IN std_logic_vector(4 downto 0);          
		DOB : OUT std_logic_vector(63 downto 0)
		);
	END COMPONENT;
-----------------------------------------------------------------
-- SIGNALS
-----------------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates a one CLK early version of the net with the same name
-- Suffix _X indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name
signal MODULO_CNTR: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR_D: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR_INC: unsigned(10 downto 0) := (others => '0');
signal SEQL: std_logic_vector(63 downto 0) := (others => '0');
signal SEQH: std_logic_vector(63 downto 0) := (others => '0');
signal SAMPLE_CLK_OUT_E: std_logic := '0';
signal SOF_OUT_E: std_logic := '0';
signal DATA_OUT_local: std_logic_vector(63 downto 0) := (others => '0');
-----------------------------------------------------------------
-- IMPLEMENTATION
-----------------------------------------------------------------
begin

-- latency 1 CLK
-- outputs aligned with SAMPLE_CLK_OUT_E
LFSR11P64ROM_001: LFSR11P64ROM 
GENERIC MAP(
	DATA_WIDTH => 64,
	ADDR_WIDTH	=> 5
)
PORT MAP(
	CLK => CLK,
	ADDRA => std_logic_vector(MODULO_CNTR(4 downto 0)),  
	DOA => SEQL,      
	ADDRB => std_logic_vector(MODULO_CNTR_INC(4 downto 0)),  
	DOB => SEQH
);

SEQ_GEN_000: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE_CLK_OUT <= SAMPLE_CLK_OUT_E;
		SOF_OUT <= SOF_OUT_E;
		
		if(SAMPLE_CLK_OUT_E = '1') then
			for I in 0 to 63 loop
				if(I = MODULO_CNTR_D(10 downto 5)) then
					DATA_OUT_local(63-I downto 0) <= SEQL(63 downto I);
					if(I > 0) then
						DATA_OUT_local(63 downto 64-I) <= SEQH(I-1 downto 0);
					end if;
				end if;
			end loop;
		end if;
	end if;
end process;   

-- LSb or MSb first?
ORDER: process(DATA_OUT_local)
begin
	if(MSB_FIRST = '0') then
		-- LSb first
		for I in 0 to 63 loop
			DATA_OUT(I) <= DATA_OUT_local(I);
		end loop;
	else
		for I in 0 to 63 loop
			DATA_OUT(I) <= DATA_OUT_local(63-I);
		end loop;
	end if;
end process;


MODULO_CNTR_INC <= MODULO_CNTR + 1;
SEQ_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		MODULO_CNTR_D <= MODULO_CNTR;
		
		if(SYNC_RESET = '1') then  
			MODULO_CNTR <= (others => '0');
			SAMPLE_CLK_OUT_E <= '0';
		elsif(SAMPLE_CLK_OUT_REQ = '1') then
			SAMPLE_CLK_OUT_E <= '1';
			if(MODULO_CNTR(4 downto 0) = 30) and (MODULO_CNTR(10 downto 5) = "111111") then
				-- skip word 31 once every 64*2047 bits
				MODULO_CNTR <= (others => '0');
			else
				MODULO_CNTR <= MODULO_CNTR_INC;
			end if;
		else
			SAMPLE_CLK_OUT_E <= '0';
		end if;
	end if;
end process;   

SEQ_GEN_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then  
			SOF_OUT_E <= '0';
		elsif(SAMPLE_CLK_OUT_REQ = '1') and (MODULO_CNTR = 0)  then
			SOF_OUT_E <= '1';
		else
			SOF_OUT_E <= '0';
		end if;
	end if;
end process;   





end behavior;

