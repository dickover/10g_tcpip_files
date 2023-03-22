-------------------------------------------------------------
-- MSS copyright 2018-2021
-- Filename:  TCP_SERVER_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0.7
-- Date last modified: 3/5/21
-- Inheritance: 	COM-5402SOFT TCP_SERVER.VHD rev13 12/3/16
--
-- description:  TCP protocol for a server. 10Gbits/s version. Tx and Rx. 
-- Server awaits connection from a client. Once the connection is established, bi-directional
-- data transmission can take place. 
-- One instantiation per port. 
-- This component is mainly a state machine. It avoids storing any packet data to keep size to its minimum.
-- Consequently, the rx data recipient should be able to backtrack and throw out the received packet if
-- proven invalid at the end. 
-- Likewise, the tx data source should be able to rewind and re-transmit previous data if the TCP client 
-- requests is.
-- Since this is a server, we do not know a priori whether the protocol is IPv4 or IPv6 (it depends on the client).
-- So each server is given two IP addresses, one for each IP version.
--
-- Device utilization (NTCPSTREAMS=1, MSS=1460, IPv6_ENABLED='1')
-- FF: 1134
-- LUT: 1536
-- DSP48: 0
-- 18Kb BRAM: 0
-- BUFG: 1
-- Minimum period: 4.096ns (Maximum Frequency: 244.126MHz)  Artix7-100T -1 speed grade
--
-- Rev 0.1 12/8/18 
-- Harmonizing with COM-5402SOFT/TCP_SERVER.VHD
--
-- Rev 0.2 4/24/19 AZ
-- Corrected bug with (late) retransmission when a missing or delayed ACK is detected.
-- Increased retransmit timeout value (x2)
--
-- Rev 0.3 6/10/19 AZ
-- Set a min of 1second for the retransmission timeout as per RFC
--
-- Rev 0.4 1/20/20 AZ
-- Eliminated instability in the ack/retransmission feedback loop
-- Reduce latency for receiving the first full tx frame to < 90us starting at client connection request (don't wait for the first client ACK)
--
-- Rev 0.5 12/2/20 AZ
-- Corrected bug: bad TX_ACK_NO/TX_ACK_WINDOW_LENGTH reporting when multiple connections
-- Changes as per DCC for NASA
--
-- Rev 0.6 1/18/21 AZ
-- Increased RX_FREE_SPACE, TX_SEQ_NO, RX_TCP_ACK_NO_D, EFF_RX_WINDOW_SIZE_PARTIAL to 32-bit in preparation for window scaling.
-- Added window scaling
--
-- Rev 0.7 3/5/21 AZ
-- Corrected bug affecting window size in ack: TX_ACK_WINDOW_LENGTH
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;
use work.com5502pkg.all;	-- defines global types, number of TCP streams, etc

entity TCP_SERVER_10G is
	generic (
		NTCPSTREAMS: integer := 1;  
			-- number of concurrent TCP streams handled by this component
		TCP_MAX_WINDOW_SIZE: integer range 11 to 20:= 15;
			-- maximum Window size is expressed as 2**n Bytes. Thus a value of 15 indicates a window size of 32KB.
			-- used by TCP_SERVER to negotiate if the TCP window scaling option is warranted.
		WINDOW_SCALING_ENABLED: std_logic := '0';
			-- enable/disable window scaling option
		TCP_KEEPALIVE_PERIOD: integer := 60;
			-- period in seconds for sending a keep-alive frame after no data and no ack is received. 
			-- "Typically TCP Keepalives are sent every 45 or 60 seconds on an idle TCP connection, and the connection is 
			-- dropped after 3 sequential ACKs are missed" 
		IPv6_ENABLED: std_logic := '0';
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		SIMULATION: std_logic := '0'
			-- 1 during simulation. for example to fix the tx_seq_no so that it matches the Wireshark 
			-- captures. 
	);
    Port ( 
		--// CLK, RESET, TIME
		CLK: in std_logic;	
			-- Must be a global clock. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;

		TICK_4US: in std_logic;
		TICK_100MS: in std_logic;
			-- 1 CLK-wide pulse every 4us and 10ms

		--// Configuration Fields
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		TCP_LOCAL_PORTS: in SLV16xNTCPSTREAMStype;
			-- TCP_SERVER port configuration. Each one of the NTCPSTREAMS streams handled by this
			-- component must be configured with a distinct port number. 
			-- This value is used as destination port number to filter incoming packets, 
			-- and as source port number in outgoing packets.

		--// User-initiated connection reset for stream I
		CONNECTION_RESET: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		TCP_KEEPALIVE_EN: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- enable TCP Keepalive (1) or not (0)

		--// RECEIVED IP PAYLOAD   ---------------------------------------------
		-- Excludes MAC layer header, IP header.
		IP_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: in std_logic;
		IP_PAYLOAD_EOF: in std_logic;
		IP_PAYLOAD_WORD_COUNT: in std_logic_vector(10 downto 0);    

		--// Partial checks (done in PACKET_PARSING common code)
        --// basic IP validity check
        IP_RX_FRAME_VALID: in std_logic; 
 			-- As the IP frame validity is checked on-the-fly, the user should always check if 
            -- the IP_RX_FRAME_VALID is high AT THE END of the IP payload frame (IP_PAYLOAD_EOF) to confirm that the 
            -- ENTIRE IP frame is valid. 
            -- IP frame validity checks include: 
            -- (a) protocol is IP
            -- (b) unicast or multicast destination IP address matches
            -- (c) correct IP header checksum (IPv4 only)
            -- (d) allowed IPv6
            -- (e) Ethernet frame is valid (correct FCS, dest address)
            -- Ready at IP_PAYLOAD_EOF 

		--// IP type, already parsed in PACKET_PARSING (shared code)
		RX_IPv4_6n: in std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
			-- This component responds to protocol 6 = TCP 
	  	RX_IP_PROTOCOL_RDY: in std_logic;
			-- 1 CLK wide pulse. 
			
		--// Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);

		--// TCP attributes, already parsed in PACKET_PARSING (shared code)
		-- BEWARE!!!!!!!! WE ALSO RECEIVE PACKETS NOT DESTINED FOR THIS SESSION (NOT FOR  THIS PORT)
		-- IT IS THE IMPLEMENTATION'S RESPONSIBILITY TO DISCARD DATA NOT DESTINED FOR THIS TCP PORT.
		VALID_TCP_CHECKSUM: in std_logic;
              -- '1' when valid TCP checksum(including pseudo-header). Read at IP_RX_EOF_D2 = IP_PAYLOAD_EOF_D
			
		--// RX TCP PAYLOAD -> EXTERNAL RX BUFFER 
		-- Latency: 1 CLK after the received IP payload frame.
		RX_DATA: out std_logic_vector(63 downto 0);
			-- TCP payload data field. Each byte validity is in RX_DATA_VALID(I)
			-- IMPORTANT: always left aligned (MSB first): RX_DATA_VALID is x80,xc0,xe0,xf0,....x01,x00 
		RX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- delineates the TCP payload data field
		RX_SOF: out std_logic;
			-- 1 CLK pulse indicating that RX_DATA is the first byte in the TCP data field.
		RX_TCP_STREAM_SEL_OUT: out std_logic_vector(NTCPSTREAMS-1 downto 0);
			-- output port based on the destination TCP port
		RX_EOF: out std_logic;
			-- 1 CLK pulse indicating that RX_DATA is the last byte in the TCP data field.
			-- ALWAYS CHECK RX_FRAME_VALID at the end of packet (RX_EOF = '1') to confirm
			-- that the TCP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid TCP packet.
			-- Reason: we only knows about bad TCP packets at the end.
		RX_FRAME_VALID: out std_logic;
			-- verify the entire frame validity at the end of frame (RX_EOF = '1')
		RX_FREE_SPACE: in SLV32xNTCPSTREAMStype;
			-- External buffer available space, expressed in bytes. 
			-- Information is updated upon receiving the EOF of a valid rx frame.
			-- The real-time available space is always larger

		--// OUTPUTS to TX PACKET ASSEMBLY (via TCP_TX.vhd component)
		TX_PACKET_SEQUENCE_START_OUT: out std_logic;	
			-- 1 CLK pulse to trigger packet transmission. The decision to transmit is taken by TCP_SERVER.
			-- From this trigger pulse to the end of frame, this component assembles and send data bytes
			-- like clockwork. 
			-- Note that the payload data has to be ready at exactly the right time to be appended.
			
		-- These variables are read only at the start of packet, when TX_PACKET_SEQUENCE_START_OUT = '1'
		-- They can change from packet to packet (internal code is memoryless).
		TX_DEST_MAC_ADDR_OUT: out std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_OUT: out std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_OUT: out std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_OUT: out std_logic_vector(15 downto 0);
		TX_IPv4_6n_OUT: out std_logic;
		TX_SEQ_NO_OUT: out std_logic_vector(31 downto 0);
		TX_ACK_NO_OUT: out std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_OUT: out std_logic_vector(15 downto 0);
		TX_FLAGS_OUT: out std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_OUT : out std_logic_vector(1 downto 0); 
			-- 0 = undefined
			-- 1 = SYN, no data, 24-byte header
			-- 2 = ACK, no data, 20-byte header
			-- 3 = payload data, 20-byte header
		TX_WINDOW_SCALE_OUT : out std_logic_vector(3 downto 0); 
			-- client-server negotiated window scaling

--		--// TX TCP layer -> Transmit MAC Interface
		MAC_TX_EOF: in std_logic;	-- need to know when packet tx is complete
		RTS: out std_logic := '0';
			-- '1' when a frame is ready to be sent (tell the COM5402 arbiter)
			-- When the MAC starts reading the output buffer, it is expected that it will be
			-- read until empty.

		--// EXTERNAL TX BUFFER <-> TX TCP layer
		-- upon receiving an ACK from the client, send rx window information to TXBUF for computing 
		-- the next packet size, boundaries, etc.
		-- Partial computation (rx window size + RX_TCP_ACK_NO).
		EFF_RX_WINDOW_SIZE_PARTIAL: out std_logic_vector(31 downto 0) := (others => '0');
			-- Explanation: EFF_RX_WINDOW_SIZE_PARTIAL represents the maximum TX_SEQ_NO acceptable for the 
			-- TCP client (beyond which the rx buffers would be overflowing)
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: out std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: out std_logic; -- 1 CLK-wide pulse to indicate that the above information is valid
		-- Let the TXBUF know where the next byte to be transmitted is located
		-- computing the next frame size, boundaries, etc
		TX_SEQ_NO: out SLV32xNTCPSTREAMStype := (others => (others => '0'));
		TX_SEQ_NO_JUMP: out std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
		      -- TX_SEQ_NO progresses regularly as new bytes are being transmitted, except when TX_SEQ_NO_JUMP(I) = '1'
		RX_TCP_ACK_NO_D: out SLV32xNTCPSTREAMStype := (others => (others => '0'));
			-- last acknowledged tx byte location


		CONNECTED_FLAG: out std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- '1' when TCP-IP connection is in the 'connected' state, 0 otherwise
			-- Main use: TXBUF should not store tx data until a connection is established
		MSS: in std_logic_vector(13 downto 0);
			-- The Maximum Segment Size (MSS) is the largest segment of TCP data that can be transmitted.
      -- Fixed as the Ethernet MTU (Maximum Transmission Unit) of 1500-9000 bytes - 40(IPv4) or -60(IPv6) overhead bytes 
		TX_STREAM_SEL: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise
		TX_PAYLOAD_RTS: in std_logic;
			-- '1' when at least one stream has payload data available for transmission.
		TX_PAYLOAD_SIZE: in std_logic_vector(15 downto 0);
		
	
		
		
		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_SERVER_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT TCP_RXOPTIONS_10G
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		RX_TCP_DATA_OFFSET: in std_logic_vector(3 downto 0);
		IP_PAYLOAD_DATA : IN std_logic_vector(63 downto 0);
		IP_PAYLOAD_WORD_VALID : IN std_logic;
		IP_PAYLOAD_WORD_COUNT : IN std_logic_vector(10 downto 0);          
		TCP_OPTION_MSS: out std_logic_vector(15 downto 0);
		TCP_OPTION_MSS_VALID: out std_logic;
		TCP_OPTION_WINDOW_SCALE: out std_logic_vector(3 downto 0);
		TCP_OPTION_WINDOW_SCALE_VALID: out std_logic;
		TCP_OPTION_SACK_PERMITTED: out std_logic;
		TCP_OPTION_SACK_PERMITTED_VALID: out std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates a one CLK early version of the net with the same name
-- Suffix _X indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

type SLV2xNTCPSTREAMSlocaltype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(1 downto 0);
type SLV4xNTCPSTREAMSlocaltype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(3 downto 0);
type SLV16xNTCPSTREAMSlocaltype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(15 downto 0);
type U2xNTCPSTREAMSlocaltype is array (integer range 0 to (NTCPSTREAMS-1)) of unsigned(1 downto 0);
type U8xNTCPSTREAMSlocaltype is array (integer range 0 to (NTCPSTREAMS-1)) of unsigned(7 downto 0);
type U32xNTCPSTREAMSlocaltype is array (integer range 0 to (NTCPSTREAMS-1)) of unsigned(31 downto 0);

--//===== COMMON ==========================================
signal TICK_CNTR: unsigned(3 downto 0) := "0000";
signal TICK_1S: std_logic := '0';

--//===== NON-VOLATILE PORT-SPECIFIC DATA ==================
-- (to be saved after a packet ends) 
-- state machine
type STATEtype is array (integer range 0 to (NTCPSTREAMS-1)) of integer range 0 to 15; -- (i.e. 4-bits)
signal TCP_STATE: STATEtype := (others => 0);
signal TIMER1: U8xNTCPSTREAMSlocaltype := (others => (others => '0'));	-- timer range 0 - 25.5s
signal CONNECTED_FLAG_local: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
-- keep-alive timer
signal TIMER2: U8xNTCPSTREAMSlocaltype := (others => (others => '0'));	-- timer range 0 - 255s
signal TIMER2_D: U8xNTCPSTREAMSlocaltype := (others => (others => '0'));	-- timer range 0 - 255s
signal KASTATE: U2xNTCPSTREAMSlocaltype:= (others => (others => '0'));	-- keep alive state
-- zero-window probe timer
signal ZWS: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal TIMER3: U8xNTCPSTREAMSlocaltype := (others => (others => '0'));	-- timer range 0 - 25.5s
constant ZERO_WINDOW_PROBE_PERIOD: integer := 3;	-- first interval to send zero-window probe (in 100ms units)
signal ZWP_STATE: U4xNTCPSTREAMStype:= (others => (others => '0'));	-- zero-window probe state
signal ZWP_TRIGGER: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');

-- relevant transmit destination information
type MAC_ADDRtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(47 downto 0);
type IP_ADDRtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(127 downto 0);
signal TX_DEST_MAC_ADDR: MAC_ADDRtype := (others => (others => '0'));
signal TX_DEST_IP_ADDR: IP_ADDRtype := (others => (others => '0'));
signal TX_DEST_PORT_NO: SLV16xNTCPSTREAMSlocaltype := (others => (others => '0'));
-- tx sequence numbers
signal TX_SEQ_NO_INIT: unsigned(31 downto 0) := (others => '0');
signal TX_ACK_NO: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal TX_ACK_NO2: unsigned(31 downto 0) := (others => '0');
signal TX_SEQ_NO_local: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal TX_SEQ_NO_OUT_local: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal FAST_REXMIT_SEQ_NO_START: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal FAST_REXMIT_SEQ_NO_END: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
-- received sequence number
signal RX_TCP_ACK_NO_D_local: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal RX_TCP_SEQ_NO_MAX: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal RX_TCP_SEQ_NO_MIN: U32xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal RX_TCP_SEQ_NO_MAX2: unsigned(31 downto 0) := (others => '0');
signal RX_TCP_SEQ_NO_MIN2: unsigned(31 downto 0) := (others => '0');
signal TX_IPv4_6n: std_logic_vector((NTCPSTREAMS-1) downto 0);
signal TX_PACKET_TYPE_QUEUED: SLV2xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal TX_PACKET_TYPE: std_logic_vector(1 downto 0) := "00";
signal TX_FLAGS: SLV8xNTCPSTREAMStype := (others => (others => '0'));


--//==== VARIABLES WITH A 1 PACKET LIFESPAN ==================
signal IP_PAYLOAD_WORD_VALID: std_logic := '0';

---- PARSE TCP HEADER     ------------------
signal RX_SOURCE_TCP_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal RX_DEST_TCP_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal RX_TCP_SEQ_NO: unsigned(31 downto 0) := (others => '0');
signal RX_TCP_ACK_NO: unsigned(31 downto 0) := (others => '0');
signal RX_TCP_DATA_OFFSET: std_logic_vector(3 downto 0) := (others => '0');
signal RX_TCP_DATA_OFFSET_INC: unsigned(3 downto 0) := (others => '0');
signal RX_TCP_DATA_OFFSET_DIV2_INC: unsigned(3 downto 0) := (others => '0');
signal RX_TCP_FLAGS: std_logic_vector(7 downto 0)  := (others => '0');
signal RX_TCP_WINDOW_SIZE_SCALED: std_logic_vector(15 downto 0) := (others => '0');
signal RX_TCP_WINDOW_SIZE: unsigned(31 downto 0) := (others => '0');
signal TCP_RXOPTIONS_RESET: std_logic := '0';
signal TCP_OPTION_MSS: std_logic_vector(15 downto 0) := (others => '0');
signal TCP_OPTION_WINDOW_SCALE: std_logic_vector(3 downto 0) := (others => '0');
signal TCP_OPTION_WINDOW_SCALE_VALID: std_logic := '0';
signal TCP_OPTION_SACK_PERMITTED: std_logic := '0';

---- TCP stream identification ------------------
signal RX_TCP_STREAM_SEL: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
signal RX_TCP_STREAM_SEL_D: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
signal IP_PAYLOAD_EOF_D: std_logic := '0';
signal VALID_RX_TCP0: std_logic := '0';
signal VALID_RX_TCP_ALL: std_logic := '0';

--// COPY RX TCP DATA TO BUFFER 
signal TCP_PAYLOAD_FLAG: std_logic := '0';
signal TCP_SOF_FLAG: std_logic := '0';
signal RX_TCP_NON_ZERO_DATA_LENGTH: std_logic := '0';
signal IP_PAYLOAD_SOF_D: std_logic := '0';
signal IP_PAYLOAD_SOF_D2: std_logic := '0';
signal RX_DATA_VALID_local: std_logic_vector(7 downto 0) := (others => '0');
signal RX_SOF_local: std_logic := '0';
signal RX_EOF_local: std_logic := '0';
signal RX_EOF_D: std_logic := '0';
signal RX_FRAME_VALID_local: std_logic := '0';

--// RX SEQUENCE NUMBER 
signal RX_TCP_SEQ_NO_INC: unsigned(31 downto 0) := (others => '0');
signal RX_TCP_SEQ_NO_TRACK: unsigned(31 downto 0) := (others => '0');
signal RX_TCP_SEQ_NO_INCREMENT: integer range 0 to 8 := 0;
signal RX_OUTOFBOUND: std_logic := '0';
signal RX_ZERO_WINDOW_PROBE: std_logic := '0';
signal GAP_IN_RX_SEQ: std_logic := '0';
signal RETRANSMIT_FLAG: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal TX_SEQ_NO_JUMP_local: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal RX_VALID_ACK_TIMOUT: U24xNTCPSTREAMStype;

--// state machine
signal TCP_STATE_localrx: integer range 0 to 15 := 0;
signal EVENTS2: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS4: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS4A: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS4B: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS4C: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS5: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS7: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS10: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS11: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS12: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENT1: std_logic:= '0';
signal EVENT2: std_logic:= '0';
signal EVENT4: std_logic:= '0';
signal EVENT4A: std_logic:= '0';
signal EVENT4B: std_logic:= '0';
signal EVENT6: std_logic:= '0';
signal EVENT8: std_logic:= '0';

----// ACK generation
signal SEND_ACK_NOW: std_logic:= '0';
signal DUPLICATE_RX_TCP_ACK_CNTR: U2xNTCPSTREAMSlocaltype := (others => (others => '0'));

-- Keep-Alive probe sequence detection
signal KA_PROBE_DET: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');

--// relevant transmit destination information
constant TX_ACK_WINDOW_LENGTH_MARGIN  : integer := 32;
signal ORIGINATOR_IDENTIFIED: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal RX_BUF_FULL: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal RX_BUF_1MSSFREE: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal TX_ACK_WINDOW_LENGTH: unsigned(31 downto 0) := (others => '0');
signal TX_ACK_WINDOW_LENGTH_SCALED: unsigned(15 downto 0) := (others => '0');
signal RX_WINDOW_RESIZE_STATE: SLV2xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal RX_WINDOW_SCALE: SLV4xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal TX_WINDOW_SCALE: SLV4xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal SEND_RX_WINDOW_RESIZE: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal RX_WINDOW_RESIZE2_STATE: SLV2xNTCPSTREAMSlocaltype := (others => (others => '0'));
signal SEND_RX_WINDOW_RESIZE2: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');

--// Measure round-trip delay: client -> server -> client
signal TXRX_DELAY_CNTR: U24xNTCPSTREAMStype := (others => (others => '0'));
signal TXRX_DELAY: U24xNTCPSTREAMStype := (others => (others => '0'));
signal TXRX_DELAY_STATE: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');


--// transmit packet assembly
signal TCP_ISN: unsigned(31 downto 0) := x"010ae614";
signal TCP_ISN_D: unsigned(31 downto 0) := x"010ae614";
constant TX_TCP_RTS: std_logic := '0';  -- temp

-- TCP transmit flow control -------------------
signal EFF_RX_WINDOW_SIZE_PARTIAL_local: unsigned(31 downto 0) := (others => '0');
signal EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local: std_logic := '0';

--//---- TX PACKET ASSEMBLY   
signal TCP_CONGESTION_WINDOW: U32xNTCPSTREAMStype;
signal TCP_TX_SLOW_START: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal NEXT_TX_TCP_FRAME_QUEUED: std_logic := '0';
signal NEXT_TX_TCP_STREAM_SEL: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal TX_TCP_STREAM_SEL: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal RTS_local: std_logic := '0';
signal TX_PACKET_SEQUENCE_START: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

TICK_1S_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(TICK_100MS = '1') then
			if(TICK_CNTR = 9) then
				TICK_CNTR <= (others => '0');
				TICK_1S <= '1';
			else
				TICK_CNTR <= TICK_CNTR + 1;
				TICK_1S <= '0';
			end if;
		else
			TICK_1S <= '0';
		end if;
	end if;
end process;

-------------------------------------------------
---- PARSE TCP HEADER     ------------------
-------------------------------------------------
IP_PAYLOAD_WORD_VALID <= '1' when (unsigned(IP_PAYLOAD_DATA_VALID) /= 0) else '0';

-- These fields are read at the first IP payload word
-- Available at IP_PAYLOAD_SOF_D
TCP_DECODE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
		-- TODO reset after end of frame
			RX_SOURCE_TCP_PORT_NO <= (others => '0');
			RX_DEST_TCP_PORT_NO <= (others => '0');
			RX_TCP_SEQ_NO <= (others => '0');
		elsif(IP_PAYLOAD_SOF = '1') then
			RX_SOURCE_TCP_PORT_NO <= IP_PAYLOAD_DATA(63 downto 48);
			RX_DEST_TCP_PORT_NO <= IP_PAYLOAD_DATA(47 downto 32);
			RX_TCP_SEQ_NO <= unsigned(IP_PAYLOAD_DATA(31 downto 0));
		end if;
    end if;
end process;

-- These fields are available at the second IP payload word
TCP_DECODE_002: process(CLK)
variable RX_TCP_WINDOW_SIZE_SCALEDv: unsigned(15 downto 0);
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
		-- TODO reset after end of frame for cleaner code
			RX_TCP_ACK_NO <= (others => '0');
			RX_TCP_DATA_OFFSET <= (others => '0');
			RX_TCP_FLAGS <= (others => '0');
			RX_TCP_WINDOW_SIZE_SCALED <= (others => '0');
			RX_TCP_WINDOW_SIZE <= (others => '0');
		elsif(IP_PAYLOAD_WORD_VALID = '1') and (unsigned(IP_PAYLOAD_WORD_COUNT) = 2) then
			RX_TCP_ACK_NO <= unsigned(IP_PAYLOAD_DATA(63 downto 32));
			RX_TCP_DATA_OFFSET <= IP_PAYLOAD_DATA(31 downto 28);
			RX_TCP_FLAGS <= IP_PAYLOAD_DATA(23 downto 16);
                -- TCP flags (MSb) CWR/ECE/URG/ACK/PSH/RST/SYN/FIN (LSb)
			RX_TCP_WINDOW_SIZE_SCALED <= IP_PAYLOAD_DATA(15 downto 0);
			RX_TCP_WINDOW_SIZE_SCALEDv := unsigned(IP_PAYLOAD_DATA(15 downto 0));

			if(WINDOW_SCALING_ENABLED = '1') then
				-- optimized out when window scaling is disabled (i.e. tx/rx buffers <= 64kB)
				-- restore the full 32-bit RX_TCP_WINDOW_SIZE
				for I in 0 to (NTCPSTREAMS-1) loop
					if	(RX_TCP_STREAM_SEL(I) = '1') then
						-- window scaling (buffer sizes ranging from 256 to 1MB)
						case RX_WINDOW_SCALE(I) is	-- valid range 0 - 14
							when "0000" => 
								RX_TCP_WINDOW_SIZE(31 downto 16) <= (others => '0');
								RX_TCP_WINDOW_SIZE(15 downto 0) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 64kB
							when "0001" => 
								RX_TCP_WINDOW_SIZE(31 downto 17) <= (others => '0');
								RX_TCP_WINDOW_SIZE(16 downto 1) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 128kB
								RX_TCP_WINDOW_SIZE(0 downto 0) <= (others => '0');
							when "0010" => 
								RX_TCP_WINDOW_SIZE(31 downto 18) <= (others => '0');
								RX_TCP_WINDOW_SIZE(17 downto 2) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 256kB
								RX_TCP_WINDOW_SIZE(1 downto 0) <= (others => '0');
							when "0011" => 
								RX_TCP_WINDOW_SIZE(31 downto 19) <= (others => '0');
								RX_TCP_WINDOW_SIZE(18 downto 3) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 512kB
								RX_TCP_WINDOW_SIZE(2 downto 0) <= (others => '0');
							when "0100" => 
								RX_TCP_WINDOW_SIZE(31 downto 20) <= (others => '0');
								RX_TCP_WINDOW_SIZE(19 downto 4) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 1MB
								RX_TCP_WINDOW_SIZE(3 downto 0) <= (others => '0');
							when "0101" => 
								RX_TCP_WINDOW_SIZE(31 downto 21) <= (others => '0');
								RX_TCP_WINDOW_SIZE(20 downto 5) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 2MB
								RX_TCP_WINDOW_SIZE(4 downto 0) <= (others => '0');
							when "0110" => 
								RX_TCP_WINDOW_SIZE(31 downto 22) <= (others => '0');
								RX_TCP_WINDOW_SIZE(21 downto 6) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 4MB
								RX_TCP_WINDOW_SIZE(5 downto 0) <= (others => '0');
							when "0111" => 
								RX_TCP_WINDOW_SIZE(31 downto 23) <= (others => '0');
								RX_TCP_WINDOW_SIZE(22 downto 7) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 8MB
								RX_TCP_WINDOW_SIZE(6 downto 0) <= (others => '0');
							when "1000" => 
								RX_TCP_WINDOW_SIZE(31 downto 24) <= (others => '0');
								RX_TCP_WINDOW_SIZE(23 downto 8) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 16MB
								RX_TCP_WINDOW_SIZE(7 downto 0) <= (others => '0');
							when "1001" => 
								RX_TCP_WINDOW_SIZE(31 downto 25) <= (others => '0');
								RX_TCP_WINDOW_SIZE(24 downto 9) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 32MkB
								RX_TCP_WINDOW_SIZE(8 downto 0) <= (others => '0');
							when "1010" => 
								RX_TCP_WINDOW_SIZE(31 downto 26) <= (others => '0');
								RX_TCP_WINDOW_SIZE(25 downto 10) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 64MB
								RX_TCP_WINDOW_SIZE(9 downto 0) <= (others => '0');
							when "1011" => 
								RX_TCP_WINDOW_SIZE(31 downto 27) <= (others => '0');
								RX_TCP_WINDOW_SIZE(26 downto 11) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 128MB
								RX_TCP_WINDOW_SIZE(10 downto 0) <= (others => '0');
							when "1100" => 
								RX_TCP_WINDOW_SIZE(31 downto 28) <= (others => '0');
								RX_TCP_WINDOW_SIZE(27 downto 12) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 256MB
								RX_TCP_WINDOW_SIZE(11 downto 0) <= (others => '0');
							when "1101" => 
								RX_TCP_WINDOW_SIZE(31 downto 29) <= (others => '0');
								RX_TCP_WINDOW_SIZE(28 downto 13) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 512MB
								RX_TCP_WINDOW_SIZE(12 downto 0) <= (others => '0');
							when others => 
								RX_TCP_WINDOW_SIZE(31 downto 30) <= (others => '0');
								RX_TCP_WINDOW_SIZE(29 downto 14) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 1GB
								RX_TCP_WINDOW_SIZE(13 downto 0) <= (others => '0');
						end case;
					end if;
				end loop;
			else
				-- window scaling is disabled (i.e. tx/rx buffers <= 64kB)
				RX_TCP_WINDOW_SIZE(31 downto 16) <= (others => '0');
				RX_TCP_WINDOW_SIZE(15 downto 0) <= RX_TCP_WINDOW_SIZE_SCALEDv;	-- <= 64kB
			end if;
		end if;
    end if;
end process;
RX_TCP_DATA_OFFSET_INC <= unsigned(RX_TCP_DATA_OFFSET) + 1;
RX_TCP_DATA_OFFSET_DIV2_INC <= resize(unsigned(RX_TCP_DATA_OFFSET(3 downto 1)),4) + 1;

-- decode TCP options
TCP_RXOPTIONS_RESET <= SYNC_RESET or (not VALID_RX_TCP0) or IP_PAYLOAD_SOF;	
	-- only applies to TCP protocol
	-- clear decoded options at start of IP payload
-- Read options at EVENT1 (= SYN message, IP_PAYLOAD_EOF_D)
TCP_DECODE_003: TCP_RXOPTIONS_10G 
port map(
	CLK => CLK,
	SYNC_RESET => TCP_RXOPTIONS_RESET,
	RX_TCP_DATA_OFFSET => RX_TCP_DATA_OFFSET,
	IP_PAYLOAD_DATA => IP_PAYLOAD_DATA,
	IP_PAYLOAD_WORD_VALID => IP_PAYLOAD_WORD_VALID,
	IP_PAYLOAD_WORD_COUNT => IP_PAYLOAD_WORD_COUNT,
	TCP_OPTION_MSS => TCP_OPTION_MSS,	-- currently unused
	TCP_OPTION_MSS_VALID => open,
	TCP_OPTION_WINDOW_SCALE => TCP_OPTION_WINDOW_SCALE,	-- window scale requested by client
	TCP_OPTION_WINDOW_SCALE_VALID => TCP_OPTION_WINDOW_SCALE_VALID,
	TCP_OPTION_SACK_PERMITTED => TCP_OPTION_SACK_PERMITTED,	-- currently unused
	TCP_OPTION_SACK_PERMITTED_VALID => open,
	TP => open
);

-- negotiate TCP_OPTION_WINDOW_SCALE for the stream being received
-- enable rx window scale if (1) we received the window scale option and 
-- (2) we plan to request the window scale option because our rx or/and tx buffers are > 64KB
TCP_DECODE_004: for I in 0 to NTCPSTREAMS-1 generate
TCP_DECODE_004x: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_WINDOW_SCALE(I) <= x"0";
			TX_WINDOW_SCALE(I) <= x"0";
		elsif(RX_TCP_STREAM_SEL_D(I) = '1') and (TCP_STATE(I) = 0)  and (EVENT1 = '1') then
			-- LISTEN
			-- Received valid SYN
			if(WINDOW_SCALING_ENABLED = '0') or (TCP_OPTION_WINDOW_SCALE_VALID = '0') then
				-- we did not receive a window scale option in the SYN message, or
				-- we do not need window scaling because our tx/rx buffers are both < 64KB
				RX_WINDOW_SCALE(I) <= x"0";
				TX_WINDOW_SCALE(I) <= x"0";
			else
				RX_WINDOW_SCALE(I) <= std_logic_vector(TCP_OPTION_WINDOW_SCALE);
				TX_WINDOW_SCALE(I) <= std_logic_vector(to_unsigned(TCP_MAX_WINDOW_SIZE-16,4));
			end if;
		end if;
	end if;
end process;
end generate;
		

-------------------------------------------------
---- TCP stream identification ------------------
-------------------------------------------------
-- Identify the stream based on the destination tcp port for each 
-- incoming frame.
-- ready at IP_PAYLOAD_SOF_D
STREAM_INDEX_001: process(RX_DEST_TCP_PORT_NO, TCP_LOCAL_PORTS)
begin
	for I in 0 to (NTCPSTREAMS-1) loop
		if(RX_DEST_TCP_PORT_NO  = TCP_LOCAL_PORTS(I)) then
		    RX_TCP_STREAM_SEL(I) <= '1';
		else
		    RX_TCP_STREAM_SEL(I) <= '0';
		end if;
	end loop;
end process;

-- reclock for better timing
-- ready at IP_PAYLOAD_SOF_D2
STREAM_INDEX_002: process(CLK)
begin
	if rising_edge(CLK) then
	   RX_TCP_STREAM_SEL_D <= RX_TCP_STREAM_SEL;
	end if;
end process;

-- Demux key fields based on the current rx stream
DEMUX_001: process(RX_TCP_STREAM_SEL, RX_TCP_SEQ_NO_MAX, RX_TCP_SEQ_NO_MIN)
variable MAX2: unsigned(31 downto 0);
variable MIN2: unsigned(31 downto 0);
begin
	MAX2 := (others => '0');
	MIN2 := (others => '0');
	for I in 0 to (NTCPSTREAMS-1) loop
		if (RX_TCP_STREAM_SEL(I) = '1') then
			MAX2 := RX_TCP_SEQ_NO_MAX(I);
			MIN2 := RX_TCP_SEQ_NO_MIN(I);
		end if;
	end loop;
	RX_TCP_SEQ_NO_MAX2 <= MAX2;
	RX_TCP_SEQ_NO_MIN2 <= MIN2;
end process;

DEMUX_002: process(CLK)
begin
	if rising_edge(CLK) then
		for I in 0 to NTCPSTREAMS-1 loop
			 if(RX_TCP_STREAM_SEL(I) = '1') then  -- DCC mod *031720
				 TX_ACK_NO2 <= unsigned(TX_ACK_NO(I));
			 end if;
		end loop;
	end if;
end process;

-------------------------------------------------
---- Collect response information ---------------
-------------------------------------------------
-- save destination IP, destination port and other relevant information
-- upon receiving SYN. The information will be kept until the connection is closed.
-- valid at IP_PAYLOAD_EOF_D2
INFO_X: for I in 0 to (NTCPSTREAMS-1) generate
	INFO_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(RX_TCP_STREAM_SEL(I) = '1') and (TCP_STATE(I) = 0) and (EVENT1 = '1') then
				-- Received valid SYN while in LISTEN state
				-- Save the destination addresses during the connection
				TX_DEST_MAC_ADDR(I) <= RX_SOURCE_MAC_ADDR;	
				TX_DEST_IP_ADDR(I) <= RX_SOURCE_IP_ADDR;	
				TX_DEST_PORT_NO(I) <= RX_SOURCE_TCP_PORT_NO;	
				TX_IPv4_6n(I) <= RX_IPv4_6n;
			end if;
		end if;
	end process;
end generate;

-- After the initial SYN message where the originator identification characteristics
-- are collected (MAC/IP/PORT), the origination of subsequent messages addressed 
-- to this IP/Port is verified. (we don't want a third party to crash our connection
-- by sending RST or other disrupting messages.
-- Information is valid at the end of the TCP header until the next received packet.
-- Valid at IP_PAYLOAD_SOF_D2
ORIGIN_001: process(CLK) 
begin
	if rising_edge(CLK) then
		for I in 0 to (NTCPSTREAMS-1) loop
			if(TX_DEST_MAC_ADDR(I) = RX_SOURCE_MAC_ADDR) and 
				(TX_DEST_IP_ADDR(I) = RX_SOURCE_IP_ADDR) and 
				(TX_DEST_PORT_NO(I) = RX_SOURCE_TCP_PORT_NO)  then
				ORIGINATOR_IDENTIFIED(I) <= '1';
			else
				ORIGINATOR_IDENTIFIED(I) <= '0';
			end if;
		end loop;
	end if;
end process;

---------------------------------------------------
------ State Machine / Events ---------------------
---------------------------------------------------
-- independent state machine for each server
TCP_STATE_X: for I in 0 to (NTCPSTREAMS-1) generate

	-- EVENTS2(I)
	-- End of TCP segment transmission. Exclude the end of data frames. 
	EVENTS2(I) <= '1' when (TX_TCP_STREAM_SEL(I) = '1') and (MAC_TX_EOF = '1') and (TX_PACKET_TYPE = "10") else '0';

	-- EVENTS4(I): received valid ACK flag and ACK number from the connection client. Wait until the end of frame to confirm validity.
	EVENTS4(I) <= EVENTS12(I) when (RX_TCP_FLAGS(4) = '1') else '0';
	-- Events 4A: received valid non-duplicate ACK (a subset of EVENTS4)
	EVENTS4A(I) <= EVENTS4(I) when (RX_TCP_ACK_NO_D_local(I) /= RX_TCP_ACK_NO) else '0';
	-- Events 4B: received valid duplicate ACK (a subset of EVENTS4)
	EVENTS4B(I) <= EVENTS4(I) when (RX_TCP_ACK_NO_D_local(I) = RX_TCP_ACK_NO) else '0';
	-- Events 4C: received expected ACK number = previous transmit sequence number + 1 or payload length
	-- deleted: too narrow a definition, we may already have started transmitting data to client.
	--EVENTS4C(I) <= EVENTS4(I) when (TX_SEQ_NO_local(I)(15 downto 0) = RX_TCP_ACK_NO(15 downto 0)) else '0';

	-- EVENTS5(I)
	-- Received valid FIN flag from expected server. Wait until the end of frame to confirm validity.
	EVENTS5(I) <= '1' when (EVENTS12(I) = '1') and (RX_TCP_FLAGS(0) = '1') else '0';

	-- EVENTS7(I)
	-- Received valid RST flag from the connection server
	EVENTS7(I) <= EVENTS12(I)  when  (RX_TCP_FLAGS(2) = '1') else '0';
						
	-- EVENTS10(I)
	-- Window resizing (receive flow control), no segment to transmit. The receive buffer is no 
	-- longer empty. Send a single ACK with a non-zero window.
	EVENTS10(I) <= '1' when (((SEND_RX_WINDOW_RESIZE(I) = '1') or (SEND_RX_WINDOW_RESIZE2(I) = '1')) and (TX_TCP_RTS = '0')) else '0';

	-- EVENTS11(I)
	-- keep-alive or zero-window check: RFC: "send a probe segment designed to elicit a response from the
	-- peer TCP.  Such a segment generally contains SEG.SEQ = SND.NXT-1
	EVENTS11(I) <= '1' when ((TCP_KEEPALIVE_EN(I) = '1') and (TIMER2_D(I) /= 0) and (TIMER2(I) = 0) and (TX_TCP_RTS = '0')) else 
						ZWP_TRIGGER(I);

	-- EVENTS12(I)
	-- Receiving a valid TCP frame or ACK for stream I from expected client
	EVENTS12(I) <= '1' when (IP_PAYLOAD_EOF_D = '1') and (RX_TCP_STREAM_SEL_D(I) = '1') and (VALID_RX_TCP_ALL = '1') and (ORIGINATOR_IDENTIFIED(I) = '1') else '0';
	
	-- Note: removed state 2 because in the SYN/SYN ACK/ACK sequence
	-- if the ACK and only the ACK is dropped, the connection becomes established. If more things are dropped, there is a reset.
	TCP_STATE_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				-- reset all connections (abrupt, may cause server side to remain connected, thus preventing any further connection on that port)
				TCP_STATE(I) <= 0;
			elsif(CONNECTED_FLAG_local(I) = '1') and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected
				TCP_STATE(I) <= 6;	-- send FIN
			elsif(CONNECTED_FLAG_local(I) = '1') and (TCP_KEEPALIVE_EN(I) = '1') and (KASTATE(I) = 0) then
				-- failed keepalive. Automatic disconnect.
				TCP_STATE(I) <= 6;	-- send FIN

			-- rx-related events
			elsif(EVENTS7(I) = '1') then
				-- Reset / Abort (true in any state, as long as we verify the originator)
				-- received RST
				TCP_STATE(I) <= 0;
			elsif(RX_TCP_STREAM_SEL_D(I) = '1') and (TCP_STATE(I) = 0)  and (EVENT1 = '1') then
				-- LISTEN
				-- Received valid SYN
				TCP_STATE(I) <= 1;	-- SYN_RCVD. Transmitting SYN,ACK in progress
--			elsif(TCP_STATE(I) = 2) and (EVENTS4C(I) = '1') then	-- too narrow a definition. We may already have sent data to client. ack number is not just +1
			elsif(TCP_STATE(I) = 2) and (EVENTS4(I) = '1') then
				-- CONNECTION ESTABLISHMENT: Await ACK from client
				-- received valid ACK and ACK number
				TCP_STATE(I) <= 3;	-- CONNECTED state
			elsif(CONNECTED_FLAG_local(I) = '1') and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . Send ACK
				TCP_STATE(I) <= 4;	-- sending ACK
			elsif (TCP_STATE(I) = 7) and (EVENTS5(I) = '1') then
				-- received FIN after FIN. Send final ACK.
				TCP_STATE(I) <= 8;	
			elsif (TCP_STATE(I) = 5) and (EVENTS4(I) = '1') then	
				-- received final ACK after FIN/ACK+FIN. Connection is properly closed.
				TCP_STATE(I) <= 0;	
			

			-- tx-related events (end of transmission)
			elsif (TCP_STATE(I) = 6) and (EVENTS2(I) = '1') and (TX_FLAGS(I)(0) = '1') then
				-- sent FIN. Awaiting ACK + FIN
				TCP_STATE(I) <= 7;	
			elsif (TCP_STATE(I) = 8) and (EVENTS2(I) = '1') and (TX_FLAGS(I)(4) = '1') then
				-- Sent final ACK. Connection is properly closed
				TCP_STATE(I) <= 0;
			elsif (TCP_STATE(I) = 4) and (EVENTS2(I) = '1') and (TX_FLAGS(I)(4) = '1') then
				-- sent ACK after receiving FIN. send final FIN. Await final ack.
				TCP_STATE(I) <= 5;	
			elsif(TX_TCP_STREAM_SEL(I) = '1') and (TCP_STATE(I) = 1) and (EVENT2 = '1') then 
				-- Sent SYN/ACK. Awaiting ACK (not essential). 
				TCP_STATE(I) <= 2;	-- CONNECTED state
--			elsif(TX_TCP_STREAM_SEL(I) = '1') and (TCP_STATE(I) = 4) and (EVENT2 = '1') then
--				-- CONNECTION TERMINATION: await end of ACK transmission
--				-- completed ACK transmission
--				TCP_STATE(I) <= 5;	-- await end of FIN/ACK transmission
--			elsif(TX_TCP_STREAM_SEL(I) = '1') and (TCP_STATE(I) = 5) and (EVENT2 = '1') then
--				-- CONNECTION TERMINATION: await end of FIN/ACK transmission
--				-- completed FIN/ACK transmission
--				-- don't wait for an ACK from client (race condition: next connection SYN could arrive first)
--				TCP_STATE(I) <= 0;	-- LISTEN STATE
				
			-- timeouts
			elsif ((TCP_STATE(I) = 6) or (TCP_STATE(I) = 7) or (TCP_STATE(I) = 8)) and (TIMER1(I)= 0) then
				-- timeout waiting for normal server-originated connection termination. Abnormal connection termination.
				TCP_STATE(I) <= 0;
			elsif ((TCP_STATE(I) = 4) or (TCP_STATE(I) = 5)) and (TIMER1(I)= 0) then
				-- timeout waiting for normal client-originated connection termination. Abnormal connection termination.
				TCP_STATE(I) <= 0;
				
			end if;
		end if;
	end process;

	--// TCP-IP connection status
	-- report TCP-IP connection status to TCP_TXBUF
	CONNECTED_FLAG_local(I) <= '1' when (TCP_STATE(I) = 3) or (TCP_STATE(I) = 2) else '0';	-- *120218
	CONNECTED_FLAG(I) <= CONNECTED_FLAG_local(I);

	-- state machine timer (so that we do not get stuck into a state)
	TIMER1_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				-- reset all connections (abrupt, may cause server side to remain connected, thus preventing any further connection on that port)
				-- idle state, clear timer to 'expired' (0)
				TIMER1(I) <= (others => '0');
			elsif(CONNECTED_FLAG_local(I) = '1') and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected
				TIMER1(I) <= to_unsigned(20, TIMER1(I)'length);
			elsif(CONNECTED_FLAG_local(I) = '1') and (TCP_KEEPALIVE_EN(I) = '1') and (KASTATE(I) = 0) then
				-- failed keepalive. Disconnect.
				TIMER1(I) <= to_unsigned(20, TIMER1(I)'length);
			elsif (CONNECTED_FLAG_local(I) = '1') and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . 
				TIMER1(I) <= to_unsigned(20, TIMER1(I)'length);
			elsif(TCP_STATE(I) = 0) then
				-- idle state, clear timer to 'expired' (0)
				TIMER1(I) <= (others => '0');
			elsif(TICK_100MS = '1') and (TIMER1(I) /= 0) then
				-- decrement until timer has expired (0)
				TIMER1(I) <= TIMER1(I) - 1;
			end if;
		end if;
	end process;

end generate;

-- contextual TCP_STATE while receiving a frame
RX_TCP_STATE_GEN: process(RX_TCP_STREAM_SEL, TCP_STATE)
variable TCP_STATEv: integer;
begin  
    TCP_STATEv := 0; 
	for I in 0 to (NTCPSTREAMS-1) loop
	   if(RX_TCP_STREAM_SEL(I) = '1') then
	       TCP_STATEv := TCP_STATE(I);
	   end if;
    end loop;
    TCP_STATE_localrx <= TCP_STATEv;
end process; 
	

-- keep-alive timer
-- Send zero-data length keep alive message when TIMER2 = 0
-- TIMER2 is expressed in 1s units
TIMER2_GEN_X: for I in 0 to (NTCPSTREAMS-1) generate
	TIMER2_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			TIMER2_D(I) <= TIMER2(I);

			if(SYNC_RESET = '1') or (TCP_STATE(I) /= 3) or (TCP_KEEPALIVE_EN(I) = '0') then
				-- reset or not connected state or keepalive not enabled
				TIMER2(I) <= to_unsigned(TCP_KEEPALIVE_PERIOD, TIMER2(I)'length);
			elsif(EVENTS12(I) = '1') then
				-- received data or ACK from client I. re-arm keepalive timer
				TIMER2(I) <= to_unsigned(TCP_KEEPALIVE_PERIOD, TIMER2(I)'length);
			elsif(NEXT_TX_TCP_STREAM_SEL(I) = '1') and (NEXT_TX_TCP_FRAME_QUEUED = '1') and (RTS_local = '0') then
				-- sending a frame to client. re-arm keepalive timer
				TIMER2(I) <= to_unsigned(TCP_KEEPALIVE_PERIOD, TIMER2(I)'length);
			elsif((TICK_1S = '1') and (TIMER2(I) /= 0)) then
				-- decrement until timer has expired (0)
				TIMER2(I) <= TIMER2(I) - 1;
			end if;
		end if;
	end process;

-- detect broken connection: keepalive message sent, ack or no ack received
-- Algo: set KASTATE to 3 when receiving ACK, decrement every timeout. Broken link when 0
	TIMER2_GEN_002: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') or (TCP_STATE(I) /= 3) or (TCP_KEEPALIVE_EN(I) = '0') then
				-- reset or not connected state or keepalive not enabled
				KASTATE(I) <= "11";	-- awaiting ACK from client
			elsif(EVENTS12(I) = '1') then
				-- received data or ACK from client I
				KASTATE(I) <= "11";
			elsif((TICK_1S = '1') and (TIMER2(I) = 1))  then
				-- keepalive timeout. Send a probe with no data				
				if(KASTATE(I) /= 0) then
					KASTATE(I) <= KASTATE(I) - 1;
				end if;
			end if;
		end if;
	end process;
end generate;
-- connection status in KASTATE(I)(1)
				
--// zero-window probe timer
-- Keep track of zero-window sizes (yes/no) reported by the other side of the TCP connection
-- Available at IP_PAYLOAD_EOF_D2
ZWS_GEN_X: for I in 0 to (NTCPSTREAMS-1) generate
	ZWS_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') or (TCP_STATE(I) /= 3) then
				ZWS(I) <= '0';
			elsif(EVENTS4(I) = '1') then 
				-- Valid ACK received for stream RX_TCP_STREAM_SEL_D 
				if(unsigned(RX_TCP_WINDOW_SIZE_SCALED) = 0) then
					ZWS(I) <= '1';
				else
					ZWS(I) <= '0';
				end if;
			end if;
		end if;
	end process;

	-- Send zero-window probe message when TIMER3 = 0
	-- TIMER3 is expressed in 100ms units
	-- ZERO_WINDOW_PROBE_PERIOD = minimum interval to send zero-window probe (in 100ms units)
	TIMER3_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') or (TCP_STATE(I) /= 3) or (ZWS(I) = '0')then
				-- reset or not connected state or keepalive not enabled
				TIMER3(I) <= to_unsigned(ZERO_WINDOW_PROBE_PERIOD, TIMER3(I)'length);
			elsif((TICK_100MS = '1') and (TIMER3(I) = 0) and (ZWP_STATE(I)(3) = '0')) then
				-- timer3 expired (0) => send zero-window probe. 
				-- Re-arm timer3. Increase period between successive zero-window probes.
				case ZWP_STATE(I) is
					when "0000" => TIMER3(I) <= to_unsigned(ZERO_WINDOW_PROBE_PERIOD, TIMER3(I)'length);	-- 0.3s
					when "0001" => TIMER3(I) <= to_unsigned(2*ZERO_WINDOW_PROBE_PERIOD, TIMER3(I)'length);-- 0.6s
					when "0010" => TIMER3(I) <= to_unsigned(4*ZERO_WINDOW_PROBE_PERIOD, TIMER3(I)'length);-- 1.2s
					when "0011" => TIMER3(I) <= to_unsigned(8*ZERO_WINDOW_PROBE_PERIOD, TIMER3(I)'length);-- 2.4s
					when others => TIMER3(I) <= to_unsigned(16*ZERO_WINDOW_PROBE_PERIOD, TIMER3(I)'length);-- 5.8s
				end case;
			elsif((TICK_100MS = '1') and (TIMER3(I) /= 0)) then
				-- decrement until timer has expired (0)
				TIMER3(I) <= TIMER3(I) - 1;
			end if;
		end if;
	end process;
	
	-- slowly increase time between successive zero window probes
	-- ZWP_STATE(I) goes from 0 to 8 and stays there until connection is reset or zero-window condition disappears.
	TIMER3_GEN_002: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') or (TCP_STATE(I) /= 3) or (ZWS(I) = '0')then
				-- reset or not connected state or keepalive not enabled
				ZWP_STATE(I) <= (others => '0');	
			elsif((TICK_100MS = '1') and (TIMER3(I) = 0) and (ZWP_STATE(I)(3) = '0')) then
				-- slowly increase time between successive zero window probes
				ZWP_STATE(I) <= ZWP_STATE(I) + 1;	
			end if;
		end if;
	end process;
	
	ZWP_TRIGGER(I) <= '1' when ((TICK_100MS = '1') and (TIMER3(I) = 0))  else '0';
	
end generate;

---------------------------------------------------
------ State Machine EVENTS -----------------------
---------------------------------------------------
-- Event 1: receive valid SYN flag (from anyone). Wait until the end of frame to confirm validity.
-- design note: strengthen validity check w.r.t. previous 1G COM5402 implementation.
EVENT1 <= '1' when (IP_PAYLOAD_EOF_D = '1') and (VALID_RX_TCP_ALL = '1') and (RX_TCP_FLAGS(1) = '1') else '0';

-- Event 2: completed transmission of TCP segment.
EVENT2 <= MAC_TX_EOF;  

-- EVENT4: received valid ACK flag and ACK number from the connection client for the TCP stream RX_TCP_STREAM_SEL_D(I) associated with the current rx frame
EVENT4 <= '1' when unsigned(EVENTS4) /= 0 else '0';
-- Events 4A: received valid non-duplicate ACK (a subset of EVENTS4)
EVENT4A <= '1' when unsigned(EVENTS4A) /= 0 else '0';
-- Events 4B: received valid duplicate ACK (a subset of EVENTS4)
EVENT4B <= '1' when unsigned(EVENTS4B) /= 0 else '0';

-- Event 6
-- received valid segment, no segment to transmit. generate ACK only.
EVENT6 <= '1' when ((SEND_ACK_NOW = '1') and (TX_TCP_RTS = '0')) else '0'; 

-- Event 8
-- data is ready to be transmitted over TCP. Send data.  A distinct tx state machine is located 
-- in TCP_TXBUF together with the transmit buffers. 
-- Block sending until we receive a valid ACK from the previous transmission
-- A frame is ready for transmission when 
-- (a) the effective client rx window size is non-zero
-- (b) the tx buffer contains either the effective client rx window size or no new data received in the last TX_IDLE_TIMEOUT
-- (c) TCP is not busy transmitting/assembling another packet
-- implied condition: TCP is in connected state (3) otherwise TX_PAYLOAD_RTS = '0'
EVENT8 <= '1' when ((TX_PAYLOAD_RTS = '1') and (RTS_local = '0')) else '0';

-------------------------------------------------
---- Receive data -------------------------------
-------------------------------------------------

--// CHECK RX TCP VALIDITY -----------------------------
-- overall TCP validity. Can also be used in the case of zero-length TCP data fields)
-- Partial verification done prior to the TCP payload field, 
-- Final verification is aligned with IP_PAYLOAD_EOF_D
VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		IP_PAYLOAD_EOF_D <= IP_PAYLOAD_EOF;

		if(SYNC_RESET = '1') or (IP_PAYLOAD_SOF = '1') then
			if(unsigned(RX_IP_PROTOCOL) /= 6) then
				-- not TCP
				VALID_RX_TCP0 <= '0';
			else
				-- valid unless proven otherwise
				VALID_RX_TCP0 <= '1';
			end if;
		elsif(IP_RX_FRAME_VALID = '0') then
			-- did not pass one of the following validity criteria
			-- (a) protocol is IP
			-- (b) unicast or multicast destination IP address matches
			-- (c) correct IP header checksum (IPv4 only)
			-- (d) allowed IPv6
			VALID_RX_TCP0 <= '0';
		elsif (IP_PAYLOAD_SOF_D2 = '1') and (TCP_STATE_localrx = 3) and (ORIGINATOR_IDENTIFIED /= RX_TCP_STREAM_SEL_D) then
			-- (g) TCP connection is established and origin MAC/IP/Port is inconsistent (spoof detection)
			VALID_RX_TCP0 <= '0';
		elsif (IP_PAYLOAD_SOF_D2 = '1') and (unsigned(RX_TCP_STREAM_SEL_D) = 0) then
			-- destination port number does not match any of the specified TCP_LOCAL_PORTS
			VALID_RX_TCP0 <= '0';
		elsif(IP_PAYLOAD_EOF = '1') then
			-- additional checks performed exclusively at the end of frame
			-- mostly related to transmission errors (Ethernet FCS/CRC, TCP checksum)
			if(IP_RX_FRAME_VALID = '0') then
				-- did not pass one of the following validity criteria
				-- (e) Ethernet frame is valid (correct FCS, dest address)
				VALID_RX_TCP0 <= '0';
			end if;
		elsif(IP_PAYLOAD_EOF_D = '1') then
			if(VALID_TCP_CHECKSUM = '0') then
				VALID_RX_TCP0 <= '0';
			end if;
		end if;
	end if;
end process;
VALID_RX_TCP_ALL <= '0' when (IP_PAYLOAD_EOF_D = '1') and (VALID_TCP_CHECKSUM = '0') else VALID_RX_TCP0;
	-- to account for the late arrival of VALID_TCP_CHECKSUM (due to timing)
    
-- Note: additional checks must be performed to forward data to the output data sink (TCP state = connected, 
-- enough space in data sink to accept the data).

		
--// COPY RX TCP DATA TO BUFFER ---------------------------------------------
-- Algorithm: TCP header length is in RX_TCP_DATA_OFFSET: range 5-15 words of 32-bit

-- sloppy but simple filtering of non-payload words
-- IMPORTANT: always left aligned (MSB first): RX_DATA_VALID is x80,xc0,xe0,xf0,....x01,x00 
RX_PAYLOAD_001: process(CLK)
begin
    if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (IP_PAYLOAD_SOF = '1') or (VALID_RX_TCP_ALL = '0') or (GAP_IN_RX_SEQ = '1') or (RX_OUTOFBOUND = '1') then
            RX_DATA <= (others => '0');
        elsif(IP_PAYLOAD_WORD_VALID = '1') and (TCP_PAYLOAD_FLAG = '1')then
            if(RX_TCP_DATA_OFFSET(0) = '0') then
                -- TCP header length is an exact integer multiple of words
                RX_DATA <= IP_PAYLOAD_DATA;
            else
                -- offset by 1/2 a word
                if (TCP_SOF_FLAG = '1') then
                    if (IP_PAYLOAD_DATA_VALID(3) = '0') then
                        -- zero length payload
                        RX_DATA <= (others => '0');
                    else
                        -- left-aligned
                        RX_DATA(63 downto 32) <= IP_PAYLOAD_DATA(31 downto 0);
                        RX_DATA(31 downto 0) <= (others => '0');
                    end if;
                else
                    RX_DATA <= IP_PAYLOAD_DATA;
                end if;
            end if;
        end if;
    end if;
end process;

-- IMPORTANT: always left aligned (MSB first): RX_DATA_VALID is x80,xc0,xe0,xf0,....x01,x00 
RX_PAYLOAD_002: process(CLK)
begin
    if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (IP_PAYLOAD_SOF = '1') or (VALID_RX_TCP_ALL = '0') or (GAP_IN_RX_SEQ = '1') or (RX_OUTOFBOUND = '1') then
            RX_DATA_VALID_local <= (others => '0');
        elsif(IP_PAYLOAD_WORD_VALID = '1') and (TCP_PAYLOAD_FLAG = '1') then
            if(RX_TCP_DATA_OFFSET(0) = '0') then
                -- TCP header length is an exact integer multiple of words
                RX_DATA_VALID_local <= IP_PAYLOAD_DATA_VALID;
            else
                -- offset by 1/2 a word
                if (TCP_SOF_FLAG = '1') then
                    if (IP_PAYLOAD_DATA_VALID(3) = '0') then
                        -- zero length payload
                        RX_DATA_VALID_local <= (others => '0');
                    else
                        -- left-aligned
                        RX_DATA_VALID_local(7 downto 4) <= IP_PAYLOAD_DATA_VALID(3 downto 0);
                        RX_DATA_VALID_local(3 downto 0) <= (others => '0');
                    end if;
                else
                    RX_DATA_VALID_local <= IP_PAYLOAD_DATA_VALID;
                end if;
            end if;
        else
            RX_DATA_VALID_local <= (others => '0');
        end if;
    end if;
end process;
RX_DATA_VALID <= RX_DATA_VALID_local;

TCP_PAYLOAD_FLAG <= '1' when (unsigned(IP_PAYLOAD_WORD_COUNT) > 2) and (unsigned(IP_PAYLOAD_WORD_COUNT) > unsigned(RX_TCP_DATA_OFFSET(3 downto 1))) else '0';
-- wait until word#3 to assess possible presence of payload (since RX_TCP_DATA_OFFSET is only read at word #2
-- Note: we don't check byte validity here, so payload could still be empty.

-- Generate RX_SOF (looks like the above TCP_PAYLOAD_FLAG code, but is reset after the first payload word).
-- Also keep track of whether the received packet has zero data length or not. (Needed to 
-- determine whether an ACK should be sent)
RX_PAYLOAD_003: process(CLK)
begin
    if rising_edge(CLK) then
		if(SYNC_RESET = '1') or  (IP_PAYLOAD_SOF = '1') then
            TCP_SOF_FLAG <= '1';    -- Awaiting TCP_SOF word
		elsif (IP_PAYLOAD_WORD_VALID = '1') and (TCP_PAYLOAD_FLAG = '1') then
	        -- reached the word where TCP_SOF is expected (if not empty frame)
            TCP_SOF_FLAG <= '0';
        end if;
        
 		 if(SYNC_RESET = '1') or (IP_PAYLOAD_SOF = '1') or (VALID_RX_TCP_ALL = '0') or (GAP_IN_RX_SEQ = '1') or (RX_OUTOFBOUND = '1') then
             RX_SOF_local <= '0';
             RX_TCP_STREAM_SEL_OUT <= (others => '0');
--             RX_TCP_NON_ZERO_DATA_LENGTH <= '0';
        elsif(IP_PAYLOAD_WORD_VALID = '1') and (TCP_PAYLOAD_FLAG = '1') and (TCP_SOF_FLAG = '1')  then
           -- generate SOF if non-zero data length in payload
           if(RX_TCP_DATA_OFFSET(0) = '0') and (IP_PAYLOAD_DATA_VALID(7) = '1') then
              -- TCP header length is an exact integer multiple of words and first payload word is not empty
              RX_SOF_local <= '1';
              RX_TCP_STREAM_SEL_OUT <= RX_TCP_STREAM_SEL_D;
--              RX_TCP_NON_ZERO_DATA_LENGTH <= '1';
           elsif (RX_TCP_DATA_OFFSET(0) = '1') and (IP_PAYLOAD_DATA_VALID(3) = '1') then
              RX_SOF_local <= '1';
              RX_TCP_STREAM_SEL_OUT <= RX_TCP_STREAM_SEL_D;
--              RX_TCP_NON_ZERO_DATA_LENGTH <= '1';
           else
              -- first payload word but no data
              RX_SOF_local <= '0';
              RX_TCP_STREAM_SEL_OUT <= (others => '0');
--              RX_TCP_NON_ZERO_DATA_LENGTH <= '0';
          end if;
         else
            RX_SOF_local <= '0';
         end if;                  
    end if;
end process;
RX_SOF <= RX_SOF_local;

-- detect non-zero data length: check the presence of the first payload byte
RX_PAYLOAD_004: process(CLK)
begin
    if rising_edge(CLK) then
         if(SYNC_RESET = '1') or (IP_PAYLOAD_SOF = '1') then
             -- RX_TCP_DATA_OFFSET is read at IP_PAYLOAD_WORD_COUNT = 2
             RX_TCP_NON_ZERO_DATA_LENGTH <= '0';
        elsif(IP_PAYLOAD_WORD_VALID = '1') and (TCP_PAYLOAD_FLAG = '1') and (TCP_SOF_FLAG = '1')  then
           if(RX_TCP_DATA_OFFSET(0) = '0') and (IP_PAYLOAD_DATA_VALID(7) = '1') then
              -- TCP header length is an exact integer multiple of words and first payload word is not empty
              RX_TCP_NON_ZERO_DATA_LENGTH <= '1';
           elsif (RX_TCP_DATA_OFFSET(0) = '1') and (IP_PAYLOAD_DATA_VALID(3) = '1') then
              RX_TCP_NON_ZERO_DATA_LENGTH <= '1';
           else
              -- first payload word but no data
              RX_TCP_NON_ZERO_DATA_LENGTH <= '0';
          end if;
        end if;                  
    end if;
end process;

-- generate RX_EOF
RX_PAYLOAD_005: process(CLK)
begin
    if rising_edge(CLK) then
        RX_EOF_D <= RX_EOF_local;
        
		if(SYNC_RESET = '1') or (IP_PAYLOAD_SOF = '1') or (VALID_RX_TCP_ALL = '0') or (GAP_IN_RX_SEQ = '1') or (RX_OUTOFBOUND = '1') then
		  RX_EOF_local <= '0';
		elsif (IP_PAYLOAD_EOF = '1') and (TCP_PAYLOAD_FLAG = '1') then
		  -- detect empty frame
		  if(TCP_SOF_FLAG = '1') and (RX_TCP_DATA_OFFSET(0) = '0') and (IP_PAYLOAD_DATA_VALID(7) = '0') then
		      -- even length header, empty frame
    		  RX_EOF_local <= '0';
		  elsif(TCP_SOF_FLAG = '1') and (RX_TCP_DATA_OFFSET(0) = '1') and (IP_PAYLOAD_DATA_VALID(3) = '0') then
		      -- odd length header, empty frame
    		  RX_EOF_local <= '0';
          else
            -- end of non-empty frame
            RX_EOF_local <= '1';
          end if;
       else
		  RX_EOF_local <= '0';
	   end if;
    end if;
end process;
RX_EOF <= RX_EOF_local;

RX_FRAME_VALID_local <= VALID_RX_TCP_ALL when  (RX_TCP_NON_ZERO_DATA_LENGTH = '1') and (GAP_IN_RX_SEQ = '0') and (RX_OUTOFBOUND = '0') else '0';
RX_FRAME_VALID <= RX_FRAME_VALID_local;
    -- always verify the rx tcp frame validity at IP_PAYLOAD_EOF_D = RX_EOF
    -- Do not forward data to the rx buffer if there is a gap in rx sequence or if the client 
    -- is doing a zero window-length probe (i.e. writing past the declared max)
    -- No point in writing non-TCP data to the rx buffer in the first place (those pesky
    -- NetBUI packets fill-up pretty fast, even if we rewind the write pointer at the next valid
    -- TCP packet
    -- Also block data if not connected.

WPTR_GEN_001: process(RX_DATA_VALID_local)
begin
    if(RX_DATA_VALID_local(0) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 8;
    elsif(RX_DATA_VALID_local(1) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 7;
    elsif(RX_DATA_VALID_local(2) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 6;
    elsif(RX_DATA_VALID_local(3) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 5;
    elsif(RX_DATA_VALID_local(4) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 4;
    elsif(RX_DATA_VALID_local(5) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 3;
    elsif(RX_DATA_VALID_local(6) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 2;
    elsif(RX_DATA_VALID_local(7) = '1') then
       RX_TCP_SEQ_NO_INCREMENT <= 1;
    else
       RX_TCP_SEQ_NO_INCREMENT <= 0;
    end if;
end process;

-- read the TCP client sequence number in the received TCP header. 
-- This is subsequently used as ack when replying or sending data to the TCP client
RX_PAYLOAD_006: process(CLK)
begin
    if rising_edge(CLK) then
        IP_PAYLOAD_SOF_D <= IP_PAYLOAD_SOF;
        IP_PAYLOAD_SOF_D2 <= IP_PAYLOAD_SOF_D;
        
		if (IP_PAYLOAD_SOF_D = '1') then
            RX_TCP_SEQ_NO_TRACK <= RX_TCP_SEQ_NO;
        elsif(RX_DATA_VALID_local(7) = '1') then
            -- at least one byte passed to rx elastic buffer
            RX_TCP_SEQ_NO_TRACK <= RX_TCP_SEQ_NO_TRACK + RX_TCP_SEQ_NO_INCREMENT;
        end if;
    end if;
end process;

--// RX SEQUENCE NUMBER ------------------------
RX_TCP_SEQ_NO_INC <= RX_TCP_SEQ_NO + 1;

-- Manage tx ack number
TX_ACK_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	TX_ACK_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(RX_TCP_STREAM_SEL(I) = '1') then
				-- rx event
				if(TCP_STATE(I) < 3) and (EVENT1 = '1') then	-- *062716
					-- Received valid SYN while in LISTEN state
					-- ACK sequence number is the one received + 1
					-- Extend the applicability to the case when we receive multiple SYN messages (could happen
					-- when transmission delay is long)  *062716
					TX_ACK_NO(I) <= RX_TCP_SEQ_NO_INC;
				elsif(CONNECTED_FLAG_local(I) = '1') and (EVENTS5(I) = '1') then
					-- Received valid FIN while in CONNECTED state
					-- ACK sequence number depends on whether FIN packets include data or not
					TX_ACK_NO(I) <= RX_TCP_SEQ_NO_TRACK + 1;
				elsif(RX_ZERO_WINDOW_PROBE = '1') then
					-- TCP zero-window-length exception. sender may be testing whether the TX_ACK_WINDOW_LENGTH is 
					-- still zero by sending a 1-byte data. Treat as a zero-length packet
				elsif(GAP_IN_RX_SEQ = '1') then
					-- Do not update TX_ACK_NO if we have received a valid packet with unexpected RX_TCP_SEQ_NO (gap in sequence)
					-- as data was not written to the rx buffer, but we still send an ACK.
				elsif(RX_EOF_D = '1') and (RX_FRAME_VALID_local = '1') then 
					-- in CONNECTED state, received and successfully forwarded a rx segment. 
					-- TX_ACK_NO is the next expected number
					TX_ACK_NO(I) <= RX_TCP_SEQ_NO_TRACK;
				end if;
			end if;
		end if;
	end process;
end generate;


------------------------------------------------
---- TCP receive flow control -------------------
-------------------------------------------------

-- Detect when RX_TCP_SEQ_NO is beyond the TCP receive window (it happens, for example during TCP zero-window probes)
RX_OUTOFBOUND_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_OUTOFBOUND <= '0';
		-- rx window upper bound (RX_TCP_SEQ_NO_MAX) computed upon sending the last tx frame.
		elsif(RX_TCP_SEQ_NO >= RX_TCP_SEQ_NO_MAX2) and 
		not((RX_TCP_SEQ_NO(31 downto 30) = "11") and (RX_TCP_SEQ_NO_MAX2(31 downto 30) = "00")) then
			-- a bit complicated because of modulo 2^32 counters.
			RX_OUTOFBOUND <= '1';
		elsif(RX_TCP_SEQ_NO < RX_TCP_SEQ_NO_MIN2) and 
		not((RX_TCP_SEQ_NO(31 downto 30) = "00") and (RX_TCP_SEQ_NO_MIN2(31 downto 30) = "11")) then
			RX_OUTOFBOUND <= '1';
		else
			RX_OUTOFBOUND <= '0';
		end if;
	end if;
end process;

-- Send ACK immediately upon receiving a valid data segment while TCP connected.
-- Watch out for infinite loops! cannot send an ACK on an ACK
-- Therefore, inhibit SEND_ACK_NOW if the last packet received has the ACK with zero-length.
SEND_ACK_NOW <= VALID_RX_TCP_ALL when  (TCP_STATE_localrx = 3) and (RX_TCP_NON_ZERO_DATA_LENGTH = '1') and (IP_PAYLOAD_EOF_D = '1') else '0';	-- *070118

-- Detect when there is a gap in the RX_TCP_SEQ_NO, indicating a previous frame is missing
-- In general, we expect RX_TCP_SEQ_NO to match TX_ACK_NO, the next expected rx sequence number.
GAP_IN_RX_SEQ <= '1' when (RX_TCP_SEQ_NO /= TX_ACK_NO2) else '0';	-- ready at IP_PAYLOAD_SOF_D2

-- Detect when client tries to send data past the end of the window (for example during 
-- TCP zero-window probing. Sender may be probing whether the TX_ACK_WINDOW_LENGTH is 
--	still zero by sending a 1-byte data past the end of the window. 
RX_ZERO_WINDOW_PROBE <= (VALID_RX_TCP_ALL and RX_OUTOFBOUND) when  (TCP_STATE_localrx = 3) else '0';

-- external receive buffer is full 
RX_BUF_FULL_GEN: for I in 0 to (NTCPSTREAMS-1) generate
	RX_BUF_FULL(I) <= '1' when (unsigned(RX_FREE_SPACE(I)) = 0) else '0';
end generate;

-- external receive buffer has space for at least one MSS frame *071416
RX_BUF_1MSSFREE_GEN: for I in 0 to (NTCPSTREAMS-1) generate
	RX_BUF_1MSSFREE(I) <= '1' when (unsigned(RX_FREE_SPACE(I)) > (unsigned(MSS)+TX_ACK_WINDOW_LENGTH_MARGIN)) else '0';
end generate;

-- flow control information is sent to the client within the ack 
-- using the TX_ACK_WINDOW_LENGTH window size FROZEN during packet transmission
TX_ACK_WINDOW_LENGTH_GEN_001: process(CLK) 
variable TX_ACK_WINDOW_LENGTHv: unsigned(31 downto 0);
variable TX_WINDOW_SCALEv: std_logic_vector(3 downto 0);
begin
	if rising_edge(CLK) then
		TX_WINDOW_SCALEv := x"0";
		TX_ACK_WINDOW_LENGTHv := (others => '0');	-- *030521

		if(SYNC_RESET = '1') then
			TX_ACK_WINDOW_LENGTHv := resize(unsigned(MSS),32);	-- initial available is at least 1 MSS
		elsif(RTS_local = '0') then
			-- update TX_ACK_WINDOW_LENGTH when triggering a frame transmission 
			-- Two trigger events:
			if(NEXT_TX_TCP_FRAME_QUEUED = '1') then
				-- short (no payload data) tx packet for stream NEXT_TX_TCP_STREAM_SEL
				for I in 0 to NTCPSTREAMS-1 loop
					if(NEXT_TX_TCP_STREAM_SEL(I) = '1') then
						TX_ACK_WINDOW_LENGTHv := unsigned(RX_FREE_SPACE(I));	
						TX_WINDOW_SCALEv := TX_WINDOW_SCALE(I);
					end if;
        	    end loop;
			elsif(EVENT8 = '1') then
				-- long (with payload data) tx packet for stream TX_STREAM_SEL
				for I in 0 to NTCPSTREAMS-1 loop
				   if(TX_STREAM_SEL(I) = '1') then
						TX_ACK_WINDOW_LENGTHv := unsigned(RX_FREE_SPACE(I));	
						TX_WINDOW_SCALEv := TX_WINDOW_SCALE(I);
				    end if;
				end loop;
			end if;
		end if;

		-- new *080818 take a margin of 4 samples = 32 bytes when reporting about the available space in the rx buffer
		-- as we are trying to shorten the time between RX_EOF and ack transmission. 
		-- Reason: RX_FREE_SPACE information is 3 clocks late
		if(TX_ACK_WINDOW_LENGTHv >= 32) then
			TX_ACK_WINDOW_LENGTHv := TX_ACK_WINDOW_LENGTHv - to_unsigned(TX_ACK_WINDOW_LENGTH_MARGIN,32);
		else
			TX_ACK_WINDOW_LENGTHv := (others => '0');
		end if;
		
		if(SYNC_RESET = '1') then
			TX_ACK_WINDOW_LENGTH <= (others => '0');
			TX_ACK_WINDOW_LENGTH_SCALED <= (others => '0');
		elsif(RTS_local = '0') and ((NEXT_TX_TCP_FRAME_QUEUED = '1') or (EVENT8 = '1')) then
			TX_ACK_WINDOW_LENGTH <= TX_ACK_WINDOW_LENGTHv;
			-- window scaling (buffer sizes ranging from 256 to 1MB)
			case TX_WINDOW_SCALEv is
				when "0000" => TX_ACK_WINDOW_LENGTH_SCALED <= TX_ACK_WINDOW_LENGTHv(15 downto 0);	-- <= 64kB
				when "0001" => TX_ACK_WINDOW_LENGTH_SCALED <= TX_ACK_WINDOW_LENGTHv(16 downto 1);
				when "0010" => TX_ACK_WINDOW_LENGTH_SCALED <= TX_ACK_WINDOW_LENGTHv(17 downto 2);
				when "0011" => TX_ACK_WINDOW_LENGTH_SCALED <= TX_ACK_WINDOW_LENGTHv(18 downto 3);
				when others => TX_ACK_WINDOW_LENGTH_SCALED <= TX_ACK_WINDOW_LENGTHv(19 downto 4);	-- 1MB
			end case;
		end if;
		
		
	end if;
end process;
TX_ACK_WINDOW_LENGTH_OUT <= std_logic_vector(TX_ACK_WINDOW_LENGTH_SCALED);

-- window resizing
-- set when transmitting an ACK with TX_ACK_WINDOW_LENGTH = 0 indicating receiver buffer is full,
-- clear when the input receive buffer is no longer empty. 
RX_WINDOW_RESIZE_STATEx: for I in 0 to (NTCPSTREAMS-1) generate
	RX_WINDOW_RESIZE_STATE_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RX_WINDOW_RESIZE_STATE(I) <= "00";
				SEND_RX_WINDOW_RESIZE(I) <= '0';
			elsif(TX_PACKET_SEQUENCE_START = '1') and (TX_TCP_STREAM_SEL(I) = '1') and (RX_BUF_FULL(I) = '1') then
				-- not enough room in rx buffer. Sending ACK with zero-width ACK window to client I.
				RX_WINDOW_RESIZE_STATE(I) <= "01";
			elsif(RX_WINDOW_RESIZE_STATE(I) = "01") and (MAC_TX_EOF = '1') and (TX_TCP_STREAM_SEL(I) = '1')  then
				-- completed transmission of the ACK with TX_ACK_WINDOW_LENGTH = 0 to client I
				RX_WINDOW_RESIZE_STATE(I) <= "10";
			elsif (RX_WINDOW_RESIZE_STATE(I) = "10") and (RX_BUF_FULL(I) = '0') then
				-- Receive buffer has room for another segment. 
				-- time to send unsollicited ACKs to indicate window resizing. The receive window is no
				-- longer empty, the clients are on-hold due to the previous ACK with zero-width ack window.
				RX_WINDOW_RESIZE_STATE(I) <= "00";
				SEND_RX_WINDOW_RESIZE(I) <= '1';
			else
				SEND_RX_WINDOW_RESIZE(I) <= '0';
			end if;
		end if;
	end process;
end generate;

-- window resizing2 *071416
-- set when the receive buffer available space goes very low and no further data is received (Windows OS waits 5 seconds)
-- clear when the input receive buffer has enough room for a full MSS-size frame
-- The objective is to avoid waiting a long time (5s) until the Windows OS decides to send data again. 
RX_WINDOW_RESIZE2_STATEx: for I in 0 to (NTCPSTREAMS-1) generate
	RX_WINDOW_RESIZE2_STATE_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RX_WINDOW_RESIZE2_STATE(I) <= "00";
				SEND_RX_WINDOW_RESIZE2(I) <= '0';
			elsif(TX_PACKET_SEQUENCE_START = '1') and (TX_TCP_STREAM_SEL(I) = '1')  and (RX_BUF_1MSSFREE(I) = '0') then
				-- rx buffer is getting full... wait
				RX_WINDOW_RESIZE2_STATE(I) <= "01";
			elsif(RX_WINDOW_RESIZE2_STATE(I) = "01") and (MAC_TX_EOF = '1') and (TX_TCP_STREAM_SEL(I) = '1')  then
				-- completed transmission of the ACK  to client I
				RX_WINDOW_RESIZE2_STATE(I) <= "10";
			elsif(RX_WINDOW_RESIZE2_STATE(I) = "10") and (TX_TCP_STREAM_SEL(I) = '1')  and (RX_BUF_1MSSFREE(I) = '1') then
				-- receive buffer now has enough space on rx buffer for a full MSS-size frame. Go back to idle
				RX_WINDOW_RESIZE2_STATE(I) <= "00";
				SEND_RX_WINDOW_RESIZE2(I) <= '1';
			else
				SEND_RX_WINDOW_RESIZE2(I) <= '0';
			end if;
		end if;
	end process;
end generate;


-- remember the receive window upper bound RX_TCP_SEQ_NO_MAX (exclusive)
-- to compare with follow-on RX_TCP_SEQ_NO
RX_WINDOW_UPPER_BOUNDx: for I in 0 to (NTCPSTREAMS-1) generate
	RX_WINDOW_UPPER_BOUND_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RX_TCP_SEQ_NO_MAX(I) <= (others => '0');
			elsif(TX_PACKET_SEQUENCE_START = '1') and (TX_TCP_STREAM_SEL(I) = '1')  then
				-- compute the receive address ceiling when sending the sequence ack to the client.
				RX_TCP_SEQ_NO_MAX(I) <= TX_ACK_NO(I) + TX_ACK_WINDOW_LENGTH;
				-- design note: TX_ACK_WINDOW_LENGTH is an aggregate value showing only space in the 
				-- common rx buffer (common to all streams). TODO: change when TCP_RXBUFNDEMUX is upgrade
				-- with individual buffers for each channel.
			end if;
		end if;
	end process;
end generate;

-- RECEIVE CODE ABOVE ^^^^^^^^^^^^^^^^^^^
--=============================================================================================
--=============================================================================================
--=============================================================================================
--=============================================================================================
-- TRANSMIT CODE BELOW  VVVVVVVVVVVVVVVVVV

---------------------------------------------------
------ Transmit EVENTS ----------------------------
---------------------------------------------------

---------------------------------------------------
--//---- TX SEQUENCER  ----------------------------
---------------------------------------------------
-- First, schedule a TX frame based on RX events.
-- The decision to transmit is made here and stored in non-volatile TX_PACKET_TYPE_QUEUED() variable until
-- the actual frame transmission can take place. This is a kind of queue to avoid conflicts.
-- Identify the stream based on the destination tcp port for each 
-- incoming frame.
SCHEDULE_TX_FRAME_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	SCHEDULE_TX_FRAME_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_PACKET_TYPE_QUEUED(I) <= "00";	-- undefined tx packet type
			elsif (NEXT_TX_TCP_STREAM_SEL(I) = '1')  and (RTS_local = '0') and (NEXT_TX_TCP_FRAME_QUEUED = '1') then
				-- scheduled for transmission, clear any tx frame queued
				TX_PACKET_TYPE_QUEUED(I) <= "00";	-- undefined tx packet type
			elsif (TCP_STATE(I) = 0) and (RX_TCP_STREAM_SEL_D(I) = '1') and (EVENT1 = '1')  then
				-- Connection establishment. send SYN/ACK
				TX_PACKET_TYPE_QUEUED(I) <= "01";		-- SYN/ACK, 24 bytes TCP header, no TCP payload
				-- send MSS option with the SYN message. TCP header is thus 24 byte long.
			elsif(CONNECTED_FLAG_local(I) = '1') and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected. Send FIN.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif(CONNECTED_FLAG_local(I) = '1') and (TCP_KEEPALIVE_EN(I) = '1') and (KASTATE(I) = 0) then
				-- failed keepalive. Automatic disconnect. Send FIN.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (TCP_STATE(I) = 7) and (EVENTS5(I) = '1') then
				-- received FIN after FIN. Send final ACK.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (CONNECTED_FLAG_local(I) = '1') and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . Send ACK
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (TCP_STATE(I) = 4) and (EVENTS2(I) = '1') and (TX_FLAGS(I)(4) = '1') then
				-- sent ACK after receiving FIN. send final FIN
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif ((CONNECTED_FLAG_local(I) = '1') and (EVENTS11(I) = '1')) then
				-- keep-alive or zero-window check: send a probe segment (zero-length, TX_SEQ_NO = RX_TCP_ACK_NO -1)
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (KA_PROBE_DET(I) = '1') then
				-- received a keep-alive probe segment. Send ack
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (CONNECTED_FLAG_local(I) = '1') and (RX_TCP_STREAM_SEL_D(I) = '1') and (EVENT6 = '1') then
				-- received valid segment, no segment to transmit. generate ACK only.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
				-- default length
			elsif (CONNECTED_FLAG_local(I) = '1') and (EVENTS10(I) = '1') then
				-- Window resizing (receive flow control), no segment to transmit. The receive buffer is no 
				-- longer empty. Send a single ACK with a non-zero window.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			end if;
		end if;
	end process;
end generate;	

-- Trigger response
-- Which stream is next? Check if any non-payload packet is queued (TX_PACKET_TYPE_QUEUED(I) /= 0)
NEXT_TCP_TX_STREAM_INDEX_001: process(TX_PACKET_TYPE_QUEUED)
variable TX_STREAM_NO: std_logic_vector(NTCPSTREAMS-1 downto 0);
variable TX_FRAME_QUEUED: std_logic := '0';
begin
	TX_STREAM_NO  := (others => '0');
	TX_FRAME_QUEUED := '0';
	for I in 0 to (NTCPSTREAMS-1) loop
		if(TX_FRAME_QUEUED = '0') and (TX_PACKET_TYPE_QUEUED(I) /= "00") then
			TX_FRAME_QUEUED := '1';
			TX_STREAM_NO(I) := '1';	-- rephrasing 081918
		end if;
	end loop;
	NEXT_TX_TCP_STREAM_SEL <= TX_STREAM_NO;
	NEXT_TX_TCP_FRAME_QUEUED <= TX_FRAME_QUEUED;
end process;

-- decision to transmit a frame (with or without payload) is made here.
-- TX_PACKET_TYPE is valid during transmission from the TX_PACKET_SEQUENCE_START pulse (incl) 
-- to MAC_TX_EOF (incl), undefined otherwise.
TX_PACKET_SEQUENCE_START_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS_local <= '0';
			TX_PACKET_TYPE <= (others => '0');	-- undefined
		elsif(RTS_local = '0') then
			-- Prevent a new packet assembly/transmission until current assembly/transmission is complete.
			if(NEXT_TX_TCP_FRAME_QUEUED = '1') then
				-- short (no payload data) tx packet for stream NEXT_TX_TCP_STREAM_SEL
				RTS_local <= '1';	
				TX_PACKET_SEQUENCE_START <='1';	
				TX_TCP_STREAM_SEL <= NEXT_TX_TCP_STREAM_SEL;
				for I in 0 to NTCPSTREAMS-1 loop
				    if(NEXT_TX_TCP_STREAM_SEL(I) = '1') then
				        TX_PACKET_TYPE <= TX_PACKET_TYPE_QUEUED(I);
				    end if;
			     end loop;
			elsif(EVENT8 = '1') then
				-- long (with payload data) tx packet for stream TX_STREAM_SEL
				RTS_local <= '1';	
				TX_PACKET_SEQUENCE_START <='1';	
				TX_TCP_STREAM_SEL <= TX_STREAM_SEL;
				TX_PACKET_TYPE <= "11";		-- tx data packet, 20 bytes TCP header
			end if;
		elsif(MAC_TX_EOF = '1') then
			-- transmit is complete.
			RTS_local <= '0';
			TX_PACKET_TYPE <= (others => '0');
		else
			TX_PACKET_SEQUENCE_START <= '0';	-- make it a one-CLK pulse
		end if;
	end if;
end process;
RTS <= RTS_local;	-- tell TCP_TX
		
		
-- send all relevant information to TCP_TX so that it can format the transmit frame
OUTPUT_GEN: process(TX_TCP_STREAM_SEL, TX_DEST_MAC_ADDR, TX_DEST_IP_ADDR, TX_DEST_PORT_NO, TCP_LOCAL_PORTS,
	TX_IPv4_6n, TX_SEQ_NO_OUT_local, TX_ACK_NO, TX_FLAGS, TX_WINDOW_SCALE)
variable TX_DEST_MAC_ADDRv: std_logic_vector(47 downto 0);
variable TX_DEST_IP_ADDRv: std_logic_vector(127 downto 0);
variable TX_DEST_PORT_NOv: std_logic_vector(15 downto 0);
variable TCP_LOCAL_PORTSv: std_logic_vector(15 downto 0);
variable TX_IPv4_6nv: std_logic;
variable TX_SEQ_NO_OUTv: std_logic_vector(31 downto 0);
variable TX_ACK_NOv: std_logic_vector(31 downto 0);
variable TX_FLAGSv: std_logic_vector(7 downto 0);
variable TX_WINDOW_SCALEv: std_logic_vector(3 downto 0);
begin
	TX_DEST_MAC_ADDRv := (others => '0');
	TX_DEST_IP_ADDRv := (others => '0');
	TX_DEST_PORT_NOv := (others => '0');
	TCP_LOCAL_PORTSv := (others => '0');
	TX_IPv4_6nv := '0';
	TX_SEQ_NO_OUTv := (others => '0');
	TX_ACK_NOv := (others => '0');
	TX_FLAGSv := (others => '0');
	TX_WINDOW_SCALEv := (others => '0');
	for I in 0 to NTCPSTREAMS-1 loop
		if(TX_TCP_STREAM_SEL(I) = '1') then
			TX_DEST_MAC_ADDRv := TX_DEST_MAC_ADDR(I);
			TX_DEST_IP_ADDRv := TX_DEST_IP_ADDR(I);
			TX_DEST_PORT_NOv := TX_DEST_PORT_NO(I);
			TCP_LOCAL_PORTSv := TCP_LOCAL_PORTS(I);
			TX_IPv4_6nv := TX_IPv4_6n(I);    
			TX_SEQ_NO_OUTv := std_logic_vector(TX_SEQ_NO_OUT_local(I));
			TX_ACK_NOv := std_logic_vector(TX_ACK_NO(I));
			TX_FLAGSv := TX_FLAGS(I);
			TX_WINDOW_SCALEv := TX_WINDOW_SCALE(I);
		end if;
		TX_DEST_MAC_ADDR_OUT <= TX_DEST_MAC_ADDRv;
		TX_DEST_IP_ADDR_OUT <= TX_DEST_IP_ADDRv;
		TX_DEST_PORT_NO_OUT <= TX_DEST_PORT_NOv;
		TX_SOURCE_PORT_NO_OUT <= TCP_LOCAL_PORTSv;
		TX_IPv4_6n_OUT <= TX_IPv4_6nv;    
		TX_SEQ_NO_OUT <= TX_SEQ_NO_OUTv;
		TX_ACK_NO_OUT <= TX_ACK_NOv;
		TX_FLAGS_OUT <= TX_FLAGSv;
		TX_WINDOW_SCALE_OUT <= TX_WINDOW_SCALEv;
	end loop;
end process;
TX_PACKET_SEQUENCE_START_OUT <= TX_PACKET_SEQUENCE_START;
TX_PACKET_TYPE_OUT <= TX_PACKET_TYPE;



-------------------------------------------------
---- TCP transmit flow control -------------------
-------------------------------------------------
-- last byte sent : TX_SEQ_NO
-- last byte ack'd: RX_TCP_ACK_NO
-- advertised rx window: RX_TCP_WINDOW_SIZE
-- sent and unacknowledged: TX_SEQ_NO - RX_TCP_ACK_NO

-- The next TCP tx frame size is determined by 
-- (a) the maximum packet size in the MAC (assumed 9000 payload bytes in TCP_TXBUF) or
-- (b) the effective TCP rx window size as reported by the receive side, or

-- Effective TCP rx window size = advertised TCP rx window size - unacknowledged but sent data size
-- changes at end of tx packet (TX_EOF_D2), and upon receiving a valid ack
-- Partial computation upon receiving a valid ACK, complete computation upon frame transmission
-- when TX_SEQ_NO is updated.
-- The effective TCP rx window size can be temporarily reduced by the TCP congestion window.

-- The TCP congestion window starts at 2 segments (see MSS) and doubles at each valid ACK.
EFF_RX_WINDOW_SIZE_PARTIAL_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			EFF_RX_WINDOW_SIZE_PARTIAL_local <= (others => '0');
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= (others => '0');
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local <= '0';
		elsif(TCP_STATE_localrx = 0) and (EVENT1 = '1') then	-- *012020
			-- Received valid SYN from client. First time we learn about window size
			-- Note: window size advertized by client may change at the next ACK from client
			-- Waste no time. We can start preparing transmit frames once we send the SYNC ACK to the client. 
			-- anticipate RX_TCP_ACK_NO before we receive it. 
			EFF_RX_WINDOW_SIZE_PARTIAL_local <= RX_TCP_WINDOW_SIZE + TX_SEQ_NO_INIT + 1;  
			for I in 0 to NTCPSTREAMS-1 loop
				if(RX_TCP_STREAM_SEL_D(I) = '1') then
					TCP_TX_SLOW_START(I) <= '0';	-- ignore slow-start phase  TEST TEST TEST
				end if;
			end loop;
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_SEL_D;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local <= '1';
--		elsif(TCP_STATE_localrx = 2) and (EVENT4 = '1') then
--			-- entering the 'connected' state
--			-- enter slow start phase: TCP congestion window starts with 2 segment. increases after each ACK
--			-- until we reach the effective window size advertized by the receive side.
--			EFF_RX_WINDOW_SIZE_PARTIAL_local <= RX_TCP_ACK_NO + 2*MSS;	   
--			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_SEL_D;
--			EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local <= '1';
--			for I in 0 to NTCPSTREAMS-1 loop
--				if(RX_TCP_STREAM_SEL_D(I) = '1') then
--					TCP_CONGESTION_WINDOW(I) <=  to_unsigned(2*MSS,16);	 -- remember it for each stream
--					TCP_TX_SLOW_START(I) <= '1';
--				end if;
--			end loop;
		elsif(EVENT4A = '1')and (unsigned(RX_TCP_WINDOW_SIZE_SCALED) /= 0) then 
			-- Valid ACK received for stream RX_TCP_STREAM_SEL_D (not a duplicate ACK)
			for I in 0 to NTCPSTREAMS-1 loop
                 if(RX_TCP_STREAM_SEL_D(I) = '1') then
                    if(TCP_TX_SLOW_START(I) = '1') and (TCP_CONGESTION_WINDOW(I)(30 downto 0) < RX_TCP_WINDOW_SIZE(31 downto 1)) then	
                         -- double the next tx frame size until we reach the effective TCP rx window size
                         EFF_RX_WINDOW_SIZE_PARTIAL_local <= (TCP_CONGESTION_WINDOW(I)(30 downto 0) & "0") + RX_TCP_ACK_NO;
                         -- remember it here
                         TCP_CONGESTION_WINDOW(I) <= TCP_CONGESTION_WINDOW(I)(30 downto 0) & "0";  
                     else
                         EFF_RX_WINDOW_SIZE_PARTIAL_local <= RX_TCP_WINDOW_SIZE + RX_TCP_ACK_NO;  
                         TCP_TX_SLOW_START(I) <= '0';    -- end of slow-start phase
                     end if;
                 end if;
            end loop;
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_SEL_D;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local <= '1';
			-- partial computation of the effective tcp rx window size
		elsif(EVENT4B = '1') and (unsigned(RX_TCP_WINDOW_SIZE_SCALED) /= 0) then 
			-- Duplicate ACK for stream RX_TCP_STREAM_SEL_D. Even though the RX_TCP_ACK_NO is the same, the
			-- RX_TCP_WINDOW_SIZE may have changed (window resizing)
			EFF_RX_WINDOW_SIZE_PARTIAL_local <= RX_TCP_WINDOW_SIZE + RX_TCP_ACK_NO;  
			for I in 0 to NTCPSTREAMS-1 loop
				if(RX_TCP_STREAM_SEL_D(I) = '1') then
					TCP_TX_SLOW_START(I) <= '0';	-- end of slow-start phase
				end if;
			end loop;
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_SEL_D;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local <= '1';
		else
			-- ignore duplicate ACKs.
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local <= '0';
		end if;
	end if;
end process;
EFF_RX_WINDOW_SIZE_PARTIAL <= std_logic_vector(EFF_RX_WINDOW_SIZE_PARTIAL_local);
EFF_RX_WINDOW_SIZE_PARTIAL_VALID <= EFF_RX_WINDOW_SIZE_PARTIAL_VALID_local;

-- detect duplicate ACKs (an indication that at least one of our tx packet got lost/collided)
-- keep the flag up until (a) the condition disappears, or (b) we rewind and transmit a packet 
RX_VALID_ACK_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	-- send duplicate if we have received three ACKs in a row with the same ack no.
	-- why 3? because it is normal to receive two acks without lost packet (regular ack + window adjustment for example).

	-- tell TCP_TXBUF about the last acknowledged location.
	RX_TCP_ACK_NO_D(I) <= std_logic_vector(RX_TCP_ACK_NO_D_local(I));	

	RX_VALID_ACK_GEN_002: process(CLK)
	begin
		if rising_edge(CLK) then
			if (TCP_STATE(I) = 0) and (RX_TCP_STREAM_SEL_D(I) = '1') and (EVENT1 = '1')  then	-- *012020
				-- Connection establishment. send SYN/ACK
				-- tell TCP_TXBUF about the expected acknowledgment to compute the free space
				-- (otherwise spurious transmissions may occur randomly after SYNC)
				RX_TCP_ACK_NO_D_local(I) <= TX_SEQ_NO_INIT + 1;
			elsif(EVENTS4(I) = '1') then
				-- rx event:
				-- save rx ack number (RX_TCP_ACK_NO is transient)
				RX_TCP_ACK_NO_D_local(I) <= RX_TCP_ACK_NO;
			end if;
		end if;
	end process;

	RX_VALID_ACK_GEN_003: process(CLK)
	begin
		if rising_edge(CLK) then
			if(EVENTS4(I) = '1') then
				-- rx event:
				-- detect duplicates
				if(RX_TCP_ACK_NO_D_local(I) = RX_TCP_ACK_NO) 
				and (RX_TCP_ACK_NO /= TX_SEQ_NO_local(I))
				and (RX_TCP_NON_ZERO_DATA_LENGTH = '0') then	-- *120918
					-- Ignore duplicates when already matching the expected TX_SEQ_NO_local
					-- Ignore duplicates due to multiple received payloads while still transmitting.
					if(DUPLICATE_RX_TCP_ACK_CNTR(I) /= 3) then
						DUPLICATE_RX_TCP_ACK_CNTR(I) <= DUPLICATE_RX_TCP_ACK_CNTR(I) + 1;   -- counts from 0 to 3
					end if;
				else
					-- received new or expected ack. condition is gone.
					DUPLICATE_RX_TCP_ACK_CNTR(I) <= "00";
				end if;
			elsif (TX_TCP_STREAM_SEL(I) = '1') and (TX_PACKET_SEQUENCE_START = '1') and (TX_PACKET_TYPE = "11")
				and (TX_SEQ_NO_local(I) =  RX_TCP_ACK_NO_D_local(I)) then 
				-- tx event:
				-- started retransmitting unacknowledged data. clear flag
				DUPLICATE_RX_TCP_ACK_CNTR(I) <= "00";
			end if;
		end if;
	end process;
end generate;

-- detect keep-alive probe segment: RX_TCP_SEQ_NO is TX_ACK_NO -1 and no data
KA_PROBE_DET_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	KA_PROBE_DET_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if ((CONNECTED_FLAG_local(I) = '1') and (EVENTS12(I) = '1') and (RX_TCP_NON_ZERO_DATA_LENGTH = '0') and
			(RX_TCP_SEQ_NO_INC(15 downto 0) = TX_ACK_NO(I)(15 downto 0))) then
				KA_PROBE_DET(I) <= '1';
			else
				KA_PROBE_DET(I) <= '0';
			end if;
		end if;
	end process;
end generate;

-- Retransmission timeout
-- Compute timout since we have transmitted a packet and not received any ACK with different RX_TCP_ACK_NO.
-- See RFC 2988 Section 5: Managing the RTO timer. 
-- At this time, we do not implement the RTO max(60s) nor the backing-off algorithm for 
-- repeated timeouts.
RX_VALID_ACK_TIMEOUT_x: for I in 0 to (NTCPSTREAMS-1) generate
	RX_VALID_ACK_TIMEOUT_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') or (TCP_STATE(I) = 0) or (TX_SEQ_NO_JUMP_local(I) = '1') then	
				-- clear at start of connection
				-- clear RETRANSMIT_FLAG when the TCP_TXBUF is informed of the pointer rewind	-- *042419
				RX_VALID_ACK_TIMOUT(I) <= (others => '0');
			elsif(TX_TCP_STREAM_SEL(I) = '1') and (TX_PACKET_TYPE = "11") and (TX_PACKET_SEQUENCE_START = '1') then	-- *062716
				-- tx event: just (re)transmitted 1 frame with payload data. must wait for ACK
				-- arm timer
				if(SIMULATION = '0') then
					if(TXRX_DELAY(I)(18 downto 7) < x"03D") then	-- timeout min = 1s	*061019
						RX_VALID_ACK_TIMOUT(I) <= x"03D000";
					else
						RX_VALID_ACK_TIMOUT(I) <= TXRX_DELAY(I)(18 downto 0) & "00000"; -- 32* the average round-trip delay -- *042419
					end if;
				else
					-- shorten rexmit during simulation -- *042419
					RX_VALID_ACK_TIMOUT(I) <= TXRX_DELAY(I)(21 downto 0) & "00"; -- 4* the average round-trip delay
				end if;
			elsif(EVENTS4(I) = '1') and (RX_TCP_ACK_NO(15 downto 0)  = TX_SEQ_NO_local(I)(15 downto 0)) then  --*062316
				-- rx event: received a valid ACK, all outstanding data has been acknowledged
				-- turn off the retransmission timer.
				RX_VALID_ACK_TIMOUT(I) <= (others => '0');
			elsif(EVENTS4A(I) = '1') and (RX_TCP_ACK_NO(15 downto 0) /= TX_SEQ_NO_local(I)(15 downto 0)) then
				-- rx event: received a valid ACK, not a duplicate, acknowledging new data
				-- re-arm timer
				if(TXRX_DELAY(I)(18 downto 7) < x"03D") then	-- timeout min = 1s	*060919
					RX_VALID_ACK_TIMOUT(I) <= x"03D000";
				else
					RX_VALID_ACK_TIMOUT(I) <= TXRX_DELAY(I)(19 downto 0) & "0000"; -- 16* the average round-trip delay
				end if;
			elsif(TICK_4US = '1') and (RX_VALID_ACK_TIMOUT(I) > 1) then
				-- otherwise, decrement until counter reaches 1 (Re-transmit condition)
				RX_VALID_ACK_TIMOUT(I) <= RX_VALID_ACK_TIMOUT(I) -1;
			end if;
		end if;
	end process;

	RETRANSMIT_FLAG(I) <= '1' when (RX_VALID_ACK_TIMOUT(I) = 1) and (TX_SEQ_NO_JUMP_local(I) = '0') else '0'; 	-- *042419
end generate;

-- Measure round-trip delay: server -> client -> server
-- Units: 4us
TXRX_DELAY_x: for I in 0 to (NTCPSTREAMS-1) generate
	TXRX_DELAY_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TXRX_DELAY_STATE(I) <= '0';
				TXRX_DELAY_CNTR(I) <= (others => '0');
				TXRX_DELAY(I) <= x"01E848";  -- 0.5s worst case default (leave 6 extra MSBs for xX multiplication in timeout)
			elsif(TCP_STATE(I) = 0) then
				-- clear the last RT delay value at the start of connection
				TXRX_DELAY_STATE(I) <= '0';
				TXRX_DELAY_CNTR(I) <= (others => '0');
				TXRX_DELAY(I) <= x"01E848";  -- 0.5s worst case default (leave 6 extra MSBs for xX multiplication in timeout)
			elsif(TXRX_DELAY_STATE(I) = '0') and (TX_PACKET_SEQUENCE_START = '1') and (TX_TCP_STREAM_SEL(I) = '1') then
				-- regular tx event
				TXRX_DELAY_STATE(I) <= '1';
				-- start the stop watch
				TXRX_DELAY_CNTR(I) <= (others => '0');
			elsif(TXRX_DELAY_STATE(I) = '1') and (EVENTS4(I) = '1') then
				-- received ACK 
				TXRX_DELAY_STATE(I) <= '0';
				-- set a minimum RT delay value (here 32us)
				if(TXRX_DELAY_CNTR(I)(19 downto 3) = 0) then
					TXRX_DELAY(I) <= x"000008";
				else
					TXRX_DELAY(I) <= TXRX_DELAY_CNTR(I);
				end if;
			elsif(TXRX_DELAY_STATE(I) = '1') and (TICK_4US = '1') then
				-- increment stop watch up to 0.5s max
				if(TXRX_DELAY_CNTR(I) <  x"01E848") then
					TXRX_DELAY_CNTR(I) <= TXRX_DELAY_CNTR(I) + 1;
				else
					-- reached the max value of 0.5s
					TXRX_DELAY_STATE(I) <= '0';
					TXRX_DELAY(I) <= TXRX_DELAY_CNTR(I);
				end if;
			end if;
		end if;
	end process;
end generate;


--
-------------------------------------------------
---- Transmit data ------------------------------
-------------------------------------------------
-- 32-bit initial sequence number to be used at TCP connection time.
-- This is simply a counter incremented every 4 usec.
TCP_ISN_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		TCP_ISN_D <= TCP_ISN;	-- pipelining for better timing
		
		if(TICK_4US = '1') then
			TCP_ISN <= TCP_ISN + 1;
		end if;
	end if;
end process;

-- Manage tx sequence number. Changes based on INDEPENDENT rx and tx events (we may be receiving data about stream#1 
-- while transmitting data about stream#2).
-- To prevent deadlocks, TX_SEQ_NO should only change upon completing a frame transmission or when 
-- no data is waiting for transmission in TCP_TXBUF.
-- We keep two sets: TX_SEQ_NO_local has memory, TX_SEQ_NO_OUT_local is for output only, generally the same as TX_SEQ_NO_local
-- but can vary in special cases like probing (see keep-alive)
TX_SEQ_NO_INIT_GEN: process(TCP_ISN_D)
begin
	if(SIMULATION = '1') then
		-- During simulations, set the TX_SEQ_NO so that it matches Wireshark captures
		-- (sequence number in the SYN/ACK packet)
--		TX_SEQ_NO_INIT <= x"17a872a6";
		TX_SEQ_NO_INIT <= x"F0000000";
--		TX_SEQ_NO_INIT <= x"00000000";
	else
		-- use a random number (time)
		TX_SEQ_NO_INIT <= TCP_ISN_D;
	end if;
end process;	

TX_SEQ_NO_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	-- forward information to TXBUF (to compute effective rx window size and reposition the buffer read
	-- pointer)
	TX_SEQ_NO(I) <= std_logic_vector(TX_SEQ_NO_local(I));	-- don't need the entire 32-bits

	TX_SEQ_NO_GENx_001: process(CLK)
	begin
		if rising_edge(CLK) then 
			if(RX_TCP_STREAM_SEL(I) = '1') and (TCP_STATE(I) = 0) and (EVENT1 = '1') then
                -- Received valid SYN while in LISTEN state
				-- Save the initial sequence number
				TX_SEQ_NO_local(I) <= TX_SEQ_NO_INIT;
				TX_SEQ_NO_OUT_local(I) <= TX_SEQ_NO_INIT;
				TX_SEQ_NO_JUMP_local(I) <= '1';	
			elsif(TX_TCP_STREAM_SEL(I) = '1') and (TX_PACKET_TYPE = "11") and (TX_PACKET_SEQUENCE_START = '1') then
				-- regular tx event: 
				-- just triggered transmission of a frame with TX_PAYLOAD_SIZE payload bytes.
				TX_SEQ_NO_local(I) <= TX_SEQ_NO_local(I) + resize(unsigned(TX_PAYLOAD_SIZE), TX_SEQ_NO_local(I)'length);
				TX_SEQ_NO_OUT_local(I) <= TX_SEQ_NO_local(I) + resize(unsigned(TX_PAYLOAD_SIZE), TX_SEQ_NO_local(I)'length);
				TX_SEQ_NO_JUMP_local(I) <= '0';
			elsif(TX_TCP_STREAM_SEL(I) = '1') and (TX_PACKET_SEQUENCE_START = '1') and ((TX_FLAGS(I)(1) = '1') or (TX_FLAGS(I)(0) = '1'))then
				-- tx event: 
				-- SYN and FIN flags consumes a sequence number
				-- Update sequence number upon tx completion, getting ready for comparison with the RX_TCP_ACK_NO
				TX_SEQ_NO_local(I) <= TX_SEQ_NO_local(I) + 1;
				TX_SEQ_NO_OUT_local(I) <= TX_SEQ_NO_local(I) + 1;
				TX_SEQ_NO_JUMP_local(I) <= '1';
			elsif (RETRANSMIT_FLAG(I) = '1') and (CONNECTED_FLAG_local(I) = '1') then	-- NEW 11/4/11 AZ. this re-transmission scheme works only during connected state.
				-- tx event. timeout awaiting for ACK. Rewind TX_SEQ_NO which will indirectly cause a re-transmission since
				-- TCP_TXBUF will declare data ready to send.
				-- Rewind tx sequence number to the last acknowledged seq no at the start of retransmission
				TX_SEQ_NO_local(I) <= RX_TCP_ACK_NO_D_local(I);
				TX_SEQ_NO_OUT_local(I) <= RX_TCP_ACK_NO_D_local(I);
				TX_SEQ_NO_JUMP_local(I) <= '1';
			elsif (EVENTS4B(I) = '1') and (DUPLICATE_RX_TCP_ACK_CNTR(I) = 2) and 
				(RX_TCP_ACK_NO_D_local(I) /= FAST_REXMIT_SEQ_NO_START(I)) and
				(RX_TCP_ACK_NO_D_local(I) /= FAST_REXMIT_SEQ_NO_END(I)) then
				-- rx event: received 3 duplicate acks (could be a missed packet). 
				-- Do a TCP fast retransmission (while avoiding multiple fast retransmissions starting at the same tx seq no)
				-- Rewind tx sequence number to the last acknowledged seq no at the start of retransmission
				-- TCP_TXBUF will declare data ready to send.
				TX_SEQ_NO_local(I) <= RX_TCP_ACK_NO_D_local(I);
				TX_SEQ_NO_OUT_local(I) <= RX_TCP_ACK_NO_D_local(I);
				TX_SEQ_NO_JUMP_local(I) <= '1';
			elsif ((CONNECTED_FLAG_local(I) = '1') and (EVENTS11(I) = '1')) then
				-- non-tx related events		
				-- keep-alive or zero-window check: send a probe segment (zero-length, TX_SEQ_NO = RX_TCP_ACK_NO -1)
				TX_SEQ_NO_OUT_local(I) <= RX_TCP_ACK_NO_D_local(I) - 1;
			elsif(TX_TCP_STREAM_SEL(I) = '1') and (MAC_TX_EOF = '1') then
				-- after transmitting a probe segment , restore the normal TX_SEQ_NO 
				TX_SEQ_NO_OUT_local(I) <= TX_SEQ_NO_local(I);
			else
				TX_SEQ_NO_JUMP_local(I) <= '0';
			end if;
		end if;
	end process;

	-- remember the last rewind tx sequence number for TCP fast retransmission
	-- This mechanism is to avoid multiple fast retransmission at the same tx sequence number 
	-- which would otherwise occur because of propagation delay (tx keep receiving duplicate acks after a fast rexmit)
	FAST_REXMIT_001: process(CLK)
	begin
		if rising_edge(CLK) then 
			if (EVENTS4B(I) = '1') and (DUPLICATE_RX_TCP_ACK_CNTR(I) = 2) and
				(RX_TCP_ACK_NO_D_local(I) /= FAST_REXMIT_SEQ_NO_START(I)) and
				(RX_TCP_ACK_NO_D_local(I) /= FAST_REXMIT_SEQ_NO_END(I)) then
				-- TCP fast retransmit. Rewind address
				FAST_REXMIT_SEQ_NO_START(I) <= RX_TCP_ACK_NO_D_local(I);
				FAST_REXMIT_SEQ_NO_END(I) <= TX_SEQ_NO_local(I);
			end if;
		end if;
	end process;

end generate;
TX_SEQ_NO_JUMP <= TX_SEQ_NO_JUMP_local;



-- Manage tx TCP flags:  
-- (MSb) CWR Congestion Window Reduced (CWR) flag/ECE - ECN-Echo/URG/ACK/PSH/RST/SYN/FIN (LSb)
TX_FLAGS_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	TX_FLAGS_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_FLAGS(I) <= "00000000";	
			elsif(CONNECTED_FLAG_local(I) = '1') and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected. Send FIN/ACK.
				TX_FLAGS(I) <= "00010001";	
			elsif(CONNECTED_FLAG_local(I) = '1') and (TCP_KEEPALIVE_EN(I) = '1') and (KASTATE(I) = 0) then
				-- failed keepalive. Automatic disconnect. Send FIN/ACK.
				TX_FLAGS(I) <= "00010001";	
			elsif (TCP_STATE(I) = 7) and (EVENTS5(I) = '1') then
				-- received FIN after FIN. Send final ACK.
				TX_FLAGS(I) <= "00010000";	
			elsif (CONNECTED_FLAG_local(I) = '1') and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . Send ACK
				TX_FLAGS(I) <= "00010000";	
			elsif (TCP_STATE(I) = 4) and (EVENTS2(I) = '1') and (TX_FLAGS(I)(4) = '1') then
				-- sent ACK after receiving FIN. send final FIN/ACK
				TX_FLAGS(I) <= "00010001";	
			elsif(TCP_STATE_localrx = 0) and (EVENT1 = '1') then
				-- Received valid SYN while in LISTEN state
				TX_FLAGS(I) <= "00010010";	-- SYN flag set in response
			elsif (EVENT8 = '1') then
				-- CONNECTED state(implied in EVENT8). send or re-send data. set PUSH flag
				TX_FLAGS(I) <= "00011000";	-- flags in response
			elsif (TCP_STATE_localrx = 3) and ((EVENTS5(I) = '1') or (EVENT6 = '1') or (EVENTS10(I) = '1') or (EVENTS11(I) = '1')) then
				-- CONNECTED state. ACK only. clear PUSH flag
				TX_FLAGS(I) <= "00010000";	-- flags in response
			elsif(TCP_STATE_localrx = 4) and (EVENT2 = '1') then
				-- Connection termination. Send FIN
				TX_FLAGS(I) <= "00010001";	-- FIN/ACK flag set in response
			elsif ((CONNECTED_FLAG_local(I) = '1') and (EVENTS11(I) = '1')) then
				-- keep-alive or zero-window check: send a probe segment (zero-length, TX_SEQ_NO = RX_TCP_ACK_NO -1)
				TX_FLAGS(I) <= "00000000";	-- flags in response
			elsif (KA_PROBE_DET(I) = '1') then
				-- received a keep-alive probe segment. Send ack
				TX_FLAGS(I) <= "00010000";	-- flags in response
			end if;
		end if;
	end process;
end generate;


--// Test Point
-- TP(10 downto 1) <= (others => '0');
-- DEBUG
tp_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(TCP_MAX_WINDOW_SIZE = 17) then
			TP(1) <= '1';
		else
			TP(1) <= '0';
		end if;
		if(EVENT1 = '1') and (unsigned(TCP_OPTION_WINDOW_SCALE) = 0) then
			TP(2) <= '1';
		else
			TP(2) <= '0';
		end if;
		if(EVENT1 = '1') and (unsigned(TCP_OPTION_WINDOW_SCALE) = 1) then
			TP(3) <= '1';
		else
			TP(3) <= '0';
		end if;
		if(EVENT1 = '1') and (unsigned(TCP_OPTION_WINDOW_SCALE) = 8) then
			TP(4) <= '1';
		else
			TP(4) <= '0';
		end if;
		if(unsigned(TX_WINDOW_SCALE(0)) = 0) then
			TP(5) <= '1';
		else
			TP(5) <= '0';
		end if;
		if(unsigned(TX_WINDOW_SCALE(0)) = 1) then
			TP(6) <= '1';
		else
			TP(6) <= '0';
		end if;
		TP(7) <= '1';
		TP(8) <= '1';
		if((TCP_STATE_localrx = 0) and (EVENT1 = '1')) then
			TP(9) <= '1';
		else
			TP(9) <= '0';
		end if;
		
	end if;
end process;


--	tp_001: process(CLK)
--	begin
--		if rising_edge(CLK) then
--			TP(1) <= EVENT1;	-- connected
--			TP(2) <= VALID_RX_TCP0;	-- connected
--			TP(3) <= VALID_TCP_CHECKSUM;	-- connected
--			TP(4) <= RX_TCP_FLAGS(1);
--			TP(5) <= VALID_RX_TCP_ALL;
--			TP(6) <= IP_RX_FRAME_VALID;
--			TP(7) <= IP_PAYLOAD_WORD_VALID;
--			TP(8) <= IP_PAYLOAD_WORD_COUNT(0);
--			TP(9) <= IP_PAYLOAD_EOF_D;
--			TP(10) <= IP_PAYLOAD_SOF;	
--		end if;
--	end process;

--	tp_001: process(CLK)
--	begin
--		if rising_edge(CLK) then
--			TP(1) <= TX_PACKET_SEQUENCE_START;	
--			TP(2) <= TX_ACK_NO(0)(1);	
--			TP(3) <= RX_TCP_SEQ_NO(1);	
--			TP(4) <= IP_PAYLOAD_SOF_D;
--			TP(6) <= TX_ACK_NO2(1);
--			TP(7) <= TX_TCP_STREAM_SEL(0);
--			TP(8) <= RX_EOF_D and RX_FRAME_VALID_local;	
--			TP(9) <= RX_TCP_SEQ_NO_TRACK(1);
--		end if;
--	end process;

--	tp_002: process(CLK)
--	begin
--		if rising_edge(CLK) then
--			TP(1) <= EVENTS4(0);	
--			TP(2) <= EVENTS4A(0);	
--			TP(3) <= EVENTS4B(0);	
--			TP(4) <= EVENTS4C(0);
--			TP(6) <= RETRANSMIT_FLAG(0);
--			if(unsigned(RX_VALID_ACK_TIMOUT(0)) = 0) then
--				TP(7) <= '1';
--			else
--				TP(7) <= '0';
--			end if;
--			TP(8) <= TX_PACKET_SEQUENCE_START;	
--			TP(9) <= RX_VALID_ACK_TIMOUT(0)(0);	
--		end if;
--	end process;

--	tp_001: process(CLK)
--	begin
--		if rising_edge(CLK) then
--			TP(1) <= EVENTS4B(1);
--			TP(2) <= TX_SEQ_NO_JUMP_local(1);
--			if(EVENTS4B(1) = '1') and (DUPLICATE_RX_TCP_ACK_CNTR(1) = 2) then
--				TP(3) <= '1';
--			else
--				TP(3) <= '0';
--			end if;
--			TP(4) <= RETRANSMIT_FLAG(1);
--			TP(5) <= EVENT2;	
--		end if;
--	end process;
end Behavioral;
