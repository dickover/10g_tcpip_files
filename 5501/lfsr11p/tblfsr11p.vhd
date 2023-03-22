--------------------------------------------------------------------------------
-- Company: 
-- Engineer:
--
-- Create Date:   15:59:17 04/26/2017
-- Design Name:   
-- Module Name:   C:/Users/Alain/Documents/1VHDL/com-5402 TCP server 007r/tblfsr11p.vhd
-- Project Name:  com5402_ISE144
-- Target Device:  
-- Tool versions:  
-- Description:   
-- 
-- VHDL Test Bench Created by ISE for module: LFSR11P
-- 
-- Dependencies:
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
-- Notes: 
-- This testbench has been automatically generated using types std_logic and
-- std_logic_vector for the ports of the unit under test.  Xilinx recommends
-- that these types always be used for the top-level I/O of a design in order
-- to guarantee that the testbench will bind correctly to the post-implementation 
-- simulation model.
--------------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
use ieee.numeric_std.all;
 
-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--USE ieee.numeric_std.ALL;
 
ENTITY tblfsr11p IS
END tblfsr11p;
 
ARCHITECTURE behavior OF tblfsr11p IS 
 
    -- Component Declaration for the Unit Under Test (UUT)
 
    COMPONENT LFSR11P
    PORT(
         CLK : IN  std_logic;
         SYNC_RESET : IN  std_logic;
         DATA_OUT : OUT  std_logic_vector(7 downto 0);
         SAMPLE_CLK_OUT : OUT  std_logic;
         SOF_OUT : OUT  std_logic;
         SAMPLE_CLK_OUT_REQ : IN  std_logic
        );
    END COMPONENT;
    

   --Inputs
   signal CLK : std_logic := '0';
   signal SYNC_RESET : std_logic := '0';
   signal SAMPLE_CLK_OUT_REQ : std_logic := '1';

 	--Outputs
   signal DATA_OUT : std_logic_vector(7 downto 0);
   signal SAMPLE_CLK_OUT : std_logic;
   signal SOF_OUT : std_logic;
	signal CLK_CNTR: unsigned(4 downto 0) := "00000";

   -- Clock period definitions
   constant CLK_period : time := 10 ns;
 
BEGIN
 
	-- Instantiate the Unit Under Test (UUT)
   uut: LFSR11P PORT MAP (
          CLK => CLK,
          SYNC_RESET => SYNC_RESET,
          DATA_OUT => DATA_OUT,
          SAMPLE_CLK_OUT => SAMPLE_CLK_OUT,
          SOF_OUT => SOF_OUT,
          SAMPLE_CLK_OUT_REQ => SAMPLE_CLK_OUT_REQ
        );

   -- Clock process definitions
   CLK_process :process
   begin
		CLK <= '0';
		wait for CLK_period/2;
		CLK <= '1';
		wait for CLK_period/2;
   end process;
 

	CLK_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			CLK_CNTR <= CLK_CNTR + 1;
			if(CLK_CNTR = 0) then
				SAMPLE_CLK_OUT_REQ <= '1';
			else
				SAMPLE_CLK_OUT_REQ <= '0';
			end if;
		end if;
	end process;

   -- Stimulus process
   stim_proc: process
   begin		
      -- hold reset state for 100 ns.
      wait for 100 ns;	

      wait for CLK_period*10;

      -- insert stimulus here 

      wait;
   end process;

END;
