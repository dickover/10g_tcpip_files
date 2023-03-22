-------------------------------------------------------------
-- MSS copyright 2003-2018
--	Filename:  MII_MI.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 12/2/17
-- Inheritance: 	MII_MI.VHD rev3 2/1/14 (COM-5401)
--						MII_MI.vhd rev1 11-8-03 (COM-5003/5004)
--
-- description:  MII management interface.
-- Three transactions are supported: set register address, write and read register
-- to/from the PHY IC through the MDC & MDIO serial interface.
-- The MCLK clock speed is set as a constant within (integer division of the reference clock CLK).
-- USAGE: adjust the constant MCLK_COUNTER_DIV within to meet the MDC/MDIO timing requirements (see PHY specs).
-- Note: uses a ST="00" start of frame, unlike previous versions using a "01"
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee. numeric_std.all;

entity MII_MI is
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;

		PHY_ADDR: std_logic_vector(4 downto 0);
			-- destination device address
		MI_REGAD: in std_logic_vector(4 downto 0);	
			-- 32 register address space for the PHY (ieee 802.3)
			--  0 - 15 are standard PHY registers as per IEEE specification.
			-- 16 - 31 are vendor-specific registers
		MI_TX_DATA: in std_logic_vector(15 downto 0);
			-- address/data
		MI_RX_DATA: out std_logic_vector(15 downto 0);	
		MI_ADDR_START: in std_logic;
			-- 1 CLK wide pulse to start a set address transaction
			-- The 16-bit address is in MI_TX_DATA
			-- will be ignored if the previous transaction is yet to be completed.
			-- For reliable operation, the user must check MI_TRANSACTION_COMPLETE first.
		MI_READ_START: in std_logic;
			-- 1 CLK wide pulse to start read transaction
			-- will be ignored if the previous transaction is yet to be completed.
			-- For reliable operation, the user must check MI_TRANSACTION_COMPLETE first.
		MI_WRITE_START: in std_logic;
			-- 1 CLK wide pulse to start write transaction
			-- will be ignored if the previous transaction is yet to be completed.
			-- For reliable operation, the user must check MI_TRANSACTION_COMPLETE first.

		MI_TRANSACTION_COMPLETE: out std_logic;
			-- '1' when transaction is complete 

		--// serial interface to/from MDIO managed devices:
		-- Connect to external PHY and XAUI adapter (shared MDIO bus)
		MDC: out std_logic;
		MDIO_OUT: out std_logic;  
		MDIO_IN: in std_logic;
		MDIO_DIR: out std_logic
			-- '0' when output, '1' when input
			-- MDIO serial interface to control and monitor two MMDs: external 10G PHY and 
			-- internal XAUI adapter.
		
 );
end entity;

architecture Behavioral of MII_MI is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal TRANSACTION: std_logic_vector(1 downto 0) := "00";
signal STATE: unsigned(7 downto 0) := (others => '0');   -- 0 is idle
signal TXRX_FRAME: std_logic_vector(63 downto 0); --32-bit idle sequence + 32-bit MI serial port frame + 2 end bit
signal MCLK_LOCAL: std_logic := '0';
signal MDOE: std_logic := '1';
signal MDI_SAMPLE_CLK: std_logic := '0';
constant MCLK_COUNTER_DIV: unsigned(7 downto 0) := x"4D"; 	--  1 MHz (156.25 MHz/156)
--constant MCLK_COUNTER_DIV: std_logic_vector(7 downto 0) := x"17";  
	-- divide CLK by this 2*(value + 1) to generate a slower MCLK
	-- MCLK period (typ): 600 ns [Microsemi VSC8486-11]
	-- Example: 156.25 MHz clock, 1us MCLK period => MCLK_COUNTER_DIV = 77
signal MCLK_COUNTER: unsigned(7 downto 0) := x"00";
signal MI_SAMPLE_REQ: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

------------------------------------------------------
-- MCLK GENERATION
------------------------------------------------------
-- Divide CLK by MCLK_COUNTER_DIV
MCLK_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MCLK_COUNTER <= (others => '0');
			MI_SAMPLE_REQ <= '0';
		elsif(STATE = 0) then
			-- idle. awaiting a start of transaction.
			MI_SAMPLE_REQ <= '0';
			if(MI_WRITE_START = '1') or (MI_READ_START = '1') or (MI_ADDR_START = '1') then
				-- get started. reset MCLK phase.
				MCLK_COUNTER <= (others => '0');
			end if;
		else
			-- read/write transaction in progress
			if(MCLK_COUNTER = MCLK_COUNTER_DIV) then 
				-- next sample
				MI_SAMPLE_REQ <= '1';
				MCLK_COUNTER <= (others => '0');
			else
				MI_SAMPLE_REQ <= '0';
				MCLK_COUNTER <= MCLK_COUNTER + 1;
			end if;
		end if;
	end if;
end process;

------------------------------------------------------
-- OUTPUT TO PHY
------------------------------------------------------

STATE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE <= (others => '0');
			MCLK_LOCAL <= '0';
			MDOE <= '0';
			TRANSACTION <= "00";	
		elsif(STATE = 0) then
			if(MI_ADDR_START = '1') then
				-- was idle. start of set address transaction. start counting 
				TRANSACTION <= "00";
				STATE <= x"01";
				MCLK_LOCAL <= '0';
				MDOE <= '1';
			elsif (MI_WRITE_START = '1') then
				-- was idle. start of write transaction. start counting 
				TRANSACTION <= "01";
				STATE <= x"01";
				MCLK_LOCAL <= '0';
				MDOE <= '1';
			elsif (MI_READ_START = '1') then
				-- was idle. start of read transaction. start counting 
				TRANSACTION <= "11";
				STATE <= x"01";
				MCLK_LOCAL <= '0';
				MDOE <= '1';
			end if;
		elsif (MI_SAMPLE_REQ = '1') then
			if (STATE = 128) then
				-- address/write transaction complete. set output enable to high impedance
				TRANSACTION <= "00";
				STATE <= x"00";
				MCLK_LOCAL <= '0';
				MDOE <= '0';
				if(TRANSACTION(1) = '1') then
					-- read transaction near complete
					MI_RX_DATA <= TXRX_FRAME(15 downto 0);  -- complete word read from PHY
				end if;
			elsif (TRANSACTION(1) = '1') and (STATE = 92) then
				-- read transaction: finished writing addresses. switch to read mode
				STATE <= STATE + 1;
				MCLK_LOCAL <= not MCLK_LOCAL;
				MDOE <= '0';
			else
				STATE <= STATE + 1;
				MCLK_LOCAL <= not MCLK_LOCAL;
			end if;
		end if;
	end if;
end process;

-- immediate turn off the 'available' message as soon as a new transaction is triggered.
MI_TRANSACTION_COMPLETE <= '0' when (STATE > 0) else
									'0' when (MI_ADDR_START = '1') else
									'0' when (MI_WRITE_START = '1') else
									'0' when (MI_READ_START = '1') else
									'1';

-- send MCLK to output
MDC <= MCLK_LOCAL;

TXRX_FRAME_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TXRX_FRAME <= (others => '0');
		elsif(MI_ADDR_START = '1') then
			-- start of set address transaction. 
			-- Note: transmission sequence starts at bit 63 
			TXRX_FRAME(63 downto 32) <= x"FFFFFFFF";	-- preamble: idle sequence 32 '1's
			TXRX_FRAME(31 downto 23)  <= "0000" & PHY_ADDR;  
			TXRX_FRAME(22 downto 18) <= MI_REGAD;
			TXRX_FRAME(17 downto 16) <= "10";	
			TXRX_FRAME(15 downto 0) <= MI_TX_DATA;
		elsif(MI_WRITE_START = '1') then
			-- start of write transaction. 
			-- Note: transmission sequence starts at bit 63 
			TXRX_FRAME(63 downto 32) <= x"FFFFFFFF";	-- preamble: idle sequence 32 '1's
			TXRX_FRAME(31 downto 23)  <= "0001" & PHY_ADDR;  
			TXRX_FRAME(22 downto 18) <= MI_REGAD;
			TXRX_FRAME(17 downto 16) <= "10";	
			TXRX_FRAME(15 downto 0) <= MI_TX_DATA;
		elsif(MI_READ_START = '1') then
			-- start of read transaction. 
			-- Note: transmission sequence starts at bit 63 
			TXRX_FRAME(63 downto 32) <= x"FFFFFFFF";	-- preamble: idle sequence 32 '1's
			TXRX_FRAME(31 downto 23)  <= "0011" & PHY_ADDR; 
			TXRX_FRAME(22 downto 18) <= MI_REGAD;
		elsif(MI_SAMPLE_REQ = '1') and (STATE /= 0) and (STATE(0) = '0') and (MDOE = '1') then
			-- shift TXRX_FRAME 1 bit left every two clocks
			TXRX_FRAME(63 downto 1) <= TXRX_FRAME(62 downto 0);
		elsif(MI_SAMPLE_REQ = '1') and (STATE /= 0) and (STATE(0) = '1') and (MDOE = '0') then
			-- shift MDIO into TXRX_FRAME 1 bit left every two clocks (read at the rising edge of MCLK)
			-- do this 16 times to collect the 16-bit response from the PHY.
			TXRX_FRAME(63 downto 1) <= TXRX_FRAME(62 downto 0);
			TXRX_FRAME(0) <= MDIO_IN;
	 	end if;
  end if;
end process;

-- select output bit. 
MDIO_OUT <= TXRX_FRAME(63);
MDIO_DIR <= not MDOE;


end Behavioral;
