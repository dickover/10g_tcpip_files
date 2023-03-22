-------------------------------------------------------------
-- Filename:  XGMII2XAUI.VHD
-- Authors: 
--		Alain Zarembowitch / MSS
-- Version: Rev 0
-- Last modified: 10/25/20
-- Inheritance: 	N/A
--
-- description:   XGMII to XAUI translation
-- converts the incoming XGMII data into XAUI-compatible characters
-- 
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity XGMII2XAUI is
	Generic (
		NBYTES: integer := 4	
			-- number of Bytes in/out. Valid values: 4,8,etc. 
			-- always multiple of 4 (4 lanes per XAUI)
	);
    Port ( 
		SYNC_RESET: in std_logic;
		CLK: in std_logic;

		XGMII_TXD: in std_logic_vector(8*NBYTES-1 downto 0);
		XGMII_TXC: in std_logic_vector(NBYTES-1 downto 0);
			-- Single data rate interface 
			-- LSb of LSB is sent first
			-- Start character 0xFB is always in byte 0
			-- XGMII_RXC control bit is '0' for valid data byte

		XAUI_TXD: out std_logic_vector(8*NBYTES-1 downto 0);
		XAUI_TXCHARISK: out std_logic_vector(NBYTES-1 downto 0);
			-- K character detected 
		
		-- test points
		TP: out std_logic_vector(10 downto 1)
		);
end entity;

architecture Behavioral of XGMII2XAUI is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT LFSR11P
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		SAMPLE_CLK_OUT_REQ : IN std_logic;          
		DATA_OUT : OUT std_logic_vector(7 downto 0);
		SAMPLE_CLK_OUT : OUT std_logic;
		SOF_OUT : OUT std_logic
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal PRBS11_DATA1_VALID: std_logic := '0';
signal PRBS11_CTS1: std_logic := '0';
signal PRBS11_DATA1: std_logic_vector(7 downto 0) := (others => '0');
signal A_CNTR: unsigned(5 downto 0) := (others => '0');
signal T_IN_PREV_GROUP2: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- pseudo-random sequence generator
LFSR11P_001: LFSR11P PORT MAP(
	CLK => CLK,
	SYNC_RESET => SYNC_RESET,
	DATA_OUT => PRBS11_DATA1,
	SAMPLE_CLK_OUT => open,
	SOF_OUT => open,
	SAMPLE_CLK_OUT_REQ => PRBS11_CTS1
);
PRBS11_CTS1 <= '1' when (unsigned(XGMII_TXC) /= 0) else '0';
	-- new random number when idle, not needed during data field


--  XGMII to XAUI Code Mapping. First 4 Bytes
-- Background: see Tables 4/5 in 
-- http://www.latticesemi.com/-/media/LatticeSemi/Documents/UserManuals/1D/10GbEthernetXGXSIPCoreUserGuide.ashx?document_id=6833
-- https://www.ti.com/lit/ds/symlink/tlk3134.pdf?ts=1603734299407&ref_url=https%253A%252F%252Fwww.google.com%252F
MAP_001: process(CLK)
variable A_CNTR_RESET: std_logic;
variable T_IN_GROUP1: std_logic;	-- Terminate code in the first group (I < 4)
variable T_IN_GROUP2: std_logic;	-- Terminate code in the second group (I = 4-7)
begin
	if rising_edge(CLK) then
		A_CNTR_RESET := '0';
		T_IN_GROUP1 := '0';
		T_IN_GROUP2 := '0';
		if(SYNC_RESET = '1') then
			A_CNTR_RESET := '1';
		else
			for I in 0 to NBYTES-1 loop
				if(XGMII_TXC(I) = '0') then
					-- data Byte: unchanged 
					XAUI_TXD(8*(I+1)-1 downto 8*I) <= XGMII_TXD(8*(I+1)-1 downto 8*I);
					XAUI_TXCHARISK(I) <= '0';
				elsif	(XGMII_TXD(8*(I+1)-1 downto 8*I) = x"FD") then
					-- terminate: unchanged
					XAUI_TXD(8*(I+1)-1 downto 8*I) <= XGMII_TXD(8*(I+1)-1 downto 8*I);
					XAUI_TXCHARISK(I) <= '1';
					if(I < 4) then
						T_IN_GROUP1 := '1';
						T_IN_GROUP2 := '0';
					else
						T_IN_GROUP1 := '0';
						T_IN_GROUP2 := '1';
					end if;
				elsif	(XGMII_TXD(8*(I+1)-1 downto 8*I) = x"FB") or 
						(XGMII_TXD(8*(I+1)-1 downto 8*I) = x"FE") or 
						(XGMII_TXD(8*(I+1)-1 downto 8*I) = x"9C") then 
					-- start, error, ordered set: unchanged
					XAUI_TXD(8*(I+1)-1 downto 8*I) <= XGMII_TXD(8*(I+1)-1 downto 8*I);
					XAUI_TXCHARISK(I) <= '1';
				elsif	(XGMII_TXD(8*(I+1)-1 downto 8*I) = x"07") then 
					-- idle 0x07
					XAUI_TXCHARISK(I) <= '1';
					if(I < 4) then
						-- first of possibly two words (when NBYTES = 8)
						if((A_CNTR(A_CNTR'left) = '1') and (T_IN_GROUP1 = '0')) or (T_IN_PREV_GROUP2 = '1') then
							-- minimum /A/ separation requirement met.
							-- send /A/ = K28.3 = 0x7C 
							-- make sure we do not send /A/ in two successive words when NBYTES=8 (I<4 and I>= 4)
							XAUI_TXD(8*(I+1)-1 downto 8*I) <= x"7C";
							A_CNTR_RESET := '1';
						elsif(PRBS11_DATA1(0) = '0') or (T_IN_GROUP1 = '1') then
							-- after Terminate or random
							-- send /K/ = K28.5 = 0xBC (Comma)
							XAUI_TXD(8*(I+1)-1 downto 8*I) <= x"BC";
						else
							-- random number LSb determines whether to send /R/ or /K/
							-- send /R/ = K28.0 = 0x1C
							XAUI_TXD(8*(I+1)-1 downto 8*I) <= x"1C";
						end if;
					else
						-- second of possibly two words (when NBYTES = 8)
						-- use a different random bit for the second word
						if((A_CNTR(A_CNTR'left) = '1') and (T_IN_GROUP2 = '0')) or (T_IN_GROUP1 = '1') then
							-- minimum /A/ separation requirement met.
							-- send /A/ = K28.3 = 0x7C 
							-- make sure we do not send /A/ in two successive words when NBYTES=8 (I<4 and I>= 4)
							XAUI_TXD(8*(I+1)-1 downto 8*I) <= x"7C";
							A_CNTR_RESET := '1';
						elsif(PRBS11_DATA1(1) = '0') or (T_IN_GROUP2 = '1') then
							-- after Terminate or random
							-- send /K/ = K28.5 = 0xBC (Comma)
							XAUI_TXD(8*(I+1)-1 downto 8*I) <= x"BC";
						else
							-- random number bit 1 determines whether to send /R/ or /K/
							-- send /R/ = K28.0 = 0x1C
							XAUI_TXD(8*(I+1)-1 downto 8*I) <= x"1C";
						end if;
					end if;
				else
					-- abnormal case. Should never happen. do nothing. 
					XAUI_TXD(8*(I+1)-1 downto 8*I) <= XGMII_TXD(8*(I+1)-1 downto 8*I);
					XAUI_TXCHARISK(I) <= '1';
				end if;
			end loop;
		end if;

		T_IN_PREV_GROUP2 <= T_IN_GROUP2;	
		
		-- count min separation between /A/
		if(A_CNTR_RESET = '1') then
			A_CNTR <= (others => '0');
		elsif(A_CNTR(A_CNTR'left) = '0') then
			-- increment. Stop when reaching >= 32
			if(NBYTES = 4) then
				A_CNTR <= A_CNTR + 1;
			elsif(NBYTES = 8) then
				A_CNTR <= A_CNTR + 2;
			end if;
		end if;
	end if;
end process;

-- test points
TP(1) <= T_IN_PREV_GROUP2;
TP(2) <= '1' when (XGMII_TXD(7 downto 0) = x"07") and (XGMII_TXC(0) = '1') else '0';
TP(3) <= XGMII_TXC(0);
TP(4) <= XGMII_TXC(4);

end Behavioral;
