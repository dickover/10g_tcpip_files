-------------------------------------------------------------
-- MSS copyright 2010-2018
--	Filename:  PHY_CONFIG.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 0
--	Date last modified: 8/16/18
-- Inheritance: 	COM-5401 PHY_CONFIG.VHD rev6 8/23/13
--
-- description:  Configures a 10G PHY through a MDIO interface.
-- The control and status registers are specific to the VSC8486-11 PHY
-- The state machine must be edited to reflect any other PHY.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity PHY_CONFIG is
	generic (
		EXT_PHY_MDIO_ADDR: std_logic_vector(4 downto 0) := "00000"	
			-- external PHY MDIO address
	);
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		
		--// CONTROLS
		CONFIG_CHANGE: in std_logic;
			-- 1 CLK-wide pulse to activate any configuration change below.
			-- Not needed if the default values are acceptable.
		PHY_RESET: in std_logic; 
			-- 1 = PHY software reset, 0 = no reset
		TEST_MODE: in std_logic_vector(1 downto 0);
			-- 00 = normal mode (default)
			-- 01 = loopback mode
			-- 10 = remote loopback
		POWER_DOWN: in std_logic;
			-- software power down mode. 1 = enabled, 0 = disabled (default).

		--// MONITORING
		-- read ONE status register
		SREG_READ_START: in std_logic;
			-- 1 CLK wide pulse to start read transaction
			-- will be ignored if the previous transaction is yet to be completed.
		SREG_MMD: in std_logic_vector(4 downto 0);	
			-- device 
		SREG_ADDR: in std_logic_vector(15 downto 0);	
			-- status register address
		SREG_DATA : OUT std_logic_vector(15 downto 0);
			-- 16-bit status register. Read when SREG_SAMPLE_CLK = '1'
		SREG_SAMPLE_CLK: out std_logic;
		SREG_READ_IDLE: out std_logic;
			-- '1' when the state machine is idle and thus available to read another status register
			
		
		-- Connect to external PHY and XAUI adapter (shared MDIO bus)
		MDC: out std_logic;
		MDIO_OUT: out std_logic;  
		MDIO_IN: in std_logic;
		MDIO_DIR: out std_logic;	-- '0' when output, '1' when input
			-- MDIO serial interface to control and monitor two MMDs: external 10G PHY and 
			-- internal XAUI adapter.
		
		--// TEST POINTS
		TP: out std_logic_vector(10 downto 1)
		
		
);
end entity;

architecture Behavioral of PHY_CONFIG is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT MII_MI
	PORT(
		SYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		PHY_ADDR: std_logic_vector(4 downto 0);
		MI_REGAD : IN std_logic_vector(4 downto 0);
		MI_TX_DATA : IN std_logic_vector(15 downto 0);
		MI_ADDR_START: in std_logic;
		MI_READ_START : IN std_logic;
		MI_WRITE_START : IN std_logic;    
		MI_RX_DATA : OUT std_logic_vector(15 downto 0);
		MI_TRANSACTION_COMPLETE : OUT std_logic;
		MDC: out std_logic;
		MDIO_OUT: out std_logic;  
		MDIO_IN: in std_logic;
		MDIO_DIR: out std_logic	-- '0' when output, '1' when input
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal CONFIG_CHANGE_PENDING_FLAG: std_logic:= '0';
signal PHY_RESET0: std_logic:= '0';
signal PHY_RESET_D: std_logic:= '0';
signal TEST_MODE0: std_logic_vector(1 downto 0) := (others => '0');
signal POWER_DOWN0: std_logic:= '0';
signal POWER_DOWN_D: std_logic:= '0';
signal LOOPBACK_MODE: std_logic:= '0';
signal REMOTE_LOOPBACK: std_logic:= '0';
signal STATE: unsigned(7 downto 0) := (others => '0');
signal MI_WRITE_START: std_logic := '0';
signal MI_REGAD: std_logic_vector(4 downto 0) := "00000";
signal MI_TX_DATA: std_logic_vector(15 downto 0) := (others => '0');
signal MI_READ_START: std_logic := '0';
signal MI_ADDR_START: std_logic := '0';
signal MI_RX_DATA: std_logic_vector(15 downto 0) := (others => '0');
signal MI_TRANSACTION_COMPLETE: std_logic:= '0';
signal SREG_SAMPLE_CLK_local: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- hold the configuration request until it is time to process it (state machine may be busy)
CONFIG_SAVE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(CONFIG_CHANGE = '1') then
			CONFIG_CHANGE_PENDING_FLAG <= '1';
			PHY_RESET0 <= PHY_RESET;
			TEST_MODE0 <= TEST_MODE;
			POWER_DOWN0 <= POWER_DOWN;
		elsif(STATE = 0) and (CONFIG_CHANGE_PENDING_FLAG = '1') then
			CONFIG_CHANGE_PENDING_FLAG <= '0';
		end if;
	end if;
end process;


-- save the configuration so that it does not change while the configuration is in progress
RECLOCK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(STATE = 0) and (CONFIG_CHANGE_PENDING_FLAG = '1') then
			PHY_RESET_D <= PHY_RESET0;
			POWER_DOWN_D <= POWER_DOWN0;
			
			case TEST_MODE0 is
				when "00" => 
					LOOPBACK_MODE <= '0';
					REMOTE_LOOPBACK <= '0';
				when "01" => 
					LOOPBACK_MODE <= '1';
					REMOTE_LOOPBACK <= '0';
				when "10" => 
					LOOPBACK_MODE <= '0';
					REMOTE_LOOPBACK <= '1';
				when others => 
					LOOPBACK_MODE <= '0';
					REMOTE_LOOPBACK <= '0';
			end case;
		end if;
	end if;
end process;

-- state machine
-- The state machine structure is generic, however, the actual control and status registers
-- depend on the PHY.
-- Written specifically for the Microsemi VSC8486-11 PHY
STATE_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE <= (others => '0');
			MI_REGAD <= (others => '0');
			MI_TX_DATA <= (others => '0');
			MI_ADDR_START <= '0';
			MI_WRITE_START <= '0';
			MI_READ_START <= '0';
			SREG_SAMPLE_CLK_local <= '0';

		-- WRITE CONFIGURATION REGISTERS as needed
		elsif(STATE = 0) and (CONFIG_CHANGE_PENDING_FLAG = '1') then
			-- triggers a PHY reconfiguration. await PHY MDIO availability
			STATE <= STATE + 1;
			SREG_SAMPLE_CLK_local <= '0';

		elsif(STATE = 1) and (MI_TRANSACTION_COMPLETE = '1') then
			-- PHY is ready for next transaction.
			-- Set address register 1x0000
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= x"0000";
			MI_ADDR_START <= '1';
		elsif(STATE = 2) and (MI_TRANSACTION_COMPLETE = '1') then
			-- set configuration register 1x0000 (part 1/2)
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= PHY_RESET_D & "010" & POWER_DOWN_D & "0000100000" & LOOPBACK_MODE;
				-- loopback J
				-- low power
				-- soft reset
			MI_WRITE_START <= '1';
		elsif(STATE = 3) and (MI_TRANSACTION_COMPLETE = '1') then
			-- set configuration register 1x0000 (part 2/2)
			-- remove the reset condition
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= "0010" & POWER_DOWN_D & "0000100000" & LOOPBACK_MODE;
				-- loopback J
				-- low power
				-- soft reset
			MI_WRITE_START <= '1';
		elsif(STATE = 4) and (MI_TRANSACTION_COMPLETE = '1') then
			-- PHY is ready for next transaction.
			-- Set address register 1x8000
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= x"8000";
			MI_ADDR_START <= '1';
		elsif(STATE = 5) and (MI_TRANSACTION_COMPLETE = '1') then
			-- set configuration register 1x8000
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= x"B55F";
				-- invert tx data polarity (see com5104 schematics)
			MI_WRITE_START <= '1';
		elsif(STATE = 6) and (MI_TRANSACTION_COMPLETE = '1') then
			-- PHY is ready for next transaction.
			-- Set address register 1xE901
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= x"E901";
			MI_ADDR_START <= '1';
		elsif(STATE = 7) and (MI_TRANSACTION_COMPLETE = '1') then
			-- set configuration register 1xE901
			STATE <= STATE + 1;
			MI_REGAD <= "00001";
			MI_TX_DATA <= x"283A";
				-- LEDs configured for rx and tx lines activity
			MI_WRITE_START <= '1';
		elsif(STATE = 8) and (MI_TRANSACTION_COMPLETE = '1') then
			-- PHY is ready for next transaction.
			-- Set address register 4x800F
			STATE <= STATE + 1;
			MI_REGAD <= "00100";
			MI_TX_DATA <= x"800F";
			MI_ADDR_START <= '1';
		elsif(STATE = 9) and (MI_TRANSACTION_COMPLETE = '1') then
			-- set configuration register 4x800F
			STATE <= (others => '0');	-- back to idle unless there are other write transactions
			MI_REGAD <= "00100";
			MI_TX_DATA <= x"0600";
				-- invert XAUI tx/rx bits (see COM-5104 schematics p3)
			MI_WRITE_START <= '1';
			
		-- add more write cycles to control registers... as needed
		-- then move to reading a status register
			
		-- READ ONE STATUS REGISTER	
		elsif(STATE = 0) and (SREG_READ_START = '1') then
			-- triggers a PHY status read. await PHY MDIO availability
			STATE <= "00010000";
			SREG_SAMPLE_CLK_local <= '0';
		elsif(STATE = 16) and (MI_TRANSACTION_COMPLETE = '1') then
			-- set status register address 
			STATE <= STATE + 1;
			MI_REGAD <= SREG_MMD;  
			MI_TX_DATA <= SREG_ADDR;
			MI_ADDR_START <= '1';
		elsif(STATE = 17) and (MI_TRANSACTION_COMPLETE = '1') then
			-- read status register 
			STATE <= STATE + 1;
			MI_REGAD <= SREG_MMD;  
			MI_READ_START <= '1';
		elsif(STATE = 18) and (MI_TRANSACTION_COMPLETE = '1') then
			-- we are done reading a status register! Going back to idle.
			STATE <= (others => '0');
			MI_READ_START <= '0';
			SREG_SAMPLE_CLK_local <= '1';
		else
			MI_ADDR_START <= '0';
			MI_WRITE_START <= '0';
			MI_READ_START <= '0';
			SREG_SAMPLE_CLK_local <= '0';
		
		end if;
	end if;
end process;

SREG_READ_IDLE <= '1' when (STATE = 0) and (CONFIG_CHANGE_PENDING_FLAG = '0') else '0';
	-- '1' when the state machine is idle and thus available to read another status register

-- latch status register
SREGOUT_001:  process(CLK)
begin
	if rising_edge(CLK) then
		SREG_SAMPLE_CLK <= SREG_SAMPLE_CLK_local;
		
		if(SREG_SAMPLE_CLK_local = '1') then
			SREG_DATA <= MI_RX_DATA;
		end if;
	end if;
end process;


MII_MI_001: MII_MI 
PORT MAP(
	SYNC_RESET => SYNC_RESET,
	CLK => CLK,
	PHY_ADDR => EXT_PHY_MDIO_ADDR,
	MI_REGAD => MI_REGAD,
	MI_TX_DATA => MI_TX_DATA,
	MI_RX_DATA => MI_RX_DATA,
	MI_ADDR_START => MI_ADDR_START,
	MI_WRITE_START => MI_WRITE_START,
	MI_READ_START => MI_READ_START,
	MI_TRANSACTION_COMPLETE => MI_TRANSACTION_COMPLETE,
	MDC => MDC,
	MDIO_OUT => MDIO_OUT,
	MDIO_IN => MDIO_IN,
	MDIO_DIR => MDIO_DIR
);

--// TEST POINTS -------------------------
TP(1) <= CONFIG_CHANGE;
TP(2) <= MI_TRANSACTION_COMPLETE;
TP(3) <= SREG_SAMPLE_CLK_local;
TP(4) <= '1' when (STATE = 1) else '0';
TP(5) <= '1' when (STATE = 6) else '0';
TP(6) <= '1' when (STATE = 9) else '0';
TP(7) <= '1' when (STATE = 10) else '0';
TP(8) <= MI_ADDR_START;
TP(9) <= MI_WRITE_START;
TP(10) <= MI_READ_START;


end Behavioral;

