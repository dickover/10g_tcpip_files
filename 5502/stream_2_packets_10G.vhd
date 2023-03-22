-------------------------------------------------------------
-- MSS copyright 2018
-- Filename:  STREAM_2_PACKETS_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0
-- Date last modified: 3/11/18
-- Inheritance: 	COM-5402 STREAM_2_PACKETS.VHD 8/18/11 rev1
--
-- description: Send a stream in the form of packets.
-- 10Gbits/s speed.
-- Fully portable VHDL.
-- The input stream is segmented into data packets. The packet transmission
-- is triggered when one of two events occur:
-- (a) full packet: the number of bytes waiting for transmission is greater or equal than 
-- the maximum packet size (see constant MAX_PACKET_SIZE within), or
-- (b) no-new-input timeout: there are a few bytes waiting for transmission but no new input 
-- bytes were received in the last 200us (or adjust constant TX_IDLE_TIMEOUT within).
-- 
-- If the follow-on transmission component is unable to immediately send the packet 
-- (for example if UDP_TX is missing routing information) it will return a negative acknowledgement (NAK). 
-- This component is responsible for triggering a re-transmission at a later time.
-- The wait before the next retransmission attempt is defined by the constant TX_RETRY_TIMEOUT within.
--
-- This component can interface seemlessly with PRBS11P.vhd at the input for generating
-- a high-speed pseudo-random test pattern generation (perfect for throughput and BER 
-- measurements). 
--
-- This component can interface seemlessly with USB_TX.vhd at the output to encapsulate
-- the output packets within UDP frames for network transmission. 

---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity STREAM_2_PACKETS_10G is
	generic (
		MAX_PACKET_SIZE: integer := 256;    
			-- in number of 64-bit words.  
		TX_IDLE_TIMEOUT: integer range 0 to 50 := 50;	
			-- inactive input timeout, expressed in 4us units. -- 50*4us = 200us 
		ADDR_WIDTH: integer := 8;
			-- allocates buffer space: 72 bits * 2^ADDR_WIDTH words
			-- CAREFUL: if the buffer allocation is too small, the maximum frame size may not be reached 
			-- and only the (slow) timer will trigger a packet transmission
		SIMULATION: std_logic := '0'
	);
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;		-- synchronous clock
			-- Must be a global clocks. No BUFG instantiation within this component.
		TICK_4US: in std_logic;

		--// INPUT STREAM
		STREAM_DATA: in std_logic_vector(63 downto 0);
		STREAM_DATA_VALID: in std_logic_vector(7 downto 0);
		  -- valid must be either 0x00 or 0xFF. No partial word allowed here.
		STREAM_CTS: out std_logic; 	-- flow control
		
		--// OUTPUT PACKETS
		-- For example, interfaces with UDP_TX
		DATA_OUT: out std_logic_vector(63 downto 0);
		DATA_VALID_OUT: out std_logic_vector(7 downto 0);
		SOF_OUT: out std_logic;	-- also resets internal state machine
		EOF_OUT: out std_logic;
		CTS_IN: in std_logic;  -- Clear To Send = transmit flow control. 
		ACK_IN: in std_logic;
			-- previous packet is accepted for transmission. 
			-- ACK/NAK can arrive anytime after SOF_OUT, even before the packet is fully transferred 
		NAK_IN: in std_logic;
			-- could not send the packet (for example, no routing information available for the selected 
			-- LAN destination IP). Try later.
	
		--// TEST POINTS 
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of STREAM_2_PACKETS_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
COMPONENT BRAM_DP2
    GENERIC(
        DATA_WIDTHA: integer;
        ADDR_WIDTHA: integer;
        DATA_WIDTHB: integer;
        ADDR_WIDTHB: integer
    );
    PORT(
        CSA : IN std_logic;
        CLKA   : in  std_logic;
        WEA    : in  std_logic;
        OEA : IN std_logic;
        ADDRA  : in  std_logic_vector(ADDR_WIDTHA-1 downto 0);
        DIA   : in  std_logic_vector(DATA_WIDTHA-1 downto 0);
        DOA  : out std_logic_vector(DATA_WIDTHA-1 downto 0);
        CSB : IN std_logic;
        CLKB   : in  std_logic;
        WEB    : in  std_logic;
        OEB : IN std_logic;
        ADDRB  : in  std_logic_vector(ADDR_WIDTHB-1 downto 0);
        DIB   : in  std_logic_vector(DATA_WIDTHB-1 downto 0);
        DOB  : out std_logic_vector(DATA_WIDTHB-1 downto 0)
        );
END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates a one CLK early version of the net with the same name
-- Suffix _X indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

--//-- COMPONENT CONFIGURATION (FIXED AT PRE-SYNTHESIS) ---------------
constant TX_RETRY_TIMEOUT: integer range 0 to 1023 := 500;	-- expressed in 4us units. -- 500*4us = 2ms 
constant TX_RETRY_TIMEOUT_SIM: integer range 0 to 1023 := 10;	-- shorter timer during simulations
	-- wait time after a NAK before trying a retransmission, expressed in 4us units. -- 500*4us = 2ms 
	-- IMPORTANT: the timeout starts at the SOF. It therefore includes the output data transfer duration  (MAX_PACKET_SIZE/fCLK).
	-- Always make sure the timeout is always greater than the output data transfer duration.


--//-- INPUT IDLE DETECTION ---------------------------
signal TX_IDLE_TIMER: integer range 0 to 50 := TX_IDLE_TIMEOUT;
signal TX_IDLE: std_logic := '0';

--//-- ELASTIC BUFFER ---------------------------
signal WPTR: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal RPTR: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal RPTR_INC: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal RPTR_ACKED: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal RPTR_MAX: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal BUF_SIZE: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal BUF_SIZE_ACKED: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WEA: std_logic := '0';
signal DIA: std_logic_vector(71 downto 0) := (others => '0');
signal DOB: std_logic_vector(71 downto 0) := (others => '0');

--//-- READ POINTER AND STATE MACHINE ----------------------------
signal STATE: integer range 0 to 3 := 0;
signal WORD_VALID_E: std_logic := '0';
signal WORD_VALID: std_logic := '0';
signal SOF_E: std_logic := '0';
signal SOF: std_logic := '0';
signal EOF_E: std_logic := '0';
signal EOF: std_logic := '0';
signal TX_RETRY_TIMER: integer range 0 to 1023 := 0;
signal TX_RETRY_TIMEOUT_B: integer range 0 to 1023 := 0;	

signal ACK_IN_FLAG: std_logic := '0';
signal NAK_IN_FLAG: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- during simulations, reduce long timer values 
TX_RETRY_TIMEOUT_B <= TX_RETRY_TIMEOUT when (SIMULATION = '0') else TX_RETRY_TIMEOUT_SIM;

--//-- INPUT IDLE DETECTION ---------------------------
-- Raise a flag when no new Tx data is received in the last 200 us. 
-- Keep track for each stream.
TX_IDLE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	    if(SYNC_RESET = '1') then
    		TX_IDLE_TIMER <= TX_IDLE_TIMEOUT;
		elsif(WEA = '1') then
			-- new transmit data, reset counter
			--TX_IDLE_TIMER <= 1;	-- TEST TEST TEST FOR SIMULATION PURPOSES ONLY
			TX_IDLE_TIMER <= TX_IDLE_TIMEOUT;	
		elsif(TICK_4US = '1') and (TX_IDLE_TIMER /= 0) then
			-- otherwise, decrement until counter reaches 0 (TX_IDLE condition)
			TX_IDLE_TIMER <= TX_IDLE_TIMER -1;
		end if;
	end if;
end process;

TX_IDLE <= '1' when (TX_IDLE_TIMER = 0) and (WEA = '0') else '0';

--//-- ELASTIC BUFFER ---------------------------
WEA <= '1' when (unsigned(STREAM_DATA_VALID) /= 0) else '0';

WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
        if(SYNC_RESET = '1') then
    		WPTR <= (others => '0');
		elsif(WEA = '1') then
			WPTR <= WPTR + 1;
		end if;
	end if;
end process;

DIA(63 downto 0) <= STREAM_DATA;
DIA(71 downto 64) <= STREAM_DATA_VALID;

-- Buffer size is controlled by generic ADDR_WIDTH
BRAM_DP2_001: BRAM_DP2 
GENERIC MAP(
    DATA_WIDTHA => 72,		
    ADDR_WIDTHA => ADDR_WIDTH,
    DATA_WIDTHB => 72,		 
    ADDR_WIDTHB => ADDR_WIDTH
)
PORT MAP(
    CSA => '1',
    CLKA => CLK,
    WEA => WEA,      -- Port A Write Enable Input
    ADDRA => std_logic_vector(WPTR),  
    DIA => DIA,      
    OEA => '0',
    DOA => open,
    CSB => '1',
    CLKB => CLK,
    WEB => '0',
    ADDRB => std_logic_vector(RPTR),  
    DIB => (others => '0'),      
    OEB => '1',
    DOB => DOB      
);

BUF_SIZE <= WPTR + not (RPTR);
    -- occupied space in the buffer (i.e. data waiting for transmission)
BUF_SIZE_ACKED <= WPTR + not (RPTR_ACKED);
-- input flow control (buffer 3/4 full)
STREAM_CTS <= '0' when (BUF_SIZE_ACKED(ADDR_WIDTH-1 downto ADDR_WIDTH-2) = "11") else '1';

--//-- READ POINTER AND STATE MACHINE ----------------------------
-- manage read pointer
RPTR_INC <= RPTR + 1;
RPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		-- 1 CLK delay in reading data from block RAM
		WORD_VALID <= WORD_VALID_E;
		SOF <= SOF_E;
		EOF <= EOF_E;
		
		if(SYNC_RESET = '1') then
            STATE <= 0;
            RPTR <= (others => '1');
            WORD_VALID_E <= '0';
            SOF_E <= '0';
            EOF_E <= '0';
            WORD_VALID <= '0';
            SOF <= '0';
            EOF <= '0';
		elsif(STATE = 0) and (CTS_IN = '1') and (BUF_SIZE /= 0) then
			-- idle state, destination ready for tx and data is waiting in input elastic buffer
			if(BUF_SIZE >= MAX_PACKET_SIZE) then
				-- tx trigger 2: got enough data in buffer to fill a maximum size packet
				STATE <= 1;
				RPTR_MAX <= RPTR_ACKED + MAX_PACKET_SIZE;
				RPTR <= RPTR + 1;	-- start transferring the first word
				WORD_VALID_E <= '1';
				SOF_E <= '1';
				if(MAX_PACKET_SIZE = 1) then	
					-- special case: 1 word packet. EOF = SOF
					EOF_E <= '1';
				end if;
			elsif(TX_IDLE = '1') then
				-- tx trigger 1: timeout waiting for fresh input bytes
				STATE <= 1;
				RPTR_MAX <= WPTR - 1;
				RPTR <= RPTR + 1;	-- start transferring the first word
				WORD_VALID_E <= '1';
				SOF_E <= '1';
				if(BUF_SIZE = 1) then	
					-- special case: 1 byte packet. EOF = SOF
					EOF_E <= '1';
				end if;
			end if;
		elsif(STATE = 1) then
			SOF_E <= '0';
			if (RPTR = RPTR_MAX) then
				-- end of packet transmission
				WORD_VALID_E <= '0';
				EOF_E <= '0';
				STATE <= 2;				-- data transfer complete. wait for ACK or NAK
				TX_RETRY_TIMER <= TX_RETRY_TIMEOUT_B;	
					-- this timer has two objectives: 
					-- (a) make sure the state machine does not get stuck at state 2 if for some unexplained reason
					-- no ACK/NAK is received, and 
					-- (b) wait a bit before retransmitting a NAK'ed packet.
			else
				-- not yet done transferring bytes
				if(CTS_IN = '1') then
					RPTR <= RPTR + 1;	-- continue transferring bytes
					WORD_VALID_E <= '1';
					if(RPTR_INC = RPTR_MAX) then
						EOF_E <= '1';
					end if;
				else
					WORD_VALID_E <= '0';
				end if;
			end if;
		elsif(STATE = 2) then
			-- data transfer complete. waiting for ACK/NAK
			if(ACK_IN = '1') or (ACK_IN_FLAG = '1') then
				-- All done. 
				if (CTS_IN = '1') and (BUF_SIZE >= MAX_PACKET_SIZE) then
				    -- don't waste a clock. skip going to STATE=0
				    -- tx trigger 2: got enough data in buffer to fill a maximum size packet
                    STATE <= 1;
                    RPTR_MAX <= RPTR + MAX_PACKET_SIZE;
                    RPTR <= RPTR + 1;    -- start transferring the first word
                    WORD_VALID_E <= '1';
                    SOF_E <= '1';
                    if(MAX_PACKET_SIZE = 1) then    
                        -- special case: 1 word packet. EOF = SOF
                        EOF_E <= '1';
                    end if;
                else
                    -- wait for the next trigger condition
				    STATE <= 0;				-- back to idle
				end if;
			elsif(NAK_IN = '1') or (NAK_IN_FLAG = '1') then
				-- no transfer. try again later 
				STATE <= 3;				-- wait a bit, then re-try
				RPTR <= RPTR_ACKED; 	-- rewind read pointer
			elsif(TX_RETRY_TIMER = 0) then
				-- timer expired without receiving an ACK/NAK (abnormal condition). go back to idle
				STATE <= 0;
				RPTR <= RPTR_ACKED; 	-- rewind read pointer
			elsif(TICK_4US = '1') then
				TX_RETRY_TIMER <= TX_RETRY_TIMER - 1;
			end if;
		elsif(STATE = 3) then
			-- wait a bit then retry sending
			if(TX_RETRY_TIMER = 0) then
				-- waited long enough. try retransmitting.
				STATE <= 0;
			elsif(TICK_4US = '1') then
				TX_RETRY_TIMER <= TX_RETRY_TIMER - 1;
			end if;
		end if;
	end if;
end process;

-- split complex state machine into smaller simpler processes for better timing
RPTR_GEN_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
            RPTR_ACKED <= (others => '1');
		elsif(STATE = 2) then
			-- data transfer complete. waiting for ACK/NAK
			if(ACK_IN = '1') or (ACK_IN_FLAG = '1') then
				-- All done. 
				RPTR_ACKED <= RPTR;	-- new acknowledged read pointer
			end if;
		end if;
	end if;
end process;

-- ACK/NAK received flags
ACK_NAK_FLAGS_001: process(CLK)
begin
	if rising_edge(CLK) then
        if(SYNC_RESET = '1') then
            ACK_IN_FLAG <= '0';
            NAK_IN_FLAG <= '0';
        else
            if(STATE = 0) or ((STATE = 2) and (ACK_IN = '1')) then
                ACK_IN_FLAG <= '0';
            elsif(ACK_IN = '1') then
                ACK_IN_FLAG <= '1';
            end if;
            if(STATE = 0) then
                NAK_IN_FLAG <= '0';
            elsif(NAK_IN = '1') then
                NAK_IN_FLAG <= '1';
            end if;
        end if;
    end if;
end process;

--//-- OUTPUT --------------------------------
DATA_OUT <= DOB(63 downto 0);
DATA_VALID_OUT <= DOB(71 downto 64) when (WORD_VALID = '1')  else x"00";
SOF_OUT <= SOF;
EOF_OUT <= EOF;

--//-- TEST POINTS ----------------------------
TP(1) <= '1' when (STATE = 0) else '0';
TP(2) <= '1' when (STATE = 1) else '0';
TP(3) <= '1' when (STATE = 2) else '0';
TP(4) <= '1' when (STATE = 3) else '0';
TP(5) <= RPTR(0);
TP(6) <= NAK_IN_FLAG;
TP(7) <= SOF;
TP(8) <= EOF;
TP(9) <= WORD_VALID;
TP(10) <= ACK_IN_FLAG;
end Behavioral;
