-------------------------------------------------------------
-- MSS copyright 2018
-- Filename:  WHOIS2_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0
-- Date last modified: 7/30/18
-- Inheritance: 	COM-5402 WHOIS2.VHD rev1 8/8/12
--
-- description:  Asks around who is (given IP address) using the 
-- Address Resolution Protocol (ARP) for IPv4 or Neighbor Discovery Protocol (NDP) for IPv6. 10Gb.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity WHOIS2_10G is
	generic (
    IPv6_ENABLED: std_logic := '0'
        -- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
    );
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		
		--// User interface
		WHOIS_IP_ADDR: in std_logic_vector(127 downto 0);
			-- user query: IP address to resolve. read at WHOIS_START
			-- use 32LSbs for IPv4
		WHOIS_IPv4_6n: in std_logic;
		    -- address type IPv4(1) or IPv6(0)
		WHOIS_START: in std_logic;
			-- 1 CLK pulse to start the ARP query
			-- new WHOIS requests will be ignored until the module is 
			-- finished with the previous request/reply transaction. 
		WHOIS_RDY: out std_logic;
			-- always check WHOIS_RDY before requesting a WHOIS transaction with WHOIS_START, otherwise
			-- there is risk that WHOIS is busy and that the request will be ignored.

		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB = REG32) 0x000102030405 (LSB = REG37) 
			-- as transmitted in the Ethernet packet.
        IPv4_ADDR: in std_logic_vector(31 downto 0);
        IPv6_ADDR: in std_logic_vector(127 downto 0);
            -- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
            -- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.

		--// Transmit frame/packet
		MAC_TX_DATA: out std_logic_vector(63 downto 0);
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- one CLK-wide pulse indicating a new word is sent on MAC_TX_DATA
		MAC_TX_EOF: out std_logic;
			-- End of Frame: one CLK-wide pulse indicating the last word in the transmit frame.
 		   -- aligned with MAC_TX_DATA_VALID.
		MAC_TX_CTS: in std_logic;
			-- 1 CLK-wide pulse requesting output samples. Check RTS first.
		RTS: out std_logic;
			-- '1' when a full or partial packet is ready to be read.
			-- '0' when output buffer is empty.
			-- When the user starts reading the output buffer, it is expected that it will be
			-- read until empty.

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of WHOIS2_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal WHOIS_STATE: std_logic := '0';
signal WHOIS_IP_ADDR_D: std_logic_vector(127 downto 0) := (others => '0');
signal DEST_IPv6_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal WHOIS_IPv4_6n_D: std_logic := '0';

--// ICMP CHECKSUM -----------------
signal CKSUM_SEQ_CNTR: unsigned(2 downto 0) := "000";
signal CKSUM_PART1: unsigned(19 downto 0) := (others => '0');
signal CKSUM_PART2: unsigned(19 downto 0) := (others => '0');
signal CKSUM: std_logic_vector(15 downto 0) := (others => '0');

--// ARP request
signal TX_PACKET_SEQUENCE: unsigned(4 downto 0) := (others => '1');  -- 42 bytes max IPv4, ? IPv6
signal MAC_TX_DATA_VALID_E: std_logic := '0';
signal MAC_TX_EOF_local: std_logic := '0';
signal RTS_local: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

DEST_IPv6_ADDR <= x"FF0200000000000000000001FF" & WHOIS_IP_ADDR_D(23 downto 0);

--// Generate ARP/NDP query
ARP_RESP_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_TX_DATA <= (others => '0');
		elsif(WHOIS_IPv4_6n_D = '1') then
		    -- IPv4 address -> send an ARP request. 42 bytes.
			case(TX_PACKET_SEQUENCE) is
				-- Ethernet header
				when "00000" => MAC_TX_DATA <= x"FFFFFFFFFFFF" & MAC_ADDR(47 downto 32);
				    -- destination MAC address: broadcast. fixed at the time of connection establishment.
				when "00001" => MAC_TX_DATA <= MAC_ADDR(31 downto 0) & x"08060001";
				    -- source Ethernet address  +  Ethernet type  + hardware type
				when "00010" => MAC_TX_DATA <= x"080006040001" & MAC_ADDR(47 downto 32);
                    -- protocol type + hardware size, protocol size + op field. ARP request + sender Ethernet address
				when "00011" => MAC_TX_DATA <= MAC_ADDR(31 downto 0) & IPv4_ADDR;
				    -- sender Ethernet address + sender IP address
				when "00100" => MAC_TX_DATA <= x"000000000000" & WHOIS_IP_ADDR_D(31 downto 16);
                    -- target Ethernet address + target IP address
				when "00101" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(15 downto 0) & x"000000000000";
					-- target IP address
				when others => MAC_TX_DATA <= (others => '0'); -- default & trailer	
			end case;
		elsif(IPv6_ENABLED = '1') then
		    -- IPv6 address -> send a Neighbor solicitation message.86 bytes
			case(TX_PACKET_SEQUENCE) is
                -- Ethernet header
                when "00000" => MAC_TX_DATA <= x"3333ff" & WHOIS_IP_ADDR_D(23 downto 0) & MAC_ADDR(47 downto 32);
                    -- destination MAC address: broadcast. fixed at the time of connection establishment.
                when "00001" => MAC_TX_DATA <= MAC_ADDR(31 downto 0) & x"86DD6000";
                    -- source Ethernet address  +  Ethernet type IPv6 + hardware type
                when "00010" => MAC_TX_DATA <= x"000000203AFF" & IPv6_ADDR(127 downto 112);
                    -- payload length (32), next header ICMPv6 (58), hop limit (255), source IP address
                when "00011" => MAC_TX_DATA <= IPv6_ADDR(111 downto 48);
                    -- source IP address
                when "00100" => MAC_TX_DATA <= IPv6_ADDR(47 downto 0) & x"FF02";
                     -- source IP address, destination IP address
                when "00101" => MAC_TX_DATA <= x"0000000000000000";
                    -- destination IP address
                when "00110" => MAC_TX_DATA <= x"0001FF" & WHOIS_IP_ADDR_D(23 downto 0) & x"8700";
                    -- destination IP address, ICMPv6 neighbor solicitation
                when "00111" => MAC_TX_DATA <= CKSUM & x"00000000" & WHOIS_IP_ADDR_D(127 downto 112);
                    -- checksum, target address
                when "01000" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(111 downto 48);
                    -- target address
                when "01001" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(47 downto 0) & x"0101";
                    -- target IP address, ICMPv6 option
                when "01010" => MAC_TX_DATA <= MAC_ADDR & x"0000";
                    -- link layer address
                when others => MAC_TX_DATA <= (others => '0'); -- default & trailer    
            end case;
		    
		end if;
	end if;
end process;

--// ICMP CHECKSUM -----------------
-- The ICMP reply checksum is computed in two parts: one part at reset, based on the IPv6_ADDR and MAC_ADDR. 
-- The second part is computed for each valid received ICMP message.
IPv6ONLY: if(IPv6_ENABLED = '1') generate
    CKSUM_001: 	process(CLK)
    begin
        if rising_edge(CLK) then
            if(SYNC_RESET = '1') then
                CKSUM_SEQ_CNTR <= "101";
            elsif(CKSUM_SEQ_CNTR > 0) then
                CKSUM_SEQ_CNTR <= CKSUM_SEQ_CNTR - 1;
            end if;
        end if;
    end process;
    
    CKSUM_002: 	process(CLK)
    begin
        if rising_edge(CLK) then
            -- fixed part of the checksum is initialized at reset
            if(SYNC_RESET = '1') then
                CKSUM_PART1 <= resize(unsigned(IPv6_ADDR(127 downto 112)),20) + resize(unsigned(IPv6_ADDR(111 downto 96)),20);
            elsif(CKSUM_SEQ_CNTR = "101") then
                CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(95 downto 80)),20) + resize(unsigned(IPv6_ADDR(79 downto 64)),20);
            elsif(CKSUM_SEQ_CNTR = "100") then
                CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(63 downto 48)),20) + resize(unsigned(IPv6_ADDR(47 downto 32)),20);
            elsif(CKSUM_SEQ_CNTR = "011") then
                CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(31 downto 16)),20) + resize(unsigned(IPv6_ADDR(15 downto 0)),20);
            elsif(CKSUM_SEQ_CNTR = "010") then
                CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(MAC_ADDR(47 downto 32)),20) + resize(unsigned(MAC_ADDR(31 downto 16)),20);
            elsif(CKSUM_SEQ_CNTR = "001") then
                CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(MAC_ADDR(15 downto 0)),20) + x"875F";
                    -- constant is the sum of 3A + 20 + 8700 + 0101 + FF02 + 0001 
            end if;
     
            if(MAC_TX_CTS = '1') then
                -- variable part of the checksum depends on the ICMP message originator
                case(TX_PACKET_SEQUENCE) is
                  when "11111" =>
                    CKSUM_PART2 <= CKSUM_PART1 + resize(unsigned(WHOIS_IP_ADDR_D(127 downto 112)),20) + resize(unsigned(WHOIS_IP_ADDR_D(111 downto 96)),20);
                  when "00000" =>
                    CKSUM_PART2 <= CKSUM_PART2 + resize(unsigned(WHOIS_IP_ADDR_D(95 downto 80)),20) + resize(unsigned(WHOIS_IP_ADDR_D(79 downto 64)),20);
                  when "00001" =>
                    CKSUM_PART2 <= CKSUM_PART2 + resize(unsigned(WHOIS_IP_ADDR_D(63 downto 48)),20) + resize(unsigned(WHOIS_IP_ADDR_D(47 downto 32)),20);
                  when "00010" =>
                    CKSUM_PART2 <= CKSUM_PART2 + resize(unsigned(WHOIS_IP_ADDR_D(31 downto 16)),20) + resize(unsigned(WHOIS_IP_ADDR_D(15 downto 0) & "0"),20);    -- the 2 LSBs are summed twice
                  when "00011" =>
                    CKSUM_PART2 <= resize(unsigned(CKSUM_PART2(15 downto 0)),20)  + resize(unsigned(CKSUM_PART2(19 downto 16)),20) + resize(unsigned(DEST_IPv6_ADDR(31 downto 16)),20);
                  when "00100" =>
                    CKSUM_PART2 <= resize(unsigned(CKSUM_PART2(15 downto 0)),20)  + resize(unsigned(CKSUM_PART2(19 downto 16)),20);
                  when others => null;
                end case;
            end if;
        end if;
    end process;
    CKSUM <= std_logic_vector(not CKSUM_PART2(15 downto 0));
end generate;

TX_SEQUENCE_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or ((WHOIS_START = '1') and (WHOIS_STATE = '0')) or (MAC_TX_EOF_local = '1') then	-- *073018
			TX_PACKET_SEQUENCE <= (others => '1');
			MAC_TX_DATA_VALID_E <= '0';
		elsif(WHOIS_STATE = '1') and (MAC_TX_CTS = '1') then
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
            if(WHOIS_IPv4_6n_D = '1') and (TX_PACKET_SEQUENCE = 5) then
                -- IPv4 ARP done. transmitting the last word (42-bytes)
                MAC_TX_DATA_VALID <= x"c0"; -- last word contains only 2 bytes
                MAC_TX_EOF_local <= '1';
             elsif(WHOIS_IPv4_6n_D = '0') and (TX_PACKET_SEQUENCE = 10) then
                -- IPv6 Neighbor solicitation done. transmitting the last word (86-bytes)
                MAC_TX_DATA_VALID <= x"fc"; -- last word contains only 6 bytes
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

-- WHOIS state machine
RTS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS_local <= '0';
			WHOIS_STATE <= '0';
		else
			if(WHOIS_START = '1') and (WHOIS_STATE = '0') then
				-- new transaction. Sending ARP or NDP request
				RTS_local <= '1';
				WHOIS_STATE <= '1';
				-- freeze whois IP address and IPversion
                WHOIS_IP_ADDR_D <= WHOIS_IP_ADDR;
                WHOIS_IPv4_6n_D <= WHOIS_IPv4_6n;
            elsif(MAC_TX_EOF_local = '1') then
				-- done. transmitting the last word
				RTS_local <= '0';
				WHOIS_STATE <= '0';
			end if;
		end if;
	end if;
end process;
RTS <= RTS_local;
WHOIS_RDY <= RTS_local or WHOIS_START;


--// Test Point
TP(1) <= WHOIS_START;
TP(2) <= MAC_TX_CTS;
--TP(3) <= MAC_TX_DATA_VALID_E;
TP(4) <= MAC_TX_EOF_local;
TP(5) <= RTS_local;

end Behavioral;
