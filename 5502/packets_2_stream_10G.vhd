-------------------------------------------------------------
-- MSS copyright 2011-2018
-- Filename:  PACKETS_2_STREAM_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 0
-- Date last modified: 7/20/16
-- Inheritance: 	PACKETS_2_STREAM.VHD 1G 7/20/16
--
-- description: Receive packets (in sequence) and reassemble a stream. 
-- The packets validity is checked upon receiving the last packet byte. Any failure
-- will cause this component to discard the invalid packet and rewind the write pointer in the
-- elastic buffer to the previous valid location.
-- No flow control on the packets side. Flow-control (see APP_CTS) on the application side.
--
-- This component can interface seemlessly with USB_RX.vhd at the input to receive
-- input packets conveyed as UDP frames over the network. 
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity PACKETS_2_STREAM_10G is
	generic (
		ADDR_WIDTH: integer := 8
			-- allocates buffer space: 73 bits * 2^ADDR_WIDTH words
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;		-- synchronous clock
			-- Must be a global clocks. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;

		--// INPUT PACKETS
		-- For example, interfaces with UDP_RX
		PACKET_DATA_IN: in std_logic_vector(63 downto 0);
		PACKET_DATA_VALID_IN: in std_logic_vector(7 downto 0);
		PACKET_FRAME_VALID_IN: in std_logic;
		PACKET_EOF_IN: in std_logic;
			-- 1 CLK pulse indicating that PACKET_DATA_IN is the last byte in the received packet.
			-- ALWAYS CHECK PACKET_FRAME_VALID_IN at the end of packet (PACKET_EOF_IN = '1') to confirm
			-- that the packet is valid. Internal elastic buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid packet.
			-- Reason: we only knows about bad UDP packets at the end.
		PACKET_CTS_OUT: out std_logic;  -- Clear To Send = transmit flow control. 


		--// OUTPUT STREAM
		STREAM_DATA_OUT: out std_logic_vector(63 downto 0);
		STREAM_DATA_VALID_OUT: out std_logic_vector(7 downto 0);
		STREAM_CTS_IN: in std_logic; 	-- flow control, clear-to-send
	
	    STREAM_SOF_OUT: out std_logic;
	    STREAM_EOF_OUT: out std_logic;
	       -- optional SOF/EOF markers
	    
		--// TEST POINTS, MONITORING
		BAD_PACKET: out std_logic;
			-- 1 CLK wide pulse indicating a bad packet
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of PACKETS_2_STREAM_10G is
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
		CSA : IN std_logic;
		CLKA   : in  std_logic;
		WEA    : in  std_logic;
		OEA : IN std_logic;
		ADDRA  : in  std_logic_vector(ADDR_WIDTHA-1 downto 0);
		DIA   : in  std_logic_vector(DATA_WIDTHA-1 downto 0);
		DOA  : out std_logic_vector(DATA_WIDTHA-1 downto 0);
		CSB : IN std_logic;
		CLKB   : in  std_logic;
		WEB    : in  std_logic;
		OEB : IN std_logic;
		ADDRB  : in  std_logic_vector(ADDR_WIDTHB-1 downto 0);
		DIB   : in  std_logic_vector(DATA_WIDTHB-1 downto 0);
		DOB  : out std_logic_vector(DATA_WIDTHB-1 downto 0)
        );
    END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates a one CLK early version of the net with the same name
-- Suffix _X indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

--//-- ELASTIC BUFFER ---------------------------
signal WPTR: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WPTR_ACKED: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WEA: std_logic := '0';
signal DIAx: std_logic_vector(72 downto 0) := (others => '0');
signal RPTR: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal RPTR_D: unsigned(ADDR_WIDTH-1 downto 0) := (others => '1');
signal BUF_SIZE: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal BUF_SIZE_ACKED: unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal DOBx: std_logic_vector(72 downto 0) := (others => '0');
signal DATA_VALID_E: std_logic := '0';
signal DATA_VALID: std_logic := '0';
signal SOFn_FLAG: std_logic := '0';
signal STREAM_EOF_OUT_local: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- report a bad input packet
BAD_PACKET <= PACKET_EOF_IN and (not PACKET_FRAME_VALID_IN);

--//-- ELASTIC BUFFER ---------------------------
WEA <= '1' when (unsigned(PACKET_DATA_VALID_IN) /= 0) else '0';
WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			WPTR <= (others => '0');
			WPTR_ACKED <= (others => '0');
		elsif(WEA = '1') then
			WPTR <= WPTR + 1;
			if(PACKET_EOF_IN = '1') then
				-- last byte in the received packet. Packet is valid. Remember the next start of packet
				WPTR_ACKED <= WPTR + 1;
			end if;
		elsif(PACKET_EOF_IN = '1')then
			-- last byte in the received packet. Packet is invalid. Discard it (i.e. rewind the write pointer)
			WPTR <= WPTR_ACKED;
		end if;
	end if;
end process;

DIAx <= PACKET_EOF_IN & PACKET_DATA_VALID_IN & PACKET_DATA_IN; 
-- Buffer size is controlled by generic ADDR_WIDTH
BRAM_DP2_001: BRAM_DP2 
GENERIC MAP(
    DATA_WIDTHA => 73,		
    ADDR_WIDTHA => ADDR_WIDTH,
    DATA_WIDTHB => 73,		 
    ADDR_WIDTHB => ADDR_WIDTH
)
PORT MAP(
    CSA => '1',
    CLKA => CLK,
    WEA => WEA,      -- Port A Write Enable Input
    ADDRA => std_logic_vector(WPTR),  
    DIA => DIAx,      
    OEA => '0',
    DOA => open,
    CSB => '1',
    CLKB => CLK,
    WEB => '0',
    ADDRB => std_logic_vector(RPTR),  
    DIB => (others => '0'),      
    OEB => '1',
    DOB => DOBx      
);

BUF_SIZE <= WPTR + not (RPTR);
BUF_SIZE_ACKED <= WPTR_ACKED + not (RPTR);
	-- occupied space in the buffer 
	-- confirmed and unconfirmed
	
-- input flow control (buffer 3/4 full)
PACKET_CTS_OUT <= '0' when (BUF_SIZE(ADDR_WIDTH-1 downto ADDR_WIDTH-2) = "11") else '1';

-- manage read pointer
RPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RPTR <= (others => '1');
			RPTR_D <= (others => '1');
			DATA_VALID_E <= '0';
			DATA_VALID <= '0';
		else
			-- 1 CLK delay in reading data from block RAM
			RPTR_D <= RPTR;	
			DATA_VALID <= DATA_VALID_E;
			
			if(STREAM_CTS_IN = '1') and (BUF_SIZE_ACKED /= 0) then
				RPTR <= RPTR + 1;
				DATA_VALID_E <= '1';
			else
				DATA_VALID_E <= '0';
			end if;
		end if;
	end if;
end process;

--//-- OUTPUT --------------------------------
STREAM_DATA_OUT <= DOBx(63 downto 0);
STREAM_DATA_VALID_OUT <= DOBx(71 downto 64) when (DATA_VALID = '1') else (others => '0');
STREAM_EOF_OUT_local <= DOBx(72) and DATA_VALID;
STREAM_EOF_OUT <= STREAM_EOF_OUT_local;
STREAM_SOF_OUT <= DATA_VALID and (not SOFn_FLAG);

-- reconstruct SOF marker
SOF_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			SOFn_FLAG <= '0';   -- arm
	  elsif(STREAM_EOF_OUT_local = '1') then
			SOFn_FLAG <= '0';   -- arm
	  elsif(DATA_VALID = '1') then
			SOFn_FLAG <= '1';   -- clear
	  end if;
	end if;
end process;

--//-- TEST POINTS ----------------------------
TP(1) <= WPTR(0);
TP(2) <= RPTR(0);
TP(3) <= WPTR(ADDR_WIDTH-1);
TP(4) <= RPTR(ADDR_WIDTH-1);
TP(5) <= '1' when (BUF_SIZE = 0) else '0';
TP(6) <= '1' when (BUF_SIZE_ACKED = 0) else '0';
end Behavioral;
