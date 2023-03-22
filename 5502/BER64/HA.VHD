----------------------------------------------
-- MSS copyright 1999-2000
-- VHDL code for 12bit x 9bit = 10-bit multiplier, synchronous
-- Applicability: Xilinx Spartan FPGA family
-- Primary project: Sirius Satellite Radio
-- Author: Alain Zarembowitch / MSS
-- Edit date: 7-14-00
-- Revision: 0.024 (QPSK)
-- 
-----------------------------------------------------------------
-- HALF ADDER
-----------------------------------------------------------------
Library ieee;
Use ieee.std_logic_1164.all;

entity HA is
	port (
		A: in std_logic;	-- input A
		B: in std_logic;	-- input B
		O: out std_logic;	-- added value
		CO: out std_logic	-- carry out
	);
end HA;

architecture BEHAVIOR_HA of HA is
begin
	O <= A XOR B;
	CO <= A AND B;
end BEHAVIOR_HA;
		
