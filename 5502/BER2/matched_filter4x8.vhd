-------------------------------------------------------------
-- MSS copyright 2009-2019
--	Filename:  MATCHED_FILTER4x8.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 10/11/19
-- Inheritance: 	BER.VHD
--
-- description:  
-- 32-bit matched filter with 8-bit parallel input.
-- The matched filter detects a match on all 8 possible alignments. 
-- It also report inverted sequences.
-- Default detection threshold is 3 mismatches out of 32 (9.3% BER). 
--
-- SEE ALSO MATCHED_FILTERNX8.VHD AS A FLEXIBLE GENERIC REPLACEMENT
--
-- Rev 1 10/11/19 AZ
-- Initialize simulation variables
-- 
--Device utilization summary:
-----------------------------
--   Minimum period: 4.879ns (Maximum Frequency: 204.960MHz) Artix7-1 speed grade
-- Device utilization, Xilinx Artix7-100T -1 speed grade
-- LUT: 530
-- FF: 400
-- BRAM: 0
-- DSP: 0
-- GCLK: 1
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity MATCHED_FILTER4x8 is
	generic (
		DETECT_THRESHOLD: std_logic_vector(4 downto 0) := "00011"
			-- maximum mismatch in 32-bit sequence to declare a DETECT
			-- Adjust depending on worst case SNR
	);
    port ( 
		--GLOBAL CLOCKS, RESET
	   CLK : in std_logic;	-- reference clock, synchronous 
		SYNC_RESET: in std_logic;	-- synchronous reset

		--// Input samples
		DATA_IN: in std_logic_vector(7 downto 0);
			-- 8-bit parallel input. MSb is first.
			-- Read at rising edge of CLK when SAMPLE_CLK_IN = '1';
		SAMPLE_CLK_IN: in std_logic;
			-- one CLK-wide pulse
		REFSEQ: in std_logic_vector(31 downto 0);   
			-- reference sequence. MSb first. 

		--// Output
		DETECT_OUT: out std_logic;
			-- 1 CLK wide pulse, 6 CLKs after the LAST byte of the reference sequence is at the input.
		PHASE_OUT: out std_logic_vector(2 downto 0);
			-- bit to byte alignment error. Correct by delaying the input signal PHASE_OUT bits.
		BIT_ERRORS: out std_logic_vector(4 downto 0);
			-- number of bit errors in the 32-bit reference sequence
		INVERSION: out std_logic;
		SAMPLE_CLK_OUT: out std_logic;
			-- when to read the four outputs above
			-- 6 CLKs latency w.r.t. SAMPLE_CLK_IN

		TP: out std_logic_vector(10 downto 1)
			
			);
end entity;

architecture behavioral of MATCHED_FILTER4x8 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT PC_16
	PORT(
		A : IN std_logic_vector(15 downto 0);          
		O : OUT std_logic_vector(4 downto 0)
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

--// SAVE 5 CONSECUTIVE INPUT BYTES -----------------------------------
signal DATA1: std_logic_vector(39 downto 0) := (others => '0'); 
signal SAMPLE1_CLK: std_logic;

--// COMPARE WITH LAST 24-BITS + FIRST 8-BITS OF PRBS11 TEST SEQUENCE  --------------
signal DATA10: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA11: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA12: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA13: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA14: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA15: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA16: std_logic_vector(31 downto 0) := (others => '0'); 
signal DATA17: std_logic_vector(31 downto 0) := (others => '0'); 

--// 32-BIT MATCHED FILTER -------------------------------------------
signal MF0A: std_logic_vector(4 downto 0) := (others => '0');
signal MF0B: std_logic_vector(4 downto 0) := (others => '0');
signal MF1A: std_logic_vector(4 downto 0) := (others => '0');
signal MF1B: std_logic_vector(4 downto 0) := (others => '0');
signal MF2A: std_logic_vector(4 downto 0) := (others => '0');
signal MF2B: std_logic_vector(4 downto 0) := (others => '0');
signal MF3A: std_logic_vector(4 downto 0) := (others => '0');
signal MF3B: std_logic_vector(4 downto 0) := (others => '0');
signal MF4A: std_logic_vector(4 downto 0) := (others => '0');
signal MF4B: std_logic_vector(4 downto 0) := (others => '0');
signal MF5A: std_logic_vector(4 downto 0) := (others => '0');
signal MF5B: std_logic_vector(4 downto 0) := (others => '0');
signal MF6A: std_logic_vector(4 downto 0) := (others => '0');
signal MF6B: std_logic_vector(4 downto 0) := (others => '0');
signal MF7A: std_logic_vector(4 downto 0) := (others => '0');
signal MF7B: std_logic_vector(4 downto 0) := (others => '0');
signal MFSUM0: unsigned(5 downto 0) := (others => '0');
signal MFSUM1: unsigned(5 downto 0) := (others => '0');
signal MFSUM2: unsigned(5 downto 0) := (others => '0');
signal MFSUM3: unsigned(5 downto 0) := (others => '0');
signal MFSUM4: unsigned(5 downto 0) := (others => '0');
signal MFSUM5: unsigned(5 downto 0) := (others => '0');
signal MFSUM6: unsigned(5 downto 0) := (others => '0');
signal MFSUM7: unsigned(5 downto 0) := (others => '0');
signal MF0: unsigned(4 downto 0) := (others => '0');
signal MF1: unsigned(4 downto 0) := (others => '0');
signal MF2: unsigned(4 downto 0) := (others => '0');
signal MF3: unsigned(4 downto 0) := (others => '0');
signal MF4: unsigned(4 downto 0) := (others => '0');
signal MF5: unsigned(4 downto 0) := (others => '0');
signal MF6: unsigned(4 downto 0) := (others => '0');
signal MF7: unsigned(4 downto 0) := (others => '0');
signal SAMPLE1_CLK_D: std_logic;
signal SIGNMF0: std_logic;
signal SIGNMF1: std_logic;
signal SIGNMF2: std_logic;
signal SIGNMF3: std_logic;
signal SIGNMF4: std_logic;
signal SIGNMF5: std_logic;
signal SIGNMF6: std_logic;
signal SIGNMF7: std_logic;

--// SELECT BEST MATCH -------------------------------------------
signal MF01: unsigned(4 downto 0) := (others => '0');
signal MF23: unsigned(4 downto 0) := (others => '0');
signal MF45: unsigned(4 downto 0) := (others => '0');
signal MF67: unsigned(4 downto 0) := (others => '0');
signal SIGNMF01: std_logic;
signal SIGNMF23: std_logic;
signal SIGNMF45: std_logic;
signal SIGNMF67: std_logic;
signal MF0123: unsigned(4 downto 0) := (others => '0');
signal MF4567: unsigned(4 downto 0) := (others => '0');
signal SIGNMF0123: std_logic;
signal SIGNMF4567: std_logic;
signal MF01234567: unsigned(4 downto 0) := (others => '0');
signal SIGNMF01234567: std_logic;
signal SEL01: std_logic_vector(2 downto 0) := (others => '0');
signal SEL23: std_logic_vector(2 downto 0) := (others => '0');
signal SEL45: std_logic_vector(2 downto 0) := (others => '0');
signal SEL67: std_logic_vector(2 downto 0) := (others => '0');
signal SEL0123: std_logic_vector(2 downto 0) := (others => '0');
signal SEL4567: std_logic_vector(2 downto 0) := (others => '0');
signal SEL01234567: std_logic_vector(2 downto 0) := (others => '0');
signal SAMPLE1_CLK_D2: std_logic;
signal SAMPLE1_CLK_D3: std_logic;
signal SAMPLE1_CLK_D4: std_logic;


--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// SAVE 5 CONSECUTIVE INPUT BYTES -----------------------------------
INPUT_001: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE1_CLK <= SAMPLE_CLK_IN;
		
		if(SYNC_RESET = '1') then
			DATA1 <= (others => '0');
		elsif(SAMPLE_CLK_IN = '1') then
			-- shift in the nominal 32-bits + 8 extra bits since 
			-- we are not sure of the byte alignment at this time.
			DATA1(7 downto 0) <= DATA_IN;
			DATA1(15 downto 8) <= DATA1(7 downto 0);
			DATA1(23 downto 16) <= DATA1(15 downto 8);
			DATA1(31 downto 24) <= DATA1(23 downto 16);
			DATA1(39 downto 32) <= DATA1(31 downto 24);
		end if;
	end if;
end process;

--// COMPARE WITH LAST 24-BITS + FIRST 8-BITS OF PRBS11 TEST SEQUENCE  --------------
COMPARE_001: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE1_CLK_D <= SAMPLE1_CLK;

		if(SAMPLE1_CLK = '1') then
			DATA10 <= DATA1(31 downto 0) xor REFSEQ;
			DATA11 <= DATA1(32 downto 1) xor REFSEQ;
			DATA12 <= DATA1(33 downto 2) xor REFSEQ;
			DATA13 <= DATA1(34 downto 3) xor REFSEQ;
			DATA14 <= DATA1(35 downto 4) xor REFSEQ;
			DATA15 <= DATA1(36 downto 5) xor REFSEQ;
			DATA16 <= DATA1(37 downto 6) xor REFSEQ;
			DATA17 <= DATA1(38 downto 7) xor REFSEQ;
		end if;
	end if;
end process;

--// 32-BIT MATCHED FILTER -------------------------------------------
PC_16_0A: PC_16 PORT MAP(
	A => DATA10(15 downto 0),
	O => MF0A
);
PC_16_0B: PC_16 PORT MAP(
	A => DATA10(31 downto 16),
	O => MF0B
);
PC_16_1A: PC_16 PORT MAP(
	A => DATA11(15 downto 0),
	O => MF1A
);
PC_16_1B: PC_16 PORT MAP(
	A => DATA11(31 downto 16),
	O => MF1B
);
PC_16_2A: PC_16 PORT MAP(
	A => DATA12(15 downto 0),
	O => MF2A
);
PC_16_2B: PC_16 PORT MAP(
	A => DATA12(31 downto 16),
	O => MF2B
);
PC_16_3A: PC_16 PORT MAP(
	A => DATA13(15 downto 0),
	O => MF3A
);
PC_16_3B: PC_16 PORT MAP(
	A => DATA13(31 downto 16),
	O => MF3B
);
PC_16_4A: PC_16 PORT MAP(
	A => DATA14(15 downto 0),
	O => MF4A
);
PC_16_4B: PC_16 PORT MAP(
	A => DATA14(31 downto 16),
	O => MF4B
);
PC_16_5A: PC_16 PORT MAP(
	A => DATA15(15 downto 0),
	O => MF5A
);
PC_16_5B: PC_16 PORT MAP(
	A => DATA15(31 downto 16),
	O => MF5B
);
PC_16_6A: PC_16 PORT MAP(
	A => DATA16(15 downto 0),
	O => MF6A
);
PC_16_6B: PC_16 PORT MAP(
	A => DATA16(31 downto 16),
	O => MF6B
);
PC_16_7A: PC_16 PORT MAP(
	A => DATA17(15 downto 0),
	O => MF7A
);
PC_16_7B: PC_16 PORT MAP(
	A => DATA17(31 downto 16),
	O => MF7B
);

SUM_001: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE1_CLK_D2 <= SAMPLE1_CLK_D;
		
		if(SAMPLE1_CLK_D = '1') then
			--// sum the two 16-bit matched filter outputs to create a 32-bit matched filter
			-- sum with precision extension to prevent overflow
			-- Range 0 - 32
			MFSUM0 <= unsigned("0" & MF0A) + unsigned("0" & MF0B);
			MFSUM1 <= unsigned("0" & MF1A) + unsigned("0" & MF1B);
			MFSUM2 <= unsigned("0" & MF2A) + unsigned("0" & MF2B);
			MFSUM3 <= unsigned("0" & MF3A) + unsigned("0" & MF3B);
			MFSUM4 <= unsigned("0" & MF4A) + unsigned("0" & MF4B);
			MFSUM5 <= unsigned("0" & MF5A) + unsigned("0" & MF5B);
			MFSUM6 <= unsigned("0" & MF6A) + unsigned("0" & MF6B);
			MFSUM7 <= unsigned("0" & MF7A) + unsigned("0" & MF7B);
		end if;
	end if;
end process;

ABS_001: process(MFSUM0, MFSUM1, MFSUM2, MFSUM3, MFSUM4, MFSUM5, MFSUM6, MFSUM7)
begin
	-- Take the absolute value
	if(MFSUM0(5) = '1') then 
		-- special case 32 = exact inversion
		MF0 <= (others => '0');
	elsif(MFSUM0(4) = '1') then 
		MF0 <= not MFSUM0(4 downto 0) + 1;
	else
		MF0 <= MFSUM0(4 downto 0);
	end if;
	if(MFSUM1(5) = '1') then 
		-- special case 32 = exact inversion
		MF1 <= (others => '0');
	elsif(MFSUM1(4) = '1') then 
		MF1 <= not MFSUM1(4 downto 0) + 1;
	else
		MF1 <= MFSUM1(4 downto 0);
	end if;
	if(MFSUM2(5) = '1') then 
		-- special case 32 = exact inversion
		MF2 <= (others => '0');
	elsif(MFSUM2(4) = '1') then 
		MF2 <= not MFSUM2(4 downto 0) + 1;
	else
		MF2 <= MFSUM2(4 downto 0);
	end if;
	if(MFSUM3(5) = '1') then 
		-- special case 32 = exact inversion
		MF3 <= (others => '0');
	elsif(MFSUM3(4) = '1') then 
		MF3 <= not MFSUM3(4 downto 0) + 1;
	else
		MF3 <= MFSUM3(4 downto 0);
	end if;
	if(MFSUM4(5) = '1') then 
		-- special case 32 = exact inversion
		MF4 <= (others => '0');
	elsif(MFSUM4(4) = '1') then 
		MF4 <= not MFSUM4(4 downto 0) + 1;
	else
		MF4 <= MFSUM4(4 downto 0);
	end if;
	if(MFSUM5(5) = '1') then 
		-- special case 32 = exact inversion
		MF5 <= (others => '0');
	elsif(MFSUM5(4) = '1') then 
		MF5 <= not MFSUM5(4 downto 0) + 1;
	else
		MF5 <= MFSUM5(4 downto 0);
	end if;
	if(MFSUM6(5) = '1') then 
		-- special case 32 = exact inversion
		MF6 <= (others => '0');
	elsif(MFSUM6(4) = '1') then 
		MF6 <= not MFSUM6(4 downto 0) + 1;
	else
		MF6 <= MFSUM6(4 downto 0);
	end if;
	if(MFSUM7(5) = '1') then 
		-- special case 32 = exact inversion
		MF7 <= (others => '0');
	elsif(MFSUM7(4) = '1') then 
		MF7 <= not MFSUM7(4 downto 0) + 1;
	else
		MF7 <= MFSUM7(4 downto 0);
	end if;
end process;

-- remember the signs
SIGNMF0 <= '0' when (MFSUM0(5 downto 4) = "00") else '1';
SIGNMF1 <= '0' when (MFSUM1(5 downto 4) = "00") else '1';
SIGNMF2 <= '0' when (MFSUM2(5 downto 4) = "00") else '1';
SIGNMF3 <= '0' when (MFSUM3(5 downto 4) = "00") else '1';
SIGNMF4 <= '0' when (MFSUM4(5 downto 4) = "00") else '1';
SIGNMF5 <= '0' when (MFSUM5(5 downto 4) = "00") else '1';
SIGNMF6 <= '0' when (MFSUM6(5 downto 4) = "00") else '1';
SIGNMF7 <= '0' when (MFSUM7(5 downto 4) = "00") else '1';


--// SELECT BEST MATCH -------------------------------------------
-- Pipelined for speed
-- Best match is when all bits match the reference sequence. Then MF = all zeros.
MOST_POSITIVE_001: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE1_CLK_D3 <= SAMPLE1_CLK_D2;
		
		if(SAMPLE1_CLK_D2 = '1') then
			if(MF0 < MF1) then
				MF01 <= MF0;
				SEL01 <= "000";
				SIGNMF01 <= SIGNMF0;
			else
				MF01 <= MF1;
				SEL01 <= "001";
				SIGNMF01 <= SIGNMF1;
			end if;
			if(MF2 < MF3) then
				MF23 <= MF2;
				SEL23 <= "010";
				SIGNMF23 <= SIGNMF2;
			else
				MF23 <= MF3;
				SEL23 <= "011";
				SIGNMF23 <= SIGNMF3;
			end if;
			if(MF4 < MF5) then
				MF45 <= MF4;
				SEL45 <= "100";
				SIGNMF45 <= SIGNMF4;
			else
				MF45 <= MF5;
				SEL45 <= "101";
				SIGNMF45 <= SIGNMF5;
			end if;
			if(MF6 < MF7) then
				MF67 <= MF6;
				SEL67 <= "110";
				SIGNMF67 <= SIGNMF6;
			else
				MF67 <= MF7;
				SEL67 <= "111";
				SIGNMF67 <= SIGNMF7;
			end if;
		end if;
	end if;
end process; 

MOST_POSITIVE_002: process(MF01, MF23, MF45, MF67, SEL01, SEL23, SEL45, SEL67,
		SIGNMF01, SIGNMF23, SIGNMF45, SIGNMF67)
begin
	if(MF01 < MF23) then
		MF0123 <= MF01;
		SEL0123 <= SEL01;
		SIGNMF0123 <= SIGNMF01;
	else
		MF0123 <= MF23;
		SEL0123 <= SEL23;
		SIGNMF0123 <= SIGNMF23;
	end if;
	if(MF45 < MF67) then
		MF4567 <= MF45;
		SEL4567 <= SEL45;
		SIGNMF4567 <= SIGNMF45;
	else
		MF4567 <= MF67;
		SEL4567 <= SEL67;
		SIGNMF4567 <= SIGNMF67;
	end if;
end process; 

MOST_POSITIVE_003: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE1_CLK_D4 <= SAMPLE1_CLK_D3;
		
		if(SAMPLE1_CLK_D3 = '1') then
			if(MF0123 < MF4567) then
				MF01234567 <= MF0123;
				SEL01234567 <= SEL0123;
				SIGNMF01234567 <= SIGNMF0123;
			else
				MF01234567 <= MF4567;
				SEL01234567 <= SEL4567;
				SIGNMF01234567 <= SIGNMF4567;
			end if;
		end if;
	end if;
end process; 

--// ABOVE THRESHOLD? -------------------------------------------
-- The detection threshold is set at 9.34% bit errors or 3 mismatches out of 32 
DETECT_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE_CLK_OUT <= SAMPLE1_CLK_D4;
		
		if(SYNC_RESET = '1') then
			DETECT_OUT <= '0';
			INVERSION <= '0';
			PHASE_OUT <= (others => '0');
		elsif(SAMPLE1_CLK_D4 = '1') then
			if(MF01234567 < unsigned(DETECT_THRESHOLD)) then
				DETECT_OUT <= '1';
				INVERSION <= SIGNMF01234567;
				PHASE_OUT <= SEL01234567;
				BIT_ERRORS <= std_logic_vector(MF01234567);
			else
				DETECT_OUT <= '0';
			end if;
		else
			DETECT_OUT <= '0';
		end if;
	end if;
end process; 


--// TEST POINTS --------------------------------
-- N/A

end behavioral;
