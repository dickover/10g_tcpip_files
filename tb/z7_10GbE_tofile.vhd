library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library utils;
use utils.utils_pkg.all;

library per_lib;
use per_lib.perbus_pkg.all;
use work.pcspma_shared_pkg.all;

library com5502_lib;
use com5502_lib.com5502pkg.all;

use work.z7clk_per_pkg.all;
use work.z7_10GbE_tcpip_per_pkg.all;

entity z7_10GbE_tofile is
  generic(
    ENABLE_PORT0    : boolean := false;
    MAC0            : std_logic_vector(47 downto 0) := x"000102030405";
    IP0             : std_logic_vector(31 downto 0) := x"00000000";
    MASK0           : std_logic_vector(31 downto 0) := x"FFFFFF00";
    TCP_DESTIP0     : std_logic_vector(31 downto 0) := x"00000000";
    TCP_PORTS0      : std_logic_vector(31 downto 0) := x"00000000";
    TCP_FILENAME0   : string := "none";
    TCP_SERVER0     : boolean := false;
    UDP_PORTS0      : std_logic_vector(31 downto 0) := x"00000000";
    UDPRX_FILENAME0 : string := "none";
    ENABLE_PORT1    : boolean := false;
    MAC1            : std_logic_vector(47 downto 0) := x"000102030405";
    IP1             : std_logic_vector(31 downto 0) := x"00000000";
    MASK1           : std_logic_vector(31 downto 0) := x"FFFFFF00";
    TCP_DESTIP1     : std_logic_vector(31 downto 0) := x"00000000";
    TCP_PORTS1      : std_logic_vector(31 downto 0) := x"00000000";
    TCP_FILENAME1   : string := "none";
    TCP_SERVER1     : boolean := false;
    UDP_PORTS1      : std_logic_vector(31 downto 0) := x"00000000";
    UDPRX_FILENAME1 : string := "none"
  );
  port(
    ETH_TX0   : out std_logic;
    ETH_RX0   : in  std_logic;
    ETH_TX1   : out std_logic;
    ETH_RX1   : in  std_logic
  );
end z7_10GbE_tofile;

architecture testbench of z7_10GbE_tofile is
  impure function get_tcp_server(INST : integer) return boolean is
    variable result : boolean;
  begin
    case INST is
      when 0 => result := TCP_SERVER0;
      when 1 => result := TCP_SERVER1;
--      when 2 => result := TCP_SERVER2;
--      when 3 => result := TCP_SERVER3;
      when others => result := false;
    end case;
    return result;
  end get_tcp_server;
  
  signal CLK_156_25               : std_logic;
  signal PCS_PMA_SHARED           : PCS_PMA_SHARED_TYPE;
  signal TXOUTCLK                 : std_logic;
  signal BUS_CLK                  : std_logic;
  signal BUS_WR                   : BUS_FIFO_WR := BUS_FIFO_WR_INIT;
  signal BUS_RD                   : BUS_FIFO_RD := BUS_FIFO_RD_INIT;
  signal BUS_WR_ARRAY             : BUS_FIFO_WR_ARRAY(0 to 3) := (others=>BUS_FIFO_WR_INIT);
  signal BUS_RD_ARRAY             : BUS_FIFO_RD_ARRAY(0 to 3) := (others=>BUS_FIFO_RD_INIT);
  signal GCLK_P                   : std_logic;
  signal GCLK_N                   : std_logic;
  signal CLK_40GBE_P              : std_logic;
  signal CLK_40GBE_N              : std_logic;
  
  -- Client signals
  signal TCP_RX_DATA              : slv64a(0 to 1) := (others=>x"0000_0000_0000_0000");
  signal TCP_RX_DATA_VALID        : slv8a(0 to 1) := (others=>x"00");
  signal TCP_RX_RTS               : std_logic_vector(0 to 1) := (others=>'0');
  signal TCP_RX_CTS               : std_logic_vector(0 to 1) := (others=>'1');
  signal TCP_RX_CTS_ACK           : std_logic_vector(0 to 1) := (others=>'0');
  signal TXP                      : std_logic_vector(0 to 1) := (others=>'1');
  signal TXN                      : std_logic_vector(0 to 1) := (others=>'0');
  signal RXP                      : std_logic_vector(0 to 1) := (others=>'1');
  signal RXN                      : std_logic_vector(0 to 1) := (others=>'0');

  signal UDP_RX_DATA              : slv64a(0 to 1);
  signal UDP_RX_DATA_VALID        : slv8a(0 to 1);
  signal UDP_RX_SOF               : std_logic_vector(0 to 1);
  signal UDP_RX_EOF               : std_logic_vector(0 to 1);
  signal UDP_RX_FRAME_VALID       : slv8a(0 to 1);
begin

  RXP(0)  <=     ETH_RX0;
  RXN(0)  <= not ETH_RX0;
  ETH_TX0 <= TXP(0);

  RXP(1)  <=     ETH_RX1;
  RXN(1)  <= not ETH_RX1;
  ETH_TX1 <= TXP(1);

  process
  begin
    wait for 1 us;
    --         CLK     WR     RD     ADDR        DATA
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000100",x"00000003");
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000100",x"00000000");
    wait for 1 us;
    
    --Setup z7_10GbE_tcpip_per
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000210",IP0);    --IP4_ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000218",MASK0);  --IP4_SUBNETMASK
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000238",x"0000" & MAC0(47 downto 32)); --MAC ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000234",MAC0(31 downto 0));  --MAC ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000268",UDP_PORTS0);
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000280",TCP_DESTIP0);
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"000002A0",TCP_PORTS0);
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000200",x"000003C5");  --Signal detect, PMA_PMD_TYPE 111, RESET
    
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000310",IP1);    --IP4_ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000318",MASK1);  --IP4_SUBNETMASK
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000338",x"0000" & MAC1(47 downto 32)); --MAC ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000334",MAC1(31 downto 0));  --MAC ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000368",UDP_PORTS1);
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000380",TCP_DESTIP1);
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"000003A0",TCP_PORTS1);
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000003C5");  --Signal detect, PMA_PMD_TYPE 111, RESET

    wait for 400 ns;
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000200",x"000003C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000003C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET

    wait for 32 us;

    if TCP_SERVER0 = false then
      report "[0] Connect to server" severity note;
      pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000220",x"00000001");  --Command client to connect to server
      report "[0] Connect to server...done" severity note;
    end if;

    if TCP_SERVER1 = false then
      report "[1] Connect to server" severity note;
      pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000320",x"00000001");  --Command client to connect to server
      report "[1] Connect to server...done" severity note;
    end if;

    wait;
  end process;

  process
  begin
    BUS_CLK <= '0';
    wait for 10 ns;
    BUS_CLK <= '1';
    wait for 10 ns;
  end process;

  process
  begin
    GCLK_P <= '1';
    GCLK_N <= '1';
    wait for 2 ns;
    GCLK_P <= '0';
    GCLK_N <= '0';
    wait for 2 ns;
  end process;

  process
  begin
    CLK_40GBE_P <= '1';
    CLK_40GBE_N <= '1';
    wait for 3.2 ns;
    CLK_40GBE_P <= '0';
    CLK_40GBE_N <= '0';
    wait for 3.2 ns;
  end process;

  BUS_WR_ARRAY <= (others=>BUS_WR);
  BUS_RD <= fbus_rd_reduce(BUS_RD_ARRAY);

  z7clk_per_inst: z7clk_per
    generic map(
      ADDR_INFO       => (x"00000100", x"0000FF00",x"000000FF"),
      FIRMWARE_TYPE   => x"00000001",
      VERSION_MAJOR   => 1,
      VERSION_MINOR   => 0,
      GCLK_PERIOD_PS  => 4000,
      SIMULATION      => '1'
    )
    port map(
      FCLK_200M       => '0',
      GCLK_P          => GCLK_P,
      GCLK_N          => GCLK_N,
      CLK_40GBE_P     => CLK_40GBE_P,
      CLK_40GBE_N     => CLK_40GBE_N,
      PCS_PMA_SHARED  => PCS_PMA_SHARED,
      TXOUTCLK        => TXOUTCLK,
      CLK_156_25      => CLK_156_25,
      BUS_CLK         => BUS_CLK,
      BUS_WR          => BUS_WR_ARRAY(1),
      BUS_RD          => BUS_RD_ARRAY(1)
    );

  z7_10GbE_tcpip_per_gen: for I in 0 to 1 generate
    z7_10GbE_tcpip_per_inst: z7_10GbE_tcpip_per
      generic map(
        ADDR_INFO             => (std_logic_vector(unsigned(x"00000200")+to_unsigned(I,2)*unsigned(x"0100")), x"0000FF00",x"000000FF"),
        SIMULATION            => '1',
        TCP_TX_WINDOW_SIZE    => 12,
        TCP_RX_WINDOW_SIZE    => 12,
        UDP_TX_EN             => false,
        UDP_RX_EN             => true,
        TX_IDLE_TIMEOUT       => 50,
        TCP_KEEPALIVE_PERIOD  => 60,
        SERVER                => get_tcp_server(I),
        TXPOLARITY            => '0',
        RXPOLARITY            => '0'
      )
      port map(
        CLK_156_25            => CLK_156_25,
        MTU_OUT               => open,
        TCP_TX_DATA           => (others=>'0'),
        TCP_TX_DATA_VALID     => (others=>'0'),
        TCP_TX_DATA_FLUSH     => '0',
        TCP_TX_CTS            => open,
        TCP_RX_DATA           => TCP_RX_DATA(I),
        TCP_RX_DATA_VALID     => TCP_RX_DATA_VALID(I),
        TCP_RX_RTS            => TCP_RX_RTS(I),
        TCP_RX_CTS            => TCP_RX_CTS(I),
        TCP_RX_CTS_ACK        => open,
        UDP_TX_DATA           => (others=>'0'),
        UDP_TX_DATA_VALID     => (others=>'0'),
        UDP_TX_SOF            => '0',
        UDP_TX_EOF            => '0',
        UDP_TX_CTS            => open,
        UDP_TX_ACK            => open,
        UDP_TX_NAK            => open,
        UDP_RX_DATA           => UDP_RX_DATA(I),
        UDP_RX_DATA_VALID     => UDP_RX_DATA_VALID(I),
        UDP_RX_SOF            => UDP_RX_SOF(I),
        UDP_RX_EOF            => UDP_RX_EOF(I),
        PCS_PMA_SHARED        => PCS_PMA_SHARED,
        TXOUTCLK              => TXOUTCLK,
        TXP                   => TXP(I),
        TXN                   => TXN(I),
        RXP                   => RXP(I),
        RXN                   => RXN(I),
        FIBER_CTRL_INTL       => '0',
        FIBER_CTRL_LINKSTATUS => open,
        FIBER_CTRL_MODSELL    => open,
        FIBER_CTRL_RESETL     => open,
        FIBER_CTRL_MODPRSL    => '0',
        FIBER_CTRL_LPMODE     => open,
        BUS_CLK               => BUS_CLK,
        BUS_WR                => BUS_WR_ARRAY(2+I),
        BUS_RD                => BUS_RD_ARRAY(2+I)
      );
  end generate;

  --TCP file dump
  tcp_writer_gen: for I in 0 to 1 generate
  begin
    process
      function get_filename(inst : integer) return string is
      begin
        case inst is
          when 0      => return "streaming_data_tcp0.bin";
          when 1      => return "streaming_data_tcp1.bin";
          when 2      => return "streaming_data_tcp2.bin";
          when others => return "streaming_data_tcp3.bin";
        end case;
      end get_filename;
      
      type file_integer is file of integer;
      file roc_event_data : file_integer;
      variable val        : std_logic_vector(31 downto 0);
      variable pos        : integer := 0;
    begin
      TCP_RX_CTS(I) <= '0';
      file_open(roc_event_data, get_filename(I), write_mode);
      wait for 1 us;
      TCP_RX_CTS(I) <= '1';
      
      while true loop
        wait until falling_edge(CLK_156_25);
        for J in 7 downto 0 loop
          if TCP_RX_DATA_VALID(I)(J) = '1' then
            val(8*pos+7 downto 8*pos) := TCP_RX_DATA(I)(8*J+7 downto 8*J);
            pos := pos + 1;
            if pos = 4 then
              pos := to_integer(signed(val));
              write(roc_event_data, pos);
              pos := 0;
            end if;
          end if;
        end loop;
      end loop;    
    end process;
  end generate;
  
  --UDP file dump
  udp_writer_gen: for I in 0 to 1 generate
  begin
    process
      function get_filename(inst : integer) return string is
      begin
        case inst is
          when 0      => return "streaming_data_udp0.bin";
          when 1      => return "streaming_data_udp1.bin";
          when 2      => return "streaming_data_udp2.bin";
          when others => return "streaming_data_udp3.bin";
        end case;
      end get_filename;
      
      type file_integer is file of integer;
      file roc_event_data : file_integer;
      variable val        : std_logic_vector(31 downto 0);
      variable pos        : integer := 0;
    begin
      file_open(roc_event_data, get_filename(I), write_mode);
      wait for 1 us;
      
      while true loop
        wait until falling_edge(CLK_156_25);
        for J in 7 downto 0 loop
          if UDP_RX_DATA_VALID(I)(J) = '1' then
            val(8*pos+7 downto 8*pos) := UDP_RX_DATA(I)(8*J+7 downto 8*J);
            pos := pos + 1;
            if pos = 4 then
              pos := to_integer(signed(val));
              write(roc_event_data, pos);
              pos := 0;
            end if;
          end if;
        end loop;
      end loop;    
    end process;
  end generate;

end testbench;
