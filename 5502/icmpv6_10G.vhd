-------------------------------------------------------------
-- MSS copyright 2018
--	Filename:  ICMPV6_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 3/4/18
-- Inheritance: 	n/a
--
-- description:  ICMPV6 protocol, 10Gb 
-- Reads a received IP/ICMP frame on the fly and generate responses (Ethernet format).
-- Any new received frame is presumed to be a valid ICMPv6 message. Within a few bytes,
-- information is received as to the real protocol associated with the received packet.
-- The ping echo generation is immediately cancelled if 
-- (a) not IPv6
-- (b) invalid target IP (unicast or multicast)
-- (c) not ICMPv6 
-- (d) ICMPv6 type not a neighbor solicitation
-- (e) ICMPv6 solicited IP address does not match 
-- (f) erroneous MAC frame
-- Any follow-on received IP frame is discarded while a valid response awaits transmission in the elastic buffer.
--
-- Device utilization (IPv6_ENABLED='1')
-- FF: 301
-- LUT: 835
-- DSP48: 0
-- 18Kb BRAM: 0
-- BUFG: 1
-- Minimum period: 4.683ns (Maximum Frequency: 213.516MHz)  Artix7-100T -1 speed grade
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ICMPV6_10G is
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
			-- Must be a global clock. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;
			-- CLK-synchronous reset. MANDATORY!

		--// ICMP frame received
		IP_RX_DATA: in std_logic_vector(63 downto 0);
		IP_RX_DATA_VALID: in std_logic_vector(7 downto 0);
		IP_RX_SOF: in std_logic;
		IP_RX_EOF: in std_logic;
		IP_RX_WORD_COUNT: in std_logic_vector(10 downto 0);	

		--// Partial checks (done in PACKET_PARSING common code)
        --// basic IP validity check
        IP_RX_FRAME_VALID: in std_logic; 
            -- The received IP frame is presumed valid until proven otherwise. 
            -- IP frame validity checks include: 
            -- (a) protocol is IP
            -- (b) unicast or multicast destination IP address matches
            -- (c) correct IP header checksum (IPv4 only)
            -- (d) allowed IPv6
            -- (e) Ethernet frame is valid (correct FCS, dest address)
            -- Ready at IP_RX_VALID_D (= MAC_RX_DATA_VALID_D3)
		
		--// Partial checks (done in PACKET_PARSING common code)
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
			-- Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);  	-- IPv4,IPv6,ARP
		
		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
		
		--// IP type: 
		RX_IPv4_6n: in std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- read between RX_IP_PROTOCOL_RDY (inclusive)(i.e. before IP_PAYLOAD_SOF) and IP_PAYLOAD_EOF (inclusive)
			-- most common protocols: 
			-- 0 = unknown, 1 = ICMP, 2 = IGMP, 6 = TCP, 17 = UDP, 41 = IPv6 encapsulation, 
            -- 58 = ICMPv6, 89 = OSPF, 132 = SCTP
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

architecture Behavioral of ICMPV6_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
--// STATE MACHINE ------------------
signal STATE: unsigned(0 downto 0) := (others => '0');
signal INPUT_ENABLED: std_logic := '1';
signal IP_RX_WORD_VALID: std_logic := '0';
signal IP_RX_EOF_D: std_logic := '0';

--// VALIDATE ICMP MESSAGE -----------
signal VALID_ICMP_MSG0: std_logic := '0';
signal VALID_ICMP_MSG: std_logic := '0';
signal NEIGHBOR_SOLICITATION_FLAG: std_logic := '0';
signal ECHO_REQUEST_FLAG: std_logic := '0';
signal VALID_NEIGHBOR_SOLICITATION_MSG: std_logic := '0';
--signal VALID_ECHO_REQUEST_MSG: std_logic := '0';
signal RX_SOURCE_MAC_ADDR0: std_logic_vector(47 downto 0) := (others => '0');
signal RX_SOURCE_IP_ADDR0: std_logic_vector(127 downto 0) := (others => '0');
signal REPLY_CHECKSUM: unsigned(15 downto 0) := (others => '0');

--// ICMP CHECKSUM -----------------
signal CKSUM_SEQ_CNTR: unsigned(2 downto 0) := "000";
signal CKSUM_PART1: unsigned(19 downto 0) := (others => '0');
signal CKSUM_PART2: unsigned(19 downto 0) := (others => '0');

--// ICMP REPLY -----------------
signal MAC_TX_EOF_local: std_logic := '0';
signal RPTR: unsigned(5 downto 0) := (others => '0');	-- range 0 - 10
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// STATE MACHINE ------------------
-- A state machine is needed as this process is memoryless.
-- State 0 = idle or incoming packet being processed. No tx packet waiting.
-- State 1 = valid ICMP request. tx packet waiting for tx capacity. Incoming packets are ignored.
STATE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE <= (others => '0');
		elsif(IP_RX_EOF_D = '1') and (INPUT_ENABLED = '1') and (VALID_NEIGHBOR_SOLICITATION_MSG = '1') then
			-- event = valid ICMP message. Ready to send reply when tx channel opens.
			-- In the mean time, incoming packets are ignored.
			STATE <= "1";
		elsif(MAC_TX_EOF_local = '1') then
			-- event = successfully sent ICMP reply. Reopen input
			STATE <= "0";
		end if;
	end if;
end process;

INPUT_ENABLED <= '1' when (STATE = 0) else '0';

--// VALIDATE ICMP MESSAGE -----------
IP_RX_WORD_VALID <= '1' when (unsigned(IP_RX_DATA_VALID) /= 0) else '0';

VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		IP_RX_EOF_D <= IP_RX_EOF;
		
		if(INPUT_ENABLED = '1')  then
            if(IP_RX_SOF = '1') then
                -- just received first byte. ICMP message valid until proven otherwise
                VALID_ICMP_MSG0 <= '1';
            else
                if(RX_IPv4_6n = '1') then
                    -- (a) not IPv6
                    VALID_ICMP_MSG0 <= '0';
                end if;
                if(RX_IP_PROTOCOL_RDY = '1') and (unsigned(RX_IP_PROTOCOL) /= 58) then
                    -- (c) not ICMPv6 
                     VALID_ICMP_MSG0 <= '0';
                end if;
            end if;
		end if;
	end if;
end process;
VALID_ICMP_MSG <= VALID_ICMP_MSG0 and IP_RX_FRAME_VALID;   -- combine with the other checks done in parsing.vhd

-- Neighbor solicitation flag
VALIDITY_CHECK_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(INPUT_ENABLED = '1') and (IP_RX_SOF = '1') then
			NEIGHBOR_SOLICITATION_FLAG <= '1';
        elsif(INPUT_ENABLED = '1') and (IP_RX_WORD_VALID = '1') then
            if (unsigned(IP_RX_WORD_COUNT) = 6)  and (IP_RX_DATA(63 downto 48) /= x"8700") then
                -- (e) ICMPv6 type not a neighbor solicitation
                NEIGHBOR_SOLICITATION_FLAG <= '0';
            end if;
        end if;
	end if;
end process;
VALID_NEIGHBOR_SOLICITATION_MSG <= VALID_ICMP_MSG and NEIGHBOR_SOLICITATION_FLAG;

---- Echo (ping) request flag (Note: implemented in PING.VHD)
--VALIDITY_CHECK_003: process(CLK)
--begin
--	if rising_edge(CLK) then
--		if(INPUT_ENABLED = '1') and (IP_RX_SOF = '1') then
--			ECHO_REQUEST_FLAG <= '1';
--        elsif(INPUT_ENABLED = '1') and (IP_RX_WORD_VALID = '1') and (unsigned(IP_RX_WORD_COUNT) = 6)  and (IP_RX_DATA(63 downto 48) /= x"8000") then
--            -- (d) ICMPv6 type not an echo request
--            ECHO_REQUEST_FLAG <= '0';
--        end if;
--	end if;
--end process;
--VALID_ECHO_REQUEST_MSG <= VALID_ICMP_MSG and ECHO_REQUEST_FLAG;

--// freeze source MAC address and source IP address at the end of the packet 
-- Reason: we don't want subsequent packets to change this information while we are waiting
-- to send the ICMP reply.
FREEZE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_SOURCE_MAC_ADDR0 <= (others => '0');
			RX_SOURCE_IP_ADDR0 <= (others => '0');
	  	elsif(IP_RX_EOF = '1') and (INPUT_ENABLED = '1') then
			RX_SOURCE_MAC_ADDR0 <= RX_SOURCE_MAC_ADDR;
			RX_SOURCE_IP_ADDR0 <= RX_SOURCE_IP_ADDR;
	 	end if;
	end if;
end process;
	
--// ICMP CHECKSUM -----------------
-- The ICMP reply checksum is computed in two parts: one part at reset, based on the IPv6_ADDR and MAC_ADDR. 
-- The second part is computed for each valid received ICMP message.
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
			CKSUM_PART1 <= resize(unsigned(IPv6_ADDR(127 downto 112)& "0"),20) + resize(unsigned(IPv6_ADDR(111 downto 96)& "0"),20);
		elsif(CKSUM_SEQ_CNTR = "101") then
            CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(95 downto 80)& "0"),20) + resize(unsigned(IPv6_ADDR(79 downto 64)& "0"),20);
		elsif(CKSUM_SEQ_CNTR = "100") then
            CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(63 downto 48)& "0"),20) + resize(unsigned(IPv6_ADDR(47 downto 32)& "0"),20);
		elsif(CKSUM_SEQ_CNTR = "011") then
            CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(31 downto 16)& "0"),20) + resize(unsigned(IPv6_ADDR(15 downto 0)& "0"),20);
		elsif(CKSUM_SEQ_CNTR = "010") then
            CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(MAC_ADDR(47 downto 32)),20) + resize(unsigned(MAC_ADDR(31 downto 16)),20);
		elsif(CKSUM_SEQ_CNTR = "001") then
            CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(MAC_ADDR(15 downto 0)),20) + x"EA5B";
                -- constant is the sum of 3A + 20 + 8800 + 6000 + 0201 
        end if;
 
		if(MAC_TX_CTS = '1') then
		    -- variable part of the checksum depends on the ICMP message originator
		    case(RPTR) is
		      when "000001" =>
                CKSUM_PART2 <= CKSUM_PART1 + resize(unsigned(RX_SOURCE_IP_ADDR0(127 downto 112)),20) + resize(unsigned(RX_SOURCE_IP_ADDR0(111 downto 96)),20);
		      when "000010" =>
                CKSUM_PART2 <= CKSUM_PART2 + resize(unsigned(RX_SOURCE_IP_ADDR0(95 downto 80)),20) + resize(unsigned(RX_SOURCE_IP_ADDR0(79 downto 64)),20);
		      when "000011" =>
                CKSUM_PART2 <= CKSUM_PART2 + resize(unsigned(RX_SOURCE_IP_ADDR0(63 downto 48)),20) + resize(unsigned(RX_SOURCE_IP_ADDR0(47 downto 32)),20);
              when "000100" =>
                CKSUM_PART2 <= CKSUM_PART2 + resize(unsigned(RX_SOURCE_IP_ADDR0(31 downto 16)),20) + resize(unsigned(RX_SOURCE_IP_ADDR0(15 downto 0)),20);
              when "000101" =>
                CKSUM_PART2 <= resize(unsigned(CKSUM_PART2(15 downto 0)),20)  + resize(unsigned(CKSUM_PART2(19 downto 16)),20);
              when "000110" =>
                CKSUM_PART2 <= resize(unsigned(CKSUM_PART2(15 downto 0)),20)  + resize(unsigned(CKSUM_PART2(19 downto 16)),20);
              when others => null;
            end case;
	 	end if;
	end if;
end process;
REPLY_CHECKSUM <= not CKSUM_PART2(15 downto 0);
	
--// ICMP REPLY -----------------
--// Generate ICMP reply packet on the fly
ICMP_RESP_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_TX_DATA <= (others => '0');
			MAC_TX_DATA_VALID <= (others => '0');
			MAC_TX_EOF_local <= '0';
		elsif(MAC_TX_CTS = '1') and (RPTR <= 10) then
			case(RPTR) is
				
				when "000000" => 
					MAC_TX_DATA(63 downto 16) <= RX_SOURCE_MAC_ADDR0;
					-- destination ethernet address
					MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
					-- our Ethernet address (2 MSBs)
					MAC_TX_DATA_VALID <= x"FF";
				when "000001" => 
					MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);
					-- our Ethernet address (4 LSBs)
					MAC_TX_DATA(31 downto 0) <= x"86DD6000";
					-- Ethernet type, hardware type IPv6
					MAC_TX_DATA_VALID <= x"FF";
				when "000010" => 
					MAC_TX_DATA(63 downto 16) <= x"000000203aff";
					-- ICMPv6,32 bytes header length, hop
					MAC_TX_DATA(15 downto 0) <= IPv6_ADDR(127 downto 112);
					-- our source IPv6 address (2 MSBs)
					MAC_TX_DATA_VALID <= x"FF";
				when "000011" => 
					MAC_TX_DATA <= IPv6_ADDR(111 downto 48);
					-- our source IPv6 address (cont'd)
					MAC_TX_DATA_VALID <= x"FF";
				when "000100" => 
					MAC_TX_DATA(63 downto 16) <= IPv6_ADDR(47 downto 0);
                    -- our source IPv6 address (LSBs)
					MAC_TX_DATA(15 downto 0) <= RX_SOURCE_IP_ADDR0(127 downto 112);	
					-- target IP address (2 MSBs)
					MAC_TX_DATA_VALID <= x"FF";
				when "000101" => 
					MAC_TX_DATA <= RX_SOURCE_IP_ADDR0(111 downto 48);    
					-- target IP address (cont'd)
					MAC_TX_DATA_VALID <= x"FF";
				 when "000110" => 
					MAC_TX_DATA(63 downto 16) <= RX_SOURCE_IP_ADDR0(47 downto 0);    
					-- target IP address (LSBs)
					MAC_TX_DATA(15 downto 0) <= x"8800";   
					-- neighbor advertisement message, code 0
					MAC_TX_DATA_VALID <= x"FF";
				 when "000111" => 
					MAC_TX_DATA(63 downto 48) <= std_logic_vector(REPLY_CHECKSUM);    
					-- checksum
					MAC_TX_DATA(47 downto 16) <= x"60000000";
					-- router flag = 0, solicited flag = 1, overide cache entry = 1
					MAC_TX_DATA(15 downto 0) <=  IPv6_ADDR(127 downto 112);
					-- target address
					MAC_TX_DATA_VALID <= x"FF";
				when "001000" => 
					MAC_TX_DATA <= IPv6_ADDR(111 downto 48);    
					-- target IP address (cont'd)
					MAC_TX_DATA_VALID <= x"FF";
				when "001001" => 
					MAC_TX_DATA(63 downto 16) <= IPv6_ADDR(47 downto 0);    
					-- target IP address (LSBs)
					MAC_TX_DATA(15 downto 0) <=  x"0201";
						-- target link layer address, length 8 bytes
					MAC_TX_DATA_VALID <= x"FF";
				when "001010" => 
					MAC_TX_DATA(63 downto 16) <= MAC_ADDR;
					MAC_TX_DATA(15 downto 0) <=  x"0000";
					-- our Ethernet address 
					MAC_TX_DATA_VALID <= x"FC";
					MAC_TX_EOF_local <= '1';
				when others => 
					MAC_TX_DATA <= (others => '0');	
					MAC_TX_DATA_VALID <= x"00";
					MAC_TX_EOF_local <= '0';
			end case;
		else
			MAC_TX_DATA_VALID <= x"00";
			MAC_TX_EOF_local <= '0';
		end if;
	end if;
end process;
MAC_TX_EOF <= MAC_TX_EOF_local;

--// Sequence reply transmission and Flow control 
-- Request to send when ICMP reply is ready.
RTS_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS <= '0';
			RPTR <= (others => '0');
		elsif(IP_RX_EOF_D = '1') and (INPUT_ENABLED = '1') and (VALID_NEIGHBOR_SOLICITATION_MSG = '1') then
			-- Valid  & complete ICMP neighbor solicitation was received. Start reply transmission.
			RTS <= '1';	-- tell MAC we have a packet to send
			RPTR <= (others => '0');	
		elsif(MAC_TX_CTS = '1') and (RPTR < 10) then
			-- Assemble reply on the fly. 
			-- Always Ethernet encapsulation
			RPTR <= RPTR + 1;	-- move read pointer in response to read request
		elsif(MAC_TX_CTS = '1') and (RPTR = 10) then
			RPTR <= RPTR + 1;	-- move read pointer in response to read request
			RTS <= '0';
		end if;
	end if;
end process;

--// TEST POINTS --------------------------
TP(1) <= STATE(0);
TP(2) <= IP_RX_WORD_VALID;
TP(3) <= VALID_NEIGHBOR_SOLICITATION_MSG;
TP(4) <= MAC_TX_EOF_local;
TP(5) <= MAC_TX_CTS;
TP(6) <= RPTR(0);



end Behavioral;
