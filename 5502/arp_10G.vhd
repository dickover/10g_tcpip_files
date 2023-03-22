-------------------------------------------------------------
-- MSS copyright 2003-2020
--	Filename:  ARP_10G.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 9/24/20
-- Inheritance: 	ARP_10G.VHD version 2, 12/10/15
--
-- description:  Address resolution protocol, 10GbE version
-- Reads receive packet structure on the fly and generates an ARP reply.
-- Any new received packet is presumed to be an ARP request. Within a few bytes,
-- information is received as to the real protocol associated with the received packet.
-- The ARP reply generation is immediately cancelled if 
-- (a) the received packet type is not an ARP request/reply
-- (b) the Opcode does not indicate an ARP request
-- (c) the IP address does not match
-- (d) erroneous MAC frame
-- Supports only Ethernet (IEEE 802.3) encapsulation
-- ARP only applies to IPv4. For IPv6, use neighbour discovery protocol instead.
-- Any follow-on received MAC frame is discarded while a valid ARP response awaits transmission in the elastic buffer.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ARP_10G is
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
			-- Must be a global clock. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;

		--// Packet/Frame received
		MAC_RX_DATA: in std_logic_vector(63 downto 0);
			-- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID /= 0
			-- Bytes order: MSB was received first
			-- Bytes are left aligned: first byte in MSB, occasional follow-on fill-in Bytes in the LSB(s)
			-- The first destination address byte is always a MSB (MAC_RX_DATA(7:0))
		MAC_RX_DATA_VALID: in std_logic_vector(7 downto 0);
			-- data valid, for each byte in MAC_RX_DATA
		MAC_RX_SOF: in std_logic;
			-- '1' when sending the first byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_EOF: in std_logic;
			-- '1' when sending the last byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_FRAME_VALID: in std_logic;
			-- MAC frame integrity verification (at the end of frame)
		MAC_RX_WORD_COUNT: in std_logic_vector(10 downto 0);
			-- MAC word counter, 1 CLK after the input. 0 is the first word.

		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
			-- local IP address. 4 bytes for IPv4 only
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.

		--// Received type
		RX_TYPE: in std_logic_vector(3 downto 0);
			-- Information stays until start of following packet.
			-- Only one valid types: 
			-- 2 = Ethernet encapsulation, ARP request/reply
	  	RX_TYPE_RDY: in std_logic;
			-- 1 CLK-wide pulse indicating that a detection was made on the received packet
			-- type, and that RX_TYPE can be read.
			-- Detection occurs as soon as possible, two clocks after receiving byte 13 or 21.

		--// Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0);	-- IPv4 only

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

architecture Behavioral of ARP_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--// STATE MACHINE ------------------
signal STATE: unsigned(0 downto 0) := (others => '0');
signal INPUT_ENABLED: std_logic := '1';
signal MAC_RX_DATA_VALID_D: std_logic_vector(7 downto 0) := (others => '0');
signal MAC_RX_SOF_D: std_logic := '0';
signal MAC_RX_EOF_D: std_logic := '0';
signal MAC_RX_DATA_D: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_RX_WORD_VALID_D: std_logic := '0';
signal MAC_RX_EOF_D2: std_logic := '0';

--// VALIDATE ARP REQUEST -----------
signal VALID_ARP_REQ: std_logic := '0';
signal RX_SOURCE_MAC_ADDR0: std_logic_vector(47 downto 0) := (others => '0');
signal RX_SOURCE_IP_ADDR0: std_logic_vector(31 downto 0) := (others => '0');

--// ARP REPLY -----------------
signal MAC_TX_EOF_local: std_logic := '0';
signal RPTR: unsigned(5 downto 0) := (others => '0');	-- range 0 - 41
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// STATE MACHINE ------------------
-- A state machine is needed as this process is memoryless.
-- State 0 = idle or incoming packet being processed. No tx packet waiting.
-- State 1 = valid ARP request. tx packet waiting for tx capacity. Incoming packets are ignored.
STATE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE <= (others => '0');
		elsif(MAC_RX_EOF_D2 = '1') and (VALID_ARP_REQ = '1') then
			-- event = valid ARP request. Ready to send ARP reply when tx channel opens.
			-- In the mean time, incoming packets are ignored.
			STATE <= "1";
		elsif(MAC_TX_EOF_local = '1') then
			-- event = successfully sent ARP reply. Reopen input
			STATE <= "0";
		end if;
	end if;
end process;

INPUT_ENABLED <= '1' when (STATE = 0) else '0';

STATE_GEN_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_RX_DATA_D <= (others => '0');
			MAC_RX_DATA_VALID_D <= (others => '0');
			MAC_RX_SOF_D <= '0';
			MAC_RX_EOF_D <= '0';
			MAC_RX_WORD_VALID_D <= '0';
			-- reclock data and sample clock so that they are aligned with the word count.
		elsif(INPUT_ENABLED = '0') then
			-- we still waiting to send the last ARP reply. Ignore any incoming packets until transmission is complete.
			MAC_RX_DATA_D <= (others => '0');
			MAC_RX_DATA_VALID_D <= (others => '0');
			MAC_RX_SOF_D <= '0';
			MAC_RX_EOF_D <= '0';
			MAC_RX_WORD_VALID_D <= '0';
		else
			MAC_RX_DATA_D <= MAC_RX_DATA;
			MAC_RX_DATA_VALID_D <= MAC_RX_DATA_VALID;
			MAC_RX_SOF_D <= MAC_RX_SOF;
			MAC_RX_EOF_D <= MAC_RX_EOF;
			if(unsigned(MAC_RX_DATA_VALID) /= 0) then
				MAC_RX_WORD_VALID_D <= '1';
			else
				MAC_RX_WORD_VALID_D <= '0';
			end if;
		end if;
	end if;
end process;
--
--// VALIDATE ARP REQUEST -----------
-- The ARP reply generation is immediately cancelled if 
-- (a) the received packet type is not an ARP request/reply
-- (b) the Opcode does not indicate an ARP request
-- (c) the IP address does not match
-- (d) erroneous MAC frame
-- VALID_ARP_REQ is ready at MAC_RX_EOF_D2
VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			VALID_ARP_REQ <= '1';
			MAC_RX_EOF_D2 <= '0';
		else
			MAC_RX_EOF_D2 <= MAC_RX_EOF_D;
			
			if(MAC_RX_SOF_D = '1') then
				-- just received first byte. ARP request valid until proven otherwise
				VALID_ARP_REQ <= '1';
			elsif(MAC_RX_EOF = '1') and (MAC_RX_FRAME_VALID = '0') then
				-- (d) erroneous MAC frame
				VALID_ARP_REQ <= '0';
			elsif(MAC_RX_EOF_D = '1') and (unsigned(RX_TYPE) /= 2) then
				-- (a) the received packet type is not an ARP request/reply
				VALID_ARP_REQ <= '0';
			elsif (MAC_RX_WORD_VALID_D = '1') and (unsigned(MAC_RX_WORD_COUNT) = 1) then
				if (MAC_RX_DATA_D(15 downto 0) /= x"0001") then
					-- unexpected hardware type
					VALID_ARP_REQ <= '0';
				end if;
			elsif (MAC_RX_WORD_VALID_D = '1') and (unsigned(MAC_RX_WORD_COUNT) = 2) then
				if (MAC_RX_DATA_D(63 downto 32) /= x"08000604") then
					-- unexpected protocol type, hardware length or protocol length
					VALID_ARP_REQ <= '0';
				end if;
				if (MAC_RX_DATA_D(23 downto 16) /= x"01") then
                    -- (b) op field does not indicate ARP request
                    VALID_ARP_REQ <= '0';
                end if;
			elsif (MAC_RX_WORD_VALID_D = '1') and (unsigned(MAC_RX_WORD_COUNT) = 4) then
				if(MAC_RX_DATA_VALID_D(1 downto 0) /= "11")  or (MAC_RX_DATA_D(15 downto 0) /= IPv4_ADDR(31 downto 16)) then
					-- (c) Target IP address does not match
					VALID_ARP_REQ <= '0';
				end if;
			elsif (MAC_RX_WORD_VALID_D = '1')  and (unsigned(MAC_RX_WORD_COUNT) = 5) then
				if(MAC_RX_DATA_VALID_D(7 downto 6) /= "11")  or (MAC_RX_DATA_D(63 downto 48) /= IPv4_ADDR(15 downto 0)) then
					-- (c) Target IP address does not match
					VALID_ARP_REQ <= '0';
				end if;
			end if;
		end if;
	end if;
end process;

--// freeze source MAC address and source IP address at the end of the packet 
-- Reason: we don't want subsequent packets to change this information while we are waiting
-- to send the ARP reply.
FREEZE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_SOURCE_MAC_ADDR0 <= (others => '0');
			RX_SOURCE_IP_ADDR0 <= (others => '0');
	  	elsif(MAC_RX_EOF = '1') and (STATE = 0) then
			RX_SOURCE_MAC_ADDR0 <= RX_SOURCE_MAC_ADDR;
			RX_SOURCE_IP_ADDR0 <= RX_SOURCE_IP_ADDR;
	 	end if;
	end if;
end process;
	
--// ARP REPLY -----------------
--// Generate ARP reply packet on the fly
ARP_RESP_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_TX_DATA <= (others => '0');
			MAC_TX_DATA_VALID <= (others => '0');
			MAC_TX_EOF_local <= '0';
		elsif(MAC_TX_CTS = '1') and (RPTR <= 6) then
			case(RPTR) is
				-- destination Ethernet address
				when "000000" => 
					MAC_TX_DATA(63 downto 16) <= RX_SOURCE_MAC_ADDR0;
					-- source Ethernet address 
					MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
					-- our Ethernet address (2 MSBs)
					MAC_TX_DATA_VALID <= x"FF";
				when "000001" => 
					MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);
					-- our Ethernet address (4 LSBs)
					MAC_TX_DATA(31 downto 0) <= x"08060001";
					-- Ethernet type, hardware type
					MAC_TX_DATA_VALID <= x"FF";
				when "000010" => 
					MAC_TX_DATA(63 downto 16) <= x"080006040002";
					-- protocol type
					-- hardware size, protocol size
					-- op field. ARP reply
					MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
					-- source Ethernet address (2 MSBs)
					MAC_TX_DATA_VALID <= x"FF";
				when "000011" => 
					MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);
					-- our Ethernet address (4 LSBs)
					MAC_TX_DATA(31 downto 0) <= IPv4_ADDR(31 downto 0);
					-- sender IP address
					MAC_TX_DATA_VALID <= x"FF";
				when "000100" => 
					MAC_TX_DATA(63 downto 16) <= RX_SOURCE_MAC_ADDR0;
					-- destination Ethernet address
					MAC_TX_DATA(15 downto 0) <= RX_SOURCE_IP_ADDR0(31 downto 16);	
					-- target IP address (2 MSBs)
					MAC_TX_DATA_VALID <= x"FF";
				when "000101" => 
					MAC_TX_DATA(63 downto 48) <= RX_SOURCE_IP_ADDR0(15 downto 0);	
					-- target IP address (2 LSBs)
					MAC_TX_DATA(47 downto 0) <= (others => '0');	
					MAC_TX_DATA_VALID <= x"C0";
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
-- Request to send when ARP reply is ready.
RTS_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS <= '0';
			RPTR <= (others => '0');
		elsif(STATE = 0) and (MAC_RX_EOF_D2 = '1') and (VALID_ARP_REQ = '1') then
			-- Valid  & complete ARP request was received. Start reply transmission.
			RTS <= '1';	-- tell MAC we have a packet to send
			RPTR <= (others => '0');	
		elsif(MAC_TX_CTS = '1') and (RPTR < 5) then
			-- Assemble reply on the fly. 
			-- Always Ethernet encapsulation
			RPTR <= RPTR + 1;	-- move read pointer in response to read request
		elsif(MAC_TX_CTS = '1') and (RPTR = 5) then
			RPTR <= RPTR + 1;	-- move read pointer in response to read request
			RTS <= '0';
		end if;
	end if;
end process;


--// Test Point
TP(1) <= MAC_RX_SOF_D;
TP(2) <= MAC_RX_WORD_VALID_D;
TP(3) <= STATE(0);
TP(4) <= VALID_ARP_REQ;
--TP(5) <= '1' when (unsigned(RX_TYPE) = 2) else '0';
--TP(6) <= RPTR(0);
TP(5) <= '1' when (IPv4_ADDR = x"A9FE5080") else '0';
TP(6) <= MAC_TX_EOF_local;
TP(10 downto 7) <= (others => '0');


end Behavioral;
