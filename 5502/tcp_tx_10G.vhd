-------------------------------------------------------------
-- MSS copyright 2018-2021
-- Filename:  TCP_TX_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 2
-- Date last modified: 1/18/21
-- Inheritance: 	COM-5402 (1G) TCP_TX.VHD rev2 12/10/15
--
-- description:  Sends a TCP packet, including the IP and MAC headers. 10Gbits/s.
-- All input information is available at the time of the transmit trigger.
--
-- Device utilization (MSS = 1460, IPv6_ENABLED='1')
-- FF: 681
-- LUT: 1331
-- DSP48: 0
-- 18Kb BRAM: 0
-- BUFG: 1
-- Minimum period: 6.408ns (Maximum Frequency: 156.055MHz) Artix7-100T -1 speed grade
--
-- Rev 1 1/18/20 AZ
-- corrected bug in the TCP option field (MSS size)
--
-- Rev 2 1/18/21 AZ
-- Added TCP option for window scaling
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity TCP_TX_10G is
	generic (
		IPv6_ENABLED: std_logic := '1'
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;	
			-- Must be a global clock. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;
			-- CLK-synchronous reset. MANDATORY!

		--// CONFIGURATION PARAMETERS
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);


		--// INPUT: HEADERS
		TX_PACKET_SEQUENCE_START: in std_logic;	
			-- 1 CLK pulse to trigger packet transmission. The decision to transmit is taken by TCP_SERVER.
			-- From this trigger pulse to the end of frame, this component assembles and send data bytes
			-- like clockwork. 
			-- Note that the payload data has to be ready at exactly the right time to be appended.
			
		-- These variables MUST be fixed at the start of packet and not change until the transmit EOF.
		-- They can change from packet to packet (internal code is entirely memoryless).
		TX_DEST_MAC_ADDR_IN: in std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_IN: in std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_IN: in std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_IN: in std_logic_vector(15 downto 0);
		TX_IPv4_6n_IN: in std_logic;
		TX_SEQ_NO_IN: in std_logic_vector(31 downto 0);
		TX_ACK_NO_IN: in std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_IN: in std_logic_vector(15 downto 0);
		IP_ID_IN: in std_logic_vector(15 downto 0);
			-- 16-bit IP ID, unique for each datagram. Incremented every time
			-- an IP datagram is sent (not just for this socket).
		TX_FLAGS_IN: in std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_IN : in std_logic_vector(1 downto 0);
			-- 0 = undefined
			-- 1 = SYN, no data, 28-byte header
			-- 2 = ACK, no data, 20-byte header
			-- 3 = payload data, 20-byte header
		TX_WINDOW_SCALE_IN: in std_logic_vector(3 downto 0);

		--// INPUT: EXTERNAL TX BUFFER -> TX TCP PAYLOAD
		TX_PAYLOAD_DATA: in std_logic_vector(63 downto 0);
			-- TCP payload data field when TX_PAYLOAD_DATA_VALID = '1'
		TX_PAYLOAD_DATA_VALID: in std_logic_vector(7 downto 0);
		TX_PAYLOAD_WORD_VALID: in std_logic;
			-- delineates the TCP payload data field
		TX_PAYLOAD_DATA_EOF: in std_logic;
			-- End Of Frame. 1 CLK-wide pulse aligned with TX_PAYLOAD_DATA_VALID
		TX_PAYLOAD_RTS: in std_logic;  
			-- '1' to tell TX TCP layer that the application has a packet ready to send
			-- Must stay high at least until TX_CTS goes high, but not beyond TX_EOF.
		TX_PAYLOAD_CTS: out std_logic;
			-- clear to send. 2 CLK latency until 1st data byte is available at TX_PAYLOAD_DATA
		TX_PAYLOAD_SIZE: in std_logic_vector(15 downto 0);
			-- packet size (TCP payload data only). valid (and fixed) while TX_RTS = '1'.
		TX_PAYLOAD_CHECKSUM: in std_logic_vector(17 downto 0);
			-- partial TCP checksum computation. payload only, no header. bits 17:16 are the carry, add later.
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise


		--// OUTPUT: TX TCP layer -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended by MAC. Not supplied here.
		-- Synchonous with the user-side CLK
		MAC_TX_DATA: out std_logic_vector(63 downto 0) := (others => '0');
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
		MAC_TX_DATA_VALID: out std_logic_vector(7 downto 0) := x"00";
			-- data valid
		MAC_TX_EOF: out std_logic := '0';
			-- '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal, indicating room in the 
			-- MAC tx elastic buffer for a complete maximum size frame 1518B. 
			-- The user should check that this signal is high before deciding to send
			-- sending the next frame. 
			-- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it as space is guaranteed
			-- at the start of frame.
		MSSv4: in std_logic_vector(13 downto 0);
    MSSv6: in std_logic_vector(13 downto 0);
			-- The Maximum Segment Size (MSS) is the largest segment of TCP data that can be transmitted.
    -- Fixed as the Ethernet MTU (Maximum Transmission Unit) of 1500-9000 bytes - 40(IPv4) or -60(IPv6) overhead bytes 

--		-- Test Points
	TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_TX_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--//---- FREEZE INPUTS -----------------------
signal TX_DEST_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal TX_DEST_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal TX_DEST_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TX_SOURCE_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TX_IPv4_6n: std_logic := '0';
signal TX_TCP_HEADER_LENGTH: unsigned(3 downto 0) := (others => '0');	-- in 32-bit words
--signal TX_TCP_HEADER_LENGTH_DEC: unsigned(3 downto 0) := (others => '0');	-- in 32-bit words
signal TX_TCP_PAYLOAD_SIZE: std_logic_vector(15 downto 0) := (others => '0');	-- TCP payload size in bytes.
signal TX_SEQ_NO: std_logic_vector(31 downto 0) := (others => '0');
signal TX_ACK_NO: std_logic_vector(31 downto 0) := (others => '0');
signal TX_ACK_WINDOW_LENGTH: std_logic_vector(15 downto 0) := (others => '0');
signal IP_ID: std_logic_vector(15 downto 0) := (others => '0');
signal TX_FLAGS: std_logic_vector(7 downto 0) := (others => '0');
signal TX_PACKET_TYPE:  unsigned(1 downto 0) := (others => '0');
signal TX_WINDOW_SCALE: std_logic_vector(3 downto 0) := (others => '0');

--// TX IP HEADER CHECKSUM ---------------------------------------------
signal TX_PACKET_SEQUENCE_START_SHIFT: std_logic_vector(7 downto 0) := (others => '0');
signal CKSUM_PART1: unsigned(18 downto 0) := (others => '0');
signal CKSUM_SEQ_CNTR: unsigned(2 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM0: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM_PLUS: unsigned(17 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM_FINAL: std_logic_vector(15 downto 0) := (others => '0');

--//-- TCP TX CHECKSUM  ---------------------------
signal CKSUM4: unsigned(17 downto 0) := (others => '0');
signal CKSUM5: unsigned(17 downto 0) := (others => '0');
signal CKSUM6: unsigned(17 downto 0) := (others => '0');
signal CKSUM7: unsigned(17 downto 0) := (others => '0');
signal CKSUM8: unsigned(17 downto 0) := (others => '0');
signal CKSUM_CARRY2: unsigned(3 downto 0) := (others => '0');
signal CKSUM_CARRY4: unsigned(3 downto 0) := (others => '0');
signal TCP_CHECKSUM: unsigned(15 downto 0) := (others => '0');

--//---- TX PACKET ASSEMBLY   ----------------------
signal TX_PAYLOAD_CTS_FLAG: std_logic := '0';
signal TCP_HEADER_BYTE12_13: std_logic_vector(15 downto 0) := (others => '0');
signal TX_PAYLOAD_DATA_PREVIOUS: std_logic_vector(63 downto 0) := (others => '0');
signal TX_PAYLOAD_DATA_VALID_PREVIOUS: std_logic_vector(7 downto 0) := (others => '0');
signal TX_PAYLOAD_DATA_EOF_PREVIOUS: std_logic := '0';
signal MAC_TX_CTS_D: std_logic := '0';
signal MAC_TX_CTS_D2: std_logic := '0';
signal TX_PAYLOAD_CTS_FLAG0: std_logic := '0';
signal TX_ACTIVE0: std_logic := '0';
signal TX_ACTIVE: std_logic := '0';
signal TX_WORD_COUNTER: unsigned(10 downto 0) := (others => '0'); 
signal TX_WORD_COUNTER_D: unsigned(10 downto 0) := (others => '0'); 
signal MAC_TX_WORD_VALID_E2: std_logic := '0';
signal MAC_TX_WORD_VALID_E: std_logic := '0';
signal MAC_TX_WORD_VALID: std_logic := '0';

signal MAC_TX_EOF_local: std_logic := '0';
signal TX_TCP_LAST_HEADER_BYTE: std_logic := '0';
signal TX_IP_LENGTH: unsigned(15 downto 0) := (others => '0');

signal MAC_TX_DATA_D:  std_logic_vector(7 downto 0) := (others => '0');

--// TX TCP CHECKSUM ---------------------------------------------
--signal TX_TCP_HEADER_D: std_logic := '0';
--signal TX_TCP_CKSUM_DATA: std_logic_vector(15 downto 0) := (others => '0');
--signal TX_TCP_CKSUM_FLAG: std_logic := '0';
--signal TX_TCP_CHECKSUM: unsigned(16 downto 0) := (others => '0');
--signal TX_TCP_CHECKSUM_FINAL: unsigned(15 downto 0) := (others => '0');
signal TX_TCP_LENGTH: unsigned(15 downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--//---- FREEZE INPUTS -----------------------
-- Latch in all key fields at the start trigger
FREEZE_KEY_FIELDS_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- Freeze parameters which can change 
			-- while we are sending the TCP packet to the MAC layer
			TX_DEST_MAC_ADDR <= TX_DEST_MAC_ADDR_IN;	
			TX_DEST_IP_ADDR <= TX_DEST_IP_ADDR_IN;	
			TX_DEST_PORT_NO <= TX_DEST_PORT_NO_IN;	
			TX_SOURCE_PORT_NO <= TX_SOURCE_PORT_NO_IN;
			TX_IPv4_6n <= TX_IPv4_6n_IN;    
			IP_ID <= IP_ID_IN;
		end if;
	end if;
end process;

FREEZE_KEY_FIELDS_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- latch in key fields at start of packet assembly (they can change during packet assembly, 
			-- for example if an ACK is received).
			TX_SEQ_NO <= TX_SEQ_NO_IN;
			TX_ACK_NO <= TX_ACK_NO_IN;
			TX_ACK_WINDOW_LENGTH <= TX_ACK_WINDOW_LENGTH_IN;
			TX_FLAGS <= TX_FLAGS_IN;
			TX_PACKET_TYPE <= unsigned(TX_PACKET_TYPE_IN);
			TX_WINDOW_SCALE <= TX_WINDOW_SCALE_IN;
			if(unsigned(TX_PACKET_TYPE_IN) = 1) then
				 TX_TCP_HEADER_LENGTH <= x"7";    -- 28 bytes, includes two TCP options (MSS, window scaling).
			else
				 -- default length
				 TX_TCP_HEADER_LENGTH <= x"5";    -- 20 bytes, default
			end if;
			if(unsigned(TX_PACKET_TYPE_IN) = 3) then
				-- payload size from TCP_TXBUF
				TX_TCP_PAYLOAD_SIZE <= TX_PAYLOAD_SIZE;
			else
				-- no payload
				TX_TCP_PAYLOAD_SIZE <= (others => '0');
			end if;
        end if;
    end if;
end process;

--//---- TX PACKET SIZE ---------------------------
TX_PACKET_TYPE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
        TX_TCP_LENGTH <= unsigned("0000000000" & TX_TCP_HEADER_LENGTH & "00") + unsigned(TX_TCP_PAYLOAD_SIZE) ;	
         -- total TCP frame size, in bytes. Part of TCP pseudo-header needed for TCP checksum computation

		-- total IP frame size, in bytes. IP header is always the standard size of 20 bytes (IPv4) or 40 bytes (IPv6)
		-- ready at TX_PACKET_SEQUENCE_START_D3
		if(TX_IPv4_6n = '1') then
			TX_IP_LENGTH <= TX_TCP_LENGTH + 20;	
		else
			TX_IP_LENGTH <= TX_TCP_LENGTH + 40;	
		end if;
	end if;
end process;

--// IP HEADER CHECKSUM ----------------------
-- Transmit IP packet header checksum. Only applies to IPv4 (no header checksum in IPv6)
-- We must start the checksum early as the checksum field is not the last word in the header.
-- perform 1's complement sum of all 16-bit words within the header.
-- the checksum must be ready when TX_WORD_COUNTER_D=3
---- Note: same code used in udp_tx.vhd

IP_HEADER_CHECKSUM_001: process(CLK)
begin
	if rising_edge(CLK) then
		IP_HEADER_CHECKSUM0 <= ("01" & x"8406") + resize(unsigned(IPv4_ADDR(31 downto 16)),18) + resize(unsigned(IPv4_ADDR(15 downto 0)),18);  -- x"4500" + x"4000" + x"FF06"
	
		if (TX_PACKET_SEQUENCE_START = '1') and (TX_IPv4_6n_IN = '0') then
			-- the IP header checksum applies only to IPv4
			IP_HEADER_CHECKSUM <= (others => '0');
		elsif (TX_PACKET_SEQUENCE_START = '1') and (TX_IPv4_6n_IN = '1') then
			IP_HEADER_CHECKSUM <= resize(unsigned(IP_HEADER_CHECKSUM0(15 downto 0)),18) + resize(unsigned(IP_HEADER_CHECKSUM0(17 downto 16)),18) + resize(unsigned(IP_ID_IN),18);  
		elsif(TX_PACKET_SEQUENCE_START_SHIFT(0) = '1') then
			IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS  + resize(unsigned(TX_DEST_IP_ADDR(15 downto 0)),18);
		elsif(TX_PACKET_SEQUENCE_START_SHIFT(1) = '1') then
			IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS + resize(unsigned(TX_DEST_IP_ADDR(31 downto 16)),18);
		elsif(TX_PACKET_SEQUENCE_START_SHIFT(2) = '1') then
			IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS  + resize(TX_IP_LENGTH,18);
		elsif(TX_PACKET_SEQUENCE_START_SHIFT(3) = '1') then
			IP_HEADER_CHECKSUM <= IP_HEADER_CHECKSUM_PLUS ;
		end if;	
 	end if;
end process;
IP_HEADER_CHECKSUM_PLUS <= resize(unsigned(IP_HEADER_CHECKSUM(15 downto 0)),18) + resize(unsigned(IP_HEADER_CHECKSUM(17 downto 16)),18);
IP_HEADER_CHECKSUM_FINAL <= x"FFFF" when (IP_HEADER_CHECKSUM(16) = '1') and (IP_HEADER_CHECKSUM(0) = '0') else  
                            x"FFFE" when (IP_HEADER_CHECKSUM(16) = '1') and (IP_HEADER_CHECKSUM(0) = '1') else  
                            not(std_logic_vector(IP_HEADER_CHECKSUM(15 downto 0)));

--//-- TCP TX CHECKSUM  ---------------------------
-- Compute the TCP payload checksum (excluding headers).
-- Different pseudo-headers are used for IPv4 and IPv6

-- for IPv6, pre-compute the IPv6 address checksum. Only once at reset.
TCP_CKSUM_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			CKSUM_SEQ_CNTR <= "110";
		elsif(CKSUM_SEQ_CNTR > 0) then
			CKSUM_SEQ_CNTR <= CKSUM_SEQ_CNTR - 1;
		end if;
	end if;
end process;

TCP_CKSUM_002: process(CLK)
begin
	if rising_edge(CLK) then
		 -- fixed part of the checksum is initialized at reset
		if(SYNC_RESET = '1') then
			CKSUM_PART1 <= resize(unsigned(IPv6_ADDR(127 downto 112)),19) + resize(unsigned(IPv6_ADDR(111 downto 96)),19);
		elsif(CKSUM_SEQ_CNTR = "110") then
			CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(95 downto 80)),19);
		elsif(CKSUM_SEQ_CNTR = "101") then
			CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(79 downto 64)),19);
		elsif(CKSUM_SEQ_CNTR = "100") then
			CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(63 downto 48)),19);
		elsif(CKSUM_SEQ_CNTR = "011") then
			CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(47 downto 32)),19);
		elsif(CKSUM_SEQ_CNTR = "010") then
			CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(31 downto 16)),19);
		elsif(CKSUM_SEQ_CNTR = "001") then
			CKSUM_PART1 <= CKSUM_PART1 + resize(unsigned(IPv6_ADDR(15 downto 0)),19);
		end if;
	end if;
end process;



-- Checksum computation must be complete by the time TX_WORD_COUNTER reaches 5(IPv4) or 7 (IPv6). So we only have 5 iterations maximum to sum the pseudo header.
TCP_CKSUM_003: 	process(CLK)
begin
	if rising_edge(CLK) then
	    TX_PACKET_SEQUENCE_START_SHIFT(7 downto 0) <= TX_PACKET_SEQUENCE_START_SHIFT(6 downto 0) & TX_PACKET_SEQUENCE_START;

        if(TX_PACKET_SEQUENCE_START = '1') then
            if(unsigned(TX_PACKET_TYPE_IN) = 3) then
                -- payload size from TCP_TXBUF
                CKSUM4 <= resize(unsigned(TX_PAYLOAD_CHECKSUM(15 downto 0)),18) + x"0006"; -- data checksum + TCP protocol
            elsif(unsigned(TX_PACKET_TYPE_IN) = 1) then
					if(TX_WINDOW_SCALE_IN /= x"0") then
						-- TCP option: MSS, window scale, no payload data
						if(TX_IPv4_6n_IN = '1') then
							CKSUM4 <= resize((to_integer(unsigned(MSSv4))+ x"020A" + x"0103" + unsigned(x"030" & TX_WINDOW_SCALE_IN)),18); -- TCP protocol + MSS options  
						else
							CKSUM4 <= resize((to_integer(unsigned(MSSv6))+ x"020A" + x"0103" + unsigned(x"030" & TX_WINDOW_SCALE_IN)),18); -- TCP protocol + MSS options  
						end if;
					else
						-- TCP option: MSS, no payload data
						if(TX_IPv4_6n_IN = '1') then
							CKSUM4 <= resize((to_integer(unsigned(MSSv4))+ x"020A"),18); -- TCP protocol + MSS options  
						else
							CKSUM4 <= resize((to_integer(unsigned(MSSv6))+ x"020A"),18); -- TCP protocol + MSS options  
						end if;
					end if;
            else	-- (unsigned(TX_PACKET_TYPE_IN) = 2) then
                -- no payload data
                CKSUM4 <= "00" & x"0006"; -- TCP protocol  
            end if;
            CKSUM5 <= resize(unsigned(TX_SOURCE_PORT_NO_IN),18) + resize(unsigned(TX_DEST_PORT_NO_IN),18); -- src + dest ports 
				CKSUM6 <= resize(unsigned(TX_SEQ_NO_IN(31 downto 16)),18) + resize(unsigned(TX_SEQ_NO_IN(15 downto 0)),18);   
				CKSUM7 <= resize(unsigned(TX_ACK_NO_IN(31 downto 16)),18) + resize(unsigned(TX_ACK_NO_IN(15 downto 0)),18); 
            if(unsigned(TX_PACKET_TYPE_IN) = 3) then
                -- payload size from TCP_TXBUF
                CKSUM8 <= resize(unsigned(TX_PAYLOAD_CHECKSUM(17 downto 16)),18) ; -- carry bits
            else
                CKSUM8 <= (others => '0');
            end if;
        else
            if(TX_IPv4_6n = '1') then   -- IPv4
                if(TX_PACKET_SEQUENCE_START_SHIFT(0) = '1') then
                    CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(IPv4_ADDR(31 downto 16)),18);   -- src IP address
                    CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(IPv4_ADDR(15 downto 0)),18);   -- src IP address
                    CKSUM6 <= resize(CKSUM6(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(31 downto 16)),18); -- dest IP address
                    CKSUM7 <= resize(CKSUM7(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(15 downto 0)),18); -- dest IP address
                    CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
               elsif(TX_PACKET_SEQUENCE_START_SHIFT(1) = '1') then
                    CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TCP_HEADER_BYTE12_13),18);   
                    CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_ACK_WINDOW_LENGTH),18);   
                    CKSUM6 <= resize(CKSUM6(15 downto 0),18) + resize(TX_TCP_LENGTH,18); -- + TCP length
                    CKSUM7(17 downto 16) <= "00";
                    CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
               elsif(TX_PACKET_SEQUENCE_START_SHIFT(2) = '1') then
                    CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM6(15 downto 0),18);   
                    CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(CKSUM7(15 downto 0),18);   
                    CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
               elsif(TX_PACKET_SEQUENCE_START_SHIFT(3) = '1') then
                    CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM5(15 downto 0),18);   
                    CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY2,18); -- carry
              elsif(TX_PACKET_SEQUENCE_START_SHIFT(4) = '1') then
                   CKSUM8 <= CKSUM8 + resize(CKSUM4(15 downto 0),18) + CKSUM4(17 downto 16);
					elsif(TX_PACKET_SEQUENCE_START_SHIFT(5) = '1') then
						 CKSUM8 <= resize(CKSUM8(15 downto 0),18) + CKSUM8(17 downto 16);
                end if;
            elsif(IPv6_ENABLED = '1') then -- IPv6
					if(TX_PACKET_SEQUENCE_START_SHIFT(0) = '1') then
						CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM_PART1(15 downto 0),18) ;
						CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(CKSUM_PART1(18 downto 16),18);
						CKSUM6 <= resize(CKSUM6(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(127 downto 112)),18);
						CKSUM7 <= resize(CKSUM7(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(111 downto 96)),18);
						CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
					elsif(TX_PACKET_SEQUENCE_START_SHIFT(1) = '1') then
						CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(95 downto 80)),18);  -- dest IP address
						CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(79 downto 64)),18); -- dest IP address
						CKSUM6 <= resize(CKSUM6(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(63 downto 48)),18); 
						CKSUM7 <= resize(CKSUM7(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(47 downto 32)),18); 
						CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
					elsif(TX_PACKET_SEQUENCE_START_SHIFT(2) = '1') then
						CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(31 downto 16)),18); -- dest IP address
						CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(unsigned(TX_DEST_IP_ADDR(15 downto 0)),18); -- dest IP address
						CKSUM6 <= resize(CKSUM6(15 downto 0),18) + resize(unsigned(TCP_HEADER_BYTE12_13),18);
						CKSUM7 <= resize(CKSUM7(15 downto 0),18) + resize(unsigned(TX_ACK_WINDOW_LENGTH),18);
						CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
               elsif(TX_PACKET_SEQUENCE_START_SHIFT(3) = '1') then
                  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(TX_TCP_LENGTH,18); -- + TCP length
                  CKSUM5 <= resize(CKSUM5(15 downto 0),18) + resize(CKSUM7(15 downto 0),18);   
                  CKSUM6(17 downto 16) <= "00";
                  CKSUM7(17 downto 16) <= "00";
						CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY4,18); -- carry
					elsif(TX_PACKET_SEQUENCE_START_SHIFT(4) = '1') then
                  CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM6(15 downto 0),18);   
                  CKSUM5(17 downto 16) <= "00";
						CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY2,18); -- carry
               elsif(TX_PACKET_SEQUENCE_START_SHIFT(5) = '1') then
                    CKSUM4 <= resize(CKSUM4(15 downto 0),18) + resize(CKSUM5(15 downto 0),18);   
                    CKSUM8 <= CKSUM8 + resize(CKSUM_CARRY2,18); -- carry
              elsif(TX_PACKET_SEQUENCE_START_SHIFT(6) = '1') then
                   CKSUM8 <= CKSUM8 + resize(CKSUM4(15 downto 0),18) + CKSUM4(17 downto 16);
					elsif(TX_PACKET_SEQUENCE_START_SHIFT(7) = '1') then
						 CKSUM8 <= resize(CKSUM8(15 downto 0),18) + CKSUM8(17 downto 16);
					end if;
            end if;
        end if;
    end if;
end process;
CKSUM_CARRY2 <= resize(CKSUM4(17 downto 16),4) + resize(CKSUM5(17 downto 16),4);
CKSUM_CARRY4 <= resize(CKSUM4(17 downto 16),4) + resize(CKSUM5(17 downto 16),4) + resize(CKSUM6(17 downto 16),4) + resize(CKSUM7(17 downto 16),4);
TCP_CHECKSUM <= not CKSUM8(15 downto 0);

--//---- TX PACKET ASSEMBLY   ---------------------
-- Transmit packet is assembled on the fly, consistent with our design goal
-- of minimizing storage in each TCP_SERVER component.
-- The packet includes the lower layers, i.e. IP layer and Ethernet layer.
-- 
-- First, we tell the outsider arbitration that we are ready to send by raising RTS high.
-- When the transmit path becomes available, the arbiter tells us to go ahead with the transmission MAC_TX_CTS = '1'

STATE_MACHINE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_ACTIVE0 <= '0';
		elsif (TX_PACKET_SEQUENCE_START = '1') then
			TX_ACTIVE0 <= '1';
		elsif(MAC_TX_EOF_local = '1') then
			TX_ACTIVE0 <= '0';
		end if;
	end if;
end process;
TX_ACTIVE <= TX_ACTIVE0 and (not MAC_TX_EOF_local);

TX_SCHEDULER_001: process(CLK)
begin
	if rising_edge(CLK) then
	    
		if(SYNC_RESET = '1') then
			TX_WORD_COUNTER <= (others => '1');
			TX_WORD_COUNTER_D <= (others => '1');
			MAC_TX_WORD_VALID_E2 <= '0';
			MAC_TX_WORD_VALID_E <= '0';
		else
		    MAC_TX_WORD_VALID_E <= MAC_TX_WORD_VALID_E2;
    	    TX_WORD_COUNTER_D <= TX_WORD_COUNTER;

			if (TX_PACKET_SEQUENCE_START = '1') then
				TX_WORD_COUNTER <= (others => '1');
				MAC_TX_WORD_VALID_E2 <= '0';
			elsif(TX_ACTIVE = '1') and (MAC_TX_CTS = '1') then
				TX_WORD_COUNTER <= TX_WORD_COUNTER + 1;
				MAC_TX_WORD_VALID_E2 <= '1';  -- enable path to MAC
 			else
				MAC_TX_WORD_VALID_E2 <= '0';
			end if;
		end if;
	end if;
end process;

TCP_HEADER_BYTE12_13(15 downto 12) <=  std_logic_vector(TX_TCP_HEADER_LENGTH);      
TCP_HEADER_BYTE12_13(11 downto 8) <=  "0000";      
TCP_HEADER_BYTE12_13(7 downto 0) <=  TX_FLAGS; 

-- re-align bytes from payload data word to  MAC_TX_DATA word
WORD_ALIGN_001: process(CLK)
begin
	if rising_edge(CLK) then
		MAC_TX_CTS_D <= MAC_TX_CTS;
		MAC_TX_CTS_D2 <= MAC_TX_CTS_D;
		
		if(TX_PAYLOAD_WORD_VALID = '1') then	-- = MAC_TX_CTS_D2 when there is payload data
			TX_PAYLOAD_DATA_PREVIOUS <= TX_PAYLOAD_DATA;
			TX_PAYLOAD_DATA_VALID_PREVIOUS <= TX_PAYLOAD_DATA_VALID;
			TX_PAYLOAD_DATA_EOF_PREVIOUS <= TX_PAYLOAD_DATA_EOF;
		elsif(TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (MAC_TX_CTS_D2 = '1') then
			TX_PAYLOAD_DATA_VALID_PREVIOUS <= x"00";
			TX_PAYLOAD_DATA_EOF_PREVIOUS <= '0';
		end if;
	end if;
end process;

MAC_TX_DATA_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(TX_IPv4_6n = '1') then -- IPv4
           case TX_WORD_COUNTER_D is
               when "00000000000" => 
                   MAC_TX_DATA(63 downto 16) <= TX_DEST_MAC_ADDR;    
                   MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
               when "00000000001" => 
                   MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);    
                   MAC_TX_DATA(31 downto 0) <= x"08004500";   
               when "00000000010" => 
                   MAC_TX_DATA(63 downto 48) <= std_logic_vector(TX_IP_LENGTH);   
                   MAC_TX_DATA(47 downto 32) <= IP_ID;
                   MAC_TX_DATA(31 downto 0) <= x"4000FF06";     -- don't fragment, 255 hop limit, TCP
               when "00000000011" => 
                   MAC_TX_DATA(63 downto 48) <= IP_HEADER_CHECKSUM_FINAL;   -- IP header checksum   
                   MAC_TX_DATA(47 downto 16) <= IPv4_ADDR;   -- source IP address   
                   MAC_TX_DATA(15 downto 0) <= TX_DEST_IP_ADDR(31 downto 16);   -- destination IP address   
               when "00000000100" => 
                   MAC_TX_DATA(63 downto 48) <= TX_DEST_IP_ADDR(15 downto 0);   -- destination IP address  
                   MAC_TX_DATA(47 downto 32) <= TX_SOURCE_PORT_NO;
                   MAC_TX_DATA(31 downto 16) <= TX_DEST_PORT_NO;
                   MAC_TX_DATA(15 downto 0) <=  TX_SEQ_NO(31 downto 16);
               when "00000000101" => 
                   MAC_TX_DATA(63 downto 48) <= TX_SEQ_NO(15 downto 0);
                   MAC_TX_DATA(47 downto 16) <= TX_ACK_NO(31 downto 0); -- ack number;
                   MAC_TX_DATA(15 downto 0) <=  TCP_HEADER_BYTE12_13;      
               when "00000000110" => 
                   MAC_TX_DATA(63 downto 48) <= TX_ACK_WINDOW_LENGTH;
                   MAC_TX_DATA(47 downto 32) <= std_logic_vector(TCP_CHECKSUM);
                   MAC_TX_DATA(31 downto 16) <= X"0000";   
                   if(TX_PACKET_TYPE = 1) then
                        -- TCP option: MSS
                      MAC_TX_DATA(15 downto 0) <=  x"0204";      
                   elsif(TX_PACKET_TYPE = 3) and (TX_PAYLOAD_WORD_VALID = '1') then     
                       MAC_TX_DATA(15 downto 0) <=  TX_PAYLOAD_DATA(63 downto 48);      
                   else
                       MAC_TX_DATA(15 downto 0) <=  (others => '0');      
                  end if;  
               when others => 
                   if(TX_WORD_COUNTER_D = 7) and (TX_PACKET_TYPE = 1) then
                        -- TCP option: MSS. No payload data
                        MAC_TX_DATA(63 downto 48) <= "00" & MSSv4;
								-- TCP option: window scaling (when not zero)
								if(TX_WINDOW_SCALE /= x"0") then
									MAC_TX_DATA(47 downto 24) <= x"010303";
								else
									MAC_TX_DATA(47 downto 24) <= x"000000";
								end if;
								MAC_TX_DATA(23 downto 16) <= "0000" & TX_WINDOW_SCALE;
                        MAC_TX_DATA(15 downto 0) <=  (others => '0');      
                   elsif(TX_PACKET_TYPE = 3) then
							if (TX_PAYLOAD_WORD_VALID = '1') then
								MAC_TX_DATA(63 downto 16) <= TX_PAYLOAD_DATA_PREVIOUS(47 downto 0);
								MAC_TX_DATA(15 downto 0) <= TX_PAYLOAD_DATA(63 downto 48);
							elsif(MAC_TX_CTS_D2 = '1') and (TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (TX_PAYLOAD_DATA_VALID_PREVIOUS(5) = '1') then
								-- flush partial last word
								MAC_TX_DATA(63 downto 16) <= TX_PAYLOAD_DATA_PREVIOUS(47 downto 0);
								MAC_TX_DATA(15 downto 0) <= (others => '0');
							end if;
						end if;
            end case;
	   elsif(IPv6_ENABLED = '1') then -- IPv6
            case TX_WORD_COUNTER_D is
               when "00000000000" => 
                   MAC_TX_DATA(63 downto 16) <= TX_DEST_MAC_ADDR;    
                   MAC_TX_DATA(15 downto 0) <= MAC_ADDR(47 downto 32);
               when "00000000001" => 
                   MAC_TX_DATA(63 downto 32) <= MAC_ADDR(31 downto 0);    
                   MAC_TX_DATA(31 downto 0) <= x"86dd6000";   
               when "00000000010" => 
                   MAC_TX_DATA(63 downto 48) <= x"0000";   
                   MAC_TX_DATA(47 downto 32) <= std_logic_vector(TX_TCP_LENGTH);   -- payload length
                   MAC_TX_DATA(31 downto 16) <= x"06FF";   -- TCP, 255 hop limit
                   MAC_TX_DATA(15 downto 0) <= IPv6_ADDR(127 downto 112);   
               when "00000000011" => 
                   MAC_TX_DATA <= IPv6_ADDR(111 downto 48);   
               when "00000000100" => 
                   MAC_TX_DATA(63 downto 16) <= IPv6_ADDR(47 downto 0);  
                   MAC_TX_DATA(15 downto 0) <= TX_DEST_IP_ADDR(127 downto 112);   
               when "00000000101" => 
                   MAC_TX_DATA <= TX_DEST_IP_ADDR(111 downto 48);   
               when "00000000110" => 
                   MAC_TX_DATA(63 downto 16) <= TX_DEST_IP_ADDR(47 downto 0);  
                   MAC_TX_DATA(15 downto 0) <= TX_SOURCE_PORT_NO;
               when "00000000111" => 
                   MAC_TX_DATA(63 downto 48) <= TX_DEST_PORT_NO;
                   MAC_TX_DATA(47 downto 16) <= TX_SEQ_NO(31 downto 0);
                   MAC_TX_DATA(15 downto 0) <= TX_ACK_NO(31 downto 16);
               when "00000001000" => 
                   MAC_TX_DATA(63 downto 48) <= TX_ACK_NO(15 downto 0);
                   MAC_TX_DATA(47 downto 32) <= TCP_HEADER_BYTE12_13;
                   MAC_TX_DATA(31 downto 16) <= TX_ACK_WINDOW_LENGTH;
                   MAC_TX_DATA(15 downto 0) <= std_logic_vector(TCP_CHECKSUM);
               when "00000001001" => 
                   MAC_TX_DATA(63 downto 48) <= x"0000";
                   if(TX_PACKET_TYPE = 1) then
							-- TCP option: MSS
                      MAC_TX_DATA(47 downto 32) <=  x"0240"; 
                      MAC_TX_DATA(31 downto 16) <=  "00" & MSSv6; 
							 -- TCP option: window scaling (when not zero)
							 if(TX_WINDOW_SCALE /= x"0") then
								MAC_TX_DATA(15 downto 0) <= x"0103";
							 else
								MAC_TX_DATA(15 downto 0) <= x"0000";
							 end if;
                    elsif(TX_PACKET_TYPE = 3) and (TX_PAYLOAD_WORD_VALID = '1') then     
                      MAC_TX_DATA(47 downto 0) <=  TX_PAYLOAD_DATA(63 downto 16);   
                   else
                      MAC_TX_DATA(47 downto 0) <= (others => '0');
                   end if;   
               when others => 
						if(TX_WORD_COUNTER_D = "00000001010") and (TX_PACKET_TYPE = 1) then
							-- TCP option: window scaling (cont'd)
							 -- TCP option: window scaling (when not zero)
							 if(TX_WINDOW_SCALE /= x"0") then
								MAC_TX_DATA(63 downto 56) <= x"03";
							else
								MAC_TX_DATA(63 downto 56) <= x"00";
							end if;
							MAC_TX_DATA(55 downto 48) <= "0000" & TX_WINDOW_SCALE;
							MAC_TX_DATA(47 downto 0) <=  (others => '0');      
						elsif(TX_PACKET_TYPE = 3) then
							if (TX_PAYLOAD_WORD_VALID = '1') then
								MAC_TX_DATA(63 downto 48) <= TX_PAYLOAD_DATA_PREVIOUS(15 downto 0);
								MAC_TX_DATA(47 downto 0) <= TX_PAYLOAD_DATA(63 downto 16);
							elsif(MAC_TX_CTS_D2 = '1') and (TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (TX_PAYLOAD_DATA_VALID_PREVIOUS(1) = '1') then
								-- flush partial last word
								MAC_TX_DATA(63 downto 48) <= TX_PAYLOAD_DATA_PREVIOUS(15 downto 0);
								MAC_TX_DATA(47 downto 0) <= (others => '0');
							end if;
						end if;
					end case;
        end if;
	end if;
end process;

MAC_TX_DATA_VALID_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	   MAC_TX_WORD_VALID <= MAC_TX_WORD_VALID_E;
	   
	   if(MAC_TX_WORD_VALID_E = '1') then
           if(TX_IPv4_6n = '1') then -- IPv4
                if(TX_WORD_COUNTER_D <= 5) then
	               MAC_TX_DATA_VALID <= x"FF";
	            elsif(TX_WORD_COUNTER_D = 6) then
                   if(TX_PACKET_TYPE = 1) then
                       -- TCP options: MSS
    	               MAC_TX_DATA_VALID <= x"FF";
                   elsif(TX_PACKET_TYPE = 3) and (TX_PAYLOAD_WORD_VALID = '1') then
	                   MAC_TX_DATA_VALID <="111111" & TX_PAYLOAD_DATA_VALID(7 downto 6);
	               else	-- TX_PACKET_TYPE = 2
	                   MAC_TX_DATA_VALID <= x"FC";
	               end if;
	            elsif(TX_WORD_COUNTER_D = 7) then
                    if(TX_PACKET_TYPE = 1) then
                        -- TCP options: MSS, window scaling
                        MAC_TX_DATA_VALID <= x"FC";
                    elsif(TX_PACKET_TYPE = 3) then
								if (TX_PAYLOAD_WORD_VALID = '1') then
									MAC_TX_DATA_VALID <= TX_PAYLOAD_DATA_VALID_PREVIOUS(5 downto 0) & TX_PAYLOAD_DATA_VALID(7 downto 6);
								elsif(MAC_TX_CTS_D2 = '1') then
									-- flush partial last word
									MAC_TX_DATA_VALID <= TX_PAYLOAD_DATA_VALID_PREVIOUS(5 downto 0) & "00";
								end if;
							else
								MAC_TX_DATA_VALID <= x"00";
                    end if;
					 elsif(TX_PACKET_TYPE = 3) then
						if (TX_PAYLOAD_WORD_VALID = '1') then
							MAC_TX_DATA_VALID <= TX_PAYLOAD_DATA_VALID_PREVIOUS(5 downto 0) & TX_PAYLOAD_DATA_VALID(7 downto 6);
						elsif(MAC_TX_CTS_D2 = '1') and (TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (TX_PAYLOAD_DATA_VALID_PREVIOUS(5) = '1') then
							 -- flush partial last word
							MAC_TX_DATA_VALID <= TX_PAYLOAD_DATA_VALID_PREVIOUS(5 downto 0) & "00";
						else
							MAC_TX_DATA_VALID <= x"00";
						end if;
					else
	               MAC_TX_DATA_VALID <= x"00";
	            end if;
            elsif(IPv6_ENABLED = '1') then -- IPv6
                if(TX_WORD_COUNTER_D <= 8) then
                   MAC_TX_DATA_VALID <= x"FF";
                elsif(TX_WORD_COUNTER_D = 9) then
                   if(TX_PACKET_TYPE = 1) then
                        -- TCP options: MSS, window scaling
                        MAC_TX_DATA_VALID <= x"FF";
                    elsif(TX_PACKET_TYPE = 3) and (TX_PAYLOAD_WORD_VALID = '1') then
                        MAC_TX_DATA_VALID <="11" & TX_PAYLOAD_DATA_VALID(7 downto 2);
                    else	-- (including TX_PACKET_TYPE = 2)
                        MAC_TX_DATA_VALID <= x"C0";
                   end if;
					 elsif(TX_WORD_COUNTER_D = 10) and (TX_PACKET_TYPE = 1) then
							-- TCP option: window scaling
							MAC_TX_DATA_VALID <= x"c0";
					 elsif(TX_PACKET_TYPE = 3) then
						if (TX_PAYLOAD_WORD_VALID = '1') then
							MAC_TX_DATA_VALID <= TX_PAYLOAD_DATA_VALID_PREVIOUS(1 downto 0) & TX_PAYLOAD_DATA_VALID(7 downto 2);
						elsif(MAC_TX_CTS_D2 = '1') and (TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (TX_PAYLOAD_DATA_VALID_PREVIOUS(1) = '1') then
							-- flush partial last word
							MAC_TX_DATA_VALID <= TX_PAYLOAD_DATA_VALID_PREVIOUS(1 downto 0) & "000000";
						else
							MAC_TX_DATA_VALID <= x"00";
						end if;
					else
	               MAC_TX_DATA_VALID <= x"00";
                end if;
           end if;
	   else
	       MAC_TX_DATA_VALID <= x"00";
	   end if;
   end if;
end process;

MAC_TX_EOF_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
	   if(SYNC_RESET = '1') then
           MAC_TX_EOF_local <= '0';        
	   elsif(MAC_TX_WORD_VALID_E = '1') then
			if(TX_IPv4_6n = '1') then
				if(TX_WORD_COUNTER_D = 6) and (((TX_PAYLOAD_DATA_VALID(5) = '0') and (TX_PACKET_TYPE = 3)) or (TX_PACKET_TYPE = 2)) then
					MAC_TX_EOF_local <= '1';
				elsif(TX_WORD_COUNTER_D = 7) and (TX_PACKET_TYPE = 1) then
					MAC_TX_EOF_local <= '1';
				elsif (TX_PACKET_TYPE = 3) and (TX_WORD_COUNTER_D > 6) then
					if (TX_PAYLOAD_WORD_VALID = '1') and (TX_PAYLOAD_DATA_VALID(5) = '0') then
						MAC_TX_EOF_local <= '1';
					elsif (MAC_TX_CTS_D2 = '1') and (TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (TX_PAYLOAD_DATA_VALID_PREVIOUS(5) = '1') then
						-- flush partial last word
						MAC_TX_EOF_local <= '1';
					else
						MAC_TX_EOF_local <= '0';
					end if;
				else
					MAC_TX_EOF_local <= '0';
				end if;
			elsif(IPv6_ENABLED = '1') then -- IPv6
				if(TX_WORD_COUNTER_D = 9) and (TX_PAYLOAD_DATA_VALID(1) = '0') then
					MAC_TX_EOF_local <= '1';
				elsif(TX_WORD_COUNTER_D = 10) and (TX_PACKET_TYPE = 1) then
					MAC_TX_EOF_local <= '1';
				elsif (TX_PACKET_TYPE = 3) and (TX_WORD_COUNTER_D > 9) then
					if (TX_PAYLOAD_WORD_VALID = '1') and (TX_PAYLOAD_DATA_VALID(1) = '0') then
						MAC_TX_EOF_local <= '1';
					elsif (MAC_TX_CTS_D2 = '1') and (TX_PAYLOAD_DATA_EOF_PREVIOUS = '1') and (TX_PAYLOAD_DATA_VALID_PREVIOUS(1) = '1') then
						-- flush partial last word
						MAC_TX_EOF_local <= '1';
					else
						MAC_TX_EOF_local <= '0';
					end if;
				else
					MAC_TX_EOF_local <= '0';
				end if;
			else
				 MAC_TX_EOF_local <= '0';
			end if;
		else
			MAC_TX_EOF_local <= '0';
		end if;
   end if;
end process;
MAC_TX_EOF <= MAC_TX_EOF_local;

-- when to ask for next word from TCP tx buffer
TX_PAYLOAD_CTS_FLAG_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_PAYLOAD_CTS_FLAG0 <= '0';
		elsif (TX_PACKET_SEQUENCE_START = '1') then
			TX_PAYLOAD_CTS_FLAG0 <= '0';
		elsif(MAC_TX_CTS = '1') and (TX_PACKET_TYPE = "11") and 
		(((TX_IPv4_6n = '1') and (TX_WORD_COUNTER = 4)) or ((IPv6_ENABLED = '1') and (TX_IPv4_6n = '0') and (TX_WORD_COUNTER = 7))) then
			TX_PAYLOAD_CTS_FLAG0 <= '1';
		elsif(TX_PAYLOAD_DATA_EOF = '1') then
			-- received the last word in a frame from TCP_TXBUF
			TX_PAYLOAD_CTS_FLAG0 <= '0'; 
		end if;
	end if;
end process;
TX_PAYLOAD_CTS_FLAG <= TX_PAYLOAD_CTS_FLAG0 and (not TX_PAYLOAD_DATA_EOF);	  

-- clear to send. Ask TCP_TXBUF to send payload data
TX_PAYLOAD_CTS <= MAC_TX_CTS and TX_PAYLOAD_CTS_FLAG;
    -- 2 CLK latency until 1st data byte is available at TX_PAYLOAD_DATA
    -- IPv4: first word has to arrive here when TX_WORD_COUNTER_D = 6
    -- IPv6: first word has to arrive here when TX_WORD_COUNTER_D = 9

end Behavioral;
