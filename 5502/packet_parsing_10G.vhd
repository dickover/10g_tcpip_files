-------------------------------------------------------------
-- MSS copyright 2003-2020
--	Filename:  PACKET_PARSING_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 2
--	Date last modified: 9/24/20
-- Inheritance: 	COM-5402 PACKET_PARSING.VHD rev 8 12/10/15
--
-- description: Common code. This component parses the received packets from the MAC
-- and extracts key information shared by all protocols.  
-- Reads receive packet structure on the fly and detect the following
-- (a) encapsulation: ethernet (RFC 894) or 802.2/802.3 (RFC 1042)
-- (b) type: 0800 IP datagram, 0806 ARP request/reply, 8035 RARP request/reply
-- (c) IP address match
-- (d) IP port match
-- (e) IP protocol detected: ICMP, UDP, TCP-IP
-- (f) IP checksum verification
-- (g) UDP checksum verification
-- It also saves the source IP/source LAN address on the fly to avoid doing ARPs
-- This module includes all checks which could be performed in multiple protocol modules.
-- The goal is to share these checks to save implementation gates.
-- Each protocol layer is associated with one CLK latency. 
--
-- Limitations: 802.3/802.2 encapsulation is only detected, not supported for any protocol.
--
-- Rev1 4/30/19 AZ
-- Added IP payload checksum computation
-- Added IPv4 broadcast address check (needed for DHCP)
-- 
-- Rev 2 6/7/19 AZ
-- corrected bug clearing IPv4_PROTOCOL too early in very small frame and adjacent frames (no gap)
--
-- Device utilization (IPv6_ENABLED='1')
-- FF: 850
-- LUT: 1468
-- DSP48: 0
-- 18Kb BRAM: 0
-- BUFG: 1
-- Minimum period: 6.586ns (Maximum Frequency: 151.837MHz)  Artix7-100T -1 speed grade
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity PACKET_PARSING_10G is
	generic (
		IPv6_ENABLED: std_logic := '1';
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		SIMULATION: std_logic := '0'
			-- 1 during simulation with Wireshark .cap file, '0' otherwise
			-- Wireshark many not be able to collect offloaded checksum computations.
			-- when SIMULATION =  '1': 
			-- (a) IP header checksum is valid if 0000,
			-- (b) TCP checksum computation is forced to a valid 00001 irrespective of the 16-bit checksum
			-- captured by Wireshark.
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
		SYNC_RESET: in std_logic;

		--// RECEIVED MAC FRAME ---------------------------------------------
		MAC_RX_DATA: in std_logic_vector(63 downto 0);
			-- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID /= 0
			-- Bytes order: MSB was received first
			-- Bytes are left aligned: first byte in MSB, occasional follow-on fill-in Bytes in the LSB(s)
			-- The first destination address byte is always a MSB (MAC_RX_DATA(7:0))
		MAC_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		MAC_RX_SOF: in std_logic;
			-- Start of Frame: one CLK-wide pulse indicating the first word in the received frame
			-- aligned with MAC_RX_DATA_VALID.
		MAC_RX_EOF: in std_logic;
			-- End of Frame: one CLK-wide pulse indicating the last word in the received frame
			-- aligned with MAC_RX_DATA_VALID.
		MAC_RX_FRAME_VALID: in std_logic;
            -- MAC frame integrity verification (at the end of frame)
		MAC_RX_WORD_COUNT: out std_logic_vector(10 downto 0);
			-- MAC word counter, 1 CLK after the input. 0 is the first word.

		--// local IP address
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
		IPv4_MULTICAST_ADDR: in std_logic_vector(31 downto 0); 
		    -- to receive UDP multicast messages. One multicast address only
            -- 0.0.0.0 to signify that IP multicasting is not supported here.

		--// RECEIVED IP FRAME  --------------------------------------------
		-- Excludes MAC layer header. Includes IP header.
		IP_RX_DATA: out std_logic_vector(63 downto 0);
		IP_RX_DATA_VALID: out std_logic_vector(7 downto 0);
		IP_RX_SOF: out std_logic;
		IP_RX_EOF: out std_logic;
		IP_RX_WORD_COUNT: out std_logic_vector(10 downto 0);	
		IP_HEADER_FLAG: out std_logic_vector(1 downto 0);
		  -- bit 1 is for the upper 32-bit
		  -- bit 0 lower 32-bit

		--// Received type
		RX_TYPE: out std_logic_vector(3 downto 0);
			-- Information stays until start of following packet.
			-- 0 = unknown type
			-- 1 = Ethernet encapsulation, IPv4 datagram
			-- 2 = Ethernet encapsulation, ARP request/reply
			-- 3 = Ethernet encapsulation, RARP request/reply
			-- 5 = Ethernet encapsulation, IPv6 datagram
			-- 9 = IEEE 802.3/802.2  encapsulation, IPv4 datagram (almost never used)
			-- 10 = IEEE 802.3/802.2  encapsulation, ARP request/reply (almost never used)
			-- 11 = IEEE 802.3/802.2  encapsulation, RARP request/reply (almost never used)
			-- 13 = IEEE 802.3/802.2  encapsulation, IPv6 datagram (almost never used)
	  	RX_TYPE_RDY: out std_logic;
			-- 1 CLK-wide pulse indicating that a detection was made on the received packet
			-- type, and that RX_TYPE can be read.
			-- Detection occurs as soon as possible, two clocks after receiving byte 13 or 21.

		--// IP type: 
		RX_IPv4_6n: out std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: out std_logic_vector(7 downto 0);
			-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
			-- most common protocols: 
			-- 0 = unknown, 1 = ICMP, 2 = IGMP, 6 = TCP, 17 = UDP, 41 = IPv6 encapsulation, 
			-- 58 = ICMPv6, 89 = OSPF, 132 = SCTP
	  	RX_IP_PROTOCOL_RDY: out std_logic;
			-- 1 CLK wide pulse. 
        
		--// basic IP validity check
		IP_RX_FRAME_VALID: out std_logic; 
		IP_RX_FRAME_VALID2: out std_logic;
			-- The received IP frame is presumed valid until proven otherwise. 
			-- IP frame validity checks include: 
			-- (a) protocol is IP
			-- (b) unicast or multicast destination IP address matches
			-- (c) correct IP header checksum (IPv4 only)
			-- (d) allowed IPv6
			-- (e) Ethernet frame is valid (correct FCS, dest address)
			-- Also compute IP_RX_FRAME_VALID2 (no IP destination check)
			-- Ready at IP_RX_EOF_D2

		--// Destination IP check for IP datagram
		-- IP is checked only for IP datagrams (RX_TYPE 1,5)
		-- Check is against unicast or multicast IP address IPv4_ADDR, IPv6_ADDR, or IPv4_MULTICAST_ADDR
		VALID_UNICAST_DEST_IP: out std_logic;
		VALID_MULTICAST_DEST_IP: out std_logic;
			-- 1 = valid , 0 = invalid. Read when VALID_DEST_IP_RDY = '1'
			-- IPv4: checks match against IPv4_MULTICAST_ADDR and IP broadcast (full or subnet) address
			-- IPv6: checks match against solicited-node multicast IP FF02....+lower 24-bit of unicast IP
		VALID_DEST_IP_RDY : out std_logic;
			-- 1 CLK wide pulse. 

		--// IP header checksum verification
		IP_HEADER_CHECKSUM_VALID: out std_logic;
		IP_HEADER_CHECKSUM_VALID_RDY: out std_logic;
		
		--// Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_MAC_ADDR: out std_logic_vector(47 downto 0);	-- all received packets
		RX_SOURCE_IP_ADDR: out std_logic_vector(127 downto 0);  	-- IPv4,IPv6,ARP
		RX_DEST_IP_ADDR: out std_logic_vector(127 downto 0);  	
			
		--// RECEIVED IP PAYLOAD   ---------------------------------------------
		IP_PAYLOAD_DATA: out std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: out std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: out std_logic;
		IP_PAYLOAD_EOF: out std_logic;
		IP_PAYLOAD_LENGTH: out std_logic_vector(15 downto 0);
			-- payload length in bytes (i.e. excluding MAC and IP headers) 
		IP_PAYLOAD_WORD_COUNT: out std_logic_vector(10 downto 0);    
			-- 2 CLKs latency w.r.t. IP_RX_DATA
		VALID_IP_PAYLOAD_CHECKSUM: out std_logic;
			-- '1' when valid IP payload checksum. Read at IP_RX_EOF_D2 or IP_PAYLOAD_EOF_D
			-- verified only for IGMP messages
			
		--// UDP attributes
		VALID_UDP_CHECKSUM: out std_logic;
			-- '1' when valid UDP checksum(including pseudo-header). Read at IP_RX_EOF_D2 or IP_PAYLOAD_EOF_D
			-- verified only for UDP messages

		--// TCP attributes
		VALID_TCP_CHECKSUM: out std_logic;
			-- '1' when valid TCP checksum(including pseudo-header). Read at IP_RX_EOF_D2 or IP_PAYLOAD_EOF_D
			-- verified only for TCP messages
		
		--// TEST POINTS, COMSCOPE TRACES
		CS1: out std_logic_vector(7 downto 0);
		CS1_CLK: out std_logic;
		CS2: out std_logic_vector(7 downto 0);
		CS2_CLK: out std_logic;
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of PACKET_PARSING_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- NOTATIONS: 
-- _E as one-CLK early sample
-- _D as one-CLK delayed sample
-- _D2 as two-CLKs delayed sample

--// WORD COUNT ----------------------
signal MAC_RX_DATA_VALID_D: std_logic_vector(7 downto 0):= (others => '0');
signal MAC_RX_WORD_VALID_D: std_logic := '0';
signal MAC_RX_SOF_D: std_logic := '0';
signal MAC_RX_EOF_D: std_logic := '0';
signal MAC_RX_DATA_D: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_RX_WORD_COUNT_local: unsigned(10 downto 0):= (others => '0');

--// TYPE ---------------------------------
signal RX_TYPE_FIELD_D: std_logic_vector(15 downto 0) := (others => '0');
signal RX_TYPE_local: unsigned(3 downto 0) := x"0";
signal RX_TYPE_RDY_local: std_logic := '0';

--// SOURCE MAC ADDRESS ------------------------------------
signal RX_SOURCE_MAC_ADDR_local: std_logic_vector(47 downto 0) := (others => '0');

--// IP DATA -------------------------------------
signal MAC_RX_SOF_D2: std_logic := '0';
signal IP_RX_DATA_CACHE: std_logic_vector(63 downto 48) := (others => '0');
signal IP_RX_DATA_CACHE_VALID: std_logic_vector(7 downto 6) := (others => '0');
signal IP_RX_DATA0: std_logic_vector(63 downto 0) := (others => '0');
signal IP_RX_DATA_local: std_logic_vector(63 downto 0) := (others => '0');
signal IP_RX_WORD_VALID_local: std_logic := '0';
signal IP_RX_SOF_local: std_logic := '0';
signal IP_RX_EOF0: std_logic := '0';
signal IP_RX_EOF_local: std_logic := '0';
signal IP_RX_EOF_D: std_logic := '0';

signal IP_RX_WORD_COUNT_local: unsigned(10 downto 0):= (others => '0');
signal IP_RX_FLUSH_CACHE: std_logic := '0';
signal IP_RX_DATA_VALID0: std_logic_vector(7 downto 0) := (others => '0');
signal IP_RX_DATA_VALID_local: std_logic_vector(7 downto 0) := (others => '0');
signal IP_RX_MASK_ETH_PADS: std_logic_vector(7 downto 0) := (others => '0');

--// IP PROTOCOL ----------------------
signal RX_IPv4_6n_local: std_logic := '1';
signal RX_IP_PROTOCOL_local: std_logic_vector(7 downto 0) := x"00";
signal IPv4_PROTOCOL: std_logic_vector(7 downto 0) := x"00";
signal IPv4_PROTOCOL_RDY: std_logic := '0';
signal IPv6_PROTOCOL: std_logic_vector(7 downto 0) := x"00";
signal IPv6_PROTOCOL_RDY: std_logic := '0';

--// IPv6 HEADER PARSING ---------------------------------------
signal IPv6_HEADER_FLAG: std_logic := '0';
signal IPv6_HEADER_WORD_CNTR: unsigned(7 downto 0):= (others => '0');
signal IPv6_NEXT_HEADER: std_logic_vector(7 downto 0) := (others => '0');
signal IP_HEADER_FLAG_local: std_logic_vector(1 downto 0) := (others => '0');

--// IPv4 HEADER PARSING ---------------------------------------
signal IPv4_HEADER_N32bWORDS: unsigned(3 downto 0) := (others => '0');	-- expressed in 32-bit words. read/use at MAC_RX_DATA_VALID_D3
signal IPv4_HEADER_N32bWORDS_D: unsigned(3 downto 0) := (others => '0');	-- expressed in 32-bit words. read/use at MAC_RX_DATA_VALID_D3
signal IPv4_HEADER_N32bWORDS_DEC: unsigned(3 downto 0) := (others => '0');
signal IPv4_HEADER_MASK_A: std_logic_vector(1 downto 0) := (others => '0');
signal IPv4_HEADER_MASK: std_logic_vector(1 downto 0) := (others => '0');
signal IPv4_HEADER_MASK_D: std_logic_vector(1 downto 0) := (others => '0');
--signal IPv4_HEADER_DATA: std_logic_vector(63 downto 0) := (others => '0');
signal IPv4_RX_EOH: std_logic := '0';
signal IPv4_RX_EOH_D: std_logic := '0';
signal IP_TOTAL_LENGTH_DEC: unsigned(15 downto 0) := (others => '0');

----// IP BYTE COUNT ----------------------
--signal MAC_RX_EOF_D2: std_logic := '0';
--signal MAC_RX_DATA_D2: std_logic_vector(7 downto 0) := x"00";
--signal IP_FRAME_FLAG: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D2
--signal IP_HEADER_FLAG_E: std_logic := '0';							
--signal IP_FRAME_FLAG_E: std_logic := '0';						
--signal IP_RX_EOF_E: std_logic := '0';



--// VALIDATE IP ADDRESS ----------------------
signal VALID_UNICAST_DEST_IP_local: std_logic := '0';
signal VALID_UNICAST_DEST_IP_MSBS: std_logic := '0';
signal VALID_MULTICAST_DEST_IP_local: std_logic := '0';
signal VALID_MULTICAST_DEST_IP_MSBS: std_logic := '0';
signal VALID_DEST_IP_RDY_local: std_logic := '0';
signal IP_ADDR_local: std_logic_vector(127 downto 0) := x"00000000000000000000000000000000";

--// VALIDATE IP HEADER CHECKSUM ----------------------
signal IP_RX_DATA_SUM_MSW: unsigned(17 downto 0) := (others => '0');
signal IP_RX_DATA_SUM_LSW: unsigned(17 downto 0) := (others => '0');
signal TYPE_FIELD_D2: std_logic_vector(15 downto 0) := (others => '0');
signal HCKSUM1: unsigned(17 downto 0)  := (others => '0');
signal HCKSUM2: unsigned(17 downto 0)  := (others => '0');
signal HCKSUM3: unsigned(5 downto 0)  := (others => '0');
signal HCKSUM3_PLUS: unsigned(5 downto 0)  := (others => '0');
signal IP_HEADER_CHECKSUM_FINAL: unsigned(17 downto 0)  := (others => '0');
signal IP_HEADER_CHECKSUM: unsigned(17 downto 0) := (others => '0');	-- 16-bit sum + carry
signal IP_HEADER_CHECKSUM_VALID_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D3
signal IP_HEADER_CHECKSUM_VALID_RDY_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D3

--// IP LENGTH ----------------------
signal IP_PAYLOAD_LENGTH_local: unsigned(15 downto 0) := x"0000";	-- IP payload length in bytes
signal IP_PAYLOAD_LENGTH_RDY: std_logic := '0';

--// SOURCE & DESTINATION IP ADDRESS -------------------------
signal RX_SOURCE_IP_ADDR_local: std_logic_vector(127 downto 0) := (others => '0');
signal RX_DEST_IP_ADDR_local: std_logic_vector(127 downto 0) := (others => '0');

--// CHECK IP VALIDITY ----------------------
signal IP_RX_FRAME_VALID_local: std_logic := '0';
signal IP_RX_FRAME_VALID2_local: std_logic := '0';
signal IP_RX_FRAME_VALID3_local: std_logic := '0';

--// IP PAYLOAD   ---------------------------------------------
signal IP_PAYLOAD_DATA_LS32b_D: std_logic_vector(31 downto 0) := (others => '0');
signal IP_PAYLOAD_DATA_VALID_LSB32b_D: std_logic_vector(3 downto 0) := (others => '0');
signal IP_PAYLOAD_DATA_VALID0: std_logic_vector(7 downto 0) := (others => '0');
signal IP_PAYLOAD_WORD_COUNT_local: unsigned(10 downto 0) := (others => '0');
signal IP_PAYLOAD_SOF0: std_logic := '0';
signal IP_PAYLOAD_EOF_local: std_logic := '0';
signal IP_PAYLOAD_EOF_D: std_logic := '0';

--//--- UDP LAYER ---------------------------------
signal UDPv4_CKSUM_NULL: std_logic := '0';
signal CKSUM1: unsigned(17 downto 0):= (others => '0');
signal CKSUM2: unsigned(17 downto 0):= (others => '0');
signal CKSUM3: unsigned(17 downto 0):= (others => '0');
signal CKSUM3PLUS: unsigned(17 downto 0):= (others => '0');
signal RX_UDP_CKSUM_local: unsigned(17 downto 0):= (others => '0');
signal VALID_UDP_CHECKSUM0: std_logic := '0';
signal VALID_UDP_CHECKSUM1: std_logic := '0';
signal VALID_UDP_CHECKSUM_local: std_logic := '0';

------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

---------------------------------------------------
---- PACKET LAYER ---------------------------------
---------------------------------------------------

--// PACKET WORD COUNT ----------------------
-- Most packet processing is performed with a 1CLK latency (processes MAC_RX_DATA_D and MAC_RX_DATA_VALID_D)
-- count received bytes for each incoming packet. 0 is the first word.
MAC_RX_WORD_COUNT_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_RX_WORD_COUNT_local <= (others => '0');
			MAC_RX_DATA_D <= (others => '0');
			MAC_RX_DATA_VALID_D <= (others => '0');
			MAC_RX_WORD_VALID_D <= '0';
			MAC_RX_SOF_D <= '0';
			MAC_RX_EOF_D <= '0';
		else
			-- reclock data and sample clock so that they are aligned with the byte count.
			-- Also blank data bytes not marked as valid  *063018
			for I in 0 to 7 loop
				if(MAC_RX_DATA_VALID(I) = '1') then
					MAC_RX_DATA_D(8*I+7 downto 8*I) <= MAC_RX_DATA(8*I+7 downto 8*I);
				else
					MAC_RX_DATA_D(8*I+7 downto 8*I) <= (others => '0');
				end if;
			end loop;
			--MAC_RX_DATA_D <= MAC_RX_DATA;
			MAC_RX_DATA_VALID_D <= MAC_RX_DATA_VALID;
			MAC_RX_SOF_D <= MAC_RX_SOF;
			MAC_RX_EOF_D <= MAC_RX_EOF;

			if(MAC_RX_SOF = '1') then
				-- just received first byte. 
				MAC_RX_WORD_COUNT_local <= (others => '0');
			elsif(unsigned(MAC_RX_DATA_VALID) /= 0) then
				MAC_RX_WORD_COUNT_local <= MAC_RX_WORD_COUNT_local + 1;
			end if;
			
			if(unsigned(MAC_RX_DATA_VALID) /= 0) then
				MAC_RX_WORD_VALID_D <= '1';
			else
				MAC_RX_WORD_VALID_D <= '0';
			end if;
		end if;
	end if;
end process;
MAC_RX_WORD_COUNT <= std_logic_vector(MAC_RX_WORD_COUNT_local);

--// PACKET TYPE ---------------------------------
-- type detection at word 6 (Ethernet encapsulation, RFC 894)
-- OR at word 10 (802.3)
RX_TYPE_FIELD_D <= MAC_RX_DATA_D(31 downto 16);
DETECT_TYPE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_TYPE_local <= x"0";	-- unknown type
			RX_TYPE_RDY_local <= '0';
		elsif(MAC_RX_SOF_D = '1') then
			-- clear type to unknown
			RX_TYPE_local <= x"0";	-- unknown type
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 1) and (RX_TYPE_local= 0) then
			-- Ethernet encapsulation, RFC 894
			if(RX_TYPE_FIELD_D = x"0800") then
				-- IPv4 datagram
				RX_TYPE_local <= x"1";
				RX_TYPE_RDY_local <= '1';
			elsif(RX_TYPE_FIELD_D = x"0806") then
				-- ARP request/reply
				RX_TYPE_local <= x"2";
				RX_TYPE_RDY_local <= '1';
			elsif(RX_TYPE_FIELD_D = x"8035") then
                -- RARP request/reply
                RX_TYPE_local <= x"3";
                RX_TYPE_RDY_local <= '1';
            elsif(RX_TYPE_FIELD_D = x"86DD") then
 				-- IPv6 datagram
                RX_TYPE_local <= x"5";
                RX_TYPE_RDY_local <= '1';
			else
				RX_TYPE_RDY_local <= '0';
		  	end if;
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 2) and (RX_TYPE_local = 0) then
			-- IEEE 802.3/802.2 encapsulation, RFC 1042
			if(RX_TYPE_FIELD_D = x"0800") then
				-- IP datagram
				RX_TYPE_local <= x"9";
				RX_TYPE_RDY_local <= '1';
			elsif(RX_TYPE_FIELD_D = x"0806") then
				-- ARP request/reply
				RX_TYPE_local <= x"A";
				RX_TYPE_RDY_local <= '1';
			elsif(RX_TYPE_FIELD_D = x"8035") then
				-- RARP request/reply
				RX_TYPE_local <= x"B";
				RX_TYPE_RDY_local <= '1';
            elsif(RX_TYPE_FIELD_D = x"86DD") then
                 -- IPv6 datagram
                RX_TYPE_local <= x"D";
                RX_TYPE_RDY_local <= '1';
			else
				-- still unrecognized type after second word, declare unknown type
				RX_TYPE_RDY_local <= '1';
		  	end if;
		else
			RX_TYPE_RDY_local <= '0';
		end if;
	end if;
end process;
RX_TYPE <= std_logic_vector(RX_TYPE_local);
RX_TYPE_RDY <= RX_TYPE_RDY_local;

--// SOURCE MAC ADDRESS ------------------------------------
CAPTURE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_SOURCE_MAC_ADDR_local <= (others => '0');
		elsif(MAC_RX_SOF_D = '1') and (MAC_RX_DATA_VALID_D(1 downto 0) = "11") then
			RX_SOURCE_MAC_ADDR_local(47 downto 32) <= MAC_RX_DATA_D(15 downto 0);
		elsif (MAC_RX_WORD_COUNT_local = 1) and (MAC_RX_DATA_VALID_D(7 downto 4) = "1111") then
			RX_SOURCE_MAC_ADDR_local(31 downto 0) <= MAC_RX_DATA_D(63 downto 32);
		end if;
	end if;
end process;
RX_SOURCE_MAC_ADDR <= RX_SOURCE_MAC_ADDR_local;

--// IP DATA -------------------------------------
-- Parse the IP frame, (discard the Ethernet header), starting at the version number 
-- Most packet processing is performed with a 2CLK latency w.r.t. the input
-- Keep track of the number of IP words (first is 1), even during Ethernet short frame padding.
-- Note: IP_RX_DATA0 will be masked by IP_RX_DATA_VALID_local further down
RX_IP_FRAME_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		MAC_RX_SOF_D2 <= MAC_RX_SOF_D;
		
		if(SYNC_RESET = '1') then
			IP_RX_DATA_CACHE <= (others => '0');
			IP_RX_DATA_CACHE_VALID <= (others => '0');
			IP_RX_DATA0 <= (others => '0');
			IP_RX_WORD_COUNT_local <= (others => '0');
			IP_RX_FLUSH_CACHE <= '0';
		elsif(MAC_RX_SOF_D = '1') then
			if(IP_RX_FLUSH_CACHE = '1') then	
				-- special case when EOF is followed immediately by SOF
				IP_RX_DATA0(63 downto 48)  <= IP_RX_DATA_CACHE(63 downto 48);
				IP_RX_DATA0(47 downto 0)  <= (others => '0');
				IP_RX_WORD_COUNT_local <= IP_RX_WORD_COUNT_local + 1;
				IP_RX_DATA_CACHE_VALID(7 downto 6) <= "00";
				IP_RX_FLUSH_CACHE <= '0';
			end if;
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 1) and (RX_TYPE_local= 0) then
			-- Ethernet encapsulation, RFC 894
			IP_RX_DATA_CACHE(63 downto 48) <= MAC_RX_DATA_D(15 downto 0);
			IP_RX_DATA_CACHE_VALID(7 downto 6) <= MAC_RX_DATA_VALID_D(1 downto 0);
			IP_RX_WORD_COUNT_local <= (others => '0');
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 2) and (RX_TYPE_local = 0) then
			-- IEEE 802.3/802.2 encapsulation, RFC 1042
			IP_RX_DATA_CACHE(63 downto 48) <= MAC_RX_DATA_D(15 downto 0);
			IP_RX_DATA_CACHE_VALID(7 downto 6) <= MAC_RX_DATA_VALID_D(1 downto 0);
			IP_RX_WORD_COUNT_local <= (others => '0');
		elsif(MAC_RX_WORD_VALID_D = '1') then
			IP_RX_DATA0(63 downto 48)  <= IP_RX_DATA_CACHE(63 downto 48);
			IP_RX_DATA0(47 downto 0)  <= MAC_RX_DATA_D(63 downto 16);
			IP_RX_DATA_CACHE(63 downto 48) <= MAC_RX_DATA_D(15 downto 0);
			IP_RX_DATA_CACHE_VALID(7 downto 6) <= MAC_RX_DATA_VALID_D(1 downto 0);
			IP_RX_WORD_COUNT_local <= IP_RX_WORD_COUNT_local + 1;
			if(MAC_RX_DATA_VALID_D(1 downto 0) /= "00") then
				IP_RX_FLUSH_CACHE <= MAC_RX_EOF_D;	-- maybe last (full) word, or not the last word.
			end if;
		elsif(IP_RX_FLUSH_CACHE = '1') then	
			IP_RX_DATA0(63 downto 48)  <= IP_RX_DATA_CACHE(63 downto 48);
			IP_RX_DATA0(47 downto 0)  <= (others => '0');
			IP_RX_WORD_COUNT_local <= IP_RX_WORD_COUNT_local + 1;
			IP_RX_DATA_CACHE_VALID(7 downto 6) <= "00";
			IP_RX_FLUSH_CACHE <= '0';
		end if;
	end if;
end process;
IP_RX_WORD_COUNT <= std_logic_vector(IP_RX_WORD_COUNT_local);

-- reconstruct IP_RX_SOF for the IP frame
RX_IP_FRAME_GEN_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_RX_SOF_D = '1') then
			IP_RX_SOF_local <= '0';
		elsif (MAC_RX_WORD_VALID_D = '1') and (MAC_RX_WORD_COUNT_local = 2) and ((RX_TYPE_local = 1) or  (RX_TYPE_local = 5)) then
			-- Ethernet encapsulation, RFC 894
			IP_RX_SOF_local <= '1';
		elsif (MAC_RX_WORD_VALID_D = '1') and (MAC_RX_WORD_COUNT_local = 3) and ((RX_TYPE_local = 9) or  (RX_TYPE_local = 13)) then
			-- IEEE 802.3/802.2 encapsulation, RFC 1042
			IP_RX_SOF_local <= '1';
		else
			IP_RX_SOF_local <= '0';
		end if;
	end if;
end process;

-- reconstruct the IP_RX_DATA_VALID for the IP frame
RX_IP_FRAME_GEN_003: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			IP_RX_DATA_VALID0 <= (others => '0');
		elsif(MAC_RX_SOF_D = '1') then
			if(IP_RX_FLUSH_CACHE = '1') then	
				-- special case when EOF is followed immediately by SOF
				IP_RX_DATA_VALID0 <= IP_RX_DATA_CACHE_VALID(7 downto 6) & "000000";
			else
				IP_RX_DATA_VALID0 <= (others => '0');
			end if;
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 1) and (RX_TYPE_local= 0) then
			-- Ethernet encapsulation, RFC 894
			IP_RX_DATA_VALID0 <= (others => '0');
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 2) and (RX_TYPE_local = 0) then
			-- IEEE 802.3/802.2 encapsulation, RFC 1042
			IP_RX_DATA_VALID0 <= (others => '0');
		elsif(IP_TOTAL_LENGTH_DEC(15 downto 14) = "00") and (IP_TOTAL_LENGTH_DEC(13 downto 3) < IP_RX_WORD_COUNT_local) then
			-- Ethernet frame may be padded to meet the minimum 46 Byte (IPv4) or 26 Byte (IPv6) payload length. 
			-- Discard the padding here based on the IP total length
			IP_RX_DATA_VALID0 <= (others => '0');
		elsif(MAC_RX_WORD_VALID_D = '1') then
			IP_RX_DATA_VALID0 <= IP_RX_DATA_CACHE_VALID(7 downto 6) & MAC_RX_DATA_VALID_D(7 downto 2);
		elsif(IP_RX_FLUSH_CACHE = '1') then	
			IP_RX_DATA_VALID0 <= IP_RX_DATA_CACHE_VALID(7 downto 6) & "000000";
		else
			IP_RX_DATA_VALID0 <= (others => '0');
		end if;
	end if;
end process;
IP_RX_DATA_VALID_local <= IP_RX_DATA_VALID0 and IP_RX_MASK_ETH_PADS when (IP_RX_FRAME_VALID3_local = '1') else x"00";	
	-- mask Ethernet pads when short frame. Mask if not an IP frame.
IP_RX_WORD_VALID_local <= '0' when (IP_RX_DATA_VALID_local = x"00") else '1';

-- zero (mask) IP_RX_DATA bytes based on IP_RX_DATA_VALID_local
RX_IP_FRAME_GEN_004: process(IP_RX_DATA0, IP_RX_DATA_VALID_local)
begin	
	for I in 0 to 7 loop
		if(IP_RX_DATA_VALID_local(I) = '1') then
			IP_RX_DATA_local(8*I+7 downto 8*I) <= IP_RX_DATA0(8*I+7 downto 8*I);
		else
			IP_RX_DATA_local(8*I+7 downto 8*I) <= (others => '0');
		end if;
	end loop;
end process;

-- reconstruct the IP_RX_EOF for the IP frame
-- TODO: EOF MAY ARRIVE EARLIER IN THE CASE OF SHORT (<60BYTES) ETHERNET FRAMES
RX_IP_FRAME_GEN_005: process(CLK)
begin
	if rising_edge(CLK) then
	    IP_RX_EOF_D <= IP_RX_EOF_local;
	    
		if(SYNC_RESET = '1') then
			IP_RX_EOF0 <= '0';
		elsif(MAC_RX_SOF_D = '1') then
			if(IP_RX_FLUSH_CACHE = '1') then	
				-- special case when EOF is followed immediately by SOF
				IP_RX_EOF0 <= '1';
			else
				IP_RX_EOF0 <= '0';
			end if;
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 1) and (RX_TYPE_local= 0) then
			-- Ethernet encapsulation, RFC 894
			IP_RX_EOF0 <= '0';
		elsif(MAC_RX_DATA_VALID_D(3 downto 2) = "11") and (MAC_RX_WORD_COUNT_local = 2) and (RX_TYPE_local = 0) then
			-- IEEE 802.3/802.2 encapsulation, RFC 1042
			IP_RX_EOF0 <= '0';
		elsif((MAC_RX_WORD_VALID_D = '1') or (IP_RX_FLUSH_CACHE = '1')) and (IP_TOTAL_LENGTH_DEC(15 downto 14) = "00") and (IP_TOTAL_LENGTH_DEC(13 downto 3) = IP_RX_WORD_COUNT_local) then
			-- Ethernet frame may be padded to meet the minimum 46 Byte (IPv4) or 26 Byte (IPv6) payload length. 
			-- Discard the padding here based on the IP total length
			IP_RX_EOF0 <= '1';
-- PREVIOUS CODE SMALL DOUBT 062118			
--		elsif(MAC_RX_WORD_VALID_D = '1') and (MAC_RX_DATA_VALID_D(1 downto 0) = "00") then
--			IP_RX_EOF0 <= '1'; 
--		elsif(IP_RX_FLUSH_CACHE = '1') then	
--			IP_RX_EOF0 <= '1';
		else
			IP_RX_EOF0 <= '0';
		end if;
	end if;
end process;
IP_RX_EOF_local <= IP_RX_EOF0 and IP_RX_FRAME_VALID3_local;
	-- mask EOF if not an IP frame

-- mask Ethernet short-frame padding bits
IP_RX_MASK_ETH_PADS_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (IP_RX_WORD_COUNT_local < 2) then
			-- wait until RX_IPv4_6N and IP_TOTAL_LENGTH_DEC are known to generate the ethernet mask
			IP_RX_MASK_ETH_PADS <= x"FF";
		elsif(IP_TOTAL_LENGTH_DEC(15 downto 14) = "00") and (IP_TOTAL_LENGTH_DEC(13 downto 3) = IP_RX_WORD_COUNT_local) then
			-- last byte
			case IP_TOTAL_LENGTH_DEC(2 downto 0) is
				when "000" => IP_RX_MASK_ETH_PADS <= x"80";
				when "001" => IP_RX_MASK_ETH_PADS <= x"C0";
				when "010" => IP_RX_MASK_ETH_PADS <= x"E0";
				when "011" => IP_RX_MASK_ETH_PADS <= x"F0";
				when "100" => IP_RX_MASK_ETH_PADS <= x"F8";
				when "101" => IP_RX_MASK_ETH_PADS <= x"FC";
				when "110" => IP_RX_MASK_ETH_PADS <= x"FE";
				when others => IP_RX_MASK_ETH_PADS <= x"FF";
			end case;
		elsif(IP_TOTAL_LENGTH_DEC(15 downto 14) = "00") and (IP_TOTAL_LENGTH_DEC(13 downto 3) > IP_RX_WORD_COUNT_local) then
			IP_RX_MASK_ETH_PADS <= x"FF";
		else
			IP_RX_MASK_ETH_PADS <= x"00";
		end if;
	end if;
end process;


-- pass to other components
IP_RX_DATA <= IP_RX_DATA_local;
IP_RX_SOF <= IP_RX_SOF_local;
IP_RX_EOF <= IP_RX_EOF_local;
IP_RX_DATA_VALID <= IP_RX_DATA_VALID_local;

--// IP PROTOCOL ----------------------
-- IP version 4 or 6?  Ready at IP_RX_SOF_D
DETECT_IP_PROTOCOL_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(IP_RX_SOF_local = '1') then
			if(unsigned(IP_RX_DATA_local(63 downto 60)) = 6) then 
				RX_IPv4_6n_local <= '0';	-- IPv6
			else
				RX_IPv4_6n_local <= '1';	-- IPv4
			end if;
		end if;
	end if;
end process;
RX_IPv4_6n <= RX_IPv4_6n_local;

-- IP protocol (ICMP, UDP, TCP) detection 
DETECT_IPv4_PROTOCOL_002: process(CLK)
begin
	if rising_edge(CLK) then
		IP_PAYLOAD_EOF_D <= IP_PAYLOAD_EOF_local;
		if(SYNC_RESET = '1') or (IP_PAYLOAD_EOF_D = '1') then	-- *060719
			-- reset or end of packet
			-- clear type to unknown
			IPv4_PROTOCOL <= x"00";
			IPv4_PROTOCOL_RDY <= '0';
 		elsif (RX_IPv4_6n_local = '1') and (RX_TYPE_local(2 downto 0) = 1) and 
			(IP_RX_DATA_VALID_local(6) = '1') and (IP_RX_WORD_COUNT_local = 2) then
			-- IPv4. 
			IPv4_PROTOCOL <= IP_RX_DATA_local(55 downto 48);
			IPv4_PROTOCOL_RDY <= '1';
		else
			IPv4_PROTOCOL_RDY <= '0';
		end if;
	end if;
end process;

-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
RX_IP_PROTOCOL_local <= IPv4_PROTOCOL when (RX_IPv4_6n_local = '1') else IPv6_PROTOCOL;
RX_IP_PROTOCOL <= RX_IP_PROTOCOL_local;
RX_IP_PROTOCOL_RDY <= IPv4_PROTOCOL_RDY or IPv6_PROTOCOL_RDY;


--// IPv6 HEADER PARSING ---------------------------------------
-- outline IP header and IPv6 extension headers
-- TODO: IPv6 extension header
IPv6_ONLY_001: if(IPv6_ENABLED = '1') generate
    IPv6_HEADER_001: process(CLK)
    begin
        if rising_edge(CLK) then
			  if(SYNC_RESET = '1') or (IP_PAYLOAD_EOF_D = '1') then	-- *060719
                -- reset or end of packet
                -- clear type to unknown
                IPv6_PROTOCOL <= (others => '0');
                IPv6_PROTOCOL_RDY <= '0';
                IPv6_HEADER_FLAG <= '0';
            elsif(IP_RX_EOF_local = '1') then
                -- safety (in case we missed a new extension protocol)
                IPv6_HEADER_FLAG <= '0';
		  elsif (RX_TYPE_local(2 downto 0) = 5) and (IP_RX_WORD_VALID_local = '1') and 
				(IP_RX_WORD_COUNT_local = 1) and (unsigned(IP_RX_DATA_local(63 downto 60)) = 6) then 
                -- IP_RX_SOF  IPv6 header length is 5 words
                IPv6_HEADER_WORD_CNTR <= to_unsigned(5,IPv6_HEADER_WORD_CNTR'length);
                IPv6_NEXT_HEADER <= IP_RX_DATA_local(15 downto 8);
                IPv6_HEADER_FLAG <= '1';
            elsif(IPv6_HEADER_FLAG = '1') and (IP_RX_WORD_VALID_local = '1') then
                IPv6_HEADER_WORD_CNTR <= IPv6_HEADER_WORD_CNTR - 1;
                if(IPv6_HEADER_WORD_CNTR = 2) then
                    if(unsigned(IPv6_NEXT_HEADER) = 0) then
                    -- extension header: hop-by-hop options
                    elsif(unsigned(IPv6_NEXT_HEADER) = 43) then
                        -- extension header: routing
                    else
                        -- end of current header
                        IPv6_HEADER_FLAG <= '0';
                        -- display protocol
								IPv6_PROTOCOL <= IPv6_NEXT_HEADER;
                        IPv6_PROTOCOL_RDY <= '1';
                   end if;
                elsif(IPv6_HEADER_WORD_CNTR = 1) then
                    -- 1st word in an extension header. Re-arm word counter
                    IPv6_HEADER_WORD_CNTR <= unsigned(IP_RX_DATA_local(55 downto 48));
                    IPv6_NEXT_HEADER <= IP_RX_DATA_local(63 downto 56);
                end if;
            else
                IPv6_PROTOCOL_RDY <= '0';
            end if;
        end if;
    end process;
end generate;
IP_HEADER_FLAG_local(0) <= IP_RX_SOF_local or IPv6_HEADER_FLAG or (IPv4_HEADER_MASK(0) and RX_IPv4_6n_local);
IP_HEADER_FLAG_local(1) <= IP_RX_SOF_local or IPv6_HEADER_FLAG or (IPv4_HEADER_MASK(1) and RX_IPv4_6n_local);
IP_HEADER_FLAG <= IP_HEADER_FLAG_local;
 

--// IPv4 HEADER PARSING ---------------------------------------
-- Parse IPv4_HEADER_N32bWORDS. To be used at MAC_RX_DATA_VALID_D3. 
-- Valid only if type is IPv4. 
IPv4_HEADER_N32bWORDS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		IPv4_HEADER_N32bWORDS_D <= IPv4_HEADER_N32bWORDS;	
		
		if(SYNC_RESET = '1') or (MAC_RX_SOF_D = '1') then
			-- reset or new packet
			-- clear last IP header length
			IPv4_HEADER_N32bWORDS <= (others => '0');
		elsif(IP_RX_SOF_local = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 4) then
			-- IPv4 header
			IPv4_HEADER_N32bWORDS <= unsigned(IP_RX_DATA_local(59 downto 56));
		end if;
	end if;
end process;

-- generate mask for IP header
IPv4_HEADER_N32bWORDS_DEC <= IPv4_HEADER_N32bWORDS-1;
IPv4_HEADER_MASK_001: process(CLK)
begin
	if rising_edge(CLK) then
	   IPv4_HEADER_MASK_D <= IPv4_HEADER_MASK;
	   
	   if(SYNC_RESET = '1') or (MAC_RX_SOF_D = '1') then
			-- reset or new packet
			IPv4_HEADER_MASK_A <= "00";
	   elsif(IP_RX_SOF_local = '1') then
			IPv4_HEADER_MASK_A <= "11";
	   elsif (IP_RX_WORD_VALID_local = '1') and (IP_RX_WORD_COUNT_local = IPv4_HEADER_N32bWORDS_DEC(3 downto 1)) then
			if(IPv4_HEADER_N32bWORDS(0) = '0') then
				-- even number of 32-bit words in IP header
				IPv4_HEADER_MASK_A <= "11";
			else
				-- odd number of 32-bit words in IP header
				IPv4_HEADER_MASK_A <= "10";
			end if;
		elsif (IP_RX_WORD_VALID_local = '1') and (IP_RX_WORD_COUNT_local > IPv4_HEADER_N32bWORDS_DEC(3 downto 1)) then
			IPv4_HEADER_MASK_A <= "00";
		end if;
	end if;
end process;
IPv4_HEADER_MASK <= "11" when (IP_RX_SOF_local = '1')  else IPv4_HEADER_MASK_A;

-- End Of Header, marks the last word in an IPv4 header. Aligned with IP_RX_WORD_VALID_local
IPv4_RX_EOH <= '1' when (IPv4_HEADER_MASK_A /= "00") and (IP_RX_WORD_VALID_local = '1') and (IP_RX_WORD_COUNT_local > IPv4_HEADER_N32bWORDS_DEC(3 downto 1))  else '0';


-- Masked IPv4 header (unused)
--IPv4_HEADER_DATA_GEN: process(IPv4_HEADER_MASK,IP_RX_DATA_local)
--begin
--	if(IPv4_HEADER_MASK = "00") then
--		IPv4_HEADER_DATA <= (others => '0');
--	elsif(IPv4_HEADER_MASK = "10") then
--		IPv4_HEADER_DATA(63 downto 32) <= IP_RX_DATA_local(63 downto 32);
--		IPv4_HEADER_DATA(31 downto 0) <= (others => '0');
--	else
--		IPv4_HEADER_DATA <= IP_RX_DATA_local;
--	end if;
--end process;

-- Parse IP_TOTAL_LENGTH - 1
-- Valid only if type is IPv4. 
IPv4_TOTAL_LENGTH_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_RX_SOF_D = '1') then
			-- reset or new packet
			-- clear last IP total length. Minimum length is 20 bytes
			IP_TOTAL_LENGTH_DEC <= to_unsigned(19,IP_TOTAL_LENGTH_DEC'length);
		elsif(IP_RX_SOF_local = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 4) then
			-- IPv4 header
			IP_TOTAL_LENGTH_DEC <= unsigned(IP_RX_DATA_local(47 downto 32)) - 1;
		elsif(IP_RX_SOF_local = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 6) then
			-- IPv6 header
			IP_TOTAL_LENGTH_DEC <= unsigned(IP_RX_DATA_local(31 downto 16)) + to_unsigned(39,IP_TOTAL_LENGTH_DEC'length);
		end if;
	end if;
end process;


--// VALIDATE IP HEADER CHECKSUM ----------------------
-- perform 1's complement sum of all 16-bit words within the header.
-- IP_HEADER_CHECKSUM_VALID ready 2 CLK after the last header word (RX_SAMPLE_CLK_D4_LOCAL)
-- This applies only to IPv4 (no such field in IPv6)

-- sum most significant and least significant words (used several times in this component)
IP_RX_DATA_SUM_MSW <= resize(unsigned(IP_RX_DATA_local(63 downto 48)),18) + resize(unsigned(IP_RX_DATA_local(47 downto 32)),18);
IP_RX_DATA_SUM_LSW <= resize(unsigned(IP_RX_DATA_local(31 downto 16)),18) + resize(unsigned(IP_RX_DATA_local(15 downto 0)),18);

IP_HEADER_CHECKSUM_001: process(CLK)
variable CKSUM: unsigned(17 downto 0);
begin
	if rising_edge(CLK) then
		IPv4_RX_EOH_D <= IPv4_RX_EOH;	-- end of header
		IP_HEADER_CHECKSUM_VALID_RDY_local <= IPv4_RX_EOH_D;
		
		if(IP_RX_SOF_local = '1') then
		    HCKSUM1 <= IP_RX_DATA_SUM_MSW;
		    HCKSUM2 <= IP_RX_DATA_SUM_LSW;
		    HCKSUM3 <= (others => '0');
		elsif (IP_RX_WORD_VALID_local = '1') then
			if(IPv4_HEADER_MASK(1) = '1') then 
			  HCKSUM1 <= resize(HCKSUM1(15 downto 0),18) + IP_RX_DATA_SUM_MSW;
			end if;
			if(IPv4_HEADER_MASK(0) = '1') then 
				HCKSUM2 <= resize(HCKSUM2(15 downto 0),18) + IP_RX_DATA_SUM_LSW;
			else
				HCKSUM2(17 downto 16) <= (others => '0');	-- blank carry bits, already summed into HCKSUM3_PLUS
			end if;
			if(IPv4_HEADER_MASK /= "00") then 
				 HCKSUM3 <= HCKSUM3_PLUS;
			end if;
		end if;	

		IP_HEADER_CHECKSUM_FINAL <= resize(IP_HEADER_CHECKSUM(15 downto 0),18) + resize(IP_HEADER_CHECKSUM(17 downto 16),18);	-- add carry
		
 	end if;
end process;
HCKSUM3_PLUS <= HCKSUM3 + resize(unsigned(HCKSUM1(17 downto 16)),6) + resize(unsigned(HCKSUM2(17 downto 16)),6);
IP_HEADER_CHECKSUM <= resize(HCKSUM1(15 downto 0),18) + resize(HCKSUM2(15 downto 0),18) + resize(HCKSUM3_PLUS,18);
IP_HEADER_CHECKSUM_VALID_local <= '1' when (SIMULATION = '1') else
											 '1' when (IP_HEADER_CHECKSUM_FINAL(16) = '0') and (IP_HEADER_CHECKSUM_FINAL(15 downto 0) = x"FFFF") else 
											 '1' when (IP_HEADER_CHECKSUM_FINAL(16) = '1') and (IP_HEADER_CHECKSUM_FINAL(15 downto 0) = x"FFFE") else 
											 '0';
	-- ignore computation during simulation with a Wireshark stimulus file as the header checksum may be incorrect (offloaded)

-- make information available to other components
IP_HEADER_CHECKSUM_VALID <= IP_HEADER_CHECKSUM_VALID_local;
IP_HEADER_CHECKSUM_VALID_RDY <= IP_HEADER_CHECKSUM_VALID_RDY_local;


--// SOURCE & DESTINATION IP ADDRESS -------------------------
-- includes IP (v4, v6) and ARP
CAPTURE_SOURCE_IP_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_SOURCE_IP_ADDR_local <= (others => '0');
		elsif(MAC_RX_SOF_D = '1') then
			-- new packet. clear field.
			RX_SOURCE_IP_ADDR_local <= (others => '0');
		elsif (RX_TYPE_local(2 downto 0) = 2) then
			-- ARP request/reply 
			if (MAC_RX_DATA_VALID_D(3 downto 0) = "1111") and (MAC_RX_WORD_COUNT_local = 3) then
				RX_SOURCE_IP_ADDR_local(31 downto 0) <= MAC_RX_DATA_D(31 downto 0);
			end if;
		elsif (RX_IPv4_6n_local = '1') and (RX_TYPE_local(2 downto 0) = 1) and 
			(IP_RX_DATA_VALID_local(3 downto 0) = "1111") and (IP_RX_WORD_COUNT_local = 2) then
			-- IPv4. 
			RX_SOURCE_IP_ADDR_local(31 downto 0) <= IP_RX_DATA_local(31 downto 0);
		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')	and (RX_TYPE_local(2 downto 0) = 5) and 	
			(IP_RX_WORD_VALID_local = '1') then
			-- IPv6 (when enabled)
			if (IP_RX_WORD_COUNT_local = 2) then
				RX_SOURCE_IP_ADDR_local(127 downto 64) <= IP_RX_DATA_local;
			elsif (IP_RX_WORD_COUNT_local = 3) then
				RX_SOURCE_IP_ADDR_local(63 downto 0) <= IP_RX_DATA_local;
			end if;
		end if;
	end if;
end process;
RX_SOURCE_IP_ADDR <= RX_SOURCE_IP_ADDR_local;

CAPTURE_DEST_IP_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_DEST_IP_ADDR_local <= (others => '0');
		elsif(MAC_RX_SOF_D = '1') then
			-- new packet. clear field.
			RX_DEST_IP_ADDR_local <= (others => '0');
		elsif (RX_TYPE_local(2 downto 0) = 2) then
			-- ARP request 
			if	(MAC_RX_DATA_VALID_D(1 downto 0) = "11") and (MAC_RX_WORD_COUNT_local = 4) then
				RX_DEST_IP_ADDR_local(31 downto 16) <= MAC_RX_DATA_D(15 downto 0);
			elsif	(MAC_RX_DATA_VALID_D(7 downto 6) = "11") and (MAC_RX_WORD_COUNT_local = 5) then
				RX_DEST_IP_ADDR_local(15 downto 0) <= MAC_RX_DATA_D(63 downto 48);
			end if;	
		elsif (RX_IPv4_6n_local = '1') and (RX_TYPE_local(2 downto 0) = 1) and 
			(IP_RX_DATA_VALID_local(7 downto 4) = "1111") and (IP_RX_WORD_COUNT_local = 3) then
			-- IPv4. 
			RX_DEST_IP_ADDR_local(31 downto 0) <= IP_RX_DATA_local(63 downto 32);
		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')	and (RX_TYPE_local(2 downto 0) = 5) and
			(IP_RX_WORD_VALID_local = '1') and (IP_RX_WORD_COUNT_local = 4) then		
			-- IPv6 (when enabled) destination address upper 64-bit
			RX_DEST_IP_ADDR_local(127 downto 64) <= IP_RX_DATA_local;
		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')	and (RX_TYPE_local(2 downto 0) = 5) and 
			(IP_RX_WORD_VALID_local = '1') and (IP_RX_WORD_COUNT_local = 5) then		
			-- IPv6 (when enabled) destination address lower 64-bit
			RX_DEST_IP_ADDR_local(63 downto 0) <= IP_RX_DATA_local;
		end if;
	end if;
end process;
RX_DEST_IP_ADDR <= RX_DEST_IP_ADDR_local;

--// VALIDATE IP DESTINATION ADDRESS ----------------------
-- Check only in the case of IP datagram, as identified by the RX_TYPE = 1 
-- latency: 3 CLK after receiving the last byte of the destination address field.
-- TODO: currently checking only for UNICAST addresses. Todo: extend to multicast? broadcast? limited broadcast?
DEST_IP_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_RX_SOF_D = '1') then
			VALID_UNICAST_DEST_IP_local <= '0';
			VALID_UNICAST_DEST_IP_MSBS <= '0';
			VALID_MULTICAST_DEST_IP_local <= '0';
			VALID_MULTICAST_DEST_IP_MSBS <= '0';
			VALID_DEST_IP_RDY_local <= '0';
		-- IPv4
		elsif (RX_IPv4_6n_local = '1') and (RX_TYPE_local(2 downto 0) = 1) and 
			(IP_RX_DATA_VALID_local(7 downto 4) = "1111") and (IP_RX_WORD_COUNT_local = 3) then
			-- IPv4. 
			VALID_DEST_IP_RDY_local <= '1';
			if(IP_RX_DATA_local(63 downto 32) = IPv4_ADDR) then
				-- unicast address match
				VALID_UNICAST_DEST_IP_local <= '1';
			end if;
			if(unsigned(IPv4_MULTICAST_ADDR(31 downto 24)) /= 0) and (IP_RX_DATA_local(63 downto 32) = IPv4_MULTICAST_ADDR) then
				-- multicast address match when enabled (i.e. multicast address is not zero)
				VALID_MULTICAST_DEST_IP_local <= '1';
			elsif(IP_RX_DATA_local(39 downto 32) = x"FF") then
				-- broadcast (weak check, could be strengthened if needed) *043019
				VALID_MULTICAST_DEST_IP_local <= '1';
			end if;
		-- IPv6
		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')	and (RX_TYPE_local(2 downto 0) = 5) and
			(IP_RX_WORD_VALID_local = '1') then
			if(IP_RX_WORD_COUNT_local = 5) then
				VALID_DEST_IP_RDY_local <= '1';
			else
                VALID_DEST_IP_RDY_local <= '0';
			end if;
			-- unicast
			if (IP_RX_WORD_COUNT_local = 4) and	(IP_RX_DATA_local = IPv6_ADDR(127 downto 64)) then
				-- IPv6 (when enabled) destination address upper 64-bit
				VALID_UNICAST_DEST_IP_MSBS <= '1';
			elsif (IP_RX_WORD_COUNT_local = 5) and	(IP_RX_DATA_local = IPv6_ADDR(63 downto 0)) then
				-- IPv6 (when enabled) destination address lower 64-bit
				VALID_UNICAST_DEST_IP_local <= VALID_UNICAST_DEST_IP_MSBS;
			end if;
			-- solicited-node multicast
			if (IP_RX_WORD_COUNT_local = 4) and	(IP_RX_DATA_local = x"FF02000000000000") then
                -- IPv6 (when enabled) multicast destination address upper 64-bit
                VALID_MULTICAST_DEST_IP_MSBS <= '1';
            elsif (IP_RX_WORD_COUNT_local = 5) and (IP_RX_DATA_local(63 downto 24) = x"00000001FF") and (IP_RX_DATA_local(23 downto 0) = IPv6_ADDR(23 downto 0)) then
                -- IPv6 (when enabled) multicast destination address lower 64-bit
                VALID_MULTICAST_DEST_IP_local <= VALID_MULTICAST_DEST_IP_MSBS;
            end if;
		else
			VALID_DEST_IP_RDY_local <= '0';
		end if;
	end if;
end process;
VALID_UNICAST_DEST_IP <= VALID_UNICAST_DEST_IP_local;
VALID_MULTICAST_DEST_IP <= VALID_MULTICAST_DEST_IP_local;
VALID_DEST_IP_RDY <= VALID_DEST_IP_RDY_local;

----// CHECK IP VALIDITY ----------------------
--IP_BYTE_COUNT <= IP_BYTE_COUNT_local;
--IP_RX_DATA <= MAC_RX_DATA_D2;
--IP_RX_SOF <= IP_RX_SOF_local;
--IP_RX_EOF <= IP_RX_EOF_local;
--IP_RX_DATA_VALID_local <= MAC_RX_DATA_VALID_D2 and IP_RX_FRAME_VALID and IP_FRAME_FLAG;
--IP_RX_DATA_VALID <= IP_RX_DATA_VALID_local;
--IP_RX_DATA_VALID2 <= MAC_RX_DATA_VALID_D2 and IP_RX_FRAME_VALID2 and IP_FRAME_FLAG;
--IP_HEADER_FLAG <= IP_HEADER_FLAG_local;

-- The received IP frame is presumed valid until proven otherwise. 
-- IP frame validity checks include: 
-- (a) protocol is IP
-- (b) unicast or multicast destination IP address matches
-- (c) correct IP header checksum (IPv4 only)
-- (d) allowed IPv6
-- (e) Ethernet frame is valid (correct FCS, dest address)
-- Also compute IP_RX_FRAME_VALID2 (no IP destination check)
-- Also compute IP_RX_FRAME_VALID3 (simply not IP, objective: if no IP_SOF then no IP_EOF, no IP_RX_WORD_VALID)
-- Ready at IP_RX_VALID_D (= MAC_RX_DATA_VALID_D3)
IP_RX_FRAME_VALID_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(MAC_RX_SOF_D2 = '1') then
			-- just received first byte. valid until proven otherwise
			IP_RX_FRAME_VALID_local <= '1';
			IP_RX_FRAME_VALID2_local <= '1';
			IP_RX_FRAME_VALID3_local <= '1';
		else
            if(RX_TYPE_RDY_local = '1') and (RX_TYPE_local /= 1) and (RX_TYPE_local /= 5) then
                -- (a) the received packet type is not an IPv4 nor IPv6 datagram 
                IP_RX_FRAME_VALID_local <= '0';
                IP_RX_FRAME_VALID2_local <= '0';
                IP_RX_FRAME_VALID3_local <= '0';
            end if;
            if(IP_RX_SOF_local = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 6) and (IPv6_ENABLED = '0')  then
                -- (d) IPv6 frame not allowed
                IP_RX_FRAME_VALID_local <= '0';
                IP_RX_FRAME_VALID2_local <= '0';
            end if;
            if(VALID_DEST_IP_RDY_local = '1') and (VALID_UNICAST_DEST_IP_local = '0') and (VALID_MULTICAST_DEST_IP_local = '0') then
                -- (b) invalid destination IP 
                IP_RX_FRAME_VALID_local <= '0';
            end if;
            if(RX_IPv4_6n_local = '1') and (IP_HEADER_CHECKSUM_VALID_RDY_local = '1') and (IP_HEADER_CHECKSUM_VALID_local = '0') then
                -- (c) invalid IP header checksum (IPv4 only)
                IP_RX_FRAME_VALID_local <= '0';
                IP_RX_FRAME_VALID2_local <= '0';
            end if;
            if(MAC_RX_EOF = '1') and (MAC_RX_FRAME_VALID = '0') then
               -- (g) erroneous MAC frame
                IP_RX_FRAME_VALID_local <= '0';
                IP_RX_FRAME_VALID2_local <= '0';
                IP_RX_FRAME_VALID3_local <= '0';
            end if;
	   end if;
	end if;
end process;
IP_RX_FRAME_VALID <= IP_RX_FRAME_VALID_local;
IP_RX_FRAME_VALID2 <= IP_RX_FRAME_VALID2_local;


--// IP PAYLOAD   ---------------------------------------------
-- 64-BIT WORD ALIGNMENT
-- In IPv4, a payload frame may start with a 32-bit offset w.r.t. 64-bit words, 
-- depending on the IP header length. Perform realignment here
IP_PAYLOAD_001: process(CLK)
begin
	if rising_edge(CLK) then
        if(IP_RX_SOF_local = '1') or (IP_RX_FRAME_VALID_local = '0') then
            IP_PAYLOAD_DATA <= (others => '0');
            IP_PAYLOAD_DATA_VALID0 <= (others => '0');
            IP_PAYLOAD_WORD_COUNT_local <= (others => '0');
            IP_PAYLOAD_DATA_VALID_LSB32b_D <= (others => '0');
        elsif (IP_RX_WORD_VALID_local = '1') then
            -- 1 received word with 32 or 64-bit payload
            IP_PAYLOAD_DATA_LS32b_D <= IP_RX_DATA_local(31 downto 0);    -- remember the lower half of the previous word
            IP_PAYLOAD_DATA_VALID_LSB32b_D <= IP_RX_DATA_VALID_local(3 downto 0);
            
            if(RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS(0) = '1') and (IPv4_HEADER_MASK = "00") then
                -- IPv4 and odd number of 32-bit words in IP header
                IP_PAYLOAD_DATA(63 downto 32) <= IP_PAYLOAD_DATA_LS32b_D;
                IP_PAYLOAD_DATA(31 downto 0) <= IP_RX_DATA_local(63 downto 32);
                IP_PAYLOAD_DATA_VALID0(7 downto 4) <= IP_PAYLOAD_DATA_VALID_LSB32b_D;
                IP_PAYLOAD_DATA_VALID0(3 downto 0) <= IP_RX_DATA_VALID_local(7 downto 4);
                IP_PAYLOAD_WORD_COUNT_local <= IP_PAYLOAD_WORD_COUNT_local + 1;
            elsif(RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS(0) = '0') and (IPv4_HEADER_MASK = "00") then
                IP_PAYLOAD_DATA <= IP_RX_DATA_local;
                IP_PAYLOAD_DATA_VALID0 <= IP_RX_DATA_VALID_local;
                IP_PAYLOAD_WORD_COUNT_local <= IP_PAYLOAD_WORD_COUNT_local + 1;
           elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (IPv6_HEADER_FLAG = '0') then
                IP_PAYLOAD_DATA <= IP_RX_DATA_local;
                IP_PAYLOAD_DATA_VALID0 <= IP_RX_DATA_VALID_local;
                IP_PAYLOAD_WORD_COUNT_local <= IP_PAYLOAD_WORD_COUNT_local + 1;
            else
                IP_PAYLOAD_DATA_VALID0 <= x"00";
            end if;
        elsif(IP_RX_EOF_D = '1') and (RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS_D(0) = '1') and (IP_PAYLOAD_DATA_VALID_LSB32b_D /= x"0") then
            -- flush remaining 32 bits in cache
            IP_PAYLOAD_DATA(63 downto 32) <= IP_PAYLOAD_DATA_LS32b_D;
            IP_PAYLOAD_DATA(31 downto 0) <= (others => '0');
            IP_PAYLOAD_DATA_VALID0(7 downto 4) <= IP_PAYLOAD_DATA_VALID_LSB32b_D;
            IP_PAYLOAD_DATA_VALID0(3 downto 0) <= x"0";
            IP_PAYLOAD_WORD_COUNT_local <= IP_PAYLOAD_WORD_COUNT_local + 1;
            IP_PAYLOAD_DATA_VALID_LSB32b_D <= x"0";
        else
            IP_PAYLOAD_DATA_VALID0 <= x"00";
        end if;
    end if;
end process;
IP_PAYLOAD_DATA_VALID <= IP_PAYLOAD_DATA_VALID0 when (IP_RX_FRAME_VALID_local = '1') else x"00";	-- blank out ASAP when frame is invalid
IP_PAYLOAD_WORD_COUNT <= std_logic_vector(IP_PAYLOAD_WORD_COUNT_local) when (IP_RX_FRAME_VALID_local = '1') else (others => '0');

-- Generate SOF for the first word of the IP payload
-- Takes into account the possibility of a zero-length payload.
IP_PAYLOAD_002: process(CLK)
begin
	if rising_edge(CLK) then
        if(IP_RX_SOF_local = '1') or (IP_RX_FRAME_VALID_local = '0') then
            IP_PAYLOAD_SOF0 <= '0';
        elsif (IP_RX_WORD_VALID_local = '1') and (IP_PAYLOAD_WORD_COUNT_local = 0) then
            -- 1 received word with 32 or 64-bit payload
            if(RX_IPv4_6n_local = '1') and (IPv4_HEADER_MASK = "00") then
                -- IPv4 
                IP_PAYLOAD_SOF0 <= '1';
           elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (IPv6_HEADER_FLAG = '0') then
                IP_PAYLOAD_SOF0 <= '1';
            else
                IP_PAYLOAD_SOF0 <= '0';
            end if;
        elsif(IP_RX_EOF_D = '1') and (IP_PAYLOAD_WORD_COUNT_local = 0) and (RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS_D(0) = '1') and (IP_PAYLOAD_DATA_VALID_LSB32b_D /= x"0") then
            -- IP payload size is 1-4 bytes => IP_PAYLOAD_SOF coincides with IP_PAYLOAD_EOF
            IP_PAYLOAD_SOF0 <= '1';
        else
            IP_PAYLOAD_SOF0 <= '0';
        end if;
    end if;
end process;
IP_PAYLOAD_SOF <= IP_PAYLOAD_SOF0 and IP_RX_FRAME_VALID_local;	-- blank out ASAP when frame is invalid

-- Generate EOF for the last word of the IP payload
-- Takes into account the possibility of a zero-length payload.
IP_PAYLOAD_003: process(CLK)
begin
	if rising_edge(CLK) then
        if(IP_RX_SOF_local = '1') or (IP_RX_FRAME_VALID_local = '0') then
            IP_PAYLOAD_EOF_local <= '0';
        elsif (IP_RX_EOF_local = '1') then
            if(RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS(0) = '1') and (IPv4_HEADER_MASK = "00") and (IP_RX_DATA_VALID_local(3 downto 0) = x"0") then
                IP_PAYLOAD_EOF_local <= '1';
            elsif(RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS(0) = '0') and (IPv4_HEADER_MASK = "00") then
                IP_PAYLOAD_EOF_local <= '1';
            elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (IPv6_HEADER_FLAG = '0') then
                IP_PAYLOAD_EOF_local <= '1';
            end if;
        elsif(IP_RX_EOF_D = '1') and (RX_IPv4_6n_local = '1') and (IPv4_HEADER_N32bWORDS_D(0) = '1') and (IP_PAYLOAD_DATA_VALID_LSB32b_D /= x"0") then
            -- flush remaining 32 bits in cache
            IP_PAYLOAD_EOF_local <= '1';
        else
            IP_PAYLOAD_EOF_local <= '0';
        end if;
    end if;
end process;
IP_PAYLOAD_EOF <= IP_PAYLOAD_EOF_local;

-- Parse IP payload length (excluding IP header), expressed in bytes. 
IP_PAYLOAD_004: 	process(CLK)
begin
	if rising_edge(CLK) then
		if(IP_RX_SOF_local = '1') then 
			if (unsigned(IP_RX_DATA_local(63 downto 60)) = 4) then
				-- IPv4 header
				IP_PAYLOAD_LENGTH_local <=  unsigned(IP_RX_DATA_local(47 downto 32)) - unsigned(IP_RX_DATA_local(59 downto 56) & "00");
				IP_PAYLOAD_LENGTH_RDY <= '1';
				-- IP payload length (= UDP or TCP length) = total IP length - IP header length in bytes
			elsif(IPv6_ENABLED = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 6) then
				-- IPv6 header
				IP_PAYLOAD_LENGTH_local <=  unsigned(IP_RX_DATA_local(31 downto 16));
				IP_PAYLOAD_LENGTH_RDY <= '1';
				-- UDP length (excludes IP header)
			else
				IP_PAYLOAD_LENGTH_RDY <= '0';
			end if;
		end if;
	end if;
end process;
IP_PAYLOAD_LENGTH <= std_logic_vector(IP_PAYLOAD_LENGTH_local);

---------------------------------------------------
--//--- UDP LAYER ---------------------------------
---------------------------------------------------

--// UDP CHECKSUM -----------------
-- In IPv4, computing the UDP checksum is not sufficient. One must also check if the UDP checksum is zero 
-- (meaning that the sender did not compute the UDP checksum). It is captured here
GET_UDP_CKSUM_IPv4: process(CLK)
begin
	if rising_edge(CLK) then
	   if(IP_RX_SOF_local = '1') then
	       UDPv4_CKSUM_NULL <= '0';    -- assume sender computed a non-null checksum until we reach the actual UDP header
       elsif(IP_RX_WORD_VALID_local = '1') and (RX_IPv4_6n_local = '1') and (IPv4_PROTOCOL = x"11") then
            -- IPv4, UDP, new word
            -- location within the 64-bit word depends on the IP header length
            if(IPv4_HEADER_MASK_D = "11") and (IPv4_HEADER_MASK = "00") and (unsigned(IP_RX_DATA_local(15 downto 0)) = 0)  then
                UDPv4_CKSUM_NULL <= '1';
            end if;
            if(IPv4_HEADER_MASK_D = "10") and (unsigned(IP_RX_DATA_local(47 downto 32)) = 0)  then
                UDPv4_CKSUM_NULL <= '1';
            end if;
        end if;
    end if;
end process;

-- for timing reasons, we limit ourselves to summing up to 3 16-bit fields per CLK 
-- Different pseudo-headers are used for IPv4 and IPv6
-- Design note: the same computation is used for UDP, TCP and IGMP. However,
-- IGMP checksum computation only includes the IP payload, without pseudo-header.
-- UDP/TCP checksum computation include both the IP payload and a pseudo-header.
UDP_CKSUM_001: 	process(CLK)
begin
	if rising_edge(CLK) then
		if(IP_RX_SOF_local = '1') then 
			if (unsigned(IP_RX_DATA_local(63 downto 60)) = 4) then
				-- IPv4 header
				CKSUM1 <=  resize(unsigned(IP_RX_DATA_local(47 downto 32)),18) - resize(unsigned(IP_RX_DATA_local(59 downto 56) & "00"),18);
				-- IP payload length (= UDP or TCP length) = total IP length - IP header length in bytes
				CKSUM2 <= (others => '0');
				CKSUM3 <= (others => '0');  -- carry
			elsif(IPv6_ENABLED = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 6) then
				-- IPv6 header
				CKSUM1 <=  resize(unsigned(IP_RX_DATA_local(31 downto 16)),18);
				-- UDP length (excludes IP header)
				CKSUM2 <=  resize(unsigned(IP_RX_DATA_local(15 downto 8)),18);
				-- Next header = protocol
				CKSUM3 <= (others => '0');  -- carry
			end if;
		elsif(IP_RX_WORD_VALID_local = '1') then
			if (RX_IPv4_6n_local = '1') then
				-- IPv4
				if(IP_RX_WORD_COUNT_local = 2) then
					CKSUM1 <= resize(CKSUM1(15 downto 0),18) + resize(unsigned(IP_RX_DATA_local(55 downto 48)),18);
					-- protocol 
					CKSUM2 <= resize(CKSUM2(15 downto 0),18) + IP_RX_DATA_SUM_LSW;
					-- source address
				elsif(IP_RX_WORD_COUNT_local = 3) then	-- *042719
					if(IP_RX_DATA_local(55 downto 48) = x"02") then	
						-- IGMP protocol case, no pseudo header in the checksum, just the IP payload. reset CKSUM1/2
						CKSUM1 <= (others => '0');
						CKSUM2 <= IP_RX_DATA_SUM_LSW;
					else
						-- UDP/TCP case, keep on summing the pseudo header
						CKSUM1 <= resize(CKSUM1(15 downto 0),18) + IP_RX_DATA_SUM_MSW;
						-- destination IP address
						CKSUM2 <= resize(CKSUM2(15 downto 0),18) + IP_RX_DATA_SUM_LSW;
					end if;
				else
					if (IP_HEADER_FLAG_local(1) = '0') then
						CKSUM1 <= resize(CKSUM1(15 downto 0),18) + IP_RX_DATA_SUM_MSW;
					end if;
					if (IP_HEADER_FLAG_local(0) = '0') then
						CKSUM2 <= resize(CKSUM2(15 downto 0),18) + IP_RX_DATA_SUM_LSW;
					end if;
				end if;
			elsif (IPv6_ENABLED = '1') then
				-- IPv6
				if(IP_RX_WORD_COUNT_local <= 5) then
					CKSUM1 <= resize(CKSUM1(15 downto 0),18) + IP_RX_DATA_SUM_MSW;
					CKSUM2 <= resize(CKSUM2(15 downto 0),18) + IP_RX_DATA_SUM_LSW; -- *042918
					-- destination + source IP addresses
				elsif(IP_HEADER_FLAG_local = "00") then
					CKSUM1 <= resize(CKSUM1(15 downto 0),18) + IP_RX_DATA_SUM_MSW;
					CKSUM2 <= resize(CKSUM2(15 downto 0),18) + IP_RX_DATA_SUM_LSW;
				end if;
			end if;
			CKSUM3 <= CKSUM3PLUS;
		end if;
	end if;
end process;
CKSUM3PLUS <= CKSUM3 + resize(CKSUM1(17 downto 16),18) + resize(CKSUM2(17 downto 16),18);

-- for timing purposes, we need to reclock
-- ready at IP_RX_EOF_D2 = IP_PAYLOAD_EOF_D
UDP_CKSUM_002: 	process(CLK)
begin
	if rising_edge(CLK) then
       RX_UDP_CKSUM_local <= resize(CKSUM1(15 downto 0),18) + resize(CKSUM2(15 downto 0),18) + CKSUM3PLUS;   

	   if(RX_IPv4_6n_local = '1') and (UDPv4_CKSUM_NULL = '1') then
	       -- UDP checksum field is zero. Acceptable for IPv4, but not for IPv6
	       VALID_UDP_CHECKSUM0 <= '1';
       else
           VALID_UDP_CHECKSUM0 <= '0';
       end if;
    end if;
end process;
--VALID_UDP_CHECKSUM1 <= '1' when ((RX_UDP_CKSUM_local(15 downto 0) = x"FFFF") and (RX_UDP_CKSUM_local(17 downto 16) = "00")) 
--                            or  ((RX_UDP_CKSUM_local(15 downto 0) = x"FFFE") and (RX_UDP_CKSUM_local(17 downto 16) = "01"))
--                            or  ((RX_UDP_CKSUM_local(15 downto 0) = x"FFFD") and (RX_UDP_CKSUM_local(17 downto 16) = "10")) else 
--                       '0';
-- alternative phrasing
VALID_UDP_CHECKSUM1 <= 	'0' when (RX_UDP_CKSUM_local(15 downto 2) /= "11111111111111") else
								'0' when ((RX_UDP_CKSUM_local(17 downto 16) xor RX_UDP_CKSUM_local(1 downto 0)) /= "11") else
								'1';
								
VALID_UDP_CHECKSUM_local <= VALID_UDP_CHECKSUM0 or VALID_UDP_CHECKSUM1;                        
VALID_UDP_CHECKSUM <= VALID_UDP_CHECKSUM_local when (RX_IP_PROTOCOL_local = x"11") else '0';

VALID_IP_PAYLOAD_CHECKSUM <= VALID_UDP_CHECKSUM1 when (IPv4_PROTOCOL = x"02") else '0';
-----------------------------------------------------
------ TCP LAYER ---------------------------------
-----------------------------------------------------
-- 
-- The TCP checksum is computed in the same manner as the UDP checksum. Sharing the same code.

-- mask the checksum when simulating using a Wireshark .cap capture file as input
-- Reason: the checksum field may be wrong due to TCP checksum offload to hardware.
--VALID_TCP_CHECKSUM <= VALID_UDP_CHECKSUM_local when (SIMULATION = '0') else '1';
VALID_TCP_CHECKSUM <= VALID_UDP_CHECKSUM_local  when (RX_IP_PROTOCOL_local = x"06") else '0';
-- Note1: TCP checksum offload can be enabled/disabled in Windows/network and sharing center.
-- Note2: TCP checksum validation can be enabled/disabled in Wireshark/Edit/Preferences/TCP


--
--// TEST POINTS --------------------------
TP(1) <= '0';
TP(2) <= '1' when (RX_TYPE_RDY_local = '1') and (RX_TYPE_local /= 1) and (RX_TYPE_local /= 5) else '0';
TP(3) <= '1' when (IP_RX_SOF_local = '1') and (unsigned(IP_RX_DATA_local(63 downto 60)) = 6) and (IPv6_ENABLED = '0') else '0';
TP(4) <= '1' when (VALID_DEST_IP_RDY_local = '1') and (VALID_UNICAST_DEST_IP_local = '0') and (VALID_MULTICAST_DEST_IP_local = '0') else '0';
TP(5) <= '1' when (RX_IPv4_6n_local = '1') and (IP_HEADER_CHECKSUM_VALID_RDY_local = '1') and (IP_HEADER_CHECKSUM_VALID_local = '0') else '0';
TP(6) <= '1' when (MAC_RX_EOF = '1') and (MAC_RX_FRAME_VALID = '0') else '0';
TP(7) <= IP_HEADER_CHECKSUM_VALID_local;
TP(10 downto 8) <= (others => '0');


end Behavioral;
