----------------------------------------------
-- MSS copyright 1999-2009
--	File: SOF_TRACK8
-- Authors: 
--		Alain Zarembowitch / MSS
--		Nayef Ahmar / MSS
-- Inheritance: SOF_TRACK.VHD 5/28/09, COOM-7001 Rev22
-- Edit date: 8/16/09
-- Revision: 1
--
-- Description: Confirmation circuit for the frame synchronization.
-- Input sampling rate is tied to the input BYTE sampling clock.
-- As the DETECT matched filter output is subject to missed detections due to 
-- bit errors, a confirmation circuit is needed. 
-- Creates a reliable periodic start of frame (SOF) signal 
-- even in the event of missed detection at the matched filter, in essence a kind
-- of fly-wheel. 
-- Also generates a DATA_ENABLE flag to outline the data segment of the frame.
-- This DATA_ENABLE can subsequently be used to separate data from the 
-- unique word synchronization overhead.
-- Finally, a lock status goes high upon detection of the first SOF, 
-- and goes low when the confidence level is null. The confidence level
-- is increased for each SOF at the right location and is decreased 
-- when an expected SOF is missing. The confidence level range is 0-3.
-- Key assumptions: unique word is 32-bit long. 
----------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity SOF_TRACK8 is
    port (
		--GLOBAL CLOCKS, RESET
	   CLK : in std_logic;	-- reference clock, synchronous 
		SYNC_RESET: in std_logic;	-- synchronous reset

		--// INPUTS
      DETECT_IN: in std_logic;     
			-- flag indicating training sequence detection by the 32-bit matched
			-- filter. Subject to missed detections and false detections. 
			-- Aligned with SAMPLE_CLK_IN. 
			-- Generated immediately after receiving the last byte of the sync pattern
		PHASE_IN: in std_logic_vector(2 downto 0);
			-- bit to byte alignment error. Correct by delaying the input signal PHASE_OUT bits.
			-- Somewhat unreliable as it is not protected against bit errors.
			-- Read when SAMPLE_CLK_IN = '1' and DETECT = '1'
		INVERSION_IN: in std_logic;
		SAMPLE_CLK_IN: in std_logic;
			-- defines the BYTE period. pulse is 1 CLK period long.

		--// CONTROLS
		FRAME_LENGTH: in std_logic_vector(15 downto 0);
			-- frame length in BITS, includes unique word.
		SUPERFRAME_LENGTH: in std_logic_vector(7 downto 0);
			-- superframe length, expressed as integer number of frames.
			-- The start of superframe is identified by an inverted unique word.
			-- 0 or 1 means no superframe formatting.
			-- A length of 2 is not recommended if phase ambiguity is to be 
			-- resolved for coherent n-PSK demodulators.

		--// OUTPUTS
		SAMPLE_CLK_OUT: out std_logic;
			-- one CLK wide pulse. Aligned with SOF, SOSF, etc.
			-- Latency is 1 CLK after SAMPLE_CLK_IN.
		SOF_OUT: out std_logic;
			-- recovered start of frame. width = 1 CLK wide
			-- Read when SAMPLE_CLK_OUT = '1'
		SOSF_OUT: out std_logic;
			-- start of superframe. pulse width: width = 1 CLK wide, aligned with SOF.
			-- Read when SAMPLE_CLK_OUT = '1'
		SOF_LOCK_DETECT: out std_logic;
			-- indicates solid tracking of the training sequence if CONSTANTLY at 1
			-- indicates that the circuit is trying to acquire the training sequence
			-- if this flag toggles. 
		RESET_REPLICA: out std_logic;
			-- Reset replica at the beginning of the start of frame when the start of sequence is byte aligned.
			-- Used to reset an external byte-wise replica generator such as RAMB.
		PHASE_OUT: out std_logic_vector(2 downto 0);  
			-- number of bit delays to apply to the input data stream so that it is 
			-- aligned with the data replica DR. Confirmed at the first lock.
		DATA_ENABLE: out std_logic
			-- Flag indicating how to separate the data field from 
			-- the synchronization overhead. 
			-- Read when SAMPLE_CLK_OUT = '1'
	);
end entity;
  
architecture BEHAVIOR of SOF_TRACK8 is
-----------------------------------------------------------------
-- COMPONENTS
-----------------------------------------------------------------
-----------------------------------------------------------------
-- SIGNALS
-----------------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates an extended precision version of the net with the same name
-- Suffix _R indicates a reduced precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name
-- Suffix _LOCAL indicates an exact version of the (output signal) net with the same name

signal BIT_COUNT: std_logic_vector(15 downto 0) := x"0000";
	-- bit counter 0 - 8*FRAME_LENGTH
signal BIT_COUNT_PLUS8: std_logic_vector(15 downto 0);
signal FRAME_LENGTH_PLUS8: std_logic_vector(15 downto 0);
signal DETECT_EXPECTED: std_logic;
signal DETECT_EXPECTED_E: std_logic;


signal FRAME_COUNT: std_logic_vector(7 downto 0) := x"00";
signal FRAME_COUNT_INC: std_logic_vector(7 downto 0);
signal CONFIDENCE_LEVEL: std_logic_vector(1 downto 0) := "00";
  	-- 0 to 3
signal SOF_LOCK_DETECT_LOCAL: std_logic := '0';
	-- active low for counter= 00
signal INVERSION_IN_D: std_logic := '0';
signal INVERSION_IN_D2: std_logic := '0';
signal PHASE_OUT_LOCAL: std_logic_vector(2 downto 0);  
-----------------------------------------------------------------
-- IMPLEMENTATION
-----------------------------------------------------------------
begin 

-- when normally expecting a DETECT_IN pulse
DETECT_EXPECTED <= 	'1' when ((BIT_COUNT_PLUS8 >= FRAME_LENGTH) and (BIT_COUNT_PLUS8 < (FRAME_LENGTH + 8)) )else
							'0';
						
-- when normally expecting a DETECT_IN pulse at the next input sample SAMPLE_CLK_IN
DETECT_EXPECTED_E <= 	'1' when ((BIT_COUNT_PLUS8 >= (FRAME_LENGTH - 8)) and (BIT_COUNT_PLUS8 < FRAME_LENGTH ) )else
							'0';

-- Keep track of the bit count within a period of 8 consecutive frames
BIT_COUNT_PLUS8 <= BIT_COUNT + 8;

BIT_COUNT_GEN_001: process(CLK)
begin       
	if rising_edge(CLK) then  
		FRAME_LENGTH_PLUS8 <= FRAME_LENGTH + x"0008";
		
	  if(SYNC_RESET = '1') then
			BIT_COUNT <= FRAME_LENGTH;  -- block DATA_ENABLE for a while at the start until we get a bonefide  DETECT pulse
	  elsif(SAMPLE_CLK_IN = '1') then
			if (DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '0') then
				-- reset at the first raw DETECT_IN pulse when not in lock
				-- start at PHASE_IN (bits remainder after /8 division)
				BIT_COUNT(2 downto 0) <= PHASE_IN;   -- PHASE_IN bits belonging to the next frame alreadin in last rx byte
				BIT_COUNT(15 downto 3) <= (others => '0');  
			elsif (DETECT_EXPECTED = '1') then
				-- we expect a new sync pattern detection here.
				BIT_COUNT(15 downto 4) <= (others => '0');  
				-- start at PHASE_IN (bits remainder after /8 division)
				BIT_COUNT(2 downto 0) <= PHASE_IN;   -- PHASE_IN bits belonging to the next frame alreadin in last rx byte
				BIT_COUNT(15 downto 3) <= (others => '0');  
			else 
				-- received 8 additional bits.
				BIT_COUNT <= BIT_COUNT_PLUS8;
			end if;
	  end if;
	end if;
end process; 

-- Confidence level
CONFIDENCE_LEVEL_GEN_001: process (CLK)
-- Increment confidence level upon detecting SOF at the right time.
-- Decrement confidence level upon detectinig a missing SOF at the expected time.
-- Range is 0 (no confidence) to 3 (maximum confidence).
begin
	if rising_edge(CLK) then 
   	-- special case: first sync pattern detected
	  if(SYNC_RESET = '1') then
 		CONFIDENCE_LEVEL <= "00";         
	  elsif(SAMPLE_CLK_IN = '1') then
			if (DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '0') then
				-- declare lock upon receiving the first sync pattern when being out of lock.
				-- Reason: we don't want to waste a good frame
		 		CONFIDENCE_LEVEL <= "01";         
		 		PHASE_OUT_LOCAL <= PHASE_IN; -- freeze bit offset.
			elsif (DETECT_EXPECTED = '1') then
				-- we expect a new sync pattern detection here.
				if(DETECT_IN = '1') then
					-- if the locally generated SOF matches the SOF detected by the matched filter,
					-- everything is OK, increment the counter. Otherwise, decrement CONFIDENCE_LEVELer.
					-- CONFIDENCE_LEVEL is a measure of confidence as to the SOF detection.
					if(CONFIDENCE_LEVEL < 3) then
						CONFIDENCE_LEVEL <= CONFIDENCE_LEVEL + 1;
		  			end if; 
			 	else
					-- missed detection
					if(CONFIDENCE_LEVEL > 0) then
						CONFIDENCE_LEVEL <= CONFIDENCE_LEVEL - 1;
		  			end if; 
			 	end if;
			end if;              
		end if;
	end if;
end process;        
PHASE_OUT <= PHASE_OUT_LOCAL;

---- Lock is detected when CONFIDENCE_LEVEL > 0
SOF_LOCK_DETECT_LOCAL <= '1' when (CONFIDENCE_LEVEL > 0) else '0';
SOF_LOCK_DETECT <= SOF_LOCK_DETECT_LOCAL;

-- keep track of the frame count within a superframe
FRAME_COUNT_INC <= FRAME_COUNT + 1;

FRAME_COUNT_GEN_001: process(CLK)
begin       
	if rising_edge(CLK) then  
		if(SAMPLE_CLK_IN = '1') then
			if (DETECT_EXPECTED = '1') and (DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '1') then
				-- periodic SOF, reliable SOF lock.
				-- save last two detected phases
				INVERSION_IN_D <= INVERSION_IN;
				INVERSION_IN_D2 <= INVERSION_IN_D;

			  	-- reset FRAME_COUNT upon detecting start of superframe
				if(INVERSION_IN = not INVERSION_IN_D) and (INVERSION_IN_D = INVERSION_IN_D2) then
					-- this unique word is inverted w.r.t. the last two. 
					-- Possibly affected by phase ambiguity. 
					-- Incompatible with SUPERFRAME_LENGTH = 2 when used with 
					-- demodulators which exhibit phase ambiguity.
					-- must be a start of superframe.
					FRAME_COUNT <= (others => '0');
				elsif(INVERSION_IN = '0') and (INVERSION_IN_D = '1') and (INVERSION_IN_D2 = '0') then
					-- this unique word is inverted w.r.t. the last one and
					-- no phase ambiguity is detected.
					-- must be a start of superframe.
					FRAME_COUNT <= x"01";
				end if;
			
			elsif(DETECT_EXPECTED_E = '1')  then
				-- end of frame
				if(FRAME_COUNT_INC = SUPERFRAME_LENGTH) then
					FRAME_COUNT <= (others => '0');
				else
					FRAME_COUNT <= FRAME_COUNT_INC;
				end if;
		  end if;
	  end if;
	end if;
end process; 

-- Flywheel. Generate reconstructed SOF and SOSF, even when there is no matched filter output.
SOF_GEN_001: process(CLK)
begin       
	if rising_edge(CLK) then  
		if(SAMPLE_CLK_IN = '1') then
			if ((DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '0')) then   -- don't wait. use first SOF
				SOF_OUT <= '1';
				if(INVERSION_IN = '1') then
					SOSF_OUT <= '1';
				else
					SOSF_OUT <= '0';
				end if;
			elsif ((DETECT_EXPECTED = '1') and (SOF_LOCK_DETECT_LOCAL = '1')) then  -- flywheel
				SOF_OUT <= '1';
				if(SUPERFRAME_LENGTH > 1) and (FRAME_COUNT = 0) then
					-- Start of Superframe. 
					-- Disabled whtn SUPERFRAME_LENGTH = 0 or 1.
					-- Aligned with SOF.
					SOSF_OUT <= '1';
				else
					SOSF_OUT <= '0';
				end if;
			else
				SOF_OUT <= '0';
				SOSF_OUT <= '0';
			end if;
		else
			SOF_OUT <= '0';
			SOSF_OUT <= '0';
		end if;
	end if;
end process;


-- Delay SAMPLE_CLK_IN
RECLOCK_002: process(CLK)
begin
	if rising_edge(CLK) then
		SAMPLE_CLK_OUT <= SAMPLE_CLK_IN;
	end if;
end process;

-- Reset replica at the beginning of the start of frame when the start of sequence is byte aligned.
-- Used to reset an external byte-wise replica generator such as RAMB.
RESET_REPLICA_GEN_001: process (CLK)
begin
	if rising_edge(CLK) then 
	  if(SAMPLE_CLK_IN = '1') then
--			if (DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '0') and (PHASE_IN = 0) then  -- note: az 8-14-09 don't wait until phase_in = 0. implemented bit delay.
			if (DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '0') then
				-- special case: first sync pattern detected
		 		RESET_REPLICA <= '1';
			elsif (DETECT_EXPECTED = '1') and (DETECT_IN = '1') and (SOF_LOCK_DETECT_LOCAL = '1') and (PHASE_IN = PHASE_OUT_LOCAL) then
				-- periodic confirmed SOF with byte-aligned data.
		 		RESET_REPLICA <= '1';
		 	else
		 		RESET_REPLICA <= '0';
			end if;              
		end if;
	end if;
end process; 

DATA_ENABLE <= '1' when (BIT_COUNT < (FRAME_LENGTH - 32)) else '0';
   
end  BEHAVIOR; 
