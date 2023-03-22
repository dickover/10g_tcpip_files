-------------------------------------------------------------
-- MSS copyright 2018
--	Filename:  UDP_RX_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 4/29/18
-- Inheritance: 	COM-5402 UDP_RX.VHD 7/31/15
--
-- description:  UDP protocol (receive-only) 10Gb, for IPv4 and IPv6  
-- Receives and validates UDP frames. The data segment of the UDP frame is immediately 
-- forwarded to the application without any intermediate storage in an elastic buffer.
-- Thus the application must be capable of receiving data at full speed (156.25MHz/64-bit wide).
-- 
-- Various validation checks are performed in real-time while receiving a new frame.
-- If any of the check fails, the UDP_RX_DATA_VALID is cleared. It is therefore IMPORTANT
-- that the application rejects frame if UDP_RX_FRAME_VALID = '0' at the end of the frame  
-- (UDP_RX_EOF = '1'). 
-- 
-- Validation checks:
-- MAC address, IP type, IP destination address, UDP protocol, 
-- UDP destination port, IP header checksum, UDP checksum
-- 
-- As there is no difference between IPv4 and IPv6 for UDP, this component is compatible with 
-- both IPv4 and IPv6.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity UDP_RX_10G is
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
		SYNC_RESET: in std_logic;

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
            -- The received IP frame is presumed valid until proven otherwise. 
            -- IP frame validity checks include: 
            -- (a) protocol is IP
            -- (b) unicast or multicast destination IP address matches
            -- (c) correct IP header checksum (IPv4 only)
            -- (d) allowed IPv6
            -- (e) Ethernet frame is valid (correct FCS, dest address)
            -- Ready at IP_RX_EOF_D2 = IP_PAYLOAD_EOF 
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
			-- This component responds to protocol 17 = UDP 
		VALID_UDP_CHECKSUM: in std_logic;
		  -- '1' when valid UDP checksum. Read at IP_RX_EOF_D2 = IP_PAYLOAD_EOF_D
		
		--// configuration
		PORT_NO: in std_logic_vector(15 downto 0);
			-- accepts UDP packets with a destination port PORT_NO
		CHECK_UDP_RX_DEST_PORT_NO: in std_logic;
			-- check the destination port number matches PORT_NO (1) or ignore it (0)
			-- The latter case is useful when this component is shared among multiple UDP ports
		
		--// Application interface 
		-- Latency: 0 
		UDP_RX_DATA: out std_logic_vector(63 downto 0);
			-- UDP data field when UDP_RX_DATA_VALID = '1'
		UDP_RX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- delineates the UDP data field
		UDP_RX_SOF: out std_logic;
			-- 1 CLK pulse indicating that UDP_RX_DATA is the first byte in the UDP data field.
		UDP_RX_EOF: out std_logic;
			-- 1 CLK pulse indicating that UDP_RX_DATA is the last byte in the UDP data field.
			-- ALWAYS CHECK UDP_RX_FRAME_VALID at the end of packet (UDP_RX_EOF = '1') to confirm
			-- that the UDP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid UDP packet.
			-- Reason: we only knows about bad UDP packets at the end.
	    UDP_RX_FRAME_VALID: out std_logic;
	        -- check entire frame validity at UDP_RX_EOF
		UDP_RX_SRC_PORT: out std_logic_vector(15 downto 0);
			-- Identify the source UDP port. Read when UDP_RX_EOF = '1' 
		UDP_RX_DEST_PORT: out std_logic_vector(15 downto 0);
				-- Identify the destination UDP port. Read when UDP_RX_EOF = '1' 
			

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of UDP_RX_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
--// PARSE UDP HEADER --------------------------
signal LENGTH: std_logic_vector(15 downto 0) := (others => '0');

--// CHECK UDP VALIDITY -----------------------------
signal VALID_RX_UDP0: std_logic := '0';
signal VALID_RX_UDP: std_logic := '0';

-- Remove UDP header
signal UDP_PAYLOAD_FLAG: std_logic := '0';
signal UDP_PAYLOAD_SOF_FLAG: std_logic := '0';
signal UDP_RX_EOF_local: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// PARSE UDP HEADER --------------------------
UDP_HEADER_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(IP_PAYLOAD_SOF = '1') then
	       UDP_RX_SRC_PORT <= IP_PAYLOAD_DATA(63 downto 48);
	       UDP_RX_DEST_PORT <= IP_PAYLOAD_DATA(47 downto 32);
	       LENGTH <= IP_PAYLOAD_DATA(31 downto 16);
	   end if; 
	end if;
end process;

--// CHECK UDP VALIDITY -----------------------------
-- The UDP packet reception is immediately cancelled if 
-- (a) the received packet type is not an IP datagram  (done in common code PACKET_PARSING)
-- (b) invalid destination IP  (done in common code PACKET_PARSING)
-- (c) incorrect IP header checksum (IPv4 only) (done in common code PACKET_PARSING)
-- (d) the received IP type is not UDP 
-- (e) destination port number is not the specified PORT_NO (checking is user-enabled)
-- (f) UDP checksum is incorrect

VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(IP_PAYLOAD_SOF = '1') then
			if(unsigned(RX_IP_PROTOCOL) /= 17) then
				-- received protocol is not UDP
				 VALID_RX_UDP0 <= '0';
			elsif(CHECK_UDP_RX_DEST_PORT_NO = '1') and (PORT_NO /= IP_PAYLOAD_DATA(47 downto 32)) then
				 -- user asked us to check the destination port number and it does not match.
				 -- Note: in some applications where UDP_RX_10G.vhd is shared by multiple UDP ports (DHCP server for example), 
				 -- the destination port number check is better done outside this component.
				 VALID_RX_UDP0 <= '0';
			else
				 VALID_RX_UDP0 <= '1';
			end if;
		elsif(IP_PAYLOAD_EOF = '1') and (IP_RX_FRAME_VALID = '0') then
			VALID_RX_UDP0 <= '0';
	   end if;
 	end if;
end process;
UDP_RX_FRAME_VALID <= VALID_RX_UDP0 and VALID_UDP_CHECKSUM and UDP_RX_EOF_local;   -- combine with the other checks done in parsing.vhd
    -- validity assessment is complete at IP_PAYLOAD_EOF_D = UDP_RX_EOF


--// COPY UDP DATA TO APPLICATION INTERFACE ------------------------
-- Algorithm: UDP header is 8-byte long = 1 word. So just skip the first IP payload word.
-- TODO: verify that in the case of very short (<60 bytes) Ethernet frames, the zero padding
-- is removed in packet_parsing.vhd

-- Remove UDP header
UDP_PAYLOAD_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(IP_PAYLOAD_EOF = '1') then
	       UDP_PAYLOAD_FLAG <= '0';
	   elsif(IP_PAYLOAD_SOF = '1') then
	       UDP_PAYLOAD_FLAG <= '1';
       end if;
       
	   if(IP_PAYLOAD_SOF = '1') and (IP_PAYLOAD_EOF = '0')then
           UDP_PAYLOAD_SOF_FLAG <= '1';
       elsif(unsigned(IP_PAYLOAD_DATA_VALID) /= 0) or (IP_PAYLOAD_EOF = '1') then
           UDP_PAYLOAD_SOF_FLAG <= '0';
       end if;
 	end if;
end process;

-- reclock to align UDP_RX_EOF with the late arrival of VALID_UDP_CHECKSUM
OUTPUT_001: process(CLK)
begin
    if rising_edge(CLK) then
        UDP_RX_DATA <= IP_PAYLOAD_DATA;
        if(UDP_PAYLOAD_FLAG = '1') and (VALID_RX_UDP0 = '1') then
            UDP_RX_DATA_VALID <= IP_PAYLOAD_DATA_VALID ;
        else
            UDP_RX_DATA_VALID <= (others => '0');
        end if;
        if(UDP_PAYLOAD_SOF_FLAG = '1') and (VALID_RX_UDP0 = '1') and (unsigned(IP_PAYLOAD_DATA_VALID) /= 0) then
            UDP_RX_SOF <= '1';
        else
            UDP_RX_SOF <= '0';
        end if;
        UDP_RX_EOF_local <= IP_PAYLOAD_EOF and UDP_PAYLOAD_FLAG and VALID_RX_UDP0;
    end if;
end process;
UDP_RX_EOF <= UDP_RX_EOF_local;

--// Test Point
-- unused here
-- TP(1) <= ...

end Behavioral;
