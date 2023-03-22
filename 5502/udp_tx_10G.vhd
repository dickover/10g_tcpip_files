-------------------------------------------------------------
-- MSS copyright 2018
-- Filename:  UDP_TX_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0
--	Date last modified: 8/21/18
-- Inheritance: 	COM5402 UDP_TX.VHD 5/10/17 rev7
--
-- description:  
-- The flexible UDP_TX.vhd component encapsulates a data packet into a UDP frame 
-- addressed from any port to any port/IP destination. 
-- 10Gbits/s.
-- Supports IPv4 and IPv6. 
-- Portable VHDL
--
-- As we can't be sure that the destination is reachable or even in the routing table, 
-- input packet acceptance is signified by an ACK or NAK.
-- Three cases:
-- (a) destination IP address is a WAN address: the UDP frame is sent immediately to the gateway
-- (b) destination IP address is a LAN address stored in the routing table. The UDP frame is sent between 0.1 and 
-- 1.33us after receiving the last byte. 
-- (c) destination IP address is not in the routing table. The routing table will send an ARP request (takes time).
-- This component sends a NAK back to the application. It is up to the application to discard or retry later.
-- 
-- The application (layer above) is responsible for UDP frame segmentation. 
-- The maximum size is determined by the number of block RAMs instantiated within. 
-- 
-- This component holds AT MOST TWO PACKETS at any given time in an elastic buffer. One packet being transferred in,
-- another packet being transferred out.
--
-- The application must check the flow control flag APP_CTS before and while sending data to this component.
-- The application should not send another UDP frame until receiving either an ACK or NAK regarding the previous
-- UDP frame. For speed reason, the app can transfer in the next UDP frame while the previous one is being 
-- transferred out to the MAC layer. The component behaves as an A/B buffer. 
--
-- The maximum overall throughput is reached when all packets have about the same size.
--
-- Device utilization (ADDR_WIDTH = 10, UDP_CKSUM_ENABLED='1',IPv6_ENABLED='1')
-- FF: 639
-- LUT: 1626
-- DSP48: 0
-- 18Kb BRAM: 2
-- BUFG: 1
-- Minimum period: 5.688ns (Maximum Frequency: 175.824MHz) Artix7-100T -1 speed grade
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity UDP_TX_10G is
	generic (
		ADDR_WIDTH: integer := 10;
            -- allocates buffer space: 73 bits * 2^ADDR_WIDTH words
		UDP_CKSUM_ENABLED: std_logic := '1';
			-- IPv4 checksum computation is optional. 0 to save space, 1 to enable.
		IPv6_ENABLED: std_logic := '1'
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
	);
    Port ( 
		CLK: in std_logic;
			 -- CLK must be a global clock 156.25 MHz or faster to match the 10Gbps MAC speed.
		SYNC_RESET: in std_logic;
			-- CLK-synchronous reset. MANDATORY!
		TICK_4US: in std_logic;

		--// APPLICATION INTERFACE -> TX BUFFER
		-- The application interface is synchronous with the application clock CLK
		APP_DATA: in std_logic_vector(63 downto 0);
		    -- byte order: MSB first (reason: easier to read contents during simulation)
		    -- unused bytes are expected to be zeroed
		APP_DATA_VALID: in std_logic_vector(7 downto 0);
		    -- example: 1 byte -> 0x80, 2 bytes -> 0xC0
		APP_SOF: in std_logic;	-- also resets internal state machine
		APP_EOF: in std_logic;
			-- IMPORTANT: always send an EOF to close the transaction.
		APP_CTS: out std_logic;	
			-- Clear To Send = transmit flow control. 
			-- App is responsible for checking the CTS signal before sending APP_DATA
			-- APP_SOF and APP_EOF are one CLK wide pulses indicating the first and last byte in the UDP frame.
			-- Special case: Zero-length UDP frame: APP_SOF = '1', APP_EOF = '1' and APP_DATA_VALID = x"00"
			-- Special case: 1 byte UDP frame: APP_SOF = '1', APP_EOF = '1', APP_DATA_VALID = x"80"
		ACK: out std_logic;
			-- previous UDP frame is accepted for transmission. Always after APP_SOF, but could happen before or
		NAK: out std_logic;
			-- no routing information available for the selected LAN destination IP. Try later.  
			-- ACK/NAK is sent anytime after APP_SOF, even before the input packet is fully transferred in  
	
		--// CONTROLS
		DEST_IP_ADDR: in std_logic_vector(127 downto 0);	
		DEST_PORT_NO: in std_logic_vector(15 downto 0);
		SOURCE_PORT_NO: in std_logic_vector(15 downto 0);
		IPv4_6n: in std_logic;
			-- routing information. Read at start of UDP frame (APP_SOF = '1')
			-- It can at any other time. 
			-- Note: changing destination IP address may involve a timing penalty as this component
			-- has to ask the routing table for routing information and possibly send an ARP request to
			-- the target IP and wait for the ARP response.
		IP_ID: in std_logic_vector(15 downto 0);
                -- 16-bit IP ID, unique for each datagram. Incremented every time
                -- an IP datagram is sent (not just for this socket).

		--// CONFIGURATION
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- fixed (i.e. not changing from UDP frame to frame)

		--// ROUTING INFO (interface with ARP_CACHE2)
		-- (a) Query
		RT_IP_ADDR: out std_logic_vector(127 downto 0);
			-- user query: destination IP address to resolve (could be local or remote). read when RT_REQ_RTS = '1'
		RT_IPv4_6n: out std_logic;
		    -- qualifier for RT_IP_ADDR: IPv4 (1) or IPv6 (0) address?
		RT_REQ_RTS: out std_logic;
			-- routing query ready to start
		RT_REQ_CTS: in std_logic;
			-- the top-level arbitration circuit passed the request to the routing table
		    -- (b) Reply
		RT_MAC_REPLY: in std_logic_vector(47 downto 0);
			-- Destination MAC address associated with the destination IP address RT_IP_ADDR. 
			-- Could be the Gateway MAC address if the destination IP address is outside the local area network.
		RT_MAC_RDY: in std_logic;
			-- 1 CLK pulse to read the MAC reply
			-- If the routing table is idle, the worst case latency from the RT_REQ_RTS request is 0.85us
			-- If there is no match in the table, no response will be provided. Calling routine should
			-- therefore have a timeout timer to detect lack of response.
		RT_NAK: in std_logic;
			-- 1 CLK pulse indicating that no record matching the RT_IP_ADDR was found in the table.


		--// OUTPUT: TX UDP layer -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended by MAC. Not supplied here.
		MAC_TX_DATA: out std_logic_vector(63 downto 0) := (others => '0');
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0) := x"00";
			-- data valid
		MAC_TX_EOF: out std_logic := '0';
			-- '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal. The user should check that this 
			-- signal is high before sending the next MAC_TX_DATA byte. 
		RTS: out std_logic := '0';
			-- '1' when a frame is ready to be sent (tell the COM5402 arbiter)
			-- When the MAC starts reading the output buffer, it is expected that it will be
			-- read until empty.

		--// TEST POINTS 
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of UDP_TX_10G is
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
--//-- INPUT STATE MACHINE -------------------------------------
signal STATE_A: integer range 0 to 5 := 0;
signal LAST_IP: std_logic_vector(127 downto 0) := (others => '0');
signal LAST_IPv4_6n: std_logic := '0';
signal LAST_MAC: std_logic_vector(47 downto 0) := (others => '0');
signal APP_EOF_FLAG0: std_logic := '0';
signal APP_EOF_FLAG: std_logic := '0';
signal TIMER_A: integer range 0 to 10 := 0;	-- integer multiple of 4us 
signal RT_REQ_RTS_local: std_logic := '0';
signal RT_REQ_RTS_TRIGGER: std_logic := '0';
signal TX_PACKET_SEQUENCE_START: std_logic := '0';
signal RTS_local: std_logic := '0';
signal EVENT_TO_STATE_A4: std_logic := '0';

--//-- UDP TX CHECKSUM  ---------------------------
signal TX_PACKET_SEQUENCE_START_SHIFT: std_logic_vector(6 downto 0) := (others => '0');
signal CKSUM_PART1: unsigned(18 downto 0) := (others => '0');
signal CKSUM_SEQ_CNTR: unsigned(2 downto 0) := (others => '0');
signal CKSUM1: unsigned(17 downto 0) := (others => '0');
signal CKSUM1A: unsigned(17 downto 0) := (others => '0');
signal CKSUM1B: unsigned(17 downto 0) := (others => '0');
signal CKSUM2: unsigned(17 downto 0) := (others => '0');
signal CKSUM3: unsigned(17 downto 0) := (others => '0');
signal CKSUM4: unsigned(17 downto 0) := (others => '0');
signal CKSUM5: unsigned(17 downto 0) := (others => '0');
signal CKSUM6: unsigned(17 downto 0) := (others => '0');
signal CKSUM3PLUS: unsigned(17 downto 0) := (others => '0');
signal CKSUM6PLUS: unsigned(17 downto 0) := (others => '0');
signal UDP_CHECKSUM: unsigned(15 downto 0) := (others => '0');
signal PAYLOAD_SIZE: unsigned(15 downto 0) := (others => '0');	-- in bytes
signal PAYLOAD_SIZE_PLUS8: unsigned(15 downto 0) := (others => '0');	-- in bytes
signal PAYLOAD_SIZE0: unsigned(15 downto 0) := (others => '0');	-- in bytes
signal PAYLOAD_SIZE_D: unsigned(15 downto 0) := (others => '0');	-- in bytes

--//-- ELASTIC BUFFER -----------------
signal WPTR: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WPTR_SOF: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WPTR0: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WEA: std_logic := '0';
signal WEA_D: std_logic := '0';
signal APP_SOF_D: std_logic := '0';
signal RPTR: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal BUF_SIZE: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal DIA: std_logic_vector(71 downto 0) := (others => '0');
signal DOB: std_logic_vector(71 downto 0) := (others => '0');
signal DOB_PREVIOUS: std_logic_vector(71 downto 0) := (others => '0');
signal DOB_SAMPLE_CLK_E: std_logic := '0';
signal DOB_SAMPLE_CLK: std_logic := '0';
signal TX_PAYLOAD_DATA:  std_logic_vector(63 downto 0) := (others => '0');


--//-- FREEZE INPUTS -----------------------
signal TX_DEST_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal IPv4_6n_D: std_logic := '0';
signal DEST_IP_ADDR_D: std_logic_vector(127 downto 0):= (others => '0');
signal DEST_PORT_NO_D: std_logic_vector(15 downto 0):= (others => '0');
signal SOURCE_PORT_NO_D: std_logic_vector(15 downto 0):= (others => '0');
signal TX_DEST_IP_ADDR: std_logic_vector(127 downto 0):= (others => '0');
signal IP_ID_D: std_logic_vector(15 downto 0);
signal TX_IPv4_6n: std_logic := '0';
signal TX_DEST_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TX_SOURCE_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal TX_SOURCE_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TX_IP_ID: std_logic_vector(15 downto 0);
signal IPv4_TOTAL_LENGTH: unsigned(15 downto 0) := (others => '0');			
signal IPv6_PAYLOAD_LENGTH: unsigned(15 downto 0) := (others => '0');	
signal UDP_LENGTH: unsigned(15 downto 0) := (others => '0');			

--//-- TX PACKET ASSEMBLY   ----------------------
signal TX_ACTIVE0: std_logic := '0';
signal TX_ACTIVE: std_logic := '0';
signal TX_WORD_COUNTER: unsigned(10 downto 0) := (others => '0'); 
signal TX_WORD_COUNTER_D: unsigned(10 downto 0) := (others => '0'); 
signal MAC_TX_WORD_VALID_E2: std_logic := '0';
signal MAC_TX_WORD_VALID_E: std_logic := '0';
signal MAC_TX_WORD_VALID: std_logic := '0';
signal TX_UDP_PAYLOAD: std_logic := '0';
signal MAC_TX_WORD_FLUSH_E2: std_logic := '0';


signal TX_UDP_PAYLOAD_D: std_logic := '0';
signal MAC_TX_EOF_local: std_logic := '0';

signal UDP_LAST_HEADER_BYTE: std_logic := '0';

--// TX IP HEADER CHECKSUM ---------------------------------------------
signal IP_HEADER_CHECKSUM: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM0: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM_PLUS: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM_FINAL: std_logic_vector(15 downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--//-- INPUT STATE MACHINE -------------------------------------
-- A-side of the dual-port block RAM
STATE_A_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE_A <= 0;
			TIMER_A <= 0;
			NAK <= '0';
		elsif (APP_SOF = '1') then
			-- App starts transferring a new UDP frame. Resets the state machine.
			-- Do we already know the destination MAC address here (in this component?)
			if(DEST_IP_ADDR = LAST_IP) and (IPv4_6n = LAST_IPv4_6n) then
				-- same destination as the previous frame. No need to ask the ARP cache (use LAST_MAC).
    			if (APP_EOF_FLAG = '1') then
                    -- input UDP frame is complete. 
                    STATE_A <= 3;  -- await complete MAC transmission of previous frame.
                else
                    STATE_A <= 2;    -- awaiting complete input UDP frame
                end if;
			else 
				-- request the destination MAC address from the routing table (ARP_CACHE2) 				
				-- Set timer to avoid being stuck waiting for a missing event.
				TIMER_A <= 10;
				STATE_A <= 1;	-- awaiting routing info
			end if;
		elsif (STATE_A = 0) then
			NAK <= '0';
		elsif (STATE_A = 1) and (RT_MAC_RDY = '1') then
			-- received destination MAC address for the specified destination IP address
			if (APP_EOF_FLAG = '1') then
				-- input UDP frame is complete. 
				STATE_A <= 3;  -- await complete MAC transmission of previous frame.
			else
				STATE_A <= 2;	-- awaiting complete input UDP frame
			end if;
		elsif (STATE_A = 1) and (RT_NAK = '1') then
			-- no entry in the routing table. Tell application (please try again later)
			STATE_A <= 5;    -- await EOF
			NAK <= '1';
		elsif (STATE_A = 1) and (TIMER_A = 0) then
			-- timeout waiting for a response from routing table (traffic congestion?) 
			-- tell application (please try again later)
			STATE_A <= 5;    -- Await EOF
			NAK <= '1';
		elsif (STATE_A = 2) and (APP_EOF_FLAG = '1') then
			-- input UDP frame is complete. 
			if ((RTS_local = '0') or (MAC_TX_EOF_local = '1')) then
			     -- input UDP frame is complete & previous frame transmission is complete.
			     STATE_A <= 4;
			else
			     STATE_A <= 3;  -- await complete MAC transmission of previous frame.
			end if;
		elsif (STATE_A = 3) and ((RTS_local = '0') or (MAC_TX_EOF_local = '1')) then
			-- input UDP frame is complete & previous frame transmission is complete.
			-- Ask MAC to send this new frame (raise RTS) and await MAC_TX_CTS.
			STATE_A <= 4;
		elsif (STATE_A = 4) and (MAC_TX_CTS = '1') then
			-- starting transmission to MAC layer (TX_PACKET_SEQUENCE_START). Ready for another input UDP frame.
			STATE_A <= 0;
		elsif (STATE_A = 5) then
		    -- Received NAK. Awaiting EOF.
			NAK <= '0';
			if (APP_EOF_FLAG = '1') then
			  -- discard previous frame. back to idle
		      STATE_A <= 0;
		    end if;
		elsif(TICK_4US = '1') and (TIMER_A /= 0) then
			TIMER_A <= TIMER_A - 1;
		end if;
	end if;
end process;
EVENT_TO_STATE_A4 <=  '1' when (STATE_A = 2) and (APP_EOF_FLAG = '1') and ((RTS_local = '0') or (MAC_TX_EOF_local = '1')) else
                    '1' when (STATE_A = 3) and ((RTS_local = '0') or (MAC_TX_EOF_local = '1')) else
                    '0';
		
-- flow control: stop input flow immediately upon receiving the last packet byte. Resume when 
APP_CTS <=  '1' when (TX_PACKET_SEQUENCE_START = '1') else
            '0' when (APP_EOF = '1') or (APP_EOF_FLAG = '1') or (STATE_A = 3) else
			'1';

ACK <= TX_PACKET_SEQUENCE_START;	-- send ACK to the App (same as start of UDP packet assembly).

-- Ask for MAC transmit resources as soon as a complete UDP frame is stored in the elastic buffer
-- and the previous frame was completely transferred to the MAC 
-- and routing information is available.
RTS_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS_local <= '0';
		elsif (EVENT_TO_STATE_A4 = '1') then
            -- complete UDP frame waiting for tx in elastic buffer and previous frame transmission is complete
            RTS_local <= '1';
		elsif(MAC_TX_EOF_local = '1') then
			-- no complete UDP frame waiting for tx
			RTS_local <= '0';
		end if;
	end if;
end process;
RTS <= RTS_local or EVENT_TO_STATE_A4;

--//-- ROUTING -------------------------------------
-- send routing request
RT_REQ_RTS_TRIGGER <= '1' when (STATE_A = 0) and (APP_SOF = '1') and ((DEST_IP_ADDR /= LAST_IP) or (IPv4_6n /= LAST_IPv4_6n)) else '0';
RT_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RT_REQ_RTS_local <= '0';
		elsif (RT_REQ_RTS_TRIGGER = '1') then
			-- new UDP tx packet, different destination. 
			-- request the destination MAC address from the routing table (ARP_CACHE2) 				
			RT_REQ_RTS_local <= '1';
		elsif (RT_REQ_CTS = '1') then
			-- routing request in progress.
			RT_REQ_RTS_local <= '0';
		end if;
	end if;
end process;
RT_REQ_RTS <= RT_REQ_RTS_local or RT_REQ_RTS_TRIGGER;

RT_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RT_IP_ADDR <= (others => '0');
		elsif (RT_REQ_RTS_TRIGGER = '1') then
			-- new UDP tx packet, different destination. 
			-- request the destination MAC address from the routing table (ARP_CACHE2) 				
			RT_IP_ADDR <= DEST_IP_ADDR;	
			RT_IPv4_6n <= IPv4_6n;
		end if;
	end if;
end process;

-- DOUBT ABOUT TIMING... HOW TO MATCH RT_MAC_REPLY WITH DEST_IP_ADDR??????
-- Remember the last set of destination IP/MAC addresses to minimize traffic at the cache memory
RT_003: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			LAST_IP <= (others => '0');
			LAST_IPv4_6n <= '0';
			LAST_MAC <= (others => '0');
		elsif (STATE_A = 1) and (RT_MAC_RDY = '1') then
			-- received destination MAC address for the specified destination IP address
			LAST_IP <= DEST_IP_ADDR;	
			LAST_IPv4_6n <= IPv4_6n;
			LAST_MAC <= RT_MAC_REPLY;
		end if;
	end if;
end process;

-- Is the UDP frame completely in?
-- This process works even in the special case of zero-length UDP frame
APP_EOF_FLAG_GEN: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			APP_EOF_FLAG0 <= '0';
		-- the events order is important here.
        elsif (STATE_A = 5) and (APP_EOF_FLAG = '1') then
            -- NAK. Discard frame 		
			APP_EOF_FLAG0 <= '0';
        elsif(APP_EOF = '1') then
			APP_EOF_FLAG0 <= '1';
		elsif(TX_PACKET_SEQUENCE_START = '1') then
			-- idle
			APP_EOF_FLAG0 <= '0';
		end if;
	end if;
end process;
APP_EOF_FLAG <= APP_EOF_FLAG0 or APP_EOF;

--//-- UDP TX CHECKSUM  ---------------------------
UDP_TX_CKSUM_1: if(UDP_CKSUM_ENABLED = '1') generate
	-- Compute the UDP payload checksum (excluding headers).
	-- This PARTIAL checksum is ready 1(even number of bytes in payload) or 2 (odd number) into STATE_A = 3.
	-- So the checksum will always be ready when needed.

	-- for timing reasons, we limit ourselves to summing up to 3 16-bit fields per CLK 
	UDP_CKSUM_001: 	process(CLK)
	begin
		if rising_edge(CLK) then
			-- rephrased for better timing. *080718
			CKSUM1A <= resize(unsigned(APP_DATA(63 downto 48)),18) + resize(unsigned(APP_DATA(47 downto 32)),18);
			CKSUM1B <= resize(unsigned(APP_DATA(31 downto 16)),18) + resize(unsigned(APP_DATA(15 downto 0)),18);
			  if(APP_SOF_D = '1') then
					-- start of frame
					CKSUM1 <= CKSUM1A;
					CKSUM2 <= CKSUM1B;
					CKSUM3 <= ("00" & x"00_11");	-- UDP protocol
			  elsif(WEA_D = '1') then
					CKSUM1 <= resize(CKSUM1(15 downto 0),18) + CKSUM1A;
					CKSUM2 <= resize(CKSUM2(15 downto 0),18) + CKSUM1B;
					CKSUM3 <= CKSUM3PLUS;
			  end if;
		 end if;
	end process;
	CKSUM3PLUS <= CKSUM3 + resize(CKSUM1(17 downto 16),18) + resize(CKSUM2(17 downto 16),18);
	
	-- for IPv6, pre-compute the IPv6 address checksum. Only once at reset.
	UDP_CKSUM_002: 	process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				CKSUM_SEQ_CNTR <= "110";
			elsif(CKSUM_SEQ_CNTR > 0) then
				CKSUM_SEQ_CNTR <= CKSUM_SEQ_CNTR - 1;
			end if;
		end if;
	end process;

	UDP_CKSUM_003: 	process(CLK)
	begin
		if rising_edge(CLK) then
			 -- fixed part of the checksum is initialized at reset
			if(SYNC_RESET = '1') then
				CKSUM_PART1 <= resize(unsigned(IPv6_ADDR(127 downto 112)),19) + resize(unsigned(IPv6_ADDR(111 downto 96)),19);
			elsif(CKSUM_SEQ_CNTR = "110") then
				CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(95 downto 80)),19);
			elsif(CKSUM_SEQ_CNTR = "101") then
				CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(79 downto 64)),19);
			elsif(CKSUM_SEQ_CNTR = "100") then
				CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(63 downto 48)),19);
			elsif(CKSUM_SEQ_CNTR = "011") then
				CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(47 downto 32)),19);
			elsif(CKSUM_SEQ_CNTR = "010") then
				CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(31 downto 16)),19);
			elsif(CKSUM_SEQ_CNTR = "001") then
				CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(15 downto 0)),19);
			end if;
		end if;
	end process;


	-- Different pseudo-headers are used for IPv4 and IPv6
	-- Checksum computation must be complete by the time TX_WORD_COUNTER reaches 5(IPv4) or 7 (IPv6). So we only have 5 iterations maximum to sum the pseudo header.
	UDP_CKSUM_004: 	process(CLK)
	begin
		if rising_edge(CLK) then
			 TX_PACKET_SEQUENCE_START_SHIFT(6 downto 0) <= TX_PACKET_SEQUENCE_START_SHIFT(5 downto 0) & TX_PACKET_SEQUENCE_START;
			  if(TX_PACKET_SEQUENCE_START = '1') then
					CKSUM4 <=  resize(unsigned(SOURCE_PORT_NO_D),18) +  resize(unsigned(DEST_PORT_NO_D),18); 
					CKSUM6 <= (others => '0');
					if(IPv4_6n_D = '1') then   -- IPv4
						CKSUM5 <= resize(unsigned(IPv4_ADDR(31 downto 16)),18) + resize(unsigned(IPv4_ADDR(15 downto 0)),18) + resize(PAYLOAD_SIZE_PLUS8 & "0",18); -- src IP address + 2*UDP length
					elsif(IPv6_ENABLED = '1') then -- IPv6
						CKSUM5 <= resize(CKSUM_PART1(15 downto 0),18) + resize(CKSUM_PART1(18 downto 16),18) + resize(PAYLOAD_SIZE_PLUS8 & "0",18); -- src IP address + 2*UDP length
					end if;
			  else
					if(TX_IPv4_6n = '1') then   -- IPv4
						 if(TX_PACKET_SEQUENCE_START_SHIFT(0) = '1') then
							  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM1(15 downto 0),18);   
							  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(CKSUM2(15 downto 0),18);
							  CKSUM6 <= CKSUM6PLUS + CKSUM3PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(1) = '1') then
							  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(15 downto 0)),18);   -- dst IP address
							  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(31 downto 16)),18);
							  CKSUM6 <= CKSUM6PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(2) = '1') then
							 CKSUM6 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM5(15 downto 0),18) + CKSUM6PLUS;
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(3) = '1') then
							 CKSUM6 <= resize(CKSUM6(15 downto 0),18) + CKSUM6(17 downto 16);
            elsif(TX_PACKET_SEQUENCE_START_SHIFT(4) = '1') then
                  CKSUM6 <= resize(CKSUM6(15 downto 0),18) + CKSUM6(17 downto 16);
						end if;
					elsif(IPv6_ENABLED = '1') then -- IPv6
						if(TX_PACKET_SEQUENCE_START_SHIFT(0) = '1') then
							CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM1(15 downto 0),18);   
							CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(CKSUM2(15 downto 0),18);
							CKSUM6 <= CKSUM6PLUS + CKSUM3PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(1) = '1') then
						  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(127 downto 112)),18);   -- dest IP address
						  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(95 downto 80)),18); -- dest IP address
						  CKSUM6 <= CKSUM6PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(2) = '1') then
						  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(111 downto 96)),18);   -- dest IP address
						  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(79 downto 64)),18); -- dest IP address
						  CKSUM6 <= CKSUM6PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(3) = '1') then
						  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(63 downto 48)),18);   -- dest IP address
						  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(31 downto 16)),18); -- dest IP address
						  CKSUM6 <= CKSUM6PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(4) = '1') then
						  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(47 downto 32)),18);   -- dest IP address
						  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(15 downto 0)),18); -- dest IP address
						  CKSUM6 <= CKSUM6PLUS; -- carry
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(5) = '1') then
							CKSUM6 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM5(15 downto 0),18) + CKSUM6PLUS;
						elsif(TX_PACKET_SEQUENCE_START_SHIFT(6) = '1') then
							CKSUM6 <= resize(CKSUM6(15 downto 0),18) + CKSUM6(17 downto 16);
						end if;
					end if;
			  end if;
		 end if;
	end process;
	CKSUM6PLUS <= CKSUM6 + resize(CKSUM4(17 downto 16),18) + resize(CKSUM5(17 downto 16),18);
	UDP_CHECKSUM <= not CKSUM6(15 downto 0);
end generate;
UDP_TX_CKSUM_0: if(UDP_CKSUM_ENABLED = '0') generate
	UDP_CHECKSUM <= x"0000";
end generate;

PAYLOAD_SIZE_GEN: 	process(CLK)
begin
	if rising_edge(CLK) then
        if(WEA = '1') then
            -- new word
            if(APP_DATA_VALID(0) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 8;
            elsif(APP_DATA_VALID(1) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 7;
            elsif(APP_DATA_VALID(2) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 6;
            elsif(APP_DATA_VALID(3) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 5;
            elsif(APP_DATA_VALID(4) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 4;
            elsif(APP_DATA_VALID(5) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 3;
            elsif(APP_DATA_VALID(6) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 2;
            elsif(APP_DATA_VALID(7) = '1') then
                PAYLOAD_SIZE <= PAYLOAD_SIZE0 + 1;
--            else
--					-- illegal
--                PAYLOAD_SIZE <= PAYLOAD_SIZE0;
            end if;  
        end if;
     end if;
end process;
PAYLOAD_SIZE_PLUS8 <= PAYLOAD_SIZE + 8;
PAYLOAD_SIZE0 <= PAYLOAD_SIZE when (APP_SOF = '0') else (others => '0');

--//-- ELASTIC BUFFER ----------------------------
WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		WEA_D <= WEA;
		APP_SOF_D <= APP_SOF;
		
		if(SYNC_RESET = '1') then
			WPTR <= (others => '0');
		elsif(WEA = '1') then
			WPTR <= WPTR + 1;
		end if;
	end if;
end process;

-- remember SOF location
WPTR_SOF_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WPTR_SOF <= (others => '0');
		elsif(APP_SOF = '1') then
			WPTR_SOF <= WPTR;
		end if;
	end if;
end process;


WEA <= '1' when (unsigned(APP_DATA_VALID) /= 0) else '0';
DIA <= APP_DATA_VALID & APP_DATA;
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
    ADDRA => std_logic_vector(WPTR),  -- Port A Address Input
    DIA => DIA,      -- Port A Data Input
    OEA => '0',
    DOA => open,
    CSB => '1',
    CLKB => CLK,
    WEB => '0',
    ADDRB => std_logic_vector(RPTR),  -- Port B Address Input
    DIB => (others => '0'),      -- Port B Data Input
    OEB => '1',
    DOB => DOB      -- Port B Data Output
);

TX_PAYLOAD_DATA <= DOB(63 downto 0);
BUF_SIZE <= WPTR0 + not RPTR;

-- read pointer management
RPTR_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RPTR <= (others => '1');
			DOB_SAMPLE_CLK_E <= '0';
		else
			TX_UDP_PAYLOAD_D <= TX_UDP_PAYLOAD;
			DOB_SAMPLE_CLK <= DOB_SAMPLE_CLK_E;
			
			if(TX_PACKET_SEQUENCE_START = '1') then
				RPTR <= WPTR_SOF - 1;	-- points to one address before the start of UDP payload
			    DOB_SAMPLE_CLK_E <= '0';
			elsif(TX_ACTIVE = '1') and (MAC_TX_CTS = '1') and (TX_UDP_PAYLOAD = '1')  then	
				RPTR <= RPTR + 1;	-- read follow-on UDP payload bytes
			    DOB_SAMPLE_CLK_E <= '1';
			else
			    DOB_SAMPLE_CLK_E <= '0';
			end if;
		end if;
	end if;
end process;
	
-- remember previous word
DOB_PREVIOUS_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(DOB_SAMPLE_CLK = '1') then
			DOB_PREVIOUS <= DOB;
		end if;
	end if;
end process;

--//-- FREEZE INPUTS -----------------------
-- Latch in all key fields at the start trigger, or at the latest during the Ethernet header.

-- 1st latch info at the input start from app
INFO_011: process(CLK)
begin
	if rising_edge(CLK) then
		if(APP_SOF  ='1') then
			DEST_IP_ADDR_D <= DEST_IP_ADDR;
			DEST_PORT_NO_D <= DEST_PORT_NO;
			SOURCE_PORT_NO_D <= SOURCE_PORT_NO;
			IPv4_6n_D <= IPv4_6n;
			IP_ID_D <= IP_ID;
		end if;
	end if;
end process;

-- latch a second time upon start of output frame to MAC
INFO_012: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- Freeze parameters which can change on the A-side of the block ram 
			-- while we are sending the UDP packet to the MAC layer
			PAYLOAD_SIZE_D <= PAYLOAD_SIZE;  -- latch in payload size
			TX_DEST_MAC_ADDR <= LAST_MAC;
			TX_DEST_IP_ADDR <= DEST_IP_ADDR_D;	
			TX_IPv4_6n <= IPv4_6n_D;
			TX_DEST_PORT_NO <= DEST_PORT_NO_D;
			TX_SOURCE_PORT_NO <= SOURCE_PORT_NO_D;
			TX_IP_ID <= IP_ID_D;
			IPv6_PAYLOAD_LENGTH <= PAYLOAD_SIZE_PLUS8; -- same as UDP length
			IPv4_TOTAL_LENGTH <= PAYLOAD_SIZE + 28;
			WPTR0 <= WPTR;  -- remember memory location for the last byte
		end if;
	end if;
end process;

--// IP HEADER CHECKSUM ----------------------
-- Transmit IP packet header checksum. Only applies to IPv4 (no header checksum in IPv6)
-- We must start the checksum early as the checksum field is not the last word in the header.
-- perform 1's complement sum of all 16-bit words within the header.
-- the checksum must be ready when TX_WORD_COUNTER_D=3

IP_HEADER_CHECKSUM_001: process(CLK)
begin
	if rising_edge(CLK) then
        IP_HEADER_CHECKSUM0 <= ("01" & x"8411") + resize(unsigned(IPv4_ADDR(31 downto 16)),18) + resize(unsigned(IPv4_ADDR(15 downto 0)),18);  -- x"4500" + +x"4000" + x"FF11"
	
        if (TX_PACKET_SEQUENCE_START = '1') and (IPv4_6n_D = '0') then
            -- the IP header checksum applies only to IPv4
            IP_HEADER_CHECKSUM <= (others => '0');
        elsif (TX_PACKET_SEQUENCE_START = '1') and (IPv4_6n_D = '1') then
             IP_HEADER_CHECKSUM <= resize(unsigned(IP_HEADER_CHECKSUM0(15 downto 0)),18) + resize(unsigned(IP_HEADER_CHECKSUM0(17 downto 16)),18) + resize(unsigned(IP_ID_D),18);  
        elsif(TX_IPv4_6n = '1') then
            if(TX_PACKET_SEQUENCE_START_SHIFT(0) = '1') then
                IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS  + resize(IPv4_TOTAL_LENGTH,18);
            elsif(TX_PACKET_SEQUENCE_START_SHIFT(1) = '1') then
                IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS  + resize(unsigned(TX_DEST_IP_ADDR(15 downto 0)),18);
            elsif(TX_PACKET_SEQUENCE_START_SHIFT(2) = '1') then
                IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS + resize(unsigned(TX_DEST_IP_ADDR(31 downto 16)),18);
            elsif(TX_PACKET_SEQUENCE_START_SHIFT(3) = '1') then
                IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS ;
            end if;	
		end if;
		
 	end if;
end process;
IP_HEADER_CHECKSUM_PLUS <= resize(unsigned(IP_HEADER_CHECKSUM(15 downto 0)),18) + resize(unsigned(IP_HEADER_CHECKSUM(17 downto 16)),18);
IP_HEADER_CHECKSUM_FINAL <= x"FFFF" when (IP_HEADER_CHECKSUM(16) = '1') and (IP_HEADER_CHECKSUM(0) = '0') else  
                            x"FFFE" when (IP_HEADER_CHECKSUM(16) = '1') and (IP_HEADER_CHECKSUM(0) = '1') else  
                            not(std_logic_vector(IP_HEADER_CHECKSUM(15 downto 0)));
--//-- TX PACKET ASSEMBLY   ----------------------
-- Transmit packet is assembled on the fly, consistent with our design goal
-- of minimizing storage in each UDP_TX component.
-- The packet includes the lower layers, i.e. IP layer and Ethernet layer.
-- 
-- First, we tell the outsider arbitration that we are ready to send by raising RTS high.
-- When the transmit path becomes available, the arbiter tells us to go ahead with the transmission MAC_TX_CTS = '1'

TX_PACKET_SEQUENCE_START <= '1' when (STATE_A = 4) and (MAC_TX_CTS = '1') else '0';
	-- Starting sending the Ethernet/IP/UDP packet to the MAC layer.

STATE_MACHINE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_ACTIVE0 <= '0';
		elsif (TX_PACKET_SEQUENCE_START = '1') then
			TX_ACTIVE0 <= '1';
		elsif(MAC_TX_EOF_local = '1') then
			TX_ACTIVE0 <= '0';
		end if;
	end if;
end process;
TX_ACTIVE <= TX_ACTIVE0 and (not MAC_TX_EOF_local);

TX_SCHEDULER_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_WORD_COUNTER <= (others => '0');
			TX_WORD_COUNTER_D <= (others => '0');
			MAC_TX_WORD_VALID_E2 <= '0';
			MAC_TX_WORD_VALID_E <= '0';
			MAC_TX_WORD_FLUSH_E2 <= '0';
		else
		    MAC_TX_WORD_VALID_E <= MAC_TX_WORD_VALID_E2;
			TX_WORD_COUNTER_D <= TX_WORD_COUNTER;    -- must keep the alignment with RPTR/DOB
		
--			if(MAC_TX_EOF_E = '1') then
--				-- end of UDP frame transmission
--				-- For clarity, wait 1 CLK after the end of the previous packet to do anything.
--    			TX_WORD_COUNTER <= (others => '0');
--				MAC_TX_WORD_VALID_E2 <= '0';
			if (TX_PACKET_SEQUENCE_START = '1') then
				-- UDP frame ready to send in the elastic buffer 
				-- initiating tx request. Reset counters. 
    			TX_WORD_COUNTER <= (others => '0');
				MAC_TX_WORD_VALID_E2 <= '1';
				MAC_TX_WORD_FLUSH_E2 <= '0';
			elsif(TX_ACTIVE = '1') and (MAC_TX_CTS = '1') and (BUF_SIZE /= 0) then
				-- one packet is ready to send and MAC requests another byte
				MAC_TX_WORD_VALID_E2 <= '1';  -- enable path to MAC
                TX_WORD_COUNTER <= TX_WORD_COUNTER + 1;
            elsif(TX_ACTIVE = '1') and  (MAC_TX_CTS = '1') and (BUF_SIZE = 0) and (MAC_TX_WORD_FLUSH_E2 = '0') then
                -- possible last word (to be confirmed later)
                TX_WORD_COUNTER <= TX_WORD_COUNTER + 1;
				MAC_TX_WORD_FLUSH_E2 <= '1';
				MAC_TX_WORD_VALID_E2 <= '1';  -- enable path to MAC (to be confirmed later
			else
				MAC_TX_WORD_VALID_E2 <= '0';
			end if;
		end if;
	end if;
end process;
TX_UDP_PAYLOAD <=   '0' when (BUF_SIZE = 0) else
                    '1' when (TX_IPv4_6n = '1') and (TX_WORD_COUNTER >= "00000000100")  else 
                    '1' when (IPv6_ENABLED = '1') and (TX_IPv4_6n = '0') and (TX_WORD_COUNTER >= "00000000110")  else
                    '0';    

MAC_TX_DATA_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(TX_IPv4_6n = '1') then -- IPv4
           case TX_WORD_COUNTER_D is
               when "00000000000" => 
                   MAC_TX_DATA(63 downto 16) <= TX_DEST_MAC_ADDR;    
                   MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
               when "00000000001" => 
                   MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);    
                   MAC_TX_DATA(31 downto 0) <= x"08004500";   
               when "00000000010" => 
                   MAC_TX_DATA(63 downto 48) <= std_logic_vector(IPv4_TOTAL_LENGTH);   
                   MAC_TX_DATA(47 downto 32) <= TX_IP_ID;
                   MAC_TX_DATA(31 downto 0) <= x"4000FF11";     -- don't fragment, 255 hop limit, UDP
               when "00000000011" => 
                   MAC_TX_DATA(63 downto 48) <= IP_HEADER_CHECKSUM_FINAL;   -- IP header checksum   
                   MAC_TX_DATA(47 downto 16) <= IPv4_ADDR;   -- source IP address   
                   MAC_TX_DATA(15 downto 0) <= TX_DEST_IP_ADDR(31 downto 16);   -- destination IP address   
               when "00000000100" => 
                   MAC_TX_DATA(63 downto 48) <= TX_DEST_IP_ADDR(15 downto 0);   -- destination IP address  
                   MAC_TX_DATA(47 downto 32) <= TX_SOURCE_PORT_NO;
                   MAC_TX_DATA(31 downto 16) <= TX_DEST_PORT_NO;
                   MAC_TX_DATA(15 downto 0) <= std_logic_vector(IPv6_PAYLOAD_LENGTH);  -- = UDP frame length
               when "00000000101" => 
                   MAC_TX_DATA(63 downto 48) <= std_logic_vector(UDP_CHECKSUM);
                   MAC_TX_DATA(47 downto 0) <= DOB(63 downto 16);
               when others => 
                   if(DOB_SAMPLE_CLK = '1') then
                       MAC_TX_DATA(63 downto 48) <= DOB_PREVIOUS(15 downto 0);
                       MAC_TX_DATA(47 downto 0) <= DOB(63 downto 16);
                   else
                       -- flush partial last word
                       MAC_TX_DATA(63 downto 48) <= DOB(15 downto 0);
                       MAC_TX_DATA(47 downto 0) <= (others => '0');
                   end if;
            end case;
	   elsif(IPv6_ENABLED = '1') then -- IPv6
            case TX_WORD_COUNTER_D is
               when "00000000000" => 
                   MAC_TX_DATA(63 downto 16) <= TX_DEST_MAC_ADDR;    
                   MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
               when "00000000001" => 
                   MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);    
                   MAC_TX_DATA(31 downto 0) <= x"86dd6000";   
               when "00000000010" => 
                   MAC_TX_DATA(63 downto 48) <= x"0000";   
                   MAC_TX_DATA(47 downto 32) <= std_logic_vector(IPv6_PAYLOAD_LENGTH);   -- payload length
                   MAC_TX_DATA(31 downto 16) <= x"11FF";   -- UDP, 255 hop limit
                   MAC_TX_DATA(15 downto 0) <= IPv6_ADDR(127 downto 112);   
               when "00000000011" => 
                   MAC_TX_DATA <= IPv6_ADDR(111 downto 48);   
               when "00000000100" => 
                   MAC_TX_DATA(63 downto 16) <= IPv6_ADDR(47 downto 0);  
                   MAC_TX_DATA(15 downto 0) <= TX_DEST_IP_ADDR(127 downto 112);   
               when "00000000101" => 
                   MAC_TX_DATA <= TX_DEST_IP_ADDR(111 downto 48);   
               when "00000000110" => 
                   MAC_TX_DATA(63 downto 16) <= TX_DEST_IP_ADDR(47 downto 0);  
                   MAC_TX_DATA(15 downto 0) <= TX_SOURCE_PORT_NO;
               when "00000000111" => 
                   MAC_TX_DATA(63 downto 48) <= TX_DEST_PORT_NO;
                   MAC_TX_DATA(47 downto 32) <= std_logic_vector(IPv6_PAYLOAD_LENGTH);
                   MAC_TX_DATA(31 downto 16) <= std_logic_vector(UDP_CHECKSUM);
                   MAC_TX_DATA(15 downto 0) <= DOB(63 downto 48);
                when others => 
                    if(DOB_SAMPLE_CLK = '1') then
                        MAC_TX_DATA(63 downto 16) <= DOB_PREVIOUS(47 downto 0);
                        MAC_TX_DATA(15 downto 0) <= DOB(63 downto 48);
                    else
                        -- flush partial last word
                        MAC_TX_DATA(63 downto 16) <= DOB(47 downto 0);
                        MAC_TX_DATA(15 downto 0) <= (others => '0');
                    end if;
            end case;
        end if;
	end if;
end process;

MAC_TX_DATA_VALID_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	   MAC_TX_WORD_VALID <= MAC_TX_WORD_VALID_E;
	   
	   if(MAC_TX_WORD_VALID_E = '1') then
           if(TX_IPv4_6n = '1') then -- IPv4
                if(TX_WORD_COUNTER_D <= 4) then
	               MAC_TX_DATA_VALID <= x"FF";
	            elsif(TX_WORD_COUNTER_D = 5) then
	               MAC_TX_DATA_VALID <="11" & DOB(71 downto 66);
	            elsif(DOB_SAMPLE_CLK = '1') then
	               MAC_TX_DATA_VALID <= DOB_PREVIOUS(65 downto 64) & DOB(71 downto 66);
	            else
                   -- flush partial last word
	               MAC_TX_DATA_VALID <= DOB(65 downto 64) & "000000";
	            end if;
            elsif(IPv6_ENABLED = '1') then -- IPv6
                if(TX_WORD_COUNTER_D <= 6) then
                   MAC_TX_DATA_VALID <= x"FF";
                elsif(TX_WORD_COUNTER_D = 7) then
                   MAC_TX_DATA_VALID <="111111" & DOB(71 downto 70);
 	            elsif(DOB_SAMPLE_CLK = '1') then
                   MAC_TX_DATA_VALID <= DOB_PREVIOUS(69 downto 64) & DOB(71 downto 70);
                else
                   -- flush partial last word
                   MAC_TX_DATA_VALID <= DOB(69 downto 64) & "00";
                end if;
           end if;
	   else
	       MAC_TX_DATA_VALID <= x"00";
	   end if;
   end if;
end process;

MAC_TX_EOF_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(SYNC_RESET = '1') then
           MAC_TX_EOF_local <= '0';        
	   elsif(MAC_TX_WORD_VALID_E = '1') then
           if(TX_IPv4_6n = '1') then
 	           if(TX_WORD_COUNTER_D = 5) and (DOB(65) = '0') then
 	              MAC_TX_EOF_local <= '1';
               elsif (TX_WORD_COUNTER_D > 5) and (DOB_SAMPLE_CLK = '1') and (DOB(65) = '0') then
  	              MAC_TX_EOF_local <= '1';
               elsif (TX_WORD_COUNTER_D > 5) and (DOB_SAMPLE_CLK = '0') and (DOB_PREVIOUS(65) = '1') then
                  -- flush partial last word
 	              MAC_TX_EOF_local <= '1';
  	           else
 	              MAC_TX_EOF_local <= '0';
	           end if;
            elsif(IPv6_ENABLED = '1') then -- IPv6
 	           if(TX_WORD_COUNTER_D = 7) and (DOB(69) = '0') then
                   MAC_TX_EOF_local <= '1';
               elsif (TX_WORD_COUNTER_D > 7) and (DOB_SAMPLE_CLK = '1') and (DOB(69) = '0') then
                   MAC_TX_EOF_local <= '1';
               elsif (TX_WORD_COUNTER_D > 7) and (DOB_SAMPLE_CLK = '0') and (DOB_PREVIOUS(69) = '0') then
                  -- flush partial last word
                   MAC_TX_EOF_local <= '1';
                else
                   MAC_TX_EOF_local <= '0';
               end if;
            else
                MAC_TX_EOF_local <= '0';
            end if;
	    else
            MAC_TX_EOF_local <= '0';
	   end if;
   end if;
end process;
MAC_TX_EOF <= MAC_TX_EOF_local;

--//-- TEST POINTS ---------------------------------
TP(1) <= '1' when (STATE_A = 0) else '0';
TP(2) <= '1' when (STATE_A = 3) else '0';
TP(3) <= RTS_local;
TP(4) <= MAC_TX_EOF_local;
TP(5) <= MAC_TX_CTS;
TP(7) <= RT_MAC_RDY;
TP(8) <= RT_NAK;
TP(9) <= TX_PACKET_SEQUENCE_START;
TP(10) <= TX_ACTIVE;

end Behavioral;
