library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library per_lib;
use per_lib.perbus_pkg.all;

entity z7_vmesim_bridge is
  generic(
    BUS_IF_NUM        : integer := 1
  );
  port(
    BUS_ADDR          : in std_logic_vector(31 downto 16);
    SYSBUS_ADDR       : in std_logic_vector(31 downto 16);
    
    VMEBUS_DS_N       : in std_logic_vector(1 downto 0);
    VMEBUS_AS_N       : in std_logic;
    VMEBUS_W_N        : in std_logic;
    VMEBUS_AM         : in std_logic_vector(5 downto 0);
    VMEBUS_D          : inout std_logic_vector(31 downto 0);
    VMEBUS_A          : inout std_logic_vector(31 downto 0);
    VMEBUS_BERR_N     : inout std_logic;
    VMEBUS_DTACK_N    : inout std_logic;
    
    -- Z7 bus
    BUS_CLK           : out std_logic;
    BUS_WR_ARRAY      : out BUS_FIFO_WR_ARRAY(BUS_IF_NUM-1 downto 0);
    BUS_RD_ARRAY      : in BUS_FIFO_RD_ARRAY(BUS_IF_NUM-1 downto 0);
      
    -- V7 bus
    SYSBUS_ACK        : in std_logic;
    SYSBUS_AD         : inout std_logic_vector(31 downto 0);
    SYSBUS_AUX        : inout std_logic_vector(5 downto 0);
    SYSBUS_CLK        : out std_logic;
    SYSBUS_CSI_B      : out std_logic;
    SYSBUS_RD         : out std_logic;
    SYSBUS_RDWR_B     : out std_logic;
    SYSBUS_RESET      : out std_logic;
    SYSBUS_RESET_SOFT : out std_logic;
    SYSBUS_WR         : out std_logic
  );
end z7_vmesim_bridge;

architecture behavioral of z7_vmesim_bridge is
  signal BUS_WR         : BUS_FIFO_WR := BUS_FIFO_WR_INIT;
  signal BUS_RD         : BUS_FIFO_RD := BUS_FIFO_RD_INIT;
begin

  BUS_RD <= fbus_rd_reduce(BUS_RD_ARRAY);
  BUS_WR_ARRAY <= (others=>BUS_WR);

  process
    procedure WriteReg(
        addr : in std_logic_vector(15 downto 0);
        data : in std_logic_vector(31 downto 0)
      ) is
    begin
      wait until falling_edge(SYSBUS_CLK);
      SYSBUS_WR <= '1';
      SYSBUS_AD <= x"0000" & addr;
      wait until falling_edge(SYSBUS_CLK);
      SYSBUS_WR <= '0';
      SYSBUS_AD <= data;
      wait until falling_edge(SYSBUS_CLK);
      SYSBUS_WR <= '0';
      SYSBUS_AD <= (others=>'Z');
      for I in 0 to 99 loop
        if SYSBUS_ACK = '1' then
          exit;
        end if;
        wait until falling_edge(SYSBUS_CLK);
      end loop;
    end WriteReg;

    procedure ReadReg(
        addr : in std_logic_vector(15 downto 0);
        signal data : out std_logic_vector(31 downto 0)
      ) is
    begin
      wait until falling_edge(SYSBUS_CLK);
      SYSBUS_RD <= '1';
      SYSBUS_AD <= x"0000" & addr;
      wait until falling_edge(SYSBUS_CLK);
      SYSBUS_RD <= '0';
      SYSBUS_AD <= (others=>'Z');

      for I in 0 to 99 loop
        if SYSBUS_ACK = '1' then
          data <= SYSBUS_AD;
          exit;
        end if;
        wait until falling_edge(SYSBUS_CLK);
      end loop;
    end ReadReg;
    
    variable val  : std_logic_vector(31 downto 0);
  begin
    BUS_WR.RESET <= '1';
    BUS_WR.RESET_SOFT <= '0';
    SYSBUS_RESET <= '1';
    SYSBUS_AD <= (others=>'Z');
    SYSBUS_WR <= '0';
    SYSBUS_RD <= '0';
    --SYSBUS_ACK
    SYSBUS_AUX <= (others=>'Z');
    SYSBUS_CSI_B <= '1';
    SYSBUS_RDWR_B <= '1';

    VMEBUS_D <= (others=>'H');
    VMEBUS_A <= (others=>'H');
    VMEBUS_BERR_N <= 'H';
    VMEBUS_DTACK_N <= 'H';

    wait for 200 ns;
    SYSBUS_RESET <= '0';
    BUS_WR.RESET <= '0';
    wait for 200 ns;

    while true loop
      wait until falling_edge(VMEBUS_AS_N);

      if VMEBUS_A(31 downto 16) = SYSBUS_ADDR then
        if VMEBUS_W_N = '1' then
          ReadReg(VMEBUS_A(15 downto 0), VMEBUS_D);
        else
          WriteReg(VMEBUS_A(15 downto 0), VMEBUS_D);
        end if;
        VMEBUS_DTACK_N <= '0';
      elsif VMEBUS_A(31 downto 16) = BUS_ADDR then
        if VMEBUS_W_N = '1' then
          pbus_read(BUS_CLK, BUS_WR, BUS_RD, x"0000" & VMEBUS_A(15 downto 0), val);
          VMEBUS_D <= val;
        else
          pbus_write(BUS_CLK, BUS_WR, BUS_RD, x"0000" & VMEBUS_A(15 downto 0), VMEBUS_D);
        end if;
        VMEBUS_DTACK_N <= '0';
      end if;

      wait until to_X01(VMEBUS_AS_N) = '1';
      VMEBUS_D <= (others=>'H');
      VMEBUS_DTACK_N <= 'H';
    end loop;

  end process;

  process
  begin
    SYSBUS_RESET_SOFT <= '1';
    wait for 10 us;
    SYSBUS_RESET_SOFT <= '0';
    wait;
  end process;

  process
  begin
    SYSBUS_CLK <= '0';
    BUS_CLK <= '0';
    wait for 15.001 ns;
    SYSBUS_CLK <= '1';
    BUS_CLK <= '1';
    wait for 15.001 ns;
  end process;

end behavioral;
