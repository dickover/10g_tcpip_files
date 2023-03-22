-------------------------------------------------------------
-- MSS copyright 2019
--	Filename:  DHCP_SERVER_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 5/3/19
-- Inheritance: DHCP_SERVER.vhd  6/26/16
--
-- description:  
-- DHCP server (on-top of UDP_TX and UDP_RX). 10G version.
-- Based on RFC2131
-- Supports dynamic and automatic allocation:
-- dynamic allocation: A network administrator assigns a range of IP addresses to DHCP, and each client computer on the LAN 
-- is configured to request an IP address from the DHCP server during network initialization. The request-and-grant process 
-- uses a lease concept with a controllable time period, allowing the DHCP server to reclaim (and then reallocate) IP 
-- addresses that are not renewed.
-- automatic allocation: The DHCP server permanently assigns a free IP address to a requesting client from the range defined 
-- by the administrator. This is like dynamic allocation, but the DHCP server keeps a table of past IP address assignments, 
-- so that it can preferentially assign to a client the same IP address that the client previously had.
--
-- Limitations:
-- No support for static allocation.
-- Client and server are on the same subnet (no relay)
--
-- Usage:
-- 1. A DHCP server can be instantiated (using the DHCP_SERVER_EN generic parameter in COM5502/3.vhd), but still
-- enabled/disabled dynamically at run-time using the SYNC_RESET input. Set SYNC_RESET to '1' to disable this server.
-- 2. After changing DHCP server configuration parameter, the server must be reset.
-- 3. Proposed IP address is always on the same subnet as this server (i.e. same 3 MSBs as this server IPv4_ADDR)
-- 4. Limited to 6-byte (Ethernet) hardware addressing
--
-- Device utilization 
-- FF: 1534
-- LUT: 1399
-- DSP48: 0
-- 36Kb BRAM: 5
-- BUFG: 1
-- Minimum period: 6.122ns (Maximum Frequency: 163.359MHz)  Artix7-100T -1 speed grade

---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity DHCP_SERVER_10G is
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
			-- set to '1' to disable the DHCP server
		CLK: in std_logic;		-- synchronous clock
			-- Must be a global clocks. No BUFG instantiation within this component.
		TICK_4US: in std_logic;
		TICK_100MS : in std_logic;
			-- 100 ms tick for timer

		--// DHCP SERVER CONFIGURATION: IP address, MAC address, host name
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- this DHCP server IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
		HOST_NAME: in std_logic_vector(47 downto 0) := (others => '0');	-- 6 char max or hash if longer		
		IP_MIN: in std_logic_vector(7 downto 0);
		NIPs: in std_logic_vector(7 downto 0);
			-- range of IP addresses to be assigned by this DHCP server
			-- the actual address is in the form IPv4_ADDR for the 3 MSB, and a subnet address between IP_MIN (inclusive)
			-- and IP_MIN + NIPs -1 (inclusive)
			-- Maximum 128 entries.
			-- For example, if IPv4_ADDR = 172.16.1.3, IP_MIN = 10, NIPs = 10, this DHCP server will assign and keep track of 
			-- IP addresses in the range 172.16.1.10 and 172.16.1.19 (inclusive).
		LEASE_TIME:  in std_logic_vector(31 downto 0);
			-- lease time in secs
		SUBNET_MASK:  in std_logic_vector(31 downto 0);
		ROUTER:  in std_logic_vector(31 downto 0);
		DNS:  in std_logic_vector(31 downto 0);
		
		IP_ID_IN: in std_logic_vector(15 downto 0);
			-- 16-bit IP ID, unique for each datagram. Incremented every time
			-- an IP datagram is sent (not just for this protocol).

		--// Received UDP payload 
		-- DHCP message is encapsulated within a UDP frame
		UDP_RX_DATA: in std_logic_vector(63 downto 0);
 		    -- byte order: MSB first (reason: easier to read contents during simulation)
		UDP_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		UDP_RX_SOF: in std_logic;
		UDP_RX_EOF: in std_logic;
			-- 1 CLK pulse indicating that UDP_RX_DATA is the last word in the UDP data field.
			-- ALWAYS CHECK UDP_RX_FRAME_VALID at the end of packet (UDP_RX_EOF = '1') to confirm
			-- that the UDP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid UDP packet.
			-- Reason: we only knows about bad UDP packets at the end.
		UDP_RX_FRAME_VALID: in std_logic;
			-- check entire frame validity at UDP_RX_EOF
		UDP_RX_DEST_PORT_NO: in std_logic_vector(15 downto 0);
				-- Identify the destination UDP port. Read when UDP_RX_EOF = '1' 

		--// IP type, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0); 

		--// OUTPUT: TX UDP layer -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended by MAC. Not supplied here.
		MAC_TX_DATA: out std_logic_vector(63 downto 0) := (others => '0');
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID /= 0
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0) := (others => '0');
			-- data valid
		MAC_TX_EOF: out std_logic := '0';
			-- '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal. The user should check that this 
			-- signal is high before sending the next MAC_TX_DATA byte. 
		RTS: out std_logic := '0';
			-- '1' when a frame is ready to be sent (tell the COM550X arbiter)
			-- When the MAC starts reading the output buffer, it is expected that it will be
			-- read until empty.

		--// TEST POINTS 
--		N_DHCPDISCOVER_OUT: out std_logic_vector(7 downto 0);
--			-- monitors the number of received DHCPDISCOVER messages, modulo 256
--		N_DHCPREQUEST1_OUT: out std_logic_vector(7 downto 0);
--			-- monitors the number of received DHCPREQUEST messages addressed to this server (continuation of the DHCPDISCOVER), modulo 256
--		N_DHCPREQUEST2_OUT: out std_logic_vector(7 downto 0);
--			-- monitors the number of DHCPREQUEST messages for renewing state
--		N_DHCPREQUEST3_OUT: out std_logic_vector(7 downto 0);
--			-- monitors the number of DHCPREQUEST messages (INIT REBOOT STATE)
--		N_DHCPACK_OUT: out std_logic_vector(7 downto 0);
--			-- monitors the number of successful DHCPACK messages sent, concluding the dynamic IP address assignment, modulo 256
				
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of DHCP_SERVER_10G is
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

	COMPONENT UDP_TX_10G
	generic (
		ADDR_WIDTH: integer;
		UDP_CKSUM_ENABLED: std_logic;
		IPv6_ENABLED: std_logic
	);
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		TICK_4US: in std_logic;
		APP_DATA : IN std_logic_vector(63 downto 0);
		APP_DATA_VALID : IN std_logic_vector(7 downto 0);
		APP_SOF : IN std_logic;
		APP_EOF : IN std_logic;
		APP_CTS : OUT std_logic;
		DEST_IP_ADDR: in std_logic_vector(127 downto 0);	
		IPv4_6n: in std_logic;
		DEST_PORT_NO : IN std_logic_vector(15 downto 0);
		SOURCE_PORT_NO : IN std_logic_vector(15 downto 0);
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		IP_ID: in std_logic_vector(15 downto 0);
		ACK : OUT std_logic;
		NAK : OUT std_logic;
		RT_IP_ADDR : OUT std_logic_vector(127 downto 0);
		RT_IPv4_6n: out std_logic;
		RT_REQ_RTS: out std_logic;
		RT_REQ_CTS: in std_logic;
		RT_MAC_REPLY : IN std_logic_vector(47 downto 0);
		RT_MAC_RDY : IN std_logic;
		RT_NAK: in std_logic;
		MAC_TX_DATA : OUT std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID : OUT std_logic_vector(7 downto 0);
		MAC_TX_EOF : OUT std_logic;
		MAC_TX_CTS : IN std_logic;          
		RTS: out std_logic := '0';
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
--// TIME ------------------------------------------------
signal TIMER: integer range 0 to 50 := 0;
signal TIME_CNTR: unsigned(31 downto 0) := (others => '0');
signal CNTR10: unsigned(3 downto 0) := (others => '0');

--// UDP RX frame ---------------------------------------
signal VALID_UDP_DEST_PORT: std_logic := '0';
signal DHCP_RX_WORD_COUNT: unsigned(6 downto 0) := (others => '0');
signal DHCP_RX_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal DHCP_RX_DATA_D: std_logic_vector(63 downto 0) := (others => '0');
signal DHCP_RX_DATA_D_FLIPPED: std_logic_vector(63 downto 0) := (others => '0');
signal DHCP_RX_DATA_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal DHCP_RX_DATA_VALID_D: std_logic_vector(7 downto 0) := (others => '0');
signal DHCP_RX_SOF: std_logic := '0';
signal DHCP_RX_SOF_D: std_logic := '0';
signal DHCP_RX_EOF: std_logic := '0';
signal DHCP_RX_EOF_D: std_logic := '0';
signal DHCP_RX_WORD_VALID: std_logic := '0';
signal DHCP_RX_WORD_VALID_D: std_logic := '0';
signal CLIENT_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal XID: std_logic_vector(31 downto 0) := (others => '0');
signal XID4RESPONSE: std_logic_vector(31 downto 0) := (others => '0');
signal FLAGS: std_logic_vector(15 downto 0) := (others => '0');
signal CIADDR: std_logic_vector(31 downto 0) := (others => '0');
signal GIADDR: std_logic_vector(31 downto 0) := (others => '0');
signal MAGIC_COOKIE: std_logic_vector(31 downto 0) := (others => '0');
-- word to byte serialization
signal DHCP_RX_BYTE_COUNT: unsigned(9 downto 0) := (others => '1');
signal BUF1_SIZE: unsigned(9 downto 0) := (others => '0');
signal DHCP_RX_DATA2_VALID_E: std_logic := '0';
signal DHCP_RX_DATA2_VALID: std_logic := '0';
signal DHCP_RX_DATA2: std_logic_vector(7 downto 0) := (others => '0');
signal DHCP_READ_STATE: integer range 0 to 3 := 0;
signal DHCP_RX_EOF2: std_logic := '0';
signal DHCP_RX_EOF2_D: std_logic := '0';
signal DHCP_OPTION: unsigned(7 downto 0) := (others => '0');		
signal DHCP_MESSAGE_LENGTH: unsigned(7 downto 0) := (others => '0');		
signal DHCP_MESSAGE: std_logic_vector(95 downto 0) := (others => '0');		
signal DHCP_MESSAGE_TYPE: unsigned(3 downto 0) := (others => '0');		
signal DHCP_CLIENT_ID: std_logic_vector(55 downto 0) := (others => '0');		
signal DHCP_CLIENT_ID_D: std_logic_vector(55 downto 0) := (others => '0');		
signal DHCP_CLIENT_ID_MATCH: std_logic := '0'; 
signal DHCP_REQUESTED_IP_ADDR: std_logic_vector(31 downto 0) := (others => '0');		
signal DHCP_SERVER_IP_ADDR: unsigned(31 downto 0) := (others => '0');		
signal DHCP_PARAMETERS_REQUEST: std_logic_vector(23 downto 0) := (others => '0');		
signal DHCP_HOST_NAME: std_logic_vector(47 downto 0) := (others => '0');	-- 6 char max or hash if longer		
signal RX_VALID: std_logic := '0'; 
signal EVENT0: std_logic := '0'; 
signal EVENT1: std_logic := '0'; 
signal EVENT2A: std_logic := '0'; 
signal EVENT2B: std_logic := '0'; 
signal EVENT2C: std_logic := '0'; 
signal EVENT2D: std_logic := '0'; 
signal EVENT3A: std_logic := '0'; 
signal EVENT3B: std_logic := '0'; 
signal EVENT3C: std_logic := '0'; 
--signal EVENT4: std_logic := '0'; 
signal EVENT6: std_logic := '0'; 
--signal EVENT7: std_logic := '0'; 
--signal EVENT8: std_logic := '0'; 
signal EVENT10: std_logic := '0'; 
signal EVENT11: std_logic := '0'; 
signal STATE: integer range 0 to 31 := 0;

--//-- TABLE ---------------------------------------------------
signal WEA: std_logic := '0';
signal WEB: std_logic := '0';
signal DIA: std_logic_vector(31 downto 0) := (others => '0');
signal DIB: std_logic_vector(31 downto 0) := (others => '0');
signal DOA: std_logic_vector(31 downto 0) := (others => '0');
signal DOB: std_logic_vector(31 downto 0) := (others => '0');
--
--//-- SEARCH STATE MACHINE ---------------------------------------
signal TRIGGER_SEARCH_BY_CLIENTID: std_logic := '0'; 
signal SEARCH_STATE: integer range 0 to 3 := 0;  
signal SEARCH_STATE_D: integer range 0 to 3 := 0;  
signal SEARCH_STATE_D2: integer range 0 to 3 := 0;  
signal SEARCH_COMPLETE: std_logic := '0';
signal SEARCH_COMPLETE_D: std_logic := '0';
signal SEARCH_COMPLETE_D2: std_logic := '0';
signal ADDRA: std_logic_vector(9 downto 0) := (others => '0');  -- table is 512 x 36 + 1 bit for overflow detection
signal ADDRA_PLUS: std_logic_vector(9 downto 0) := (others => '0');  -- table is 512 x 36 + 1 bit for overflow detection
signal ADDRA_D: std_logic_vector(9 downto 0) := (others => '0'); 
signal ADDRA_D2: std_logic_vector(9 downto 0) := (others => '0'); 
signal ADDRB: std_logic_vector(9 downto 0) := (others => '0');  -- table is 512 x 36 + 1 bit for overflow detection
signal FOUND_CLIENT_ID: std_logic := '0'; 
signal FOUND_CLIENT_ID_D: std_logic := '0'; 
signal FOUND_IP: std_logic_vector(7 downto 0) := (others => '0');
signal FOUND_IP_PLUSMIN: std_logic_vector(7 downto 0) := (others => '0');
signal FOUND_OLDEST_IP: std_logic_vector(7 downto 0) := (others => '0');
signal FOUND_OLDEST_EXPIRATION_TIME: std_logic_vector(31 downto 0) := (others => '0');
signal EXPIRED_OLDEST_ENTRY: std_logic := '0'; 
signal PROPOSED_IP_ADDR: std_logic_vector(31 downto 0) := (others => '0');
signal IP_MATCH: std_logic := '0'; 
signal IP_MATCH_MSB: std_logic := '0'; 

--//-- COMPOSE REPLY --------------------------
signal DEST_IPv4_ADDR: std_logic_vector(31 downto 0) := (others => '0');
signal DEST_IPv4_ADDRx: std_logic_vector(127 downto 0) := (others => '0');
signal DEST_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal WPTR: unsigned(6 downto 0) := (others => '0');	-- maximum size 576Bytes or 73 Words
signal UDP_TX_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal UDP_TX_DATA_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal UDP_TX_SOF: std_logic := '0'; 
signal UDP_TX_EOF: std_logic := '0'; 
signal UDP_TX_CTS: std_logic := '0'; 
signal UDP_TX_ACK_local: std_logic := '0'; 
signal UDP_TX_NAK_local: std_logic := '0'; 
signal MAC_TX_EOF_local: std_logic := '0'; 
--
--//-- MONITORING ---------------------------------
signal N_DHCPDISCOVER: unsigned(7 downto 0) := (others => '0');
signal N_DHCPREQUEST1: unsigned(7 downto 0) := (others => '0');
signal N_DHCPREQUEST2: unsigned(7 downto 0) := (others => '0');
signal N_DHCPREQUEST3: unsigned(7 downto 0) := (others => '0');
signal N_DHCPACK: unsigned(7 downto 0) := (others => '0');
--
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// TIME ------------------------------------------------
-- track relative time in secs.
TIME_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			TIME_CNTR <= (0 => '1', others => '0');
			CNTR10 <= (others => '0');
		elsif(TICK_100MS = '1') then
			if(CNTR10 = 9) then
				-- TIME_CNTR units = seconds
				CNTR10 <= (others => '0');
				TIME_CNTR <= TIME_CNTR + 1;
			else
				CNTR10 <= CNTR10 + 1;
			end if;
		end if;
	end if;
end process;

--// UDP RX frame ---------------------------------------
-- DHCP is encapsulated within a UDP frame
-- verify UDP destination port is 67 (x0043)  67 is the DHCP server port
VALID_UDP_DEST_PORT <= '1' when (UDP_RX_DEST_PORT_NO = x"0043") else '0';
DHCP_RX_DATA <= UDP_RX_DATA;
DHCP_RX_DATA_VALID <= UDP_RX_DATA_VALID when (VALID_UDP_DEST_PORT = '1') else x"00";
DHCP_RX_SOF <= UDP_RX_SOF and VALID_UDP_DEST_PORT;
DHCP_RX_EOF <= UDP_RX_EOF and VALID_UDP_DEST_PORT;
DHCP_RX_WORD_VALID <= '1' when (UDP_RX_DATA_VALID /= x"00") and (VALID_UDP_DEST_PORT = '1') else '0';

-- keep track of the received DHCP rx pointer
-- Pointer DHCP_RX_WORD_COUNT aligned with DHCP_RX_DATA_VALID_D
-- DHCP message datagram can be up to 576 bytes, thus DHCP_RX_WORD_COUNT 7-bits
DHCP_RX_BYTE_COUNT_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		DHCP_RX_DATA_D <= DHCP_RX_DATA;
		DHCP_RX_DATA_VALID_D <= DHCP_RX_DATA_VALID;
		DHCP_RX_WORD_VALID_D <= DHCP_RX_WORD_VALID;
		DHCP_RX_SOF_D <= DHCP_RX_SOF;
		DHCP_RX_EOF_D <= DHCP_RX_EOF;
		
		if(SYNC_RESET = '1') or (DHCP_RX_SOF = '1') then
			DHCP_RX_WORD_COUNT <= (others => '0');
		elsif(DHCP_RX_WORD_VALID_D = '1') then
			if(DHCP_RX_WORD_COUNT(6) = '0') then	-- max 64. should not normally happen. 
				DHCP_RX_WORD_COUNT <= DHCP_RX_WORD_COUNT + 1;
			end if;
		end if;
	end if;
end process;

-- capture relevant fields (only while STATE = 6)
GET_FIELDS_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(DHCP_RX_WORD_VALID_D = '1') and (STATE = 6) then  -- *062516
			if(DHCP_RX_SOF_D = '1') then
				-- transaction ID
				XID <= DHCP_RX_DATA_D(31 downto 0);
			end if;
			if(DHCP_RX_WORD_COUNT = 1) then
				FLAGS <= DHCP_RX_DATA_D(47 downto 32);
				CIADDR <= DHCP_RX_DATA_D(31 downto 0);
			end if;
			if(DHCP_RX_WORD_COUNT = 3) then
				GIADDR <= DHCP_RX_DATA_D(63 downto 32);
				-- assumes a 6-byte Ethernet address (out of 16-byte field)
				CLIENT_MAC_ADDR(47 downto 16) <= DHCP_RX_DATA_D(31 downto 0);
			end if;
			if(DHCP_RX_WORD_COUNT = 4) then
				CLIENT_MAC_ADDR(15 downto 0) <= DHCP_RX_DATA_D(63 downto 48);
			end if;
			if(DHCP_RX_WORD_COUNT = 29) then
				MAGIC_COOKIE <= DHCP_RX_DATA_D(31 downto 0);
			end if;
		end if;
	end if;
end process;

-- parse the variable-length DHCP fields, starting immediately after the magic cookie		
-- serialize word through a small (1KB) DPRAM
-- this eases the parsing of the option fields
-- DHCP message datagram can be up to 576 bytes

-- flip LSB/MSB
PARSE_001: process(DHCP_RX_DATA_D)
begin
	for I in 0 to 7 loop
		DHCP_RX_DATA_D_FLIPPED((7-I)*8+7 downto (7-I)*8) <= DHCP_RX_DATA_D(I*8+7 downto I*8);
	end loop;
end process;

PARSE_002 : BRAM_DP2
generic map (
	DATA_WIDTHA => 8,
	ADDR_WIDTHA => 10,
	DATA_WIDTHB => 64,
	ADDR_WIDTHB => 7
)
port map(
	CSA => '1',
	CLKA => CLK,     
	WEA => '0',       
	ADDRA => std_logic_vector(DHCP_RX_BYTE_COUNT),   
	DIA => (others => '0'),       
	OEA => '1',
	DOA => DHCP_RX_DATA2,  	-- byte-wide
	CSB => '1',
	CLKB => CLK,     
	WEB => DHCP_RX_WORD_VALID_D,       
	ADDRB => std_logic_vector(DHCP_RX_WORD_COUNT), 
	DIB => DHCP_RX_DATA_D_FLIPPED,    
	OEB => '0',
	DOB => open     
);

BUF1_SIZE <= (DHCP_RX_WORD_COUNT & "000") + (not DHCP_RX_BYTE_COUNT);

PARSE_003: process(CLK)
begin
	if rising_edge(CLK) then 
		DHCP_RX_DATA2_VALID <= DHCP_RX_DATA2_VALID_E;	-- 1CLK latency to read from BRAM

		if(SYNC_RESET = '1') or (DHCP_RX_SOF = '1') then
			DHCP_RX_BYTE_COUNT <= (others => '1');
			DHCP_RX_DATA2_VALID_E <= '0';
		elsif(BUF1_SIZE > 0) then
			DHCP_RX_BYTE_COUNT <= DHCP_RX_BYTE_COUNT + 1;
			DHCP_RX_DATA2_VALID_E <= '1';
		else
			DHCP_RX_DATA2_VALID_E <= '0';
		end if;
	end if;
end process;

-- parse the variable-length DHCP fields, starting immediately after the magic cookie		
PARSE_DHCP_FIELDS: process(CLK)
begin
	if rising_edge(CLK) then 
		if(SYNC_RESET = '1') then
			DHCP_READ_STATE <= 0;
		elsif(DHCP_RX_BYTE_COUNT = 240) then 
			-- magic cookie immediately preceeds the DHCP options
			DHCP_READ_STATE <= 1;
			-- clear previous option fields
			DHCP_MESSAGE_TYPE <= (others => '0');
			DHCP_CLIENT_ID <= (others => '0');
			DHCP_REQUESTED_IP_ADDR <= (others => '0');
			DHCP_SERVER_IP_ADDR <= (others => '0');
			DHCP_HOST_NAME <= (others => '0');
		elsif(DHCP_RX_DATA2_VALID = '1') then
			if(DHCP_READ_STATE = 1) then
				if(DHCP_RX_DATA2 = x"FF") then
					-- end of DHCP options
					DHCP_READ_STATE <= 0;
				else	
					DHCP_READ_STATE <= 2;
					DHCP_OPTION <= unsigned(DHCP_RX_DATA2);
					DHCP_MESSAGE <= (others => '0');	-- clear message field before next option
				end if;
			elsif(DHCP_READ_STATE = 2) then
				DHCP_READ_STATE <= 3;
				DHCP_MESSAGE_LENGTH <= unsigned(DHCP_RX_DATA2);
			elsif(DHCP_READ_STATE = 3) then
				if(DHCP_MESSAGE_LENGTH = 1) then
					-- reached end of DHCP message
					DHCP_READ_STATE <= 1;
					-- save in various fields
					if(DHCP_OPTION = 53) then
						-- DHCP message type
						DHCP_MESSAGE_TYPE <= unsigned(DHCP_RX_DATA2(3 downto 0));	-- 1-8
					end if;
					if(DHCP_OPTION = 61) then
						-- client identifier
						DHCP_CLIENT_ID <= DHCP_MESSAGE(47 downto 0) & DHCP_RX_DATA2;	-- 7 bytes
					end if;
					if(DHCP_OPTION = 50) then
						-- requested IP address
						DHCP_REQUESTED_IP_ADDR <= DHCP_MESSAGE(23 downto 0) & DHCP_RX_DATA2;	-- 4 bytes
					end if;
					if(DHCP_OPTION = 54) then
						-- DHCP server identifier
						DHCP_SERVER_IP_ADDR <= unsigned(DHCP_MESSAGE(23 downto 0) & DHCP_RX_DATA2);	-- 4 bytes
					end if;
					if(DHCP_OPTION = 55) then
						-- DHCP parameters request list
						DHCP_PARAMETERS_REQUEST <= DHCP_MESSAGE(15 downto 0) & DHCP_RX_DATA2;	-- 3 bytes
					end if;
					if(DHCP_OPTION = 12) then
						-- host name
						DHCP_HOST_NAME <= DHCP_MESSAGE(39 downto 0) & DHCP_RX_DATA2;	-- 6 char max or hash if longer	
					end if;
						
				else
					DHCP_MESSAGE <= DHCP_MESSAGE(87 downto 0) & DHCP_RX_DATA2;
					DHCP_MESSAGE_LENGTH <= DHCP_MESSAGE_LENGTH - 1;
				end if;
			end if;
		end if;
	end if;
end process;
			
-- generate an EOF on the other side of the serialization buffer
DHCP_RX_EOF2 <= '1' when (DHCP_RX_DATA2_VALID = '1') and (DHCP_READ_STATE = 1) and (DHCP_RX_DATA2 = x"FF")  else '0';

-- check incoming message validity
-- ready at DHCP_RX_EOF1_D
VALID_CHECK_001: 	process(CLK)
begin
	if rising_edge(CLK) then
		DHCP_RX_EOF2_D <= DHCP_RX_EOF2;
		
		if(UDP_RX_SOF = '1') then
			RX_VALID <= '1';	-- valid by default, until proven otherwise
		elsif(UDP_RX_EOF = '1') and (UDP_RX_FRAME_VALID = '0') then 
			-- invalid UDP message
			RX_VALID <= '0';	
		elsif(DHCP_RX_EOF2 = '1') and (MAGIC_COOKIE /= x"63825363") then
			RX_VALID <= '0';	
		end if;
	end if;
end process;

		
--//-- EVENTS ---------------------------------------------------
-- 0 = start of new rx message addressed to port 67 (x0043)
EVENT0 <= DHCP_RX_SOF when (unsigned(UDP_RX_DEST_PORT_NO) = 67) else '0';

-- 10 = end of invalid rx message (before parallel to serial buffer)
EVENT10 <= DHCP_RX_EOF when (UDP_RX_FRAME_VALID = '0') or (unsigned(UDP_RX_DEST_PORT_NO) /= 67) else '0';

-- 11 = end of invalid rx message (after parallel to serial buffer)
EVENT11 <= DHCP_RX_EOF2_D when (RX_VALID = '0')  else '0';

-- 1 = DHCP Discover message (DHCPDISCOVER).
EVENT1 <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 1) else '0';

-- 3 = DHCP Request message (DHCPREQUEST) addressed to the right DHCP server
EVENT3A <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 3)
					and (DHCP_SERVER_IP_ADDR = unsigned(IPv4_ADDR)) else '0';

-- 3 = DHCP Request message (DHCPREQUEST) for renewing 
EVENT3B <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 3)
					and (DHCP_SERVER_IP_ADDR = 0) and (unsigned(DHCP_REQUESTED_IP_ADDR) = 0) 
					and ((CIADDR and SUBNET_MASK) = (IPv4_ADDR and SUBNET_MASK))	-- client IP addr on the correct network
					else '0';
					
-- 3 = DHCP Request message (DHCPREQUEST) for init-reboot 
EVENT3C <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 3)
					and (DHCP_SERVER_IP_ADDR = 0) and (unsigned(DHCP_REQUESTED_IP_ADDR) /= 0) 
					and (unsigned(CIADDR) = 0) else '0';

---- 4 = DHCP Request message (DHCPDECLINE).
--EVENT4 <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 4) else '0';
--
-- 6 = end of message (whether valid or processed or not)
EVENT6 <= '1' when (DHCP_RX_EOF2_D = '1') else '0';

---- 7 = DHCP Request message (DHCPRELEASE).
--EVENT7 <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 7) else '0';
--
---- 8 = DHCP Request message (DHCPINFORM).
--EVENT8 <= '1' when (DHCP_RX_EOF2_D = '1') and (RX_VALID = '1') and (DHCP_MESSAGE_TYPE = 8) else '0';
--
-- search by client ID complete, found match
EVENT2A <= SEARCH_COMPLETE_D2 and FOUND_CLIENT_ID;

-- search by client ID complete, found no entry 
EVENT2B <= SEARCH_COMPLETE_D2 and (not FOUND_CLIENT_ID);

-- search by client ID complete, found no entry and oldest entry has expired (free to re-assign)
EVENT2C <= SEARCH_COMPLETE_D2 and (not FOUND_CLIENT_ID) and EXPIRED_OLDEST_ENTRY;

-- search by client ID complete, found match, IP request matches table entry
EVENT2D <= SEARCH_COMPLETE_D2 and FOUND_CLIENT_ID and IP_MATCH;

--//-- STATE MACHINE ---------------------------------------------------
-- new replace too large ifthenelse with case for better timing
STATE_GEN_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE <= 0;	-- idle
			TRIGGER_SEARCH_BY_CLIENTID <= '0';
		elsif(EVENT10 = '1') or (EVENT11 = '1') then
			-- invalid rx UDP frame
			STATE <= 0;	-- idle
		else
			case STATE is
				when 0 => 
					if(EVENT0 = '1') then
						-- new incoming message. start parsing fields
						STATE <= 6;
					end if;
				when 6 => 
					--------- DHCPDISCOVER --------------------------------	
					if(EVENT1 = '1') then 
						-- received valid DHCPDISCOVER, start table search
						STATE <= 1;
						N_DHCPDISCOVER <= N_DHCPDISCOVER + 1;
						-- freeze key fields (XID, client ID) for response
						XID4RESPONSE <= XID;
						DHCP_CLIENT_ID_D <= DHCP_CLIENT_ID;
						TRIGGER_SEARCH_BY_CLIENTID <= '1';
					--------- DHCPREQUEST (SELECTING STATE) --------------------------------	
					elsif(EVENT3A = '1') then 
						-- received DHCP Request message (DHCPREQUEST) addressed to the right DHCP server
						STATE <= 8;
						N_DHCPREQUEST1 <= N_DHCPREQUEST1 + 1;
						-- save XID for response
						XID4RESPONSE <= XID;
						DHCP_CLIENT_ID_D <= DHCP_CLIENT_ID;
						TRIGGER_SEARCH_BY_CLIENTID <= '1';
					--------- DHCPREQUEST (RENEWING STATE) --------------------------------	
					elsif(EVENT3B = '1') then 
						-- received DHCP Request message (DHCPREQUEST) for renewing 
						STATE <= 16;
						N_DHCPREQUEST2 <= N_DHCPREQUEST1 + 2;
						-- save XID for response
						XID4RESPONSE <= XID;
						DHCP_CLIENT_ID_D <= DHCP_CLIENT_ID;
					--------- DHCPREQUEST (INIT REBOOT STATE) --------------------------------	
					elsif(EVENT3C = '1') then 
						if(unsigned(DHCP_REQUESTED_IP_ADDR and SUBNET_MASK) = unsigned(IPv4_ADDR and SUBNET_MASK)) then
							-- correct network. next verify table
							STATE <= 24;
							N_DHCPREQUEST3 <= N_DHCPREQUEST3 + 1;
							-- save XID for response
							XID4RESPONSE <= XID;
							DHCP_CLIENT_ID_D <= DHCP_CLIENT_ID;
						else
							-- incorrect network. send DHCPNAK 
							STATE <= 26;
						end if;
					elsif(EVENT6 = '1') then
						-- end of message, none of the above. Back to idle
						STATE <= 0;
					end if;

				when 1 => 
					TRIGGER_SEARCH_BY_CLIENTID <= '0';
					if(EVENT2A = '1') then
						-- search by client ID complete, found match
						-- send DHCPOFFER
						PROPOSED_IP_ADDR(7 downto 0) <= FOUND_IP_PLUSMIN;
						STATE <= 3;
					elsif(EVENT2C = '1') then
						-- search by client ID complete, found no entry and oldest entry has expired (free to re-assign)
						STATE <= 2;
					end if;
				when 2 => 
					-- done creating new entry with client ID from DHCPDISCOVER
					-- send DHCPOFFER
					PROPOSED_IP_ADDR(7 downto 0) <= std_logic_vector(unsigned(FOUND_OLDEST_IP) + unsigned(IP_MIN));
					STATE <= 3;
				when 3 => 
					if (UDP_TX_ACK_local = '1') then 
						-- composed UDP reply. UDP confirmed. awaiting MAC confirmation.
						STATE <= 4;
					elsif (UDP_TX_NAK_local = '1') then 
						-- composed UDP reply. NAK from UDP_TX (abnormal). Abort.
						STATE <= 0;
					end if;
				when 4 => 
					if (MAC_TX_EOF_local = '1') then 
						-- MAC transmission completion confirmed
						STATE <= 0;
					end if;
				when 8 => 
					TRIGGER_SEARCH_BY_CLIENTID <= '0';
					if(EVENT2D = '1') then
						-- search by client ID complete, matching IP request/table index
						-- write new expiration
						STATE <= 9;
					elsif(EVENT2B = '1') then
						-- no match
						-- TODO
						STATE <= 0;
					end if;
				when 9 => 
					-- send DHCPACK
					PROPOSED_IP_ADDR(7 downto 0) <= FOUND_IP_PLUSMIN;  
					STATE <= 10;
				when 10 => 
					if (UDP_TX_ACK_local = '1') then 
						-- composed UDP reply. UDP confirmed. awaiting MAC confirmation.
						STATE <= 11;
					elsif(UDP_TX_NAK_local = '1') then 
						-- composed UDP reply. NAK from UDP_TX (abnormal). Abort.
						STATE <= 0;
					end if;
				when 11 => 
					if (MAC_TX_EOF_local = '1') then 
						-- MAC transmission completion confirmed
						STATE <= 0;
						N_DHCPACK <= N_DHCPACK + 1;
					end if;
				when 16 => 
					-- waiting 1 CLK to read/verify the client ID from the table
					STATE <= 17;
				when 17 => 
					-- wait one more CLK to do a large comparison (timing0
					STATE <= 18;
				when 18 => 
					if(DHCP_CLIENT_ID_MATCH = '1') then
						-- client ID matches information in table
						-- write new expiration date, send DHCPACK
						STATE <= 9;
					else
						-- abnormal case. IP address to renew is not associated with the correct client ID in the table
						STATE <= 0;
					end if;
				when 24 => 
					-- correct network. 
					-- waiting 1 CLK to read/verify the client ID from the table
					STATE <= 25;
				when 25 => 
					if(unsigned(DOA) = 0) then
						-- DHCP server has no record of this client. 
						-- server MUST remain silent
						STATE <= 0;
					elsif(DOA(23 downto 0) = DHCP_CLIENT_ID_D(55 downto 32)) and (DOB = DHCP_CLIENT_ID_D(31 downto 0)) then 
						-- client ID matches information in table
						-- write new expiration date, send DHCPACK
						STATE <= 9;
					else
						-- abnormal case. Requested IP address is not associated with the correct client ID in the table
						-- send DHCPNAK
						STATE <= 26;
					end if;
				when 26 => 
					if(UDP_TX_ACK_local = '1') then 
						-- composed UDP reply. UDP confirmed. awaiting MAC confirmation.
						STATE <= 27;
					elsif(UDP_TX_NAK_local = '1') then 
						-- composed UDP reply. NAK from UDP_TX (abnormal). Abort.
						STATE <= 0;
					end if;
				when 27 => 
					if(MAC_TX_EOF_local = '1') then 
						-- MAC transmission completion confirmed
						STATE <= 0;
					end if;
				when others => null;
			end case;
		end if;
	end if;
end process;

	
PROPOSED_IP_ADDR(31 downto 8) <= IPv4_ADDR(31 downto 8);
	-- Proposed IP address is always on the same subnet as this server (i.e. same 3 MSBs as this server IPv4_ADDR)

--//-- TABLE ---------------------------------------------------
-- Each entry comprises 4 * 36-bit locations. 128 entries max.
-- location0: 8-bit spare + 24-bit client identifier (47:32) + 4-bit spare (parity)
-- location1: 32-bit client identifier (31:0) + 4-bit spare (parity)
-- location2: 32-bit TIME (31:0) + 4-bit spare (parity)
-- location3: spare

-- One table entry per bindable IP address.
-- IP address binding is implied by the address.
-- the actual address is in the form IPv4_ADDR for the 3 MSB, and a subnet address between IP_MIN (inclusive)
-- and IP_MIN + NIPs -1 (inclusive)
-- For example, if IPv4_ADDR = 172.16.1.3, IP_MIN = 10, NIPs = 10, this DHCP server will assign and keep track of 
-- IP addresses in the range 172.16.1.10 and 172.16.1.19 (inclusive).

RAMB1_1 : BRAM_DP2
generic map (
	DATA_WIDTHA => 32,
	ADDR_WIDTHA => 9,
	DATA_WIDTHB => 32,
	ADDR_WIDTHB => 9
)
port map(
	CSA => '1',
	CLKA => CLK,     
	WEA => WEA,       
	ADDRA => ADDRA(8 downto 0), 
	DIA => DIA,    
	OEA => '1',
	DOA => DOA,     
	CSB => '1',
	CLKB => CLK,     
	WEB => WEB,       
	ADDRB => ADDRB(8 downto 0),   
	DIB => DIB,       
	OEB => '1',
	DOB => DOB  
);

--//-- SEARCH STATE MACHINE ---------------------------------------
-- search the table based on a client ID
-- new simplified process for timing 4/5/14 az
SEARCH_STATE_MACHINE_001a: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			SEARCH_STATE <= 0;
		elsif(SEARCH_STATE = 0) then
			if(TRIGGER_SEARCH_BY_CLIENTID = '1') then
				SEARCH_STATE <= 1;
			elsif(STATE = 2) then
				-- (over)write oldest expired entry with this new DHCPDISCOVER client ID
				SEARCH_STATE <= 2;
				WEA <= '1';
				WEB <= '1';
			elsif(STATE = 9) then
				-- write new expiration 
				SEARCH_STATE <= 3;
				WEA <= '1';
				WEB <= '0';
			end if;
		elsif(SEARCH_STATE = 1) then
			if(ADDRA_PLUS(9) = '1') then
				-- scan complete
				SEARCH_STATE <= 0;
			end if;
		elsif(SEARCH_STATE = 2) then
			-- done creating new entry in table with client ID from DHCPDISCOVER
			SEARCH_STATE <= 0;
			WEA <= '0';
			WEB <= '0';
		elsif(SEARCH_STATE = 3) then
			-- done updating entry in table with fresh expiration
			SEARCH_STATE <= 0;
			WEA <= '0';
		end if;
	end if;
end process;

SEARCH_STATE_MACHINE_001b: process(CLK)
begin
	if rising_edge(CLK) then
		if(SEARCH_STATE = 0) and (TRIGGER_SEARCH_BY_CLIENTID = '0') then
			if (STATE = 2) then
				-- (over)write oldest expired entry with this new DHCPDISCOVER client ID
				DIA(23 downto 0) <= DHCP_CLIENT_ID_D(55 downto 32);
				DIB <= DHCP_CLIENT_ID_D(31 downto 0);
			elsif(STATE = 9) then
				-- write new expiration 
				DIA <= std_logic_vector(TIME_CNTR + unsigned(LEASE_TIME));
			end if;
		end if;
	end if;
end process;

-- new simplified process for timing 4/5/14 az
SEARCH_STATE_MACHINE_001c: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			SEARCH_COMPLETE <= '0';
		elsif(SEARCH_STATE = 1) and(ADDRA_PLUS(9) = '1') then
			-- scan complete
			SEARCH_COMPLETE <= '1';	-- aligned with last search in SEARCH_STATE_D/ADDRA_D
		else
			SEARCH_COMPLETE <= '0';
		end if;
	end if;
end process;

ADDRA_PLUS <= std_logic_vector(unsigned(ADDRA) + 2);
SEARCH_STATE_MACHINE_001d: process(CLK)
begin
	if rising_edge(CLK) then
		if(SEARCH_STATE = 0) then
			if(TRIGGER_SEARCH_BY_CLIENTID = '1') then
				ADDRA <= (others => '0');
				ADDRB <= (0 => '1', others => '0');	
			elsif(STATE = 2) then
				-- (over)write oldest expired entry with this new DHCPDISCOVER client ID
				ADDRA <= FOUND_OLDEST_IP & "00";
				ADDRB <= FOUND_OLDEST_IP & "01";
			elsif(STATE = 9) then
				-- write new expiration 
				ADDRA <= FOUND_IP & "10";
			elsif(STATE = 16) then
				-- read client ID from the table (to verify)
				ADDRA <=  std_logic_vector((unsigned(CIADDR(7 downto 0)) - unsigned(IP_MIN)) & "00");
				ADDRB <=  std_logic_vector((unsigned(CIADDR(7 downto 0)) - unsigned(IP_MIN)) & "01");
			elsif(STATE = 24) then
				-- read client ID from the table (to verify)
				ADDRA <=  std_logic_vector((unsigned(DHCP_REQUESTED_IP_ADDR(7 downto 0)) - unsigned(IP_MIN)) & "00");
				ADDRB <=  std_logic_vector((unsigned(DHCP_REQUESTED_IP_ADDR(7 downto 0)) - unsigned(IP_MIN)) & "01");
			end if;
		elsif(SEARCH_STATE = 1) and(ADDRA_PLUS(9) = '0') then
			-- scan all 128 positions
			ADDRA <= ADDRA_PLUS;
			ADDRB <= std_logic_vector(unsigned(ADDRB) + 2);
		end if;
	end if;
end process;
 
-- important for better timing. Aligned with ADDRA_D2
DHCP_CLIENT_ID_MATCH_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		ADDRA_D2 <= ADDRA_D;
		
		if(DOA(23 downto 0) = DHCP_CLIENT_ID_D(55 downto 32)) and (DOB = DHCP_CLIENT_ID_D(31 downto 0)) then
			DHCP_CLIENT_ID_MATCH <= '1';
		else
			DHCP_CLIENT_ID_MATCH <= '0';
		end if;
	end if;
end process;
	
SEARCH_STATE_MACHINE_002: process(CLK)
begin
	if rising_edge(CLK) then
		ADDRA_D <= ADDRA;	-- 1 CLK delay between ADDRA and DOA
		SEARCH_STATE_D <= SEARCH_STATE;
		SEARCH_COMPLETE_D <= SEARCH_COMPLETE;
		FOUND_CLIENT_ID_D <= FOUND_CLIENT_ID;
		
		if(SYNC_RESET = '1') or (SEARCH_STATE_D2 = 0) then
			FOUND_CLIENT_ID <= '0';
		elsif(SEARCH_STATE_D2 = 1) and (DHCP_CLIENT_ID_MATCH = '1') then
			-- found matching client ID. Aligned with ADDRA_D3
			FOUND_CLIENT_ID <= '1';
			FOUND_IP <= ADDRA_D2(9 downto 2);	-- to make up the real IP address, add IP_MIN and subnet address
		elsif(SEARCH_STATE = 0) and (STATE = 16) then
			-- DHCPREQUEST generated during RENEWING state. save pointer, we'll need it later to write the expiration date
			FOUND_IP <= std_logic_vector(unsigned(CIADDR(7 downto 0)) - unsigned(IP_MIN));
		end if; 
	end if;
end process; 

FOUND_IP_PLUSMIN <= std_logic_vector(unsigned(FOUND_IP) + unsigned(IP_MIN));

-- found IP address in table = DHCP requested IP address
IP_MATCH <= '1' when (FOUND_IP_PLUSMIN = DHCP_REQUESTED_IP_ADDR(7 downto 0)) and (IP_MATCH_MSB = '1') else '0';
	
-- pipelining for better timing of the above statement
IP_MATCH_MSB_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(DHCP_REQUESTED_IP_ADDR(31 downto 8) = IPv4_ADDR(31 downto 8)) then
			IP_MATCH_MSB <= '1';
		else
			IP_MATCH_MSB <= '0';
		end if;
	end if;
end process; 
	

-- find the oldest expired entry
SEARCH_STATE_MACHINE_003: process(CLK)
begin
	if rising_edge(CLK) then
		SEARCH_STATE_D2 <= SEARCH_STATE_D;
		
		if(SEARCH_STATE_D = 1) and (unsigned(ADDRA_D(9 downto 2)) = 0) then	-- *062516
			-- first result in the search is the 'oldest' until older ones are found subsequently
			FOUND_OLDEST_EXPIRATION_TIME <= DOA;
			FOUND_OLDEST_IP <= ADDRA_D(9 downto 2);	-- to make up the real IP address, add IP_MIN and subnet address
		elsif(SEARCH_STATE_D = 1) and (ADDRA_D(1) = '1') and 
		(FOUND_OLDEST_EXPIRATION_TIME(31 downto 30) = "00") and (DOA(31 downto 30) = "11") then
			-- found new oldest
			FOUND_OLDEST_EXPIRATION_TIME <= DOA;
			FOUND_OLDEST_IP <= ADDRA_D(9 downto 2);	-- to make up the real IP address, add IP_MIN and subnet address
		elsif(SEARCH_STATE_D = 1) and (ADDRA_D(1) = '1') and (DOA < FOUND_OLDEST_EXPIRATION_TIME) then	
			FOUND_OLDEST_EXPIRATION_TIME <= DOA;
			FOUND_OLDEST_IP <= ADDRA_D(9 downto 2);	-- to make up the real IP address, add IP_MIN and subnet address
		end if;
	end if;
end process;

-- is oldest entry expired?
EXPIRATION_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		SEARCH_COMPLETE_D2 <= SEARCH_COMPLETE_D;

		if(SYNC_RESET = '1') or (SEARCH_STATE_D2 = 0) then
			EXPIRED_OLDEST_ENTRY <= '0';
		elsif	(FOUND_OLDEST_EXPIRATION_TIME(31 downto 30) = "11") and (TIME_CNTR(31 downto 30) = "00") then
			-- expired entry
			EXPIRED_OLDEST_ENTRY <= '1';
		elsif	(unsigned(FOUND_OLDEST_EXPIRATION_TIME) < TIME_CNTR)  then
			-- expired entry
			EXPIRED_OLDEST_ENTRY <= '1';
		end if;
	end if;
end process;


--//-- COMPOSE REPLY TO DHCP CLIENT --------------------------
-- WPTR is a word counter for the UDP tx payload
WPTR_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WPTR <= (others => '0');
		elsif(STATE = 3) or (STATE = 10) or (STATE = 26) then
			-- DHCPOFFER message
			-- DHCPACK message
			-- DHCPNAK message
			if(UDP_TX_CTS = '1') then
				WPTR <= WPTR + 1;
			end if;
		else
			WPTR <= (others => '0');
		end if;
		
	end if;
end process;

COMPOSE_TX: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			UDP_TX_DATA_VALID <= X"00";
			UDP_TX_SOF <= '0';
			UDP_TX_EOF <= '0';
		elsif(STATE = 3) and (UDP_TX_CTS = '1') then
			-- DHCPDISCOVER message
			-- UDP destination IP address, broadcast 
			DEST_IPv4_ADDR <= x"FFFFFFFF";
			DEST_MAC_ADDR <= CLIENT_MAC_ADDR;
			if(WPTR < 34) then
				UDP_TX_DATA_VALID <= x"FF";
			elsif(WPTR = 34) then
				UDP_TX_DATA_VALID <= x"C0";
			else
				UDP_TX_DATA_VALID <= x"00";
			end if;
			case WPTR is
				when "0000000" => 
					UDP_TX_DATA <= x"02010600" & XID4RESPONSE;
						-- op: BOOTREPLY
						-- hardware type: Ethernet
						-- hardware address length
						-- 00
						-- XID4RESPONSE
					UDP_TX_SOF <= '1';
				when "0000001" => 
					UDP_TX_DATA <= (others => '0');	
						-- 0000
						-- unicast flag
						-- reserved flags
						-- 00000000
					UDP_TX_SOF <= '0';
				when "0000010" => 
					UDP_TX_DATA <= PROPOSED_IP_ADDR & x"00000000";
						-- proposed IP address
				when "0000011" => 
					UDP_TX_DATA <= GIADDR & CLIENT_MAC_ADDR(47 downto 16);
						-- GIADDR
						-- client MAC address
				when "0000100" => 
					UDP_TX_DATA <= CLIENT_MAC_ADDR(15 downto 0) & x"000000000000";
						-- client MAC address
				when "0011101" => 
					UDP_TX_DATA(63 downto 32) <= (others => '0');
					UDP_TX_DATA(31 downto 0) <= MAGIC_COOKIE;
				when "0011110" => 
					UDP_TX_DATA <= x"3501023604" & IPv4_ADDR(31 downto 8);
						-- option DHCP message type (53)
						-- length
						-- DHCPOFFER
						-- option DHCP server identifier (54)
						-- length
						-- server IP address
				when "0011111" => 
					UDP_TX_DATA <= IPv4_ADDR(7 downto 0) & x"3304" & LEASE_TIME(31 downto 0) & x"01";
						-- server IP address
						-- option lease time (51)
						-- length
						-- lease time
						-- option subnet mask (01)
				when "0100000" => 
					UDP_TX_DATA <= x"04" & SUBNET_MASK & x"0304" & ROUTER(31 downto 24);
						-- length
						-- SUBNET_MASK
						-- option router (03)
						-- length
						-- ROUTER
				when "0100001" => 
					UDP_TX_DATA <= ROUTER(23 downto 0) & x"0604" & DNS(31 downto 8);
						-- ROUTER
						-- option DNS (06)
						-- length
						-- DNS
				when "0100010" => 
					UDP_TX_DATA <= DNS(7 downto 0) & x"FF000000000000";
						-- DNS
						-- option end (255)
					UDP_TX_EOF <= '1';
				when others => 
					UDP_TX_DATA <= (others => '0');	
					UDP_TX_SOF <= '0';
					UDP_TX_EOF <= '0';
			end case;

		elsif(STATE = 10) then
			-- DHCACK message
			DEST_IPv4_ADDR <= PROPOSED_IP_ADDR;
			DEST_MAC_ADDR <= CLIENT_MAC_ADDR;
			-- UDP destination IP address 
			if(WPTR < 34) then
				UDP_TX_DATA_VALID <= x"FF";
			elsif(WPTR = 34) then
				UDP_TX_DATA_VALID <= x"C0";
			else
				UDP_TX_DATA_VALID <= x"00";
			end if;
			case WPTR is
				when "0000000" => 
					UDP_TX_DATA <= x"02010600" & XID4RESPONSE;
						-- op: BOOTREPLY
						-- hardware type: Ethernet
						-- hardware address length
						-- 00
						-- XID4RESPONSE
					UDP_TX_SOF <= '1';
				when "0000001" => 
					UDP_TX_DATA <= (others => '0');	
						-- 0000
						-- unicast flag
						-- reserved flags
						-- 00000000
					UDP_TX_SOF <= '0';
				when "0000010" => 
					UDP_TX_DATA <= PROPOSED_IP_ADDR & x"00000000";
						-- proposed IP address
				when "0000011" => 
					UDP_TX_DATA <= GIADDR & CLIENT_MAC_ADDR(47 downto 16);
						-- GIADDR
						-- client MAC address
				when "0000100" => 
					UDP_TX_DATA <= CLIENT_MAC_ADDR(15 downto 0) & x"000000000000";
						-- client MAC address
				when "0011101" => 
					UDP_TX_DATA(63 downto 32) <= (others => '0');
					UDP_TX_DATA(31 downto 0) <= MAGIC_COOKIE;
				when "0011110" => 
					UDP_TX_DATA <= x"3501053604" & IPv4_ADDR(31 downto 8);
						-- option DHCP message type (53)
						-- length
						-- DHCPACK
						-- option DHCP server identifier (54)
						-- length
						-- server IP address
				when "0011111" => 
					UDP_TX_DATA <= IPv4_ADDR(7 downto 0) & x"3304" & LEASE_TIME(31 downto 0) & x"01";
						-- server IP address
						-- option lease time (51)
						-- length
						-- lease time
						-- option subnet mask (01)
				when "0100000" => 
					UDP_TX_DATA <= x"04" & SUBNET_MASK & x"0304" & ROUTER(31 downto 24);
						-- length
						-- SUBNET_MASK
						-- option router (03)
						-- length
						-- ROUTER
				when "0100001" => 
					UDP_TX_DATA <= ROUTER(23 downto 0) & x"0604" & DNS(31 downto 8);
						-- ROUTER
						-- option DNS (06)
						-- length
						-- DNS
				when "0100010" => 
					UDP_TX_DATA <= DNS(7 downto 0) & x"FF000000000000";
						-- DNS
						-- option end (255)
					UDP_TX_EOF <= '1';
				when others => 
					UDP_TX_DATA <= (others => '0');	
					UDP_TX_SOF <= '0';
					UDP_TX_EOF <= '0';
			end case;
		elsif(STATE = 26) then
			-- DHCNAK message
			DEST_IPv4_ADDR <= PROPOSED_IP_ADDR;
				-- UDP destination IP address 
			if(unsigned(GIADDR) = 0) then 
				-- client on same subnet as server. Broadcast DHCPNAK
				DEST_MAC_ADDR <= x"FFFFFFFFFFFF";
			else
				DEST_MAC_ADDR <= CLIENT_MAC_ADDR;
			end if;
			if(WPTR < 31) then
				UDP_TX_DATA_VALID <= x"FF";
			elsif(WPTR = 31) then
				UDP_TX_DATA_VALID <= x"C0";
			else
				UDP_TX_DATA_VALID <= x"00";
			end if;
			case WPTR is
				when "0000000" => 
					UDP_TX_DATA <= x"02010600" & XID4RESPONSE;
						-- op: BOOTREPLY
						-- hardware type: Ethernet
						-- hardware address length
						-- 00
						-- XID4RESPONSE
					UDP_TX_SOF <= '1';
				when "0000001" => 
					UDP_TX_DATA(63 downto 48) <= (others => '0');
					if(unsigned(GIADDR) /= 0) then
						-- client on a different subnet. set broadcast flag
						UDP_TX_DATA(47 downto 40) <= x"80";	-- broadcast flag
					else
						UDP_TX_DATA(47 downto 40) <= x"00";	-- unicast flag
					end if;
					UDP_TX_DATA(39 downto 0) <= (others => '0');
						-- 0000
						-- unicast/broadcast flag
						-- reserved flags
						-- 00000000
					UDP_TX_SOF <= '0';
				when "0000010" => 
					UDP_TX_DATA <= PROPOSED_IP_ADDR & x"00000000";
						-- proposed IP address
				when "0000011" => 
					UDP_TX_DATA <= GIADDR & CLIENT_MAC_ADDR(47 downto 16);
						-- GIADDR
						-- client MAC address
				when "0000100" => 
					UDP_TX_DATA <= CLIENT_MAC_ADDR(15 downto 0) & x"000000000000";
						-- client MAC address
				when "0011101" => 
					UDP_TX_DATA(63 downto 32) <= (others => '0');
					UDP_TX_DATA(31 downto 0) <= MAGIC_COOKIE;
				when "0011110" => 
					UDP_TX_DATA <= x"3501063604" & IPv4_ADDR(31 downto 8);
						-- option DHCP message type (53)
						-- length
						-- DHCPNAK
						-- option DHCP server identifier (54)
						-- length
						-- server IP address
				when "0011111" => 
					UDP_TX_DATA <= IPv4_ADDR(7 downto 0) & x"FF000000000000";
						-- server IP address
						-- option end (255)
				when others => 
					UDP_TX_DATA <= (others => '0');	
					UDP_TX_SOF <= '0';
					UDP_TX_EOF <= '0';
			end case;
		else
			UDP_TX_DATA_VALID <= X"00";
			UDP_TX_SOF <= '0';
			UDP_TX_EOF <= '0';
		end if;
	end if;
end process;

DEST_IPv4_ADDRx <= x"000000000000000000000000" & DEST_IPv4_ADDR;
UDP_TX_001: UDP_TX_10G 
GENERIC MAP(
	ADDR_WIDTH => 7,  -- elastic buffer size as 72b * 2^ADDR_WIDTH
	UDP_CKSUM_ENABLED => '1',
	IPv6_ENABLED => '0'
)
PORT MAP(
	CLK => CLK,
	SYNC_RESET => SYNC_RESET,
	TICK_4US => TICK_4US,
	-- Application interface
	APP_DATA => UDP_TX_DATA,
	APP_DATA_VALID => UDP_TX_DATA_VALID,
	APP_SOF => UDP_TX_SOF,
	APP_EOF => UDP_TX_EOF,
	APP_CTS => UDP_TX_CTS,
	ACK => UDP_TX_ACK_local,
	NAK => UDP_TX_NAK_local,
	DEST_IP_ADDR => DEST_IPv4_ADDRx,	
	IPv4_6n => '1',
	DEST_PORT_NO => x"0044",	-- DHCP client port (68)
	SOURCE_PORT_NO => x"0043",	-- DHCP server port (67)
	-- Configuration
	MAC_ADDR => MAC_ADDR,
	IPv4_ADDR => IPv4_ADDR,
	IPv6_ADDR => (others => '0'),
	IP_ID => std_logic_vector(IP_ID_IN),	
	-- Routing
	RT_IP_ADDR => open,
	RT_IPv4_6n => open,
	RT_REQ_RTS => open,
	RT_REQ_CTS => '1',
	RT_MAC_REPLY => DEST_MAC_ADDR,
	RT_MAC_RDY => '1',
	RT_NAK => '0',
	-- MAC interface
	MAC_TX_DATA => MAC_TX_DATA,
	MAC_TX_DATA_VALID => MAC_TX_DATA_VALID,
	MAC_TX_EOF => MAC_TX_EOF_local,
	MAC_TX_CTS => MAC_TX_CTS,
	RTS => RTS,
	TP => open
);
MAC_TX_EOF <= MAC_TX_EOF_local;

---- DHCP message check
---- source IP is 0.0.0.0.
----		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0); 
---- DHCP source port is 68
---- Destination IP is 255.x.x.x
--
----// CHECK DHCP VALIDITY -----------------------------
---- validate DHCL rx frame
---- (a) received frame is a valid UDP frame
---- (b) source IP address is 0.0.0.0.
---- (c) received port is 67
---- (d) source port is 68
--
--
--
----// TEST POINTS -----------------------------
----TP(1) <= DHCP_RX_DATA_VALID;
----TP(2) <= EVENT1;
----TP(3) <= EVENT2A;
----TP(4) <= EVENT2B;
----TP(5) <= EVENT2C;
----TP(6) <= EVENT2D;
----TP(7) <= UDP_TX_CTS; 
----TP(8) <= '1' when (STATE = 3) and (UDP_TX_CTS = '1')  else '0';
----TP(9) <= MAC_TX_EOF_local;
--
--N_DHCPDISCOVER_OUT <= N_DHCPDISCOVER;
--N_DHCPREQUEST1_OUT <= N_DHCPREQUEST1;
--N_DHCPREQUEST2_OUT <= N_DHCPREQUEST2;
--N_DHCPREQUEST3_OUT <= N_DHCPREQUEST3;
--N_DHCPACK_OUT <= N_DHCPACK;
--
end Behavioral;
