library ieee;
use ieee.std_logic_1164.all;

library utils;
use utils.utils_pkg.all;

--library com5501_lib;
--library com5502_lib;
--use com5502_lib.com5502pkg.all;
library work;
use work.com5502pkg.all;

entity z7_10GbE_tcpip_server is
  generic(
    SIMULATION                : std_logic := '0';
    TCP_TX_WINDOW_SIZE        : integer;
    TCP_RX_WINDOW_SIZE        : integer;
    UDP_TX_EN                 : boolean := false;
    UDP_RX_EN                 : boolean := false;
    IPv6_ENABLED              : std_logic := '0';
    IGMP_EN                   : std_logic := '0';
    TX_IDLE_TIMEOUT           : integer := 50;
    TCP_KEEPALIVE_PERIOD      : integer := 60;
    TXPOLARITY                : std_logic;
    RXPOLARITY                : std_logic
  );
  port(
    -- 156.25MHz
    CLK                       : in std_logic;
    -- reset pulse must be > slowest clock period  (>400ns)
    -- synchronous with CLK
    RESET_MAC                 : in std_logic;
    RESET_STACK               : in std_logic;

    -- IP signals
    DYNAMIC_IPv4              : in std_logic;
    IPv4_ADDR                 : in std_logic_vector(31 downto 0);
    IPv4_MULTICAST_ADDR       : in std_logic_vector(31 downto 0);
    IPv4_SUBNET_MASK          : in std_logic_vector(31 downto 0);
    IPv4_GATEWAY_ADDR         : in std_logic_vector(31 downto 0);
    IPv6_ADDR                 : in std_logic_vector(127 downto 0);
    IPv6_SUBNET_PREFIX_LENGTH : in std_logic_vector(7 downto 0);
    IPv6_GATEWAY_ADDR         : in std_logic_vector(127 downto 0);
    CONNECTION_RESET          : in std_logic;
    TCP_KEEPALIVE_EN          : in std_logic;
    TCP_LOCAL_PORTS           : in std_logic_vector(15 downto 0);
    TCP_RX_DATA               : out std_logic_vector(63 downto 0);
    TCP_RX_DATA_VALID         : out std_logic_vector(7 downto 0);
    TCP_RX_RTS                : out std_logic;
    TCP_RX_CTS                : in std_logic;
    TCP_RX_CTS_ACK            : out std_logic;
    TCP_TX_DATA               : in std_logic_vector(63 downto 0);
    TCP_TX_DATA_VALID         : in std_logic_vector(7 downto 0);
    TCP_TX_DATA_FLUSH         : in std_logic;
    TCP_TX_CTS                : out std_logic;
    TCP_CONNECTED_FLAG        : out std_logic;
    UDP_RX_DATA               : out std_logic_vector(63 downto 0);
    UDP_RX_DATA_VALID         : out std_logic_vector(7 downto 0);
    UDP_RX_SOF                : out std_logic;
    UDP_RX_EOF                : out std_logic;
    UDP_RX_FRAME_VALID        : out std_logic;
    UDP_RX_DEST_PORT_NO_IN    : in std_logic_vector(15 downto 0);
    CHECK_UDP_RX_DEST_PORT_NO : in std_logic;
    UDP_RX_DEST_PORT_NO_OUT   : out std_logic_vector(15 downto 0);
    UDP_TX_DATA               : in std_logic_vector(63 downto 0);
    UDP_TX_DATA_VALID         : in std_logic_vector(7 downto 0);
    UDP_TX_SOF                : in std_logic;
    UDP_TX_EOF                : in std_logic;
    UDP_TX_CTS                : out std_logic;
    UDP_TX_ACK                : out std_logic;
    UDP_TX_NAK                : out std_logic;
    UDP_TX_DEST_IP_ADDR       : in std_logic_vector(127 downto 0);
    UDP_TX_DEST_IPv4_6n       : in std_logic;
    UDP_TX_DEST_PORT_NO       : in std_logic_vector(15 downto 0);
    UDP_TX_SOURCE_PORT_NO     : in std_logic_vector(15 downto 0);

    -- PCS/PMA signals
    PMA_PMD_TYPE              : in std_logic_vector(2 downto 0);
    PCS_CORE_STATUS           : out std_logic_vector(7 downto 0);
    SIGNAL_DETECT             : in std_logic;
    TX_FAULT                  : in std_logic;
    TX_DISABLE                : out std_logic;

    -- PCS/PMA shared signals
    TXUSRCLK                  : in std_logic;
    TXUSRCLK2                 : in std_logic;
    ARESET_CORECLK            : in std_logic;
    TXOUTCLK                  : out std_logic;
    GTTXRESET                 : in std_logic;
    GTRXRESET                 : in std_logic;
    TXUSERRDY                 : in std_logic;
    QPLLLOCK                  : in std_logic;
    QPLLOUTCLK                : in std_logic;
    QPLLOUTREFCLK             : in std_logic;
    RESET_COUNTER_DONE        : in std_logic;

    -- MAC
    MAC_ADDR                  : in std_logic_vector(47 downto 0);
    MAC_N_TX_FRAMES           : out std_logic_vector(15 downto 0);
    MAC_N_RX_FRAMES           : out std_logic_vector(15 downto 0);
    MAC_N_RX_BAD_CRCS         : out std_logic_vector(15 downto 0);
    MAC_N_RX_FRAMES_TOO_SHORT : out std_logic_vector(15 downto 0);
    MAC_N_RX_FRAMES_TOO_LONG  : out std_logic_vector(15 downto 0);
    MAC_N_RX_WRONG_ADDR       : out std_logic_vector(15 downto 0);
    MAC_N_RX_LENGTH_ERRORS    : out std_logic_vector(15 downto 0);
    MAC_RX_IPG                : out std_logic_vector(7 downto 0);

    -- PHY
    PHY_CONFIG_CHANGE         : in std_logic;
    PHY_RESET                 : in std_logic;
    PHY_TEST_MODE             : in std_logic_vector(1 downto 0);
    PHY_POWER_DOWN            : in std_logic;
    PHY_STATUS                : out std_logic_vector(7 downto 0);
    PHY_STATUS2               : out std_logic_vector(7 downto 0);
    PHY_ID                    : out std_logic_vector(15 downto 0);
    
    MTU                       : in std_logic_vector(13 downto 0);

    -- SFP Module
    TXP                       : out std_logic;
    TXN                       : out std_logic;
    RXP                       : in std_logic;
    RXN                       : in std_logic
  );
end z7_10GbE_tcpip_server;

architecture synthesis of z7_10GbE_tcpip_server is

  impure function get_nudptx return integer is
  begin
    if UDP_TX_EN then
      return 1;
    else
      return 0;
    end if;
  end get_nudptx;

  impure function get_nudprx return integer is
  begin
    if UDP_RX_EN then
      return 1;
    else
      return 0;
    end if;
  end get_nudprx;
  
  component COM5501
	generic (
		EXT_PHY_MDIO_ADDR: std_logic_vector(4 downto 0) := "00000";	
			-- external PHY MDIO address
		RX_BUFFER: std_logic := '0';
			-- '1' when the received messages are stored temporarily into an elastic buffer prior to the output. 
			-- either because the next block is slower (and thus regulates the data flow), or when crossing clock
			-- domains from CLK156g to CLK. 
			-- '0' for no output buffer: when flow control is not needed on the rx path and 
			-- the same 156.25 MHz clock is used as both user clock CLK and PHY clock CLK156g. 
			-- This setting is preferred for the lowest latency on the receive path.
		RX_BUFFER_ADDR_NBITS: integer := 10;
			-- size of the receiver output elastic buffer (when enabled by RX_BUFFER = '1'). Data width is always 74 bits.
			-- Example: when RX_BUFFER_ADDR_NBITS = 10, the receive buffer size is 74*2^10 = 75776 bits
		TX_BUFFER: std_logic := '0';
			-- '1' when the transmit messages are stored temporarily into an input elastic buffer,
			-- when crossing clock domains from user CLK to PHY CLK156g. 
			-- '0' for no input buffer: when the same 156.25 MHz clock is used as both user clock CLK and PHY clock CLK156g. 
			-- This setting is preferred for the lowest latency on the transmit path.
		TX_BUFFER_ADDR_NBITS: integer := 10;
		MAC_CONTROL_PAUSE_ENABLE: std_logic := '1';
		  -- enable (1)/disable (0) enacting transmit pause upon receive a MAC control PAUSE message.
		SIMULATION: std_logic := '0'
			-- during simulation, fake LINK_STATUS = '1'
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
			-- USER-side GLOBAL clock. Must be at least 156.25 MHz for full 10Gbits/s throughput.
			-- It must be the same signal as CLK156g when RX_BUFFER = '0' 
		SYNC_RESET: in std_logic;
			-- reset pulse must be > slowest clock period  (>400ns)
			-- synchronous with CLK
		CLK156g: in std_logic;
			-- PHY-side GLOBAL clock at 156.25 MHz
		
		--// MAC CONFIGURATION
		-- configuration signals are synchonous with the user-side CLK
		MAC_TX_CONFIG: in std_logic_vector(7 downto 0);
			-- bit 0: (1) Automatic padding of short frames. Requires that auto-CRC insertion be enabled too. 
			--			 (0) Skip padding. User is responsible for adding padding to meet the minimum 60 byte frame size
			-- bit 1: (1) Automatic appending of 32-bit CRC at the end of the frame
			--			 (0) Skip CRC32 insertion. User is responsible for including the frame check sequence
			-- Note: use 0x03 when interfacing with COM-5502 IP/UDP/TCP stack.
		MAC_RX_CONFIG: in std_logic_vector(7 downto 0);
			-- bit 0: (1) promiscuous mode enabled (0) disabled, i.e. destination address is verified for each incoming packet 
			-- bit 1: (1) accept broadcast rx packets (0) reject
			-- bit 2: (1) accept multi-cast rx packets (0) reject
			-- bit 3: unused
			-- bit 4: (1) Verify MTU size. Frames will be flagged as invalid if the payload size exceeds RX_MTU Bytes.
			--			 (0) Do not check MTU size
			-- Note2: use 0x0F when interfacing with COM-5502 IP/UDP/TCP stack.
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- This network node 48-bit MAC address. The receiver checks incoming packets for a match between 
			-- the destination address field and this MAC address.
			-- The user is responsible for selecting a unique �hardware� address for each instantiation.
			-- Natural bit order: enter x0123456789ab for the MAC address 01:23:45:67:89:ab
			-- here, x01 is the first received/transmitted byte in the address

		--// USER -> Transmit MAC Interface
		-- Synchonous with the user-side CLK
		MAC_TX_DATA: in std_logic_vector(63 downto 0);
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
			-- Bytes order: LSB is sent first
			-- Bytes are right aligned: first byte in LSB, occasional follow-on fill-in Bytes in the MSB(s)
			-- The first destination address byte is always a LSB (MAC_TX_DATA(7:0))
			-- USAGE RULE: only the end of frame word can be partially full (MAC_TX_DATA_VALID = 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f)
			-- all other words must contain either 0 or 8 bytes. 
		MAC_TX_DATA_VALID: in std_logic_vector(7 downto 0);
			-- '1' for each meaningful byte in MAC_TX_DATA. 
			-- In this application, only valid values are 0x00, 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff
		MAC_TX_EOF: in std_logic;
			-- '1' when sending the last word in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: out std_logic;
			-- MAC-generated Clear To Send flow control signal, indicating room in the 
			-- tx elastic buffer for a complete MTU. 
			-- The user should check that this signal is high before deciding to send
			-- sending the next frame. 
			-- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it.
		
		--// Receive MAC -> USER Interface
		-- Valid rx packets only: packets with bad CRC or invalid address are discarded.
		-- Synchonous with the user-side CLK
		-- The short-frame padding is included .
		MAC_RX_DATA: out std_logic_vector(63 downto 0);
			-- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID = '1'
			-- Bytes order: LSB was received first
			-- Bytes are right aligned: first byte in LSB, occasional follow-on fill-in Bytes in the MSB(s)
			-- The first destination address byte is always a LSB (MAC_RX_DATA(7:0))
		MAC_RX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- '1' for each meaningful byte in MAC_RX_DATA. 
			-- In this application, only valid values are 0x00, 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff
		MAC_RX_SOF: out std_logic;
			-- '1' when sending the first byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_EOF: out std_logic;
			-- '1' when sending the last byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
			-- The entire frame validity is confirmed at the end of frame when MAC_RX_FRAME_VALID = '1' 
			-- Users should discard the entire frame when MAC_RX_FRAME_VALID = '0' at  MAC_RX_EOF
		MAC_RX_FRAME_VALID: out std_logic;
			-- '1' when the received frame passed all validity checks, including CRC32.
			-- Read at the end of frame when MAC_RX_EOF = '1'
		MAC_RX_CTS: in std_logic;
			-- User-generated Clear To Send flow control signal. The receive MAC checks that this 
			-- signal is high before sending the next MAC_RX_DATA byte. 
			-- Ignored when the rx output buffer is not instantiated (RX_BUFFER = '0')
		-- parsed information from received MAC frame

		
		--// XGMII PHY Interface 
		XGMII_TXD: out std_logic_vector(63 downto 0);
		XGMII_TXC: out std_logic_vector(7 downto 0);
			-- Single data rate transmit interface 
			-- LSB is sent first
		
		XGMII_RXD: in std_logic_vector(63 downto 0);
		XGMII_RXC: in std_logic_vector(7 downto 0);
			-- Single data rate receive interface 
			-- LSb of LSB is received first
			-- Start character 0xFB is in byte 0 or 4
			-- XGMII_RXC bit is '0' for valid data byte
		RESET_N: out std_logic;
			-- PHY reset#
		MDC: out std_logic;
		MDIO_OUT: out std_logic;  
		MDIO_IN: in std_logic;
		MDIO_DIR: out std_logic;	-- '0' when output, '1' when input
			-- MDIO serial interface to control and monitor two MMDs: external 10G PHY and 
			-- internal XAUI adapter.

		--// PHY CONFIGURATION
		-- configuration signals are synchonous with the user-side CLK.
		PHY_CONFIG_CHANGE: in std_logic;
			-- optional pulse to activate any configuration change below.
			-- Not needed if the internal default values are acceptable.
		PHY_RESET: in std_logic; 
			-- 1 = PHY software reset (default), 0 = no reset
		TEST_MODE: in std_logic_vector(1 downto 0);
			-- 00 = normal mode (default)
			-- 01 = loopback mode
			-- 10 = remote loopback
		POWER_DOWN: in std_logic;
			-- software power down mode. 1 = enabled, 0 = disabled (default).


		--// PHY status
		-- synchronous with CLK156g global clock
		PHY_STATUS: out std_logic_vector(7 downto 0);
			-- XAUI side of the PHY chip
			-- bit0: all PHY XAUI rx lanes in sync
			-- bit1: PHY XAUI rx PLL in lock
			-- bit2: PHY XAUI rx lane0 signal present
			-- bit3: PHY XAUI rx lane1 signal present
			-- bit4: PHY XAUI rx lane2 signal present
			-- bit5: PHY XAUI rx lane3 signal present
			-- Expecting 0x3F during normal operations
			-- read periodically.
		PHY_STATUS2: out std_logic_vector(7 downto 0);
			-- SFP+ side of the PHY chip
		PHY_ID: out std_logic_vector(15 downto 0);
			-- read PHY device ID (part of hardware self-test). Correct answer for VSC8486-11 is 0x8486
			-- read once at power up.
			
		--// DIAGNOSTICS (synchronous with user-supplied clock CLK) 
		N_TX_FRAMES: out  std_logic_vector(15 downto 0);
			-- number of transmitted frames
		N_RX_FRAMES: out  std_logic_vector(15 downto 0);
			-- number of received frames
		N_RX_BAD_CRCS: out  std_logic_vector(15 downto 0);
			-- number of BAD CRCs among the received frames
		N_RX_FRAMES_TOO_SHORT: out  std_logic_vector(15 downto 0);
			-- number of rx frames too short (<64B)
		N_RX_FRAMES_TOO_LONG: out  std_logic_vector(15 downto 0);
			-- number of rx frames too long (>1518B)
		N_RX_WRONG_ADDR: out  std_logic_vector(15 downto 0);
			-- number of rx frames where address does not match (and promiscuous mode is off)
		N_RX_LENGTH_ERRORS: out  std_logic_vector(15 downto 0);
			-- number of rx frames with length field inconsistent with actual rx frame length
		RX_IPG: out std_logic_vector(7 downto 0);
			-- InterPacket Gap (in Bytes) between the last two successive packets (min is typically 12 Bytes, but
			-- can be as low as 5 Bytes for 10G).

		TX_MTU: in std_logic_vector(13 downto 0);
		RX_MTU: in std_logic_vector(13 downto 0);
      -- Maximum Transmission Unit: maximum number of payload Bytes.
      -- Typically 1500 for standard frames, 9000 for jumbo frames.
      -- A frame will be deemed invalid if its payload size exceeds this MTU value.
      
		--// TEST POINTS
		DEBUG1: out std_logic_vector(63 downto 0);
		DEBUG2: out std_logic_vector(63 downto 0);
		DEBUG3: out std_logic_vector(63 downto 0);
		TP: out std_logic_vector(10 downto 1)
		
 );
  end component; 
  
  component COM5502 is
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
		IPv6_ENABLED: std_logic := '0';
            -- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		DHCP_SERVER_EN: std_logic := '0';
			-- instantiate ('1') a DHCP server
			-- One can instantiate both DHCP server and DHCP client at the same time, but not enable them simultaneously
		DHCP_CLIENT_EN: std_logic := '0';
			-- '0' for static address (for minimum size), '1' for static/dynamic address (instantiates a DHCP_CLIENT component)
			-- One can instantiate both DHCP server and DHCP client at the same time, but not enable them simultaneously
		IGMP_EN: std_logic := '0';
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
			-- Mutually exclusive with DHCP_SERVER_EN2 (chose DHCP client OR server, but not both)
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
			-- Ignored when the DHCP client feature is enabled, as the DHCP server provides the gateway information. 
		IPv4_GATEWAY_ADDR: in std_logic_vector(31 downto 0);
			-- Ignored when the DHCP client feature is enabled, as the DHCP server provides the gateway information. 
		IPv6_ADDR: in std_logic_vector(127 downto 0);
            -- local IP address. 16 bytes for IPv6
		IPv6_SUBNET_PREFIX_LENGTH: in std_logic_vector(7 downto 0);
				 -- 128 - subnet size in bits. Usually expressed as /n. Typical range 64-128
		IPv6_GATEWAY_ADDR: in std_logic_vector(127 downto 0);

		--// User-initiated connection reset for stream I
		CONNECTION_RESET: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		TCP_KEEPALIVE_EN: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- enable TCP Keepalive (1) or not (0)

		--//-- DHCP SERVER CONFIGURATION
		DHCP_SERVER_EN2: in std_logic;
			-- enable(1)/disable(0) DHCP server at run-time. Requires DHCP_SERVER to be instantiated through DHCP_SERVER_EN
			-- Mutually exclusive with DYNAMIC_IP (chose DHCP client OR server, but not both)
		DHCP_SERVER_IP_MIN_LSB: in std_logic_vector(7 downto 0);
		DHCP_SERVER_NIPs: in std_logic_vector(7 downto 0);
			-- range of IP addresses to be assigned by this DHCP server
			-- the actual address is in the form IPv4_ADDR for the 3 MSB, and a subnet address between IP_MIN (inclusive)
			-- and IP_MIN + NIPs -1 (inclusive)
			-- Maximum 128 entries.
			-- For example, if IPv4_ADDR = 172.16.1.3, IP_MIN = 10, NIPs = 10, this DHCP server will assign and keep track of 
			-- IP addresses in the range 172.16.1.10 and 172.16.1.19 (inclusive).
		DHCP_SERVER_LEASE_TIME:  in std_logic_vector(31 downto 0);
			-- DHCP server to provide a lease time in secs to DHCP clients. 
			-- applicable only when DHCP server is instantiated within and enabled, DHCP_SERVER_EN/DHCP_SERVER_EN2='1'
		DHCP_ROUTER:  in std_logic_vector(31 downto 0);
			-- DHCP server to provide a router IP address to DHCP clients. 
			-- In a typical configuration, the router address is this device's address.
			-- However, the network administrator can decide to use point to another router (in effect rendering this router LAN to WAN link inoperative)
		DHCP_SERVER_DNS:  in std_logic_vector(31 downto 0);
			-- DHCP server to provide DNS address to DHCP clients. 
			-- applicable only when DHCP server is instantiated within and enabled, DHCP_SERVER_EN/DHCP_SERVER_EN2='1'

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
			-- TCP_SERVER port configuration. Each one of the NTCPSTREAMS streams handled by this
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
		TP: out std_logic_vector(10 downto 1)
	   
 );
end component;
  
--COMPONENT xxv_ethernet_0
--  PORT (
--    gt_txp_out : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
--    gt_txn_out : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
--    gt_rxp_in : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
--    gt_rxn_in : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
--    rx_core_clk_0 : IN STD_LOGIC;
--    txoutclksel_in_0 : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
--    rxoutclksel_in_0 : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
--    gt_dmonitorout_0 : OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
--    gt_eyescandataerror_0 : OUT STD_LOGIC;
--    gt_eyescanreset_0 : IN STD_LOGIC;
--    gt_eyescantrigger_0 : IN STD_LOGIC;
--    gt_pcsrsvdin_0 : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
--    gt_rxbufreset_0 : IN STD_LOGIC;
--    gt_rxbufstatus_0 : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
--    gt_rxcdrhold_0 : IN STD_LOGIC;
--    gt_rxcommadeten_0 : IN STD_LOGIC;
--    gt_rxdfeagchold_0 : IN STD_LOGIC;
--    gt_rxdfelpmreset_0 : IN STD_LOGIC;
--    gt_rxlatclk_0 : IN STD_LOGIC;
--    gt_rxlpmen_0 : IN STD_LOGIC;
--    gt_rxpcsreset_0 : IN STD_LOGIC;
--    gt_rxpmareset_0 : IN STD_LOGIC;
--    gt_rxpolarity_0 : IN STD_LOGIC;
--    gt_rxprbscntreset_0 : IN STD_LOGIC;
--    gt_rxprbserr_0 : OUT STD_LOGIC;
--    gt_rxprbssel_0 : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
--    gt_rxrate_0 : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
--    gt_rxslide_in_0 : IN STD_LOGIC;
--    gt_rxstartofseq_0 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
--    gt_txbufstatus_0 : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
--    gt_txdiffctrl_0 : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
--    gt_txinhibit_0 : IN STD_LOGIC;
--    gt_txlatclk_0 : IN STD_LOGIC;
--    gt_txmaincursor_0 : IN STD_LOGIC_VECTOR(6 DOWNTO 0);
--    gt_txpcsreset_0 : IN STD_LOGIC;
--    gt_txpmareset_0 : IN STD_LOGIC;
--    gt_txpolarity_0 : IN STD_LOGIC;
--    gt_txpostcursor_0 : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
--    gt_txprbsforceerr_0 : IN STD_LOGIC;
--    gt_txelecidle_0 : IN STD_LOGIC;
--    gt_txprbssel_0 : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
--    gt_txprecursor_0 : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
--    gtwiz_reset_tx_datapath_0 : IN STD_LOGIC;
--    gtwiz_reset_rx_datapath_0 : IN STD_LOGIC;
--    rxrecclkout_0 : OUT STD_LOGIC;
--    gt_drpclk_0 : IN STD_LOGIC;
--    gt_drprst_0 : IN STD_LOGIC;
--    gt_drpdo_0 : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
--    gt_drprdy_0 : OUT STD_LOGIC;
--    gt_drpen_0 : IN STD_LOGIC;
--    gt_drpwe_0 : IN STD_LOGIC;
--    gt_drpaddr_0 : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
--    gt_drpdi_0 : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
--    sys_reset : IN STD_LOGIC;
--    dclk : IN STD_LOGIC;
--    tx_mii_clk_0 : OUT STD_LOGIC;
--    rx_clk_out_0 : OUT STD_LOGIC;
--    gt_refclk_p : IN STD_LOGIC;
--    gt_refclk_n : IN STD_LOGIC;
--    gt_refclk_out : OUT STD_LOGIC;
--    gtpowergood_out_0 : OUT STD_LOGIC;
--    rx_reset_0 : IN STD_LOGIC;
--    user_rx_reset_0 : OUT STD_LOGIC;
--    rx_mii_d_0 : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
--    rx_mii_c_0 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
--    ctl_rx_test_pattern_0 : IN STD_LOGIC;
--    ctl_rx_data_pattern_select_0 : IN STD_LOGIC;
--    ctl_rx_test_pattern_enable_0 : IN STD_LOGIC;
--    ctl_rx_prbs31_test_pattern_enable_0 : IN STD_LOGIC;
--    stat_rx_framing_err_0 : OUT STD_LOGIC;
--    stat_rx_framing_err_valid_0 : OUT STD_LOGIC;
--    stat_rx_local_fault_0 : OUT STD_LOGIC;
--    stat_rx_block_lock_0 : OUT STD_LOGIC;
--    stat_rx_valid_ctrl_code_0 : OUT STD_LOGIC;
--    stat_rx_status_0 : OUT STD_LOGIC;
--    stat_rx_hi_ber_0 : OUT STD_LOGIC;
--    stat_rx_bad_code_0 : OUT STD_LOGIC;
--    stat_rx_bad_code_valid_0 : OUT STD_LOGIC;
--    stat_rx_error_0 : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
--    stat_rx_error_valid_0 : OUT STD_LOGIC;
--    stat_rx_fifo_error_0 : OUT STD_LOGIC;
--    tx_reset_0 : IN STD_LOGIC;
--    user_tx_reset_0 : OUT STD_LOGIC;
--    tx_mii_d_0 : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
--    tx_mii_c_0 : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
--    stat_tx_local_fault_0 : OUT STD_LOGIC;
--    ctl_tx_test_pattern_0 : IN STD_LOGIC;
--    ctl_tx_test_pattern_enable_0 : IN STD_LOGIC;
--    ctl_tx_test_pattern_select_0 : IN STD_LOGIC;
--    ctl_tx_data_pattern_select_0 : IN STD_LOGIC;
--    ctl_tx_test_pattern_seed_a_0 : IN STD_LOGIC_VECTOR(57 DOWNTO 0);
--    ctl_tx_test_pattern_seed_b_0 : IN STD_LOGIC_VECTOR(57 DOWNTO 0);
--    ctl_tx_prbs31_test_pattern_enable_0 : IN STD_LOGIC;
--    gt_loopback_in_0 : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
--    qpllreset_in_0 : IN STD_LOGIC
--  );
--END COMPONENT;  
  
  component ten_gig_eth_pcs_pma_0
    port(
      rxrecclk_out : out std_logic;
      coreclk : in std_logic;
      dclk : in std_logic;
      txusrclk : in std_logic;
      txusrclk2 : in std_logic;
      areset : in std_logic;
      txoutclk : out std_logic;
      areset_coreclk : in std_logic;
      gttxreset : in std_logic;
      gtrxreset : in std_logic;
      txuserrdy : in std_logic;
      qplllock : in std_logic;
      qplloutclk : in std_logic;
      qplloutrefclk : in std_logic;
      reset_counter_done : in std_logic;
      txp : out std_logic;
      txn : out std_logic;
      rxp : in std_logic;
      rxn : in std_logic;
      sim_speedup_control : in std_logic;
      xgmii_txd : in std_logic_vector(63 downto 0);
      xgmii_txc : in std_logic_vector(7 downto 0);
      xgmii_rxd : out std_logic_vector(63 downto 0);
      xgmii_rxc : out std_logic_vector(7 downto 0);
      mdc : in std_logic;
      mdio_in : in std_logic;
      mdio_out : out std_logic;
      mdio_tri : out std_logic;
      prtad : in std_logic_vector(4 downto 0);
      core_status : out std_logic_vector(7 downto 0);
      tx_resetdone : out std_logic;
      rx_resetdone : out std_logic;
      signal_detect : in std_logic;
      tx_fault : in std_logic;
      drp_req : out std_logic;
      drp_gnt : in std_logic;
      drp_den_o : out std_logic;
      drp_dwe_o : out std_logic;
      drp_daddr_o : out std_logic_vector(15 downto 0);
      drp_di_o : out std_logic_vector(15 downto 0);
      drp_drdy_o : out std_logic;
      drp_drpdo_o : out std_logic_vector(15 downto 0);
      drp_den_i : in std_logic;
      drp_dwe_i : in std_logic;
      drp_daddr_i : in std_logic_vector(15 downto 0);
      drp_di_i : in std_logic_vector(15 downto 0);
      drp_drdy_i : in std_logic;
      drp_drpdo_i : in std_logic_vector(15 downto 0);
      tx_disable : out std_logic;
      pma_pmd_type : in std_logic_vector(2 downto 0);
      gt0_eyescanreset : in std_logic;
      gt0_eyescandataerror : out std_logic;
      gt0_txbufstatus : out std_logic_vector(1 downto 0);
      gt0_rxbufstatus : out std_logic_vector(2 downto 0);
      gt0_eyescantrigger : in std_logic;
      gt0_rxcdrhold : in std_logic;
      gt0_txprbsforceerr : in std_logic;
      gt0_txpolarity : in std_logic;
      gt0_rxpolarity : in std_logic;
      gt0_rxprbserr : out std_logic;
      gt0_txpmareset : in std_logic;
      gt0_rxpmareset : in std_logic;
      gt0_txresetdone : out std_logic;
      gt0_rxresetdone : out std_logic;
      gt0_rxdfelpmreset : in std_logic;
      gt0_rxlpmen : in std_logic;
      gt0_dmonitorout : out std_logic_vector(7 downto 0);
      gt0_rxrate : in std_logic_vector(2 downto 0);
      gt0_txprecursor : in std_logic_vector(4 downto 0);
      gt0_txpostcursor : in std_logic_vector(4 downto 0);
      gt0_txdiffctrl : in std_logic_vector(3 downto 0)
    );
  end component;  

  -- PCS/PMA <-> MAC signals
  signal XGMII_TXD            : std_logic_vector(63 downto 0);
  signal XGMII_TXC            : std_logic_vector(7 downto 0);
  signal XGMII_RXD            : std_logic_vector(63 downto 0);
  signal XGMII_RXC            : std_logic_vector(7 downto 0);
  signal XGMII_RESET          : std_logic;
  signal XGMII_RESET_N        : std_logic;
  signal MDC                  : std_logic;
  signal MDIO_OUT             : std_logic;
  signal MDIO_IN              : std_logic;
  signal TX_RESETDONE         : std_logic;
  signal RX_RESETDONE         : std_logic;
  signal SIM_SPEEDUP_CONTROL  : std_logic := '0';

  -- MAC <-> TCP/UDP signals
  signal MAC_TX_DATA          : std_logic_vector(63 downto 0);
  signal MAC_TX_DATA_VALID    : std_logic_vector(7 downto 0);
  signal MAC_TX_EOF           : std_logic;
  signal MAC_TX_CTS           : std_logic;
  signal MAC_RX_DATA          : std_logic_vector(63 downto 0);
  signal MAC_RX_DATA_VALID    : std_logic_vector(7 downto 0);
  signal MAC_RX_SOF           : std_logic;
  signal MAC_RX_EOF           : std_logic;
  signal MAC_RX_FRAME_VALID   : std_logic;

  -- DRP signals
  signal DRP_REQ              : std_logic;
  signal DRP_DEN              : std_logic;
  signal DRP_DWE              : std_logic;
  signal DRP_DADDR            : std_logic_vector(15 downto 0);
  signal DRP_DI               : std_logic_vector(15 downto 0);
  signal DRP_DRDY             : std_logic;
  signal DRP_DRPDO            : std_logic_vector(15 downto 0);
begin

--  COM5502_inst: entity com5502_lib.COM5502
COM5502_inst: COM5502
    generic map(
      NTCPSTREAMS           => 1,
      NUDPTX                => get_nudptx,
      NUDPRX                => get_nudprx,
      TCP_TX_WINDOW_SIZE    => TCP_TX_WINDOW_SIZE,
      TCP_RX_WINDOW_SIZE    => TCP_RX_WINDOW_SIZE,
      IPv6_ENABLED          => IPv6_ENABLED,
      DHCP_SERVER_EN        => '0',
      DHCP_CLIENT_EN        => '1',
      IGMP_EN               => IGMP_EN,
      TX_IDLE_TIMEOUT       => TX_IDLE_TIMEOUT,
      TCP_KEEPALIVE_PERIOD  => TCP_KEEPALIVE_PERIOD,
      CLK_FREQUENCY         => 156,
      SIMULATION            => SIMULATION
    )
    port map(
      CLK                       => CLK,
      SYNC_RESET                => RESET_STACK,
      MAC_ADDR                  => MAC_ADDR,
      DYNAMIC_IPv4              => DYNAMIC_IPv4,
      REQUESTED_IPv4_ADDR       => IPv4_ADDR,
      IPv4_MULTICAST_ADDR       => IPv4_MULTICAST_ADDR,
      IPv4_SUBNET_MASK          => IPv4_SUBNET_MASK,
      IPv4_GATEWAY_ADDR         => IPv4_GATEWAY_ADDR,
      IPv6_ADDR                 => IPv6_ADDR,
      IPv6_SUBNET_PREFIX_LENGTH => IPv6_SUBNET_PREFIX_LENGTH,
      IPv6_GATEWAY_ADDR         => IPv6_GATEWAY_ADDR,
      CONNECTION_RESET(0)       => CONNECTION_RESET,
      TCP_KEEPALIVE_EN(0)       => TCP_KEEPALIVE_EN,
      DHCP_SERVER_EN2           => '0',
      DHCP_SERVER_IP_MIN_LSB    => x"00",
      DHCP_SERVER_NIPs          => x"00",
      DHCP_SERVER_LEASE_TIME    => x"00000000",
      DHCP_ROUTER               => x"00000000",
      DHCP_SERVER_DNS           => x"00000000",
      MAC_TX_DATA               => MAC_TX_DATA,
      MAC_TX_DATA_VALID         => MAC_TX_DATA_VALID,
      MAC_TX_SOF                => open,
      MAC_TX_EOF                => MAC_TX_EOF,
      MAC_TX_CTS                => MAC_TX_CTS,
      MAC_TX_RTS                => open,
      MAC_RX_DATA               => MAC_RX_DATA,
      MAC_RX_DATA_VALID         => MAC_RX_DATA_VALID,
      MAC_RX_SOF                => MAC_RX_SOF,
      MAC_RX_EOF                => MAC_RX_EOF,
      MAC_RX_FRAME_VALID        => MAC_RX_FRAME_VALID,
      UDP_RX_DATA               => UDP_RX_DATA,
      UDP_RX_DATA_VALID         => UDP_RX_DATA_VALID,
      UDP_RX_SOF                => UDP_RX_SOF,
      UDP_RX_EOF                => UDP_RX_EOF,
      UDP_RX_FRAME_VALID        => UDP_RX_FRAME_VALID,
      UDP_RX_DEST_PORT_NO_IN    => UDP_RX_DEST_PORT_NO_IN,
      CHECK_UDP_RX_DEST_PORT_NO => CHECK_UDP_RX_DEST_PORT_NO,
      UDP_RX_DEST_PORT_NO_OUT   => UDP_RX_DEST_PORT_NO_OUT,
      UDP_TX_DATA               => UDP_TX_DATA,
      UDP_TX_DATA_VALID         => UDP_TX_DATA_VALID,
      UDP_TX_SOF                => UDP_TX_SOF,
      UDP_TX_EOF                => UDP_TX_EOF,
      UDP_TX_CTS                => UDP_TX_CTS,
      UDP_TX_ACK                => UDP_TX_ACK,
      UDP_TX_NAK                => UDP_TX_NAK,
      UDP_TX_DEST_IP_ADDR       => UDP_TX_DEST_IP_ADDR,
      UDP_TX_DEST_IPv4_6n       => UDP_TX_DEST_IPv4_6n,
      UDP_TX_DEST_PORT_NO       => UDP_TX_DEST_PORT_NO,
      UDP_TX_SOURCE_PORT_NO     => UDP_TX_SOURCE_PORT_NO,
      TCP_LOCAL_PORTS(0)        => TCP_LOCAL_PORTS,
      TCP_RX_DATA(0)            => TCP_RX_DATA,
      TCP_RX_DATA_VALID(0)      => TCP_RX_DATA_VALID,
      TCP_RX_RTS(0)             => TCP_RX_RTS,
      TCP_RX_CTS(0)             => TCP_RX_CTS,
      TCP_RX_CTS_ACK(0)         => TCP_RX_CTS_ACK,
      TCP_TX_DATA(0)            => TCP_TX_DATA,
      TCP_TX_DATA_VALID(0)      => TCP_TX_DATA_VALID,
      TCP_TX_DATA_FLUSH(0)      => TCP_TX_DATA_FLUSH,
      TCP_TX_CTS(0)             => TCP_TX_CTS,
      TCP_CONNECTED_FLAG(0)     => TCP_CONNECTED_FLAG,
      MTU                       => MTU,
      CS1                       => open,
      CS1_CLK                   => open,
      CS2                       => open,
      CS2_CLK                   => open,
      DEBUG1                    => open,
      DEBUG2                    => open,
      DEBUG3                    => open,
      TP                        => open
   );

  --COM5501_inst: entity com5501_lib.COM5501
  COM5501_inst: COM5501
    generic map(
      EXT_PHY_MDIO_ADDR         => "00000",
      RX_BUFFER                 => '0',
      RX_BUFFER_ADDR_NBITS      => 1,
      TX_BUFFER                 => '0',
      TX_BUFFER_ADDR_NBITS      => 0,
      MAC_CONTROL_PAUSE_ENABLE  => '1',
      SIMULATION                => SIMULATION
    )
    port map(
      CLK                   => CLK,
      SYNC_RESET            => RESET_MAC,
      CLK156g               => CLK,
      MAC_TX_CONFIG         => "00000011",
      MAC_RX_CONFIG         => "00001111",
      MAC_ADDR              => MAC_ADDR,
      MAC_TX_DATA           => MAC_TX_DATA,
      MAC_TX_DATA_VALID     => MAC_TX_DATA_VALID,
      MAC_TX_EOF            => MAC_TX_EOF,
      MAC_TX_CTS            => MAC_TX_CTS,
      MAC_RX_DATA           => MAC_RX_DATA,
      MAC_RX_DATA_VALID     => MAC_RX_DATA_VALID,
      MAC_RX_SOF            => MAC_RX_SOF,
      MAC_RX_EOF            => MAC_RX_EOF,
      MAC_RX_FRAME_VALID    => MAC_RX_FRAME_VALID,
      MAC_RX_CTS            => '1',
      XGMII_TXD             => XGMII_TXD,
      XGMII_TXC             => XGMII_TXC,
      XGMII_RXD             => XGMII_RXD,
      XGMII_RXC             => XGMII_RXC,
      RESET_N               => XGMII_RESET_N,
      MDC                   => MDC,
      MDIO_OUT              => MDIO_IN,
      MDIO_IN               => MDIO_OUT,
      MDIO_DIR              => open,
      PHY_CONFIG_CHANGE     => PHY_CONFIG_CHANGE,
      PHY_RESET             => PHY_RESET,
      TEST_MODE             => PHY_TEST_MODE,
      POWER_DOWN            => PHY_POWER_DOWN,
      PHY_STATUS            => PHY_STATUS,
      PHY_STATUS2           => PHY_STATUS2,
      PHY_ID                => PHY_ID,
      N_TX_FRAMES           => MAC_N_TX_FRAMES,
      N_RX_FRAMES           => MAC_N_RX_FRAMES,
      N_RX_BAD_CRCS         => MAC_N_RX_BAD_CRCS,
      N_RX_FRAMES_TOO_SHORT => MAC_N_RX_FRAMES_TOO_SHORT,
      N_RX_FRAMES_TOO_LONG  => MAC_N_RX_FRAMES_TOO_LONG,
      N_RX_WRONG_ADDR       => MAC_N_RX_WRONG_ADDR,
      N_RX_LENGTH_ERRORS    => MAC_N_RX_LENGTH_ERRORS,
      RX_IPG                => MAC_RX_IPG,
      TX_MTU                => MTU,
      RX_MTU                => MTU,
      DEBUG1                => open,
      DEBUG2                => open,
      DEBUG3                => open,
      TP                    => open
   );

  XGMII_RESET <= not XGMII_RESET_N;

  sim_true: if SIMULATION = '1' generate
    process
    begin
      SIM_SPEEDUP_CONTROL <= '0';
      wait for 200 ns;
      SIM_SPEEDUP_CONTROL <= '1';
      wait;
    end process;
  end generate;


--your_instance_name : xxv_ethernet_0
--  PORT MAP (
--    gt_txp_out(0) => TXP,
--    gt_txn_out(0) => TXN,
--    gt_rxp_in(0) => RXP,
--    gt_rxn_in(0) => RXN,
--    rx_core_clk_0 => CLK,
--    txoutclksel_in_0 => txoutclksel_in_0,
--    rxoutclksel_in_0 => rxoutclksel_in_0,
--    gt_dmonitorout_0 => gt_dmonitorout_0,
--    gt_eyescandataerror_0 => gt_eyescandataerror_0,
--    gt_eyescanreset_0 => gt_eyescanreset_0,
--    gt_eyescantrigger_0 => gt_eyescantrigger_0,
--    gt_pcsrsvdin_0 => gt_pcsrsvdin_0,
--    gt_rxbufreset_0 => gt_rxbufreset_0,
--    gt_rxbufstatus_0 => gt_rxbufstatus_0,
--    gt_rxcdrhold_0 => gt_rxcdrhold_0,
--    gt_rxcommadeten_0 => gt_rxcommadeten_0,
--    gt_rxdfeagchold_0 => gt_rxdfeagchold_0,
--    gt_rxdfelpmreset_0 => gt_rxdfelpmreset_0,
--    gt_rxlatclk_0 => gt_rxlatclk_0,
--    gt_rxlpmen_0 => gt_rxlpmen_0,
--    gt_rxpcsreset_0 => GTRXRESET, --gt_rxpcsreset_0,
--    gt_rxpmareset_0 => GTRXRESET, --gt_rxpmareset_0,
--    gt_rxpolarity_0 => RXPOLARITY,
--    gt_rxprbscntreset_0 => gt_rxprbscntreset_0,
--    gt_rxprbserr_0 => gt_rxprbserr_0,
--    gt_rxprbssel_0 => gt_rxprbssel_0,
--    gt_rxrate_0 => gt_rxrate_0,
--    gt_rxslide_in_0 => gt_rxslide_in_0,
--    gt_rxstartofseq_0 => gt_rxstartofseq_0,
--    gt_txbufstatus_0 => gt_txbufstatus_0,
--    gt_txdiffctrl_0 => gt_txdiffctrl_0,
--    gt_txinhibit_0 => gt_txinhibit_0,
--    gt_txlatclk_0 => gt_txlatclk_0,
--    gt_txmaincursor_0 => gt_txmaincursor_0,
--    gt_txpcsreset_0 => GTTXRESET, --gt_txpcsreset_0,
--    gt_txpmareset_0 => GTTXRESET, --gt_txpmareset_0,
--    gt_txpolarity_0 => TXPOLARITY,
--    gt_txpostcursor_0 => gt_txpostcursor_0,
--    gt_txprbsforceerr_0 => gt_txprbsforceerr_0,
--    gt_txelecidle_0 => gt_txelecidle_0,
--    gt_txprbssel_0 => gt_txprbssel_0,
--    gt_txprecursor_0 => gt_txprecursor_0,
--    gtwiz_reset_tx_datapath_0 => gtwiz_reset_tx_datapath_0,
--    gtwiz_reset_rx_datapath_0 => gtwiz_reset_rx_datapath_0,
--    rxrecclkout_0 => open,
--    gt_drpclk_0 => gt_drpclk_0,
--    gt_drprst_0 => gt_drprst_0,
--    gt_drpdo_0 => DRP_DRPDO,
--    gt_drprdy_0 => DRP_DRDY,
--    gt_drpen_0 => DRP_DEN,
--    gt_drpwe_0 => DRP_DWE,
--    gt_drpaddr_0 => DRP_DADDR,
--    gt_drpdi_0 => DRP_DI,
--    sys_reset => sys_reset,
--    dclk => CLK,
--    tx_mii_clk_0 => TXOUTCLK, --tx_mii_clk_0,
--    rx_clk_out_0 => rx_clk_out_0,
--    gt_refclk_p => gt_refclk_p,
--    gt_refclk_n => gt_refclk_n,
--    gt_refclk_out => gt_refclk_out,
--    gtpowergood_out_0 => gtpowergood_out_0,
--    rx_reset_0 => rx_reset_0,
--    user_rx_reset_0 => user_rx_reset_0,
--    rx_mii_d_0 => XGMII_RXD, --rx_mii_d_0,
--    rx_mii_c_0 => XGMII_RXC, --rx_mii_c_0,
--    ctl_rx_test_pattern_0 => ctl_rx_test_pattern_0,
--    ctl_rx_data_pattern_select_0 => ctl_rx_data_pattern_select_0,
--    ctl_rx_test_pattern_enable_0 => ctl_rx_test_pattern_enable_0,
--    ctl_rx_prbs31_test_pattern_enable_0 => ctl_rx_prbs31_test_pattern_enable_0,
--    stat_rx_framing_err_0 => stat_rx_framing_err_0,
--    stat_rx_framing_err_valid_0 => stat_rx_framing_err_valid_0,
--    stat_rx_local_fault_0 => stat_rx_local_fault_0,
--    stat_rx_block_lock_0 => stat_rx_block_lock_0,
--    stat_rx_valid_ctrl_code_0 => stat_rx_valid_ctrl_code_0,
--    stat_rx_status_0 => stat_rx_status_0,
--    stat_rx_hi_ber_0 => stat_rx_hi_ber_0,
--    stat_rx_bad_code_0 => stat_rx_bad_code_0,
--    stat_rx_bad_code_valid_0 => stat_rx_bad_code_valid_0,
--    stat_rx_error_0 => stat_rx_error_0,
--    stat_rx_error_valid_0 => stat_rx_error_valid_0,
--    stat_rx_fifo_error_0 => stat_rx_fifo_error_0,
--    tx_reset_0 => tx_reset_0,
--    user_tx_reset_0 => user_tx_reset_0,
--    tx_mii_d_0 => XGMII_TXD, --tx_mii_d_0,
--    tx_mii_c_0 => XGMII_TXC, --tx_mii_c_0,
--    stat_tx_local_fault_0 => stat_tx_local_fault_0,
--    ctl_tx_test_pattern_0 => ctl_tx_test_pattern_0,
--    ctl_tx_test_pattern_enable_0 => ctl_tx_test_pattern_enable_0,
--    ctl_tx_test_pattern_select_0 => ctl_tx_test_pattern_select_0,
--    ctl_tx_data_pattern_select_0 => ctl_tx_data_pattern_select_0,
--    ctl_tx_test_pattern_seed_a_0 => ctl_tx_test_pattern_seed_a_0,
--    ctl_tx_test_pattern_seed_b_0 => ctl_tx_test_pattern_seed_b_0,
--    ctl_tx_prbs31_test_pattern_enable_0 => ctl_tx_prbs31_test_pattern_enable_0,
--    gt_loopback_in_0 => gt_loopback_in_0,
--    qpllreset_in_0 => ARESET_CORECLK --qpllreset_in_0
--  );

  ten_gig_eth_pcs_pma_0_inst: ten_gig_eth_pcs_pma_0
    port map(
      RXRECCLK_OUT          => open,
      CORECLK               => CLK,
      DCLK                  => CLK,
      TXUSRCLK              => TXUSRCLK,
      TXUSRCLK2             => TXUSRCLK2,
      ARESET                => XGMII_RESET,
      TXOUTCLK              => TXOUTCLK,
      ARESET_CORECLK        => ARESET_CORECLK,
      GTTXRESET             => GTTXRESET,
      GTRXRESET             => GTRXRESET,
      TXUSERRDY             => TXUSERRDY,
      QPLLLOCK              => QPLLLOCK,
      QPLLOUTCLK            => QPLLOUTCLK,
      QPLLOUTREFCLK         => QPLLOUTREFCLK,
      RESET_COUNTER_DONE    => RESET_COUNTER_DONE,
      TXP                   => TXP,
      TXN                   => TXN,
      RXP                   => RXP,
      RXN                   => RXN,
      SIM_SPEEDUP_CONTROL   => SIM_SPEEDUP_CONTROL,
      XGMII_TXD             => XGMII_TXD,
      XGMII_TXC             => XGMII_TXC,
      XGMII_RXD             => XGMII_RXD,
      XGMII_RXC             => XGMII_RXC,
      MDC                   => MDC,
      MDIO_IN               => MDIO_IN,
      MDIO_OUT              => MDIO_OUT,
      MDIO_TRI              => open,
      PRTAD                 => "00000",
      CORE_STATUS           => PCS_CORE_STATUS,
      TX_RESETDONE          => TX_RESETDONE,
      RX_RESETDONE          => RX_RESETDONE,
      SIGNAL_DETECT         => SIGNAL_DETECT,
      TX_FAULT              => TX_FAULT,
      DRP_REQ               => DRP_REQ,
      DRP_GNT               => DRP_REQ,
      DRP_DEN_O             => DRP_DEN,
      DRP_DWE_O             => DRP_DWE,
      DRP_DADDR_O           => DRP_DADDR,
      DRP_DI_O              => DRP_DI,
      DRP_DRDY_O            => DRP_DRDY,
      DRP_DRPDO_O           => DRP_DRPDO,
      DRP_DEN_I             => DRP_DEN,
      DRP_DWE_I             => DRP_DWE,
      DRP_DADDR_I           => DRP_DADDR,
      DRP_DI_I              => DRP_DI,
      DRP_DRDY_I            => DRP_DRDY,
      DRP_DRPDO_I           => DRP_DRPDO,
      TX_DISABLE            => TX_DISABLE,
      PMA_PMD_TYPE          => PMA_PMD_TYPE,
      GT0_EYESCANRESET      => '0',
      GT0_EYESCANDATAERROR  => open,
      GT0_TXBUFSTATUS       => open,
      GT0_RXBUFSTATUS       => open,
      GT0_EYESCANTRIGGER    => '0',
      GT0_RXCDRHOLD         => '0',
      GT0_TXPRBSFORCEERR    => '0',
      GT0_TXPOLARITY        => TXPOLARITY,
      GT0_RXPOLARITY        => RXPOLARITY,
      GT0_RXPRBSERR         => open,
      GT0_TXPMARESET        => '0',
      GT0_RXPMARESET        => '0',
      GT0_TXRESETDONE       => open,
      GT0_RXRESETDONE       => open,
      GT0_RXDFELPMRESET     => '0',
      GT0_RXLPMEN           => '0',
      GT0_DMONITOROUT       => open,
      GT0_RXRATE            => "000",
      GT0_TXPRECURSOR       => "00000",
      GT0_TXPOSTCURSOR      => "00000",
      GT0_TXDIFFCTRL        => "1110"
    );

end synthesis;
