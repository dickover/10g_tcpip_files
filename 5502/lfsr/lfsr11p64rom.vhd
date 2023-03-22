-------------------------------------------------------------
-- Filename:  LFSR11P64ROM.VHD
-- Authors: 
-- 	from http://www.xilinx.com/support/documentation/sw_manuals/xilinx14_4/xst_v6s6.pdf  p262
--		Alain Zarembowitch / MSS
-- Version: Rev 0
-- Last modified: 1/9/21

-- Inheritance: 	ROM1.VHD, LFSR11PROM.VHD 8/24/16
--
-- description:  synthesizable generic dual port ROM. Customized for LFSR11P.
-- Warning: convoluted pointers to alleviate re-writing the ROM contents transferred from a Xilinx block ram.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity LFSR11P64ROM is
	 Generic (
		DATA_WIDTH: integer := 64;	
		ADDR_WIDTH: integer := 5
	);
    Port ( 
		CLK   : in  std_logic;

	    -- Port A
		ADDRA  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
		DOA  : out std_logic_vector(DATA_WIDTH-1 downto 0);
			-- Stores 8 contiguous PRBS-11 sequence in DATA_OUT(7:0). Period is 8*2047 bits.	
			-- SOF is placed in DATA_OUT(8)

		-- Port B 
		ADDRB  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
		DOB  : out std_logic_vector(DATA_WIDTH-1 downto 0)
		);
end entity;

architecture Behavioral of LFSR11P64ROM is
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- inferred rom
signal DOA_local: std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
signal DOB_local: std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
type ROM_TYPE is array ( (2**(ADDR_WIDTH))-1 downto 0 ) of std_logic_vector(63 downto 0);
constant ROM : ROM_TYPE := (
      x"3F01CE7CF8F31F00",
      x"82C970180CD3B447",
      x"2E8334476B74B90E",
      x"3BA0CC2D85C4380D",
      x"72B6164236E971E5",
      x"0BDF54B8F3B5BA08",
      x"9858F2B64237419B",
      x"114F7EFC53B5BBA0",
      x"4CD2B617EADC0795",
      x"3AA33412B6E92590",
      x"4E7D046C8696BD05",
      x"EE7D05C46C7859F1",
      x"469643CA76E873B5",
      x"A3CADDFAA2623714",
      x"CF80676A898E7DFA",
      x"15111B0B8B21CF81",
      x"E56FD5BB5FFFFE57",
      x"2B75BB5E5714B9F1",
      x"D413B5111AA361CF",
      x"FD504D8493B5456F",
      x"2B21CE29256E839E",
      x"F714B8590F81314F",
      x"B24827C131E5911A",
      x"76E9DB5F0099F1B0",
      x"4924390ED6BC076A",
      x"D5104D2E298E7C52",
      x"C19B5FAA23CA898F",
      x"CE839F55BAA36067",
      x"29DA09253B5E0361",
      x"00CD84C7C0321DAE",
      x"F5BB0A2263CB8BDF",
      x"66961617EB74ED7B"
);

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin
-- Port A read
process(CLK, ADDRA)
variable ROWA: integer range 0 to (2**(ADDR_WIDTH))-1 := 0;
begin
	ROWA := to_integer(unsigned(not ADDRA));	--reading from top to bottom

	if rising_edge(CLK) then
		DOA <= ROM(ROWA);
	end if;
end process;

-- Port B read
process(CLK, ADDRB)
variable ROWB: integer range 0 to (2**(ADDR_WIDTH))-1 := 0;
begin
	ROWB := to_integer(unsigned(not ADDRB));	-- 32 bytes per row, reading from top to bottom


	if rising_edge(CLK) then
		DOB <= ROM(ROWB);
	end if;
end process;

end Behavioral;
