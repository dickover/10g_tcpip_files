-------------------------------------------------------------
-- MSS copyright 2019
-- Filename:  ARP_CACHE2_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 1
-- Date last modified: 5/24/19
-- Inheritance: 	COM-5402 ARP_CACHE2.VHD 5/10/17 rev7
--
-- description:  table linking 32-bit IPv4 or 128-bit IPv6 addresses to 48-bit MAC addresses and the information
-- "freshness", i.e. time last seen, in effect a routing table. 
-- Uses one 16Kbit block RAM for a maximum of 128 entries.    
-- This component determines whether the destination IP address is local or not. In the
-- latter case, the MAC address of the gateway is returned. 
-- Only records regarding local addresses are stored (i.e. not WAN addresses since these often
-- point to the router MAC address anyway).
--
-- Assumming a 156.25 MHz clock...  
-- Time to access an existing record: between 24ns to 850ns max depending on the record location in the table.

-- An important startup issue is that ARP requests sent shortly after power up are
-- lost either at our LAN IC or at the destination LAN network interface card (PC
-- operating system slow at detecting a new LAN connection). 
--
-- Rev1 5/24/19 
-- Corrected bug when searching for IP match at address 0
-- 
-- Device utilization (IPv6_ENABLED='1')
-- FF: 1629
-- LUT: 1849
-- DSP48: 0
-- 18Kb BRAM: 5
-- BUFG: 1
-- Minimum period: 4.952ns (Maximum Frequency: 201.939MHz)  Artix7-100T -1 speed grade
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ARP_CACHE2_10G is
	generic (
    IPv6_ENABLED: std_logic := '1'
        -- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
    );
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
			-- synchronous reset: MANDATORY to properly initialize this component
		CLK: in std_logic;	
			-- reference clock.
			-- Global clock. No BUFG instantiation within this component.
		TICK_100MS : in std_logic;
			-- 100 ms tick for timer
		
		--// User interface (query/reply)
		-- (a) query
		RT_IP_ADDR: in std_logic_vector(127 downto 0);
			-- user query: destination IP address to resolve (could be local or remote). read when RT_REQ_RTS = '1'
		RT_IPv4_6n: in std_logic;
             -- IP version for RT_IP_ADDR: 1 for IPv4, 0 for IPv6
		RT_REQ_RTS: in std_logic;
			-- new requests will be ignored until the module is 
			-- finished with the previous request/reply transaction
		RT_CTS: out std_logic;	
			-- ready to accept a new routing query.
		-- (b) reply
		RT_MAC_REPLY: out std_logic_vector(47 downto 0);
			-- Destination MAC address associated with the destination IP address RT_IP_ADDR. 
			-- Could be the Gateway MAC address if the destination IP address is outside the local area network.
		RT_MAC_RDY: out std_logic;
			-- 1 CLK pulse to read the MAC reply
			-- The worst case latency from the RT_REQ_RTS request is 1.33us
			-- If there is no match in the table, no response will be provided. Calling routine should
			-- therefore have a timeout timer to detect lack of response.
		RT_NAK: out std_logic;
			-- 1 CLK pulse indicating that no record matching the RT_IP_ADDR was found in the table.

		--// Routing information
		MAC_ADDR : IN std_logic_vector(47 downto 0);
			-- local MAC address
		IPv4_ADDR: in std_logic_vector(31 downto 0);
            -- local IP address. 4 bytes for IPv4
            -- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
        IPv4_SUBNET_MASK: in std_logic_vector(31 downto 0);
			-- local subnet mask. used to distinguish local vs wan packets
        IPv4_GATEWAY_ADDR: in std_logic_vector(31 downto 0);
			-- Gateway IP address. Direct WAN packets to that gateway if non-local;
        IPv6_ADDR: in std_logic_vector(127 downto 0);
            -- local IP address. 16 bytes for IPv6
        IPv6_SUBNET_PREFIX_LENGTH: in std_logic_vector(7 downto 0);
            -- 128 - subnet size in bits. Usually expressed as /n. Typical range 64-128
        IPv6_GATEWAY_ADDR: in std_logic_vector(127 downto 0);
            --  upper 64 bits MUST match our IPv6 address (i.e. gateway MUST be on the same network)

		--// WHOIS interface (send ARP request)
		WHOIS_IP_ADDR: out std_logic_vector(127 downto 0) := (others => '0');
			-- user query: IP address to resolve. read at WHOIS_START
		WHOIS_IPv4_6n: out std_logic;
		    -- IP version for WHOIS_IP_ADDR: 1 for IPv4, 0 for IPv6
		WHOIS_START: out std_logic := '0';
			-- 1 CLK pulse to start the ARP query
			-- Note: since we do not check for the WHOIS_RDY signal, there is a small probability that WHOIS is busy 
			-- and that the request will be ignored. Higher-level Application should ask again in this case.

		--// Source MAC/IP addresses 
		-- Packet origin, parsed in PACKET_PARSING (shared code) from
		-- ARP responses and IP packets. Ignored when the component is busy.
		RX_SOURCE_ADDR_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);	-- all received packets
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);  	-- IPv4,ARP
		RX_IPv4_6n: in std_logic;

		-- Test Points
		SREG1 : OUT std_logic_vector(7 downto 0);
		SREG2 : OUT std_logic_vector(7 downto 0);
		SREG3 : OUT std_logic_vector(7 downto 0);
		SREG4 : OUT std_logic_vector(7 downto 0);
		SREG5 : OUT std_logic_vector(7 downto 0);
		SREG6 : OUT std_logic_vector(7 downto 0);
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of ARP_CACHE2_10G is
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
constant REFRESH_PERIOD: unsigned(19 downto 0) := x"00BB8";  -- time between entries refreshed (5 minutes)
constant ADDR_WIDTH: integer := 8;  -- table size is 2^(ADDR_WIDTH-1) entries

--// TIME ------------------------------------------------
signal TIMER1: integer range 0 to 50 := 0;
signal IPv4GATEWAY_REFRESH_TIMER: unsigned(11 downto 0)  := (others => '0');   -- 12-bits = 409.6s refresh max
signal IPv6GATEWAY_REFRESH_TIMER: unsigned(11 downto 0)  := (others => '0');   -- 12-bits = 409.6s refresh max
signal TIME_CNTR: unsigned(19 downto 0) := (others => '0');
signal TIMEDIFF: unsigned(19 downto 0) := (others => '0');

--//-- NEW QUERY IP CHECK ---------------------------------------------------
signal IPv6_SUBNET_MASK: std_logic_vector(63 downto 0) := (others => '0');    
signal IPv4_MASKED: std_logic_vector(31 downto 0) := (others => '0');
signal IPv6_MASKED: std_logic_vector(63 downto 0) := (others => '0');
signal RT_IP_ADDR_MASKED: std_logic_vector(63 downto 0) := (others => '0');
signal RT_IP_ADDR_D: std_logic_vector(127 downto 0) := (others => '0');
signal RT_IPv4_6n_D: std_logic := '0';
signal EVENT1: std_logic := '0';
signal EVENT2: std_logic := '0';
signal EVENT3: std_logic := '0';
signal EVENT4: std_logic := '0';
signal EVENT5: std_logic := '0';
signal EVENT6: std_logic := '0';
signal EVENT7: std_logic := '0';
signal EVENT8: std_logic := '0';
signal EVENT9: std_logic := '0';
signal EVENT10: std_logic := '0';
signal EVENTB1: std_logic := '0';
signal EVENTB2: std_logic := '0';

--//-- B-SIDE STATE MACHINE ---------------------------------------
signal MEMORY_INITIALIZED: std_logic := '0';
signal STATE_B: integer range 0 to 8;  
signal STATE_B_D: integer range 0 to 8;  
signal STATE_B_D2: integer range 0 to 8;  
signal STATE_B_D3: integer range 0 to 8;  
signal LAST_IP: std_logic_vector(63 downto 0) := (others => '0');
signal LAST_IPv4_6n: std_logic := '0';
signal LAST_MAC: std_logic_vector(47 downto 0) := (others => '0');
signal LAST_TIME: unsigned(19 downto 0) := (others => '0');
signal RT_MAC_RDY_local: std_logic := '0';
signal RT_NAK_local: std_logic  := '0';
signal RT_MAC_REPLY_local: std_logic_vector(47 downto 0) := (others => '0');
signal ADDRB: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');  -- table is 128 entries x 133b + 1 bit for overflow detection
signal ADDRB_INC: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0'); 
signal ADDRB_D: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0'); 
signal ADDRB_D2: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0'); 
signal WHOIS_START_local: std_logic := '0'; 
signal WHOIS_IP_ADDR_local: std_logic_vector(127 downto 0) := (others => '0'); 
signal WHOIS_IPv4_6n_local: std_logic := '0';
signal WHOIS_IPv4GATEWAY: std_logic := '0';
signal WHOIS_IPv6GATEWAY: std_logic := '0';

--//-- ROUTING TABLE ---------------------------------------------------
signal WEA: std_logic := '0';
signal WEB: std_logic := '0';
signal ENA: std_logic := '0';
signal ENB: std_logic := '0';
signal DIA: std_logic_vector(132 downto 0) := (others => '0');
signal DOA: std_logic_vector(132 downto 0) := (others => '0');
signal DOA_D: std_logic_vector(132 downto 0) := (others => '0');
signal DIB: std_logic_vector(132 downto 0) := (others => '0');
signal DOB: std_logic_vector(132 downto 0) := (others => '0');
signal DOB_D: std_logic_vector(132 downto 0) := (others => '0');

--//-- KEY MATCH ---------------------------------------------------
signal ZERO_IP_AMATCH: std_logic_vector (3 downto 0) := (others => '0');
signal IP_KEY1_AMATCH: std_logic_vector (4 downto 0) := (others => '0');
signal IP_KEY1_BMATCH: std_logic_vector (4 downto 0) := (others => '0');
signal IP_KEY1_MATCH: std_logic := '0';
signal IP_KEY1: std_logic_vector (64 downto 0) := (others => '0');
signal IP_KEY1_MAC: std_logic_vector(47 downto 0) := (others => '0');
signal IP_KEY1_TIME: unsigned(19 downto 0) := (others => '0');
signal IP_KEY2_AMATCH: std_logic_vector (4 downto 0) := (others => '0');
signal IP_KEY2_BMATCH: std_logic_vector (4 downto 0) := (others => '0');
signal IP_KEY2_MATCH: std_logic := '0';
signal IP_KEY2: std_logic_vector (64 downto 0) := (others => '0');
signal IP_KEY2_ADDR: std_logic_vector (ADDR_WIDTH-2 downto 0) := (others => '0');

--//-- NEW MAC/IP ADDRESSES ENTRY ---------------------------------------------------
signal RX_SOURCE_MAC_ADDR_D: std_logic_vector(47 downto 0) := (others => '0');	
signal RX_SOURCE_IP_ADDR_D: std_logic_vector(127 downto 0) := (others => '0');	
signal RX_IPv4_6n_D: std_logic := '0';
signal LAST_RX_MAC: std_logic_vector(47 downto 0) := (others => '0');	
signal LAST_RX_IP: std_logic_vector(127 downto 0) := (others => '0');	
signal LAST_RX_IPv4_6n: std_logic := '0';
signal LAST_RX_TIME: unsigned(19 downto 0) := (others => '0');
signal RX_SOURCE_IP_ADDR_MASKED:std_logic_vector(63 downto 0) := (others => '0');	

--//-- A-SIDE STATE MACHINE ---------------------------------------
signal EVENTA1: std_logic := '0';
signal STATE_A: integer range 0 to 4 := 0;  
signal STATE_A_D: integer range 0 to 4 := 0;  
signal STATE_A_D2: integer range 0 to 4 := 0;  
signal ADDRA: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');  -- table is 128 entries x 133b + 1 bit for overflow detection
signal ADDRA_D: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0'); 
signal ADDRA_D2: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0'); 
signal GATEWAYv4_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal GATEWAYv6_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');

--//-- FIND OLDEST ENTRY -----------------------------
signal TIME_A: unsigned(19 downto 0) := (others => '0'); 
signal TIME_B: unsigned(19 downto 0) := (others => '0'); 
signal OLDEST_TIME: unsigned(19 downto 0) := (others => '0'); 
signal OLDEST_ADDR: unsigned(ADDR_WIDTH-2 downto 0) := (others => '0');  
signal VIRGIN: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// TIME ------------------------------------------------
-- keep track of time, by increments of 100ms
-- range: 29 hours
TIME_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			TIME_CNTR <= (others => '0');
		elsif(TICK_100MS = '1') then
			TIME_CNTR <= TIME_CNTR + 1;
		end if;

        -- to improve timing, pre-compute TIME_CNTR - REFRESH_PERIOD
        TIMEDIFF <= TIME_CNTR - REFRESH_PERIOD;

	end if;
end process;

-- prevent flood of ARP requests / Neighbor solicitations being sent out
TIMER1_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			TIMER1 <= 0;
		elsif (WHOIS_START_local = '1') then 
			-- re-arm timer
			TIMER1 <= 10;
		elsif(TICK_100MS = '1') and (TIMER1 > 0) then
			TIMER1 <= TIMER1 - 1;
		end if;
	end if;
end process;

-- gateway MAC refresh timer. 12-bits = 409.6s refresh max
IPv4GATEWAY_REFRESH_TIMER_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			IPv4GATEWAY_REFRESH_TIMER <= to_unsigned(11,IPv4GATEWAY_REFRESH_TIMER'length);
			-- first ARP request approximately 1s after FPGA is configured  
		elsif(WHOIS_IPv4GATEWAY = '1') then
		    -- sent the ARP request. awaiting ARP reply. Short timer value to prevent a flood of ARP requests.
		    -- If no gateway response, another ARP request will be sent in 30 seconds
		    IPv4GATEWAY_REFRESH_TIMER <= to_unsigned(301,IPv4GATEWAY_REFRESH_TIMER'length);
		      -- use slightly different timers to alleviate repetitive contentions
        elsif (RX_SOURCE_ADDR_RDY = '1') and (RX_IPv4_6n = '1') and (RX_SOURCE_IP_ADDR(31 downto 0) = IPv4_GATEWAY_ADDR) then
            -- re-arm timer
			IPv4GATEWAY_REFRESH_TIMER <= REFRESH_PERIOD(IPv4GATEWAY_REFRESH_TIMER'left downto 0);
		elsif(TICK_100MS = '1') and (IPv4GATEWAY_REFRESH_TIMER > 0) then
			IPv4GATEWAY_REFRESH_TIMER <= IPv4GATEWAY_REFRESH_TIMER - 1;
		end if;
	end if;
end process;

IPv6GATEWAY_REFRESH_TIMER_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') or (IPv6_ENABLED = '0') then
			IPv6GATEWAY_REFRESH_TIMER <= to_unsigned(12,IPv6GATEWAY_REFRESH_TIMER'length);
			-- first ARP request approximately 1s after FPGA is configured  
		elsif(WHOIS_IPv6GATEWAY = '1') then
              -- sent the ARP request. awaiting ARP reply. Short timer value to prevent a flood of ARP requests
  		      -- If no gateway response, another ARP request will be sent in 30 seconds
              IPv6GATEWAY_REFRESH_TIMER <= to_unsigned(302,IPv6GATEWAY_REFRESH_TIMER'length);
		      -- use slightly different timers to alleviate repetitive contentions
        elsif (RX_SOURCE_ADDR_RDY = '1') and (RX_IPv4_6n = '0') and (RX_SOURCE_IP_ADDR = IPv6_GATEWAY_ADDR) then
            -- re-arm timer
			IPv6GATEWAY_REFRESH_TIMER <= REFRESH_PERIOD(IPv6GATEWAY_REFRESH_TIMER'left downto 0);
		elsif(TICK_100MS = '1') and (IPv4GATEWAY_REFRESH_TIMER > 0) then
			IPv6GATEWAY_REFRESH_TIMER <= IPv6GATEWAY_REFRESH_TIMER - 1;
		end if;
	end if;
end process;

--//-- NEW QUERY IP CHECK ---------------------------------------------------
-- Is target IP local or remote? If remote, the Gateway is the next hop 
-- -> search for Gateway MAC address instead.

IPv6_SUBNET_MASK_GEN: process(CLK)
begin
	if rising_edge(CLK) then
	   for I in 64 to 127 loop
	       if(I >= to_integer(unsigned(IPv6_SUBNET_PREFIX_LENGTH))) then
	           IPv6_SUBNET_MASK(127-I) <= '0';
	       else
	           IPv6_SUBNET_MASK(127-I) <= '1';
	       end if;
	   end loop;
    end if;
end process;

LATCH_RT_IP_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		IPv4_MASKED <= IPv4_ADDR and IPv4_SUBNET_MASK;
		IPv6_MASKED <= IPv6_ADDR(63 downto 0) and IPv6_SUBNET_MASK;    -- no need for the upper 64-bits

		-- new request
		if(STATE_B = 0) and (RT_REQ_RTS = '1') then
			-- idle + new query. freeze input information during the query 
			-- just in case two requests are very close to eachother)
			if(RT_IPv4_6n = '1') then
			     RT_IP_ADDR_MASKED(31 downto 0) <= RT_IP_ADDR(31 downto 0) and IPv4_SUBNET_MASK;
			elsif(IPv6_ENABLED = '1') then
			     -- IPv6
			     RT_IP_ADDR_MASKED <= RT_IP_ADDR(63 downto 0) and IPv6_SUBNET_MASK;
			end if;
			RT_IP_ADDR_D <= RT_IP_ADDR;
			RT_IPv4_6n_D <= RT_IPv4_6n;
		
            -- process events 1 CLK before use (for better timing)
            if (unsigned(RT_IP_ADDR(31 downto 24)) >= 224) and  (unsigned(RT_IP_ADDR(31 downto 24)) <= 239) then
                EVENT1 <= '1';
            else
                EVENT1 <= '0';
            end if;
                    
            if (RT_IP_ADDR(31 downto 0) = x"FF_FF_FF_FF") then
                EVENT2 <= '1';
            else
                EVENT2 <= '0';
            end if;
            
            if(RT_IP_ADDR(31 downto 0) = LAST_IP(31 downto 0)) and (LAST_IPv4_6n = '1') and (EVENTB1 = '1') then
                EVENT3 <= '1';
            else
                EVENT3 <= '0';
            end if;		
    
            if(RT_IP_ADDR(31 downto 0) = IPv4_GATEWAY_ADDR) and (unsigned(GATEWAYv4_MAC_ADDR) /= 0)  then
                EVENT4 <= '1';
            else
                EVENT4 <= '0';
            end if;		
    
            if(RT_IP_ADDR(31 downto 0) = x"7F000001") or (RT_IP_ADDR(31 downto 0) = IPv4_ADDR) then
                EVENT5 <= '1';
            else
                EVENT5 <= '0';
            end if;		
    
            if (RT_IPv4_6n = '0') and (RT_IP_ADDR(127 downto 120) = x"FF") then
                EVENT6 <= '1';
            else
                EVENT6 <= '0';
            end if;		

            if (RT_IP_ADDR(127 downto 112) = x"FE80") and (RT_IP_ADDR(127 downto 64) /= IPv6_ADDR(127 downto 64)) then
                EVENT7 <= '1';
            else
                EVENT7 <= '0';
            end if;		

            if (RT_IP_ADDR(63 downto 0) = LAST_IP(63 downto 0)) and (LAST_IPv4_6n = '0') and (EVENTB1 = '1') then
                EVENT8 <= '1';
            else
                EVENT8 <= '0';
            end if;		

            if (RT_IP_ADDR(63 downto 0) = IPv6_GATEWAY_ADDR(63 downto 0)) and (unsigned(GATEWAYv6_MAC_ADDR) /= 0)  then
                EVENT9 <= '1';
            else
                EVENT9 <= '0';
            end if;		

            if (RT_IP_ADDR(63 downto 0) = x"0000000000000001") or (RT_IP_ADDR(63 downto 0) = IPv6_ADDR(63 downto 0))  then
                EVENT10 <= '1';
            else
                EVENT10 <= '0';
            end if;		



		end if;
	end if;
end process;

EVENTB1 <= '1' when (TIMEDIFF < LAST_TIME) or ((TIMEDIFF(TIMEDIFF'left) = '1') and (LAST_TIME(LAST_TIME'left) = '0')) else '0';
    -- '1' when LAST_TIME is recent (i.e. occurred less than refresh period)
    -- Code is a bit tricky because of the wrap-around unsigned time
    -- Also because we rephrased this time comparison for better timing (TIMEDIFF is pipelined already)

EVENTB2 <= '1' when (TIMEDIFF < IP_KEY1_TIME) or ((TIMEDIFF(TIMEDIFF'left) = '1') and (IP_KEY1_TIME(IP_KEY1_TIME'left) = '0')) else '0';
    -- '1' when record found in database is recent enough, '0' when record is too old 

-- accept new routing queries when idle 
RT_CTS <= MEMORY_INITIALIZED when (STATE_B = 0) else '0';

----//-- B-SIDE STATE MACHINE ---------------------------------------
---- B-side of the block RAM used for (a) block RAM initialization and (b) look-up table

ADDRB_INC <= ADDRB + 1;

STATE_MACHINE_B_001: process(CLK)
begin
	if rising_edge(CLK) then
        ADDRB_D <= ADDRB;	-- 1 CLK delay to read data from the block RAM.
        ADDRB_D2 <= ADDRB_D;	-- 1 CLK delay to read data from the block RAM.
        STATE_B_D <= STATE_B;
        STATE_B_D2 <= STATE_B_D;
        STATE_B_D3 <= STATE_B_D2;

		if(SYNC_RESET = '1') or ((MEMORY_INITIALIZED = '0') and (STATE_B /= 8))then
			STATE_B <= 8;  -- start with clearing the RAMB (could remember old entries?)
			RT_MAC_REPLY_local <= (others => '0');
			RT_MAC_RDY_local <= '0';
			ADDRB <= (others => '0');
			WEB <= '1';
		elsif(STATE_B = 8)  then
			-- one-time RAMB initialization. Scan through all the block RAM addresses 0 - 127
			if(ADDRB_INC(ADDR_WIDTH-1) = '1') then
				-- done.
				MEMORY_INITIALIZED <= '1';
				STATE_B <= 0;
				WEB <= '0';
			else
				ADDRB <= ADDRB + 1;
				DIB(112+ADDR_WIDTH downto 113) <= std_logic_vector(ADDRB);
				    -- trick so that first entry (oldest timestamp) will be at address 0 (to minimize the search time)
			end if;
		elsif(STATE_B = 0) then
			-- idle
			ADDRB <= (others => '0');
			RT_MAC_RDY_local <= '0';			-- clear
			if (RT_REQ_RTS = '1') then
				-- new query. (1 CLK duration)
				STATE_B <= 1;
			end if;
		elsif(STATE_B = 1) then
			-- In the several cases below, there is no need for a table search. STATE_B goes back to zero
			if (RT_IPv4_6n_D = '1') then
                if (EVENT1 = '1') then	-- new 12/21/15 AZ
                    -- IPv4 multicast destination
                    RT_MAC_REPLY_local(47 downto 24) <= x"01_00_5E";
                    RT_MAC_REPLY_local(23 downto 0) <= "0" & RT_IP_ADDR_D(22 downto 0);
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;	-- back to idle
                elsif  (EVENT2 = '1') then	
                    -- Broadcast IP 255.255.255.255
                    RT_MAC_REPLY_local <= x"FF_FF_FF_FF_FF_FF";
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;    -- back to idle
                elsif (RT_IP_ADDR_MASKED(31 downto 0) /= IPv4_MASKED) or  (EVENT4 = '1') then 
                    -- remote (WAN) address. substitute Gateway IP
                    -- (b) Gateway IPv4
                    -- Do not forward IP broadcast messages to the WAN 
                    RT_MAC_REPLY_local <= GATEWAYv4_MAC_ADDR;
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;	-- back to idle
                elsif (EVENT3 = '1') then
                    -- (a) same as last and last information is recent. No need to go further. Same reply. 
                    RT_MAC_REPLY_local <= LAST_MAC;
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;    -- back to idle
                elsif (EVENT5 = '1') then
                    -- (c) local host 127.0.0.1. Local loopback
                    RT_MAC_REPLY_local <= MAC_ADDR;
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;    -- back to idle
                else
                    STATE_B <= 2;
                    ADDRB <= (others => '0');   -- prepare to read in STATE_B = 3
                end if;
            elsif (IPv6_ENABLED = '1') then   
                if (EVENT6 = '1') then
                    -- IPv6 multicast destination 
                    RT_MAC_REPLY_local(47 downto 32) <= x"33_33";
                    RT_MAC_REPLY_local(31 downto 0) <= RT_IP_ADDR_D(31 downto 0);
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;    -- back to idle
                elsif (EVENT9 = '1') or (EVENT7 = '1') or ((RT_IP_ADDR_D(127 downto 112) = x"FE80") and (RT_IP_ADDR_MASKED(63 downto 0) /= IPv6_MASKED)) then -- *042918
                    -- unicast destination address, different network/subnet -> remote (WAN) address. substitute Gateway IP
                    RT_MAC_REPLY_local <= GATEWAYv6_MAC_ADDR;
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;	-- back to idle
                elsif (EVENT8 = '1') then
                    -- (a) same as last and last information is recent. No need to go further. Same reply. 
                    RT_MAC_REPLY_local <= LAST_MAC;
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;    -- back to idle
                elsif (EVENT10 = '1') then
                    -- (c) Local loopback
                    RT_MAC_REPLY_local <= MAC_ADDR;
                    RT_MAC_RDY_local <= '1';
                    STATE_B <= 0;    -- back to idle
               else
                    STATE_B <= 2;
                    ADDRB <= (others => '0');   -- prepare to read in STATE_B = 3
                end if;
		    end if;
		elsif(STATE_B = 2) then
            -- SEARCH TABLE
            STATE_B <= 3;  -- scan routing table from the bottom
            ADDRB <= ADDRB + 1;  -- go from 0 to 1
		elsif (STATE_B = 3) then 
			-- scan records 0 - 127 or until we find the target IP address
			-- is there a match with the query?
			if(IP_KEY1_MATCH = '1') then
				-- found a match
				RT_MAC_REPLY_local <= IP_KEY1_MAC;
				RT_MAC_RDY_local <= '1';
				STATE_B <= 0; -- back to idle
			elsif (ADDRB_D2(ADDR_WIDTH-1) = '1') then
				-- no match found. reached end of range and yet no match.
				-- note STATE_B=3 is extended three more clocks to wait for the last possible key match
				-- send out an ARP request IF some conditions are met
				STATE_B <= 0; -- back to idle
			else
				-- scan until we find the Target IP address
				ADDRB <= ADDRB + 1;  -- just look up the IP key to scan fast
			end if;
		end if;
	end if;
end process;
RT_MAC_RDY <= RT_MAC_RDY_local;
RT_NAK <= RT_NAK_local;
RT_MAC_REPLY <= RT_MAC_REPLY_local;

STATE_MACHINE_B_010: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MEMORY_INITIALIZED = '0') then
			WHOIS_START_local <= '0';
		elsif (STATE_B = 3) and (IP_KEY1_MATCH = '1') then 
			-- found a match
            if(EVENTB2 = '0') then
                -- If the record is too old, send another ARP request to refresh the table
                WHOIS_IPv4_6n_local <= RT_IPv4_6n_D;
                WHOIS_START_local <= '1';
                if(RT_IPv4_6n_D = '1') then
                    -- IPv4
                    WHOIS_IP_ADDR_local(31 downto 0) <= RT_IP_ADDR_D(31 downto 0);
                    WHOIS_IP_ADDR_local(127 downto 32) <= (others => '0');
                elsif(IPv6_ENABLED = '1') then
                    -- IPv6
                    WHOIS_IP_ADDR_local(63 downto 0) <= RT_IP_ADDR_D(63 downto 0);
                    WHOIS_IP_ADDR_local(127 downto 64) <= RT_IP_ADDR_D(127 downto 64);
                end if;
            end if;
        elsif (STATE_B = 3) and (ADDRB_D2(ADDR_WIDTH-1) = '1') then 
            -- no. reached end of range and yet no match
            -- send out an ARP request IF some conditions are met
            if(RT_IP_ADDR_D(63 downto 0) /= WHOIS_IP_ADDR_local(63 downto 0)) or (RT_IPv4_6n_D /= WHOIS_IPv4_6n_local) or (TIMER1 = 0) then
                -- different address from last ARP request
                -- OR elapsed enough time since last similar ARP request
                WHOIS_IPv4_6n_local <= RT_IPv4_6n_D;
                WHOIS_START_local <= '1';
                if(RT_IPv4_6n_D = '1') then
                    -- IPv4
                    WHOIS_IP_ADDR_local(31 downto 0) <= RT_IP_ADDR_D(31 downto 0);
                    WHOIS_IP_ADDR_local(127 downto 32) <= (others => '0');
                elsif(IPv6_ENABLED = '1') then
                    -- IPv6
                    WHOIS_IP_ADDR_local <= RT_IP_ADDR_D;
                end if;
            end if;
		elsif (STATE_B = 0) and (IPv4GATEWAY_REFRESH_TIMER = 0) and (WHOIS_IPv4GATEWAY = '0') then 
            -- refresh gateway IPv4 MAC 
            WHOIS_IP_ADDR_local(31 downto 0) <= IPv4_GATEWAY_ADDR;
            WHOIS_IP_ADDR_local(127 downto 32) <= (others => '0');
            WHOIS_IPv4_6n_local <= '1';
            WHOIS_START_local <= '1';
            WHOIS_IPv4GATEWAY <= '1';
        elsif (IPv6_ENABLED = '1') and (STATE_B = 0) and (IPv6GATEWAY_REFRESH_TIMER = 0) and (WHOIS_IPv6GATEWAY = '0') then 
            -- refresh gateway IPv6 MAC
            WHOIS_IP_ADDR_local <= IPv6_GATEWAY_ADDR;
            WHOIS_IPv4_6n_local <= '0';
            WHOIS_START_local <= '1';
            WHOIS_IPv6GATEWAY <= '1';
        else
            WHOIS_START_local <= '0';
            WHOIS_IPv4GATEWAY <= '0';
            WHOIS_IPv6GATEWAY <= '0';
		end if;
	end if;
end process;
WHOIS_START <= WHOIS_START_local;
WHOIS_IP_ADDR <= WHOIS_IP_ADDR_local;
WHOIS_IPv4_6n <= WHOIS_IPv4_6n_local;

-- break down state machine into smaller parts (otherwise timing is bad)
STATE_MACHINE_B_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or (MEMORY_INITIALIZED = '0') then
			LAST_IP <= (others => '0');
			LAST_IPv4_6n <= '0';
			LAST_MAC <= (others => '0');
			LAST_TIME <= (others => '0');
		elsif (STATE_B_D3 = 3) then 
			-- scan records 0 - 127 or until we find the target IP address

			-- is there a match with the query?
			if (IP_KEY1_MATCH = '1') then
				-- yes!
				-- remember last valid response just in case someone asks again (saves time)
				LAST_IP <= RT_IP_ADDR_D(63 downto 0);
				LAST_IPv4_6n <= RT_IPv4_6n_D;
				LAST_MAC <= IP_KEY1_MAC;
				LAST_TIME <= IP_KEY1_TIME;
			end if;
		end if;
	end if;
end process;

STATE_MACHINE_B_003: process(CLK)
begin
	if rising_edge(CLK) then
		--if (STATE_B = 3) and (ADDRB(ADDR_WIDTH-1) = '1') and ((RT_IP_ADDR_D(63 downto 0) /= DOB(63 downto 0)) or (RT_IPv4_6n_D /= DOB(112))) then 
		if(SYNC_RESET = '1') or ((MEMORY_INITIALIZED = '0') and (STATE_B /= 8))then
			RT_NAK_local <= '0';					-- clear
		elsif (STATE_B = 3) and (IP_KEY1_MATCH = '0') and (ADDRB_D2(ADDR_WIDTH-1) = '1')  then -- *080918
			-- scan records 0 - 127 or until we find the target IP address
			-- no. reached end of range and yet no match
			-- send a NAK to the caller
			RT_NAK_local <= '1';
	    else
			RT_NAK_local <= '0';					-- clear
		end if;
	end if;
end process;





--//-- ROUTING TABLE ---------------------------------------------------
-- Each entry comprises 133 bits: 64-bit IP address (full IPv4 or the local part of IPv6) + 1-bit IPversion + 48-bit MAC address + 20-bit TIME  
ENA <= '0' when (SYNC_RESET = '1') else '1';		-- to prevent warnings in modelsim
ENB <= '0' when (SYNC_RESET = '1') else '1';

-- split into narrower 18Kb BRAMs for slightly better timing on Xilinx (marginal improvement 070918)
-- original: one 133 bit-wide BRAM
BRAM_DP2_00x: for I in 0 to 3 generate
	BRAM_DP2_001: BRAM_DP2
	GENERIC MAP(
		DATA_WIDTHA => 32,		
		ADDR_WIDTHA => ADDR_WIDTH-1,  -- 2^(ADDR_WIDTH-1) entries 
		DATA_WIDTHB => 32,		 
		ADDR_WIDTHB => ADDR_WIDTH-1
	)
	PORT MAP(
		CSA => '1',
		CLKA => CLK,
		WEA => WEA,
		ADDRA => std_logic_vector(ADDRA(ADDR_WIDTH-2 downto 0)),
		DIA => DIA(32*I +31 downto 32*I),      
		OEA => '1',
		DOA => DOA(32*I +31 downto 32*I),
		CSB => '1',
		CLKB => CLK,
		WEB => WEB,
		ADDRB => std_logic_vector(ADDRB(ADDR_WIDTH-2 downto 0)), 
		DIB => DIB(32*I +31 downto 32*I),
		OEB => '1',
		DOB => DOB(32*I +31 downto 32*I)      
	);
end generate;
	BRAM_DP2_001b: BRAM_DP2
	GENERIC MAP(
		DATA_WIDTHA => 5,		
		ADDR_WIDTHA => ADDR_WIDTH-1,  -- 2^(ADDR_WIDTH-1) entries 
		DATA_WIDTHB => 5,		 
		ADDR_WIDTHB => ADDR_WIDTH-1
	)
	PORT MAP(
		CSA => '1',
		CLKA => CLK,
		WEA => WEA,
		ADDRA => std_logic_vector(ADDRA(ADDR_WIDTH-2 downto 0)),
		DIA => DIA(132 downto 128),      
		OEA => '1',
		DOA => DOA(132 downto 128),  
		CSB => '1',
		CLKB => CLK,
		WEB => WEB,
		ADDRB => std_logic_vector(ADDRB(ADDR_WIDTH-2 downto 0)), 
		DIB => DIB(132 downto 128),  
		OEB => '1',
		DOB => DOB(132 downto 128)        
	);

-- for timing purposes pipeline the large comparisons into smaller subsets
IP_KEY1_MATCH_DETECT_001: process(CLK)
begin
	if rising_edge(CLK) then
		DOA_D <= DOA;
		DOB_D <= DOB;

		-- break 64-bit comparison into 4*16-bit comparisons
		-- A side
		for I in 0 to 3 loop
			if(DOA(16*I+15 downto 16*I) = IP_KEY1(16*I+15 downto 16*I)) then
				IP_KEY1_AMATCH(I) <= '1';
			else
				IP_KEY1_AMATCH(I) <= '0';
			end if;
		end loop;
		if(DOA(112) = IP_KEY1(64)) then
			IP_KEY1_AMATCH(4) <= '1';
		else
			IP_KEY1_AMATCH(4) <= '1';
		end if;
		
		-- B side
		for I in 0 to 3 loop
			if(DOB(16*I+15 downto 16*I) = IP_KEY1(16*I+15 downto 16*I)) then
				IP_KEY1_BMATCH(I) <= '1';
			else
				IP_KEY1_BMATCH(I) <= '0';
			end if;
		end loop;
		if(DOB(112) = IP_KEY1(64)) then
			IP_KEY1_BMATCH(4) <= '1';
		else
			IP_KEY1_BMATCH(4) <= '1';
		end if;
		
	end if;
end process;

IP_KEY2_MATCH_DETECT_001: process(CLK)
begin
	if rising_edge(CLK) then
		
		-- break 64-bit comparison into 4*16-bit comparisons
		-- A side
		for I in 0 to 3 loop
			if(DOA(16*I+15 downto 16*I) = IP_KEY2(16*I+15 downto 16*I)) then
				IP_KEY2_AMATCH(I) <= '1';
			else
				IP_KEY2_AMATCH(I) <= '0';
			end if;
		end loop;
		if(DOA(112) = IP_KEY2(64)) then
			IP_KEY2_AMATCH(4) <= '1';
		else
			IP_KEY2_AMATCH(4) <= '1';
		end if;
		
		-- B side
		for I in 0 to 3 loop
			if(DOB(16*I+15 downto 16*I) = IP_KEY2(16*I+15 downto 16*I)) then
				IP_KEY2_BMATCH(I) <= '1';
			else
				IP_KEY2_BMATCH(I) <= '0';
			end if;
		end loop;
		if(DOB(112) = IP_KEY2(64)) then
			IP_KEY2_BMATCH(4) <= '1';
		else
			IP_KEY2_BMATCH(4) <= '1';
		end if;
		
	end if;
end process;

-- same for zero address. break into 4*16 comparisons for timing
ZERO_IP_MATCH_DETECT_001: process(CLK)
begin
	if rising_edge(CLK) then
		-- break 64-bit comparison into 4*16-bit comparisons
		for I in 0 to 3 loop
			if(DOA(16*I+15 downto 16*I) = x"0000") then
				ZERO_IP_AMATCH(I) <= '1';
			else
				ZERO_IP_AMATCH(I) <= '0';
			end if;
		end loop;
	end if;
end process;

--//-- KEY MATCH ---------------------------------------------------
IP_KEY1 <= RT_IPv4_6n_D & RT_IP_ADDR_D(63 downto 0);
IP_KEY2 <= RX_IPv4_6n_D & RX_SOURCE_IP_ADDR_D(63 downto 0);

-- Since both A and B sides of the block RAM are independently searching for IP address keys,
-- it will save time if we check both A and B outputs for match.

-- IP_KEY_MATCH and IP_KEY1_ADDR valid during STATE_X_D3		
IP_KEY1_MATCH_DETECT_002: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			IP_KEY1_MATCH <= '0';
			IP_KEY1_MAC <= (others => '0');
			IP_KEY1_TIME <= (others => '0');
		elsif((STATE_B_D2 = 2) or (STATE_B_D2 = 3)) and (IP_KEY1_BMATCH = "11111") then	-- *052419
			-- found a match for IP_KEY1 at ADDRB_D2 while scanning B-side
			IP_KEY1_MATCH <= '1';
			IP_KEY1_MAC <= DOB_D(111 downto 64);
			IP_KEY1_TIME <= unsigned(DOB_D(132 downto 113));
		elsif(STATE_A_D2 = 3) and (IP_KEY1_AMATCH = "11111")  then
			-- found a match for IP_KEY1 at ADDRA_D2 while scanning A-side
			IP_KEY1_MATCH <= '1';
			IP_KEY1_MAC <= DOA_D(111 downto 64);
			IP_KEY1_TIME <= unsigned(DOA_D(132 downto 113));
		else
			IP_KEY1_MATCH <= '0';
		end if;
	end if;
end process;

-- IP_KEY_MATCH and IP_KEY2_ADDR valid during STATE_X_D3		
IP_KEY2_MATCH_DETECT_002: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			IP_KEY2_MATCH <= '0';
			IP_KEY2_ADDR <= (others => '0');
		elsif(STATE_B_D2 = 3) and (IP_KEY2_BMATCH = "11111") then
			-- found a match for IP_KEY2 at ADDRB_D2 while scanning B-side
			IP_KEY2_MATCH <= '1';
			IP_KEY2_ADDR <= std_logic_vector(ADDRB_D2(ADDR_WIDTH-2 downto 0));
		elsif(STATE_A_D2 = 3) and (IP_KEY2_AMATCH = "11111")  then
			-- found a match for IP_KEY2 at ADDRA_D2 while scanning A-side
			IP_KEY2_MATCH <= '1';
			IP_KEY2_ADDR <= std_logic_vector(ADDRA_D2(ADDR_WIDTH-2 downto 0));
		else
			IP_KEY2_MATCH <= '0';
		end if;
	end if;
end process;


--//-- NEW MAC/IP ADDRESSES ---------------------------------------------------
-- Received another entry (decoded from received an IP or ARP response packet)
NEW_ENTRY_001: process(CLK)
begin
	if rising_edge(CLK) then
		-- new entry
		if(STATE_A = 0) and (RX_SOURCE_ADDR_RDY = '1') then
			-- idle + new entry. freeze input information during the processing 
			-- just in case two requests are very close to eachother.
			RX_SOURCE_MAC_ADDR_D <= RX_SOURCE_MAC_ADDR;
			RX_SOURCE_IP_ADDR_D <= RX_SOURCE_IP_ADDR;
			RX_IPv4_6n_D <= RX_IPv4_6n;
			if(RX_IPv4_6n = '1') then
                 RX_SOURCE_IP_ADDR_MASKED(31 downto 0) <= RX_SOURCE_IP_ADDR(31 downto 0) and IPv4_SUBNET_MASK;
            elsif(IPv6_ENABLED = '1') then
                 -- IPv6
                 RX_SOURCE_IP_ADDR_MASKED <= RX_SOURCE_IP_ADDR(63 downto 0) and IPv6_SUBNET_MASK;
            end if;
		end if;
		
		-- special case/shortcut: detect Gateway4 MAC address immediately (saves time instead of searching)
		if(SYNC_RESET = '1') then
			GATEWAYv4_MAC_ADDR <= (others => '0');
		elsif(RX_SOURCE_ADDR_RDY = '1') and (RX_IPv4_6n = '1') and (RX_SOURCE_IP_ADDR(31 downto 0) = IPv4_GATEWAY_ADDR) then
			GATEWAYv4_MAC_ADDR <= RX_SOURCE_MAC_ADDR;
		end if;

 		-- special case/shortcut: detect Gateway6 MAC address immediately (saves time instead of searching)
		if(SYNC_RESET = '1') then
			GATEWAYv6_MAC_ADDR <= (others => '0');
		elsif(RX_SOURCE_ADDR_RDY = '1') and (IPv6_ENABLED = '1') and (RX_IPv4_6n = '0') and (RX_SOURCE_IP_ADDR = IPv6_GATEWAY_ADDR) then
			GATEWAYv6_MAC_ADDR <= RX_SOURCE_MAC_ADDR;
		end if;
	end if;
end process;


--//-- A-SIDE STATE MACHINE ---------------------------------------
-- A-side of the block RAM used for (a) finding out the oldest entry and (b) save MAC/IP/timestamp
-- based on received packets (ARP response or IP)

EVENTA1 <= '1' when (TIMEDIFF < LAST_RX_TIME) or ((TIMEDIFF(TIMEDIFF'left) = '1') and (LAST_RX_TIME(LAST_RX_TIME'left) = '0')) else '0';
    -- '1' when LAST_RX_TIME is recent (i.e. occurred less than refresh period)
    -- Code is a bit tricky because of the wrap-around unsigned time
    -- Also because we rephrased this time comparison for better timing (TIMEDIFF is pipelined already)

STATE_MACHINE_A_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		ADDRA_D <= ADDRA; 
		ADDRA_D2 <= ADDRA_D; 
		STATE_A_D <= STATE_A;
		STATE_A_D2 <= STATE_A_D;
		
		if(SYNC_RESET = '1') or (MEMORY_INITIALIZED = '0') then
			STATE_A <= 0;  
			WEA <= '0';
			DIA <= (others => '0');
			ADDRA <= (others => '0');
			LAST_RX_MAC <= (others => '0');
			LAST_RX_IP <= (others => '0');
			LAST_RX_TIME <= (others => '0');
		elsif(STATE_A = 0) then
			WEA <= '0';
			if(RX_SOURCE_ADDR_RDY = '1') then
				-- idle + new entry. 
				STATE_A <= 1;
				ADDRA <= (others => '0');
			end if;
		elsif(STATE_A = 1) then
			if(RX_IPv4_6n_D = '1') then
    			-- SKIP LOOKUP CASES, don't waste time re-entering the information.
                if(unsigned(RX_SOURCE_IP_ADDR_D(31 downto 0)) = 0) then
                    -- (a) meaningless zero IP address -> skip
                    STATE_A <= 0;	-- go back to idle.
                elsif(RX_SOURCE_IP_ADDR_D(31 downto 0) = x"7F000001") then
                    -- (b) meaningless localhost address -> skip
                    STATE_A <= 0;	-- go back to idle.
                elsif(RX_SOURCE_IP_ADDR_D(31 downto 0) = IPv4_ADDR) then
                    -- (c) meaningless self address -> skip
                    STATE_A <= 0;	-- go back to idle.
                elsif(RX_SOURCE_IP_ADDR_D(31 downto 0) = LAST_RX_IP(31 downto 0)) and (LAST_RX_IPv4_6n = '1') and (EVENTA1 = '1')  then
                    -- (d) duplicate entry. We just wrote this one.
                    STATE_A <= 0;	-- go back to idle.
                elsif(RX_SOURCE_IP_ADDR_MASKED(31 downto 0) /= IPv4_MASKED) then
                    -- (e) WAN address. No need to store the MAC address because it has already
                    -- been replaced by that of the gateway.
                    STATE_A <= 0;	-- go back to idle.
                elsif(RX_SOURCE_IP_ADDR_D(31 downto 0) = IPv4_GATEWAY_ADDR) then
                    -- (f) special case: gateway address is handled by a shortcut to minimize search time.
                    STATE_A <= 0;	-- go back to idle.
                else
                    -- SEARCH ROUTING TABLE
                    -- search routing table by IP address key.
                    STATE_A <= 2;
               end if;
			elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n_D = '0') then
    			-- SKIP LOOKUP CASES, don't waste time re-entering the information.
                if(unsigned(RX_SOURCE_IP_ADDR_D) = 0) then
                    -- (a) meaningless zero IP address -> skip
                    STATE_A <= 0;    -- go back to idle.
                elsif(unsigned(RX_SOURCE_IP_ADDR_D) = 1) then
                    -- (b) meaningless localhost address -> skip
                    STATE_A <= 0;    -- go back to idle.
                elsif(RX_SOURCE_IP_ADDR_D = IPv6_ADDR) then
                    -- (c) meaningless self address -> skip
                    STATE_A <= 0;    -- go back to idle.
                --elsif(RX_SOURCE_IP_ADDR_D(63 downto 0) = LAST_RX_IP(63 downto 0)) and (LAST_RX_IPv4_6n = '0') and ((TIME_CNTR - LAST_RX_TIME) < REFRESH_PERIOD) then
                -- rephrasing for better timing
                elsif(RX_SOURCE_IP_ADDR_D(63 downto 0) = LAST_RX_IP(63 downto 0)) and (LAST_RX_IPv4_6n = '0') and (TIMEDIFF < LAST_RX_TIME)  then
                    -- (d) duplicate entry. We just wrote this one.
                    STATE_A <= 0;    -- go back to idle.
                elsif (RX_SOURCE_IP_ADDR_D(127 downto 112) = x"FE80") and (RX_SOURCE_IP_ADDR_D(111 downto 64) /= IPv6_ADDR(111 downto 64)) then
                    -- (e) WAN unicast address. No need to store the MAC address because it has already
                    -- been replaced by that of the gateway.
                     STATE_A <= 0;    -- go back to idle.
                elsif (RX_SOURCE_IP_ADDR_D(127 downto 112) = x"FE80") and (RX_SOURCE_IP_ADDR_MASKED(63 downto 0) /= IPv6_MASKED) then
                     -- (f) WAN unicast address. No need to store the MAC address because it has already
                     -- been replaced by that of the gateway.
                      STATE_A <= 0;    -- go back to idle.
                else
                    -- SEARCH ROUTING TABLE
                    -- search routing table by IP address key.
                    STATE_A <= 2;
			     end if;
	       end if;
		elsif(STATE_A = 2) then
			-- needed an extra clock before starting the search
			STATE_A <= 3;
			ADDRA <= ADDRA + 1;
		elsif(STATE_A = 3) then
			-- scan address range 0 - 128 or until we find the target IP address
			if(IP_KEY2_MATCH = '1') then
				-- found a match
				ADDRA <= unsigned("0" & IP_KEY2_ADDR);
				STATE_A <= 4;  -- go write the MAC/IP/Timestamp to the routing table
			elsif(ADDRA_D2(ADDR_WIDTH-1) = '1') then
				-- reached the end of the scan without any key match
				-- note STATE_A=3 is extended three more clocks to wait for the last possible key match
				-- find the oldest table entry and overwrite it with the newer MAC/IP/Timestamp.
				ADDRA <= unsigned("0" & OLDEST_ADDR);   -- design note: OLDEST_ADDR is only used following a full table scan
				STATE_A <= 4;
		    elsif(ADDRA(ADDR_WIDTH-1) = '0') then
				-- scan until we find the IP address key
				ADDRA <= ADDRA + 1;
			end if;
		elsif(STATE_A = 4) then
			-- write IP address  + v4/v6n + MAC address + timestamp. A total of 133 bits 
			WEA <= '1';
			DIA(63 downto 0) <= RX_SOURCE_IP_ADDR_D(63 downto 0);
			DIA(111 downto 64) <= RX_SOURCE_MAC_ADDR_D;
			DIA(112) <= RX_IPv4_6n_D;
			DIA(132 downto 113) <= std_logic_vector(TIME_CNTR);
			STATE_A <= 0;
			-- remember so that we don't waste time doing successive repetitive write with the same parameters
			LAST_RX_IP <= RX_SOURCE_IP_ADDR_D;
			LAST_RX_MAC <= RX_SOURCE_MAC_ADDR_D;
			LAST_RX_IPv4_6n <= RX_IPv4_6n_D;
			LAST_RX_TIME <= TIME_CNTR;
		end if;
	end if;
end process;

--//-- FIND OLDEST ENTRY -----------------------------
TIME_A <= unsigned(DOA(132 downto 113));
TIME_B <= unsigned(DOB(132 downto 113));

OLDEST_DETECT_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') or (MEMORY_INITIALIZED = '0') then
			OLDEST_TIME <= (others => '0');
			OLDEST_ADDR <= (others => '0');
			VIRGIN <= '0';
		elsif(STATE_A = 0) then
			VIRGIN <= '0';
		elsif (STATE_A = 3) and (ZERO_IP_AMATCH = "1111") and (VIRGIN = '0') then
            -- virgin record. perfect for use as 'oldest entry'
            -- detect virgin record while scanning A side. Never been written to before. Therefore can be
            -- used as 'oldest' record. 
            OLDEST_ADDR <= ADDRA_D2(ADDR_WIDTH-2 downto 0);
            VIRGIN <= '1';  -- lowest address is better (shorter search). Stop updating OLDEST_ADDR
        elsif (STATE_A = 3) and (IP_KEY2_MATCH = '0') and (ADDRA_D2(ADDR_WIDTH-1) = '1') then
            -- reached the end of scan. No IP_KEY2 match
            -- oldest entry or virgin entry is overwritten.... thus is no longer the oldest. Reset
            OLDEST_TIME <= TIME_CNTR;   -- reset time

--		elsif (STATE_B_D = 3) and (ADDRB_D(1 downto 0)= "10") and (OLDEST_TIME(19 downto 18) = "00") 
--				and (TIME_B(19 downto 18) = "11") then
--			-- found older entry (accounting for modulo time) while reading B-side
--			OLDEST_TIME <= TIME_B;
--			OLDEST_ADDR <= ADDRB_D(8 downto 2) & "00";
--		elsif (STATE_B_D = 3) and (ADDRB_D(1 downto 0)= "10") and (OLDEST_TIME > TIME_B) then
--			-- found older entry while reading B-side
--			OLDEST_TIME <= TIME_B;
--			OLDEST_ADDR <= ADDRB_D(8 downto 2) & "00";
		elsif (STATE_A = 3) and (VIRGIN = '0') and (OLDEST_TIME(19 downto 18) = "00") 
				and (TIME_A(19 downto 18) = "11") then
			-- found older entry (accounting for modulo time) while reading A-side
			-- Note: virgin entry has precedence
			OLDEST_TIME <= TIME_A;
			OLDEST_ADDR <= ADDRA_D(ADDR_WIDTH-2 downto 0);
		elsif (STATE_A = 3) and (VIRGIN = '0') and (OLDEST_TIME > TIME_A) then
			-- found older entry while reading A-side
			-- Note: virgin entry has precedence
			OLDEST_TIME <= TIME_A;
			OLDEST_ADDR <= ADDRA_D(ADDR_WIDTH-2 downto 0);
		end if;
	end if;
end process;

----// Test Point
--TP(1) <= RT_REQ_RTS;
--TP(2) <= '1' when (STATE_B = 0) else '0';  --RT_CTS 
--TP(3) <= RT_MAC_RDY_local;
--TP(4) <= RT_NAK_local;

--TP(5) <= WHOIS_START_local;

--TP(6) <= RX_SOURCE_ADDR_RDY;
--TP(7) <= '1' when (STATE_A = 0) else '0';
--TP(8) <= '1' when (STATE_A = 3) and (IP_KEY2_MATCH = '1') else '0';
--TP(9) <= '1' when (STATE_A = 3) and (ADDRA_D(7) = '1') else '0';
--TP(10) <= '1' when (STATE_A = 4) else '0';

TP(1) <= '1' when (IPv4GATEWAY_REFRESH_TIMER = 0) else '0';
TP(2) <= '1' when (STATE_B = 0) else '0';
TP(3) <= WHOIS_IPv4GATEWAY;

----SREG1 <= OLDEST_ADDR(7 downto 0);
----SREG2 <= LAST_IP(31 downto 24);
----SREG3 <= LAST_IP(23 downto 16);
----SREG4 <= LAST_IP(15 downto 8);
----SREG5 <= LAST_IP(7 downto 0);
----SREG6 <= OLDEST_ADDR(7 downto 0);

end Behavioral;
