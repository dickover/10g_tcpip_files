-------------------------------------------------------------
-- MSS copyright 2019
--	Filename:  IGMP_REPORT_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 4/28/19
-- Inheritance: 	IGMP_REPORT.VHD rev1 12/26/12
--
-- description:  send an IGMP membership report out to whom it may concern
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;

entity IGMP_REPORT_10G is
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
		SYNC_RESET: in std_logic;
			-- CLK-synchronous reset. MANDATORY after IPv4_ADDR and MULTICAST_IP_ADDR are defined. 
		
		--// Control
		IGMP_START: in std_logic;
			-- 1 CLK pulse to start the IGMP report
			-- new requests will be ignored until the module is 
			-- finished with the previous request. 

		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
			-- local IP address
			-- Natural order (MSB) 172.16.1.128 (LSB)
		IP_ID: in std_logic_vector(15 downto 0);
            -- 16-bit IP ID, unique for each IP frame. Incremented every time
            -- an IP frame is sent .
		MULTICAST_IP_ADDR : IN std_logic_vector(31 downto 0);
			-- multicast IP address to report. 

		--// Transmit frame/packet to MAC interface
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

architecture Behavioral of IGMP_REPORT_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

signal STATE: std_logic := '0';
signal TX_PACKET_SEQUENCE: unsigned(4 downto 0) := (others => '1');  -- 46 bytes max 
signal MAC_TX_DATA_VALID_E: std_logic := '0';
signal MAC_TX_EOF_local: std_logic := '0';
signal RTS_local: std_logic := '0';
signal IP_ID_D: std_logic_vector(15 downto 0):= (others => '0');

--// ICMP CHECKSUM -----------------
signal CKSUM_SEQ_CNTR: unsigned(1 downto 0)  := (others => '0');
signal IP_HEADER_CKSUM0: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CKSUM_FINAL: unsigned(17 downto 0) := (others => '0');
signal IGMP_CKSUM: unsigned(17 downto 0) := (others => '0');
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

TX_SEQUENCE_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or ((IGMP_START = '1') and (STATE = '0')) or (MAC_TX_EOF_local = '1') then	
			TX_PACKET_SEQUENCE <= (others => '1');
			MAC_TX_DATA_VALID_E <= '0';
		elsif(STATE = '1') and (MAC_TX_CTS = '1') then
			-- read the next word
            TX_PACKET_SEQUENCE <= TX_PACKET_SEQUENCE + 1;
            MAC_TX_DATA_VALID_E <= '1';
        else
			MAC_TX_DATA_VALID_E <= '0';
		end if;
	end if;
end process;

-- aligned with MAC_TX_DATA_VALID
MAX_TX_EOF_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MAC_TX_EOF_local = '1') then
			MAC_TX_EOF_local <= '0';
			MAC_TX_DATA_VALID <= x"00"; 
		elsif(MAC_TX_DATA_VALID_E = '1') then
            if(TX_PACKET_SEQUENCE = 5) then
                -- IGMP report done. transmitting the last word (46-bytes)
                MAC_TX_DATA_VALID <= x"FC"; -- last word contains only 6 bytes
                MAC_TX_EOF_local <= '1';
            else
                MAC_TX_DATA_VALID <= x"ff"; 
                MAC_TX_EOF_local <= '0';
            end if;
        else
            MAC_TX_DATA_VALID <= x"00"; 
            MAC_TX_EOF_local <= '0';
        end if;
	end if;
end process;
MAC_TX_EOF <= MAC_TX_EOF_local;

-- State machine
RTS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS_local <= '0';
			STATE <= '0';
		else
			if(IGMP_START = '1') and (STATE = '0') then
				-- new transaction. Sending IGMP report
				RTS_local <= '1';
				STATE <= '1';
				-- freeze IP_ID
				IP_ID_D <= IP_ID;
			elsif(MAC_TX_EOF_local = '1') then
				-- done. transmitting the last word
				RTS_local <= '0';
				STATE <= '0';
			end if;
		end if;
	end if;
end process;
RTS <= RTS_local;

----// Generate IGMP report
MAC_TX_DATA_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_TX_DATA <= (others => '0');
		elsif(MAC_TX_CTS = '1') then
			case TX_PACKET_SEQUENCE is
				-- Ethernet header
				when "00000" => 
					-- reserved a block of Ethernet addresses that map on to the Class D multicast addresses
					-- The reserved address 0x0100.5e00.0000 is used by Ethernet to determine a unique multicast MAC
					-- destination MAC address: multicast.
					MAC_TX_DATA(63 downto 39) <= x"01005E" & "0";    
					MAC_TX_DATA(38 downto 16) <= MULTICAST_IP_ADDR(22 downto 0);    
					MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
				when "00001" => 
					MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);    
					MAC_TX_DATA(31 downto 0) <= x"08004600";   -- Ethernet type, IP version 4, 24-byte header length, DSCP 0
				when "00010" => 
					MAC_TX_DATA(63 downto 48) <= x"0020"; 	-- total length 32	 
					MAC_TX_DATA(47 downto 32) <= IP_ID_D;
					MAC_TX_DATA(31 downto 0) <= x"00000102";  -- flags, fragment offset, TTL always 1, protocol IGMP
				when "00011" => 
					MAC_TX_DATA(63 downto 48) <= std_logic_vector(IP_HEADER_CKSUM_FINAL(15 downto 0));   -- IP header checksum   
					MAC_TX_DATA(47 downto 16) <= IPv4_ADDR;   -- sender IP address  
					MAC_TX_DATA(15 downto 0) <= MULTICAST_IP_ADDR(31 downto 16);   -- multicast IP address being reported
				when "00100" => 
					MAC_TX_DATA(63 downto 48) <= MULTICAST_IP_ADDR(15 downto 0);   -- multicast IP address being reported 
					-- options
					MAC_TX_DATA(47 downto 16) <= x"94040000"; -- router alert: every router examines packet
					-- IGMPv2
					MAC_TX_DATA(15 downto 0) <=  x"1600"; -- membership report, maximum response time	
				when others => 
				--when "00101" => 
					MAC_TX_DATA(63 downto 48) <= std_logic_vector(IGMP_CKSUM(15 downto 0));	-- IP checksum
					MAC_TX_DATA(47 downto 16) <= MULTICAST_IP_ADDR; -- group address
					MAC_TX_DATA(15 downto 0) <=  (others => '0');      
			end case;
		end if;
	end if;
end process;

--// IP HEADER CHECKSUM -----------------
-- Computed at reset, since all the information is fixed (except for IP_ID which changes at every message)
CKSUM_001: 	process(CLK)
begin
  if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			 CKSUM_SEQ_CNTR <= "11";
		elsif(CKSUM_SEQ_CNTR > 0) then
			 CKSUM_SEQ_CNTR <= CKSUM_SEQ_CNTR - 1;
		end if;
  end if;
end process;
    
IP_HEADER_CKSUM_002: process(CLK)
begin
  if rising_edge(CLK) then
		-- fixed part of the IP header checksum. 
		if(SYNC_RESET = '1') then
			 IP_HEADER_CKSUM0 <= resize(unsigned(IPv4_ADDR(31 downto 16)),18) + resize(unsigned(IPv4_ADDR(15 downto 0)),18);
		elsif(CKSUM_SEQ_CNTR = "11") then
			 IP_HEADER_CKSUM0 <= IP_HEADER_CKSUM0 + resize(unsigned(MULTICAST_IP_ADDR(31 downto 16)),18);
		elsif(CKSUM_SEQ_CNTR = "10") then
			 IP_HEADER_CKSUM0 <= IP_HEADER_CKSUM0 + resize(unsigned(MULTICAST_IP_ADDR(15 downto 0)),18);
		elsif(CKSUM_SEQ_CNTR = "01") then
			 IP_HEADER_CKSUM0 <= IP_HEADER_CKSUM0 + ("00" & x"DB26");
				  -- constant is the sum of x4600 + x0020 + x0102 + x9404
		end if;
		
		-- variable part of the IP header checksum. Add IP_ID
		if(MAC_TX_CTS = '1') then
			if(TX_PACKET_SEQUENCE = "00000") then
				IP_HEADER_CKSUM_FINAL <= IP_HEADER_CKSUM0 + resize(unsigned(IP_ID_D), 18);
			elsif(TX_PACKET_SEQUENCE = "00001") then
				-- carry, first pass
				IP_HEADER_CKSUM_FINAL <= resize(IP_HEADER_CKSUM_FINAL(15 downto 0), 18) + resize(IP_HEADER_CKSUM_FINAL(17 downto 16), 18);
			elsif(TX_PACKET_SEQUENCE = "00010") then
				-- final carry + final inversion
				IP_HEADER_CKSUM_FINAL <= not(resize(IP_HEADER_CKSUM_FINAL(15 downto 0), 18) + resize(IP_HEADER_CKSUM_FINAL(17 downto 16), 18));
			end if;
		end if;
	end if;
end process;

IGMP_CKSUM_001: 	process(CLK)
begin
  if rising_edge(CLK) then
		-- fixed part of the IGMP checksum. 
		if(SYNC_RESET = '1') then
			 IGMP_CKSUM <= resize(unsigned(MULTICAST_IP_ADDR(31 downto 16)),18) + resize(unsigned(MULTICAST_IP_ADDR(15 downto 0)),18);
		elsif(CKSUM_SEQ_CNTR = "11") then
			 IGMP_CKSUM <= IGMP_CKSUM + ("00" & x"1600");
				  -- constant
		elsif(CKSUM_SEQ_CNTR = "10") then
			-- possible carry + final inversion
			IGMP_CKSUM <= not(resize(IGMP_CKSUM(15 downto 0), 18) + resize(IGMP_CKSUM(17 downto 16), 18));
		end if;
	end if;
end process;


--// Test Point
--TP(1) <= IGMP_START;
--TP(2) <= MAC_TX_CTS;
--TP(3) <= MAC_TX_DATA_VALID_E;
--TP(4) <= MAX_TX_EOF_local;
--TP(5) <= RTS_local;

end Behavioral;
