-------------------------------------------------------------
-- MSS copyright 2021
--	Filename:  COM5503.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 5
--	Date last modified: 1/18/21
-- Inheritance: 	COM5502.VHD 
--
-- description:  10Gbit Internet IP stack: IP/TCP clients/UDP/ARP/PING.
-- The IP stack relies on the lower layers: MAC (for example COM5501) and PHY (Integrated circuit)
-- Interfaces directly with COM-5501SOFT 10GbE MAC protocol layer and the COM-5401SOFT 1GbE MAC.
--
-- Rev 1 4/27/19 AZ
-- Added IGMP for multicast addresses
--
-- Rev 2 6/7/19 AZ
-- Corrected bug about the timeliness of RX_IP_PROTOCOL (cleared to early)
-- Corrected bug on CHECK_UDP_RX_DEST_PORT_NO outside of UDP_RX_10G
-- 
-- Rev 3 1/19/20
-- Corrected bug in TCP MSS option
--
-- Rev 4 10/28/20
-- Corrected bug in ARP cache when NUDP = 0.
--
-- Rev 5 1/19/21 AZ
-- Added window size to generic parameters
-- Increased RX_FREE_SPACE to 32-bit in preparation for window scaling.
-- Added window scaling option
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.com5502pkg.all;	-- defines global types, number of TCP streams, etc

entity COM5503 is
	generic (
		NTCPSTREAMS: integer range 0 to 255 := 1;  
			-- number of concurrent TCP streams handled by this component
		NUDPTX: integer range 0 to 1:= 1;
		NUDPRX: integer range 0 to 1:= 1;
			-- Enable/disable UDP protocol for tx and rx
		TCP_TX_WINDOW_SIZE: integer range 11 to 20 := 15;
		TCP_RX_WINDOW_SIZE: integer range 11 to 20 := 15;
			-- Window size is expressed as 2**n Bytes. Thus a value of 15 indicates a window size of 32KB.
			-- this generic parameter determines how much memory is allocated to buffer tcp tx/rx streams. 
			-- It applies equally to all concurrent streams (no individualization)
			-- purpose: tradeoff memory utilization vs throughput. 
			-- Memory size ranges from 2KB (multiple streams/lower individual throughput) to 1MB (single stream/maximum throughput)
		IPv6_ENABLED: std_logic := '1';
            -- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		DHCP_CLIENT_EN: std_logic := '1';
			-- '0' for static address (for minimum size), '1' for static/dynamic address (instantiates a DHCP_CLIENT component)
		IGMP_EN: std_logic := '1';
			-- '1' to enable UDP multicast (which requires IGMP)
		TX_IDLE_TIMEOUT: integer range 0 to 50:= 50;	
			-- inactive input timeout, expressed in 4us units. -- 50*4us = 200us 
			-- Controls the TCP transmit stream segmentation: data in the elastic buffer will be transmitted if
			-- no input is received within TX_IDLE_TIMEOUT, without waiting for the transmit frame to be filled with MSS data bytes.
		TCP_KEEPALIVE_PERIOD: integer := 60;
			-- period in seconds for sending no data keepalive frames. 
			-- "Typically TCP Keepalives are sent every 45 or 60 seconds on an idle TCP connection, and the connection is 
			-- dropped after 3 sequential ACKs are missed" 
		CLK_FREQUENCY: integer := 156;
			-- CLK frequency in MHz. Needed to compute actual delays.
		SIMULATION: std_logic := '0'
			-- 1 during simulation with Wireshark .cap file, '0' otherwise
			-- Wireshark many not be able to collect offloaded checksum computations.
			-- when SIMULATION =  '1': (a) IP header checksum is valid if 0000,
			-- (b) TCP checksum computation is forced to a valid 00001 irrespective of the 16-bit checksum
			-- captured by Wireshark.
	);
    Port ( 
		--//-- CLK, RESET
		CLK: in std_logic;
			-- 10G: PHY/MAC clock at 156.25 MHz
			-- 1G: User clock. Must be 125 MHz or above for 1G, 25 MHz or above for 100Mbps
			-- GLOBAL clock
		SYNC_RESET: in std_logic;
			-- CLK-synchronous reset. MANDATORY after all configuration fields are defined.
		
		--//-- CONFIGURATION
		-- usage: use SYNC_RESET after a configuration change
		MAC_ADDR: in std_logic_vector(47 downto 0);
		DYNAMIC_IPv4: in std_logic;	
			-- '1' if dynamic IPv4 address using an external DHCP server, '0' if fixed (static) IPv4 address.
			-- Dynamic IP address requires the generic parameter DHCP_CLIENT_EN = '1' to instantiate a DHCP client within.
		REQUESTED_IPv4_ADDR: in std_logic_vector(31 downto 0);
			-- fixed IP address if static, or requested IP address if dynamic (DHCP_CLIENT_EN and DYNAMIC_IP = '1').
			-- In the case of dynamic IP, this is typically the last IP address, as stored in external non-volatile memory.
			-- In the case of dynamic IP, use 0.0.0.0 if no previous IP address is available.
			-- In the case of dynamic IP, this field is read only when SYNC_RESET = '1'
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
		IPv4_MULTICAST_ADDR: in std_logic_vector(31 downto 0); 
            -- to receive UDP multicast messages. One multicast address only
            -- 0.0.0.0 to signify that IP multicasting is not supported here.
		IPv4_SUBNET_MASK: in std_logic_vector(31 downto 0);
		IPv4_GATEWAY_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
            -- local IP address. 16 bytes for IPv6
		IPv6_SUBNET_PREFIX_LENGTH: in std_logic_vector(7 downto 0);
				 -- 128 - subnet size in bits. Usually expressed as /n. Typical range 64-128
		IPv6_GATEWAY_ADDR: in std_logic_vector(127 downto 0);

		--// User controls
		TCP_DEST_IP_ADDR: in SLV128xNTCPSTREAMStype;
		TCP_DEST_IPv4_6n: in std_logic_vector(NTCPSTREAMS-1 downto 0);
		TCP_DEST_PORT: in SLV16xNTCPSTREAMStype;
			-- for each TCP client, specify the destination TCP server when STATE is idle, prior to requesting a connection
		TCP_STATE_REQUESTED: in std_logic_vector(NTCPSTREAMS-1 downto 0);
			-- ask for TCP connection. Request states:
			-- 0 = go back to idle (terminate connection if currently connected or connecting)
			-- 1 = initiate connection
		TCP_STATE_STATUS: out SLV4xNTCPSTREAMStype;
			-- monitor connection state AFTER a connection request
			-- connection closed (0), connecting (1), connected (2), unreacheable IP (3), destination port busy (4)
		TCP_KEEPALIVE_EN: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- enable TCP Keepalive (1) or not (0)

		--//-- Protocol -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended by the MAC layer. User should not supply it.
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
			-- Bytes order: LSB was received first
			-- Bytes are right aligned: first byte in LSB, occasional follow-on fill-in Bytes in the MSB(s)
			-- The first destination address byte is always a LSB (MAC_TX_DATA(7:0))
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- data valid, for each byte in MAC_TX_DATA
		MAC_TX_SOF: out std_logic;
			-- start of frame: '1' when sending the first byte. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_EOF: out std_logic;
			-- End of frame: '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal, indicating room in the 
			-- MAC tx elastic buffer for a complete frame of size MTU 
			-- The user should check that this signal is high before deciding to send
			-- sending the next frame. 
		MAC_TX_RTS: out std_logic;
			-- '1' when at least one of the inner processes is ready to transmit. Will on transmit when CTS goes high.
			-- useful if there is an external transmission arbiter (for example in the case of multiple clients)

		--//-- Receive MAC -> Protocol
		-- Valid rx packets only: packets with bad CRC or invalid address are discarded in the MAC
		-- The 32-bit CRC is always removed by the MAC layer.
		MAC_RX_DATA: in std_logic_vector(63 downto 0);
			-- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID /= 0
			-- Bytes order: LSB was received first
			-- Bytes are right aligned: first byte in LSB, occasional follow-on fill-in Bytes in the MSB(s)
			-- The first destination address byte is always a LSB (MAC_RX_DATA(7:0))
		MAC_RX_DATA_VALID: in std_logic_vector(7 downto 0);
			-- data valid, for each byte in MAC_RX_DATA
		MAC_RX_SOF: in std_logic;
			-- '1' when sending the first byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_EOF: in std_logic;
			-- '1' when sending the last byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_FRAME_VALID: in std_logic;
			-- this component verifies the frame validity (CRC good, length, MAC address) at
			-- the end of the frame (when MAC_RX_EOF). 

		--//-- Application <- UDP rx payload
		UDP_RX_DATA: out std_logic_vector(63 downto 0);
 		    -- byte order: MSB first (reason: easier to read contents during simulation)
		UDP_RX_DATA_VALID: out std_logic_vector(7 downto 0);
		    -- example: 1 byte -> 0x80, 2 bytes -> 0xC0
		UDP_RX_SOF: out std_logic;	   -- start of UDP payload data field
		UDP_RX_EOF: out std_logic;	   -- end of UDP frame
		UDP_RX_FRAME_VALID: out std_logic;
			-- check entire frame validity at UDP_RX_EOF
			-- 1 CLK pulse indicating that UDP_RX_DATA is the last byte in the UDP payload data field.
			-- ALWAYS CHECK UDP_RX_FRAME_VALID at the end of packet (UDP_RX_EOF = '1') to confirm
			-- that the UDP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid UDP packet.
			-- Reason: we only knows about bad UDP packets at the end.
		UDP_RX_DEST_PORT_NO_IN: in std_logic_vector(15 downto 0);
		CHECK_UDP_RX_DEST_PORT_NO: in std_logic;
			-- check the destination port number matches UDP_RX_DEST_PORT_NO (1) or ignore it (0)
			-- The latter case is useful when this component is shared among multiple UDP ports
		UDP_RX_DEST_PORT_NO_OUT: out std_logic_vector(15 downto 0);
			-- Collected destination UDP port in received UDP frame. Read when APP_EOF = '1' 
				
		--//-- Application -> UDP tx
		UDP_TX_DATA: in std_logic_vector(63 downto 0);
			-- byte order: MSB first (reason: easier to read contents during simulation)
			-- unused bytes are expected to be zeroed
		UDP_TX_DATA_VALID: in std_logic_vector(7 downto 0);
		    -- example: 1 byte -> 0x80, 2 bytes -> 0xC0
		UDP_TX_SOF: in std_logic;	-- 1 CLK-wide pulse to mark the first byte in the tx UDP frame
		UDP_TX_EOF: in std_logic;	-- 1 CLK-wide pulse to mark the last byte in the tx UDP frame
		UDP_TX_CTS: out std_logic;	
		UDP_TX_ACK: out std_logic;	-- 1 CLK-wide pulse indicating that the previous UDP frame is being sent
		UDP_TX_NAK: out std_logic;	-- 1 CLK-wide pulse indicating that the previous UDP frame could not be sent
		UDP_TX_DEST_IP_ADDR: in std_logic_vector(127 downto 0);
		UDP_TX_DEST_IPv4_6n: in std_logic;
		UDP_TX_DEST_PORT_NO: in std_logic_vector(15 downto 0);
		UDP_TX_SOURCE_PORT_NO: in std_logic_vector(15 downto 0);
			-- the IP and port information is latched in at the UDP_TX_SOF pulse.
			-- USAGE: wait until the previous UDP tx frame UDP_TX_ACK or UDP_TX_NAK to send the follow-on UDP tx frame
		
		--//-- Application <- TCP rx
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
        -- Usage: application raises the Clear-To-Send flag for one CLK. If a 64-bit word is available to be read, it is
        -- placed in RX_APP_DATA with a latency of 2 CLKs. In this case RX_APP_DATA_VALID(I) = x"FF" indicating a data width of 8 bytes.
        -- The application can also request to 'peek' into the next 8-bytes in memory by raising RX_APP_PEEK_NEXT(I) for one CLK. 
        -- The data will also be placed in RX_APP_DATA and the width (which can be 1-8 bytes) will  be placed in RX_APP_DATA_VALID.
        -- Peeking does not advance the read pointer. It is mutually exclusive with a Clear-To-Send request. It has lower priority.
		TCP_LOCAL_PORTS: in SLV16xNTCPSTREAMStype;
			-- TCP_CLIENTS ports configuration. Each one of the NTCPSTREAMS streams handled by this
			-- component must be configured with a distinct port number. 
			-- This value is used as destination port number to filter incoming packets, 
			-- and as source port number in outgoing packets.
		TCP_RX_DATA: out SLV64xNTCPSTREAMStype;
		TCP_RX_DATA_VALID: out SLV8xNTCPSTREAMStype;
		TCP_RX_RTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	-- Ready To Send
		TCP_RX_CTS: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- 1 CLK pulse to read the next (partial) word TCP_RX_DATA
			-- Latency: 2 CLKs to TCP_RX_DATA, but only IF AND ONLY IF the next word has at least one available byte.
		TCP_RX_CTS_ACK: out std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- '1' the TCP_RX_CTS request for new data is accepted:
			-- indicating that a new (maybe partial) word will be placed on the output TCP_RX_DATA at the next CLK.
		
		--//-- Application -> TCP tx
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
		TCP_TX_DATA: in SLV64xNTCPSTREAMStype;
		TCP_TX_DATA_VALID: in SLV8xNTCPSTREAMStype;
	   TCP_TX_DATA_FLUSH: in std_logic_vector((NTCPSTREAMS-1) downto 0);	
		TCP_TX_CTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	
			-- Clear To Send = transmit flow control. 
			-- App is responsible for checking the CTS signal before sending APP_DATA
 		    -- byte order: MSB first (reason: easier to read contents during simulation)
			-- All input words must include 8 bytes of data (TCP_TX_DATA_VALID = x"FF") except the last word which can 
            -- be partially filled with 1-8 bytes of data.

		--//-- TEST POINTS, COMSCOPE TRACES
		TCP_CONNECTED_FLAG: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		MTU: in std_logic_vector(13 downto 0);
      -- Maximum Transmission Unit: maximum number of payload Bytes.
      -- Typically 1500 for standard frames, 9000 for jumbo frames.
      -- A frame will be deemed invalid if its payload size exceeds this MTU value.
      -- Should match the values in MAC layer)
      -- For maximum TCP throughput, select MTU = (buffer size/4) + 60 bytes (IP/TCP header)
      -- for example, when ADDR_WIDTH = 12, best MTU is 8252. It will work at MTU = 9000 but with a 
      -- small degradation in TCP throughput.
		CS1: out std_logic_vector(7 downto 0);
		CS1_CLK: out std_logic;
		CS2: out std_logic_vector(7 downto 0);
		CS2_CLK: out std_logic;
		DEBUG1: out std_logic_vector(63 downto 0);
		DEBUG2: out std_logic_vector(63 downto 0);
		DEBUG3: out std_logic_vector(63 downto 0);
		TP: out std_logic_vector(10 downto 1);
		COM5503_DEBUG             : out COM5503_DEBUG_TYPE;
    COM5503_TCP_CLIENTS_DEBUG : out COM5503_TCP_CLIENTS_DEBUG_TYPE;
    COM5503_TCP_TXBUF_DEBUG   : out COM5503_TCP_TXBUF_DEBUG_TYPE
 );
end entity;

architecture Behavioral of COM5503 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT TIMER_4US
	GENERIC (
		CLK_FREQUENCY: integer 
	);
	PORT(
		CLK: in std_logic;          
		SYNC_RESET: in std_logic;
		TICK_4US: out std_logic;
		TICK_100MS: out std_logic
		);
	END COMPONENT;

	COMPONENT PACKET_PARSING_10G
	GENERIC (
		IPv6_ENABLED: std_logic;
		SIMULATION: std_logic
	);	
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		MAC_RX_DATA: in std_logic_vector(63 downto 0);
		MAC_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		MAC_RX_SOF: in std_logic;
		MAC_RX_EOF: in std_logic;
		MAC_RX_FRAME_VALID: in std_logic;
		MAC_RX_WORD_COUNT: out std_logic_vector(10 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv4_MULTICAST_ADDR: in std_logic_vector(31 downto 0); 
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		IP_RX_DATA: out std_logic_vector(63 downto 0);
		IP_RX_DATA_VALID: out std_logic_vector(7 downto 0);
		IP_RX_SOF: out std_logic;
		IP_RX_EOF: out std_logic;
		IP_RX_WORD_COUNT: out std_logic_vector(10 downto 0);	
		IP_HEADER_FLAG: out std_logic_vector(1 downto 0);
		RX_TYPE: out std_logic_vector(3 downto 0);
		RX_TYPE_RDY: out std_logic;
		RX_IPv4_6n: out std_logic;
		RX_IP_PROTOCOL: out std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY: out std_logic;
		IP_RX_FRAME_VALID: out std_logic; 
		IP_RX_FRAME_VALID2: out std_logic;
		VALID_UNICAST_DEST_IP: out std_logic;
		VALID_MULTICAST_DEST_IP: out std_logic;
		VALID_DEST_IP_RDY: out std_logic;
		IP_HEADER_CHECKSUM_VALID: out std_logic;
		IP_HEADER_CHECKSUM_VALID_RDY: out std_logic;
		RX_SOURCE_MAC_ADDR: out std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: out std_logic_vector(127 downto 0);
		RX_DEST_IP_ADDR: out std_logic_vector(127 downto 0);
		IP_PAYLOAD_DATA: out std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: out std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: out std_logic;
		IP_PAYLOAD_EOF: out std_logic;
		IP_PAYLOAD_LENGTH: out std_logic_vector(15 downto 0);
		IP_PAYLOAD_WORD_COUNT: out std_logic_vector(10 downto 0);    
		VALID_IP_PAYLOAD_CHECKSUM: out std_logic;
		VALID_UDP_CHECKSUM: out std_logic;
		VALID_TCP_CHECKSUM: out std_logic;

		CS1: out std_logic_vector(7 downto 0);
		CS1_CLK: out std_logic;
		CS2: out std_logic_vector(7 downto 0);
		CS2_CLK: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT ARP_10G
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		MAC_RX_DATA: in std_logic_vector(63 downto 0);
		MAC_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		MAC_RX_SOF: in std_logic;
		MAC_RX_EOF: in std_logic;
		MAC_RX_FRAME_VALID: in std_logic;
		MAC_RX_WORD_COUNT: in std_logic_vector(10 downto 0);
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		RX_TYPE: in std_logic_vector(3 downto 0);
		RX_TYPE_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0);
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		MAC_TX_CTS: in std_logic;          
		RTS: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT ICMPV6_10G
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		IP_RX_DATA: in std_logic_vector(63 downto 0);
		IP_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_RX_SOF: in std_logic;
		IP_RX_EOF: in std_logic;
		IP_RX_WORD_COUNT: in std_logic_vector(10 downto 0);	
		IP_RX_FRAME_VALID: in std_logic; 
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		RX_IPv4_6n: in std_logic;
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY: in std_logic;
		MAC_TX_CTS: in std_logic;          
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		RTS: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT PING_10G
	GENERIC (
		IPv6_ENABLED: std_logic;
		MAX_PING_SIZE: std_logic_vector(7 downto 0)
	);	
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		IP_RX_DATA: in std_logic_vector(63 downto 0);
		IP_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_RX_SOF: in std_logic;
		IP_RX_EOF: in std_logic;
		IP_RX_WORD_COUNT: in std_logic_vector(10 downto 0);	
		IP_RX_FRAME_VALID2: in std_logic;
		VALID_UNICAST_DEST_IP: in std_logic;
		VALID_DEST_IP_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		RX_IPv4_6n: in std_logic;
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY: in std_logic;
		MAC_TX_CTS: in std_logic;          
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		RTS: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT WHOIS2_10G
	GENERIC (
        IPv6_ENABLED: std_logic
    );    
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		WHOIS_IP_ADDR: in std_logic_vector(127 downto 0);
		WHOIS_IPv4_6n: in std_logic;
		WHOIS_START: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		MAC_TX_CTS: in std_logic;          
		WHOIS_RDY: out std_logic;
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		RTS: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT ARP_CACHE2_10G
	GENERIC (
        IPv6_ENABLED: std_logic
    );    
	PORT(
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		TICK_100MS: in std_logic;          
		RT_IP_ADDR: in std_logic_vector(127 downto 0);
		RT_IPv4_6n: in std_logic;
		RT_REQ_RTS: in std_logic;
		RT_CTS: out std_logic;	
		RT_MAC_REPLY: out std_logic_vector(47 downto 0);
		RT_MAC_RDY: out std_logic;
		RT_NAK: out std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv4_SUBNET_MASK: in std_logic_vector(31 downto 0);
		IPv4_GATEWAY_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		IPv6_SUBNET_PREFIX_LENGTH: in std_logic_vector(7 downto 0);
		IPv6_GATEWAY_ADDR: in std_logic_vector(127 downto 0);
		RX_SOURCE_ADDR_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);	
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0); 
		RX_IPv4_6n: in std_logic;
		WHOIS_IP_ADDR: out std_logic_vector(127 downto 0);
		WHOIS_IPv4_6n: out std_logic;
		WHOIS_START: out std_logic;
		SREG1: out std_logic_vector(7 downto 0);
		SREG2: out std_logic_vector(7 downto 0);
		SREG3: out std_logic_vector(7 downto 0);
		SREG4: out std_logic_vector(7 downto 0);
		SREG5: out std_logic_vector(7 downto 0);
		SREG6: out std_logic_vector(7 downto 0);
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT DHCP_CLIENT_10G
	GENERIC (
        SIMULATION: std_logic
    );    
	PORT(
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		TICK_4US: in std_logic;
		TICK_100MS: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		LAST_IPv4_ADDR: in std_logic_vector(31 downto 0);
		IP_ID_IN: in std_logic_vector(15 downto 0);
		UDP_RX_DATA: in std_logic_vector(63 downto 0);
		UDP_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		UDP_RX_SOF: in std_logic;
		UDP_RX_EOF: in std_logic;
		UDP_RX_FRAME_VALID: in std_logic;
		UDP_RX_DEST_PORT_NO: in std_logic_vector(15 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0);
		MAC_TX_CTS: in std_logic;          
		IPv4_ADDR: out std_logic_vector(31 downto 0);
		LEASE_TIME: out std_logic_vector(31 downto 0);
		SUBNET_MASK: out std_logic_vector(31 downto 0);
		ROUTER: out std_logic_vector(31 downto 0);
		DNS1: out std_logic_vector(31 downto 0);
		DNS2: out std_logic_vector(31 downto 0);
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		RTS: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT IGMP_QUERY_10G
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		MULTICAST_IP_ADDR: in std_logic_vector(31 downto 0);
		IP_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: in std_logic;
		IP_PAYLOAD_EOF: in std_logic;
		IP_PAYLOAD_WORD_COUNT: in std_logic_vector(10 downto 0);    
		IP_RX_FRAME_VALID2: in std_logic; 
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
		VALID_MULTICAST_DEST_IP: IN std_logic;
		VALID_IP_PAYLOAD_CHECKSUM: in std_logic;
		RX_DEST_IP_ADDR: in std_logic_vector(31 downto 0);  	
		TRIGGER_RESPONSE: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT IGMP_REPORT_10G
	PORT(
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		IGMP_START: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IP_ID: in std_logic_vector(15 downto 0);
		MULTICAST_IP_ADDR: in std_logic_vector(31 downto 0);
		MAC_TX_CTS: in std_logic;          
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		RTS: out std_logic;
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

--	COMPONENT UDP2SERIAL_10G
--	GENERIC (
--		PORT_NO: std_logic_vector(15 downto 0);
--		CLK_FREQUENCY: integer
--	);	
--	PORT(
--		CLK: in std_logic;
--		SYNC_RESET: in std_logic;
--		IP_RX_DATA: in std_logic_vector(7 downto 0);
--		IP_RX_DATA_VALID: in std_logic;
--		IP_RX_SOF: in std_logic;
--		IP_RX_EOF: in std_logic;
--		IP_HEADER_FLAG: in std_logic;
--		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
--		RX_IP_PROTOCOL_RDY: in std_logic;
--		SERIAL_OUT: out std_logic;
--		TP: out std_logic_vector(10 downto 1)
--		);
--	END COMPONENT;
--
	COMPONENT UDP_RX_10G
	PORT(
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		IP_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: in std_logic;
		IP_PAYLOAD_EOF: in std_logic;
		IP_PAYLOAD_WORD_COUNT: in std_logic_vector(10 downto 0);    
		IP_RX_FRAME_VALID: in std_logic; 
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
		VALID_UDP_CHECKSUM: in std_logic;
		PORT_NO: in std_logic_vector(15 downto 0);
		CHECK_UDP_RX_DEST_PORT_NO: in std_logic;
		UDP_RX_DATA: out std_logic_vector(63 downto 0);
		UDP_RX_DATA_VALID: out std_logic_vector(7 downto 0);
		UDP_RX_SOF: out std_logic;
		UDP_RX_EOF: out std_logic;
		UDP_RX_FRAME_VALID: out std_logic;
		UDP_RX_SRC_PORT: out std_logic_vector(15 downto 0);			
		UDP_RX_DEST_PORT: out std_logic_vector(15 downto 0);
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT UDP_TX_10G
	generic (
		ADDR_WIDTH: integer;
		UDP_CKSUM_ENABLED: std_logic;
		IPv6_ENABLED: std_logic
	);
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		TICK_4US: in std_logic;
		APP_DATA: in std_logic_vector(63 downto 0);
		APP_DATA_VALID: in std_logic_vector(7 downto 0);
		APP_SOF: in std_logic;
		APP_EOF: in std_logic;
		APP_CTS: out std_logic;
		DEST_IP_ADDR: in std_logic_vector(127 downto 0);	
		IPv4_6n: in std_logic;
		DEST_PORT_NO: in std_logic_vector(15 downto 0);
		SOURCE_PORT_NO: in std_logic_vector(15 downto 0);
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		IP_ID: in std_logic_vector(15 downto 0);
		ACK: out std_logic;
		NAK: out std_logic;
		RT_IP_ADDR: out std_logic_vector(127 downto 0);
		RT_IPv4_6n: out std_logic;
		RT_REQ_RTS: out std_logic;
		RT_REQ_CTS: in std_logic;
		RT_MAC_REPLY: in std_logic_vector(47 downto 0);
		RT_MAC_RDY: in std_logic;
		RT_NAK: in std_logic;
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		MAC_TX_CTS: in std_logic;          
		RTS: out std_logic := '0';
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT TCP_CLIENTS_10G
	GENERIC (
		NTCPSTREAMS: integer;
		TCP_MAX_WINDOW_SIZE: integer range 8 to 20;
		WINDOW_SCALING_ENABLED: std_logic;
		TCP_KEEPALIVE_PERIOD: integer;
		IPv6_ENABLED: std_logic;
		SIMULATION: std_logic
	);	
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		TICK_4US: in std_logic;
		TICK_100MS: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		TCP_LOCAL_PORTS: in SLV16xNTCPSTREAMStype;
		DEST_IP_ADDR: in SLV128xNTCPSTREAMStype;
		DEST_IPv4_6n: in std_logic_vector(NTCPSTREAMS-1 downto 0);
		DEST_PORT: in SLV16xNTCPSTREAMStype;
		STATE_REQUESTED: in std_logic_vector(NTCPSTREAMS-1 downto 0);
		STATE_STATUS: out SLV4xNTCPSTREAMStype;
		TCP_KEEPALIVE_EN: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		RT_IP_ADDR: out std_logic_vector(127 downto 0);
		RT_IPv4_6n: out std_logic;
		RT_REQ_RTS: out std_logic;
		RT_REQ_CTS: in std_logic;
		RT_MAC_REPLY: in std_logic_vector(47 downto 0);
		RT_MAC_RDY: in std_logic;
		RT_NAK: in std_logic;
		IP_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: in std_logic;
		IP_PAYLOAD_EOF: in std_logic;
		IP_PAYLOAD_WORD_COUNT: in std_logic_vector(10 downto 0);
		IP_RX_FRAME_VALID: in std_logic;
		RX_IPv4_6n: in std_logic;
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
	  	RX_IP_PROTOCOL_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);
		VALID_TCP_CHECKSUM: in std_logic;
		RX_DATA: out std_logic_vector(63 downto 0);
		RX_DATA_VALID: out std_logic_vector(7 downto 0);
		RX_SOF: out std_logic;
		RX_TCP_STREAM_SEL_OUT: out std_logic_vector(NTCPSTREAMS-1 downto 0);
		RX_EOF: out std_logic;
		RX_FRAME_VALID: out std_logic;
		RX_FREE_SPACE: in SLV32xNTCPSTREAMStype;
		TX_PACKET_SEQUENCE_START_OUT: out std_logic;	
		TX_STREAM_SEL: in std_logic_vector(NTCPSTREAMS-1 downto 0);
		TX_PAYLOAD_RTS: in std_logic;
		TX_PAYLOAD_SIZE: in std_logic_vector(15 downto 0);          
		TX_DEST_MAC_ADDR_OUT: out std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_OUT: out std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_OUT: out std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_OUT: out std_logic_vector(15 downto 0);
		TX_IPv4_6n_OUT: out std_logic;
		TX_SEQ_NO_OUT: out std_logic_vector(31 downto 0);
		TX_ACK_NO_OUT: out std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_OUT: out std_logic_vector(15 downto 0);
		TX_FLAGS_OUT: out std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_OUT: out std_logic_vector(1 downto 0); 
		TX_WINDOW_SCALE_OUT: out std_logic_vector(3 downto 0); 
		MAC_TX_EOF: in std_logic;
		RTS: out std_logic := '0';
		EFF_RX_WINDOW_SIZE_PARTIAL: out std_logic_vector(31 downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: out std_logic_vector(NTCPSTREAMS-1 downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: out std_logic;
		TX_SEQ_NO: out SLV32xNTCPSTREAMStype;
		TX_SEQ_NO_JUMP: out std_logic_vector(NTCPSTREAMS-1 downto 0);
		RX_TCP_ACK_NO_D: out SLV32xNTCPSTREAMStype;
		CONNECTED_FLAG: out std_logic_vector(NTCPSTREAMS-1 downto 0);
		MSS: in std_logic_vector(13 downto 0);
		TP: out std_logic_vector(10 downto 1);
		COM5503_TCP_CLIENTS_DEBUG : out COM5503_TCP_CLIENTS_DEBUG_TYPE
		);
	END COMPONENT;
	
    COMPONENT TCP_TXBUF_10G is
	generic (
		NTCPSTREAMS: integer;  
		ADDR_WIDTH: integer range 8 to 27;
		TX_IDLE_TIMEOUT: integer range 0 to 50;
		SIMULATION: std_logic
	);
    Port ( 
		--//-- CLK, RESET
		CLK: in std_logic;		
		SYNC_RESET: in std_logic;
		TICK_4US: in std_logic;
		APP_DATA: in SLV64xNTCPSTREAMStype;
		APP_DATA_VALID: in SLV8xNTCPSTREAMStype;
		APP_CTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	
		APP_DATA_FLUSH: in std_logic_vector((NTCPSTREAMS-1) downto 0);	
		EFF_RX_WINDOW_SIZE_PARTIAL_IN: in std_logic_vector(31 downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: in std_logic; -- 1 CLK-wide pulse to indicate that the above information is valid
		TX_SEQ_NO_IN: in SLV32xNTCPSTREAMStype;
		TX_SEQ_NO_JUMP: in std_logic_vector(NTCPSTREAMS-1 downto 0);
		RX_TCP_ACK_NO_D: in SLV32xNTCPSTREAMStype;
		CONNECTED_FLAG: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		TX_STREAM_SEL: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		TX_PAYLOAD_RTS: out std_logic;
		TX_PAYLOAD_CHECKSUM: out std_logic_vector(17 downto 0);
		TX_PAYLOAD_SIZE: out std_logic_vector(15 downto 0);
		TX_PAYLOAD_CTS: in std_logic;
		TX_PAYLOAD_DATA: out std_logic_vector(63 downto 0);
		TX_PAYLOAD_DATA_VALID: out std_logic_vector(7 downto 0);
		TX_PAYLOAD_WORD_VALID: out std_logic;
		TX_PAYLOAD_DATA_EOF: out std_logic;
		MSS: in std_logic_vector(13 downto 0);
		TP: out std_logic_vector(10 downto 1)--;
		--COM5503_TCP_TXBUF_DEBUG : out COM5503_TCP_TXBUF_DEBUG_TYPE

			);
    end COMPONENT;

	COMPONENT TCP_TX_10G
	GENERIC (
		IPv6_ENABLED: std_logic
	);	
	PORT(
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		TX_PACKET_SEQUENCE_START: in std_logic;
		TX_DEST_MAC_ADDR_IN: in std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_IN: in std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_IN: in std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_IN: in std_logic_vector(15 downto 0);
		TX_IPv4_6n_IN: in std_logic;
		TX_SEQ_NO_IN: in std_logic_vector(31 downto 0);
		TX_ACK_NO_IN: in std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_IN: in std_logic_vector(15 downto 0);
		IP_ID_IN: in std_logic_vector(15 downto 0);
		TX_FLAGS_IN: in std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_IN: in std_logic_vector(1 downto 0);
		TX_WINDOW_SCALE_IN: in std_logic_vector(3 downto 0);
		TX_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		TX_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		TX_PAYLOAD_WORD_VALID: IN std_logic;
		TX_PAYLOAD_DATA_EOF: in std_logic;
		TX_PAYLOAD_RTS: in std_logic;
		TX_PAYLOAD_CTS: out std_logic;
		TX_PAYLOAD_SIZE: in std_logic_vector(15 downto 0);
		TX_PAYLOAD_CHECKSUM: in std_logic_vector(17 downto 0);
		MAC_TX_CTS: in std_logic;          
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
		MAC_TX_EOF: out std_logic;
		MSSv4: in std_logic_vector(13 downto 0);
		MSSv6: in std_logic_vector(13 downto 0);
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;
	

	COMPONENT TCP_RXBUFNDEMUX2_10G
	GENERIC (
		NTCPSTREAMS: integer;  
		ADDR_WIDTH: integer range 8 to 27
	);	
	PORT(
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		RX_DATA: in std_logic_vector(63 downto 0);
		RX_DATA_VALID: in std_logic_vector(7 downto 0);
		RX_SOF: in std_logic;
		RX_TCP_STREAM_SEL: in std_logic_vector(NTCPSTREAMS-1 downto 0);
		RX_EOF: in std_logic;
		RX_FRAME_VALID: in std_logic;
		RX_FREE_SPACE: out SLV32xNTCPSTREAMStype;
		RX_BUF_CLR: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_DATA: out SLV64xNTCPSTREAMStype;
		RX_APP_DATA_VALID: out SLV8xNTCPSTREAMStype;
		RX_APP_RTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_CTS: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_CTS_ACK: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- NOTATIONS: 
-- _E as one-CLK early sample
-- _D as one-CLK delayed sample
-- _D2 as two-CLKs delayed sample

function max(L,R:INTEGER) return INTEGER is
begin
	if (L > R) then
		return L;
	else
		return R;
	end if;
end;

constant TCP_MAX_WINDOW_SIZE: integer := max(TCP_TX_WINDOW_SIZE,TCP_RX_WINDOW_SIZE);
	-- maximum Window size is expressed as 2**n Bytes. Thus a value of 12 indicates a window size of 32KB.
	-- used by TCP_SERVER to negotiate if the TCP window scaling option is warranted.

function WS_EN(TCP_MAX_WINDOW_SIZE: integer) return std_logic is
begin
	if(TCP_MAX_WINDOW_SIZE > 16) then
		-- buffer size (either transmit or/and receive) is greater than 64KB. Window scaling is enabled.
		return '1';
	else
		return '0';
	end if;
end;

constant WINDOW_SCALING_ENABLED: std_logic := WS_EN(TCP_MAX_WINDOW_SIZE);
	-- enable/disable window scaling option

--//-- RESET -----------------------------
signal SYNC_RESET_local: std_logic := '0';
signal RESET_CNTR_MSB: std_logic := '0';
signal RESET_CNTR_MSB_D: std_logic := '0';
signal RESET_CNTR: unsigned(3 downto 0) := (others => '0');
signal SYNC_RESET1: std_logic := '0';
signal SYNC_RESET2: std_logic := '0';
signal SYNC_RESET3: std_logic := '0';
signal SYNC_RESET4: std_logic := '0';

--//-- TIMERS -----------------------------
signal TICK_4US: std_logic := '0';
signal TICK_100MS_rt: std_logic := '0';
signal TICK_100MS: std_logic := '0';
signal TICK_CNTR: unsigned(6 downto 0) := (others => '0');       
signal TICK_CNTR2: unsigned(9 downto 0) := (others => '0');     
  

----//-- MAC INTERFACE --------------
signal MAC_TX_DATA_local : std_logic_vector(63 downto 0) := (others => '0');      
signal MAC_TX_DATA_VALID_local : std_logic_vector(7 downto 0) := (others => '0');      
signal MAC_TX_EOF_FLAG : std_logic  := '0';
signal MAC_TX_EOF_local : std_logic  := '0';
signal MAC_TX_WORD_VALID : std_logic  := '0';
signal MAC_TX_EOF_FLAGn : std_logic  := '0';

--//-- FLIP BYTE ORDER IN MAC TX/RX WORD --------------
signal MAC_RX_DATA_FLIP: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_RX_DATA_VALID_FLIP: std_logic_vector(7 downto 0) := (others => '0');
signal MAC_RX_WORD_COUNT: std_logic_vector(10 downto 0) := (others => '0');
signal MAC_TX_DATA_FLIP: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_TX_DATA_VALID_FLIP: std_logic_vector(7 downto 0) := (others => '0');
--
----//-- PARSE INCOMING PACKET --------------
signal RX_TYPE: std_logic_vector(3 downto 0) := (others => '0');
signal RX_TYPE_RDY : std_logic  := '0';
signal RX_IPv4_6n : std_logic  := '0';
signal RX_IP_PROTOCOL : std_logic_vector(7 downto 0) := (others => '0');
signal RX_IP_PROTOCOL_RDY : std_logic  := '0';
signal IP_RX_FRAME_VALID: std_logic := '0';
signal IP_RX_FRAME_VALID2: std_logic := '0';
signal IP_RX_DATA : std_logic_vector(63 downto 0) := (others => '0');
signal IP_RX_DATA_VALID : std_logic_vector(7 downto 0) := (others => '0');
signal IP_RX_SOF : std_logic  := '0';
signal IP_RX_EOF : std_logic  := '0';
signal IP_RX_WORD_COUNT : std_logic_vector(10 downto 0) := (others => '0');
signal IP_PAYLOAD_DATA : std_logic_vector(63 downto 0) := (others => '0');
signal IP_PAYLOAD_DATA_VALID : std_logic_vector(7 downto 0) := (others => '0');
signal IP_PAYLOAD_SOF : std_logic  := '0';
signal IP_PAYLOAD_EOF : std_logic  := '0';
signal IP_PAYLOAD_LENGTH: std_logic_vector(15 downto 0) := (others => '0');
signal IP_PAYLOAD_WORD_COUNT : std_logic_vector(10 downto 0) := (others => '0');
signal IP_HEADER_FLAG : std_logic_vector(1 downto 0) := (others => '0');
signal VALID_IP_PAYLOAD_CHECKSUM: std_logic := '0';
signal VALID_UDP_CHECKSUM: std_logic := '0';
signal VALID_TCP_CHECKSUM: std_logic := '0';
signal TP_PARSING: std_logic_vector(10 downto 1);
signal RX_SOURCE_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal RX_SOURCE_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal RX_DEST_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal VALID_UNICAST_DEST_IP: std_logic := '0';
signal VALID_MULTICAST_DEST_IP: std_logic := '0';
signal VALID_DEST_IP_RDY: std_logic := '0';
signal IP_HEADER_CHECKSUM_VALID: std_logic := '0';
signal IP_HEADER_CHECKSUM_VALID_RDY: std_logic := '0';



--//-- ARP REPLY --------------
signal ARP_MAC_TX_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal ARP_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0) := x"00";
signal ARP_MAC_TX_EOF: std_logic := '0';
signal ARP_MAC_TX_CTS: std_logic := '0';
signal ARP_RTS: std_logic := '0';
signal TP_ARP: std_logic_vector(10 downto 1);

--//-- ICMPV6 --------------
signal ICMPV6_MAC_TX_DATA: std_logic_vector(63 downto 0):= (others => '0');
signal ICMPV6_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal ICMPV6_MAC_TX_EOF: std_logic := '0';
signal ICMPV6_MAC_TX_CTS: std_logic := '0';
signal ICMPV6_RTS: std_logic := '0';
signal TP_ICMPV6: std_logic_vector(10 downto 1);

--//-- PING REPLY --------------
signal PING_MAC_TX_DATA: std_logic_vector(63 downto 0):= (others => '0');
signal PING_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal PING_MAC_TX_EOF: std_logic := '0';
signal PING_MAC_TX_CTS: std_logic := '0';
signal PING_RTS: std_logic := '0';
signal TP_PING: std_logic_vector(10 downto 1);

--//-- WHOIS ---------------------------------------------
signal WHOIS_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal WHOIS_IPv4_6n: std_logic := '0';
signal WHOIS_START: std_logic := '0';
signal WHOIS_RDY: std_logic := '0';
signal WHOIS_MAC_TX_DATA: std_logic_vector(63 downto 0):= (others => '0');
signal WHOIS_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal WHOIS_MAC_TX_EOF: std_logic := '0';
signal WHOIS_MAC_TX_CTS: std_logic := '0';
signal WHOIS_RTS: std_logic := '0';
signal TP_WHOIS: std_logic_vector(10 downto 1)  := (others => '0');

--//-- ARP CACHE  -----------------------------------------
signal RT_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal RT_IPv4_6n: std_logic := '0';
signal RT_REQ_RTS: std_logic := '0';
signal RT_CTS: std_logic := '0';
signal RT_MAC_REPLY: std_logic_vector(47 downto 0) := (others => '0');
signal RT_MAC_RDY:  std_logic := '0';
signal RT_NAK:  std_logic := '0';
signal TP_ARP_CACHE2: std_logic_vector(10 downto 1)  := (others => '0');

--//-- DHCP CLIENT (DYNAMIC IP) -----------------------------------------
signal IPv4_ADDR_local: std_logic_vector(31 downto 0) := (others => '0'); 
signal IPv4_SUBNET_MASK_local: std_logic_vector(31 downto 0) := (others => '0'); 
signal IPv4_GATEWAY_ADDR_local: std_logic_vector(31 downto 0) := (others => '0'); 
signal DHCPC_SYNC_RESET: std_logic := '0';
signal DHCPC_IPv4_ADDR: std_logic_vector(31 downto 0) := (others => '0'); 
signal DHCPC_SUBNET_MASK: std_logic_vector(31 downto 0) := (others => '0'); 
signal DHCPC_ROUTER: std_logic_vector(31 downto 0) := (others => '0'); 
signal DHCPC_MAC_TX_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal DHCPC_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0) := x"00";
signal DHCPC_MAC_TX_EOF: std_logic := '0';
signal DHCPC_MAC_TX_CTS: std_logic := '0';
signal DHCPC_RTS: std_logic := '0';
signal TP_DHCPC: std_logic_vector(10 downto 1);

--//-- IGMP (MULTICAST) -----------------------------------------
signal IGMP_REPORT_START: std_logic := '0';
signal IGMP_TRIGGER_RESPONSE: std_logic := '0';
signal IGMP_TRIGGER_RESPONSE2: std_logic := '0';
signal IGMP_TRIGGER_RESPONSE3: std_logic := '0';
signal IGMP_MAC_TX_DATA: std_logic_vector(63 downto 0):= (others => '0');
signal IGMP_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal IGMP_MAC_TX_EOF: std_logic := '0';
signal IGMP_MAC_TX_CTS: std_logic := '0';
signal IGMP_RTS: std_logic := '0';
signal TP_IGMP_QUERY: std_logic_vector(10 downto 1) := (others => '0');
signal TP_IGMP_REPORT: std_logic_vector(10 downto 1) := (others => '0');

--//-- UDP RX ------------------------------------
signal UDP_RX_DATA_local: std_logic_vector(63 downto 0):= (others => '0');
signal UDP_RX_DATA_VALID_local: std_logic_vector(7 downto 0):= (others => '0');
signal UDP_RX_SOF_local: std_logic := '0';
signal UDP_RX_EOF_local: std_logic := '0';
signal UDP_RX_DEST_PORT_NO_local: std_logic_vector(15 downto 0):= (others => '0');
signal UDP_RX_FRAME_VALID1: std_logic := '0';
signal UDP_RX_FRAME_VALID2: std_logic := '0';
signal TP_UDP_RX: std_logic_vector(10 downto 1) := (others => '0');

----//-- UDP TX ------------------------------------
signal UDP001_RT_REQ_RTS: std_logic := '0';
signal UDP001_RT_REQ_CTS: std_logic := '0';
signal UDP001_RT_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal UDP001_RT_IPv4_6n: std_logic := '0';
signal UDP001_RT_MAC_RDY: std_logic := '0';
signal UDP001_RT_NAK: std_logic := '0';
signal UDP001_MAC_TX_DATA: std_logic_vector(63 downto 0):= (others => '0');
signal UDP001_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal UDP001_MAC_TX_EOF: std_logic := '0';
signal UDP001_MAC_TX_CTS: std_logic := '0';
signal UDP001_RTS: std_logic := '0';
signal TP_UDP_TX: std_logic_vector(10 downto 1) := (others => '0');
signal UDP_TX_ACK_local: std_logic := '0';
signal UDP_TX_NAK_local: std_logic := '0';
--
--//-- TCP RX ------------------------------------
-- TCP server 001
--signal TCP_LOCAL_PORTS: SLV16xNTCPSTREAMStype;
signal TCP001_MAC_TX_DATA: std_logic_vector(63 downto 0):= (others => '0');
signal TCP001_MAC_TX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal TCP001_MAC_TX_EOF: std_logic := '0';
signal TCP001_MAC_TX_CTS: std_logic := '0';
signal TCP001_RTS: std_logic := '0';
signal TCP001_RX_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal TCP001_RX_DATA_VALID: std_logic_vector(7 downto 0):= (others => '0');
signal TCP001_RX_SOF: std_logic := '0';
signal TCP001_RX_TCP_STREAM_SEL: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');	
signal TCP001_RX_EOF: std_logic := '0';
signal TCP_001_RX_FRAME_VALID: std_logic := '0';
signal TCP001_RX_FREE_SPACE: SLV32xNTCPSTREAMStype;
signal TCP001_TX_PACKET_SEQUENCE_START: std_logic  := '0';
signal TCP001_TX_DEST_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal TCP001_TX_DEST_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal TCP001_TX_DEST_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_SOURCE_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_IPv4_6n: std_logic  := '0';
signal TCP001_TX_SEQ_NO: std_logic_vector(31 downto 0) := (others => '0');
signal TCP001_TX_ACK_NO: std_logic_vector(31 downto 0) := (others => '0');
signal TCP001_TX_ACK_WINDOW_LENGTH: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_FLAGS: std_logic_vector(7 downto 0) := (others => '0');
signal TCP001_TX_WINDOW_SCALE: std_logic_vector(3 downto 0) := (others => '0');
signal TCP001_TX_PACKET_TYPE: std_logic_vector(1 downto 0) := (others => '0');
signal TCP001_EFF_RX_WINDOW_SIZE_PARTIAL: std_logic_vector(31 downto 0) := (others => '0');
signal TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');	
signal TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID: std_logic := '0'; -- 1 CLK-wide pulse to indicate that the above information is valid
signal TCP001_TX_SEQ_NOxNTCPSTREAMS: SLV32xNTCPSTREAMStype;
signal TCP001_TX_SEQ_NO_JUMP: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal TCP001_RX_ACK_NOxNTCPSTREAMS: SLV32xNTCPSTREAMStype;
signal TCP001_CONNECTED_FLAG: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal TCP001_TX_PAYLOAD_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal TCP001_TX_PAYLOAD_DATA_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal TCP001_TX_PAYLOAD_WORD_VALID: std_logic := '0';
signal TCP001_TX_PAYLOAD_DATA_EOF: std_logic := '0';
signal TCP001_TX_PAYLOAD_RTS: std_logic := '0';
signal TCP001_TX_PAYLOAD_CTS: std_logic := '0';
signal TCP001_TX_PAYLOAD_SIZE: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_PAYLOAD_CHECKSUM: std_logic_vector(17 downto 0) := (others => '0');
signal TCP001_TX_STREAM_SEL: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');	
signal TCP001_TCP_TX_CTS: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');	
signal TP_TCP_CLIENTS: std_logic_vector(10 downto 1) := (others => '0');
signal TP_TCP_TXBUF: std_logic_vector(10 downto 1) := (others => '0');
signal TP_TCPRXBUFNDEMUX2: std_logic_vector(10 downto 1) := (others => '0');
signal TCP001_RT_REQ_RTS: std_logic := '0';
signal TCP001_RT_REQ_CTS: std_logic := '0';
signal TCP001_RT_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal TCP001_RT_IPv4_6n: std_logic := '0';
signal TCP001_RT_MAC_RDY: std_logic := '0';
signal TCP001_RT_NAK: std_logic := '0';
--
-- TCP server 002
-- etc...

--//-- TRANSMISSION ARBITER --------------
signal IP_ID: unsigned(15 downto 0) := x"0000";
signal TX_MUX_STATE: integer range 0 to 10;	-- up to N protocol engines. Increase size if more.

--//-- ROUTING TABLE ARBITER --------------
signal RT_MUX_STATE: integer range 0 to 2;	
	-- 1 + number of transmit components vying for access to the routing table. Adjust as needed.

signal MSSv4: std_logic_vector(13 downto 0);
signal MSSv6: std_logic_vector(13 downto 0);
------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
attribute mark_debug : string;
attribute mark_debug of TX_MUX_STATE : signal is "true";
attribute mark_debug of RT_MUX_STATE : signal is "true";
attribute mark_debug of TCP001_EFF_RX_WINDOW_SIZE_PARTIAL : signal is "true";
attribute mark_debug of TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM : signal is "true";
attribute mark_debug of TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID : signal is "true";
attribute mark_debug of TCP001_TX_SEQ_NO : signal is "true";
attribute mark_debug of TCP001_TX_ACK_NO : signal is "true";
attribute mark_debug of TCP001_TX_FLAGS : signal is "true";
attribute mark_debug of TCP001_TX_WINDOW_SCALE : signal is "true";
attribute mark_debug of TCP001_TX_PACKET_TYPE : signal is "true";

begin

		COM5503_DEBUG.MAC_TX_CTS          <= MAC_TX_CTS;
		COM5503_DEBUG.MAC_TX_RTS          <= MAC_TX_RTS;
		COM5503_DEBUG.MAC_TX_DATA_VALID   <= MAC_TX_DATA_VALID;
		COM5503_DEBUG.MAC_TX_SOF          <= MAC_TX_SOF;
		COM5503_DEBUG.MAC_TX_EOF          <= MAC_TX_EOF;
		COM5503_DEBUG.MAC_RX_DATA_VALID   <= MAC_RX_DATA_VALID;
		COM5503_DEBUG.MAC_RX_SOF          <= MAC_RX_SOF;
		COM5503_DEBUG.MAC_RX_EOF          <= MAC_RX_EOF;
		COM5503_DEBUG.MAC_RX_FRAME_VALID  <= MAC_RX_FRAME_VALID;
		COM5503_DEBUG.TX_MUX_STATE        <= std_logic_vector(to_unsigned(TX_MUX_STATE,4));
		COM5503_DEBUG.RT_MUX_STATE        <= std_logic_vector(to_unsigned(RT_MUX_STATE,4));
		COM5503_DEBUG.RT_NAK              <= RT_NAK;
		COM5503_DEBUG.RT_MAC_RDY          <= RT_MAC_RDY;
		COM5503_DEBUG.RT_CTS              <= RT_CTS;

  MSSv4 <= std_logic_vector(unsigned(MTU)-40);	-- 40byte header for IPv4/TCP
  MSSv6 <= std_logic_vector(unsigned(MTU)-60);  -- 60byte header for IPv6/TCP

--//-- RESET -----------------------------
-- Reset is mandatory but just in case one forgets, create a local one at power up.
SYNC_RESET_001: process(CLK)
begin
	if rising_edge(CLK) then
		RESET_CNTR_MSB_D <= RESET_CNTR_MSB;

		if(RESET_CNTR_MSB = '0') then
			RESET_CNTR <= RESET_CNTR + 1;
		end if;

		if(RESET_CNTR_MSB_D = '0') and (RESET_CNTR_MSB = '1') then
			SYNC_RESET_local <= '1';
		else
			SYNC_RESET_local <= SYNC_RESET;
		end if;
	end if;
end process;
RESET_CNTR_MSB <= RESET_CNTR(RESET_CNTR'left);

-- manually reduce fanout for sync reset (there may be other methods, but this one works with Xilinx Vivado,
-- Original SYNC_RESET fanout was over 1200 resulting in excessive routing delay)
SYNC_RESET_002: process(CLK)
begin
	if rising_edge(CLK) then
		SYNC_RESET1 <= SYNC_RESET_local;
		SYNC_RESET2 <= SYNC_RESET_local;
		SYNC_RESET3 <= SYNC_RESET_local;
		SYNC_RESET4 <= SYNC_RESET_local;
	end if;
end process;

--//-- TIMERS -----------------------------
TIMER_4US_001: TIMER_4US 
GENERIC MAP(
	CLK_FREQUENCY => CLK_FREQUENCY
)
PORT MAP(
	CLK => CLK,
	SYNC_RESET => SYNC_RESET1,
	TICK_4US => TICK_4US,
	TICK_100MS => TICK_100MS_rt
);

TICK_100MS <= TICK_4US when (SIMULATION = '1') else TICK_100MS_rt;	-- to accelerate simulations

--//-- FLIP RX BYTE ORDER IN WORD --------------
-- flipping the MSB <-> LSB makes it easier to read the various fields values in the code or simulator
FLIP_RX_MAC_BYTES: process(MAC_RX_DATA, MAC_RX_DATA_VALID)
begin
	FOR I in 0 to 7 loop
		MAC_RX_DATA_FLIP(I*8+7 downto I*8) <= MAC_RX_DATA((7-I)*8+7 downto (7-I)*8);
		MAC_RX_DATA_VALID_FLIP(I) <= MAC_RX_DATA_VALID(7-I);
	end loop;
end process;


--//-- PARSE INCOMING PACKET --------------
-- Code is common to all protocols. Extracts key information from incoming packets.
	PACKET_PARSING_001: PACKET_PARSING_10G 
	GENERIC MAP(
		IPv6_ENABLED => IPv6_ENABLED,
		SIMULATION => SIMULATION
	)
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET1,
		MAC_RX_DATA => MAC_RX_DATA_FLIP,
		MAC_RX_DATA_VALID => MAC_RX_DATA_VALID_FLIP,
		MAC_RX_SOF => MAC_RX_SOF,
		MAC_RX_EOF => MAC_RX_EOF,
		MAC_RX_FRAME_VALID => MAC_RX_FRAME_VALID,
		MAC_RX_WORD_COUNT => MAC_RX_WORD_COUNT,
		IPv4_ADDR => IPv4_ADDR_local,
		IPv6_ADDR => IPv6_ADDR,
		IPv4_MULTICAST_ADDR => IPv4_MULTICAST_ADDR,
		IP_RX_DATA => IP_RX_DATA,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_SOF => IP_RX_SOF,
		IP_RX_EOF => IP_RX_EOF,
		IP_RX_WORD_COUNT => IP_RX_WORD_COUNT,
		IP_HEADER_FLAG => IP_HEADER_FLAG,
		RX_TYPE => RX_TYPE,
		RX_TYPE_RDY => RX_TYPE_RDY,
		RX_IPv4_6n => RX_IPv4_6n,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		IP_RX_FRAME_VALID => IP_RX_FRAME_VALID,
		IP_RX_FRAME_VALID2 => IP_RX_FRAME_VALID2,
		VALID_UNICAST_DEST_IP => VALID_UNICAST_DEST_IP,
		VALID_MULTICAST_DEST_IP => VALID_MULTICAST_DEST_IP,
		VALID_DEST_IP_RDY => VALID_DEST_IP_RDY,
		IP_HEADER_CHECKSUM_VALID => IP_HEADER_CHECKSUM_VALID,
		IP_HEADER_CHECKSUM_VALID_RDY => IP_HEADER_CHECKSUM_VALID_RDY,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,
		RX_DEST_IP_ADDR => RX_DEST_IP_ADDR,
		IP_PAYLOAD_DATA => IP_PAYLOAD_DATA,
		IP_PAYLOAD_DATA_VALID => IP_PAYLOAD_DATA_VALID,
		IP_PAYLOAD_SOF => IP_PAYLOAD_SOF,
		IP_PAYLOAD_EOF => IP_PAYLOAD_EOF,
		IP_PAYLOAD_LENGTH => IP_PAYLOAD_LENGTH,
		IP_PAYLOAD_WORD_COUNT => IP_PAYLOAD_WORD_COUNT,
		VALID_IP_PAYLOAD_CHECKSUM => VALID_IP_PAYLOAD_CHECKSUM,
		VALID_UDP_CHECKSUM => VALID_UDP_CHECKSUM,
		VALID_TCP_CHECKSUM => VALID_TCP_CHECKSUM,
		CS1 => open,
		CS1_CLK => open,
		CS2 => open,
		CS2_CLK => open,
		TP => TP_PARSING
	);
	
--	DEBUG_001: process(CLK)
--	begin
--		if rising_edge(CLK) then
--			if(IP_PAYLOAD_DATA_VALID /= x"00") then
--				if(unsigned(IP_PAYLOAD_WORD_COUNT) = 1) then
--					DEBUG1 <= IP_PAYLOAD_DATA;
--				end if;
--				if(unsigned(IP_PAYLOAD_WORD_COUNT) = 2) then
--					DEBUG2 <= IP_PAYLOAD_DATA;
--				end if;
--				if(unsigned(IP_PAYLOAD_WORD_COUNT) = 3) then
--					DEBUG3 <= IP_PAYLOAD_DATA;
--				end if;
--			end if;
--		end if;
--	end process;
	
	
--//-- ARP REPLY --------------
-- Instantiated once per PHY.   IPv4-only. Use NDP for IPv6.
	ARP_001: ARP_10G 
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET2,
		MAC_RX_DATA => MAC_RX_DATA_FLIP,
		MAC_RX_DATA_VALID => MAC_RX_DATA_VALID_FLIP,
		MAC_RX_SOF => MAC_RX_SOF,
		MAC_RX_EOF => MAC_RX_EOF,
		MAC_RX_FRAME_VALID => MAC_RX_FRAME_VALID,
		MAC_RX_WORD_COUNT => MAC_RX_WORD_COUNT,
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR_local,
		RX_TYPE => RX_TYPE,
		RX_TYPE_RDY => RX_TYPE_RDY,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR(31 downto 0),
		MAC_TX_DATA => ARP_MAC_TX_DATA,
		MAC_TX_DATA_VALID => ARP_MAC_TX_DATA_VALID,
		MAC_TX_EOF => ARP_MAC_TX_EOF,
		MAC_TX_CTS => ARP_MAC_TX_CTS,
		RTS => ARP_RTS,
		TP => TP_ARP
	);

--//-- ICMPV6 --------------
-- Instantiated once per PHY.
-- Respond to Neighbor Solicitation Messages
ICMPV6_001: if(IPv6_ENABLED = '1') generate
	ICMPV6_001: ICMPV6_10G 
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET2,
		IP_RX_DATA => IP_RX_DATA,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_SOF => IP_RX_SOF,
		IP_RX_EOF => IP_RX_EOF,
		IP_RX_WORD_COUNT => IP_RX_WORD_COUNT,
		IP_RX_FRAME_VALID => IP_RX_FRAME_VALID,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,
		MAC_ADDR => MAC_ADDR,
		IPv6_ADDR => IPv6_ADDR,
		RX_IPv4_6n => RX_IPv4_6n,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		MAC_TX_DATA => ICMPV6_MAC_TX_DATA,	
		MAC_TX_DATA_VALID => ICMPV6_MAC_TX_DATA_VALID,
		MAC_TX_EOF => ICMPV6_MAC_TX_EOF,
		MAC_TX_CTS => ICMPV6_MAC_TX_CTS,
		RTS => ICMPV6_RTS,
		TP => TP_ICMPV6
	);
end generate;
	
--//-- PING REPLY --------------
-- Instantiated once per PHY.
	PING_001: PING_10G 
	GENERIC MAP(
		IPv6_ENABLED => IPv6_ENABLED,
		MAX_PING_SIZE => x"20"	-- 32*8-byte words threshold for incoming IP/ICMP frame
	)
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET3,
		IP_RX_DATA => IP_RX_DATA,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_SOF => IP_RX_SOF,
		IP_RX_EOF => IP_RX_EOF,
		IP_RX_WORD_COUNT => IP_RX_WORD_COUNT,
		IP_RX_FRAME_VALID2 => IP_RX_FRAME_VALID2,
		VALID_UNICAST_DEST_IP => VALID_UNICAST_DEST_IP,
		VALID_DEST_IP_RDY => VALID_DEST_IP_RDY,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR_local,
		IPv6_ADDR => IPv6_ADDR,
		RX_IPv4_6n => RX_IPv4_6n,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		MAC_TX_DATA => PING_MAC_TX_DATA,	
		MAC_TX_DATA_VALID => PING_MAC_TX_DATA_VALID,
		MAC_TX_EOF => PING_MAC_TX_EOF,
		MAC_TX_CTS => PING_MAC_TX_CTS,
		RTS => PING_RTS,
		TP => TP_PING
	);
	
--//-- WHOIS ---------------------------------------------
-- Sends ARP and NDP requests  
-- Currently only used by UDP tx and TCP clients
WHOIS2_X: if(NUDPTX /= 0) or (NTCPSTREAMS /= 0) generate
	WHOIS2_001: WHOIS2_10G 
	GENERIC MAP(
		  IPv6_ENABLED => IPv6_ENABLED
	 )
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET3,
		WHOIS_IP_ADDR => WHOIS_IP_ADDR,
		WHOIS_IPv4_6n => WHOIS_IPv4_6n, 
		WHOIS_START => WHOIS_START,
		WHOIS_RDY => WHOIS_RDY,  -- unused
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR_local,
		IPv6_ADDR => IPv6_ADDR,
		MAC_TX_DATA => WHOIS_MAC_TX_DATA,
		MAC_TX_DATA_VALID => WHOIS_MAC_TX_DATA_VALID,
		MAC_TX_EOF => WHOIS_MAC_TX_EOF,
		MAC_TX_CTS => WHOIS_MAC_TX_CTS,
		RTS => WHOIS_RTS,
		TP => TP_WHOIS
	);
end generate;

--//-- ARP CACHE  (ROUTING TABLE) -----------------------------------------
-- Routing table mapping destination IP addresses and associated MAC addresses.
-- Currently only used by UDP tx and TCP clients
ARP_CACHE2_X: if(NUDPTX /= 0) or (NTCPSTREAMS /= 0) generate
	ARP_CACHE2_001: ARP_CACHE2_10G 
	GENERIC MAP(
		  IPv6_ENABLED => IPv6_ENABLED
	 )
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET2,
		TICK_100MS => TICK_100MS,
		RT_IP_ADDR => RT_IP_ADDR,	
		RT_IPv4_6n => RT_IPv4_6n,
		RT_REQ_RTS => RT_REQ_RTS,	
		RT_CTS => RT_CTS,	
		RT_MAC_REPLY => RT_MAC_REPLY,
		RT_MAC_RDY => RT_MAC_RDY,
		RT_NAK => RT_NAK,
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR_local,
		IPv4_SUBNET_MASK => IPv4_SUBNET_MASK_local,
		IPv4_GATEWAY_ADDR => IPv4_GATEWAY_ADDR_local,
		IPv6_ADDR => IPv6_ADDR,
		 IPv6_SUBNET_PREFIX_LENGTH => IPv6_SUBNET_PREFIX_LENGTH,
		IPv6_GATEWAY_ADDR => IPv6_GATEWAY_ADDR,
		WHOIS_IP_ADDR => WHOIS_IP_ADDR,
		WHOIS_IPv4_6n => WHOIS_IPv4_6n, 
		WHOIS_START => WHOIS_START,
		RX_SOURCE_ADDR_RDY => MAC_RX_EOF,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,	
		RX_IPv4_6n => RX_IPv4_6n,
		SREG1 => open,
		SREG2 => open,
		SREG3 => open,
		SREG4 => open,
		SREG5 => open,
		SREG6 => open,
		TP => TP_ARP_CACHE2
	);
end generate;

--//-- DHCP CLIENT (DYNAMIC IP) -----------------------------------------
DHCP_CLIENT_000: if(DHCP_CLIENT_EN = '0') generate
	-- no DHCP client is instantiated. Always static IP address
	-- use static IP address, subnet mask and gateway address (stored externally)
	IPv4_ADDR_local <= REQUESTED_IPv4_ADDR;
	IPv4_SUBNET_MASK_local <= IPv4_SUBNET_MASK;
	IPv4_GATEWAY_ADDR_local <= IPv4_GATEWAY_ADDR;
end generate;

DHCP_CLIENT_001: if(DHCP_CLIENT_EN = '1') generate
	-- keep this component in reset if the user selects static IP
	DHCPC_SYNC_RESET <= (not DYNAMIC_IPv4) or SYNC_RESET;

	-- remember the last assigned address
	DHCPC_LAST_IPv4_ADDR_GEN: process(CLK)
	begin
		if rising_edge(CLK) then
			if(DYNAMIC_IPv4 = '0') then
				-- static IP address
				IPv4_ADDR_local <= REQUESTED_IPv4_ADDR;
				IPv4_SUBNET_MASK_local <= IPv4_SUBNET_MASK;
				IPv4_GATEWAY_ADDR_local <= IPv4_GATEWAY_ADDR;
			else
				-- dynamic IP address, based on DHCP server assignment
				IPv4_ADDR_local <= DHCPC_IPv4_ADDR;	
				IPv4_SUBNET_MASK_local <= DHCPC_SUBNET_MASK;
				IPv4_GATEWAY_ADDR_local <= DHCPC_ROUTER;
			end if;
		end if;
	end process;

	DHCP_CLIENT_10G_001: DHCP_CLIENT_10G 
	GENERIC MAP(
		SIMULATION => SIMULATION
	)
	PORT MAP(
		SYNC_RESET => DHCPC_SYNC_RESET,
		CLK => CLK,
		TICK_4US => TICK_4US,
		TICK_100MS => TICK_100MS,
		MAC_ADDR => MAC_ADDR,
		LAST_IPv4_ADDR => REQUESTED_IPv4_ADDR,	
		-- DHCP server assignment
		IPv4_ADDR => DHCPC_IPv4_ADDR,
		LEASE_TIME => open,
		SUBNET_MASK => DHCPC_SUBNET_MASK,
		ROUTER => DHCPC_ROUTER,
		DNS1 => open,
		DNS2 => open,
		-- UDP rx frame
		UDP_RX_DATA => UDP_RX_DATA_local,
		UDP_RX_DATA_VALID => UDP_RX_DATA_VALID_local,
		UDP_RX_SOF => UDP_RX_SOF_local,
		UDP_RX_EOF => UDP_RX_EOF_local,
		UDP_RX_FRAME_VALID => UDP_RX_FRAME_VALID1,
		UDP_RX_DEST_PORT_NO => UDP_RX_DEST_PORT_NO_local,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR(31 downto 0),
		IP_ID_IN => std_logic_vector(IP_ID),
		-- MAC interface
		MAC_TX_DATA => DHCPC_MAC_TX_DATA,
		MAC_TX_DATA_VALID => DHCPC_MAC_TX_DATA_VALID,
		MAC_TX_EOF => DHCPC_MAC_TX_EOF,
		MAC_TX_CTS => DHCPC_MAC_TX_CTS,
		RTS => DHCPC_RTS,		
		TP => TP_DHCPC
	);

end generate;
--IPv4_ADDR_OUT <= IPv4_ADDR_local;	-- report actual IP address
--SUBNET_MASK_OUT <= SUBNET_MASK_local;
--GATEWAY_IP_ADDR_OUT <= GATEWAY_IP_ADDR_local;

--//-- IGMP (MULTICAST) -----------------------------------------
-- detects an IGMP membership query. Triggers a response
IGMP_QUERY_001x: if (IGMP_EN = '1') and (NUDPTX /= 0) generate
	IGMP_QUERY_001: IGMP_QUERY_10G
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET,
		MULTICAST_IP_ADDR => IPv4_MULTICAST_ADDR,
		IP_PAYLOAD_DATA => IP_PAYLOAD_DATA,
		IP_PAYLOAD_DATA_VALID => IP_PAYLOAD_DATA_VALID,
		IP_PAYLOAD_SOF => IP_PAYLOAD_SOF,
		IP_PAYLOAD_EOF => IP_PAYLOAD_EOF,
		IP_PAYLOAD_WORD_COUNT => IP_PAYLOAD_WORD_COUNT,
		IP_RX_FRAME_VALID2 => IP_RX_FRAME_VALID2,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		VALID_MULTICAST_DEST_IP => VALID_MULTICAST_DEST_IP,
		VALID_IP_PAYLOAD_CHECKSUM => VALID_IP_PAYLOAD_CHECKSUM,
		RX_DEST_IP_ADDR => RX_DEST_IP_ADDR(31 downto 0),	-- IGMP is only for IPv4
		TRIGGER_RESPONSE => IGMP_TRIGGER_RESPONSE,
		TP => TP_IGMP_QUERY
	);

	-- send an IGMP membership report either in response to a membership query
	-- or a couple of times at power up/reset
	-- or once every 102.4 seconds
	IGMP_REPORT_TIMER_GEN: process(CLK)
	begin
		 if rising_edge(CLK) then
			  if (SYNC_RESET = '1') then
					TICK_CNTR <= (others => '0');
			  elsif(TICK_100MS = '1') and (TICK_CNTR(6) = '0') then
					-- counts from 0 to 64 and stay there
					TICK_CNTR <= TICK_CNTR + 1;
			  end if;
			  
			  -- modulo 1024 counter
			  if (SYNC_RESET = '1') then
					TICK_CNTR2 <= (others => '0');
			  elsif(TICK_100MS = '1') then
					TICK_CNTR2 <= TICK_CNTR2 + 1;
			  end if;
			  
			  
			  if(TICK_100MS = '1') and (TICK_CNTR(6) = '0') and (TICK_CNTR(4 downto 0) = 0) then
					-- generate two pulses at 3.4 and 6.4s after reset
					IGMP_TRIGGER_RESPONSE2 <= '1';
			  else
					IGMP_TRIGGER_RESPONSE2 <= '0';
			  end if;

			  if(TICK_100MS = '1') and (TICK_CNTR2 = 1023) then
					-- generate periodic pulses once every 102.4 seconds
					IGMP_TRIGGER_RESPONSE3 <= '1';
			  else
					IGMP_TRIGGER_RESPONSE3 <= '0';
			  end if;

		 end if;
	end process;

	-- 0.0.0.0 to signify that IP multicasting is not supported here.
	IGMP_REPORT_START <= (IGMP_TRIGGER_RESPONSE or IGMP_TRIGGER_RESPONSE2 or IGMP_TRIGGER_RESPONSE3) when (IPv4_MULTICAST_ADDR /= x"00000000") else '0';

	IGMP_REPORT_001: IGMP_REPORT_10G 
	PORT MAP(
		SYNC_RESET => SYNC_RESET,
		CLK => CLK,
		IGMP_START => IGMP_REPORT_START,  
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR_local,
		IP_ID => std_logic_vector(IP_ID),
		MULTICAST_IP_ADDR => IPv4_MULTICAST_ADDR,
		MAC_TX_CTS => IGMP_MAC_TX_CTS,
		MAC_TX_DATA => IGMP_MAC_TX_DATA,
		MAC_TX_DATA_VALID => IGMP_MAC_TX_DATA_VALID,
		MAC_TX_EOF => IGMP_MAC_TX_EOF,
		RTS => IGMP_RTS,
		TP => TP_IGMP_REPORT
	);
end generate;


----//-- UDP RX to Serial (Monitoring and control) ---------
--	Inst_UDP2SERIAL: UDP2SERIAL_10G 
--	GENERIC MAP(
--		PORT_NO => x"0405",  --1029
--		CLK_FREQUENCY => CLK_FREQUENCY
--	)
--	PORT MAP(
--		CLK => CLK,
--		SYNC_RESET => SYNC_RESET,
--		IP_RX_DATA => IP_RX_DATA,
--		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
--		IP_RX_SOF => IP_RX_SOF,
--		IP_RX_EOF => IP_RX_EOF,
--		IP_HEADER_FLAG => IP_HEADER_FLAG,
--		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
--		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
--		SERIAL_OUT => open,
--		TP => open
--	);
--
--//-- UDP RX ------------------------------------
UDP_RX_X: if(NUDPRX /= 0) or (DHCP_CLIENT_EN = '1') generate
	-- Note: DHCP client relies on the UDP_RX
	UDP_RX_001: UDP_RX_10G 
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET1,
		IP_PAYLOAD_DATA => IP_PAYLOAD_DATA,
		IP_PAYLOAD_DATA_VALID => IP_PAYLOAD_DATA_VALID,
		IP_PAYLOAD_SOF => IP_PAYLOAD_SOF,
		IP_PAYLOAD_EOF => IP_PAYLOAD_EOF,
		IP_PAYLOAD_WORD_COUNT => IP_PAYLOAD_WORD_COUNT,
		IP_RX_FRAME_VALID => IP_RX_FRAME_VALID,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		VALID_UDP_CHECKSUM => VALID_UDP_CHECKSUM,
		-- configuration
		PORT_NO => x"0000",
		CHECK_UDP_RX_DEST_PORT_NO => '0',	-- destination UDP port check done below instead of within the component
		-- Application interface + DHCP server interface
		UDP_RX_DATA => UDP_RX_DATA_local,
		UDP_RX_DATA_VALID => UDP_RX_DATA_VALID_local,
		UDP_RX_SOF => UDP_RX_SOF_local,
		UDP_RX_EOF => UDP_RX_EOF_local,
		UDP_RX_FRAME_VALID => UDP_RX_FRAME_VALID1,
		UDP_RX_SRC_PORT => open,
		UDP_RX_DEST_PORT => UDP_RX_DEST_PORT_NO_local,
		TP => TP_UDP_RX
	);
	-- send to application UDP port
	UDP_RX_DATA <= UDP_RX_DATA_local;
	UDP_RX_DATA_VALID <= UDP_RX_DATA_VALID_local;
	UDP_RX_SOF <= UDP_RX_SOF_local;
	UDP_RX_EOF <= UDP_RX_EOF_local;
	UDP_RX_DEST_PORT_NO_OUT <= UDP_RX_DEST_PORT_NO_local;
	
	-- When DHCP client is enabled, the UDP destination port check must be done outside of UDP_RX_10G
	-- as a separate process, thus the input CHECK_UDP_RX_DEST_PORT_NO => '0' above.
	-- check UDP destination port for application payload (when requested by the application)
	UDP_RX_002: process(CLK)
	begin
		if rising_edge(CLK) then
		   if(IP_PAYLOAD_SOF = '1') then
				if(CHECK_UDP_RX_DEST_PORT_NO = '1') and (UDP_RX_DEST_PORT_NO_IN /= IP_PAYLOAD_DATA(47 downto 32)) then	-- *060719
					UDP_RX_FRAME_VALID2 <= '0';
				else
					UDP_RX_FRAME_VALID2 <= '1';
				end if;
			end if;
		end if;
	end process;

	UDP_RX_FRAME_VALID <= UDP_RX_FRAME_VALID1 and UDP_RX_FRAME_VALID2;
end generate;	

--//-- UDP TX ------------------------------------
UDP_TX_X: if(NUDPTX /= 0) generate
	UDP_TX_001: UDP_TX_10G 
	GENERIC MAP(
		ADDR_WIDTH => 10,  -- elastic buffer size as 72b * 2^ADDR_WIDTH
		UDP_CKSUM_ENABLED => '1',
		IPv6_ENABLED => IPv6_ENABLED
	)
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET1,
		TICK_4US => TICK_4US,
		-- Application interface
		APP_DATA => UDP_TX_DATA,
		APP_DATA_VALID => UDP_TX_DATA_VALID,
		APP_SOF => UDP_TX_SOF,
		APP_EOF => UDP_TX_EOF,
		APP_CTS => UDP_TX_CTS,
		ACK => UDP_TX_ACK_local,
		NAK => UDP_TX_NAK_local,
		DEST_IP_ADDR => UDP_TX_DEST_IP_ADDR,
		IPv4_6n => UDP_TX_DEST_IPv4_6n,
		DEST_PORT_NO => UDP_TX_DEST_PORT_NO,
		SOURCE_PORT_NO => UDP_TX_SOURCE_PORT_NO,	
		-- Configuration
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR_local,
		IPv6_ADDR => IPv6_ADDR,
		IP_ID => std_logic_vector(IP_ID),
		-- Routing
		RT_IP_ADDR => UDP001_RT_IP_ADDR,
		RT_IPv4_6n => UDP001_RT_IPv4_6n,
		RT_REQ_RTS => UDP001_RT_REQ_RTS,
		RT_REQ_CTS => UDP001_RT_REQ_CTS,
		RT_MAC_REPLY => RT_MAC_REPLY,
		RT_MAC_RDY => UDP001_RT_MAC_RDY,
		RT_NAK => UDP001_RT_NAK,
		-- MAC interface
		MAC_TX_DATA => UDP001_MAC_TX_DATA,
		MAC_TX_DATA_VALID => UDP001_MAC_TX_DATA_VALID,
		MAC_TX_EOF => UDP001_MAC_TX_EOF,
		MAC_TX_CTS => UDP001_MAC_TX_CTS,
		RTS => UDP001_RTS,
		TP => TP_UDP_TX
	);
end generate;
UDP_TX_ACK <= UDP_TX_ACK_local;
UDP_TX_NAK <= UDP_TX_NAK_local;

--//-- TCP SERVER 001 ------------------------------------
-- declare the port number for each TCP stream (NTCPSTREAMS streams, declared in the generic section)
TCP_CLIENTS_X: if (NTCPSTREAMS /= 0) generate
	TCP_CLIENTS_001: TCP_CLIENTS_10G 
	GENERIC MAP(
		NTCPSTREAMS => NTCPSTREAMS,
		TCP_MAX_WINDOW_SIZE => TCP_MAX_WINDOW_SIZE,
		WINDOW_SCALING_ENABLED => WINDOW_SCALING_ENABLED,
		IPv6_ENABLED => IPv6_ENABLED,
		TCP_KEEPALIVE_PERIOD => TCP_KEEPALIVE_PERIOD,
		SIMULATION => SIMULATION
	)
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET4,
		TICK_4US => TICK_4US,
		TICK_100MS => TICK_100MS,
		MAC_ADDR => MAC_ADDR,
		TCP_LOCAL_PORTS => TCP_LOCAL_PORTS,
		DEST_IP_ADDR => TCP_DEST_IP_ADDR,
		DEST_IPv4_6n => TCP_DEST_IPv4_6n,
		DEST_PORT => TCP_DEST_PORT,
		STATE_REQUESTED => TCP_STATE_REQUESTED,
		STATE_STATUS => TCP_STATE_STATUS,
		TCP_KEEPALIVE_EN => TCP_KEEPALIVE_EN,
		RT_IP_ADDR => TCP001_RT_IP_ADDR,
		RT_IPv4_6n => TCP001_RT_IPv4_6n,
		RT_REQ_RTS => TCP001_RT_REQ_RTS,
		RT_REQ_CTS => TCP001_RT_REQ_CTS,
		RT_MAC_REPLY => RT_MAC_REPLY,
		RT_MAC_RDY => TCP001_RT_MAC_RDY,
		RT_NAK => TCP001_RT_NAK,
		IP_PAYLOAD_DATA => IP_PAYLOAD_DATA,
		IP_PAYLOAD_DATA_VALID => IP_PAYLOAD_DATA_VALID,
		IP_PAYLOAD_SOF => IP_PAYLOAD_SOF,
		IP_PAYLOAD_EOF => IP_PAYLOAD_EOF,
		IP_PAYLOAD_WORD_COUNT => IP_PAYLOAD_WORD_COUNT,
		IP_RX_FRAME_VALID => IP_RX_FRAME_VALID,
		RX_IPv4_6n => RX_IPv4_6n,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,
		VALID_TCP_CHECKSUM => VALID_TCP_CHECKSUM,
		RX_DATA => TCP001_RX_DATA,
		RX_DATA_VALID => TCP001_RX_DATA_VALID,
		RX_SOF => TCP001_RX_SOF,
		RX_TCP_STREAM_SEL_OUT => TCP001_RX_TCP_STREAM_SEL,
		RX_EOF => TCP001_RX_EOF,
		RX_FRAME_VALID => TCP_001_RX_FRAME_VALID,
		RX_FREE_SPACE => TCP001_RX_FREE_SPACE,	
		TX_PACKET_SEQUENCE_START_OUT => TCP001_TX_PACKET_SEQUENCE_START,
		TX_DEST_MAC_ADDR_OUT => TCP001_TX_DEST_MAC_ADDR,
		TX_DEST_IP_ADDR_OUT => TCP001_TX_DEST_IP_ADDR,
		TX_DEST_PORT_NO_OUT => TCP001_TX_DEST_PORT_NO,
		TX_SOURCE_PORT_NO_OUT => TCP001_TX_SOURCE_PORT_NO,
		TX_IPv4_6n_OUT => TCP001_TX_IPv4_6n,
		TX_SEQ_NO_OUT => TCP001_TX_SEQ_NO,
		TX_ACK_NO_OUT => TCP001_TX_ACK_NO,
		TX_ACK_WINDOW_LENGTH_OUT => TCP001_TX_ACK_WINDOW_LENGTH,
		TX_FLAGS_OUT => TCP001_TX_FLAGS,
		TX_PACKET_TYPE_OUT => TCP001_TX_PACKET_TYPE,
		TX_WINDOW_SCALE_OUT => TCP001_TX_WINDOW_SCALE,
		MAC_TX_EOF => TCP001_MAC_TX_EOF,
		RTS => TCP001_RTS,
		EFF_RX_WINDOW_SIZE_PARTIAL => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL,
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM,
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID,
		TX_SEQ_NO => TCP001_TX_SEQ_NOxNTCPSTREAMS,
		TX_SEQ_NO_JUMP => TCP001_TX_SEQ_NO_JUMP,
		RX_TCP_ACK_NO_D => TCP001_RX_ACK_NOxNTCPSTREAMS,
		CONNECTED_FLAG => TCP001_CONNECTED_FLAG,
		TX_STREAM_SEL => TCP001_TX_STREAM_SEL,
		TX_PAYLOAD_RTS => TCP001_TX_PAYLOAD_RTS,
		TX_PAYLOAD_SIZE => TCP001_TX_PAYLOAD_SIZE,
		MSS => MSSv6,	-- 40byte header for IPv4/TCP but 60byte header for IPv6/TCP
		TP => TP_TCP_CLIENTS,
		COM5503_TCP_CLIENTS_DEBUG => COM5503_TCP_CLIENTS_DEBUG
	);
	 
    TCP_CONNECTED_FLAG <= TCP001_CONNECTED_FLAG;
    
	-- assemble tx packet (MAC/IP/TCP)
		TCP_TX_001: TCP_TX_10G 
		GENERIC MAP(
			IPv6_ENABLED => IPv6_ENABLED
		)
		PORT MAP(
			CLK => CLK,
			SYNC_RESET => SYNC_RESET4,
			MAC_ADDR => MAC_ADDR,
			IPv4_ADDR => IPv4_ADDR_local,
			IPv6_ADDR => IPv6_ADDR,
			TX_PACKET_SEQUENCE_START => TCP001_TX_PACKET_SEQUENCE_START,
			TX_DEST_MAC_ADDR_IN => TCP001_TX_DEST_MAC_ADDR,
			TX_DEST_IP_ADDR_IN => TCP001_TX_DEST_IP_ADDR,
			TX_DEST_PORT_NO_IN => TCP001_TX_DEST_PORT_NO,
			TX_SOURCE_PORT_NO_IN => TCP001_TX_SOURCE_PORT_NO,
			TX_IPv4_6n_IN => TCP001_TX_IPv4_6n,
			TX_SEQ_NO_IN => TCP001_TX_SEQ_NO,
			TX_ACK_NO_IN => TCP001_TX_ACK_NO,
			TX_ACK_WINDOW_LENGTH_IN => TCP001_TX_ACK_WINDOW_LENGTH,
			IP_ID_IN => std_logic_vector(IP_ID),
			TX_FLAGS_IN => TCP001_TX_FLAGS,
			TX_PACKET_TYPE_IN => TCP001_TX_PACKET_TYPE,
			TX_WINDOW_SCALE_IN => TCP001_TX_WINDOW_SCALE,
			TX_PAYLOAD_DATA => TCP001_TX_PAYLOAD_DATA,
			TX_PAYLOAD_DATA_VALID => TCP001_TX_PAYLOAD_DATA_VALID,
			TX_PAYLOAD_WORD_VALID => TCP001_TX_PAYLOAD_WORD_VALID,
			TX_PAYLOAD_DATA_EOF => TCP001_TX_PAYLOAD_DATA_EOF,
			TX_PAYLOAD_RTS => TCP001_TX_PAYLOAD_RTS,
			TX_PAYLOAD_CTS => TCP001_TX_PAYLOAD_CTS,
			TX_PAYLOAD_SIZE => TCP001_TX_PAYLOAD_SIZE,
			TX_PAYLOAD_CHECKSUM => TCP001_TX_PAYLOAD_CHECKSUM,
			MAC_TX_DATA => TCP001_MAC_TX_DATA,	
			MAC_TX_DATA_VALID => TCP001_MAC_TX_DATA_VALID,
			MAC_TX_EOF => TCP001_MAC_TX_EOF,
			MAC_TX_CTS => TCP001_MAC_TX_CTS,
			MSSv4 => MSSv4,
      MSSv6 => MSSv6,
			TP => open
		);

		TCP_TXBUF_001: TCP_TXBUF_10G 
		GENERIC MAP(
			NTCPSTREAMS => NTCPSTREAMS,
			ADDR_WIDTH => TCP_TX_WINDOW_SIZE-3,  -- elastic buffer size as 64b * 2^ADDR_WIDTH, max value: 12
			TX_IDLE_TIMEOUT => TX_IDLE_TIMEOUT,
			SIMULATION => SIMULATION
		)
		PORT MAP(
			CLK => CLK,
			SYNC_RESET => SYNC_RESET4,
			TICK_4US => TICK_4US,
			-- application interface -------
			APP_DATA => TCP_TX_DATA,
			APP_DATA_VALID => TCP_TX_DATA_VALID,
			APP_CTS => TCP001_TCP_TX_CTS,
			APP_DATA_FLUSH => TCP_TX_DATA_FLUSH,   
			-- TCP_SERVER interface -------
			EFF_RX_WINDOW_SIZE_PARTIAL_IN => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL,
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM,
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID,
			TX_SEQ_NO_IN => TCP001_TX_SEQ_NOxNTCPSTREAMS,
			TX_SEQ_NO_JUMP => TCP001_TX_SEQ_NO_JUMP,
			RX_TCP_ACK_NO_D => TCP001_RX_ACK_NOxNTCPSTREAMS,
			CONNECTED_FLAG => TCP001_CONNECTED_FLAG,
			TX_STREAM_SEL => TCP001_TX_STREAM_SEL,
			-- TCP_TX interface -------
			TX_PAYLOAD_DATA => TCP001_TX_PAYLOAD_DATA,
			TX_PAYLOAD_DATA_VALID => TCP001_TX_PAYLOAD_DATA_VALID,
			TX_PAYLOAD_WORD_VALID => TCP001_TX_PAYLOAD_WORD_VALID,
			TX_PAYLOAD_DATA_EOF => TCP001_TX_PAYLOAD_DATA_EOF,
			TX_PAYLOAD_RTS => TCP001_TX_PAYLOAD_RTS,
			TX_PAYLOAD_CTS => TCP001_TX_PAYLOAD_CTS,
			TX_PAYLOAD_SIZE => TCP001_TX_PAYLOAD_SIZE,
			TX_PAYLOAD_CHECKSUM => TCP001_TX_PAYLOAD_CHECKSUM,
			MSS => MSSv6,	-- 40byte header for IPv4/TCP but 60byte header for IPv6/TCP
			TP => TP_TCP_TXBUF--,
			--COM5503_TCP_TXBUF_DEBUG => COM5503_TCP_TXBUF_DEBUG
		);
		TCP_TX_CTS <= TCP001_TCP_TX_CTS;

		TCP_RXBUFNDEMUX2_001: TCP_RXBUFNDEMUX2_10G 
		GENERIC MAP(
			NTCPSTREAMS => NTCPSTREAMS,
			ADDR_WIDTH => TCP_RX_WINDOW_SIZE-3  -- elastic buffers size as 64b * 2^ADDR_WIDTH, MAX=12
		)
		PORT MAP(
			SYNC_RESET => SYNC_RESET3,
			CLK => CLK,
			RX_DATA => TCP001_RX_DATA,
			RX_DATA_VALID => TCP001_RX_DATA_VALID,
			RX_SOF => TCP001_RX_SOF,
			RX_TCP_STREAM_SEL => TCP001_RX_TCP_STREAM_SEL,
			RX_EOF => TCP001_RX_EOF,
			RX_FRAME_VALID => TCP_001_RX_FRAME_VALID,
			RX_FREE_SPACE => TCP001_RX_FREE_SPACE,	
			RX_BUF_CLR => (others => '0'),	-- TODO CLEAR ELASTIC BUFFERS AFTER CLOSING CONNECTION. BY APP???
			RX_APP_RTS => TCP_RX_RTS,
			RX_APP_DATA => TCP_RX_DATA,
			RX_APP_DATA_VALID => TCP_RX_DATA_VALID,
			RX_APP_CTS => TCP_RX_CTS,
			RX_APP_CTS_ACK => TCP_RX_CTS_ACK,
			TP => TP_TCPRXBUFNDEMUX2
		);
end generate;

--//-- IP ID generation
-- Increment IP ID every time an IP datagram is sent
IP_ID_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET2 = '1') then
			IP_ID <= (others => '0');	
		elsif(TCP001_MAC_TX_EOF = '1') or (UDP_TX_EOF = '1') or (DHCPC_MAC_TX_EOF = '1') or (IGMP_MAC_TX_EOF = '1') then
			-- increment every time an IP packet is send (or a commitment to send is made, in the case of UDP)
			-- Adjust as needed when other IP/UDP/TCP components are instantiated
			IP_ID <= IP_ID + 1;
		end if;
	end if;
end process;

--	
--//-- TRANSMISSION ARBITER --------------
-- determines the source for the next packet to be transmitted.
-- State machine to prevent overlapping between two packets ready... 
-- For example, one has to wait until a UDP packet has completed transmission 
-- before starting to send a TCP packet.
TX_MUX_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET2 = '1') then
			TX_MUX_STATE <= 0;	-- idle
		elsif(TX_MUX_STATE = 0) then
			if (MAC_TX_CTS = '1') then
				-- from idle to ...
				if(ARP_RTS = '1') then
					TX_MUX_STATE <= 1;	-- enable ARP response
				elsif(PING_RTS = '1') then
					TX_MUX_STATE <= 2;	-- enable PING response
				elsif(TCP001_RTS = '1') and (NTCPSTREAMS /= 0) then
					TX_MUX_STATE <= 3;	-- enable TCP001 transmission 
				elsif(WHOIS_RTS = '1') and ((NUDPTX /= 0) or (NTCPSTREAMS /= 0)) then
					TX_MUX_STATE <= 4;	-- enable WHOIS transmission
				elsif(UDP001_RTS = '1') and (NUDPTX /= 0) then
					TX_MUX_STATE <= 5;	-- enable UDP001 transmission (duplicate as needed)
				elsif(IGMP_RTS = '1') and (IGMP_EN = '1') and (NUDPTX /= 0) then
					TX_MUX_STATE <= 6;    -- enable IGMP message transmission
				elsif(ICMPV6_RTS = '1') and (IPv6_ENABLED = '1') then
					TX_MUX_STATE <= 7;    -- enable ICMPv6 message transmission--			
--				elsif(DHCPS_RTS = '1') and (DHCP_SERVER_EN = '1') and (DHCP_SERVER_EN2 = '1')then
--					TX_MUX_STATE <= 8;    -- enable DHCP server message transmission--			
				elsif(DHCPC_RTS = '1') and (DHCP_CLIENT_EN = '1') and (DYNAMIC_IPv4 = '1')then
					TX_MUX_STATE <= 9;    -- enable DHCP client message transmission--			
	--            elsif(TCP002_RTS = '1') and (NTCPSTREAMS /= 0) then
	--				TX_MUX_STATE <= 10;	-- enable TCP002 transmission 
				end if;
			end if;
		else
			-- Done transmitting. go from ... to idle
			if((TX_MUX_STATE = 1) and (ARP_MAC_TX_EOF = '1')) or
				((TX_MUX_STATE = 2) and (PING_MAC_TX_EOF = '1')) or
				((TX_MUX_STATE = 3) and (TCP001_MAC_TX_EOF = '1')) or	-- (duplicate as needed)]
				((TX_MUX_STATE = 4) and (WHOIS_MAC_TX_EOF = '1')) or
				((TX_MUX_STATE = 5) and (UDP001_MAC_TX_EOF = '1')) or 	-- (duplicate as needed)]
				((TX_MUX_STATE = 6) and (IGMP_MAC_TX_EOF = '1')) or
				((TX_MUX_STATE = 7) and (ICMPV6_MAC_TX_EOF = '1') and (IPv6_ENABLED = '1')) or
--				((TX_MUX_STATE = 8) and (DHCPS_MAC_TX_EOF = '1')) or
				((TX_MUX_STATE = 9) and (DHCPC_MAC_TX_EOF = '1')) then
				--((TX_MUX_STATE = 10) and (TCP002_MAC_TX_EOF = '1')  or
					TX_MUX_STATE <= 0;	-- idle
			end if;
		end if;
	end if;
end process;

MAC_TX_RTS <= ARP_RTS or PING_RTS or TCP001_RTS or WHOIS_RTS or UDP001_RTS or IGMP_RTS or DHCPC_RTS;

-- DESIGN NOTE: WHY DIFFERENT FROM TCP SERVER (PIPELINED)? WHICH IS BEST? 042719	
TX_MUX_002: process(TX_MUX_STATE, ARP_MAC_TX_EOF, ARP_MAC_TX_DATA_VALID, ARP_MAC_TX_DATA,
							PING_MAC_TX_EOF, PING_MAC_TX_DATA_VALID, PING_MAC_TX_DATA,
							TCP001_MAC_TX_EOF, TCP001_MAC_TX_DATA_VALID, TCP001_MAC_TX_DATA,
							WHOIS_MAC_TX_DATA, WHOIS_MAC_TX_DATA_VALID, WHOIS_MAC_TX_EOF,
							UDP001_MAC_TX_DATA, UDP001_MAC_TX_DATA_VALID, UDP001_MAC_TX_EOF,
							IGMP_MAC_TX_DATA, IGMP_MAC_TX_DATA_VALID, IGMP_MAC_TX_EOF,
							ICMPV6_MAC_TX_DATA, ICMPV6_MAC_TX_DATA_VALID, ICMPV6_MAC_TX_EOF,
							DHCPC_MAC_TX_DATA, DHCPC_MAC_TX_DATA_VALID, DHCPC_MAC_TX_EOF)
begin
	case(TX_MUX_STATE) is
		when (1) =>
			MAC_TX_DATA_local <= ARP_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= ARP_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= ARP_MAC_TX_EOF;
		when (2) =>
			MAC_TX_DATA_local <= PING_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= PING_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= PING_MAC_TX_EOF;
		when (3) =>
			MAC_TX_DATA_local <= TCP001_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= TCP001_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= TCP001_MAC_TX_EOF;
		when (4) =>
			MAC_TX_DATA_local <= WHOIS_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= WHOIS_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= WHOIS_MAC_TX_EOF;
		when (5) =>
			MAC_TX_DATA_local <= UDP001_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= UDP001_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= UDP001_MAC_TX_EOF;
      when (6) =>
			MAC_TX_DATA_local <= IGMP_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= IGMP_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= IGMP_MAC_TX_EOF;
      when (7) =>
			MAC_TX_DATA_local <= ICMPV6_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= ICMPV6_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= ICMPV6_MAC_TX_EOF;
--      when (8) =>
--			MAC_TX_DATA_local <= DHCPS_MAC_TX_DATA;
--			MAC_TX_DATA_VALID_local <= DHCPS_MAC_TX_DATA_VALID;
--			MAC_TX_EOF_local <= DHCPS_MAC_TX_EOF;
      when (9) =>
			MAC_TX_DATA_local <= DHCPC_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= DHCPC_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= DHCPC_MAC_TX_EOF;
--		when (10) =>
--			MAC_TX_DATA_local <= TCP002_MAC_TX_DATA;
--			MAC_TX_DATA_VALID_local <= TCP002_MAC_TX_DATA_VALID;
--			MAC_TX_EOF_local <= TCP002_MAC_TX_EOF;
		when others => 
			MAC_TX_DATA_local <= (others => '0');
			MAC_TX_DATA_VALID_local <= (others => '0');
			MAC_TX_EOF_local <= '0';
	end case;
end process;
MAC_TX_WORD_VALID <= '1' when (unsigned(MAC_TX_DATA_VALID_local) /= 0) else '0';
MAC_TX_EOF <= MAC_TX_EOF_local;

--//-- FLIP TX BYTE ORDER IN WORD --------------
-- flipping the MSB <-> LSB makes it easier to read the various fields values in this code or simulator
FLIP_TX_MAC_BYTES: process(MAC_TX_DATA_local, MAC_TX_DATA_VALID_local)
begin
	FOR I in 0 to 7 loop
		MAC_TX_DATA(I*8+7 downto I*8) <= MAC_TX_DATA_local((7-I)*8+7 downto (7-I)*8);
		MAC_TX_DATA_VALID(I) <= MAC_TX_DATA_VALID_local(7-I);
	end loop;
end process;

-- reconstruct a SOF pulse for local loopback
SOF_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET2 = '1') then
			MAC_TX_EOF_FLAGn <= '0';
		elsif(MAC_TX_EOF_local = '1') then
			MAC_TX_EOF_FLAGn <= '0';
		elsif(MAC_TX_WORD_VALID = '1') then
			MAC_TX_EOF_FLAGn <= '1';--

		end if;
	end if;
end process;
MAC_TX_EOF_FLAG <= not MAC_TX_EOF_FLAGn;
MAC_TX_SOF <= '1' when (MAC_TX_WORD_VALID = '1') and (MAC_TX_EOF_FLAG = '1') else '0';

-- Route "Clear To Send" signal from the MAC to the proper protocol component
ARP_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 1) else '0';
PING_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 2) else '0';
TCP001_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 3) else '0';
WHOIS_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 4) else '0';
UDP001_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 5) else '0';
IGMP_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 6) else '0';
ICMPV6_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 7) else '0'; 
--DHCPS_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 8) else '0'; 
DHCPC_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 9) else '0'; 
--TCP002_MAC_TX_CTS <= MAC_TX_CTS when (TX_MUX_STATE = 10) else '0';


--//-- ROUTING TABLE ARBITER --------------
-- Since several components could send simultaneous routing (RT) requests, one must 
-- determine who can access the routing table next
RT_MUX_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET2 = '1') then
			RT_MUX_STATE <= 0;	-- idle
		elsif(RT_MUX_STATE = 0) then
			-- from idle to ...
			if(UDP001_RT_REQ_RTS = '1') then
				RT_MUX_STATE <= 1;	-- gives UDP001 access to the routing table
			elsif(TCP001_RT_REQ_RTS = '1') then
				RT_MUX_STATE <= 2;	-- gives TCP001 access to the routing table
--			elsif(UDP002_RT_REQ_RTS = '1') then
--				RT_MUX_STATE <= 3;	-- gives UDP002 access to the routing table
--			elsif(UDP003_RT_REQ_RTS = '1') then
--				RT_MUX_STATE <= 4;	-- gives UDP003 access to the routing table
			end if;

		-- Routing table transaction complete. go back to idle
	 	elsif (RT_MAC_RDY = '1') or (RT_NAK = '1') then
			RT_MUX_STATE <= 0;	-- idle
	 	end if;
	end if;
end process;
	
RT_MUX_002: process(RT_MUX_STATE, UDP001_RT_IP_ADDR, UDP001_RT_IPv4_6n, UDP001_RT_REQ_RTS, TCP001_RT_IP_ADDR, TCP001_RT_IPv4_6n, TCP001_RT_REQ_RTS)
begin
	case(RT_MUX_STATE) is
		when (1) =>
			RT_IP_ADDR <= UDP001_RT_IP_ADDR;
			RT_IPv4_6n <= UDP001_RT_IPv4_6n;
			RT_REQ_RTS <= UDP001_RT_REQ_RTS;
		when (2) =>
			RT_IP_ADDR <= TCP001_RT_IP_ADDR;
			RT_IPv4_6n <= TCP001_RT_IPv4_6n;
			RT_REQ_RTS <= TCP001_RT_REQ_RTS;
--		when (3) =>
--			RT_IP_ADDR <= UDP002_RT_IP_ADDR;
--		--when (4) =>
--			RT_IP_ADDR <= UDP003_RT_IP_ADDR;
-- etc...
		when others =>
			RT_IP_ADDR <= (others => '0');
			RT_IPv4_6n <= '0';
			RT_REQ_RTS <= '0';
	end case;
end process;
		
UDP001_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 1) else '0';
TCP001_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 2) else '0';
--UDP002_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 3) else '0';
--UDP003_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 4) else '0';
-- etc...

UDP001_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 1) else '0';
TCP001_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 2) else '0';
--UDP002_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 3) else '0';
--UDP003_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 4) else '0';
-- etc...

UDP001_RT_NAK <= RT_NAK when (RT_MUX_STATE = 1) else '0';
TCP001_RT_NAK <= RT_NAK when (RT_MUX_STATE = 2) else '0';
--UDP002_RT_NAK <= RT_NAK when (RT_MUX_STATE = 3) else '0';
--UDP003_RT_NAK <= RT_NAK when (RT_MUX_STATE = 4) else '0';
-- etc...

--//-- TEST POINTS
--TP_001: process(CLK)
--begin
--	if rising_edge(CLK) then
--	    TP(5) <= VALID_UDP_CHECKSUM;
--	    TP(6) <= IP_PAYLOAD_DATA_VALID(7);
--	    TP(7) <= IP_PAYLOAD_SOF;
--	    TP(8) <= IP_PAYLOAD_EOF;
--	    TP(9) <= IP_RX_FRAME_VALID;
--	    TP(10) <= IP_RX_EOF;
--	end if;
--end process;
--TP(10 downto 1) <= TP_TCP_CLIENTS(10 downto 1);
--TP(1) <= UDP001_RTS;
--TP(2) <= UDP001_MAC_TX_CTS;
--TP(3) <= UDP001_MAC_TX_DATA_VALID(7);
--TP(4) <= UDP001_MAC_TX_EOF;

TP(1) <= '1' when (TX_MUX_STATE=1) else '0';	-- arp
TP(2) <= '1' when (TX_MUX_STATE=2) else '0';	-- ping
TP(3) <= '1' when (TX_MUX_STATE=3) else '0';	-- TCP
TP(4) <= '1' when (TX_MUX_STATE=4) else '0';	-- whois
TP(5) <= '1' when (TX_MUX_STATE=5) else '0';	-- udp tx
TP(6) <= '1' when (TX_MUX_STATE=6) else '0';	-- IGMP
TP(7) <= '1' when (TX_MUX_STATE=7) else '0';	-- ICMPV6
TP(8) <= '1' when (TX_MUX_STATE=9) else '0';	-- DHCPC
TP(9) <= '1' when (TX_MUX_STATE=0) else '0';	-- idle








----TP(5) <= '1' when (TX_MUX_STATE=5) else '0';	-- udp tx
----TP(5) <= UDP_TX_DATA_VALID;
----TP(6) <= UDP_TX_ACK_local;
----TP(7) <= UDP_TX_NAK_local;
----TP(8)	<= WHOIS_START;
----TP(9) <= RT_REQ_RTS;
----TP(10) <= RT_MAC_RDY;
--
----TP(1) <= IGMP_TRIGGER_RESPONSE;
----TP(2) <= IGMP_TRIGGER_RESPONSE2;
----TP(3) <= IGMP_REPORT_START;
----TP(4) <= TICK_100MS;
----TP(5) <= TICK_CNTR(0);
----TP(6) <= TICK_CNTR(5);
----TP(7) <= IGMP_MAC_TX_CTS;
----TP(8) <= IGMP_MAC_TX_DATA_VALID;
----TP(9) <= IGMP_MAC_TX_EOF;


end Behavioral;