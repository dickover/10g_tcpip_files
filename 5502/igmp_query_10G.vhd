-------------------------------------------------------------
-- MSS copyright 2019
--	Filename:  IGMP_QUERY_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 4/27/19
-- Inheritance: 	IGMP_QUERY.vhd 12/27/14
--
-- description:  detect a valid IGMP membership query and trigger a response when applicable 
-- 
-- Expects the following external validation checks (in PARSING):
-- MAC address(just multicast bit), IP type, IP header checksum
-- NO prior validation for complete MAC address, IP multicast destination address, IGMP checksum
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity IGMP_QUERY_10G is
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
		SYNC_RESET: in std_logic;

        --// Configuration
		MULTICAST_IP_ADDR : IN std_logic_vector(31 downto 0);
			-- our multicast IP address (just one)
        
		--// Received IP frame payload
		-- Excludes MAC layer header and IP header.
		IP_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
		IP_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_PAYLOAD_SOF: in std_logic;
		IP_PAYLOAD_EOF: in std_logic;
		IP_PAYLOAD_WORD_COUNT: in std_logic_vector(10 downto 0);    

		--// Partial checks (done in PACKET_PARSING common code)
		--// basic IP validity check
		IP_RX_FRAME_VALID2: in std_logic; 
		-- As the IP frame validity is checked on-the-fly, the user should always check if 
			-- the IP_RX_FRAME_VALID is high AT THE END of the IP payload frame (IP_PAYLOAD_EOF) to confirm that the 
			-- ENTIRE IP frame is valid. 
			-- The received IP frame is presumed valid until proven otherwise. 
			-- IP frame validity checks include: 
			-- (a) protocol is IP
			-- (c) correct IP header checksum (IPv4 only)
			-- (d) allowed IPv6
			-- (e) Ethernet frame is valid (correct FCS, dest address)
			-- Note: ignore IP destination check in parsing. We do it within this component.
			-- Ready at IP_RX_EOF_D2 = IP_PAYLOAD_EOF 
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
			-- This component responds to protocol 2 = IGMP 
		VALID_MULTICAST_DEST_IP: IN std_logic;
		VALID_IP_PAYLOAD_CHECKSUM: in std_logic;
			-- '1' when valid IP payload checksum. Read at IP_RX_EOF_D2 or IP_PAYLOAD_EOF_D
		RX_DEST_IP_ADDR: in std_logic_vector(31 downto 0);  	
			-- 
		
		--// Output
		TRIGGER_RESPONSE: out std_logic;
			-- aligned with IP_PAYLOAD_EOF_D
		
		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of IGMP_QUERY_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--// CHECK IGMP QUERY VALIDITY -----------------------------
signal VALID_RX_IGMP0: std_logic := '0';
signal VALID_RX_IGMP1: std_logic := '0';
signal VALID_RX_IGMP2: std_logic := '0';
signal VALID_RX_IGMP: std_logic := '0';
signal IP_PAYLOAD_EOF_D: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// CHECK IGMP QUERY VALIDITY -----------------------------
-- The IGMP packet reception is immediately cancelled if 
-- (a) the received packet type is not an IP datagram  (done in common code PACKET_PARSING)
-- (b) invalid destination IP (done in common code PACKET_PARSING)
-- (c) incorrect IP header checksum (done in common code PACKET_PARSING)
-- (d) the received IP type is not IGMP 
-- (e) IGMP type is not membership request
-- (f) IGMP checksum is incorrect
-- (g) group address in IGMP query does not match our multicast IP address

VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		IP_PAYLOAD_EOF_D <= IP_PAYLOAD_EOF;
		
	   if(IP_PAYLOAD_SOF = '1') then
			if(unsigned(RX_IP_PROTOCOL) /= 2) then
				-- (d) the received IP type is not IGMP 
				 VALID_RX_IGMP0 <= '0';
			elsif(IP_PAYLOAD_DATA(63 downto 56) /= x"11") then
				-- (e) IGMP type is not membership request
				VALID_RX_IGMP0 <= '0';
			else
				VALID_RX_IGMP0 <= '1';
			end if;
		end if;
		
		-- for IGMPv2, IP_PAYLOAD_SOF and IP_PAYLOAD_EOF can be concurrent
		if(IP_PAYLOAD_EOF = '1') then
			if (IP_RX_FRAME_VALID2 = '0') then
				-- invalid IP frame
				VALID_RX_IGMP1 <= '0';
			else
				VALID_RX_IGMP1 <= '1';
			end if;
	   end if;
		
		if(IP_PAYLOAD_DATA_VALID(3 downto 0) = x"F") and (unsigned(IP_PAYLOAD_WORD_COUNT) = 1) then
			-- expecting group address
			if(RX_DEST_IP_ADDR = x"E0000001") then
				-- general IGMP query is sent to address 224.0.0.1 (all hosts)
				-- The group field is zeroed when sending a General Query
				if (unsigned(IP_PAYLOAD_DATA(31 downto 0)) = 0) then
					VALID_RX_IGMP2 <= '1';
				else
					-- invalid combination of zero group field and unexpected destination IP address
					VALID_RX_IGMP2 <= '0';
				end if;
			elsif(IP_PAYLOAD_DATA(31 downto 0) /= MULTICAST_IP_ADDR) then
				-- group-specific IGMP query
				-- (g) group address does not match our multicast IP address
				VALID_RX_IGMP2 <= '0';
			else
				VALID_RX_IGMP2 <= '1';
			end if;
		end if;
 	end if;
end process;
-- combine with the other checks done in parsing.vhd
VALID_RX_IGMP <= VALID_RX_IGMP0 and VALID_RX_IGMP1 and VALID_RX_IGMP2 and 
						VALID_MULTICAST_DEST_IP and VALID_IP_PAYLOAD_CHECKSUM;   

-- trigger a response to a query
TRIGGER_RESPONSE <= VALID_RX_IGMP and IP_PAYLOAD_EOF_D;

--// Test Point
TP(1) <= IP_PAYLOAD_EOF_D;
TP(2) <= VALID_RX_IGMP0;
TP(3) <= VALID_RX_IGMP1;
TP(4) <= VALID_RX_IGMP2;
TP(6) <= VALID_RX_IGMP;
TP(7) <= VALID_RX_IGMP and IP_PAYLOAD_EOF_D;
end Behavioral;
