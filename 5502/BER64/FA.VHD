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
-- FULL ADDER
-----------------------------------------------------------------
Library ieee;
Use ieee.std_logic_1164.all;

entity FA is
	port (
		A: in std_logic;	-- input A
		B: in std_logic;	-- input B
		CI: in std_logic;	-- carry in
		O: out std_logic;	-- added value
		CO: out std_logic	-- carry out
	);
end FA;

architecture BEHAVIOR_FA of FA is
begin
	O <= A xor B xor CI;
	CO <= ((A or B) and CI) or (A and B);
end BEHAVIOR_FA;