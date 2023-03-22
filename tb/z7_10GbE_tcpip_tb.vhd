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

use work.z7_tcpip_testtx_per_pkg.all;
use work.z7clk_per_pkg.all;
use work.z7_10GbE_tcpip_per_pkg.all;

entity z7_10GbE_tcpip_tb is
end z7_10GbE_tcpip_tb;

architecture testbench of z7_10GbE_tcpip_tb is

  function char_to_4bit(cin : character) return std_logic_vector is
    variable result : std_logic_vector(3 downto 0) := "0000";
  begin
    case cin is
      when '0' => result := "0000";
      when '1' => result := "0001";
      when '2' => result := "0010";
      when '3' => result := "0011";
      when '4' => result := "0100";
      when '5' => result := "0101";
      when '6' => result := "0110";
      when '7' => result := "0111";
      when '8' => result := "1000";
      when '9' => result := "1001";
      when 'a' => result := "1010";
      when 'b' => result := "1011";
      when 'c' => result := "1100";
      when 'd' => result := "1101";
      when 'e' => result := "1110";
      when 'f' => result := "1111";
      when others => result := "XXXX";
    end case;
    return result;
  end char_to_4bit;

  constant NTCPSTREAMS            : integer := 1;
--  constant UDP_TEST_FRAME         : string(1 to 1440*2) := 
----    ("00010fa4000700036e009fff6e013fff6e01bfff6ff41fff6ff49fff6ff53fff6ff5bfff71e81fff71e89fff71e93fff71e9bfff73dc1fff73dc9fff73dd3fff73ddbfff75d01fff75d09fff75d13fff75d1bfff77c41fff77c49fff77c53fff77c5bfff79b81fff79b89fff79b93fff79b9bfff7bac1fff7bac9fff7bad3fff7badbfff7da01fff7da09fff7da13fff7da1bfff7f941fff7f949fff7f953fff7f95bfff0000010900070f0000a05fff00a0bfff00a15fff00a1dfff02945fff0294bfff02955fff0295dfff04885fff0488bfff04895fff0489dfff067c5fff067cbfff067d5fff067ddfff08705fff0870bfff08715fff0871dfff0a645fff0a64bfff0a655fff0a65dfff0c585fff0c58bfff0c595fff0c59dfff0e4c5fff0e4cbfff0e4d5fff0e4ddfff10405fff1040bfff10415fff1041dfff12345fff1234bfff12355fff1235dfff14285fff1428bfff14295fff1429dfff161c5fff161cbfff161d5fff161ddfff18105fff1810bfff18115fff1811dfff1a045fff1a04bfff1a055fff1a05dfff1bf85fff1bf8bfff1bf95fff1bf9dfff1dec5fff1decbfff1ded5fff1deddfff1fe05fff1fe0bfff1fe15fff1fe1dfff21d45fff21d4bfff21d55fff21d5dfff23c85fff23c8bfff23c95fff23c9dfff25bc5fff25bcbfff25bd5fff25bddfff27b05fff27b0bfff27b15fff27b1dfff29a45fff29a4bfff29a55fff29a5dfff2b985fff2b98bfff2b995fff2b99dfff2d8c5fff2d8cbfff2d8d5fff2d8ddfff2f805fff2f80bfff2f815fff2f81dfff31745fff3174bfff31755fff3175dfff33685fff3368bfff33695fff3369dfff355c5fff355cbfff355d5fff355ddfff37505fff3750bfff37515fff3751dfff39445fff3944bfff39455fff3945dfff3b385fff3b38bfff3b395fff3b39dfff3d2c5fff3d2cbfff3d2d5fff3d2ddfff3f205fff3f20bfff3f215fff3f21dfff41145fff4114bfff41155fff4115dfff43085fff4308bfff43095fff4309dfff44fc5fff44fcbfff44fd5fff44fddfff46f05fff46f0bfff46f15fff46f1dfff48e45fff48e4bfff48e55fff48e5dfff4ad85fff4ad8bfff4ad95fff4ad9dfff4ccc5fff4cccbfff4ccd5fff4ccddfff4ec05fff4ec0bfff4ec15fff4ec1dfff50b45fff50b4bfff50b55fff50b5dfff52a85fff52a8bfff52a95fff52a9dfff549c5fff549cbfff549d5fff549ddfff56905fff5690bfff56915fff5691dfff58845fff5884bfff58855fff5885dfff5a785fff5a78bfff5a795fff5a79dfff5c6c5fff5c6cbfff5c6d5fff5c6ddfff5e605fff5e60bfff5e615fff5e61dfff60545fff6054bfff60555fff6055dfff62485fff6248bfff62495fff6249dfff643c5fff643cbfff643d5fff643ddfff66305fff6630bfff66315fff6631dfff68245fff6824bfff68255fff6825dfff6a185fff6a18bfff6a195fff6a19dfff6c0c5fff6c0cbfff6c0d5fff6c0ddfff6e005fff6e00bfff6e015fff6e01dfff6ff45fff6ff4bfff6ff55fff6ff5dfff71e85fff71e8bfff71e95fff71e9dfff73dc5fff73dcbfff73dd5fff73dddfff75d05fff75d0bfff75d15fff75d1dfff77c45fff77c4bfff77c55fff77c5dfff79b85fff79b8bfff79b95fff79b9dfff7bac5fff7bacbfff7bad5fff7baddfff7da05fff7da0bfff7da15fff7da1dfff7f945fff7f94bfff7f955fff7f95dfff0000014b000a0f0000a41fff00a23fff00a27fff00a4dfff00a5dfff02981fff02963fff02967fff0298dfff0299dfff048c1fff048a3fff048a7fff048cdfff048ddfff067e3fff067e7fff06801fff0680dfff0681dfff08741fff08723fff08727fff0874dfff0875dfff0a661fff0a663fff0a667fff0a68dfff0a69dfff0c5a1fff0c5a3fff0c5a7fff0c5cdfff0c5ddfff0e4e1fff0e4e3fff0e4e7fff0e50dfff0e51dfff10421fff10423fff10427fff1044dfff1045dfff12361fff12363fff12367fff1238dfff1239dfff142a1fff");
--    ("0001472400060001000000010000211400000845010843720000000800000001000000010000220400000000c0da01000000083c000110010000000aff30200131010003010843714371000000000108410500040084018201870185018c008a008f008d000000c400020f0001189fff01193fff01199fff030c9fff030d3fff030d9fff05009fff05013fff05019fff06f49fff06f53fff06f59fff08e89fff08e93fff08e99fff0adc9fff0add3fff0add9fff0cd09fff0cd13fff0cd19fff0ec49fff0ec53fff0ec59fff10b89fff10b93fff10b99fff12ac9fff12ad3fff12ad9fff14a09fff14a13fff14a19fff16949fff16953fff16959fff18889fff18893fff18899fff1a7c9fff1a7d3fff1a7d9fff1c709fff1c713fff1c719fff1e649fff1e653fff1e659fff20589fff20593fff20599fff224c9fff224d3fff224d9fff24409fff24413fff24419fff26349fff26353fff26359fff28289fff28293fff28299fff2a1c9fff2a1d3fff2a1d9fff2c109fff2c113fff2c119fff2e049fff2e053fff2e059fff2ff89fff2ff93fff2ff99fff31ec9fff31ed3fff31ed9fff33e09fff33e13fff33e19fff35d49fff35d53fff35d59fff37c89fff37c93fff37c99fff39bc9fff39bd3fff39bd9fff3bb09fff3bb13fff3bb19fff3da49fff3da53fff3da59fff3f989fff3f993fff3f999fff418c9fff418d3fff418d9fff43809fff43813fff43819fff45749fff45753fff45759fff47689fff47693fff47699fff495c9fff495d3fff495d9fff4b509fff4b513fff4b519fff4d449fff4d453fff4d459fff4f389fff4f393fff4f399fff512c9fff512d3fff512d9fff53209fff53213fff53219fff55149fff55153fff55159fff57089fff57093fff57099fff58fc9fff58fd3fff58fd9fff5af09fff5af13fff5af19fff5ce49fff5ce53fff5ce59fff5ed89fff5ed93fff5ed99fff60cc9fff60cd3fff60cd9fff62c09fff62c13fff62c19fff64b49fff64b53fff64b59fff66a89fff66a93fff66a99fff689c9fff689d3fff689d9fff6a909fff6a913fff6a919fff6c849fff6c853fff6c859fff6e789fff6e793fff6e799fff706c9fff706d3fff706d9fff72609fff72613fff72619fff74549fff74553fff74559fff76489fff76493fff76499fff783c9fff783d3fff783d9fff7a309fff7a313fff7a319fff7c249fff7c253fff7c259fff7e189fff7e193fff7e199fff0000010500040f000118bfff0118dfff01193fff0119bfff030cbfff030cdfff030d3fff030dbfff0500bfff0500dfff05013fff0501bfff06f4bfff06f4dfff06f53fff06f5bfff08e8bfff08e8dfff08e93fff08e9bfff0adcbfff0adcdfff0add3fff0addbfff0cd0bfff0cd0dfff0cd13fff0cd1bfff0ec4bfff0ec4dfff0ec53fff0ec5bfff10b8bfff10b8dfff10b93fff10b9bfff12acbfff12acdfff12ad3fff12adbfff14a0bfff14a0dfff14a13fff14a1bfff1694bfff1694dfff16953fff1695bfff1888bfff1888dfff18893fff1889bfff1a7cbfff1a7cdfff1a7d3fff1a7dbfff1c70bfff1c70dfff1c713fff1c71bfff1e64bfff1e64dfff1e653fff1e65bfff2058bfff2058dfff20593fff2059bfff224cbfff224cdfff224d3fff224dbfff2440bfff2440dfff24413fff2441bfff2634bfff2634dfff26353fff2635bfff2828bfff2828dfff28293fff2829bfff2a1cbfff2a1cdfff2a1d3fff2a1dbfff2c10bfff2c10dfff2c113fff2c11bfff2e04bfff2e04dfff2e053fff2e05bfff2ff8bfff2ff8dfff2ff93fff2ff9bfff31ecbfff31ecdfff31ed3fff31edbfff33e0bfff33e0dfff33e13fff33e1bfff35d4bfff35d4dfff35d53fff35d5bfff37c8bfff37c8dfff37c93fff37c9bfff39bcbfff39bcdfff39bd3fff39bdbfff3bb0bfff3bb0dfff3bb13fff3bb1bfff3da4bfff3da4dfff3da53fff3da5bfff3f98bfff3f98dfff3f993fff3f99bfff418cbfff418cdfff418d3fff418dbfff");


  --constant UDP_TEST_FRAME         : string(1 to 8940*2) := (others=>'0');
  --constant UDP_TEST_FRAME         : string(1 to 7940*2) := (others=>'0');
  constant UDP_TEST_FRAME         : string(1 to 156*2) :=
      ("0003c0340001000100000025000000010000000800000001000000030000220400000000c0da01000000001c000310110000000aff30201131010003000000000000000000000000410500040084008200870085008c008a008f008d000000010002000100000001000400010000000100050001000000010007000100000001000a000100000001000c000100000001000d000100000001000f0001");
  
--  constant TEST_UDP_TX_DATA       : slv76a(0 to 26) :=
  constant TEST_UDP_TX_DATA       : slv76a(0 to 21) :=
      (
        x"000_00000001_00000001",
        x"1FF_0003C034_00010001",
        x"0FF_00000025_00000001",
        x"0FF_00000008_00000001",
        x"0FF_00000003_00002204",
        x"0FF_00000000_c0da0100",
        x"0FF_0000001c_00031011",
        x"0FF_0000000a_ff302011",
        x"0FF_31010003_00000000",
        x"0FF_00000000_00000000",
        x"0FF_41050004_00840082",
        x"0FF_00870085_008c008a",
        x"0FF_008f008d_00000001",
        x"0FF_00040001_00000001",
        x"0FF_00020001_00000001",
        x"0FF_00050001_00000001",
        x"0FF_00070001_00000001",
        x"0FF_000a0001_00000001",
        x"0FF_000c0001_00000001",
--        x"000_000c0001_00000001",
--        x"000_000c0001_00000001",
--        x"000_000c0001_00000001",
        x"0FF_000d0001_00000001",
--        x"000_000d0001_00000001",
--        x"000_000d0001_00000001",
        x"2F0_000f0001_00000001",
        x"000_000f0001_00000001"
      );
  
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
  
  signal CORRUPT_RX_CLIENT        : std_logic := '0';
  signal CORRUPT_RX_SERVER        : std_logic := '0';
  
  -- Server signals
  signal TCP_TX_DATA_SERVER       : std_logic_vector(63 downto 0) := x"00_00_00_00_00_00_00_00";
  signal TCP_TX_DATA_VALID_SERVER : std_logic_vector(7 downto 0) := x"00";
  signal TCP_TX_DATA_FLUSH_SERVER : std_logic := '0';
  signal TCP_TX_CTS_SERVER        : std_logic := '1';
  signal TCP_RX_DATA_SERVER       : std_logic_vector(63 downto 0) := x"00_00_00_00_00_00_00_00";
  signal TCP_RX_DATA_VALID_SERVER : std_logic_vector(7 downto 0) := x"00";
  signal TCP_RX_RTS_SERVER        : std_logic := '0';
  signal TCP_RX_CTS_SERVER        : std_logic := '1';
  signal TCP_RX_CTS_ACK_SERVER    : std_logic := '0';
  signal TXP_SERVER               : std_logic := '1';
  signal TXN_SERVER               : std_logic := '0';
  signal RXP_SERVER               : std_logic := '1';
  signal RXN_SERVER               : std_logic := '0';
  signal UDP_TX_DATA_SERVER       : std_logic_vector(63 downto 0) := (others=>'0');
  signal UDP_TX_DATA_VALID_SERVER : std_logic_vector(7 downto 0) := (others=>'0');
  signal UDP_TX_SOF_SERVER        : std_logic := '0';
  signal UDP_TX_EOF_SERVER        : std_logic := '0';
  signal UDP_TX_CTS_SERVER        : std_logic;
  signal UDP_TX_ACK_SERVER        : std_logic;
  signal UDP_TX_NAK_SERVER        : std_logic;
  signal UDP_RX_DATA_SERVER         : std_logic_vector(63 downto 0);
  signal UDP_RX_DATA_VALID_SERVER   : std_logic_vector(7 downto 0);
  signal UDP_RX_SOF_SERVER          : std_logic;
  signal UDP_RX_EOF_SERVER          : std_logic;
  signal UDP_RX_FRAME_VALID_SERVER  : std_logic;

  -- Client signals
  signal TCP_TX_DATA_CLIENT       : std_logic_vector(63 downto 0) := x"00_00_00_00_00_00_00_00";
  signal TCP_TX_DATA_VALID_CLIENT : std_logic_vector(7 downto 0) := x"00";
  signal TCP_TX_DATA_FLUSH_CLIENT : std_logic := '0';
  signal TCP_TX_CTS_CLIENT        : std_logic := '1';
  signal TCP_RX_DATA_CLIENT       : std_logic_vector(63 downto 0) := x"00_00_00_00_00_00_00_00";
  signal TCP_RX_DATA_VALID_CLIENT : std_logic_vector(7 downto 0) := x"00";
  signal TCP_RX_RTS_CLIENT        : std_logic := '0';
  signal TCP_RX_CTS_CLIENT        : std_logic := '1';
  signal TCP_RX_CTS_ACK_CLIENT    : std_logic := '0';
  signal TXP_CLIENT               : std_logic := '1';
  signal TXN_CLIENT               : std_logic := '0';
  signal RXP_CLIENT               : std_logic := '1';
  signal RXN_CLIENT               : std_logic := '0';
  signal UDP_TX_DATA_CLIENT       : std_logic_vector(63 downto 0) := (others=>'0');
  signal UDP_TX_DATA_VALID_CLIENT : std_logic_vector(7 downto 0) := (others=>'0');
  signal UDP_TX_SOF_CLIENT        : std_logic := '0';
  signal UDP_TX_EOF_CLIENT        : std_logic := '0';
  signal UDP_TX_CTS_CLIENT        : std_logic;
  signal UDP_TX_ACK_CLIENT        : std_logic;
  signal UDP_TX_NAK_CLIENT        : std_logic;
  signal UDP_RX_DATA_CLIENT         : std_logic_vector(63 downto 0);
  signal UDP_RX_DATA_VALID_CLIENT   : std_logic_vector(7 downto 0);
  signal UDP_RX_SOF_CLIENT          : std_logic;
  signal UDP_RX_EOF_CLIENT          : std_logic;
  signal UDP_RX_FRAME_VALID_CLIENT  : std_logic;

begin

  RXP_CLIENT <= transport (TXP_SERVER xor CORRUPT_RX_CLIENT) after 5 us;
  RXN_CLIENT <= transport (TXN_SERVER xor CORRUPT_RX_CLIENT) after 5 us;
  RXP_SERVER <= transport (TXP_CLIENT xor CORRUPT_RX_SERVER) after 5 us;
  RXN_SERVER <= transport (TXN_CLIENT xor CORRUPT_RX_SERVER) after 5 us;

--  process
--    variable s1       : positive := 10;
--    variable s2       : positive := 20;
--    variable r        : real;
--    variable ir       : integer;
--    variable n_errors : integer := 0;
--  begin
--    wait for 175 us;
--    while true loop
--      CORRUPT_RX_SERVER <= '0';
--      uniform(s1,s2,r);
--      ir := integer(trunc(r*100000.0));
--      n_errors := n_errors + 1;
--      wait for ir*1 ns;
--      CORRUPT_RX_SERVER <= '1';
--      wait for 1 ns;
--      CORRUPT_RX_SERVER <= '0';
--    end loop;
--    wait;
--  end process;
--
--  process
--    variable s1     : positive := 1;
--    variable s2     : positive := 2;
--    variable r      : real;
--    variable ir     : integer;
--  begin
--    wait for 175 us;
--    while true loop
--      uniform(s1,s2,r);
--      ir := integer(trunc(r*30.0));
--      wait for ir*1 us;
--      wait until rising_edge(CLK_156_25);
--      TCP_RX_CTS_SERVER(0) <= '1';
--      
--      uniform(s1,s2,r);
--      ir := integer(trunc(r*30.0));
--      wait for ir*1 us;
--      wait until rising_edge(CLK_156_25);
--      TCP_RX_CTS_SERVER(0) <= '0';
--    end loop;
--    wait;
--  end process;

  process
  begin
    wait for 1 us;
    --         CLK     WR     RD     ADDR        DATA
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000100",x"00000003");
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000100",x"00000000");
    wait for 1 us;
    
    --Setup TCP Server
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000210",x"81396D7C");  --IP4_ADDR       129.57.109.124
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000218",x"FFFFFF00");  --IP4_SUBNETMASK 255.255.255.0
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"0000021C",x"81396D01");  --IPv4_GATEWAY_ADDR 129.57.109.1
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000238",x"0000CEBA");  --MAC ADDR       CE:BA:F0:00:00:02
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000234",x"F0000002");  --MAC ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000264",x"81396DE6");  --UDP DEST ADDR  129.57.109.230
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000268",x"2713B02D");  --UDP PORT (dest=45101, source 10003)
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000280",x"81396DE6");  --TCP Connection IP 129.57.109.230
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"000002A0",x"80002000");  --TCP Connection Port 8192, Local 32768
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000200",x"000003C5");  --Signal detect, PMA_PMD_TYPE 111, RESET
    wait for 400 ns;
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000200",x"000003C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET

    wait for 10 us;
    
    --Setup TCP Client
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000310",x"81396DE6");  --IP4_ADDR       129.57.109.230
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000318",x"FFFFFF00");  --IP4_SUBNETMASK 255.255.255.0
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"0000031C",x"81396D01");  --IPv4_GATEWAY_ADDR 129.57.109.1
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000338",x"0000CEBA");  --MAC ADDR       CE:BA:F0:00:00:01
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000334",x"F0000001");  --MAC ADDR
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000364",x"81396D7C");  --UDP DEST ADDR  1129.57.109.124
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000368",x"B02D2713");  --UDP PORT (dest=10003, source 45101)
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"000003A0",x"20000000");  --TCP Listening Port 8192
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000003C5");  --Signal detect, PMA_PMD_TYPE 111, RESET
    wait for 400 ns;
    --pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000403C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET, ENABLE TEST MODE
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000003C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET

    -- Wait to establish links
    report "Wait for links to establish" severity note;
    wait for 32 us;
    report "Connect to server" severity note;
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000320",x"00000001");  --Command client to connect to server
    report "Connect to server...done" severity note;

    wait for 50 us;
    --pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000C03C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET, ENABLE TEST MODE, ENABLE TEST SEQUENCE
    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000300",x"000003C0");  --Signal detect, PMA_PMD_TYPE 111, NO RESET
--    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000320",x"00000000");  --Command client to dis-connect from server

---- reset server
--pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000224",x"00000001");  --Connection reset
--wait for 35 us;
---- enable server
--pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000224",x"00000000");  --Connection reset clear
--
--pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000224",x"00000000");  --Connection reset clear
----
    --Setup TX Test on server
--    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000004",x"00000002");  --CNT limit=2
--    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000000",x"00000003");  --Enable, CNT limit enabled
--    wait for 1 ms;

--    pbus_write(BUS_CLK,BUS_WR,BUS_RD,x"00000000",x"00000001");  --Enable, CNT limit disabled

  UDP_TX_EOF_SERVER <= '0';
  UDP_TX_SOF_SERVER <= '0';
  UDP_TX_DATA_VALID_SERVER <= x"00";
  UDP_TX_DATA_SERVER <= x"00000000_00000000";

  for I in TEST_UDP_TX_DATA'range loop
    wait until falling_edge(CLK_156_25);
    report "TEXT_UDP_TX_DATA(" & integer'image(I) & ") = " & to_string(TEST_UDP_TX_DATA(I)) severity note;
    UDP_TX_EOF_SERVER        <= TEST_UDP_TX_DATA(I)(73);
    UDP_TX_SOF_SERVER        <= TEST_UDP_TX_DATA(I)(72);
    UDP_TX_DATA_VALID_SERVER <= TEST_UDP_TX_DATA(I)(71 downto 64);
    UDP_TX_DATA_SERVER       <= TEST_UDP_TX_DATA(I)(63 downto 0);
  end loop;

--    while true loop
--      if UDP_TX_CTS_SERVER = '1' then
--        for I in 0 to (UDP_TEST_FRAME'length+15)/16-1 loop
--          wait until falling_edge(CLK_156_25);
--          if I = 0 then
--            UDP_TX_SOF_SERVER <= '1';
--          else
--            UDP_TX_SOF_SERVER <= '0';
--          end if;
--          
--          UDP_TX_DATA_VALID_SERVER <= (others=>'0');
--		  UDP_TX_DATA_SERVER <= (others=>'0');
--
--          if 16*I+8 <= UDP_TEST_FRAME'length then
--            UDP_TX_DATA_VALID_SERVER(7 downto 4) <= x"F";
--            UDP_TX_DATA_SERVER(63 downto 60) <= char_to_4bit(UDP_TEST_FRAME(16*I+1));
--            UDP_TX_DATA_SERVER(59 downto 56) <= char_to_4bit(UDP_TEST_FRAME(16*I+2));
--            UDP_TX_DATA_SERVER(55 downto 52) <= char_to_4bit(UDP_TEST_FRAME(16*I+3));
--            UDP_TX_DATA_SERVER(51 downto 48) <= char_to_4bit(UDP_TEST_FRAME(16*I+4));
--            UDP_TX_DATA_SERVER(47 downto 44) <= char_to_4bit(UDP_TEST_FRAME(16*I+5));
--            UDP_TX_DATA_SERVER(43 downto 40) <= char_to_4bit(UDP_TEST_FRAME(16*I+6));
--            UDP_TX_DATA_SERVER(39 downto 36) <= char_to_4bit(UDP_TEST_FRAME(16*I+7));
--            UDP_TX_DATA_SERVER(35 downto 32) <= char_to_4bit(UDP_TEST_FRAME(16*I+8));
--          end if;
--          
--          if 16*I+16 <= UDP_TEST_FRAME'length then
--            UDP_TX_DATA_VALID_SERVER(3 downto 0) <= x"F";
--            UDP_TX_DATA_SERVER(31 downto 28) <= char_to_4bit(UDP_TEST_FRAME(16*I+9));
--            UDP_TX_DATA_SERVER(27 downto 24) <= char_to_4bit(UDP_TEST_FRAME(16*I+10));
--            UDP_TX_DATA_SERVER(23 downto 20) <= char_to_4bit(UDP_TEST_FRAME(16*I+11));
--            UDP_TX_DATA_SERVER(19 downto 16) <= char_to_4bit(UDP_TEST_FRAME(16*I+12));
--            UDP_TX_DATA_SERVER(15 downto 12) <= char_to_4bit(UDP_TEST_FRAME(16*I+13));
--            UDP_TX_DATA_SERVER(11 downto 8) <= char_to_4bit(UDP_TEST_FRAME(16*I+14));
--            UDP_TX_DATA_SERVER(7 downto 4) <= char_to_4bit(UDP_TEST_FRAME(16*I+15));
--            UDP_TX_DATA_SERVER(3 downto 0) <= char_to_4bit(UDP_TEST_FRAME(16*I+16));
--          end if;
--
--          if I = (UDP_TEST_FRAME'length+15)/16-1 then
--            UDP_TX_EOF_SERVER <= '1';
--          else
--            UDP_TX_EOF_SERVER <= '0';
--          end if;
--        end loop;
--        
--        wait until falling_edge(CLK_156_25);
--        UDP_TX_DATA_SERVER <= (others=>'0');
--        UDP_TX_DATA_VALID_SERVER <= x"00";
--        UDP_TX_SOF_SERVER <= '0';
--        UDP_TX_EOF_SERVER <= '0';
--        
----        while true loop
----          wait until falling_edge(CLK_156_25);
----          if (UDP_TX_ACK_CLIENT = '1') or (UDP_TX_NAK_CLIENT = '1') then
----            exit;
----          end if;
----        end loop;
--      else
--        wait until falling_edge(CLK_156_25);
--      end if;      
--      
--    end loop;

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

  z7_10GbE_tcpip_per_inst_server: z7_10GbE_tcpip_per
    generic map(
      ADDR_INFO             => (x"00000200", x"0000FF00",x"000000FF"),
      SIMULATION            => '1',
      TCP_TX_WINDOW_SIZE    => 12,
      TCP_RX_WINDOW_SIZE    => 12,
      UDP_TX_EN             => true,
      UDP_RX_EN             => true,
      TX_IDLE_TIMEOUT       => 50,
      TCP_KEEPALIVE_PERIOD  => 60,
      SERVER                => true,
      TXPOLARITY            => '0',
      RXPOLARITY            => '0'
    )
    port map(
      CLK_156_25            => CLK_156_25,
      TCP_TX_DATA           => TCP_TX_DATA_SERVER,
      TCP_TX_DATA_VALID     => TCP_TX_DATA_VALID_SERVER,
      TCP_TX_DATA_FLUSH     => TCP_TX_DATA_FLUSH_SERVER,
      TCP_TX_CTS            => TCP_TX_CTS_SERVER,
      TCP_RX_DATA           => TCP_RX_DATA_SERVER,
      TCP_RX_DATA_VALID     => TCP_RX_DATA_VALID_SERVER,
      TCP_RX_RTS            => TCP_RX_RTS_SERVER,
      TCP_RX_CTS            => TCP_RX_CTS_SERVER,
      TCP_RX_CTS_ACK        => TCP_RX_CTS_ACK_SERVER,
      UDP_TX_DATA           => UDP_TX_DATA_SERVER,
      UDP_TX_DATA_VALID     => UDP_TX_DATA_VALID_SERVER,
      UDP_TX_SOF            => UDP_TX_SOF_SERVER,
      UDP_TX_EOF            => UDP_TX_EOF_SERVER,
      UDP_TX_CTS            => UDP_TX_CTS_SERVER,
      UDP_TX_ACK            => UDP_TX_ACK_SERVER,
      UDP_TX_NAK            => UDP_TX_NAK_SERVER,
      UDP_RX_DATA           => UDP_RX_DATA_SERVER,
      UDP_RX_DATA_VALID     => UDP_RX_DATA_VALID_SERVER,
      UDP_RX_SOF            => UDP_RX_SOF_SERVER,
      UDP_RX_EOF            => UDP_RX_EOF_SERVER,
      UDP_RX_FRAME_VALID    => UDP_RX_FRAME_VALID_SERVER,
      PCS_PMA_SHARED        => PCS_PMA_SHARED,
      TXOUTCLK              => TXOUTCLK,
      TXP                   => TXP_SERVER,
      TXN                   => TXN_SERVER,
      RXP                   => RXP_SERVER,
      RXN                   => RXN_SERVER,
      FIBER_CTRL_INTL       => '0',
      FIBER_CTRL_LINKSTATUS => open,
      FIBER_CTRL_MODSELL    => open,
      FIBER_CTRL_RESETL     => open,
      FIBER_CTRL_MODPRSL    => '0',
      FIBER_CTRL_LPMODE     => open,
      BUS_CLK               => BUS_CLK,
      BUS_WR                => BUS_WR_ARRAY(2),
      BUS_RD                => BUS_RD_ARRAY(2)
    );

  z7_10GbE_tcpip_per_inst_client: z7_10GbE_tcpip_per
    generic map(
      ADDR_INFO             => (x"00000300", x"0000FF00",x"000000FF"),
      SIMULATION            => '1',
      TCP_TX_WINDOW_SIZE    => 12,
      TCP_RX_WINDOW_SIZE    => 12,
      UDP_TX_EN             => true,
      UDP_RX_EN             => true,
      TX_IDLE_TIMEOUT       => 50,
      TCP_KEEPALIVE_PERIOD  => 60,
      SERVER                => false,
      TXPOLARITY            => '0',
      RXPOLARITY            => '0'
    )
    port map(
      CLK_156_25            => CLK_156_25,
      TCP_TX_DATA           => TCP_TX_DATA_CLIENT,
      TCP_TX_DATA_VALID     => TCP_TX_DATA_VALID_CLIENT,
      TCP_TX_DATA_FLUSH     => TCP_TX_DATA_FLUSH_CLIENT,
      TCP_TX_CTS            => TCP_TX_CTS_CLIENT,
      TCP_RX_DATA           => TCP_RX_DATA_CLIENT,
      TCP_RX_DATA_VALID     => TCP_RX_DATA_VALID_CLIENT,
      TCP_RX_RTS            => TCP_RX_RTS_CLIENT,
      TCP_RX_CTS            => TCP_RX_CTS_CLIENT,
      TCP_RX_CTS_ACK        => TCP_RX_CTS_ACK_CLIENT,
      UDP_TX_DATA           => UDP_TX_DATA_CLIENT,
      UDP_TX_DATA_VALID     => UDP_TX_DATA_VALID_CLIENT,
      UDP_TX_SOF            => UDP_TX_SOF_CLIENT,
      UDP_TX_EOF            => UDP_TX_EOF_CLIENT,
      UDP_TX_CTS            => UDP_TX_CTS_CLIENT,
      UDP_TX_ACK            => UDP_TX_ACK_CLIENT,
      UDP_TX_NAK            => UDP_TX_NAK_CLIENT,
      UDP_RX_DATA           => UDP_RX_DATA_CLIENT,
      UDP_RX_DATA_VALID     => UDP_RX_DATA_VALID_CLIENT,
      UDP_RX_SOF            => UDP_RX_SOF_CLIENT,
      UDP_RX_EOF            => UDP_RX_EOF_CLIENT,
      UDP_RX_FRAME_VALID    => UDP_RX_FRAME_VALID_CLIENT,
      PCS_PMA_SHARED        => PCS_PMA_SHARED,
      TXOUTCLK              => open,
      TXP                   => TXP_CLIENT,
      TXN                   => TXN_CLIENT,
      RXP                   => RXP_CLIENT,
      RXN                   => RXN_CLIENT,
      FIBER_CTRL_INTL       => '0',
      FIBER_CTRL_LINKSTATUS => open,
      FIBER_CTRL_MODSELL    => open,
      FIBER_CTRL_RESETL     => open,
      FIBER_CTRL_MODPRSL    => '0',
      FIBER_CTRL_LPMODE     => open,
      BUS_CLK               => BUS_CLK,
      BUS_WR                => BUS_WR_ARRAY(3),
      BUS_RD                => BUS_RD_ARRAY(3)
    );

  process
    variable n_errors : integer := 0;
    variable n_bytes  : integer := 0;
    variable val      : std_logic_vector(63 downto 0);
    variable val_idx  : integer := 0;
  begin
    while true loop
      wait until rising_edge(CLK_156_25);
      for I in 7 downto 0 loop
        if TCP_RX_DATA_VALID_SERVER(I) = '1' then
          case n_bytes is
            when 0      => val(63 downto 56) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when 1      => val(55 downto 48) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when 2      => val(47 downto 40) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when 3      => val(39 downto 32) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when 4      => val(31 downto 24) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when 5      => val(23 downto 16) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when 6      => val(15 downto  8) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
            when others => val( 7 downto  0) := TCP_RX_DATA_SERVER(8*I+7 downto 8*I+0);
                           if val_idx /= to_integer(signed(val(31 downto 0))) then
                             n_errors := n_errors + 1;
                           end if;
                           report "TCP_RX(" & integer'image(val_idx) & "): " & integer'image(to_integer(signed(val(63 downto 32)))) & "," & integer'image(to_integer(signed(val(31 downto 0)))) & " nerrors = " & integer'image(n_errors) severity note;
                           val_idx := val_idx + 1;
          end case;          
          n_bytes := (n_bytes + 1) mod 8;
        end if;
      end loop;
    end loop;
  end process;

end testbench;
