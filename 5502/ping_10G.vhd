-------------------------------------------------------------
-- MSS copyright 2018
--	Filename:  PING_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 3/4/18
-- Inheritance: 	PING.VHD rev 4, 12/10/15
--
-- description:  PING protocol, 10Gb, for IPv4 and IPv6 
-- Reads a received IP/ICMP frame on the fly and generates a ping echo (Ethernet format).
-- Any new received frame is presumed to be an ICMP echo (ping) request. Within a few bytes,
-- information is received as to the real protocol associated with the received packet.
-- The ping echo generation is immediately cancelled if 
-- (a) the received packet type is not an IP datagram or IPv6 is not allowed
-- (b) the received IP type is not ICMP/ICMP6
-- (c) invalid unicast destination IP (IPv4 or IPv6)
-- (d) packet size is greater than MAX_PING_SIZE (units = 64-bit words, including IP/ICMP headers)  
-- (e) ICMP incoming packet is not an echo request (ICMP type /= x"0800") or (ICMP6 type /= 128)
-- (f) incorrect IP header checksum (IPv4 only)
-- (g) erroneous MAC frame (incorrect FCS, wrong dest MAC address)
-- Any follow-on received IP frame is discarded while a valid ping response awaits transmission in the elastic buffer.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity PING_10G is
	generic (
		IPv6_ENABLED: std_logic := '0';
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		MAX_PING_SIZE: std_logic_vector(7 downto 0) := x"FE" 	
			-- maximum IP/ICMP size (excluding Ethernet/MAC, but including the IP/ICMP header) in 64-bit words. Larger echo requests will be ignored.
			-- The ping buffer contains up to 18Kbits total (for a queued IP/ICMP response waiting for the tx path 
			-- to become available)
		
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
			-- Must be a global clock. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;

		--// ICMP frame received
		IP_RX_DATA: in std_logic_vector(63 downto 0);
		IP_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_RX_SOF: in std_logic;
		IP_RX_EOF: in std_logic;
		IP_RX_WORD_COUNT: in std_logic_vector(10 downto 0);	
		
		--// Partial checks (done in PACKET_PARSING common code)
        --// basic IP validity check
        IP_RX_FRAME_VALID2: in std_logic;
            -- The received IP frame is presumed valid until proven otherwise. 
            -- IP frame validity checks include: 
            -- (a) protocol is IP
            -- (b) unicast or multicast destination IP address matches
            -- (c) correct IP header checksum (IPv4 only)
            -- (d) allowed IPv6
            -- (e) Ethernet frame is valid (correct FCS, dest address)
            -- Also compute IP_RX_FRAME_VALID2 (no IP destination check)
            -- Ready at IP_RX_VALID_D (= MAC_RX_DATA_VALID_D3)
		VALID_UNICAST_DEST_IP: in std_logic;
		VALID_DEST_IP_RDY : in std_logic;
			-- Unicast destination address verification 
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);
			-- Packet origin, already parsed in PACKET_PARSING (shared code)
		
		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
		
		--// IP type, already parsed in PACKET_PARSING (shared code)
		RX_IPv4_6n: in std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
			-- most common protocols: 
			-- 0 = unknown, 1 = ICMP, 2 = IGMP, 6 = TCP, 17 = UDP, 41 = IPv6 encapsulation, 89 = OSPF, 132 = SCTP
	  	RX_IP_PROTOCOL_RDY: in std_logic;
			-- 1 CLK wide pulse. 

		--// USER -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended. User should not supply it.
		-- Synchonous with CLK
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID /= 0
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- data valid
		MAC_TX_EOF: out std_logic;
			-- '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal. The user should check that this 
			-- signal is high before sending the next MAC_TX_DATA byte. 
		RTS: out std_logic;
			-- '1' when a full or partial packet is ready to be read.
			-- '0' when output buffer is empty.
			-- When the user starts reading the output buffer, it is expected that it will be
			-- read until empty.

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of PING_10G is
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
--// STATE MACHINE ------------------
signal STATE: unsigned(0 downto 0) := (others => '0');
signal INPUT_ENABLED: std_logic := '1';
signal IP_RX_WORD_VALID: std_logic := '0';
signal RX_IPv4_6n0: std_logic := '0';

signal IP_RX_DATA_PREVIOUS: std_logic_vector(63 downto 0) := (others => '0');
signal IP_RX_DATA_MOD: std_logic_vector(63 downto 0) := (others => '0');
signal REPLY_CHECKSUM: unsigned(15 downto 0) := (others => '0');
signal IP_RX_DATA_VALID_D: std_logic_vector(7 downto 0) := (others => '0');
signal IP_RX_EOF_D: std_logic := '0';

--// ELASTIC BUFFER ----------------------
signal WPTR: unsigned(7 downto 0) := (others => '0');
signal WPTR_CONFIRMED: unsigned(7 downto 0) := (others => '0');
signal WEA: std_logic := '0';
signal DIA: std_logic_vector(72 downto 0) := (others => '0');
signal DOB: std_logic_vector(72 downto 0) := (others => '0');
signal DOB_PREVIOUS: std_logic_vector(72 downto 0) := (others => '0');
signal RPTR: unsigned(7 downto 0) := (others => '1');
signal BUF_SIZE: unsigned(7 downto 0) := (others => '0');

--// VALIDATE PING REQUEST -----------
signal VALID_PING_REQ0: std_logic := '0';
signal VALID_PING_REQ: std_logic := '0';

--// OUTPUT SECTION -------------------
signal TX_SEQUENCE_CNTR: unsigned(7 downto 0) := (others => '0');
signal TX_SEQUENCE_CNTR_D: unsigned(7 downto 0) := (others => '0');
signal DOB_SAMPLE_CLK_E: std_logic := '0';
signal DOB_SAMPLE_CLK: std_logic := '0';
signal MAC_TX_CTS_D: std_logic := '0';
signal MAC_TX_CTS_D2: std_logic := '0';
signal MAC_TX_EOF_local: std_logic := '0';
signal MAC_TX_DATA_VALID_local: std_logic_vector(7 downto 0) := (others => '0');
signal RTS_local: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// STATE MACHINE ------------------
-- A state machine is needed as this process is memoryless.
-- State 0 = idle or incoming IP frame being processed. 
-- State 1 = valid ping request. tx packet waiting for tx capacity. Incoming IP frames are discarded.
STATE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE <= (others => '0');
		elsif(IP_RX_EOF_D = '1') and (VALID_PING_REQ = '1') then
			-- event = valid PING request. Ready to send PING reply when tx channel opens.
			-- In the mean time, incoming IP frames are discarded.
			STATE <= "1";
		elsif(MAC_TX_EOF_local = '1') then
			-- event = successfully sent PING reply. Reopen input
			STATE <= "0";
		end if;
	end if;
end process;

INPUT_ENABLED <= '1' when (STATE = 0) else '0';


-- save previous IP word (needed information to swap fields)
IN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			IP_RX_DATA_PREVIOUS <= (others => '0');
		elsif(IP_RX_DATA_VALID /= x"00") then
			IP_RX_DATA_PREVIOUS <= IP_RX_DATA;
		end if;
	end if;
end process;

--// freeze some parameters at the end of the packet 
-- Reason: we don't want subsequent packets to change this information while we are waiting
-- to send the echo .
FREEZE_001: process(CLK)
begin
	if rising_edge(CLK) then
	  	if(IP_RX_EOF = '1') and (INPUT_ENABLED = '1') then
			RX_IPv4_6n0 <= RX_IPv4_6n;
	 	end if;
	end if;
end process;

--// FIELDS ALTERATIONS --------------------
-- Modify the incoming words on the fly before temporary storage into elastic buffer
IN_002: process(CLK)
begin
	if rising_edge(CLK) then
		IP_RX_EOF_D <= IP_RX_EOF;
		IP_RX_DATA_VALID_D <= IP_RX_DATA_VALID;
		
		if(SYNC_RESET = '1') or (INPUT_ENABLED = '0') then
			IP_RX_DATA_MOD <= (others => '0');
	    elsif(RX_IPv4_6n = '1') then
            if(unsigned(IP_RX_WORD_COUNT) = 2) then
                IP_RX_DATA_MOD(63 downto 32) <=  IP_RX_DATA(63 downto 32);
                IP_RX_DATA_MOD(31 downto 0) <=  IPv4_ADDR;	-- source is our IP address
            elsif(unsigned(IP_RX_WORD_COUNT) = 3) then
                IP_RX_DATA_MOD(63 downto 32) <=  IP_RX_DATA_PREVIOUS(31 downto 0);	-- swap source/dest IP addresses in response
                IP_RX_DATA_MOD(31 downto 24) <=  x"00";	-- ICMP echo reply IPv4 type
                IP_RX_DATA_MOD(23 downto 16) <=  IP_RX_DATA(23 downto 16);	-- ICMP echo reply IPv4 code
                IP_RX_DATA_MOD(15 downto 0) <=  std_logic_vector(REPLY_CHECKSUM);	-- ICMP echo reply IPv4 checksum
 		    elsif(IP_RX_DATA_VALID /= x"00") then
                IP_RX_DATA_MOD <=  IP_RX_DATA;
            end if;        
	    elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n = '0') then
            if(unsigned(IP_RX_WORD_COUNT) = 2) then
                IP_RX_DATA_MOD <= IPv6_ADDR(127 downto 64);    -- source is our IP address
            elsif(unsigned(IP_RX_WORD_COUNT) = 3) then
                IP_RX_DATA_MOD <= IPv6_ADDR(63 downto 0);    -- source is our IP address
            elsif(unsigned(IP_RX_WORD_COUNT) = 4) then
                IP_RX_DATA_MOD <= RX_SOURCE_IP_ADDR(127 downto 64);    -- destination IP
            elsif(unsigned(IP_RX_WORD_COUNT) = 5) then
                IP_RX_DATA_MOD <= RX_SOURCE_IP_ADDR(63 downto 0);    -- destination IP
            elsif(unsigned(IP_RX_WORD_COUNT) = 6) then
                IP_RX_DATA_MOD <= x"8100" & std_logic_vector(REPLY_CHECKSUM) & IP_RX_DATA(31 downto 0);    -- modify the ICMP checksum
            elsif(IP_RX_DATA_VALID /= x"00") then
                IP_RX_DATA_MOD <=  IP_RX_DATA;
            end if;
        end if;
	end if;
end process;

REPLY_CHECKSUM_GEN: process(IP_RX_DATA, RX_IPv4_6n)
variable CKSUM: unsigned(16 downto 0);
begin
	if(RX_IPv4_6n = '1') then	-- IPv4 
		CKSUM := resize(unsigned(IP_RX_DATA(15 downto 0)),17);
		CKSUM := CKSUM + x"0800";
	else   -- IPv6
		CKSUM := resize(unsigned(IP_RX_DATA(47 downto 32)),17);
		CKSUM := CKSUM - x"0100";
	end if;
	if(CKSUM(16) = '1') then
		CKSUM := CKSUM + 1;
	end if;
	REPLY_CHECKSUM <= CKSUM(15 downto 0);
end process;
	
--// ELASTIC BUFFER ----------------------
-- Stores the IP/ICMP frame until validity check is complete and transmission path is open 	
WEA_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WEA <= '0';
		elsif(unsigned(IP_RX_DATA_VALID) /= 0) and (INPUT_ENABLED = '1') then
			WEA <= '1';
		else
			WEA <= '0';
		end if;
	end if;
end process;

-- write pointer management
WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WPTR <= (others => '0');
		elsif(IP_RX_SOF = '1') then
			-- rewind write pointer 
			WPTR <= (others => '0');		
		elsif(WEA = '1') then
			WPTR <= WPTR + 1;
		end if;
	end if;
end process;

-- confirm WPTR when valid IP/ICMP request
WPTR_CONFIRMED_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_TX_EOF_local = '1')  then
			WPTR_CONFIRMED <= (others => '0');
		elsif(IP_RX_EOF_D = '1') and (VALID_PING_REQ = '1') then
			WPTR_CONFIRMED <= WPTR+1;
		end if;
	end if;
end process;

-- elastic buffer.
-- 18Kbit buffer(s) 
DIA <= IP_RX_EOF_D & IP_RX_DATA_VALID_D & IP_RX_DATA_MOD;
BRAM_DP2_001: BRAM_DP2
GENERIC MAP(
	DATA_WIDTHA => 73,		
	ADDR_WIDTHA => 8,
	DATA_WIDTHB => 73,		 
	ADDR_WIDTHB => 8

)
PORT MAP(
	CSA => '1',
	CLKA => CLK,
	WEA => WEA,      -- Port A Write Enable Input
	ADDRA => std_logic_vector(WPTR),  -- Port A 8-bit Address Input
	DIA => DIA,      -- Port A 65-bit Data Input
	OEA => '0',
	DOA => open,
	CSB => '1',
	CLKB => CLK,
	WEB => '0',
	ADDRB => std_logic_vector(RPTR),  -- Port B 8-bit Address Input
	DIB => (others => '0'),      -- Port B 65-bit Data Input
	OEB => '1',
	DOB => DOB      -- Port B 65-bit Data Output
);

-- occupied buffer space, in bytes
BUF_SIZE <= WPTR_CONFIRMED + (not RPTR);

--// VALIDATE PING REQUEST -----------
-- The ping echo generation is immediately cancelled if 
-- (a) the received packet type is not an IP datagram or IPv6 is not allowed
-- (b) the received IP type is not ICMP/ICMP6
-- (c) invalid unicast destination IP (IPv4 or IPv6)
-- (d) packet size is greater than MAX_PING_SIZE (units = 64-bit words, including IP/ICMP headers)  
-- (e) ICMP incoming packet is not an echo request (ICMP type /= x"0800") or (ICMP6 type /= 128)
-- (f) incorrect IP header checksum (IPv4 only)
-- (g) erroneous MAC frame (incorrect FCS, wrong dest MAC address)

IP_RX_WORD_VALID <= '1' when (unsigned(IP_RX_DATA_VALID) /= 0) else '0';

VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			VALID_PING_REQ0 <= '1';
		elsif(IP_RX_SOF = '1') then
			-- just received first word in an IP frame. Assume validity
			VALID_PING_REQ0 <= '1';
		else
            if(RX_IP_PROTOCOL_RDY = '1') and (unsigned(RX_IP_PROTOCOL) /= 1) and (unsigned(RX_IP_PROTOCOL) /= 58)  then
                -- (b) not ICMP nor ICMPv6
                VALID_PING_REQ0 <= '0';
            end if;
            if(IP_RX_WORD_VALID = '1') and (unsigned(IP_RX_WORD_COUNT) = 3) and (RX_IPv4_6n = '1') and (IP_RX_DATA(31 downto 16) /= x"0800") then
                -- (e) IPv4 and ICMP incoming packet is not an echo request (ICMP type /= 8)
                VALID_PING_REQ0 <= '0';
            end if;
            if(VALID_DEST_IP_RDY = '1') and (VALID_UNICAST_DEST_IP = '0') then
                -- (c) invalid destination IP (IPv4 or IPv6)
                VALID_PING_REQ0 <= '0';
            end if;
            if(IP_RX_WORD_VALID = '1') and (unsigned(IP_RX_WORD_COUNT) = 6) and (RX_IPv4_6n = '0') and 
            ((IP_RX_DATA(63 downto 48) /= x"8000") or (IPv6_ENABLED = '0')) then
                -- (e) IPv6 and ICMP6 incoming packet is not an echo request (ICMP6 type /= 128)
                VALID_PING_REQ0 <= '0';
            end if;
            if(IP_RX_WORD_VALID = '1') and (unsigned(IP_RX_WORD_COUNT(MAX_PING_SIZE'left downto 0)) > unsigned(MAX_PING_SIZE)) then
                -- (d) packet size is greater than MAX_PING_SIZE (units = 64-bit words, including IP/ICMP headers) 
                VALID_PING_REQ0 <= '0';
            end if;
        end if;
	end if;
end process;
VALID_PING_REQ <= VALID_PING_REQ0 and IP_RX_FRAME_VALID2;   -- combine with the other checks done in parsing.vhd

--// OUTPUT SECTION -------------------
-- send request to send when a valid IP/ICMP echo response is ready
RTS_local <= '1' when (BUF_SIZE /= 0) else '0';
RTS <= RTS_local;

-- Output MAC frame generation
RPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		DOB_SAMPLE_CLK <= DOB_SAMPLE_CLK_E;	-- latency to read from RAM
		TX_SEQUENCE_CNTR_D <= TX_SEQUENCE_CNTR;
		MAC_TX_CTS_D <= MAC_TX_CTS;
		MAC_TX_CTS_D2 <= MAC_TX_CTS_D;
		
		if(SYNC_RESET = '1') or (MAC_TX_EOF_local = '1') then
			TX_SEQUENCE_CNTR <= (others => '0');
			RPTR <= (others => '1');
			DOB_SAMPLE_CLK_E <= '0';
		elsif(RTS_local = '1') and (MAC_TX_CTS = '1') then
			-- buffer is not empty and MAC requests another byte
			TX_SEQUENCE_CNTR <= TX_SEQUENCE_CNTR + 1;
			DOB_SAMPLE_CLK_E <= '1';
			if(TX_SEQUENCE_CNTR > 0) then
				RPTR <= RPTR + 1;
			end if;
		else
			DOB_SAMPLE_CLK_E <= '0';
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

MAC_TX_DATA_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		case TX_SEQUENCE_CNTR_D is
			when x"01" => 
				MAC_TX_DATA(63 downto 16) <= RX_SOURCE_MAC_ADDR;	-- source <-> destination MAC
				MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
			when x"02" => 
				MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);	-- source <-> destination MAC
				if(RX_IPv4_6n0 = '1') then
				    MAC_TX_DATA(31 downto 16) <= x"0800";   -- IPv4
				else
				    MAC_TX_DATA(31 downto 16) <= x"86dd";   -- IPv6
				end if;
				MAC_TX_DATA(15 downto 0) <= DOB(63 downto 48);
			when others => 
				MAC_TX_DATA(63 downto 16) <= DOB_PREVIOUS(47 downto 0);
				MAC_TX_DATA(15 downto 0) <= DOB(63 downto 48);
		end case;
	end if;
end process;

MAC_TX_DATA_VALID_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_TX_EOF_local = '1') or (STATE = "0") then
			MAC_TX_DATA_VALID_local <= x"00";
		elsif(DOB_SAMPLE_CLK = '1') then
			if(unsigned(TX_SEQUENCE_CNTR_D) < 3) then
				MAC_TX_DATA_VALID_local <= x"FF";
			else
				MAC_TX_DATA_VALID_local(7 downto 2) <= DOB_PREVIOUS(69 downto 64);
				MAC_TX_DATA_VALID_local(1 downto 0) <= DOB(71 downto 70);
			end if;
		elsif(MAC_TX_CTS_D2 = '1') and (unsigned(DOB_PREVIOUS(69 downto 64)) /= 0) then
			-- flush last bytes
			MAC_TX_DATA_VALID_local(7 downto 2) <= DOB_PREVIOUS(69 downto 64);
			MAC_TX_DATA_VALID_local(1 downto 0) <= "00";
		else
			MAC_TX_DATA_VALID_local <= x"00";
		end if;
	end if;
end process;
MAC_TX_DATA_VALID <= MAC_TX_DATA_VALID_local;

MAC_TX_EOF_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_TX_EOF_local = '1') or (STATE = "0") then
			MAC_TX_EOF_local <= '0';
		elsif(DOB_SAMPLE_CLK = '1') then
			if (DOB_SAMPLE_CLK_E = '0') and (BUF_SIZE = 0) and (unsigned(DOB(69 downto 64)) = 0) then
				MAC_TX_EOF_local <= '1';
			end if;
		elsif(DOB_SAMPLE_CLK = '0') and (MAC_TX_CTS_D2 = '1') and (unsigned(DOB_PREVIOUS(69 downto 64)) /= 0) then
			-- flush last bytes
			MAC_TX_EOF_local <= '1';
		else
			MAC_TX_EOF_local <= '0';
		end if;
	end if;
end process;
MAC_TX_EOF <= MAC_TX_EOF_local;			




--// TEST POINTS --------------------------
TP(1) <= IP_RX_EOF_D and VALID_PING_REQ;
--TP(1) <= IP_RX_SOF;
TP(2) <= '1' when (IP_RX_DATA_VALID /= x"00") else '0';
TP(3) <= IP_RX_EOF;
TP(4) <= VALID_PING_REQ0;
TP(5) <= VALID_UNICAST_DEST_IP and VALID_DEST_IP_RDY;
TP(6) <= IP_RX_FRAME_VALID2;
TP(7) <= DOB_SAMPLE_CLK;
TP(8) <= MAC_TX_EOF_local;
TP(9) <= '1' when (MAC_TX_DATA_VALID_local /= x"00") else '0';
TP(10)<= MAC_TX_CTS;



end Behavioral;
