-------------------------------------------------------------
-- MSS copyright 2018
-- Filename:  STREAM_2_PACKETS2.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0
-- Date last modified: 3/11/18
-- Inheritance: 	STREAM_2_PACKETS2.VHD rev4 7/14/17
--
-- description: Encapsulate input data into data packets (for example for UDP transmission).
-- The input stream is segmented into data packets. 
-- The packet transmission is triggered by either a timeout (TIMEOUT = maximum time between successive packets)
-- or when the number of bytes waiting for transmission is greater or equal than MAX_PACKET_SIZE bytes.
-- A 16-byte preamble field is inserted prior to the data field, consisting of 
-- 2 bytes for payload data length, 14 bytes for PREAMBLE_IN.
-- 
-- Note: no packet is sent if there is no data available when the timer expires.
-- 
-- If the follow-on transmission component is unable to immediately send the packet 
-- (for example if UDP_TX is missing routing information) it will return a negative acknowledgement (NAK). 
-- This component is responsible for triggering a re-transmission at a later time.
-- The wait before the next retransmission attempt is defined by the constant TX_RETRY_TIMEOUT within.
--
-- This component can interface seemlessly with UDP_TX.vhd at the output to encapsulate
-- the output packets within UDP frames for network transmission.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity STREAM_2_PACKETS2 is
	generic (
		NBUFS: integer := 1;
			-- number of 16Kb dual-port RAM buffers instantiated within.
			-- Valid values: 1,2,4,8
		TIMEOUT_ENABLE: std_logic := '1';
		TIMEOUT: integer range 1 to 262144:= 125000;
			-- maximum time between successive packets, expressed in 4 us units
		MAX_PACKET_SIZE: std_logic_vector(13 downto 0) := "00" & x"400";	-- in bytes. 1024 bytes
			-- maximum data field size, in bytes. Does not include the preamble.
		SIMULATION: std_logic := '0'
	);
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;		-- synchronous clock
			-- Must be a global clocks. No BUFG instantiation within this component.
		TICK_4us: in std_logic;
			-- 1 CLK wide pulse

		--// INPUT STREAM
		DATA_IN: in std_logic_vector(63 downto 0);	-- input data
		DATA_VALID_IN: in std_logic_vector(7 downto 0);	-- 1 clk wide pulse for each input sample
		CTS_OUT: out std_logic; 	
			-- flow control. Typically 1 as component is fast enough to process input samples
			-- in real time.

		--// PREAMBLE
		PACKET_TX_PULSE: out std_logic;
			-- 1 CLK pulse when the decision to send a frame is made.
		PREAMBLE_IN: in std_logic_vector(111 downto 0);	
			-- user-defined preamble. for example timestamp.
			-- read upon making the decision to send a packet (PACKET_TX_PULSE = '1').
			-- Note: a 16-bit data payload length field is inserted in the first two bytes of the output frame,
			-- before this preamble. 
		
		--// OUTPUT PACKETS
		-- For example, interfaces with UDP_TX
		DATA_OUT: out std_logic_vector(63 downto 0);
		DATA_VALID_OUT: out std_logic_vector(7 downto 0);
		SOF_OUT: out std_logic;	-- also resets internal state machine
		EOF_OUT: out std_logic;
		RTS_OUT: out std_logic;	-- indicate that we are ready to send a complete frame. Stays high until acknowledged by CTS_IN
		CTS_IN: in std_logic;  -- destination acknowledges that it's ok to send the complete frame. 
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

architecture Behavioral of STREAM_2_PACKETS2 is
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
		CLKA   : in  std_logic;
		CSA: in std_logic;	
		WEA    : in  std_logic;	
		OEA : in std_logic;	
		ADDRA  : in  std_logic_vector(ADDR_WIDTHA-1 downto 0);
		DIA   : in  std_logic_vector(DATA_WIDTHA-1 downto 0);
		DOA  : out std_logic_vector(DATA_WIDTHA-1 downto 0);
		CLKB   : in  std_logic;
		CSB: in std_logic;	
		WEB    : in  std_logic;	
		OEB : in std_logic;	
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
constant TX_RETRY_TIMEOUT: integer range 0 to 1023 := 500;	
constant TX_RETRY_TIMEOUT_SIM: integer range 0 to 1023 := 10;	-- shorter timer during simulations
	-- wait time after a NAK before trying a retransmission, expressed in 4us units. -- 500*4us = 2ms 
	-- IMPORTANT: the timeout starts at the SOF. It therefore includes the output data transfer duration  (MAX_PACKET_SIZE/fCLK).
	-- Always make sure the timeout is always greater than the output data transfer duration.

signal DATA_VALID_IN_D: std_logic := '0';
signal DATA_IN_D: std_logic_vector(7 downto 0) := (others => '0');
signal PREAMBLE_IN_SHIFT: std_logic_vector(127 downto 0):= (others => '0');

--//-- INPUT ELASTIC BUFFER ---------------------------
signal STREAM_DATAx: std_logic_vector(8 downto 0) := (others => '0');
signal PTR_MASK: std_logic_vector(13 downto 0) := (others => '1');
signal WPTR: std_logic_vector(13 downto 0) := (others => '0');
signal RPTR: std_logic_vector(13 downto 0) := (others => '1');
signal RPTR_INC: std_logic_vector(13 downto 0) := (others => '0');
signal RPTR_D: std_logic_vector(13 downto 0) := (others => '1');
signal RPTR_ACKED: std_logic_vector(13 downto 0) := (others => '1');
signal BUF_SIZE: std_logic_vector(13 downto 0) := (others => '0');
signal DATA_FIELD_SIZE: std_logic_vector(13 downto 0) := (others => '0');
signal WEA: std_logic_vector((NBUFS-1) downto 0) := (others => '0');
signal WPTR_MEMINDEX: std_logic_vector(2 downto 0) := (others => '0');
signal RPTR_MEMINDEX: std_logic_vector(2 downto 0) := (others => '0');
signal RPTR_MEMINDEX_D: std_logic_vector(2 downto 0) := (others => '0');
type DOBtype is array(integer range 0 to (NBUFS-1)) of std_logic_vector(8 downto 0);
signal DOB: DOBtype := (others => (others => '0'));

--//-- TIMEOUT ----------------------------
signal TIMER: integer range 0 to 262144 := 0;

--//-- READ POINTER AND STATE MACHINE ----------------------------
signal STATE: integer range 0 to 5 := 0;
signal STATE_D: integer range 0 to 5 := 0;
signal PREAMBLE_DATA: std_logic_vector(7 downto 0) := (others => '0');
signal PAYLOAD_DATA: std_logic_vector(7 downto 0) := (others => '0');
signal PREAMBLE_RPTR: integer range 0 to 16:= 16;
signal RPTR_MAX: std_logic_vector(13 downto 0) := (others => '0');
signal DATA_VALID_E: std_logic := '0';
signal DATA_VALID: std_logic := '0';
signal DATA_VALID_D: std_logic := '0';
signal SOF_E: std_logic := '0';
signal SOF: std_logic := '0';
signal EOF_E: std_logic := '0';
signal EOF: std_logic := '0';
signal TX_RETRY_TIMER: integer range 0 to 1023 := 0;
signal TX_RETRY_TIMEOUT_B: integer range 0 to 1023 := 0;	

signal ACK_IN_FLAG: std_logic := '0';
signal NAK_IN_FLAG: std_logic := '0';
signal RTS_OUT_local: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- during simulations, reduce long timer values 
TX_RETRY_TIMEOUT_B <= TX_RETRY_TIMEOUT when (SIMULATION = '0') else TX_RETRY_TIMEOUT_SIM;

INPUT_001: process(CLK)
begin
	if rising_edge(CLK) then
		DATA_VALID_IN_D <= DATA_VALID_IN;
		DATA_IN_D <= DATA_IN;
	end if;
end process;

--//-- INPUT ELASTIC BUFFER ---------------------------
WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WPTR <= (others => '0');
		elsif(DATA_VALID_IN_D = '1') then
			-- data sample
			WPTR <= (WPTR + 1) and PTR_MASK;
		end if;
	end if;
end process;


-- Mask upper address bits, depending on the memory depth (1,2,4, or 8 RAMblocks)
WPTR_MEMINDEX <= WPTR(13 downto 11) when (NBUFS = 8) else
				"0" & WPTR(12 downto 11) when (NBUFS = 4) else
				"00" & WPTR(11 downto 11) when (NBUFS = 2) else
				"000"; -- when  (NBUFS = 1) 

PTR_MASK <= "11111111111111" when (NBUFS = 8) else
				"01111111111111" when (NBUFS = 4) else
				"00111111111111" when (NBUFS = 2) else
				"00011111111111"; -- when  (NBUFS = 1) 


-- select which RAMBlock to write to.
WEA_GEN_001: process(WPTR_MEMINDEX, DATA_VALID_IN_D)
begin
	for J in 0 to (NBUFS -1) loop
		if(WPTR_MEMINDEX = J) then	-- range 0 through 7
			WEA(J) <= DATA_VALID_IN_D;
		else
			WEA(J) <= '0';
		end if;
	end loop;
end process;

-- 1,2,4, or 8 RAM blocks.
RAMB_16_S9_S9_Y: for J in 0 to (NBUFS-1) generate
	STREAM_DATAx <= "0" & DATA_IN_D;
	
	-- 18Kbit buffer(s) 
	RAMB16_S18_S9_001: BRAM_DP2 
	GENERIC MAP(
		DATA_WIDTHA => 9,		
		ADDR_WIDTHA => 11,
		DATA_WIDTHB => 9,		 
		ADDR_WIDTHB => 11
	)
	PORT MAP(
		CSA => '1',
		CLKA => CLK,
		WEA => WEA(J),      -- Port A Write Enable Input
		ADDRA => WPTR(10 downto 0),	-- 11-bit address
		DIA => STREAM_DATAx,
		OEA => '0',
		DOA => open,
		CSB => '1',
		CLKB => CLK,
		WEB => '0',
		ADDRB => RPTR(10 downto 0),	-- 11-bit address
		DIB => "000000000",
		OEB => '1',
		DOB => DOB(J)
	);
end generate;

-- Mask upper address bits, depending on the memory depth (1,2,4, or 8 RAMblocks)
RPTR_MEMINDEX <= RPTR(13 downto 11) when (NBUFS = 8) else
				"0" & RPTR(12 downto 11) when (NBUFS = 4) else
				"00" & RPTR(11 downto 11) when (NBUFS = 2) else
				"000"; -- when  (NBUFS = 1) 

BUF_SIZE <= (WPTR + not (RPTR_ACKED)) and PTR_MASK;
	-- occupied space in the buffer (i.e. data waiting for transmission). Expressed in Bytes.

-- input flow control
CTS_OUT <= '1' when (not BUF_SIZE(13 downto 7) /=  0) and (NBUFS = 8) else
					'1' when (not BUF_SIZE(12 downto 7) /=  0) and (NBUFS = 4) else
					'1' when (not BUF_SIZE(11 downto 7) /=  0) and (NBUFS = 2) else
					'1' when (not BUF_SIZE(10 downto 7) /=  0) and (NBUFS = 1) else
					'0';

	-- allow more tx data in if there is room for at least 128 bytes

--//-- TIMEOUT ----------------------------
TIMER_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			-- re-arm timer
			TIMER <= TIMEOUT-1;
		elsif(STATE = 1) then
		  -- Decision was made to send a packet. Rearm timer
		  TIMER <= TIMEOUT-1;
		elsif (TICK_4us = '1') then
			if(TIMER = 0) then
				-- re-arm timer
				TIMER <= TIMEOUT-1;
			else
				TIMER <= TIMER - 1;
			end if;
		end if;
	end if;
end process;

--//-- READ POINTER AND STATE MACHINE ----------------------------
-- manage read pointer
RPTR_INC <= RPTR + 1;

RPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		RPTR_MEMINDEX_D <= RPTR_MEMINDEX;

		if(SYNC_RESET = '1') then
			STATE <= 0;
			RPTR <= PTR_MASK;
			RPTR_D <= PTR_MASK;
			RPTR_ACKED <= PTR_MASK;
			DATA_VALID_E <= '0';
			SOF_E <= '0';
			EOF_E <= '0';
			DATA_VALID <= '0';
			SOF <= '0';
			EOF <= '0';
			PREAMBLE_RPTR <= 16;
			RTS_OUT_local <= '0';
		else
			-- 1 CLK delay in reading data from block RAM
			RPTR_D <= RPTR;	
			DATA_VALID <= DATA_VALID_E;
			SOF <= SOF_E;
			EOF <= EOF_E;
				-- reset start of sequence after 2^16 frames
			
			if(STATE = 0) and (BUF_SIZE /= 0) and (RTS_OUT_local = '0') then
			    -- transmit decision
				-- idle state, data is waiting in input elastic buffer. Trigger next transmit frame
				if(BUF_SIZE >= MAX_PACKET_SIZE)  then
					-- tx trigger: got enough data in buffer to fill a maximum size packet 
					RTS_OUT_local <= '1';    -- signal outside that a frame is ready to be send. Must be acknowledged with CTS_IN
					DATA_FIELD_SIZE <= MAX_PACKET_SIZE;    -- freeze size 
					STATE <= 1;    -- await CTS_IN
			     elsif((TICK_4us = '1') and (TIMER = 0) and (TIMEOUT_ENABLE = '1')) then
                        -- timeout waiting for more data and at least one byte of payload data waiting for transmission.
					RTS_OUT_local <= '1';    -- signal outside that a frame is ready to be send. Must be acknowledged with CTS_IN
					DATA_FIELD_SIZE <= BUF_SIZE; -- freeze size
					STATE <= 1;    -- await CTS_IN
                 end if;
  			elsif(STATE = 1) and (CTS_IN = '1') then
  			   -- start frame transmission
  			   RTS_OUT_local <= '0';
			   PREAMBLE_RPTR <= 0;	-- preamble data in 2 CLKs, just like reading the DPRAM
               DATA_VALID_E <= '1';
               SOF_E <= '1';
               STATE <= 2;
			elsif(STATE = 2)  then
				-- sending preamble
				SOF_E <= '0';
				if(CTS_IN = '1') then
					DATA_VALID_E <= '1';
                    PREAMBLE_RPTR <= PREAMBLE_RPTR + 1; 
                    if(PREAMBLE_RPTR >= 15) then
                        -- end of preamble
                        STATE <= 3;
                        -- start sending payload data
                        RPTR_MAX <= (RPTR_ACKED + DATA_FIELD_SIZE) and PTR_MASK;
                        RPTR <= RPTR_INC and PTR_MASK;	-- start transferring the first byte
                        if(DATA_FIELD_SIZE = 1) then	
                            -- special case: 1 byte packet. EOF = SOF
                            EOF_E <= '1';
                        end if;
                    end if;
                 else
					DATA_VALID_E <= '0';
                 end if;
			elsif(STATE = 3)  then
				if ((RPTR and PTR_MASK) = (RPTR_MAX and PTR_MASK)) then
					-- end of packet transmission
					DATA_VALID_E <= '0';
					EOF_E <= '0';
					STATE <= 4;				-- data transfer complete. wait for ACK or NAK
					TX_RETRY_TIMER <= TX_RETRY_TIMEOUT_B;	
						-- this timer has two objectives: 
						-- (a) make sure the state machine does not get stuck at state 4 if for some unexplained reason
						-- no ACK/NAK is received, and 
						-- (b) wait a bit before retransmitting a NAK'ed packet.
				elsif (CTS_IN = '1') then
					-- not yet done transferring bytes
                    RPTR <= RPTR_INC and PTR_MASK;	-- continue transferring bytes
                    DATA_VALID_E <= '1';
                    if((RPTR_INC and PTR_MASK) = (RPTR_MAX and PTR_MASK)) then
                        EOF_E <= '1';
                    end if;
                else
                    DATA_VALID_E <= '0';
    			end if;
			elsif(STATE = 4) then
				-- data transfer complete. waiting for ACK/NAK
				if(ACK_IN = '1') or (ACK_IN_FLAG = '1') then
					-- All done. 
					STATE <= 0;				-- back to idle
					RPTR_ACKED <= RPTR and PTR_MASK;	-- new acknowledged read pointer
				elsif(NAK_IN = '1') or (NAK_IN_FLAG = '1') then
					-- no transfer. try again later 
					STATE <= 5;				-- wait a bit, then re-try
					RPTR <= RPTR_ACKED and PTR_MASK; 	-- rewind read pointer
				elsif(TX_RETRY_TIMER = 0) then
					-- timer expired without receiving an ACK/NAK (abnormal condition). go back to idle
					STATE <= 0;
					RPTR <= RPTR_ACKED and PTR_MASK; 	-- rewind read pointer
				elsif(TICK_4us = '1') then
					TX_RETRY_TIMER <= TX_RETRY_TIMER - 1;
				end if;
			elsif(STATE = 5) then
				-- wait a bit then retry sending
				if(TX_RETRY_TIMER = 0) then
					-- waited long enough. try retransmitting.
					STATE <= 0;
				elsif(TICK_4us = '1') then
					TX_RETRY_TIMER <= TX_RETRY_TIMER - 1;
				end if;
			else 
			 
			end if;
		end if;
	end if;
end process;

RTS_OUT <= RTS_OUT_local;
PACKET_TX_PULSE <= SOF_E;
	-- 1 CLK pulse when the decision to send a frame is made.

-- latch in the preamble when the decision is taken to send another packet
-- preamble data
PREAMBLE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		STATE_D <= STATE;

		if(SOF_E = '1') then
			PREAMBLE_IN_SHIFT <= "00" & DATA_FIELD_SIZE & PREAMBLE_IN;
		elsif(PREAMBLE_RPTR < 16) then
		    PREAMBLE_IN_SHIFT(127 downto 8) <= PREAMBLE_IN_SHIFT(119 downto 0);
		end if;
	end if;
end process;
PREAMBLE_DATA <= PREAMBLE_IN_SHIFT(127 downto 120);	

-- payload data
PAYLOAD_DATA_GEN: process(RPTR_MEMINDEX_D, DOB)
variable data: std_logic_vector(7 downto 0);
begin
	for I in 0 to (NBUFS -1) loop
		if(I = RPTR_MEMINDEX_D) then
			data := DOB(I)(7 downto 0);
		end if;
	end loop;
	PAYLOAD_DATA <= data;
end process;

-- ACK/NAK received flags
ACK_NAK_FLAGS_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			ACK_IN_FLAG <= '0';
			NAK_IN_FLAG <= '0';
		else
			if(STATE = 0) then
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
DATA_OUT <= PREAMBLE_DATA when (STATE_D = 2) else PAYLOAD_DATA;
DATA_VALID_OUT <= DATA_VALID;
SOF_OUT <= SOF;
EOF_OUT <= EOF;

--//-- TEST POINTS ----------------------------
TP(1) <= WPTR(0);
TP(2) <= RPTR(0);
TP(3) <= CTS_IN;
TP(4) <= '1' when (STATE = 0) else '0';
TP(5) <= '1' when (STATE = 1) else '0';
TP(6) <=  '1' when (BUF_SIZE >= MAX_PACKET_SIZE)  else '0';
--TP(7) <= NAK_IN_FLAG;
--TP(8) <= SOF;
--TP(9) <= EOF;
--TP(9) <= DATA_VALID;
--TP(10) <= ACK_IN_FLAG;
end Behavioral;
