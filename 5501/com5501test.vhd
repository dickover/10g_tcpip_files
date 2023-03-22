-------------------------------------------------------------
-- MSS copyright 2017-2018
--	Filename:  COM5501.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 3/1/18
-- Inheritance: 	COM5401.vhd
-- 
-- description:  10G Ethernet MAC with XGMII hardware interface
-- Features include
-- (a) Automatic appending of 32-bit CRC to tx packets. Users don't have to.
-- (b) discarding of rx packets with bad CRC.
-- (c) implement MAC pause control
--
-- The transmit elastic buffer is large enough for 2 maximum size frame. The tx Clear To Send (MAC_TX_CTS)
-- signal is raised when the the MAC is ready to accept one complete frame without interruption.
-- In this case, MAC_TX_CTS may go low while the frame transfer has started, but there is guaranteed
-- space for the entire frame.  
-------------------------------------------
-- Device utilization 
-------------------------------------------
--Number of Slice Registers: 1512
--Number of Slice LUTs: 2389
--Number of 18 Kb Block RAM/FIFO: 8
--Number of DSP48: 0
--Number of BUFG: 2
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity COM5501 is
	generic (
		EXT_PHY_MDIO_ADDR: std_logic_vector(4 downto 0) := "00000";	
			-- external PHY MDIO address
		RX_MTU: integer := 1500;
			-- Maximum Transmission Unit: maximum number of payload Bytes.
			-- Typically 1500 for standard frames, 9000 for jumbo frames.
			-- A frame will be deemed invalid if its payload size exceeds this MTU value.
		RX_BUFFER: std_logic := '0';
			-- '1' when the received messages are stored temporarily into an elastic buffer prior to the output. 
			-- either because the next block is slower (and thus regulates the data flow), or when crossing clock
			-- domains from CLK156g to CLK. 
			-- '0' for no output buffer: when flow control is not needed on the rx path and 
			-- the same 156.25 MHz clock is used as both user clock CLK and PHY clock CLK156g. 
			-- This setting is preferred for the lowest latency on the receive path.
		RX_BUFFER_ADDR_NBITS: integer := 10;
			-- size of the receiver output elastic buffer (when enabled by RX_BUFFER = '1'). Data width is always 69 bits.
			-- Example: when RX_BUFFER_ADDR_NBITS = 10, the receive buffer size is 74*2^10 = 75776 bits
		TX_MTU: integer := 1500;
		TX_BUFFER: std_logic := '0';
			-- '1' when the transmit messages are stored temporarily into an input elastic buffer,
			-- when crossing clock domains from user CLK to PHY CLK156g. 
			-- '0' for no input buffer: when the same 156.25 MHz clock is used as both user clock CLK and PHY clock CLK156g. 
			-- This setting is preferred for the lowest latency on the transmit path.
		TX_BUFFER_ADDR_NBITS: integer := 10;
		MAC_CONTROL_PAUSE_ENABLE: std_logic := '1';
		  -- enable (1)/disable (0) enacting transmit pause upon receive a MAC control PAUSE message.
		SIMULATION: std_logic := '0'
			-- during simulation, fake LINK_STATUS = '1'
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;
			-- USER-side GLOBAL clock. Must be at least 156.25 MHz for full 10Gbits/s throughput.
			-- It must be the same signal as CLK156g when RX_BUFFER = '0' 
		SYNC_RESET: in std_logic;
			-- reset pulse must be > slowest clock period  (>400ns)
			-- synchronous with CLK
		CLK156g: in std_logic;
			-- PHY-side GLOBAL clock at 156.25 MHz
		
		--// MAC CONFIGURATION
		-- configuration signals are synchonous with the user-side CLK
		MAC_TX_CONFIG: in std_logic_vector(7 downto 0);
			-- bit 0: (1) Automatic padding of short frames. Requires that auto-CRC insertion be enabled too. 
			--			 (0) Skip padding. User is responsible for adding padding to meet the minimum 60 byte frame size
			-- bit 1: (1) Automatic appending of 32-bit CRC at the end of the frame
			--			 (0) Skip CRC32 insertion. User is responsible for including the frame check sequence
			-- bit 2: (1) Verify MTU size. Frames will be flagged as invalid if the payload size exceeds RX_MTU Bytes.
			--			 (0) Do not check MTU size
			-- Note: use 0x03 when interfacing with COM-5502 IP/UDP/TCP stack.
		MAC_RX_CONFIG: in std_logic_vector(7 downto 0);
			-- bit 0: (1) promiscuous mode enabled (0) disabled, i.e. destination address is verified for each incoming packet 
			-- bit 1: (1) accept broadcast rx packets (0) reject
			-- bit 2: (1) accept multi-cast rx packets (0) reject
			-- bit 3: (1) filter out the 4-byte CRC field (0) pass along the CRC field.
			-- 			  IGNORED IN LOW-LATENCY RECEIVE MODE when RX_BUFFER = '0': CRC is passed along in this case.
			-- bit 4: (1) Verify MTU size. Frames will be flagged as invalid if the payload size exceeds RX_MTU Bytes.
			--			 (0) Do not check MTU size
			-- Note2: use 0x0F when interfacing with COM-5502 IP/UDP/TCP stack.
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- This network node 48-bit MAC address. The receiver checks incoming packets for a match between 
			-- the destination address field and this MAC address.
			-- The user is responsible for selecting a unique ‘hardware’ address for each instantiation.
			-- Natural bit order: enter x0123456789ab for the MAC address 01:23:45:67:89:ab
			-- here, x01 is the first received/transmitted byte in the address

		--// USER -> Transmit MAC Interface
		-- Synchonous with the user-side CLK
		MAC_TX_DATA: in std_logic_vector(63 downto 0);
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
			-- Bytes order: LSB is sent first
			-- Bytes are right aligned: first byte in LSB, occasional follow-on fill-in Bytes in the MSB(s)
			-- The first destination address byte is always a LSB (MAC_TX_DATA(7:0))
			-- USAGE RULE: only the end of frame word can be partially full (MAC_TX_DATA_VALID = 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f)
			-- all other words must contain either 0 or 8 bytes. 
		MAC_TX_DATA_VALID: in std_logic_vector(7 downto 0);
			-- '1' for each meaningful byte in MAC_TX_DATA. 
			-- In this application, only valid values are 0x00, 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff
		MAC_TX_EOF: in std_logic;
			-- '1' when sending the last word in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: out std_logic;
			-- MAC-generated Clear To Send flow control signal, indicating room in the 
			-- tx elastic buffer for a complete MTU. 
			-- The user should check that this signal is high before deciding to send
			-- sending the next frame. 
			-- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it.
		
		--// Receive MAC -> USER Interface
		-- Valid rx packets only: packets with bad CRC or invalid address are discarded.
		-- Synchonous with the user-side CLK
		-- The short-frame padding is included .
		MAC_RX_DATA: out std_logic_vector(63 downto 0);
			-- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID = '1'
			-- Bytes order: LSB was received first
			-- Bytes are right aligned: first byte in LSB, occasional follow-on fill-in Bytes in the MSB(s)
			-- The first destination address byte is always a LSB (MAC_RX_DATA(7:0))
		MAC_RX_DATA_VALID: out std_logic_vector(7 downto 0);
			-- '1' for each meaningful byte in MAC_RX_DATA. 
			-- In this application, only valid values are 0x00, 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff
		MAC_RX_SOF: out std_logic;
			-- '1' when sending the first byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_EOF: out std_logic;
			-- '1' when sending the last byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
			-- The entire frame validity is confirmed at the end of frame when MAC_RX_FRAME_VALID = '1' 
			-- Users should discard the entire frame when MAC_RX_FRAME_VALID = '0' at  MAC_RX_EOF
		MAC_RX_FRAME_VALID: out std_logic;
			-- '1' when the received frame passed all validity checks, including CRC32.
			-- Read at the end of frame when MAC_RX_EOF = '1'
		MAC_RX_CTS: in std_logic;
			-- User-generated Clear To Send flow control signal. The receive MAC checks that this 
			-- signal is high before sending the next MAC_RX_DATA byte. 
			-- Ignored when the rx output buffer is not instantiated (RX_BUFFER = '0')
		-- parsed information from received MAC frame

		
		--// XGMII PHY Interface 
		XGMII_TXD: out std_logic_vector(63 downto 0);
		XGMII_TXC: out std_logic_vector(7 downto 0);
			-- Single data rate transmit interface 
			-- LSB is sent first
		
		XGMII_RXD: in std_logic_vector(63 downto 0);
		XGMII_RXC: in std_logic_vector(7 downto 0);
			-- Single data rate receive interface 
			-- LSb of LSB is received first
			-- Start character 0xFB is in byte 0 or 4
			-- XGMII_RXC bit is '0' for valid data byte
		RESET_N: out std_logic;
			-- PHY reset#
		MDC: out std_logic;
		MDIO_OUT: out std_logic;  
		MDIO_IN: in std_logic;
		MDIO_DIR: out std_logic;	-- '0' when output, '1' when input
			-- MDIO serial interface to control and monitor two MMDs: external 10G PHY and 
			-- internal XAUI adapter.

		--// PHY CONFIGURATION
		-- configuration signals are synchonous with the user-side CLK.
		PHY_CONFIG_CHANGE: in std_logic;
			-- optional pulse to activate any configuration change below.
			-- Not needed if the internal default values are acceptable.
		PHY_RESET: in std_logic; 
			-- 1 = PHY software reset (default), 0 = no reset
		TEST_MODE: in std_logic_vector(1 downto 0);
			-- 00 = normal mode (default)
			-- 01 = loopback mode
			-- 10 = remote loopback
		POWER_DOWN: in std_logic;
			-- software power down mode. 1 = enabled, 0 = disabled (default).


		--// PHY status
		-- synchronous with CLK156g global clock
		PHY_STATUS: out std_logic_vector(7 downto 0);
			-- XAUI side of the PHY chip
			-- bit0: all PHY XAUI rx lanes in sync
			-- bit1: PHY XAUI rx PLL in lock
			-- bit2: PHY XAUI rx lane0 signal present
			-- bit3: PHY XAUI rx lane1 signal present
			-- bit4: PHY XAUI rx lane2 signal present
			-- bit5: PHY XAUI rx lane3 signal present
			-- Expecting 0x3F during normal operations
			-- read periodically.
		PHY_STATUS2: out std_logic_vector(7 downto 0);
			-- SFP+ side of the PHY chip
		PHY_ID: out std_logic_vector(15 downto 0);
			-- read PHY device ID (part of hardware self-test). Correct answer for VSC8486-11 is 0x8486
			-- read once at power up.
			
		--// DIAGNOSTICS (synchronous with user-supplied clock CLK) 
		N_RX_FRAMES: out  std_logic_vector(15 downto 0);
			-- number of received frames
		N_RX_BAD_CRCS: out  std_logic_vector(15 downto 0);
			-- number of BAD CRCs among the received frames
		N_RX_FRAMES_TOO_SHORT: out  std_logic_vector(15 downto 0);
			-- number of rx frames too short (<64B)
		N_RX_FRAMES_TOO_LONG: out  std_logic_vector(15 downto 0);
			-- number of rx frames too long (>1518B)
		N_RX_WRONG_ADDR: out  std_logic_vector(15 downto 0);
			-- number of rx frames where address does not match (and promiscuous mode is off)
		N_RX_LENGTH_ERRORS: out  std_logic_vector(15 downto 0);
			-- number of rx frames with length field inconsistent with actual rx frame length
		RX_IPG: out std_logic_vector(7 downto 0);
			-- InterPacket Gap (in Bytes) between the last two successive packets (min is typically 12 Bytes, but
			-- can be as low as 5 Bytes for 10G).

		--// TEST POINTS
		DEBUG1: out std_logic_vector(63 downto 0);
		DEBUG2: out std_logic_vector(63 downto 0);
		DEBUG3: out std_logic_vector(63 downto 0);
		TP: out std_logic_vector(10 downto 1)
		
 );
end entity;

architecture Behavioral of COM5501 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT PHY_CONFIG
	GENERIC (
		EXT_PHY_MDIO_ADDR: std_logic_vector(4 downto 0)	
			-- external PHY MDIO address
	);	
	PORT(
		SYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		CONFIG_CHANGE : IN std_logic;
		PHY_RESET: in std_logic; 
		TEST_MODE: in std_logic_vector(1 downto 0);
		POWER_DOWN: in std_logic;
		SREG_READ_START : IN std_logic;
		SREG_MMD: in std_logic_vector(4 downto 0);	
		SREG_ADDR: in std_logic_vector(15 downto 0);	
		SREG_DATA : OUT std_logic_vector(15 downto 0);
		SREG_SAMPLE_CLK : OUT std_logic;
		MDC: out std_logic;
		MDIO_OUT: out std_logic;  
		MDIO_IN: in std_logic;
		MDIO_DIR: out std_logic;	-- '0' when output, '1' when input
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;

    COMPONENT CRC32
    PORT(
        CLK : IN  std_logic;
        DATA_IN : IN  std_logic_vector(63 downto 0);
        SAMPLE_CLK_IN : IN  std_logic;
        SOF_IN: in std_logic;
        DATA_VALID_IN : IN  std_logic_vector(7 downto 0);
        CRC_INITIALIZATION: in std_logic_vector(31 downto 0);
        CRC_OUT : OUT  std_logic_vector(31 downto 0);
        SAMPLE_CLK_OUT : OUT  std_logic
        );
    END COMPONENT;

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

--	COMPONENT TEST_XGMII_TX
--	PORT(
--		CLK156g : IN std_logic;
--		SYNC_RESET156 : IN std_logic;
--		TX_TRIGGER : IN std_logic;          
--		XGMII_TXD : OUT std_logic_vector(63 downto 0);
--		XGMII_TXC : OUT std_logic_vector(7 downto 0);
--		TP : OUT std_logic_vector(10 downto 1)
--		);
--	END COMPONENT;
	
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- NOTATIONS: 
-- _E as one-CLK early sample
-- _D as one-CLK delayed sample
-- _D2 as two-CLKs delayed sample

--// CLK & RESETS ---------

signal SYNC_RESET_D: std_logic := '0';
signal SYNC_RESET156: std_logic := '0';

--// PHY RESET AND CONFIGURATION ----------------------------------------------------------
signal RESET_CNTR: unsigned(8 downto 0) := (others => '0');
signal SYNC_RESET_local: std_logic := '0';
signal RESET_COMPLETE: std_logic := '0';
signal INITIAL_CONFIG_PULSE: std_logic := '1';
signal PHY_CONFIG_CHANGE_PENDING: std_logic := '0';
signal PHY_CONFIG_CHANGE_A: std_logic := '0';


signal PHY_RESET_A: std_logic := '0';
signal TEST_MODE_A: std_logic_vector(1 downto 0);
signal POWER_DOWN_A: std_logic := '0';
signal PHY_IF_WRAPPER_RESET: std_logic := '0';
signal SREG_READ_START: std_logic := '0';
signal SREG_SAMPLE_CLK: std_logic := '0';
signal LINK_STATUS_local: std_logic := '0';
signal SREG_MMD: std_logic_vector(4 downto 0) := (others => '0');
signal SREG_ADDR: std_logic_vector(15 downto 0) := (others => '0');
signal SREG_DATA : std_logic_vector(15 downto 0) := (others => '0');
signal SREG_STATE: unsigned(2 downto 0) := (others => '0');

--// LOW-LATENCY TX INPUT ----------------------------------------------------------
signal MAC_TX_INFRAME: std_logic := '0';
signal MAC_TX_DATA2: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_TX_DATA2_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal MAC_TX_SOF2: std_logic := '0';
signal MAC_TX_EOF2: std_logic := '0';

--//  TX ELASTIC BUFFER ----------------------------------------------------------
signal MAC_TX_DIA: std_logic_vector(72 downto 0) := (others => '0');
signal MAC_TX_DOB: std_logic_vector(72 downto 0) := (others => '0');
signal MAC_TX_WPTR: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_TX_WPTR_D: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_TX_WPTR_D2: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_TX_WPTR_D3: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_TX_WPTR_STABLE: std_logic := '0';
signal MAC_TX_WPTR_STABLE_D: std_logic := '0';
signal TX_COUNTER8: unsigned(2 downto 0) :=(others => '0');
signal MAC_TX_WEA: std_logic := '0';
signal MAC_TX_SAMPLE2_CLK: std_logic := '0';	-- TODO
signal MAC_TX_SAMPLE2_CLK_E: std_logic := '0';	-- TODO

signal MAC_TX_BUF_SIZE: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_TX_RPTR: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '1');
signal MAC_TX_RPTR_D: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '1');
signal MAC_TX_RPTR_CONFIRMED: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '1');
signal MAC_TX_RPTR_CONFIRMED_D: unsigned(TX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '1');
signal COMPLETE_TX_FRAMES_INBUF: std_logic_vector(7 downto 0) := x"00";  -- can't have more than 147 frames in a 16k buffer
signal ATLEAST1_COMPLETE_TX_FRAME_INBUF: std_logic := '0';
signal MAC_TX_EOF_TOGGLE: std_logic := '0';
signal MAC_TX_EOF_TOGGLE_D: std_logic := '0';
signal MAC_TX_EOF_TOGGLE_D2: std_logic := '0';
signal MAC_TX_CTS_local: std_logic := '0';

--// SHORT FRAME PADDING ----------------------------------------------------------
signal TX_BYTE_CNTR: unsigned(13 downto 0):= (others => '0');  -- large enough for counting 9000 bytes in Jumbo frame
signal TX_FILL_CNTR: unsigned(5 downto 0):= (others => '0');  -- range 0 - 60
signal TX_FILL_NEXT: std_logic := '0';
signal MAC_TX_DATA3: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_TX_DATA3_D: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_TX_DATA3_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal MAC_TX_DATA3_VALID_D: std_logic_vector(7 downto 0) := (others => '0');
signal MAC_TX_SOF3: std_logic := '0';
signal MAC_TX_EOF3: std_logic := '0';
signal MAC_TX_EOF3_D: std_logic := '0';
signal MAC_TX_EOF3_D2: std_logic := '0';

--//  TX 32-BIT CRC COMPUTATION -------------------------------------------------------
signal TX_CRC_DATA_IN: std_logic_vector(63 downto 0) := (others => '0');
signal TX_CRC_SAMPLE_CLK_IN: std_logic := '0';
signal TX_CRC_DATA_VALID_IN: std_logic_vector(7 downto 0):= (others => '0');
signal TX_CRC32: std_logic_vector(31 downto 0) := (others => '0');
signal TX_CRC_SAMPLE_CLK_OUT: std_logic := '0';
signal TX_CRC32_FLIPPED_INV: std_logic_vector(31 downto 0) := (others => '0');

--//-- XGMII TX INTERFACE --------------------------------
signal XGMII_TXD_NEXT: std_logic_vector(63 downto 0) := (others => '0');
signal XGMII_TXC_NEXT: std_logic_vector(7 downto 0) := (others => '0');

--//-- TX FLOW CONTROL --------------------------------
signal TX_SUCCESS_TOGGLE: std_logic := '0';
signal TX_SUCCESS_TOGGLE_D: std_logic := '0';
signal TX_SUCCESS_TOGGLE_D2: std_logic := '0';
signal MAC_TX_BUF_FREE: std_logic_vector(11 downto 0) := (others => '0');


--// MAC TX STATE MACHINE ----------------------------------------------------------
--signal TX_CLKG: std_logic := '0';
--signal IPG: std_logic := '0';
--signal IPG_CNTR: std_logic_vector(7 downto 0) := (others => '0');  -- TODO CHECK CONSISTENCY WITH TIMER VALUES
--signal TX_EVENT1: std_logic := '0';
--signal TX_EVENT2: std_logic := '0';
--signal TX_EVENT3: std_logic := '0';
--signal TX_STATE: integer range 0 to 15 := 0;
--signal TX_BYTE_COUNTER: std_logic_vector(18 downto 0) := (others => '0');  -- large enough for counting 2000 Bytes in max size packet
--signal TX_BYTE_COUNTER2: std_logic_vector(2 downto 0) := (others => '0');  -- small auxillary byte counter for small fields
--signal RETX_ATTEMPT_COUNTER: std_logic_vector(4 downto 0) := (others => '0'); -- re-transmission attempts counter
--signal TX_SUCCESS: std_logic := '0';
--signal TX_ER: std_logic := '0';



--//  TEST XGMII TX -------------------------------------------------------
signal TEST_XGMII_TX_TP: std_logic_vector(10 downto 1) := (others => '0');


--// MAC RX STATE MACHINE ----------------------------------------------------------
signal XGMII_RXD_D: std_logic_vector(63 downto 0) := (others => '0');
signal XGMII_RX_START_CHAR: std_logic := '0';
signal XGMII_RX_START_CHAR_D: std_logic := '0';	-- TEST TEST TEST DEL
signal XGMII_RX_START_LOC: unsigned(2 downto 0) := (others => '0');
signal XGMII_RX_SFD_CHAR: std_logic := '0';
signal XGMII_RX_SFD_LOC: unsigned(2 downto 0) := (others => '0');
signal XGMII_RX_TERM_CHAR: std_logic := '0';
signal XGMII_RX_TERM_LOC: unsigned(2 downto 0) := (others => '0');
signal XGMII_RX_ERROR_CHAR: std_logic := '0';
signal XGMII_RX_IN_FRAME: std_logic := '0';
signal XGMII_RX_DATA1: std_logic_vector(63 downto 0) := (others => '0');
signal XGMII_RX_DATA1A: std_logic_vector(31 downto 0) := (others => '0');
signal XGMII_RX_DATA1_D: std_logic_vector(63 downto 0) := (others => '0');
signal XGMII_RX_SAMPLE1_CLK: std_logic := '0';
signal XGMII_RX_SAMPLE1_CLK_D: std_logic := '0';
signal XGMII_RX_DATA1_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal XGMII_RX_DATA1_VALID_D: std_logic_vector(7 downto 0) := (others => '0');
signal XGMII_RX_SOF1: std_logic := '0';
signal XGMII_RX_SOF1_D: std_logic := '0';	-- TEST TEST TEST
signal XGMII_RX_SOF1_D2: std_logic := '0';	-- TEST TEST TEST
signal XGMII_RX_EOF1A: std_logic := '0';
signal XGMII_RX_EOF1: std_logic := '0';
signal XGMII_RX_EOF1_D: std_logic := '0';
signal XGMII_RX_FLUSH: std_logic := '0';
signal RX_STATE: integer range 0 to 3 := 0;
signal RX_STATE2: std_logic := '0';
signal RX_STATE2_D: std_logic := '0';
signal RX_TOO_SHORT: std_logic := '0';
signal RX_TOO_LONG: std_logic := '0';
signal RX_IPG_local: unsigned(8 downto 0):= (others => '0');
signal RX_VALID_ADDR: std_logic := '0';
signal MAC_ADDR_REORDER: std_logic_vector(47 downto 0) := (others => '0');
signal RX_BYTE_CNTR: unsigned(13 downto 0):= (others => '0');  -- large enough for counting 9000 bytes in Jumbo frame
signal RX_BYTE_CNTR_FINAL: unsigned(13 downto 0):= (others => '0');  
signal RX_WORD_CNTR: unsigned(RX_BYTE_CNTR'left-3 downto 0):= (others => '0'); -- 64-bit word counter

--//-- RX ETHERNET FRAME PARSING ---------------------------
signal RX_VLAN: std_logic := '0';

--//-- MAC CONTROL PAUSE OPERATION ---------------------------
signal RX_CONTROL_PAUSE_VALID: std_logic := '0';
signal RX_CONTROL_PAUSE_VALID2: std_logic := '0';
signal PAUSE_OPCODE: std_logic_vector(15 downto 0) := (others => '0');
signal PAUSE_TIME: std_logic_vector(15 downto 0) := (others => '0');

--//  RX 32-BIT CRC COMPUTATION -------------------------------------------------------
signal RX_CRC_DATA_IN: std_logic_vector(63 downto 0) := (others => '0');
signal RX_CRC_DATA_VALID_IN: std_logic_vector(7 downto 0) := (others => '0');
signal RX_CRC1_D: std_logic_vector(31 downto 0) := (others => '0');
signal RX_CRC2: std_logic_vector(31 downto 0) := (others => '0');
signal RX_CRC_VALID2: std_logic := '0';

--// Length/type field check ----------------------
signal RX_LENGTH_TYPE_FIELD: std_logic_vector(15 downto 0) := (others => '0');
signal RX_LENGTH_TYPEN: std_logic := '0';
signal RX_LENGTH: unsigned(13 downto 0) := (others => '0');
signal RX_DIFF: unsigned(13 downto 0) := (others => '0');
signal RX_LENGTH_ERR: std_logic := '0';

--//  VALID RX FRAME? ----------------------------------------------------------
signal MAC_RX_EOF_TOGGLE: std_logic := '0';
signal MAC_RX_EOF_TOGGLE_D: std_logic := '0';
signal MAC_RX_EOF_TOGGLE_D2: std_logic := '0';
signal N_RX_FRAMES_local: unsigned(15 downto 0) := (others => '0');
signal N_RX_BAD_CRCS_local: unsigned(15 downto 0) := (others => '0');
signal N_RX_FRAMES_TOO_SHORT_local: unsigned(15 downto 0) := (others => '0');
signal N_RX_FRAMES_TOO_LONG_local: unsigned(15 downto 0) := (others => '0');
signal N_RX_LENGTH_ERRORS_local: unsigned(15 downto 0) := (others => '0');
signal N_RX_WRONG_ADDR_local: unsigned(15 downto 0) := (others => '0');
signal MAC_RX_FRAME_VALID2A: std_logic := '0';
signal MAC_RX_FRAME_VALID2: std_logic := '0';

signal MAC_RX_DATA2: std_logic_vector(63 downto 0) := (others => '0');
signal MAC_RX_DATA2_VALID: std_logic_vector(7 downto 0) := (others => '0');
signal MAC_RX_SOF2: std_logic := '0';
signal MAC_RX_EOF2: std_logic := '0';
signal MAC_RX_SAMPLE2_CLK: std_logic := '0';

--//  RX INPUT ELASTIC BUFFER ----------------------------------------------------------
signal MAC_RX_WPTR: unsigned(RX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_RX_WPTR_CONFIRMED: unsigned(RX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_RX_WPTR_CONFIRMED_D: unsigned(RX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_RX_DIA: std_logic_vector(68 downto 0) := (others => '0');
signal MAC_RX_DOB: std_logic_vector(68 downto 0) := (others => '0');
signal MAC_RX_BUF_SIZE: unsigned(RX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '0');
signal MAC_RX_RPTR: unsigned(RX_BUFFER_ADDR_NBITS-1 downto 0) := (others => '1');
signal MAC_RX_SAMPLE3_CLK: std_logic := '0';
signal MAC_RX_SAMPLE3_CLK_E: std_logic := '0';



signal PHY_CONFIG_TP: std_logic_vector(10 downto 1) := (others => '0');

-- test test test
signal FIRST_RXCRCERROR_FLAG: std_logic;
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// SYNCHRONOUS RESETS ----------------------------------------------------------
-- Create synchronous reset for all two clocks within: CLK156g, CLK

-- Create synchronous reset for CLK156g
SYNC_RESET156_GEN_001: process(CLK156g)
begin	
	if rising_edge(CLK156g) then
		SYNC_RESET_D <= SYNC_RESET;
		SYNC_RESET156 <= SYNC_RESET_D;
	end if;
end process;

--// PHY RESET AND CONFIGURATION ----------------------------------------------------------
-- First generate a RESET_N pulse at least 100ns wide(VSC8486-11 specs)
RESET_GEN_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RESET_CNTR <= (others => '0');
		elsif(RESET_CNTR(8) = '0') then
			RESET_CNTR <= RESET_CNTR + 1;
		end if;
		
		case RESET_CNTR(8 downto 7) is
			when "00" => RESET_N <= '1';	-- between 0 and 63
			when "01" => RESET_N <= '0';	-- 64-127
			when "10" => RESET_N <= '1';	-- 128+
			when others => RESET_N <= '1';
		end case;
	end if;
end process;
SYNC_RESET_local <= not RESET_CNTR(8);
RESET_COMPLETE <= RESET_CNTR(8);
INITIAL_CONFIG_PULSE <= '1' when (RESET_CNTR) = 192 else '0';

-- hold the PHY_CONFIG_CHANGE until the intial reset cycle is complete
PHY_CONFIG_CHANGE_HOLD: process(CLK)
begin
	if rising_edge(CLK) then
		if(PHY_CONFIG_CHANGE = '1') then
			PHY_CONFIG_CHANGE_PENDING <= '1';
		elsif(PHY_CONFIG_CHANGE_PENDING = '1') and (RESET_COMPLETE = '1') then
			PHY_CONFIG_CHANGE_PENDING <= '0';
		end if;
	end if;
end process;

-- enact the configuration
PHY_CONFIG_CHANGE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') or ((INITIAL_CONFIG_PULSE = '1') and (PHY_CONFIG_CHANGE_PENDING = '0')) then
			-- A default configuration is loaded automatically after power up. 
			PHY_CONFIG_CHANGE_A <= '1';
			PHY_RESET_A <= '0';	-- no software PHY reset, we just did a hardware reset
			TEST_MODE_A <= "00";
			POWER_DOWN_A <= '0';
		elsif(PHY_CONFIG_CHANGE_PENDING = '1') and (RESET_COMPLETE = '1') then
			-- PHY_CONFIG_CHANGE indicates a user-triggered configuration change.
			PHY_CONFIG_CHANGE_A <= '1';
			PHY_RESET_A <= PHY_RESET;
			TEST_MODE_A <= TEST_MODE;
			POWER_DOWN_A <= POWER_DOWN;
		else
			PHY_CONFIG_CHANGE_A <= '0';
		end if;
	end if;
end process;


PHY_CONFIG_001: PHY_CONFIG 
GENERIC MAP(
  EXT_PHY_MDIO_ADDR => EXT_PHY_MDIO_ADDR
)
PORT MAP(
  SYNC_RESET => SYNC_RESET_local,  	-- wait until reset is complete
  CLK => CLK,
  CONFIG_CHANGE => PHY_CONFIG_CHANGE_A,
  PHY_RESET => PHY_RESET_A,
  TEST_MODE => TEST_MODE_A,
  POWER_DOWN => POWER_DOWN_A,
  SREG_READ_START => SREG_READ_START,
  SREG_MMD => SREG_MMD,	-- MDIO managed device
  SREG_ADDR => SREG_ADDR,	-- status register address
  SREG_DATA => SREG_DATA,
  SREG_SAMPLE_CLK => SREG_SAMPLE_CLK,
  MDC => MDC,
  MDIO_OUT => MDIO_OUT,
  MDIO_IN => MDIO_IN,
  MDIO_DIR => MDIO_DIR,
  TP => PHY_CONFIG_TP
);


---- Special cases
--LINK_STATUS_local <= '1' when (SIMULATION = '1') else	-- fake link status during simulation
--							LINK_STATUS_FROM_PHY;	-- otherwise, ask the PHY for LINK_STATUS
--
-- read PHY identification once at power-up or reset (hardware self-test
-- then periodically read the link status
PHY_STATUS_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET_local = '1') or (PHY_CONFIG_CHANGE_A = '1') then	-- power-up/reset
			SREG_MMD <= "00001";	-- MDIO managed device
			SREG_ADDR <= x"E800";	-- PHY device Identifier CHIP_ID
			SREG_STATE <= "000";
			SREG_READ_START <= '1';				-- start asking for status register
		elsif(SREG_READ_START = '1') then
			SREG_STATE <= SREG_STATE + 1;	-- await status response
			SREG_READ_START <= '0';
		elsif(SREG_STATE = 1) and (SREG_SAMPLE_CLK = '1') then
			-- received CHIP_ID
			-- periodically read XAUI RX loss of signal status into PHY_STATUS
			SREG_MMD <= "00100";	-- MDIO managed device
			SREG_ADDR <= x"8012";	-- PHY XAUI RX status
			SREG_STATE <= SREG_STATE + 1;
			SREG_READ_START <= '1';	-- ask for next status register
		elsif(SREG_STATE = 3) and (SREG_SAMPLE_CLK = '1') then
			-- received XAUI RX status. 
			-- periodically read PHY SPF+ status
			SREG_MMD <= "00001";	-- MDIO managed device
			SREG_ADDR <= x"E600";	-- PMA status 4
			SREG_STATE <= SREG_STATE + 1;
			SREG_READ_START <= '1';	-- ask for next status register
		elsif(SREG_STATE = 5) and (SREG_SAMPLE_CLK = '1') then
			-- received PHY SPF+ status. Ask again for PHY XAUI RX status
			SREG_MMD <= "00100";	-- MDIO managed device
			SREG_ADDR <= x"8012";	-- PHY Identifier MSBs
			SREG_STATE <= "010";
			SREG_READ_START <= '1';	-- ask for next status register
		end if;
	end if;
end process;

PHY_STATUS_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET_local = '1') or (PHY_CONFIG_CHANGE_A = '1') then	-- power-up/reset
			PHY_ID <= (others => '0');
		elsif(SREG_STATE = 1) and (SREG_SAMPLE_CLK = '1') then
			PHY_ID <= SREG_DATA;
		end if;

		if(SYNC_RESET_local = '1') or (PHY_CONFIG_CHANGE_A = '1') then	-- power-up/reset
			PHY_STATUS <= (others => '0');
		elsif(SREG_STATE = 3) and (SREG_SAMPLE_CLK = '1') then
			-- bit0: all PHY XAUI rx lanes in sync
			-- bit1: PHY XAUI rx PLL in lock
			-- bit2: PHY XAUI rx lane0 signal present
			-- bit3: PHY XAUI rx lane1 signal present
			-- bit4: PHY XAUI rx lane2 signal present
			-- bit5: PHY XAUI rx lane3 signal present
			PHY_STATUS(0)  <= SREG_DATA(6); 
			PHY_STATUS(1)  <= not SREG_DATA(5); 
			PHY_STATUS(2)  <= not SREG_DATA(0); 
			PHY_STATUS(3)  <= not SREG_DATA(1); 
			PHY_STATUS(4)  <= not SREG_DATA(2); 
			PHY_STATUS(5)  <= not SREG_DATA(3); 
		end if;

		if(SYNC_RESET_local = '1') or (PHY_CONFIG_CHANGE_A = '1') then	-- power-up/reset
			PHY_STATUS2 <= (others => '0');
		elsif(SREG_STATE = 5) and (SREG_SAMPLE_CLK = '1') then
			-- received PHY SPF+ status. Ask again for PHY XAUI RX status
			PHY_STATUS2 <= SREG_DATA(7 downto 0);
		end if;
		
	end if;
end process;

--// LOW-LATENCY TX INPUT ----------------------------------------------------------
-- low-latency transmit case  CLK=CLK156g
NO_TX_BUF_001: if(TX_BUFFER = '0') generate
	MAC_TX_DATA2 <= MAC_TX_DATA;
	MAC_TX_DATA2_VALID <= MAC_TX_DATA_VALID;
	MAC_TX_SOF2 <= '1' when ((MAC_TX_INFRAME = '0') and  (unsigned(MAC_TX_DATA_VALID) /= 0)) else '0';
	MAC_TX_EOF2 <= MAC_TX_EOF;
	
	-- recreate a MAC_TX_SOF2
	TX_SOF_GEN_001: process(CLK156g)
	begin
		if rising_edge(CLK156g) then
			if(MAC_TX_EOF = '1') then
				MAC_TX_INFRAME <= '0';
			elsif (unsigned(MAC_TX_DATA_VALID) /= 0) then
				MAC_TX_INFRAME <= '1';
			end if;
		end if;
	end process;
	
	MAC_TX_CTS <= '0' when (MAC_TX_EOF = '1') else	-- immediately stop inflow when receiving EOF (we may need a few CLKs for padding)
						'0' when (TX_FILL_NEXT = '1') else
						'1';
end generate;


--//  TX ELASTIC BUFFER ----------------------------------------------------------
TX_BUF_001: if(TX_BUFFER = '1') generate
	-- The purpose of the elastic buffer is two-fold:
	-- (a) a transition between the CLK-synchronous user side, and the CLK156g synchronous PHY side
	-- (b) storage for Ethernet transmit frames, to absorb traffic peaks, minimize the number of 
	-- UDP packets lost at high throughput.
	-- The tx elastic buffer is 16Kbits, large enough for TWO complete maximum size 
	-- (14addr+1500data+4FCS = 1518B) frames.

	MAC_TX_WEA <= '1' when (unsigned(MAC_TX_DATA_VALID) /= 0) else '0';
	-- write pointer management
	MAC_TX_WPTR_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_COUNTER8 <= (others => '0');
				MAC_TX_WPTR <= (others => '0');
				MAC_TX_WPTR_D <= (others => '0');
				MAC_TX_WPTR_STABLE <= '0';
			else
				TX_COUNTER8 <= TX_COUNTER8 + 1;

				if(MAC_TX_WEA = '1') then
					MAC_TX_WPTR <= MAC_TX_WPTR + 1;
				end if;
				
				-- update WPTR_D once every 8 clocks.
				if(TX_COUNTER8 = 7) then
					MAC_TX_WPTR_D <= MAC_TX_WPTR;
				end if;
				
				-- allow WPTR reclocking with another clock, as long as it is away from the transition area
				if(TX_COUNTER8 < 6) then
					MAC_TX_WPTR_STABLE <= '1';
				else 
					MAC_TX_WPTR_STABLE <= '0';
				end if;
			end if;
		end if;
	end process;

	MAC_TX_DIA <= MAC_TX_EOF & MAC_TX_DATA_VALID & MAC_TX_DATA;
		-- concatenate 64-bit word and byte valid
	BRAM_DP2_001: BRAM_DP2 
	GENERIC MAP(
		DATA_WIDTHA => 73,		
		ADDR_WIDTHA => TX_BUFFER_ADDR_NBITS,
		DATA_WIDTHB => 73,		 	
		ADDR_WIDTHB => TX_BUFFER_ADDR_NBITS
	)
	PORT MAP(
		 CSA => '1',
		 CLKA => CLK,
		 WEA => MAC_TX_WEA,
		 OEA => '0',
		 ADDRA => std_logic_vector(MAC_TX_WPTR),  
		 DIA => std_logic_vector(MAC_TX_DIA),
		 DOA => open,
		 CSB => '1',
		 CLKB => CLK156g,
		 WEB => '0',
		 OEB => '1',
		 ADDRB => std_logic_vector(MAC_TX_RPTR),
		 DIB => (others => '0'),
		 DOB => MAC_TX_DOB
	);

	MAC_TX_DATA2 <= MAC_TX_DOB(63 downto 0);
	MAC_TX_DATA2_VALID <= MAC_TX_DOB(71 downto 64) when (MAC_TX_SAMPLE2_CLK = '1') else (others => '0');
	MAC_TX_SOF2 <= '1' when ((MAC_TX_INFRAME = '0') and  (unsigned(MAC_TX_DATA2_VALID) /= 0)) else '0';
	MAC_TX_EOF2 <= MAC_TX_DOB(72);

	-- recreate a MAC_TX_SOF2
	TX_SOF_GEN_001: process(CLK156g)
	begin
		if rising_edge(CLK156g) then
			if(MAC_TX_EOF2 = '1') then
				MAC_TX_INFRAME <= '0';
			elsif (unsigned(MAC_TX_DATA2_VALID) /= 0) then
				MAC_TX_INFRAME <= '1';
			end if;
		end if;
	end process;

	-- CLK156g zone. Reclock WPTR
	MAC_TX_WPTR_002: process(CLK156g)
	begin
		if rising_edge(CLK156g) then
			if(SYNC_RESET156 = '1') then
				MAC_TX_WPTR_STABLE_D <= '0';
				MAC_TX_WPTR_D2 <= (others => '0');
				MAC_TX_WPTR_D3 <= (others => '0');
			else
				MAC_TX_WPTR_STABLE_D <= MAC_TX_WPTR_STABLE;
				MAC_TX_WPTR_D2 <= MAC_TX_WPTR_D;
				
				if(MAC_TX_WPTR_STABLE_D = '1') then
					-- WPTR is stable. OK to resample with the CLK156g clock.
					MAC_TX_WPTR_D3 <= MAC_TX_WPTR_D2;
				end if;
			end if;
		end if;
	end process;

	MAC_TX_BUF_SIZE <= MAC_TX_WPTR_D3 + not(MAC_TX_RPTR);
	-- occupied tx buffer size for reading purposes (CLKG clock domain)(
	-- always lags, could be a bit more, never less.
	
	MAC_TX_CTS <= '1';	-- TODO !!!!!!!!!!!!!!!!!!!!!!
	-- TODO: RPTR, FLOW CONTROL???
	
end generate;

--// SHORT FRAME PADDING ----------------------------------------------------------
-- keep track of incoming tx frame size
TX_PADDING_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			TX_BYTE_CNTR <= (others => '0');
		elsif(MAC_TX_SOF2 = '1') then
			TX_BYTE_CNTR <= to_unsigned(8,TX_BYTE_CNTR'length);
		elsif(MAC_TX_DATA2_VALID /= x"00") and (MAC_TX_EOF2 = '0') then
			TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(8,TX_BYTE_CNTR'length);
		elsif(MAC_TX_EOF2 = '1') then
			if(MAC_TX_DATA2_VALID(7) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(8,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(6) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(7,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(5) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(6,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(4) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(5,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(3) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(4,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(2) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(3,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(1) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(2,TX_BYTE_CNTR'length);
			elsif(MAC_TX_DATA2_VALID(0) = '1') then
				TX_BYTE_CNTR <= TX_BYTE_CNTR + to_unsigned(1,TX_BYTE_CNTR'length);
			else
				-- illegal
			end if;
		end if;
	end if;
end process;
			
-- padding
TX_PADDING_002: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			TX_FILL_NEXT <= '0';
			MAC_TX_DATA3_VALID <= (others => '0');
			MAC_TX_EOF3 <= '0';
		elsif (MAC_TX_CONFIG(0) = '0') then
			-- bit 0: (0) no short frame padding 
			TX_FILL_NEXT <= '0';
			MAC_TX_DATA3_VALID <= MAC_TX_DATA2_VALID;
			MAC_TX_EOF3 <= MAC_TX_EOF2;
		elsif(MAC_TX_EOF2 = '1') then
			-- bit 0: (1) Automatic padding of short frames. Requires that auto-CRC insertion be enabled too. 
			if (TX_BYTE_CNTR < 56) then
				-- Minimum input frame size is 60 bytes 
				TX_FILL_NEXT <= '1';
				TX_FILL_CNTR <= 56 - TX_BYTE_CNTR(5 downto 0);
				MAC_TX_DATA3_VALID <= x"FF";
				MAC_TX_EOF3 <= '0';
			elsif (TX_BYTE_CNTR = 56) then
				TX_FILL_NEXT <= '0';
				MAC_TX_DATA3_VALID <= x"0F";
				MAC_TX_EOF3 <= '1';
			else
				TX_FILL_NEXT <= '0';
				MAC_TX_DATA3_VALID <= MAC_TX_DATA2_VALID;
				MAC_TX_EOF3 <= '1';
			end if;
		elsif(TX_FILL_NEXT = '1') then
			if(TX_FILL_CNTR <= 8) then	
				TX_FILL_NEXT <= '0';
				MAC_TX_DATA3_VALID <= x"0F";
				MAC_TX_EOF3 <= '1';
			else
				TX_FILL_CNTR <= TX_FILL_CNTR - 8;
				MAC_TX_DATA3_VALID <= x"FF";
				MAC_TX_EOF3 <= '0';
			end if;
		else
			MAC_TX_DATA3_VALID <= MAC_TX_DATA2_VALID;
			MAC_TX_EOF3 <= '0';
			TX_FILL_NEXT <= '0';
		end if;
	end if;
end process;

-- zero masked bytes
TX_PADDING_003: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		MAC_TX_SOF3 <= MAC_TX_SOF2;

		for I in 0 to 7 loop
			if(MAC_TX_DATA2_VALID(I) = '1') then
				MAC_TX_DATA3(8*I+7 downto 8*I) <= MAC_TX_DATA2(8*I+7 downto 8*I);
			else
				MAC_TX_DATA3(8*I+7 downto 8*I) <= x"00";
			end if;
		end loop;
	end if;
end process;

--//  TX 32-BIT CRC COMPUTATION -------------------------------------------------------
-- 802.3 section 3.2.9: 
-- protected fields: payload data + optional pad + CRC (excludes preamble and start of frame sequence)

-- The CRC32 component assumes the serial stream is packed into 64-bit words MSb of MSB first.
-- Since MAC_TX_DATA3 is packed LSb of LSB first, we need to re-order.
-- Other reordering consideration: the CRC32 is computed with 'reflected' input bytes.
-- In summary MSB <-> LSB 
REORDER_TX_CRC32_INPUT: process(MAC_TX_DATA3, MAC_TX_DATA3_VALID)
begin
	for I in 0 to 63 loop
		TX_CRC_DATA_IN(I) <= MAC_TX_DATA3(63-I);
	end loop;
	for J in 0 to 7 loop
	   TX_CRC_DATA_VALID_IN(J) <= MAC_TX_DATA3_VALID(7-J);
    end loop;
end process;
TX_CRC_SAMPLE_CLK_IN <= '1' when (MAC_TX_DATA3_VALID /= x"00") else '0';

TX_CRC_001: CRC32 PORT MAP (
	 CLK => CLK156g,
	 DATA_IN => TX_CRC_DATA_IN,
	 SOF_IN => MAC_TX_SOF3,
	 SAMPLE_CLK_IN => TX_CRC_SAMPLE_CLK_IN,
	 DATA_VALID_IN => TX_CRC_DATA_VALID_IN,
	 CRC_INITIALIZATION => x"FFFFFFFF",
	 CRC_OUT => TX_CRC32,
	 SAMPLE_CLK_OUT => TX_CRC_SAMPLE_CLK_OUT
  );

-- flip LSb<->MSb and invert
TX_CRC32_002: process(TX_CRC32)
begin
	for I in 0 to 31 loop
		TX_CRC32_FLIPPED_INV(I) <= not TX_CRC32(31 - I);
	end loop;
end process;
 
--//-- XGMII TX INTERFACE --------------------------------
TX_XGMII_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		MAC_TX_DATA3_VALID_D <= MAC_TX_DATA3_VALID;
		MAC_TX_DATA3_D <= MAC_TX_DATA3;
		MAC_TX_EOF3_D <= MAC_TX_EOF3;
		MAC_TX_EOF3_D2 <= MAC_TX_EOF3_D;
		
		if (SYNC_RESET156 = '1') then
			XGMII_TXD <= x"0707070707070707";	
			XGMII_TXC <= x"FF";
		elsif(MAC_TX_SOF3 = '1') then
			-- insert start + preamble
			XGMII_TXD <= x"D5555555555555FB";	
			XGMII_TXC <= x"01";
		elsif(MAC_TX_EOF3_D = '1') then
			case MAC_TX_DATA3_VALID_D is
				when x"01" => 
					XGMII_TXD <= x"0707FD" & TX_CRC32_FLIPPED_INV & MAC_TX_DATA3_D(7 downto 0);
					XGMII_TXC <= x"E0";
					XGMII_TXD_NEXT <= x"0707070707070707";
					XGMII_TXC_NEXT <= x"FF";
				when x"03" => 
					XGMII_TXD <= x"07FD" & TX_CRC32_FLIPPED_INV & MAC_TX_DATA3_D(15 downto 0);
					XGMII_TXC <= x"C0";
					XGMII_TXD_NEXT <= x"0707070707070707";
					XGMII_TXC_NEXT <= x"FF";
				when x"07" => 
					XGMII_TXD <= x"FD" & TX_CRC32_FLIPPED_INV & MAC_TX_DATA3_D(23 downto 0);
					XGMII_TXC <= x"80";
					XGMII_TXD_NEXT <= x"0707070707070707";
					XGMII_TXC_NEXT <= x"FF";
				when x"0F" => 
					XGMII_TXD <= TX_CRC32_FLIPPED_INV & MAC_TX_DATA3_D(31 downto 0);
					XGMII_TXC <= x"00";
					XGMII_TXD_NEXT <= x"07070707070707FD";
					XGMII_TXC_NEXT <= x"FF";
				when x"1F" => 
					XGMII_TXD <= TX_CRC32_FLIPPED_INV(23 downto 0) & MAC_TX_DATA3_D(39 downto 0);
					XGMII_TXC <= x"00";
					XGMII_TXD_NEXT <= x"070707070707FD" & TX_CRC32_FLIPPED_INV(31 downto 24);
					XGMII_TXC_NEXT <= x"FE";
				when x"3F" => 
					XGMII_TXD <= TX_CRC32_FLIPPED_INV(15 downto 0) & MAC_TX_DATA3_D(47 downto 0);
					XGMII_TXC <= x"00";
					XGMII_TXD_NEXT <= x"0707070707FD" & TX_CRC32_FLIPPED_INV(31 downto 16);
					XGMII_TXC_NEXT <= x"FC";
				when x"7F" => 
					XGMII_TXD <= TX_CRC32_FLIPPED_INV(7 downto 0) & MAC_TX_DATA3_D(55 downto 0);
					XGMII_TXC <= x"00";
					XGMII_TXD_NEXT <= x"07070707FD" & TX_CRC32_FLIPPED_INV(31 downto 8);
					XGMII_TXC_NEXT <= x"F8";
				when x"FF" => 
                    XGMII_TXD <= MAC_TX_DATA3_D;
                    XGMII_TXC <= x"00";
                    XGMII_TXD_NEXT <= x"070707FD" & TX_CRC32_FLIPPED_INV;
                    XGMII_TXC_NEXT <= x"F0";
                when others => null;	
			end case;
		elsif(MAC_TX_EOF3_D2 = '1') then
			XGMII_TXD <= XGMII_TXD_NEXT;
			XGMII_TXC <= XGMII_TXC_NEXT;
		elsif(MAC_TX_DATA3_VALID_D = x"FF") then
			XGMII_TXD <= MAC_TX_DATA3_D;
			XGMII_TXC <= x"00";
		else
			XGMII_TXD <= x"0707070707070707";	-- idle
			XGMII_TXC <= x"FF";
		end if;
	end if;
end process;





----//-- TX FLOW CONTROL --------------------------------
---- ask for more input data if there is room for at least 1K more input bytes
---- Never write past the last confirmed read pointer location.
--
---- read the last confirmed read pointer location and reclock in CLK domain when stable
--MAC_TX_CTS_001: process(CLK)
--begin
--	if rising_edge(CLK) then
--		if(SYNC_RESET = '1') then
--			TX_SUCCESS_TOGGLE_D <= '0';
--			TX_SUCCESS_TOGGLE_D2 <= '0';
--			MAC_TX_RPTR_CONFIRMED_D <= (others => '1');
--		else
--			TX_SUCCESS_TOGGLE_D <= TX_SUCCESS_TOGGLE;
--			TX_SUCCESS_TOGGLE_D2 <= TX_SUCCESS_TOGGLE_D;
--			if(TX_SUCCESS_TOGGLE_D2 /= TX_SUCCESS_TOGGLE_D) then
--				-- shortly after successful packet transmission. 
--				MAC_TX_RPTR_CONFIRMED_D <= MAC_TX_RPTR_CONFIRMED;
--			end if;
--		end if;
--	end if;
--end process;
--
---- Compute available room for more tx data
--MAC_TX_CTS_002: process(CLK)
--begin
--	if rising_edge(CLK) then
--		if(SYNC_RESET = '1') then
--			MAC_TX_BUF_FREE <= (others => '0');
--		else
--			MAC_TX_BUF_FREE <= not (MAC_TX_WPTR_D2 + not MAC_TX_RPTR_CONFIRMED_D);
--		end if;
--	end if;
--end process;
--
---- Is there enough room for a complete max size frame?
---- Don't cut it too close because user interface can flood the buffer very quickly (CLK @ 125 MHz clock)
---- while we compute the buffer size with the possibly much slower RX_CLG (could be 2.5 MHz for 10Mbps).
--MAC_TX_CTS_003: process(CLK)
--begin
--	if rising_edge(CLK) then
--		if(SYNC_RESET = '1') then
--			MAC_TX_CTS_local <= '0';	-- reset
--		elsif(LINK_STATUS_local = '0') then
--			-- don't ask the stack for data if there is no link
--			MAC_TX_CTS_local <= '0';	-- reset
--		elsif(MAC_TX_BUF_FREE(11) = '0') then
--			-- room for less than 2KB. Activate flow control
--			MAC_TX_CTS_local <= '0';
--		else
--			MAC_TX_CTS_local <= '1';
--		end if;
--	end if;
--end process;
--MAC_TX_CTS <= MAC_TX_CTS_local;
--
--
---- manage read pointer
--MAC_TX_RPTR_001: process(TX_CLKG)
--begin
--	if rising_edge(TX_CLKG) then
--		if(SYNC_RESETTX = '1') then
--			MAC_TX_RPTR <= (others => '1');
--			MAC_TX_RPTR_D <= (others => '1');
--		else
--			MAC_TX_RPTR_D <= MAC_TX_RPTR;
--			
--			if(SYNC_RESETRX = '1') then
--				MAC_TX_RPTR <= (others => '1');
--			elsif(TX_STATE = 1) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(2 downto 0) <= 1) then
--				-- read the first byte(s) in advance (need 2 RX_CLKG to get the data out)
--				-- Note: we may temporarily read past the write pointer (by one location) 
--				-- but will rewind immediately thereafter
--				MAC_TX_RPTR <= MAC_TX_RPTR + 1;
--			elsif(TX_STATE = 2) and (TX_EVENT3 = '1') then
--				-- we are done reading the packet. rewind the read pointer, as we went past the end of packet.
--				MAC_TX_RPTR <= MAC_TX_RPTR - 1;
--			elsif(TX_STATE = 2) and (TX_BYTE_CLK = '1') then
--				-- read the rest of the packet
--				-- forward data from input elastic buffer to RGMII interface
--				-- Note: we may temporarily read past the write pointer (by one location) 
--				-- but will rewind immediately thereafter
--				MAC_TX_RPTR <= MAC_TX_RPTR + 1;
--			elsif(TX_STATE = 6) then
--				-- collision detected. rewind read pointer to the start of frame.
--				MAC_TX_RPTR <= MAC_TX_RPTR_CONFIRMED;
--			end if;
--		end if;
--	end if;
--end process;
--
---- update confirmed read pointer after successful frame transmission
--MAC_TX_RPTR_002: process(TX_CLKG)
--begin
--	if rising_edge(TX_CLKG) then
--		if(SYNC_RESETTX = '1') then
--			MAC_TX_RPTR_CONFIRMED <= (others => '1');
--			TX_SUCCESS_TOGGLE <= '0';
--		elsif(TX_SUCCESS = '1') then
--			MAC_TX_RPTR_CONFIRMED <= MAC_TX_RPTR;
--			TX_SUCCESS_TOGGLE <= not TX_SUCCESS_TOGGLE;
--		end if;
--	end if;
--end process;
--
---- How many COMPLETE tx frames are available for transmission in the input elastic buffer?
---- Transmission is triggered by the availability of a COMPLETE frame in the buffer (not just a few frame bytes)
---- It is therefore important to keep track of the number of complete frames.
---- At the elastic buffer input, a new complete frame is detected upon receiving the EOF pulse.
--COMPLETE_TX_FRAMES_001: process(CLK)
--begin
--	if rising_edge(CLK) then
--		if(SYNC_RESET = '1') then
--			MAC_TX_EOF_TOGGLE <= '0';
--		elsif(MAC_TX_DATA_VALID = '1') and (MAC_TX_EOF = '1') then
--			MAC_TX_EOF_TOGGLE <= not MAC_TX_EOF_TOGGLE;  -- Need toggle signal to generate copy in RX_CLKG clock domain
--		end if;
--	end if;
--end process;
--
--
--COMPLETE_TX_FRAMES_002: process(TX_CLKG)
--begin
--	if rising_edge(TX_CLKG) then
--		if(SYNC_RESETTX = '1') then
--			MAC_TX_EOF_TOGGLE_D <= '0';
--			MAC_TX_EOF_TOGGLE_D2 <= '0';
--			COMPLETE_TX_FRAMES_INBUF <= (others => '0');
--		else
--			MAC_TX_EOF_TOGGLE_D <= MAC_TX_EOF_TOGGLE;	-- reclock in TX_CLKG clock domain (to prevent glitches)
--			MAC_TX_EOF_TOGGLE_D2 <= MAC_TX_EOF_TOGGLE_D;
--
--			if(MAC_TX_EOF_TOGGLE_D2 /= MAC_TX_EOF_TOGGLE_D) and (TX_SUCCESS = '0') then
--				-- just added another complete frame into the tx buffer (while no successful transmission concurrently)
--				COMPLETE_TX_FRAMES_INBUF <= COMPLETE_TX_FRAMES_INBUF + 1;
--			elsif(MAC_TX_EOF_TOGGLE_D2 = MAC_TX_EOF_TOGGLE_D) and (TX_SUCCESS = '1') 
--					and (ATLEAST1_COMPLETE_TX_FRAME_INBUF = '1') then
--				-- a frame was successfully transmitted (and none was added at the very same instant)
--				COMPLETE_TX_FRAMES_INBUF <= COMPLETE_TX_FRAMES_INBUF - 1;
--			end if;
--		end if;
--	end if;
--end process;
--
---- Flag to indicate at least one complete tx frame in buffer.
--ATLEAST1_COMPLETE_TX_FRAME_INBUF <= '0' when (COMPLETE_TX_FRAMES_INBUF = 0) else '1';
--
--
--
--
----// MAC TX STATE MACHINE ----------------------------------------------------------
--
--
---- 96-bit InterPacketGap (Interframe Delay) timer
--IPG_001: process(TX_CLKG)
--begin
--	if rising_edge(TX_CLKG) then
--		if (SYNC_RESETRX = '1') then
--			IPG_CNTR <= (others => '0');
--			CRS_D <= '0';
--		else
--			CRS_D <= CRS;  -- reclock with TX_CLKG
--
--				-- or carrier extension in progress
--				-- Arm InterPacketGap timer
--				IPG_CNTR <= x"0C"  ; -- 96 bits = 12 bytes  802.3 section 4.4.2
--			elsif(IPG_CNTR > 0) and (TX_BYTE_CLK = '1') then
--				-- after end of passing packet, decrement counter downto to zero (InterPacketGap).
--				IPG_CNTR <= IPG_CNTR - 1;
--			end if;
--		end if;
--	end if;
--end process;
--IPG <= '1' when (IPG_CNTR = 0) else '0';  -- '1' last passing packet was more than InterPacketGap ago. OK to start tx.
--
---- Events ------------------------
---- First tx packet trigger
--TX_EVENT1 <= '0' when (ATLEAST1_COMPLETE_TX_FRAME_INBUF = '0') else -- no COMPLETE frame in tx input buffer
--				 '0' when (MAC_TX_BUF_SIZE = 0) else -- no data in tx input buffer
--				 '0' when (IPG = '0') else -- medium is not clear. need to wait after the InterPacketGap. Deferring on.
--				 '0' when (TX_SUCCESS = '1') else  -- don't act too quickly. It takes one RX_CLKG to update the complete_tx_frame_inbuf counter.
--				 '0' when (PHY_IF_WRAPPER_RESET = '1') else -- PHY/RGMII wrapper are being reset. Do not start tx.
--				 TX_BYTE_CLK;  -- go ahead..start transmitting. align event pulse with TX_BYTE_CLK
--				 
--				 
--
---- Tx state machine ------------------------
--TX_STATE_GEN_001: process(TX_CLKG)
--begin
--	if rising_edge(TX_CLKG) then
--		if (SYNC_RESETTX = '1') or (LINK_STATUS_local = '0') then
--			TX_STATE <= 0;	-- idle state
--			TX_SUCCESS <= '0'; 
--			TX_BYTE_CLK_D <= '0';
--			RETX_ATTEMPT_COUNTER <= (Others => '0');  -- re-transmission attempts counter
--		else
--
--			TX_BYTE_CLK_D <= TX_BYTE_CLK;  -- output byte ready one RX_CLKG later 
--			
--			if(TX_STATE = 0) then
--				TX_SUCCESS <= '0'; 
--				RETX_ATTEMPT_COUNTER <= (Others => '0');  -- reset re-transmission attempts counter
--				if (TX_EVENT1 = '1') then
--					-- start tx packet: send 1st byte of preamble
--					TX_STATE <= 1; 
--					TX_BYTE_COUNTER2 <= "111"; -- 8-byte preamble + start of frame sequence
--				end if;
--			elsif(TX_STATE = 1) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(2 downto 0) /= 0) then
--				-- counting through the preamble + start frame sequence
--				TX_BYTE_COUNTER2 <= TX_BYTE_COUNTER2 - 1;
--			elsif(TX_STATE = 1) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(2 downto 0) = 0) then
--				-- end of preamble. start forwarding data from elastic buffer to RGMII wrapper
--				TX_STATE <= 2; 
--				TX_BYTE_COUNTER <= (others => '0');
--			elsif(TX_STATE = 2) and (TX_BYTE_CLK = '1') and (TX_EVENT3 = '0') then
--				-- keep track of the payload byte count (to detect the need for padding)
--				TX_BYTE_COUNTER <= TX_BYTE_COUNTER + 1;
--			elsif(TX_STATE = 2) and (TX_BYTE_CLK = '1') and (TX_EVENT3 = '1')  then
--				-- found end of frame
--				TX_BYTE_COUNTER <= TX_BYTE_COUNTER + 1;
--				if (TX_BYTE_COUNTER(10 downto 0) < 59) then 
--					if (MAC_TX_CONFIG(1 downto 0) = "11") then
--						-- frame is too short: payload data does not meet minimum 60-byte size.
--						-- user enabled automatic padding and automatic CRC32 insertion
--						TX_STATE <= 3;
--					else
--						-- error: frame is too short. abort.
--						TX_STATE <= 10;
--					end if;
--				elsif (MAC_TX_CONFIG(1) = '1') then
--					-- user enabled auto-CRC32 insertion. Start inserting CRC
--					TX_STATE <= 4;
--					TX_BYTE_COUNTER2 <= "011";	-- 4-byte CRC(FCS)
--				elsif (TX_BYTE_COUNTER(10 downto 0) >= 63) then
--					-- complete packet (including user-supplied CRC)
--					else
--						-- we are done here
--						TX_STATE <= 0;
--						TX_SUCCESS <= '1'; -- completed frame transmission
--					end if;
--				else
--					-- error. frame is too short (< 64 bytes including 4-byte CRC). abort.
--					TX_STATE <= 10;
--				end if;
--			elsif(TX_STATE = 3) and (TX_BYTE_CLK = '1') then
--				TX_BYTE_COUNTER <= TX_BYTE_COUNTER + 1;
--				if(TX_BYTE_COUNTER(10 downto 0) < 59) then
--					-- padding payload field to the minimum size.
--					-- keep track of the byte count 
--				elsif (MAC_TX_CONFIG(1) = '1') then
--					-- Completed padding. User enabled CRC32 insertion. Start inserting CRC
--					TX_STATE <= 4;
--					TX_BYTE_COUNTER2 <= "011";	-- 4-byte CRC(FCS)
--				else
--					-- error. Illegal user configuration. auto-pad requires auto-CRC. abort.
--					TX_STATE <= 10;
--				end if;
--			elsif(TX_STATE = 4) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(1 downto 0) /= 0) then
--				-- counting through the CRC/FCS sequence
--				TX_BYTE_COUNTER2 <= TX_BYTE_COUNTER2 - 1;
--				TX_BYTE_COUNTER <= TX_BYTE_COUNTER + 1;
--			elsif(TX_STATE = 4) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(1 downto 0) = 0) then
--				-- end of CRC/FCS. Packet is now complete. 
--				TX_BYTE_COUNTER <= TX_BYTE_COUNTER + 1;
--				else
--					-- we are done here
--					TX_STATE <= 0;
--					TX_SUCCESS <= '1'; -- completed frame transmission
--				end if;
--			elsif(TX_STATE = 5) and (TX_BYTE_CLK = '1') then
--				-- Carrier extension
--				TX_BYTE_COUNTER <= TX_BYTE_COUNTER + 1;
--				if(TX_BYTE_COUNTER(10 downto 0) >= 511) then
--					-- met slotTime requirement.
--					TX_STATE <= 0;
--					TX_SUCCESS <= '1'; -- completed frame transmission
--				end if;
--			elsif(TX_STATE = 6) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(1 downto 0) /= 0) then
--				-- Jam . counting through the 4-byte jam
--				TX_BYTE_COUNTER2 <= TX_BYTE_COUNTER2 - 1;
--			elsif(TX_STATE = 6) and (TX_BYTE_CLK = '1') and (TX_BYTE_COUNTER2(1 downto 0) = 0) then
--				-- end of Jam
--
--
--TX_ER <= '1' when (TX_STATE = 5) else  -- carrier extension
--			'0';
--
--	














-- test code to send a pre-stored frame
--TEST_XGMII_TX_001: TEST_XGMII_TX PORT MAP(
--	CLK156g => CLK156g,
--	SYNC_RESET156 => SYNC_RESET156,
--	TX_TRIGGER => TX_TRIGGER,	
--	XGMII_TXD => XGMII_TXD,
--	XGMII_TXC => XGMII_TXC,
--	TP => TEST_XGMII_TX_TP
--);

--// MAC RX STATE MACHINE ----------------------------------------------------------
-- delay XGMII_RXD one CLK while we search for special characters (start,terminate,error)
RX_RECLOCK_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		XGMII_RXD_D <= XGMII_RXD;
	end if;
end process;

-- detect start character (0xFB) and pinpoint its byte location within the 8-byte XGMII rx word
-- There are two possible locations 0 and 4
-- (see Xilinx PG053 "Internal 64-bit SDR client-side interface" p77)
-- (see Altera UG-01080 7-12)
XGMII_RX_START_CHAR_001: process(CLK156g)
begin
    if rising_edge(CLK156g) then
        if(XGMII_RXC(0) = '1') and (XGMII_RXD(7 downto 0) = x"FB") then
            XGMII_RX_START_CHAR <= '1';    
            XGMII_RX_START_LOC <= "000";
        elsif(XGMII_RXC(4) = '1') and (XGMII_RXD(39 downto 32) = x"FB") then
            XGMII_RX_START_CHAR <= '1';    
            XGMII_RX_START_LOC <= "100";
        else
            XGMII_RX_START_CHAR <= '0';    
        end if;
	end if;
end process;

-- detect the first SFD character (0xD5) and pinpoint its byte location within the 8-byte XGMII rx word
XGMII_RX_SFD_CHAR_001: process(CLK156g)
variable SFD: std_logic := '0';
variable SFD_LOC: unsigned(2 downto 0) := "000";
begin
	if rising_edge(CLK156g) then
		SFD := '0';
		for I in 0 to 7 loop  
			if(XGMII_RXC(I) = '0') and (XGMII_RXD(8*I+7 downto 8*I) = x"D5") and (SFD = '0') then	
			     -- stop as soon as we found the character
				SFD := '1';
				SFD_LOC := to_unsigned(I,3);
			end if;
		end loop;
		if(SFD = '1') and (RX_STATE /= 2) then
		  -- filter out xD5 characters in payload 
		  XGMII_RX_SFD_LOC <= SFD_LOC;
		  XGMII_RX_SFD_CHAR <= '1';
		else
		  XGMII_RX_SFD_CHAR <= '0';
		end if;
	end if;
end process;

-- detect terminate character and pinpoints its byte location within the 8-byte XGMII rx word
XGMII_RX_TERMINATE_001: process(CLK156g)
variable TERMINATE: std_logic := '0';
variable TERMINATE_LOC: unsigned(2 downto 0) := "000";
begin
	if rising_edge(CLK156g) then
		TERMINATE := '0';
		for I in 0 to 7 loop
			if(XGMII_RXC(I) = '1') and (XGMII_RXD(8*I+7 downto 8*I) = x"FD") and (TERMINATE = '0') then
                -- stop as soon as we found the character
				TERMINATE := '1';
				TERMINATE_LOC := to_unsigned(I,3);
			end if;
		end loop;
		XGMII_RX_TERM_CHAR <= TERMINATE;
		XGMII_RX_TERM_LOC <= TERMINATE_LOC;
	end if;
end process;

-- detect error character
XGMII_RX_ERROR_001: process(CLK156g)
variable ERROR: std_logic := '0';
begin
	if rising_edge(CLK156g) then
		ERROR := '0';
		for I in 0 to 7 loop
			if(XGMII_RXC(I) = '1') and (XGMII_RXD(8*I+7 downto 8*I) = x"FE") then
				ERROR := '1';
			end if;
		end loop;
		XGMII_RX_ERROR_CHAR <= ERROR;
	end if;
end process;


-- delineate a frame using a state machine
XGMII_RX_STATE_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if(SYNC_RESET156 = '1') then
			XGMII_RX_IN_FRAME <= '0';
		elsif(XGMII_RX_START_CHAR = '1') then
			-- entering a frame
			XGMII_RX_IN_FRAME <= '1';
		elsif((XGMII_RX_TERM_CHAR = '1') or (XGMII_RX_ERROR_CHAR = '1')) then
			XGMII_RX_IN_FRAME <= '0';
		end if;
	end if;
end process;

-- Assess the InterPacket Gap. Clamp at 255 bytes
RX_IPG_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			 RX_IPG_local <= (others => '0');
			 RX_IPG <= (others => '0');
		elsif (XGMII_RX_TERM_CHAR = '1') then
			-- detected terminate character. Start counting IPG bytes and report previous IPG
			if(RX_IPG_local(8) = '1') then
				-- clamp at 255 bytes
				RX_IPG <= x"FF";
			else
				RX_IPG <= std_logic_vector(RX_IPG_local(7 downto 0));
			end if;
			if(XGMII_RX_START_CHAR = '0') then
				-- start and terminate characters are not in the same word
				RX_IPG_local <= resize(not XGMII_RX_TERM_LOC, RX_IPG_local'length);
			elsif(XGMII_RX_TERM_LOC < XGMII_RX_START_LOC) then
				-- start and terminate characters are in the same word, and start follows terminate as expected
				RX_IPG_local <= resize(XGMII_RX_START_LOC - XGMII_RX_TERM_LOC,RX_IPG_local'length);
			else
				-- really really short frame. ignore
			end if;
		elsif (XGMII_RX_START_CHAR = '0') then
			if(XGMII_RXC = x"FF") and (RX_IPG_local(8) = '0') then	-- clamp at 255 bytes
				RX_IPG_local <= RX_IPG_local + to_unsigned(8,RX_IPG_local'length);
			end if;
		else
			-- detected start character. Finalize IPG byte count and report.
			if (RX_IPG_local(8) = '0') then	-- clamp at 255 bytes
				RX_IPG_local <= RX_IPG_local + resize(XGMII_RX_START_LOC,RX_IPG_local'length);
			end if;
		end if;
	end if;
end process;

-- Rx state machine ------------------------
-- states:
-- 0 idle
-- 1 received start character, awaiting start of frame delimiter (SFD)
-- 2 received SFD, receiving data
--
-- Keeps track of the received bytes and words.
-- RX_BYTE_CNTR should be read when RX_SAMPLE1_CLK = '1'
-- It also represents the word count in fixed point format 10.3
-- For example RX_BYTE_CNTR = "0000000011.001" marks the third word with one extra byte waiting in cache 
RX_STATE_GEN_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		RX_STATE2_D <= RX_STATE2;
	
		if (SYNC_RESET156 = '1') then
			RX_STATE <= 0;
			RX_BYTE_CNTR <= (others => '0');
		elsif(RX_STATE2 = '0') and (XGMII_RX_TERM_CHAR = '1') then
			-- defensive code: back to idle
			RX_STATE <= 0;
		elsif(XGMII_RX_START_CHAR = '1') then
			-- SFD may be in the same word or in the next
			if(XGMII_RX_SFD_CHAR = '1') then
				-- both start character and SFD byte in the same word. Start counting rx bytes
				RX_STATE <= 2;
--				RX_BYTE_CNTR <= resize(not XGMII_RX_SFD_LOC, RX_BYTE_CNTR'length);    -- always 0
				RX_BYTE_CNTR <= (others => '0');
			else
				RX_STATE <= 1; 	-- awaiting SFD byte in the next word
			end if;
		elsif(RX_STATE = 1) then
			if(XGMII_RX_SFD_CHAR = '1') then
				-- received both start and SFD bytes. Start counting rx bytes
				RX_STATE <= 2;
				-- RX_BYTE_CNTR <= resize(not XGMII_RX_SFD_LOC, RX_BYTE_CNTR'length);   -- always 4
				RX_BYTE_CNTR <= (2 => '1', others => '0');
			else
				-- something wrong (SFD always follows START character) Error. Back to idle
				RX_STATE <= 0;	
			end if;
		elsif(RX_STATE2 = '1') then
			if(XGMII_RX_TERM_CHAR = '0') then
				RX_BYTE_CNTR <= RX_BYTE_CNTR + to_unsigned(8,RX_BYTE_CNTR'length);
			else
				RX_BYTE_CNTR <= RX_BYTE_CNTR_FINAL;
				RX_STATE <= 0;		-- back to idle
			end if;
		end if;
	end if;
end process;
RX_WORD_CNTR <= RX_BYTE_CNTR(RX_BYTE_CNTR'left downto 3);	-- int(byte counter/8)
RX_BYTE_CNTR_FINAL <= RX_BYTE_CNTR + resize(XGMII_RX_TERM_LOC, RX_BYTE_CNTR'length); 
	-- read when XGMII_RX_TERM_CHAR = '1'


-- Assess whether rx frame is too short (<64 Bytes)
RX_TOO_SHORT_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') or (XGMII_RX_START_CHAR = '1') then
			RX_TOO_SHORT <= '0';
		elsif (XGMII_RX_TERM_CHAR = '1') then
			-- end of frame 
			if(RX_STATE /= 2) or (RX_BYTE_CNTR_FINAL < 64)then
				-- end of frame before the data field, or
				-- less than 64 bytes
				RX_TOO_SHORT <= '1';
			else
				RX_TOO_SHORT <= '0';
			end if;
		end if;
	end if;
end process;

-- Assess whether rx frame is too long (>1500 payload bytes or >9000 payload bytes when jumbo frames allowed)
-- Add MAC addresses, CRC32, ethertype/length, and 802.1Q tag to payload length.
RX_TOO_LONG_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') or (XGMII_RX_START_CHAR = '1') then
			RX_TOO_LONG <= '0';
		elsif (XGMII_RX_TERM_CHAR = '1') and (MAC_RX_CONFIG(4) = '1')  then
			-- Detect payload frames longer than the user-specified MTU size
			-- at end of frame 
			if(RX_VLAN = '0') and (RX_BYTE_CNTR_FINAL > RX_MTU+18) then
				RX_TOO_LONG <= '1';
			elsif(RX_VLAN = '1') and (RX_BYTE_CNTR_FINAL > RX_MTU+22) then
				RX_TOO_LONG <= '1';
			else
				RX_TOO_LONG <= '0';
			end if;
		end if;
	end if;
end process;

-- realign bytes starting at the destination address, immediately after the SFD.
-- Discard the preamble
RX_ALIGN_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if(SYNC_RESET156 = '1') then
			XGMII_RX_SAMPLE1_CLK <= '0';
			XGMII_RX_FLUSH <= '0';
			XGMII_RX_DATA1_VALID <= x"00";
			XGMII_RX_DATA1 <= (others => '0');
		elsif(XGMII_RX_SFD_CHAR = '1') then
			-- save 0 or 4 bytes in cache XGMII_RX_DATA1A until we have a full 8-byte word
			XGMII_RX_SAMPLE1_CLK <= '0';
			XGMII_RX_FLUSH <= '0';
			XGMII_RX_DATA1_VALID <= x"00";
            if(XGMII_RX_SFD_LOC = "011") then
                XGMII_RX_DATA1A <= XGMII_RXD_D(63 downto 32);
             end if;
		elsif(RX_STATE2 = '1') then
			if(XGMII_RX_TERM_CHAR = '0') then
			    -- 8 more Bytes
				XGMII_RX_FLUSH <= '0';
				XGMII_RX_SAMPLE1_CLK <= '1';
    			XGMII_RX_DATA1_VALID <= x"FF";
			elsif(XGMII_RX_SFD_LOC = "111") then
				-- terminate character detected. No data in cache.
                XGMII_RX_FLUSH <= '0';
 				-- received terminate character: received less than 8 bytes and no data in XGMII_RX_DATA1A cache
                case XGMII_RX_TERM_LOC(2 downto 0) is    
                    when "001" => XGMII_RX_DATA1_VALID <= x"01";
                    when "010" => XGMII_RX_DATA1_VALID <= x"03";
                    when "011" => XGMII_RX_DATA1_VALID <= x"07";
                    when "100" => XGMII_RX_DATA1_VALID <= x"0F";
                    when "101" => XGMII_RX_DATA1_VALID <= x"1F";
                    when "110" => XGMII_RX_DATA1_VALID <= x"3F";
                    when "111" => XGMII_RX_DATA1_VALID <= x"7F";
                    when others => XGMII_RX_DATA1_VALID <= x"00";
                end case;
			    if(XGMII_RX_TERM_LOC = "000") then
			        -- no new data, no data in cache
                    XGMII_RX_SAMPLE1_CLK <= '0';
 			        XGMII_RX_DATA1_VALID <= x"00";
               else
                    -- new data, no data in cache
                    XGMII_RX_SAMPLE1_CLK <= '1';
               end if;
			else
 				-- received terminate character: received less than 8 bytes and 4 Bytes data in cache.
                XGMII_RX_SAMPLE1_CLK <= '1';
               case XGMII_RX_TERM_LOC(2 downto 0) is    
                   when "000" => XGMII_RX_DATA1_VALID <= x"0F";
                   when "001" => XGMII_RX_DATA1_VALID <= x"1F";
                   when "010" => XGMII_RX_DATA1_VALID <= x"3F";
                   when "011" => XGMII_RX_DATA1_VALID <= x"7F";
                   when others => XGMII_RX_DATA1_VALID <= x"FF";
              end case;
			    if(unsigned(XGMII_RX_TERM_LOC) < 5) then
                    -- 4 Bytes or less of new data + 4 Bytes in cache
                    XGMII_RX_FLUSH <= '0';
                else
                    -- 5 Bytes or more of new data + 4 Bytes in cache
                    -- need an additional flush cycle for remaining bytes
                    XGMII_RX_FLUSH <= '1';
                 end if;
			end if;
			
			-- SFD is located only at locations 3 or 7 
			-- Note: some bytes will be masked if a terminate character is received (see process below)
			-- In this case, we don't even try to zero these meaningless bytes
            if(XGMII_RX_SFD_LOC = "011") then
                XGMII_RX_DATA1(31 downto 0) <= XGMII_RX_DATA1A;
                XGMII_RX_DATA1(63 downto 32) <= XGMII_RXD_D(31 downto 0);
                XGMII_RX_DATA1A(31 downto 0) <= XGMII_RXD_D(63 downto 32);
            else
				XGMII_RX_DATA1(63 downto 0) <= XGMII_RXD_D(63 downto 0);
            end if;
		elsif(XGMII_RX_FLUSH = '1') then
			XGMII_RX_SAMPLE1_CLK <= '1';
			XGMII_RX_DATA1 <= x"00000000" & XGMII_RX_DATA1A;
			XGMII_RX_FLUSH <= '0';
			-- flush remaining bytes in XGMII_RX_DATA1A cache
            case RX_BYTE_CNTR_FINAL(2 downto 0) is    
                when "001" => XGMII_RX_DATA1_VALID <= x"01";
                when "010" => XGMII_RX_DATA1_VALID <= x"03";
                when "011" => XGMII_RX_DATA1_VALID <= x"07";
                when others => XGMII_RX_DATA1_VALID <= x"00";
            end case;
		else
			XGMII_RX_SAMPLE1_CLK <= '0';
			XGMII_RX_DATA1_VALID <= x"00";
		end if;
	end if;
end process;

-- generate start of frame
-- mark the XGMII_RX_SOF1 (1st word, contains destination MAC address + partial source address )
RX_STATE2 <= '1' when (RX_STATE = 2) else '0';
XGMII_RX_SOF1_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		-- the first received word with start character does not have enough data bytes to fill the 8-byte XGMII_RX_DATA1,
		-- but the next word certainly has
		if(SYNC_RESET156 = '1') then
			XGMII_RX_SOF1 <= '0';
		elsif(RX_STATE2 = '1') and (RX_STATE2_D = '0') then
			XGMII_RX_SOF1 <= '1';
		else
			XGMII_RX_SOF1 <= '0';
		end if;
		-- test test test 
		XGMII_RX_SOF1_D2 <= XGMII_RX_SOF1_D;
-- collect first few words of first failed CRC frame (compare with Wireshark)
--		if(XGMII_RX_SOF1 = '1') and (FIRST_RXCRCERROR_FLAG = '0') then
--			DEBUG1 <= XGMII_RX_DATA1;
--		end if;
--		if(XGMII_RX_SOF1_D = '1') and (FIRST_RXCRCERROR_FLAG = '0') then
--			DEBUG2 <= XGMII_RX_DATA1;
--		end if;
--		if(XGMII_RX_SOF1_D2 = '1') and (FIRST_RXCRCERROR_FLAG = '0') then
--			DEBUG3 <= XGMII_RX_DATA1;
--		end if;
		
	end if;
end process;

-- mark the XGMII_RX_EOF1 (last word, may be partially filled: see XGMII_RX_FRAME_SIZE(2 downto 0))
XGMII_RX_EOF1_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if(SYNC_RESET156 = '1') then
			XGMII_RX_EOF1A <= '0';
		elsif(RX_STATE2 = '1') and (XGMII_RX_TERM_CHAR = '1') then
		    if (XGMII_RX_SFD_LOC = "111") then
    		    -- terminate character detected, no data in cache
 			    if(XGMII_RX_TERM_LOC = "000") then
                    -- no new data, no data in cache (immediate EOF, see addendum below this process)
                    XGMII_RX_EOF1A <= '0';
                else
                    -- new data, no data in cache
                    XGMII_RX_EOF1A <= '1';
               end if;
            else
				-- received terminate character: received less than 8 bytes and 4 Bytes data in cache.
 			    if(unsigned(XGMII_RX_TERM_LOC) < 5) then
                    -- 4 Bytes or less of new data + 4 Bytes in cache
                    XGMII_RX_EOF1A <= '1';
                else
                    -- 5 Bytes or more of new data + 4 Bytes in cache
                    -- need an additional flush cycle for remaining bytes
                    XGMII_RX_EOF1A <= '0';
                 end if;
            end if;
		elsif(XGMII_RX_FLUSH = '1') then
			-- flush remaining bytes in XGMII_RX_DATA1A cache
			XGMII_RX_EOF1A <= '1';
		else
			XGMII_RX_EOF1A <= '0';
		end if;
	end if;
end process;

XGMII_RX_EOF1 <= 
	'1' when (RX_STATE = 2) and (XGMII_RX_TERM_CHAR = '1') and (XGMII_RX_TERM_LOC = "000") else
	XGMII_RX_EOF1A;



-- Destination address check
MAC_ADDR_REORDER <=  MAC_ADDR(7 downto 0) & MAC_ADDR(15 downto 8) & 
							MAC_ADDR(23 downto 16) & MAC_ADDR(31 downto 24) & 
							MAC_ADDR(39 downto 32) & MAC_ADDR(47 downto 40);
		-- reorder the bytes, as the XGMII interface packs first byte as LSB
ADDR_CHECK_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			RX_VALID_ADDR <= '0';
		elsif(MAC_RX_CONFIG(0) = '1') then
			-- promiscuous mode. No destination address check
			RX_VALID_ADDR <= '1';
		elsif(XGMII_RX_SOF1 = '1') then
			-- 1st word. Check address in Bytes 5:0
			if(XGMII_RX_DATA1(47 downto 0) = MAC_ADDR_REORDER) then
				-- destination address matches
				RX_VALID_ADDR <= '1';
			elsif (XGMII_RX_DATA1(47 downto 0) = x"FFFFFFFFFFFF") and (MAC_RX_CONFIG(1) = '1') then
				-- accepts broadcast packets with the broadcast destination address FF:FF:FF:FF:FF:FF. 
				RX_VALID_ADDR <= '1';
			elsif (XGMII_RX_DATA1(0) = '1') and (MAC_RX_CONFIG(2) = '1') then
				-- accept multicast packets with the multicast bit set in the destination address. 
				-- '1' in the LSb of the first address byte.
				RX_VALID_ADDR <= '1';
		   else
				RX_VALID_ADDR <= '0';
			end if;
		end if;
	end if;
end process;


--//-- RX ETHERNET FRAME PARSING ---------------------------
-- IEEE 802.1Q field, VLAN
VLAN_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			RX_VLAN <= '0';
		elsif(XGMII_RX_SAMPLE1_CLK = '1') and (RX_WORD_CNTR = 2) then
			-- 2nd word, check bytes 5:4
			if(XGMII_RX_DATA1(47 downto 32) = x"0081") then
				RX_VLAN <= '1';
			else
				RX_VLAN <= '0';
			end if;
		end if;
	end if;
end process;

--//-- MAC CONTROL PAUSE OPERATION ---------------------------
-- As per IEEE 802.3-2015 clause 31
-- See also Annex 31B.1
PAUSE_OPCODE <= XGMII_RX_DATA1(55 downto 48) & XGMII_RX_DATA1(63 downto 56);
MAC_CONTROL_PAUSE_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') and (MAC_CONTROL_PAUSE_ENABLE = '0') then
			RX_CONTROL_PAUSE_VALID <= '0';
		elsif(XGMII_RX_SOF1 = '1') then
			-- Destination is always the globally assigned 48-bit multicast address 01-80-C2-00-00-01
			if(XGMII_RX_DATA1(47 downto 0) = x"010000c28001") then
				-- destination address matches
				RX_CONTROL_PAUSE_VALID <= '1';
			else
				RX_CONTROL_PAUSE_VALID <= '0';
			end if;
		elsif(XGMII_RX_SAMPLE1_CLK = '1') and (RX_WORD_CNTR = 2) then
			if(RX_LENGTH_TYPE_FIELD /= x"8808") then
				-- not the expected type field for a MAC control message
				RX_CONTROL_PAUSE_VALID <= '0';
			end if;
			if(PAUSE_OPCODE /= x"0001") then
				-- not the expected PAUSE OpCode
				RX_CONTROL_PAUSE_VALID <= '0';
			end if;
		elsif(MAC_RX_EOF2 = '1') and (RX_CRC_VALID2 = '0') then
			-- BAD_CRC
			RX_CONTROL_PAUSE_VALID <= '0';
		end if;
	end if;
end process;
-- confirm valid MAC control PAUSE message
RX_CONTROL_PAUSE_VALID2 <= RX_CONTROL_PAUSE_VALID and RX_CRC_VALID2 and MAC_RX_EOF2;

-- parse pause time
MAC_CONTROL_PAUSE_002: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') and (MAC_CONTROL_PAUSE_ENABLE = '0') then
			RX_CONTROL_PAUSE_VALID <= '0';
		elsif(XGMII_RX_SAMPLE1_CLK = '1') and (RX_WORD_CNTR = 3) then
			PAUSE_TIME <= XGMII_RX_DATA1(7 downto 0) & XGMII_RX_DATA1(15 downto 8);
		end if;
	end if;
end process;

-- TODO: enact tx pause

--//  RX 32-BIT CRC COMPUTATION -------------------------------------------------------
-- 802.3 section 3.2.9: 
-- protected fields: payload data + optional pad + CRC (excludes preamble and start of frame sequence)

-- The CRC32 component assumes the serial stream is packed into 64-bit words MSb of MSB first.
-- Since XGMII_RX_DATA1 is packed LSb of LSB first, we need to re-order.
-- Other reordering consideration: the CRC32 is computed with 'reflected' input bytes.
-- In summary MSB <-> LSB 
REORDER_CRC32_INPUT: process(XGMII_RX_DATA1, XGMII_RX_DATA1_VALID)
begin
	for I in 0 to 63 loop
		RX_CRC_DATA_IN(I) <= XGMII_RX_DATA1(63-I);
	end loop;
	for J in 0 to 7 loop
       RX_CRC_DATA_VALID_IN(J) <= XGMII_RX_DATA1_VALID(7-J);
    end loop;
end process;

RX_CRC_001: CRC32 PORT MAP (
	 CLK => CLK156g,
	 DATA_IN => RX_CRC_DATA_IN,
	 SOF_IN => XGMII_RX_SOF1,
	 SAMPLE_CLK_IN => XGMII_RX_SAMPLE1_CLK,
	 DATA_VALID_IN => RX_CRC_DATA_VALID_IN,
	 CRC_INITIALIZATION => x"FFFFFFFF",
	 CRC_OUT => RX_CRC1_D,
	 SAMPLE_CLK_OUT => open
  );

---- The CRC output must be 'reflected' and inverted.
--REORDER_CRC32_OUTPUT: process(RX_CRC0)
--begin
--	for I in 0 to 31 loop
--		RX_CRC(I) <= not RX_CRC0(31-I);
--	end loop;
--end process;

-- when not reflected nor inverted, the correct value for RX_CRC0 is 0xC704DD7B
-- (reflected/inverted: 0x2144DF1C)
RX_CRC_VALID2 <= '1' when RX_CRC2 = x"C704DD7B" else '0';

-- align data output with CRC computation output
RECLOCK_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
        XGMII_RX_DATA1_D <= XGMII_RX_DATA1;
        XGMII_RX_DATA1_VALID_D <= XGMII_RX_DATA1_VALID;
        XGMII_RX_SOF1_D <= XGMII_RX_SOF1;
        XGMII_RX_EOF1_D <= XGMII_RX_EOF1;
        XGMII_RX_SAMPLE1_CLK_D <= XGMII_RX_SAMPLE1_CLK;

        MAC_RX_DATA2 <= XGMII_RX_DATA1_D;
        MAC_RX_DATA2_VALID <= XGMII_RX_DATA1_VALID_D;
        MAC_RX_SOF2 <= XGMII_RX_SOF1_D;
        MAC_RX_EOF2 <= XGMII_RX_EOF1_D;
        MAC_RX_SAMPLE2_CLK <= XGMII_RX_SAMPLE1_CLK_D;
        RX_CRC2 <= RX_CRC1_D;
        
        -- The entire frame validity is confirmed at the end of frame
        -- (CRC check excluded in this partial report)
       if (RX_TOO_SHORT = '0') and (RX_TOO_LONG = '0') and 
        (RX_VALID_ADDR = '1') and (RX_LENGTH_ERR = '0') then
           MAC_RX_FRAME_VALID2A <= '1';
        else
           MAC_RX_FRAME_VALID2A <= '0';
        end if;
	end if;
end process;
MAC_RX_FRAME_VALID2 <= MAC_RX_FRAME_VALID2A and RX_CRC_VALID2; 
-- test test test
FIRST_RXCRCERROR_FLAG_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			FIRST_RXCRCERROR_FLAG <= '0';
		elsif(MAC_RX_EOF2 = '1') and (RX_CRC_VALID2 = '0') then
			-- BAD_CRC
			FIRST_RXCRCERROR_FLAG <= '0';
		end if;
	end if;
end process;



--// Length/type field check ----------------------
RX_LENGTH_TYPE_FIELD <= XGMII_RX_DATA1(39 downto 32) & XGMII_RX_DATA1(47 downto 40);	-- easier to read the expected 0x0800 0x0806 etc.
LENGTH_CHECK_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			RX_LENGTH_TYPEN <= '0';  
		elsif(XGMII_RX_SOF1 = '1') then
			-- assume type field by default at the start of frame
			RX_LENGTH_TYPEN <= '0';  -- length/type field represents a type. ignore the length value.
		elsif(XGMII_RX_SAMPLE1_CLK = '1') and (RX_WORD_CNTR = 2) then
			if(unsigned(RX_LENGTH_TYPE_FIELD(15 downto 11)) = 0) then
				-- this field is interpreted as "Length" = client data field size
				-- MSB first (802.3 section 3.2.6)
				RX_LENGTH <= unsigned(RX_LENGTH_TYPE_FIELD(13 downto 0));
				RX_LENGTH_TYPEN <= '1';  -- length/type field represents a length
			else
				-- this is an ethertype or 802.1q tag
				RX_LENGTH_TYPEN <= '0';  -- length/type field represents a type. ignore the length value.
			end if;
		end if;
	end if;
end process;


-- compute the difference between RX_BYTE_CNTR and RX_LENGTH (meaningless, but help minimize gates)
RX_DIFF <= RX_BYTE_CNTR - RX_LENGTH;

-- Length field consistency with actual rx frame length. Check if the length/type field is 'length'
RX_LENGTH_ERR_GEN: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (SYNC_RESET156 = '1') then
			RX_LENGTH_ERR <= '0'; 
		elsif(RX_LENGTH_TYPEN = '0') then
			-- type field. No explicit length info. Can't validate actual length.
			RX_LENGTH_ERR <= '0'; 
		elsif(XGMII_RX_EOF1 = '1') then
			if ((RX_LENGTH <= 46) and (RX_VLAN = '0'))  or
				((RX_LENGTH <= 42) and (RX_VLAN = '1')) then
				-- short rx frame is padded to the minimum size of 60 bytes + 4 CRC
				if(RX_BYTE_CNTR = 64) then
					-- correct answer.
					RX_LENGTH_ERR <= '0'; 
				else
					-- inconsistency
					RX_LENGTH_ERR <= '1'; 
				end if;
			else
				-- normal size frame. no pad.
				if((RX_DIFF = 18) and (RX_VLAN = '0')) or 
					((RX_DIFF = 22) and (RX_VLAN = '1'))then
					-- correct answer.
					RX_LENGTH_ERR <= '0'; 
				else
					-- inconsistency
					RX_LENGTH_ERR <= '1'; 
				end if;
			end if;
		end if;
	end if;
end process;


--//  VALID RX FRAME? ----------------------------------------------------------
-- Is the rx frame valid? If so, confirm the wptr location.
MAC_RX_VALID_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then

		if(SYNC_RESET156 = '1') then
			MAC_RX_WPTR_CONFIRMED <= (others => '0');
			N_RX_BAD_CRCS_local <= (others => '0');
			N_RX_FRAMES_TOO_SHORT_local <= (others => '0');
			N_RX_FRAMES_TOO_LONG_local <= (others => '0');
			N_RX_WRONG_ADDR_local <= (others => '0');
			N_RX_LENGTH_ERRORS_local <= (others => '0');
		else 
			if(MAC_RX_EOF2 = '1') then	-- when CRC32 computation is ready
				-- frame complete, all checks complete
				N_RX_FRAMES_local <= N_RX_FRAMES_local + 1;
				
				if(RX_CRC_VALID2 = '0') then
					-- BAD_CRC
					N_RX_BAD_CRCS_local <= N_RX_BAD_CRCS_local + 1;
				end if;
				
				if(RX_TOO_SHORT = '1') then
					-- frame is too short (<64B)
					N_RX_FRAMES_TOO_SHORT_local <= N_RX_FRAMES_TOO_SHORT_local + 1;
				end if;
				
				if(RX_TOO_LONG = '1') then
					-- frame is too long 
					N_RX_FRAMES_TOO_LONG_local <= N_RX_FRAMES_TOO_LONG_local + 1;
				end if;
				
				if(RX_VALID_ADDR = '0') then
					-- address does not match (and promiscuous mode is off)
					N_RX_WRONG_ADDR_local <= N_RX_WRONG_ADDR_local + 1;
				end if;
				
				if(RX_LENGTH_ERR = '1') then
					-- length field is inconsistent with actual rx frame length
					N_RX_LENGTH_ERRORS_local <= N_RX_LENGTH_ERRORS_local + 1;
				end if;
				
--				if (RX_CRC_VALID = '1') and (RX_TOO_SHORT = '0') and (RX_TOO_LONG = '0') and (RX_VALID_ADDR = '1')
--				and (RX_LENGTH_ERR = '0') then 
--					-- passed all checks
--					RX_FRAME_TOGGLE3 <= not RX_FRAME_TOGGLE3; -- delineates VALID rx frames (does not toggle if rx frame was rejected)
--				end if;
				
			end if;
		end if;
	end if;
end process;

MAC_RX_VALID_002: process(CLK156g)
begin
	if rising_edge(CLK156g) then
		if (MAC_RX_EOF2 = '1') then
			MAC_RX_EOF_TOGGLE <= not MAC_RX_EOF_TOGGLE;
		end if;
	end if;
end process;

-- to DIAGNOSTICS output (reclock with user CLK)
MAC_RX_VALID_003: process(CLK)
begin
	if rising_edge(CLK) then
		MAC_RX_EOF_TOGGLE_D <= MAC_RX_EOF_TOGGLE;
		MAC_RX_EOF_TOGGLE_D2 <= MAC_RX_EOF_TOGGLE_D;
		
		if(MAC_RX_EOF_TOGGLE_D /= MAC_RX_EOF_TOGGLE_D2) then
			-- diagnostics were just updated. Safe to reclock with CLK now.
			N_RX_FRAMES <= std_logic_vector(N_RX_FRAMES_local);
			N_RX_BAD_CRCS <= std_logic_vector(N_RX_BAD_CRCS_local);
			N_RX_FRAMES_TOO_SHORT <= std_logic_vector(N_RX_FRAMES_TOO_SHORT_local);
			N_RX_FRAMES_TOO_LONG <= std_logic_vector(N_RX_FRAMES_TOO_LONG_local);
			N_RX_WRONG_ADDR <= std_logic_vector(N_RX_WRONG_ADDR_local);
			N_RX_LENGTH_ERRORS <= std_logic_vector(N_RX_LENGTH_ERRORS_local);
		end if;
	end if;
end process;

--// LOW-LATENCY RX OUTPUT ----------------------------------------------------------
-- low-latency output case
NO_RX_BUF_001: if(RX_BUFFER = '0') generate
	MAC_RX_DATA <= MAC_RX_DATA2;
	MAC_RX_DATA_VALID <= MAC_RX_DATA2_VALID;
	MAC_RX_SOF <= MAC_RX_SOF2;
	MAC_RX_EOF <= MAC_RX_EOF2;
	MAC_RX_FRAME_VALID <= MAC_RX_FRAME_VALID2;
end generate;

--//  RX INPUT ELASTIC BUFFER ----------------------------------------------------------
RX_BUF_001: if(RX_BUFFER = '1') generate
	-- The purpose of the elastic buffer is two-fold:
	-- (a) a transition between the CLK156g synchronous PHY side and the CLK-synchronous user side.
	-- (b) storage for receive packets, to absorb traffic peaks, minimize the number of 
	-- UDP packets lost at high throughput.
	-- The rx elastic buffer is 16Kbits, large enough for a complete maximum size (14addr+1500data+4FCS = 1518B) frame.

	-- write pointer management
	MAC_RX_WPTR_001: process(CLK156g)
	begin
		if rising_edge(CLK156g) then
			if(SYNC_RESET156 = '1') then
				MAC_RX_WPTR <= (others => '0');
			else
				if(MAC_RX_SAMPLE2_CLK = '1') and  (MAC_RX_EOF2 = '0') then
					MAC_RX_WPTR <= MAC_RX_WPTR + 1;
				elsif (MAC_RX_EOF2 = '1') then
					if(MAC_RX_FRAME_VALID2 = '1') then
						-- valid frame
						MAC_RX_WPTR <= MAC_RX_WPTR + 1;
					else
						-- faulty frame. rewind write pointer to the last confirmed location
						MAC_RX_WPTR <= MAC_RX_WPTR_CONFIRMED;
					end if;
				end if;
			end if;
		end if;
	end process;

	MAC_RX_WPTR_002: process(CLK156g)
	begin
		if rising_edge(CLK156g) then
			if(SYNC_RESET156 = '1') then
				MAC_RX_WPTR_CONFIRMED <= (others => '0');
			elsif (MAC_RX_FRAME_VALID2 = '1') and  (MAC_RX_EOF2 = '1') then
				MAC_RX_WPTR_CONFIRMED <= MAC_RX_WPTR + 1;
			end if;
		end if;
	end process;

	-- concatenate data word, nbytes, sof, eof
	MAC_RX_DIA <= MAC_RX_EOF2 & MAC_RX_SOF2 & MAC_RX_DATA2_VALID & MAC_RX_DATA2;

	-- No need for initialization
	-- cross clock domain from PHY CLK156g to user CLK
	BRAM_DP2_002: BRAM_DP2 
	GENERIC MAP(
		DATA_WIDTHA => 74,		
		ADDR_WIDTHA => RX_BUFFER_ADDR_NBITS,
		DATA_WIDTHB => 74,		 	
		ADDR_WIDTHB => RX_BUFFER_ADDR_NBITS
	)
	PORT MAP(
		 CSA => '1',
		 CLKA => CLK156g,
		 WEA => MAC_RX_SAMPLE2_CLK,
		 OEA => '0',
		 ADDRA => std_logic_vector(MAC_RX_WPTR),  
		 DIA => std_logic_vector(MAC_RX_DIA),
		 DOA => open,
		 CSB => '1',
		 CLKB => CLK,
		 WEB => '0',
		 OEB => '1',
		 ADDRB => std_logic_vector(MAC_RX_RPTR),
		 DIB => (others => '0'),
		 DOB => MAC_RX_DOB
	);

	MAC_RX_WPTR_003: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				MAC_RX_WPTR_CONFIRMED_D <= (others => '0');
			elsif(MAC_RX_EOF_TOGGLE_D /= MAC_RX_EOF_TOGGLE_D2) then
				-- MAC_RX_WPTR_CONFIRMED is stable. OK to resample with the CLK clock.
				MAC_RX_WPTR_CONFIRMED_D <= MAC_RX_WPTR_CONFIRMED;
			end if;
		end if;
	end process;

	MAC_RX_BUF_SIZE <= MAC_RX_WPTR_CONFIRMED_D + not(MAC_RX_RPTR);
	-- occupied tx buffer size

	-- manage read pointer
	MAC_RX_RPTR_001: process(CLK)
	begin
		if rising_edge(CLK) then
			MAC_RX_SAMPLE3_CLK <= MAC_RX_SAMPLE3_CLK_E;  -- it takes one CLK to read data from the RAMB

			if(SYNC_RESET = '1') then
				MAC_RX_RPTR <= (others => '1');
				MAC_RX_SAMPLE3_CLK_E <= '0';
			elsif(MAC_RX_BUF_SIZE /= 0) and (MAC_RX_CTS = '1') then
				MAC_RX_RPTR <= MAC_RX_RPTR + 1;
				MAC_RX_SAMPLE3_CLK_E <= '1';
			else
				MAC_RX_SAMPLE3_CLK_E <= '0';
			end if;	
		end if;
	end process;

	MAC_RX_DATA <= MAC_RX_DOB(63 downto 0);
	MAC_RX_DATA_VALID <= MAC_RX_DOB(71 downto 64);
	MAC_RX_SOF <= MAC_RX_DOB(72) and MAC_RX_SAMPLE3_CLK;
	MAC_RX_EOF <= MAC_RX_DOB(73) and MAC_RX_SAMPLE3_CLK;

end generate;

--// TEST POINTS -------------------------
--TP<= PHY_CONFIG_TP;
TP_001: process(CLK156g)
begin
	if rising_edge(CLK156g) then
--	   if(XGMII_RX_START_LOC = "000") then
--       TP(2) <= '1';
--      else
--       TP(2) <= '0';
--      end if;
--	   if(XGMII_RXC /= x"FF") then
--        TP(3) <= '1';
--       else
--        TP(3) <= '0';
--       end if;
--	   if(XGMII_RXC = x"00") then
--         TP(4) <= '1';
--        else
--         TP(4) <= '0';
--        end if;
--        TP(5) <= XGMII_RX_START_CHAR;
--        TP(6) <= XGMII_RX_SFD_CHAR;
--        TP(7) <= XGMII_RX_TERM_CHAR;
        
--        if(XGMII_RXC(0) = '1') and (XGMII_RXD(7 downto 0) = x"FB") then
--           TP(8) <= '1';
--        else
--           TP(8) <= '0';
--        end if;    
--        if(XGMII_RXC(0) = '0') and (XGMII_RXD(63 downto 56) = x"D5") then
--           TP(9) <= '1';
--        else
--           TP(9) <= '0';
--        end if;    
----        TP(8) <= XGMII_RX_SOF1;
----        TP(9) <= XGMII_RX_SAMPLE1_CLK;
--        TP(10) <= XGMII_RX_SOF1;

        TP(2) <= MAC_RX_EOF2;
        TP(3) <= MAC_RX_EOF2 and MAC_RX_FRAME_VALID2;
        TP(4) <= RX_CRC_VALID2;
        TP(5) <= XGMII_RX_SOF1;
        TP(6) <= XGMII_RX_SAMPLE1_CLK;
	   if(XGMII_RXC /= x"FF") then
                TP(7) <= '1';
               else
                TP(7) <= '0';
               end if;
         if(XGMII_RX_DATA1_VALID /= x"00") then
           TP(8) <= '1';
        else
           TP(8) <= '0';
        end if;    
        if(XGMII_RX_DATA1_VALID = x"FF") then
           TP(9) <= '1';
        else
           TP(9) <= '0';
        end if;    

	end if;
end process;

end Behavioral;

