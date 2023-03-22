-------------------------------------------------------------
-- MSS copyright 2021
--	Filename:  BER64.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 1/14/21
-- Inheritance: 	n/a
--
-- description:  
-- Higher-speed bit error rate measurement.
-- Assumes that a known 2047-bit periodic sequence is being transmitted.
-- Automatic synchronization.
-- For high-speed, the input is 64-bit parallel. No assumption is made as
-- to the alignment of the PRBS-11 2047-bit periodic sequence with word
-- boundaries.
--
-- Algorithm:
-- The BER tester operates in two phases:
-- acquisition: search the 2047-bit sequence for a match with the first 64-bit input at the start of acquisition.
-- If a match with less than DETECT_THRESHOLD bit errors is found, the BERT goes to tracking phase. If not restart acquisition.
-- tracking: count bit errors. If BER is greater than 25% in a window, go back to acquisition phase.
--
-- Device utilization:
-- FF 375
-- LUT 958
-- 36Kb BRAM 6
-- DSP 0
-- GCLK 1
-- Minimum period: 153 MHz  Artix7-1 (slowest) speed grade
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity BER64 is
	Generic (
		MSB_FIRST: std_logic := '0'
			-- '1' for MSb first, '0' for LSb first
	);
	port ( 
		--GLOBAL CLOCKS, RESET
	   CLK : in std_logic;	-- master clock for this FPGA, synchronous 
		SYNC_RESET: in std_logic;	-- synchronous reset
			-- resets the bit error counter, 

		--// Input samples
		DATA_IN: in std_logic_vector(63 downto 0);
			-- 8-bit parallel input. MSb is first.
			-- Read at rising edge of CLK when SAMPLE_CLK_IN = '1';
		SAMPLE_CLK_IN: in std_logic;
			-- one CLK-wide pulse

		--// Controls
	   CONTROL: in std_logic_vector(7 downto 0);
			-- bits 2-0: error measurement window. Expressed in 64-bit words!
				-- 000 = 1,000 words
				-- 001 = 10,000 words
				-- 010 = 100,000 words
				-- 011 = 1,000,000 words
				-- 100 = 10,000,000 words
				-- 101 = 100,000,000 words
				-- 110 = 1,000,000,000 words
			-- bit 7-3: unused

		--// Outputs
		WORD_ERROR: out std_logic;
			-- 1 clk-wide pulse when input word includes at least one bit error
		SYNCD: out std_logic;
			-- BER tester is synchronized when SYNCD = '1'
			-- BER is invalid when BERT is not synchronized (SYNCD = '0')
		BER: out std_logic_vector(31 downto 0);
		BER_SAMPLE_CLK: out std_logic;	
			-- bit errors expressed in number of BITS
			-- (whereas the window is expressed in words)
			-- valid only when BER tester is synchronized (SYNCD = '1')

		-- test point
		TP: out std_logic_vector(10 downto 1)
			);
end entity;

architecture behavioral of BER64 is
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

	COMPONENT PC_16
	PORT(
		A : IN std_logic_vector(15 downto 0);          
		O : OUT std_logic_vector(4 downto 0)
		);
	END COMPONENT;

	COMPONENT FIFO
	GENERIC(
		DATA_WIDTH: integer;	
		DEPTH: integer 
	);
	PORT(
		CLK   : in  std_logic;
		SYNC_RESET: in std_logic;
		DATA_IN   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
		DATA_IN_VALID  : in std_logic;
		DATA_OUT   : out  std_logic_vector(DATA_WIDTH-1 downto 0);
		DATA_OUT_VALID  : out std_logic
		);
	END COMPONENT;

	COMPONENT BRAM_DP2C
	GENERIC(
		DATA_WIDTH: integer;
		ADDR_WIDTH: integer
	);
	PORT(
		CLK   : in  std_logic;
		CSA    : in  std_logic;	
		WEA    : in  std_logic;	
		ADDRA  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
		DIA   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
		CSB    : in  std_logic;	
		ADDRB  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
		DOB  : out std_logic_vector(DATA_WIDTH-1 downto 0)
		);
	END COMPONENT;
	
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

constant	DETECT_THRESHOLD: std_logic_vector(5 downto 0) := "001010";
	-- maximum mismatch in 64-bit sequence to declare a DETECT
	-- Here, the detection threshold is set at 15.6% bit errors or 10 mismatches out of 64 
	-- Adjust depending on worst case SNR

-- LSb or MSb first?
signal DATA1: std_logic_vector(63 downto 0) := (others => '0');
signal SAMPLE1_CLK_D: std_logic_vector(4 downto 0) := (others => '0');

--// STATE MACHINE ---------------------------------
signal STATE: integer range 0 to 3 := 0;
signal STATE1: std_logic:= '0';
signal STATE1_D: std_logic:= '0';
signal STATE1_D2: std_logic:= '0';
signal STATE1_D3: std_logic:= '0';
signal STATE2: std_logic:= '0';
signal STATE2_D: std_logic:= '0';
signal STATE2_D2: std_logic:= '0';
signal STATE2_D3: std_logic:= '0';
signal STATE_CNTR: unsigned(11 downto 0) := (others => '0');
signal STATE_CNTR_D: unsigned(11 downto 0) := (others => '0');

--// ACQUISITION PHASE ---------------------------------
signal MODULO_CNTR0: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR0_D: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR0_D4: std_logic_vector(10 downto 0) := (others => '0');
signal MODULO_CNTR0_INC: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR2: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR2_D: unsigned(10 downto 0) := (others => '0');
signal MODULO_CNTR2_INC: unsigned(10 downto 0) := (others => '0');

signal DATA2: std_logic_vector(63 downto 0) := (others => '0');
signal ADDRA: std_logic_vector(4 downto 0) := (others => '0');
signal ADDRB: std_logic_vector(4 downto 0) := (others => '0');
signal SEQL: std_logic_vector(63 downto 0) := (others => '0');
signal SEQH: std_logic_vector(63 downto 0) := (others => '0');
signal REPLICA: std_logic_vector(63 downto 0) := (others => '0');
signal WORD0: std_logic_vector(63 downto 0) := (others => '0');
signal MF0A: std_logic_vector(4 downto 0) := (others => '0');
signal MF0B: std_logic_vector(4 downto 0) := (others => '0');
signal MF0C: std_logic_vector(4 downto 0) := (others => '0');
signal MF0D: std_logic_vector(4 downto 0) := (others => '0');
signal MFSUM0: unsigned(6 downto 0) := (others => '0');
signal SIGNMF0: std_logic:= '0';
signal MF0: unsigned(6 downto 0) := (others => '0');
signal DETECT: std_logic:= '0';
signal INVERSION: std_logic:= '0';

--// TRACKING PHASE -------------------------------
signal DATA1B: std_logic_vector(63 downto 0) := (others => '0');
signal WPTR1: unsigned(10 downto 0) := (others => '0');
signal WPTR0: unsigned(10 downto 0) := (others => '0');
signal RPTR1: unsigned(10 downto 0) := (others => '0');
signal BUF1_SIZE: unsigned(10 downto 0) := (others => '0');
signal SAMPLE2_CLK_E: std_logic:= '0';
signal SAMPLE2_CLK: std_logic:= '0';
signal SAMPLE2_CLK_D: std_logic:= '0';

signal N_WORDS: unsigned(29 downto 0):= (others => '0');
signal N_WORDS_MAX: unsigned(29 downto 0):= (others => '0');
signal NBITERRORS: unsigned(31 downto 0):= (others => '0');
signal EXCESSIVE_BER: std_logic:= '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- LSb or MSb first?
ORDER: process(DATA_IN)
begin
	if(MSB_FIRST = '0') then
		-- LSb first
		for I in 0 to 63 loop
			DATA1(I) <= DATA_IN(I);
		end loop;
	else
		for I in 0 to 63 loop
			DATA1(I) <= DATA_IN(63-I);
		end loop;
	end if;
end process;

-- various input sampling delays
SAMPLE1_CLK_D(0) <= SAMPLE_CLK_IN;
SAMPLE1_CLK_D_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE1_CLK_D(SAMPLE1_CLK_D'left downto 1) <= SAMPLE1_CLK_D(SAMPLE1_CLK_D'left-1 downto 0);
	end if;
end process;

--// STATE MACHINE ---------------------------------
STATE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		STATE_CNTR_D <= STATE_CNTR;
		STATE1_D <= STATE1;
		STATE1_D2 <= STATE1_D;
		STATE1_D3 <= STATE1_D2;
		STATE2_D <= STATE2;
		STATE2_D2 <= STATE2_D;
		STATE2_D3 <= STATE2_D2;
		
		
		if(SYNC_RESET = '1') then
			STATE <= 0;
			STATE_CNTR <= (others => '0');
		elsif (STATE = 0) and (SAMPLE_CLK_IN = '1') then
			-- entering acquisition phase
			STATE <= 1;
			STATE_CNTR <= (others => '0');
		elsif (STATE = 1) then
			if(DETECT = '1') then
				-- successful match
				STATE <= 2;
			elsif(STATE_CNTR = 2051) then
				-- timeout searching for match
				STATE <= 0;	-- explored all possible shifts, no detection. Restart acquisition with next input word
				STATE_CNTR <= (others => '0');
			else
				STATE_CNTR <= STATE_CNTR + 1 ;
			end if;
		elsif(STATE = 2) and (EXCESSIVE_BER = '1') then
			-- BERT lost synchronization. Return to acquisition phase
			STATE <= 0;
			STATE_CNTR <= (others => '0');
		end if;
	end if;
end process;
STATE1 <= '1' when (STATE = 1) else '0';
STATE2 <= '1' when (STATE = 2) else '0';

--// ACQUISITION PHASE ---------------------------------
-- collect word to search, count subsequent input words during search

-- scan all words (32) x all shifts (64) during the acquisition phase
MODULO_CNTR0_INC <= MODULO_CNTR0 + 1;
SEQ_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		MODULO_CNTR0_D <= MODULO_CNTR0;
		
		if(SYNC_RESET = '1') or (STATE = 0) then  
			MODULO_CNTR0 <= (others => '0');
		elsif(STATE = 1) then
			if(MODULO_CNTR0(4 downto 0) = 30) and (MODULO_CNTR0(10 downto 5) = "111111") then
				-- skip word 31 once every 64*2047 bits
				MODULO_CNTR0 <= (others => '0');
			else
				MODULO_CNTR0 <= MODULO_CNTR0_INC;
			end if;
		end if;
	end if;
end process;   


-- for each search word, we try to match it with 64*32 = 2048 replica offsets
-- latency 1 CLK
LFSR11P64ROM_001: process(STATE, MODULO_CNTR0, MODULO_CNTR0_INC, MODULO_CNTR2, MODULO_CNTR2_INC)
begin
	if(STATE = 1) then
		-- acquisition phase
		ADDRA <= std_logic_vector(MODULO_CNTR0(4 downto 0));  
		ADDRB <= std_logic_vector(MODULO_CNTR0_INC(4 downto 0));
	else
		-- tracking phase
		ADDRA <= std_logic_vector(MODULO_CNTR2(4 downto 0));
		ADDRB <= std_logic_vector(MODULO_CNTR2_INC(4 downto 0));
	end if;
end process;

LFSR11P64ROM_002: LFSR11P64ROM 
GENERIC MAP(
	DATA_WIDTH => 64,
	ADDR_WIDTH	=> 5
)
PORT MAP(
	CLK => CLK,
	ADDRA => ADDRA,  
	DOA => SEQL,  -- aligned with STATE_CNTR_D 
	ADDRB => ADDRB,  
	DOB => SEQH
);

-- replica
-- aligned with STATE_CNTR_D2
REPLICA_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(STATE = 1) then
			-- acquisition phase
			for I in 0 to 63 loop
				if(I = MODULO_CNTR0_D(10 downto 5)) then
					REPLICA(63-I downto 0) <= SEQL(63 downto I);
					if(I > 0) then
						REPLICA(63 downto 64-I) <= SEQH(I-1 downto 0);
					end if;
				end if;
			end loop;
			
		else
			-- tracking phase
			for I in 0 to 63 loop
				if(I = MODULO_CNTR2_D(10 downto 5)) then
					REPLICA(63-I downto 0) <= SEQL(63 downto I);
					if(I > 0) then
						REPLICA(63 downto 64-I) <= SEQH(I-1 downto 0);
					end if;
				end if;
			end loop;	
		end if;
	end if;
end process;   

-- 
SEARCH_SEQ_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (STATE = 0) and (SAMPLE_CLK_IN = '1') then
			-- entering search phase
			DATA2 <= DATA1;	-- aligned with STATE_CNTR
		elsif (STATE = 2) and (SAMPLE2_CLK = '1') then
			DATA2 <= DATA1B;	
		end if;
	end if;
end process;


-- check match between search sequence/received sequence and replica
WORD0 <= DATA2 xor REPLICA; 	
	-- 0 when DATA2 matches REPLICA. 
	-- aligned with STATE_CNTR_D2
PC_16_0A: PC_16 PORT MAP(
	A => WORD0(15 downto 0),
	O => MF0A
);
PC_16_0B: PC_16 PORT MAP(
	A => WORD0(31 downto 16),
	O => MF0B
);
PC_16_0C: PC_16 PORT MAP(
	A => WORD0(47 downto 32),
	O => MF0C
);
PC_16_0D: PC_16 PORT MAP(
	A => WORD0(63 downto 48),
	O => MF0D
);

-- aligned with STATE_CNTR_D3
SUM_001: process(CLK)
begin
	if rising_edge(CLK) then
		--// sum the multiple 2-BYTE matched filter outputs to create a 8-BYTE matched filter
		-- sum with precision extension to prevent overflow
		-- Range 0 - 64
		MFSUM0 <= unsigned("00" & MF0A) + unsigned("00" & MF0B) + unsigned("00" & MF0C) + unsigned("00" & MF0D);
	end if;
end process;   

-- remember the signs
-- 0 = perfect match, 64 = perfect inversion
SIGNMF0 <= '0' when (MFSUM0(6 downto 5) = "00") else '1';

-- aligned with STATE_CNTR_D3
ABS_001: process(MFSUM0, SIGNMF0)
begin
	-- number of bit errors w.r.t. replica (after correcting for possible inversion)
	if(SIGNMF0 = '0') then
		MF0(6 downto 0) <= MFSUM0(6 downto 0);
	else
		MF0(6 downto 0) <= 64- MFSUM0(6 downto 0);
	end if;
end process;

-- The detection threshold is set at 15.6% bit errors or 10 mismatches out of 64 
-- aligned with STATE_CNTR_D4
DETECT_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			DETECT <= '0';
			INVERSION <= '0';
		elsif(DETECT = '1') or (STATE1 = '0') then
			DETECT <= '0';
		elsif(STATE1_D3 = '1') and (MF0(5 downto 0) < unsigned(DETECT_THRESHOLD)) then
			DETECT <= '1';
			INVERSION <= SIGNMF0;
		else
			DETECT <= '0';
		end if;
	end if;
end process; 

-- re-align matching sequence pointer with DETECT (4 CLKs delay)
FIFO_001a: FIFO 
GENERIC MAP(
	 DATA_WIDTH => MODULO_CNTR0'length,        
	 DEPTH => 4
)
PORT MAP(
	CLK => CLK,
	SYNC_RESET => SYNC_RESET,
	DATA_IN => std_logic_vector(MODULO_CNTR0),	
	DATA_IN_VALID => '1',
	DATA_OUT => MODULO_CNTR0_D4,
	DATA_OUT_VALID => open
);



--// TRACKING PHASE -------------------------------

-- save input stream
-- read during tracking phase

WPTR1_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WPTR1 <= (others => '0');
		elsif(SAMPLE_CLK_IN = '1') then
			WPTR1 <= WPTR1 + 1;

			if (STATE = 0) then
				-- entering acquisition phase
				-- remember pointer for acquisition search sequence in elastic buffer
				WPTR0 <= WPTR1;
			end if;
		end if;
	end if;
end process;

BRAM_DP2C_001: BRAM_DP2C
GENERIC MAP(
	DATA_WIDTH => 64,		
	ADDR_WIDTH => WPTR1'length

)
PORT MAP(
	CLK => CLK,
	CSA => '1',
	WEA => SAMPLE_CLK_IN,      -- Port A Write Enable Input
	ADDRA => std_logic_vector(WPTR1),  -- Port A 8-bit Address Input
	DIA => DATA1,      -- Port A 64-bit Data Input
	CSB => '1',
	ADDRB => std_logic_vector(RPTR1),  -- Port B 8-bit Address Input
	DOB => DATA1B      -- Port B 64-bit Data Output
);

BUF1_SIZE <= WPTR1 + not(RPTR1);

RPTR1_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE2_CLK <= SAMPLE2_CLK_E;	-- 1 CLK latency in reading
		SAMPLE2_CLK_D <= SAMPLE2_CLK;	
		
		if(SYNC_RESET = '1') then
			RPTR1 <= (others => '1');
			SAMPLE2_CLK_E <= '0';
		elsif(STATE1 = '1') and (DETECT = '1') then
			-- end of acquisition: found sequence match. Rewind read pointer
			RPTR1 <= WPTR0;
			SAMPLE2_CLK_E <= '1';
		elsif(STATE = 2) and (BUF1_SIZE /= 0) then
			RPTR1 <= RPTR1 + 1;
			SAMPLE2_CLK_E <= '1';
		else
			SAMPLE2_CLK_E <= '0';
		end if;
	end if;
end process;

-- tracking
MODULO_CNTR2_INC <= MODULO_CNTR2 + 1;
SEQ_GEN_002: process(CLK)
begin
	if rising_edge(CLK) then
		MODULO_CNTR2_D <= MODULO_CNTR2;
		
		if(SYNC_RESET = '1') or (STATE = 0) then  
			MODULO_CNTR2 <= (others => '0');
		elsif(STATE1 = '1') and (DETECT = '1') then
			-- table lookup offset at the time of matched filter detection
			MODULO_CNTR2 <= unsigned(MODULO_CNTR0_D4);
		elsif(STATE = 2) and (BUF1_SIZE /= 0) then
			if(MODULO_CNTR2(4 downto 0) = 30) and (MODULO_CNTR2(10 downto 5) = "111111") then
				-- skip word 31 once every 64*2047 bits
				MODULO_CNTR2 <= (others => '0');
			else
				MODULO_CNTR2 <= MODULO_CNTR2_INC;
			end if;
		end if;
	end if;
end process;   


-- report BERT status
SYNCD <= STATE2_D3;

WORD_ERROR_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(MF0 /= 0) and (SAMPLE2_CLK_D = '1') and (STATE1_D3 = '0') then
			WORD_ERROR <= '1';
		else
			WORD_ERROR <= '0';
		end if;
	end if;
end process;

----// COUNT ERRORS -----------------------------
-- sum bit errors
BER_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (N_WORDS = N_WORDS_MAX) or (STATE2_D3 = '0') then
			NBITERRORS <= (others => '0');
			N_WORDS <= (others => '0');
		elsif(SAMPLE2_CLK_D = '1') then
			NBITERRORS <= NBITERRORS + resize(MF0, NBITERRORS'length);
			N_WORDS <= N_WORDS + 1;
		end if;
	end if;
end process;

BER_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			BER <= (others => '0');
			BER_SAMPLE_CLK <= '0';
		elsif(N_WORDS = N_WORDS_MAX) then
			-- end of BER window. Report totals
			BER <= std_logic_vector(NBITERRORS);
			BER_SAMPLE_CLK <= '1';
		else
			BER_SAMPLE_CLK <= '0';
		end if;
	end if;
end process;

-- is BER excessive? (above 25%)
BER_003: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (STATE2_D3 = '0') then
			EXCESSIVE_BER <= '0';
		elsif(N_WORDS = N_WORDS_MAX) and (resize(NBITERRORS(31 downto 6),28) > N_WORDS_MAX(29 downto 2)) then
			-- BER > 25%
			EXCESSIVE_BER <= '1';
		else
			EXCESSIVE_BER <= '0';
		end if;
	end if;
end process;




-- BER window size
N_WORDS_MAX_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		case CONTROL(2 downto 0) is
			when "001" => N_WORDS_MAX <= to_unsigned(10000,N_WORDS'length);
			when "010" => N_WORDS_MAX <= to_unsigned(100000,N_WORDS'length);
			when "011" => N_WORDS_MAX <= to_unsigned(1000000,N_WORDS'length);
			when "100" => N_WORDS_MAX <= to_unsigned(10000000,N_WORDS'length);
			when "101" => N_WORDS_MAX <= to_unsigned(100000000,N_WORDS'length);
			when "110" => N_WORDS_MAX <= to_unsigned(1000000000,N_WORDS'length);
			when others => N_WORDS_MAX <= to_unsigned(1000,N_WORDS'length);
		end case;
	end if;
end process;


end behavioral;
