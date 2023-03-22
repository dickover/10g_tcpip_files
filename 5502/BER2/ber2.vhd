-------------------------------------------------------------
-- MSS copyright 2009-2012
--	Filename:  BER2.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 2
--	Date last modified: 11/1/19
-- Inheritance: 	BER.VHD
--
-- description:  
-- Higher-speed bit error rate measurement.
-- Assumes that a known 2047-bit periodic sequence is being transmitted.
-- Automatic synchronization.
-- For high-speed, the input is 8-bit parallel. No assumption is made as
-- to the alignment of the PRBS-11 2047-bit periodic sequence with byte
-- boundaries.
--
-- Minimum period: 14.082ns (Maximum Frequency: 71.013MHz
--
-- Rev1 8/16/09 AZ
-- Initialization for simulation
--
-- Rev2 11/1/19 AZ
-- Code is now portable. Removed Xilinx primitive.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity BER2 is
    port ( 
		--GLOBAL CLOCKS, RESET
	   CLK : in std_logic;	-- master clock for this FPGA, synchronous 
		SYNC_RESET: in std_logic;	-- synchronous reset
			-- resets the bit error counter, 

		--// Input samples
		DATA_IN: in std_logic_vector(7 downto 0);
			-- 8-bit parallel input. MSb is first.
			-- Read at rising edge of CLK when SAMPLE_CLK_IN = '1';
		SAMPLE_CLK_IN: in std_logic;
			-- one CLK-wide pulse

		--// Controls
	   CONTROL: in std_logic_vector(7 downto 0);
			-- bits 2-0: error measurement window. Expressed in bytes!
				-- 000 = 1,000 bytes
				-- 001 = 10,000 bytes
				-- 010 = 100,000 bytes
				-- 011 = 1,000,000 bytes
				-- 100 = 10,000,000 bytes
				-- 101 = 100,000,000 bytes
				-- 110 = 1,000,000,000 bytes
			-- bit 7-3: unused

		--// Outputs
		MF_DETECT: out std_logic;
			-- raw detection of the last 32-bit of PRBS-11 sequence, straight from the matched filter.
			-- may include false alarms due to the transmitted sequence including strands similar to the reference 32-bit sequence.
		MF_DETECT_CONFIRMED: out std_logic;
			-- cleaned up version of MF_DETECT. Good to use as a clean trigger.
		SYNC_LOCK: out std_logic;


		BYTE_ERROR: out std_logic;
		DATA_REPLICA: out std_logic_vector(7 downto 0);
			-- local data replica (compare with DATA_IN)
		SAMPLE_CLK_OUT: out std_logic;
		

		BER: out std_logic_vector(31 downto 0);
		BER_SAMPLE_CLK: out std_logic;	
			-- bit errors expressed in number of BITS
			-- (whereas the window is expressed in bytes)
		
		-- test point
		TP: out std_logic_vector(10 downto 1)
			
			);
end entity;

architecture behavioral of BER2 is
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

	COMPONENT MATCHED_FILTER4x8
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		DATA_IN : IN std_logic_vector(7 downto 0);
		SAMPLE_CLK_IN : IN std_logic;          
		REFSEQ: in std_logic_vector(31 downto 0);   
		DETECT_OUT : OUT std_logic;
		PHASE_OUT : OUT std_logic_vector(2 downto 0);
		BIT_ERRORS : OUT std_logic_vector(4 downto 0);
		INVERSION : OUT std_logic;
		SAMPLE_CLK_OUT : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;
	
	COMPONENT SOF_TRACK8
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		DETECT_IN : IN std_logic;
		PHASE_IN : IN std_logic_vector(2 downto 0);
		INVERSION_IN : IN std_logic;
		SAMPLE_CLK_IN : IN std_logic;
		FRAME_LENGTH : IN std_logic_vector(15 downto 0);
		SUPERFRAME_LENGTH : IN std_logic_vector(7 downto 0);          
		SAMPLE_CLK_OUT : OUT std_logic;
		SOF_OUT : OUT std_logic;
		SOSF_OUT : OUT std_logic;
		SOF_LOCK_DETECT : OUT std_logic;
		PHASE_OUT : OUT std_logic_vector(2 downto 0);
		RESET_REPLICA: out std_logic;
		DATA_ENABLE: out std_logic
		);
	END COMPONENT;

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

--// MATCHED FILTER -----------------------------------
signal MF_DETECT_LOCAL: std_logic:= '0';
signal MF_PHASE: std_logic_vector(2 downto 0) := (others => '0');
signal MF_INVERSION: std_logic:= '0';
signal SAMPLE_CLK_IN_D6: std_logic:= '0';
signal DATA_IN_D: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D2: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D3: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D4: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D5: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D6: std_logic_vector(7 downto 0) := (others => '0'); 

--// CONFIRMATION --------------------------------------
constant FRAME_LENGTH : std_logic_vector(15 downto 0) := x"07FF";  -- 2047, prbs11
constant	SUPERFRAME_LENGTH : std_logic_vector(7 downto 0) := x"01";  -- no superframe structure here     
signal SAMPLE_CLK_IN_D7: std_logic:= '0';
signal DATA_IN_D7: std_logic_vector(7 downto 0) := (others => '0'); 
signal SOF: std_logic:= '0';
signal SOSF: std_logic:= '0';
signal SOF_LOCK_DETECT: std_logic:= '0';
signal RESET_REPLICA: std_logic:= '0';

--// SEQUENCE REPLICA -------------------------------
signal ADDR: std_logic_vector(10 downto 0) := (others => '0');
signal ADDR_INC: std_logic_vector(10 downto 0) := (others => '0');
signal DR: std_logic_vector(7 downto 0) := (others => '0');
signal SAMPLE_CLK_IN_D8: std_logic:= '0';
signal SAMPLE_CLK_IN_D9: std_logic:= '0';
signal DATA_IN_D8: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D9: std_logic_vector(7 downto 0) := (others => '0'); 
signal DATA_IN_D10: std_logic_vector(7 downto 0) := (others => '0'); 
signal DELAY: std_logic_vector(2 downto 0) := (others => '0');
signal DATA_IN_D9B: std_logic_vector(7 downto 0) := (others => '0'); 

--// COUNT ERRORS -----------------------------
signal DATA_ERR: std_logic_vector(15 downto 0) := (others => '0');
signal N_ERR: std_logic_vector(4 downto 0) := (others => '0');
signal N_BYTES: std_logic_vector(31 downto 0) := (others => '0');
signal N_BYTES_MAX: std_logic_vector(31 downto 0) := (others => '0');
signal N_BYTES_INC: std_logic_vector(31 downto 0) := (others => '0');
signal BER_LOCAL: std_logic_vector(31 downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- REMINDER++++++++++++++++++++++++++++++++
-- The SOF is aligned with the LAST BYTE in the periodic sequence
--+++++++++++++++++++++++++++++++++++++++++

--// MATCHED FILTER -----------------------------------
-- 6 CLK latency

MATCHED_FILTER4x8_001: MATCHED_FILTER4x8 PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET,
		DATA_IN => DATA_IN,
		SAMPLE_CLK_IN => SAMPLE_CLK_IN,
		REFSEQ => x"8B4B3300",  -- last 24 bits of the 2047-bit PRBS-11 sequence and the first 8 bits
		DETECT_OUT => MF_DETECT_LOCAL,
		PHASE_OUT => MF_PHASE,
		BIT_ERRORS => open,
		INVERSION => MF_INVERSION,
		SAMPLE_CLK_OUT => SAMPLE_CLK_IN_D6,
		TP => open
	);


-- re-align DATA_IN with the matched filter output
RECLOCK_001: process(CLK)
begin
	if rising_edge(CLK) then
		DATA_IN_D <= DATA_IN;
		DATA_IN_D2 <= DATA_IN_D;
		DATA_IN_D3 <= DATA_IN_D2;
		DATA_IN_D4 <= DATA_IN_D3;
		DATA_IN_D5 <= DATA_IN_D4;
		DATA_IN_D6 <= DATA_IN_D5;
	end if;
end process;  


--// CONFIRMATION --------------------------------------
-- verify the periodic nature of the received sequence. Declare lock when true.
-- Flywheel: reconstruct the missing start of sequences when we are confident that the alignment is correct.
SOF_TRACK8_001: SOF_TRACK8 PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET,
		DETECT_IN =>MF_DETECT_LOCAL ,
		PHASE_IN => MF_PHASE,
		INVERSION_IN => MF_INVERSION,
		SAMPLE_CLK_IN => SAMPLE_CLK_IN_D6,
		FRAME_LENGTH => FRAME_LENGTH,
		SUPERFRAME_LENGTH => SUPERFRAME_LENGTH,
		SAMPLE_CLK_OUT => SAMPLE_CLK_IN_D7,
		SOF_OUT => SOF,
		SOSF_OUT => SOSF,
		SOF_LOCK_DETECT => SOF_LOCK_DETECT, 
		PHASE_OUT => DELAY,         -- number of bit delays to apply to the input data stream so that it is aligned with the data replica DR. Confirmed at the first lock.
		RESET_REPLICA => RESET_REPLICA,
		DATA_ENABLE => open
	);

-- re-align DATA_IN with the matched filter output
RECLOCK_002: process(CLK)
begin
	if rising_edge(CLK) then
		DATA_IN_D7 <= DATA_IN_D6;
	end if;
end process;

--// SEQUENCE REPLICA -------------------------------            
-- Stores 8 contiguous PRBS-11 sequence. Period is 8*2047 bits.		
LFSR11PROM_001: LFSR11PROM PORT MAP(
	CLKA => CLK,
	CSA => '1',
	OEA => '1',
	ADDRA => ADDR,  -- 11-bit Address Input, aligned with SAMPLE_CLK_IN_D8
	DOA => DR,      -- 8-bit Data Output
	CLKB => CLK,
	CSB => '0',
	OEB => '0',
	ADDRB => (others => '0'),
	DOB => open
);

-- replica read pointer management
-- Modulo FRAME_LENGTH      
-- ADDR is aligned with SAMPLE_CLK_IN_D8
ADDR_INC <= ADDR + 1;
ADDR_GEN_001: 	process(CLK)
begin
	if rising_edge(CLK) then
		if(RESET_REPLICA = '1') then  
			-- aligned with SAMPLE_CLK_IN_D7
			ADDR <= (others => '0');
		elsif(SAMPLE_CLK_IN_D7 = '1') then
			if(ADDR_INC = FRAME_LENGTH) then
				ADDR <= (others => '0');
			else
				ADDR <= ADDR_INC;
			end if;
		end if;
	end if;
end process;

-- re-align DATA_IN with the RAMB output
RECLOCK_003: process(CLK)
begin
	if rising_edge(CLK) then  
		SAMPLE_CLK_IN_D8 <= SAMPLE_CLK_IN_D7;  -- 1 CLK delay to get ADDR
		SAMPLE_CLK_IN_D9 <= SAMPLE_CLK_IN_D8;  -- 1 CLK delay to extract data from RAMB

		if(SAMPLE_CLK_IN_D7 = '1') then
			DATA_IN_D8 <= DATA_IN_D7;
		end if;

		if(SAMPLE_CLK_IN_D8 = '1') then
			DATA_IN_D9 <= DATA_IN_D8;
		end if;
		
		-- store two consecutive bytes (so that we can implement bit-wise delays)
		if(SAMPLE_CLK_IN_D9 = '1') then
			DATA_IN_D10 <= DATA_IN_D9;
		end if;
		
	end if;
end process;

-- Delay input signal by a few bits to align with the data replica   
-- still aligned with aligned with SAMPLE_CLK_IN_D9
DELAY_001: process(DATA_IN_D9, DATA_IN_D10, DELAY)
begin
	case DELAY is
		when "000" => DATA_IN_D9B <= DATA_IN_D9;  -- 0 bit offset
		when "001" => DATA_IN_D9B <= DATA_IN_D10(0) & DATA_IN_D9(7 downto 1);  -- 1 bit offset
		when "010" => DATA_IN_D9B <= DATA_IN_D10(1 downto 0) & DATA_IN_D9(7 downto 2);  -- 1 bit offset
		when "011" => DATA_IN_D9B <= DATA_IN_D10(2 downto 0) & DATA_IN_D9(7 downto 3);  -- 1 bit offset
		when "100" => DATA_IN_D9B <= DATA_IN_D10(3 downto 0) & DATA_IN_D9(7 downto 4);  -- 1 bit offset
		when "101" => DATA_IN_D9B <= DATA_IN_D10(4 downto 0) & DATA_IN_D9(7 downto 5);  -- 1 bit offset
		when "110" => DATA_IN_D9B <= DATA_IN_D10(5 downto 0) & DATA_IN_D9(7 downto 6);  -- 1 bit offset
		when others => DATA_IN_D9B <= DATA_IN_D10(6 downto 0) & DATA_IN_D9(7);  -- 1 bit offset
	end case;
end process;


--// COUNT ERRORS -----------------------------
DATA_ERR(7 downto 0) <= DR xor DATA_IN_D9B;
DATA_ERR(15 downto 8) <= x"00";  -- extend to 16-bit because we want to reuse PC_16 component

-- compute the number of non-zero bits. PC_16 is too big for 
-- 8-bit processing, but it will be optimized at synthesis (hopefully)
Inst_PC_16: PC_16 PORT MAP(
	A => DATA_ERR,
	O => N_ERR
);


N_BYTES_INC <= N_BYTES + 1;
NBYTES_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			BER_LOCAL <= (others => '0'); 
			BER <= (others => '0'); 
			BER_SAMPLE_CLK <= '0';
		elsif(SAMPLE_CLK_IN_D9 = '1') then
			if(N_BYTES_INC >=  N_BYTES_MAX) then
				-- end of BER computation window. 
				N_BYTES <= (others => '0');
				BER <= BER_LOCAL + (x"0000000" & N_ERR(3 downto 0));
				BER_SAMPLE_CLK <= '1';
				BER_LOCAL <= (others => '0'); 
			else
				N_BYTES <= N_BYTES_INC;
				BER_LOCAL <= BER_LOCAL + (x"0000000" & N_ERR(3 downto 0));
				BER_SAMPLE_CLK <= '0';
			end if;
		else
			BER_SAMPLE_CLK <= '0';
		end if;
	end if;
end process;

-- BER window size
NBYTES_MAX_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		case CONTROL(2 downto 0) is
			when "001" => N_BYTES_MAX <= conv_std_logic_vector(10000,32);
			when "010" => N_BYTES_MAX <= conv_std_logic_vector(100000,32);
			when "011" => N_BYTES_MAX <= conv_std_logic_vector(1000000,32);
			when "100" => N_BYTES_MAX <= conv_std_logic_vector(10000000,32);
			when "101" => N_BYTES_MAX <= conv_std_logic_vector(100000000,32);
			when "110" => N_BYTES_MAX <= conv_std_logic_vector(1000000000,32);
			when others => N_BYTES_MAX <= conv_std_logic_vector(1000,32);
		end case;
	end if;
end process;

--// OUTPUTS ----------------------------------
OUTPUTS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		MF_DETECT <= MF_DETECT_LOCAL;
		MF_DETECT_CONFIRMED <= SOF;
		SYNC_LOCK <= SOF_LOCK_DETECT;
		SAMPLE_CLK_OUT <= SAMPLE_CLK_IN_D9;
		DATA_REPLICA <= DR;
		if(SAMPLE_CLK_IN_D9 = '1') and (DATA_IN_D9B /= DR) then
			BYTE_ERROR <= '1';
		else
			BYTE_ERROR <= '0';
		end if;
	end if;
end process;

end behavioral;
