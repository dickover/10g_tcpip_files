library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library xpm;
use xpm.vcomponents.all;

entity BRAM_DP2 is
	 Generic (
		DATA_WIDTHA: integer := 9;	-- MUST BE <= DATA_WIDTHB
		ADDR_WIDTHA: integer := 11;
		DATA_WIDTHB: integer := 9;	
		ADDR_WIDTHB: integer := 11
		-- total size on A size MUST match total size on B side 
		-- (DATA_WIDTHA * 2**ADDR_WIDTHA) == (DATA_WIDTHB * 2**ADDR_WIDTHB)
	);
    Port ( 
			-- chip select, active high
		
	    -- Port A
		CLKA   : in  std_logic;
		CSA: in std_logic;	-- chip select, active high
		WEA    : in  std_logic;	-- write enable, active high
		OEA : in std_logic;	-- output enable, active high
		ADDRA  : in  std_logic_vector(ADDR_WIDTHA-1 downto 0);
		DIA   : in  std_logic_vector(DATA_WIDTHA-1 downto 0);
		DOA  : out std_logic_vector(DATA_WIDTHA-1 downto 0);

		-- Port B
		CLKB   : in  std_logic;
		CSB: in std_logic;	-- chip select, active high
		WEB    : in  std_logic;	-- write enable, active high
		OEB : in std_logic;	-- output enable, active high
		ADDRB  : in  std_logic_vector(ADDR_WIDTHB-1 downto 0);
		DIB   : in  std_logic_vector(DATA_WIDTHB-1 downto 0);
		DOB  : out std_logic_vector(DATA_WIDTHB-1 downto 0)
		);
end entity;

architecture synthesis of BRAM_DP2 is
begin

xpm_memory_tdpram_inst: xpm_memory_tdpram
  generic map (
    MEMORY_SIZE             => (2**ADDR_WIDTHA)*DATA_WIDTHA,
    MEMORY_PRIMITIVE        => "block",
    CLOCKING_MODE           => "independent_clock", 
    MEMORY_INIT_FILE        => "none", 
    MEMORY_INIT_PARAM       => "",
    USE_MEM_INIT            => 0,
    WAKEUP_TIME             => "disable_sleep", 
    MESSAGE_CONTROL         => 0,
    ECC_MODE                => "no_ecc", 
    AUTO_SLEEP_TIME         => 0,
    USE_EMBEDDED_CONSTRAINT => 0,
    MEMORY_OPTIMIZATION     => "true",
    WRITE_DATA_WIDTH_A      => DATA_WIDTHA,
    READ_DATA_WIDTH_A       => DATA_WIDTHA,
    BYTE_WRITE_WIDTH_A      => DATA_WIDTHA,
    ADDR_WIDTH_A            => ADDR_WIDTHA,
    READ_RESET_VALUE_A      => "0",
    READ_LATENCY_A          => 1,
    WRITE_MODE_A            => "write_first",
    WRITE_DATA_WIDTH_B      => DATA_WIDTHB,
    READ_DATA_WIDTH_B       => DATA_WIDTHB,
    BYTE_WRITE_WIDTH_B      => DATA_WIDTHB,
    ADDR_WIDTH_B            => ADDR_WIDTHB,
    READ_RESET_VALUE_B      => "0",
    READ_LATENCY_B          => 1,
    WRITE_MODE_B            => "write_first" 
  )
  port map(
    sleep                   => '0',
    clka                    => CLKA,
    rsta                    => '0',
    ena                     => CSA,
    regcea                  => '1',
    wea                     => (others=>WEA),
    addra                   => ADDRA,
    dina                    => DIA,
    injectsbiterra          => '0',
    injectdbiterra          => '0',
    douta                   => DOA,
    sbiterra                => open,
    dbiterra                => open,
    clkb                    => CLKB,
    rstb                    => '0',
    enb                     => CSB,
    regceb                  => '1',
    web                     => (others=>WEB),
    addrb                   => ADDRB,
    dinb                    => DIB,
    injectsbiterrb          => '0',
    injectdbiterrb          => '0',
    doutb                   => DOB,
    sbiterrb                => open,
    dbiterrb                => open
  );

end synthesis;
