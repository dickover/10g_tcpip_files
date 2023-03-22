library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library utils;
use utils.utils_pkg.all;

library per_lib;
use per_lib.perbus_pkg.all;

use work.pcspma_shared_pkg.all;

entity z7_10GbE_tcpip_per is
  generic(
    ADDR_INFO             : PER_ADDR_INFO;
    SIMULATION            : std_logic := '0';
    TCP_TX_WINDOW_SIZE    : integer;
    TCP_RX_WINDOW_SIZE    : integer;
    UDP_TX_EN             : boolean := false;
    UDP_RX_EN             : boolean := false;
    TX_IDLE_TIMEOUT       : integer := 50;
    TCP_KEEPALIVE_PERIOD  : integer := 60;
    SERVER                : boolean := true;
    TXPOLARITY            : std_logic;
    RXPOLARITY            : std_logic
  );
  port(
    ----------------------------------------------------
    -- User Ports --------------------------------------
    ----------------------------------------------------
    CLK_156_25            : in std_logic;

    MTU_OUT               : out std_logic_vector(13 downto 0);

    -- TCP streams
    TCP_TX_DATA           : in std_logic_vector(63 downto 0);
    TCP_TX_DATA_VALID     : in std_logic_vector(7 downto 0);
    TCP_TX_DATA_FLUSH     : in std_logic;
    TCP_TX_CTS            : out std_logic;

    TCP_RX_DATA           : out std_logic_vector(63 downto 0);
    TCP_RX_DATA_VALID     : out std_logic_vector(7 downto 0);
    TCP_RX_RTS            : out std_logic;
    TCP_RX_CTS            : in std_logic;
    TCP_RX_CTS_ACK        : out std_logic;

    UDP_TX_DATA           : in std_logic_vector(63 downto 0);
    UDP_TX_DATA_VALID     : in std_logic_vector(7 downto 0);
    UDP_TX_SOF            : in std_logic;
    UDP_TX_EOF            : in std_logic;
    UDP_TX_CTS            : out std_logic;
    UDP_TX_ACK            : out std_logic;
    UDP_TX_NAK            : out std_logic;

    UDP_RX_DATA           : out std_logic_vector(63 downto 0);
    UDP_RX_DATA_VALID     : out std_logic_vector(7 downto 0);
    UDP_RX_SOF            : out std_logic;
    UDP_RX_EOF            : out std_logic;
    UDP_RX_FRAME_VALID    : out std_logic;

    -- PCS/PMA shared signals
    PCS_PMA_SHARED        : in PCS_PMA_SHARED_TYPE;
    TXOUTCLK              : out std_logic;

    -- SFP Module
    TXP                   : out std_logic;
    TXN                   : out std_logic;
    RXP                   : in std_logic;
    RXN                   : in std_logic;
    
    FIBER_CTRL_INTL       : in std_logic;
    FIBER_CTRL_LINKSTATUS : out std_logic;
    FIBER_CTRL_MODSELL    : out std_logic;
    FIBER_CTRL_RESETL     : out std_logic;
    FIBER_CTRL_MODPRSL    : in std_logic;
    FIBER_CTRL_LPMODE     : out std_logic;

    ----------------------------------------------------
    -- Bus interface ports -----------------------------
    ----------------------------------------------------
    BUS_CLK               : in std_logic;
    BUS_WR                : in BUS_FIFO_WR;
    BUS_RD                : out BUS_FIFO_RD
  );
end z7_10GbE_tcpip_per;

architecture synthesis of z7_10GbE_tcpip_per is
  signal PI                        : pbus_if_i := pbus_if_i_init;
  signal PO                        : pbus_if_o := pbus_if_o_init;

  --Registers
  signal CTRL_REG                  : std_logic_vector(31 downto 0) := x"00000000";
  signal STATUS_REG                : std_logic_vector(31 downto 0) := x"00000000";
  signal MTU_REG                   : std_logic_vector(31 downto 0) := x"00000000";
  signal IP4_ADDR_REG              : std_logic_vector(31 downto 0) := x"00000000";
  signal IP4_MCASTADDR_REG         : std_logic_vector(31 downto 0) := x"00000000";
  signal IP4_SUBNETMASK_REG        : std_logic_vector(31 downto 0) := x"00000000";
  signal IP4_GATEWAYADDR_REG       : std_logic_vector(31 downto 0) := x"00000000";
  signal TCP_DEST_IP_ADDR_REG      : std_logic_vector(31 downto 0) := x"00000000";
  signal TCP_PORT_REG              : std_logic_vector(31 downto 0) := x"00000000";
  signal CONNECTION_RESET_REG      : std_logic_vector(31 downto 0) := x"00000000";
  signal TCP_STATE_REQUESTED_REG   : std_logic_vector(31 downto 0) := x"00000000";
  signal TCP_KEEPALIVE_REG         : std_logic_vector(31 downto 0) := x"00000000";
  signal TCP_STATE_STATUS0_REG     : std_logic_vector(31 downto 0) := x"00000000";
  signal TCP_STATUS_REG            : std_logic_vector(31 downto 0) := x"00000000";
  signal UDP_DEST_IP_ADDR_REG      : std_logic_vector(31 downto 0) := x"00000000";
  signal UDP_PORT_REG              : std_logic_vector(31 downto 0) := x"00000000";
  signal MAC_ADDR0_REG             : std_logic_vector(31 downto 0) := x"00000000";
  signal MAC_ADDR1_REG             : std_logic_vector(31 downto 0) := x"00000000";
  signal MAC_STATUS0_REG           : std_logic_vector(31 downto 0) := x"00000000";
  signal MAC_STATUS1_REG           : std_logic_vector(31 downto 0) := x"00000000";
  signal MAC_STATUS2_REG           : std_logic_vector(31 downto 0) := x"00000000";
  signal MAC_STATUS3_REG           : std_logic_vector(31 downto 0) := x"00000000";
  signal PCS_STATUS_REG            : std_logic_vector(31 downto 0) := x"00000000";
  signal PHY_STATUS_REG            : std_logic_vector(31 downto 0) := x"00000000";

  --Register bits
  signal MTU                       : std_logic_vector(13 downto 0);
  signal RESET_MAC                 : std_logic;
  signal RESET_STACK               : std_logic;
  signal DYNAMIC_IPv4              : std_logic;
  signal IPv4_ADDR                 : std_logic_vector(31 downto 0);
  signal IPv4_MULTICAST_ADDR       : std_logic_vector(31 downto 0);
  signal IPv4_SUBNET_MASK          : std_logic_vector(31 downto 0);
  signal IPv4_GATEWAY_ADDR         : std_logic_vector(31 downto 0);
  signal TCP_DEST_IP_ADDR          : std_logic_vector(127 downto 0);
  signal TCP_DEST_PORT             : std_logic_vector(15 downto 0);
  signal UDP_TX_DEST_IP_ADDR       : std_logic_vector(127 downto 0);
  signal UDP_TX_SOURCE_PORT_NO     : std_logic_vector(15 downto 0);
  signal UDP_TX_DEST_PORT_NO       : std_logic_vector(15 downto 0);
  signal TCP_STATE_REQUESTED       : std_logic;
  signal TCP_STATE_STATUS          : std_logic_vector(3 downto 0);
  signal TCP_CONNECTED_FLAG        : std_logic;
  signal CONNECTION_RESET          : std_logic;
  signal TCP_KEEPALIVE_EN          : std_logic;
  signal TCP_LOCAL_PORTS           : std_logic_vector(15 downto 0);
  signal PMA_PMD_TYPE              : std_logic_vector(2 downto 0);
  signal PCS_CORE_STATUS           : std_logic_vector(7 downto 0);
  signal SIGNAL_DETECT             : std_logic;
  signal TX_FAULT                  : std_logic;
  signal MAC_ADDR                  : std_logic_vector(47 downto 0);
  signal MAC_N_TX_FRAMES           : std_logic_vector(15 downto 0);
  signal MAC_N_RX_FRAMES           : std_logic_vector(15 downto 0);
  signal MAC_N_RX_BAD_CRCS         : std_logic_vector(15 downto 0);
  signal MAC_N_RX_FRAMES_TOO_SHORT : std_logic_vector(15 downto 0);
  signal MAC_N_RX_FRAMES_TOO_LONG  : std_logic_vector(15 downto 0);
  signal MAC_N_RX_WRONG_ADDR       : std_logic_vector(15 downto 0);
  signal MAC_N_RX_LENGTH_ERRORS    : std_logic_vector(15 downto 0);
  signal MAC_RX_IPG                : std_logic_vector(7 downto 0);
  signal PHY_CONFIG_CHANGE         : std_logic;
  signal PHY_RESET                 : std_logic;
  signal PHY_TEST_MODE             : std_logic_vector(1 downto 0);
  signal PHY_POWER_DOWN            : std_logic;
  signal PHY_STATUS                : std_logic_vector(7 downto 0);
  signal PHY_STATUS2               : std_logic_vector(7 downto 0);
  signal PHY_ID                    : std_logic_vector(15 downto 0);
  signal TX_TEST_MODE              : std_logic;
  signal TX_TEST_EN                : std_logic;
  signal TCP_TX_DATA_i             : std_logic_vector(63 downto 0);
  signal TCP_TX_DATA_VALID_i       : std_logic_vector(7 downto 0);
  signal TCP_TX_CTS_i              : std_logic;
  signal TCP_RX_DATA_i             : std_logic_vector(63 downto 0);
  signal TCP_RX_DATA_VALID_i       : std_logic_vector(7 downto 0);
  signal TX_TEST_CNT               : std_logic_vector(63 downto 0);
begin

  MTU_OUT <= MTU;

  TCP_TX_CTS <= TCP_TX_CTS_i;

  TCP_RX_DATA <= TCP_RX_DATA_i;
  TCP_RX_DATA_VALID <= TCP_RX_DATA_VALID_i;
  
  process(TX_TEST_MODE, TCP_TX_DATA, TCP_TX_DATA_VALID, TX_TEST_CNT, TX_TEST_EN, TCP_TX_CTS_i)
  begin
    if TX_TEST_MODE = '0' then
      TCP_TX_DATA_i <= TCP_TX_DATA;
      TCP_TX_DATA_VALID_i <= TCP_TX_DATA_VALID;
    else
      TCP_TX_DATA_i <= TX_TEST_CNT;
     
      if TX_TEST_EN = '0' then
        TCP_TX_DATA_VALID_i <= (others=>'0');
      elsif TCP_TX_CTS_i = '1' then
        TCP_TX_DATA_VALID_i <= (others=>'1');
      else
        TCP_TX_DATA_VALID_i <= (others=>'0');
      end if;
    end if;
  end process;
  
  process(CLK_156_25)
  begin
    if rising_edge(CLK_156_25) then
      if TX_TEST_EN = '0' then
        TX_TEST_CNT <= (others=>'0');
      elsif TCP_TX_CTS_i = '1' then
        TX_TEST_CNT <= std_logic_vector(unsigned(TX_TEST_CNT)+1);
      end if;
    end if;
  end process;    

  server_gen_true: if SERVER = true generate
    z7_10GbE_tcpip_inst: entity work.z7_10GbE_tcpip_server
    generic map(
      SIMULATION                => SIMULATION,
      TCP_TX_WINDOW_SIZE        => TCP_TX_WINDOW_SIZE,
      TCP_RX_WINDOW_SIZE        => TCP_RX_WINDOW_SIZE,
      UDP_TX_EN                 => UDP_TX_EN,
      UDP_RX_EN                 => UDP_RX_EN,
      IPv6_ENABLED              => '0',
      IGMP_EN                   => '0',
      TX_IDLE_TIMEOUT           => TX_IDLE_TIMEOUT,
      TCP_KEEPALIVE_PERIOD      => TCP_KEEPALIVE_PERIOD,
      TXPOLARITY                => TXPOLARITY,
      RXPOLARITY                => RXPOLARITY
    )
    port map(
      CLK                       => CLK_156_25,
      RESET_MAC                 => RESET_MAC,
      RESET_STACK               => RESET_STACK,
      DYNAMIC_IPv4              => DYNAMIC_IPv4,
      IPv4_ADDR                 => IPv4_ADDR,
      IPv4_MULTICAST_ADDR       => IPv4_MULTICAST_ADDR,
      IPv4_SUBNET_MASK          => IPv4_SUBNET_MASK,
      IPv4_GATEWAY_ADDR         => IPv4_GATEWAY_ADDR,
      IPv6_ADDR                 => (others=>'0'),
      IPv6_SUBNET_PREFIX_LENGTH => (others=>'0'),
      IPv6_GATEWAY_ADDR         => (others=>'0'),
      CONNECTION_RESET          => CONNECTION_RESET,
      TCP_KEEPALIVE_EN          => TCP_KEEPALIVE_EN,
      TCP_LOCAL_PORTS           => TCP_LOCAL_PORTS,
      TCP_RX_DATA               => TCP_RX_DATA_i,
      TCP_RX_DATA_VALID         => TCP_RX_DATA_VALID_i,
      TCP_RX_RTS                => TCP_RX_RTS,
      TCP_RX_CTS                => TCP_RX_CTS,
      TCP_RX_CTS_ACK            => TCP_RX_CTS_ACK,
      TCP_TX_DATA               => TCP_TX_DATA_i,
      TCP_TX_DATA_VALID         => TCP_TX_DATA_VALID_i,
      TCP_TX_DATA_FLUSH         => TCP_TX_DATA_FLUSH,
      TCP_TX_CTS                => TCP_TX_CTS_i,
      TCP_CONNECTED_FLAG        => TCP_CONNECTED_FLAG,
      UDP_RX_DATA               => UDP_RX_DATA, 
      UDP_RX_DATA_VALID         => UDP_RX_DATA_VALID,
      UDP_RX_SOF                => UDP_RX_SOF,
      UDP_RX_EOF                => UDP_RX_EOF,
      UDP_RX_FRAME_VALID        => UDP_RX_FRAME_VALID,
      UDP_RX_DEST_PORT_NO_IN    => UDP_TX_SOURCE_PORT_NO,
      CHECK_UDP_RX_DEST_PORT_NO => '1',
      UDP_RX_DEST_PORT_NO_OUT   => open,
      UDP_TX_DATA               => UDP_TX_DATA,
      UDP_TX_DATA_VALID         => UDP_TX_DATA_VALID,
      UDP_TX_SOF                => UDP_TX_SOF,
      UDP_TX_EOF                => UDP_TX_EOF,
      UDP_TX_CTS                => UDP_TX_CTS,
      UDP_TX_ACK                => UDP_TX_ACK,
      UDP_TX_NAK                => UDP_TX_NAK,
      UDP_TX_DEST_IP_ADDR       => UDP_TX_DEST_IP_ADDR,
      UDP_TX_DEST_IPv4_6n       => '1',
      UDP_TX_DEST_PORT_NO       => UDP_TX_DEST_PORT_NO,
      UDP_TX_SOURCE_PORT_NO     => UDP_TX_SOURCE_PORT_NO,
      PMA_PMD_TYPE              => PMA_PMD_TYPE,
      PCS_CORE_STATUS           => PCS_CORE_STATUS,
      SIGNAL_DETECT             => SIGNAL_DETECT,
      TX_FAULT                  => TX_FAULT,
      TX_DISABLE                => open,
      TXUSRCLK                  => PCS_PMA_SHARED.TXUSRCLK,
      TXUSRCLK2                 => PCS_PMA_SHARED.TXUSRCLK2,
      ARESET_CORECLK            => PCS_PMA_SHARED.ARESET_CORECLK,
      TXOUTCLK                  => TXOUTCLK,
      GTTXRESET                 => PCS_PMA_SHARED.GTTXRESET,
      GTRXRESET                 => PCS_PMA_SHARED.GTRXRESET,
      TXUSERRDY                 => PCS_PMA_SHARED.TXUSERRDY,
      QPLLLOCK                  => PCS_PMA_SHARED.QPLLLOCK,
      QPLLOUTCLK                => PCS_PMA_SHARED.QPLLOUTCLK,
      QPLLOUTREFCLK             => PCS_PMA_SHARED.QPLLOUTREFCLK,
      RESET_COUNTER_DONE        => PCS_PMA_SHARED.RESET_COUNTER_DONE,
      MAC_ADDR                  => MAC_ADDR,
      MAC_N_TX_FRAMES           => MAC_N_TX_FRAMES,
      MAC_N_RX_FRAMES           => MAC_N_RX_FRAMES,
      MAC_N_RX_BAD_CRCS         => MAC_N_RX_BAD_CRCS,
      MAC_N_RX_FRAMES_TOO_SHORT => MAC_N_RX_FRAMES_TOO_SHORT,
      MAC_N_RX_FRAMES_TOO_LONG  => MAC_N_RX_FRAMES_TOO_LONG,
      MAC_N_RX_WRONG_ADDR       => MAC_N_RX_WRONG_ADDR,
      MAC_N_RX_LENGTH_ERRORS    => MAC_N_RX_LENGTH_ERRORS,
      MAC_RX_IPG                => MAC_RX_IPG,
      PHY_CONFIG_CHANGE         => PHY_CONFIG_CHANGE,
      PHY_RESET                 => PHY_RESET,
      PHY_TEST_MODE             => PHY_TEST_MODE,
      PHY_POWER_DOWN            => PHY_POWER_DOWN,
      PHY_STATUS                => PHY_STATUS,
      PHY_STATUS2               => PHY_STATUS2,
      PHY_ID                    => PHY_ID,
      MTU                       => MTU,
      TXP                       => TXP,
      TXN                       => TXN,
      RXP                       => RXP,
      RXN                       => RXN
    );
  end generate;

  server_gen_false: if SERVER = false generate
    z7_10GbE_tcpip_inst: entity work.z7_10GbE_tcpip_client
      generic map(
        SIMULATION                => SIMULATION,
        TCP_TX_WINDOW_SIZE        => TCP_TX_WINDOW_SIZE,
        TCP_RX_WINDOW_SIZE        => TCP_RX_WINDOW_SIZE,
        UDP_TX_EN                 => UDP_TX_EN,
        UDP_RX_EN                 => UDP_RX_EN,
        IPv6_ENABLED              => '0',
        IGMP_EN                   => '0',
        TX_IDLE_TIMEOUT           => TX_IDLE_TIMEOUT,
        TCP_KEEPALIVE_PERIOD      => TCP_KEEPALIVE_PERIOD,
        TXPOLARITY                => TXPOLARITY,
        RXPOLARITY                => RXPOLARITY
      )
      port map(
        CLK                       => CLK_156_25,
        RESET_MAC                 => RESET_MAC,
        RESET_STACK               => RESET_STACK,
        DYNAMIC_IPv4              => DYNAMIC_IPv4,
        IPv4_ADDR                 => IPv4_ADDR,
        IPv4_MULTICAST_ADDR       => IPv4_MULTICAST_ADDR,
        IPv4_SUBNET_MASK          => IPv4_SUBNET_MASK,
        IPv4_GATEWAY_ADDR         => IPv4_GATEWAY_ADDR,
        IPv6_ADDR                 => (others=>'0'),
        IPv6_SUBNET_PREFIX_LENGTH => (others=>'0'),
        IPv6_GATEWAY_ADDR         => (others=>'0'),
        TCP_DEST_IP_ADDR          => TCP_DEST_IP_ADDR,
        TCP_DEST_IPv4_6n          => '1',
        TCP_DEST_PORT             => TCP_DEST_PORT,
        TCP_STATE_REQUESTED       => TCP_STATE_REQUESTED,
        TCP_STATE_STATUS          => TCP_STATE_STATUS,
        CONNECTION_RESET          => CONNECTION_RESET,
        TCP_KEEPALIVE_EN          => TCP_KEEPALIVE_EN,
        TCP_LOCAL_PORTS           => TCP_LOCAL_PORTS,
        TCP_RX_DATA               => TCP_RX_DATA_i,
        TCP_RX_DATA_VALID         => TCP_RX_DATA_VALID_i,
        TCP_RX_RTS                => TCP_RX_RTS,
        TCP_RX_CTS                => TCP_RX_CTS,
        TCP_RX_CTS_ACK            => TCP_RX_CTS_ACK,
        TCP_TX_DATA               => TCP_TX_DATA_i,
        TCP_TX_DATA_VALID         => TCP_TX_DATA_VALID_i,
        TCP_TX_DATA_FLUSH         => TCP_TX_DATA_FLUSH,
        TCP_TX_CTS                => TCP_TX_CTS_i,
        TCP_CONNECTED_FLAG        => TCP_CONNECTED_FLAG,
        UDP_RX_DATA               => UDP_RX_DATA,
        UDP_RX_DATA_VALID         => UDP_RX_DATA_VALID,
        UDP_RX_SOF                => UDP_RX_SOF,
        UDP_RX_EOF                => UDP_RX_EOF,
        UDP_RX_FRAME_VALID        => UDP_RX_FRAME_VALID,
        UDP_RX_DEST_PORT_NO_IN    => UDP_TX_SOURCE_PORT_NO,
        CHECK_UDP_RX_DEST_PORT_NO => '0',
        UDP_RX_DEST_PORT_NO_OUT   => open,
        UDP_TX_DATA               => UDP_TX_DATA,
        UDP_TX_DATA_VALID         => UDP_TX_DATA_VALID,
        UDP_TX_SOF                => UDP_TX_SOF,
        UDP_TX_EOF                => UDP_TX_EOF,
        UDP_TX_CTS                => UDP_TX_CTS,
        UDP_TX_ACK                => UDP_TX_ACK,
        UDP_TX_NAK                => UDP_TX_NAK,
        UDP_TX_DEST_IP_ADDR       => UDP_TX_DEST_IP_ADDR,
        UDP_TX_DEST_IPv4_6n       => '1',
        UDP_TX_DEST_PORT_NO       => UDP_TX_DEST_PORT_NO,
        UDP_TX_SOURCE_PORT_NO     => UDP_TX_SOURCE_PORT_NO,
        PMA_PMD_TYPE              => PMA_PMD_TYPE,
        PCS_CORE_STATUS           => PCS_CORE_STATUS,
        SIGNAL_DETECT             => SIGNAL_DETECT,
        TX_FAULT                  => TX_FAULT,
        TX_DISABLE                => open,
        TXUSRCLK                  => PCS_PMA_SHARED.TXUSRCLK,
        TXUSRCLK2                 => PCS_PMA_SHARED.TXUSRCLK2,
        ARESET_CORECLK            => PCS_PMA_SHARED.ARESET_CORECLK,
        TXOUTCLK                  => TXOUTCLK,
        GTTXRESET                 => PCS_PMA_SHARED.GTTXRESET,
        GTRXRESET                 => PCS_PMA_SHARED.GTRXRESET,
        TXUSERRDY                 => PCS_PMA_SHARED.TXUSERRDY,
        QPLLLOCK                  => PCS_PMA_SHARED.QPLLLOCK,
        QPLLOUTCLK                => PCS_PMA_SHARED.QPLLOUTCLK,
        QPLLOUTREFCLK             => PCS_PMA_SHARED.QPLLOUTREFCLK,
        RESET_COUNTER_DONE        => PCS_PMA_SHARED.RESET_COUNTER_DONE,
        MAC_ADDR                  => MAC_ADDR,
        MAC_N_TX_FRAMES           => MAC_N_TX_FRAMES,
        MAC_N_RX_FRAMES           => MAC_N_RX_FRAMES,
        MAC_N_RX_BAD_CRCS         => MAC_N_RX_BAD_CRCS,
        MAC_N_RX_FRAMES_TOO_SHORT => MAC_N_RX_FRAMES_TOO_SHORT,
        MAC_N_RX_FRAMES_TOO_LONG  => MAC_N_RX_FRAMES_TOO_LONG,
        MAC_N_RX_WRONG_ADDR       => MAC_N_RX_WRONG_ADDR,
        MAC_N_RX_LENGTH_ERRORS    => MAC_N_RX_LENGTH_ERRORS,
        MAC_RX_IPG                => MAC_RX_IPG,
        PHY_CONFIG_CHANGE         => PHY_CONFIG_CHANGE,
        PHY_RESET                 => PHY_RESET,
        PHY_TEST_MODE             => PHY_TEST_MODE,
        PHY_POWER_DOWN            => PHY_POWER_DOWN,
        PHY_STATUS                => PHY_STATUS,
        PHY_STATUS2               => PHY_STATUS2,
        PHY_ID                    => PHY_ID,
        MTU                       => MTU,
        TXP                       => TXP,
        TXN                       => TXN,
        RXP                       => RXP,
        RXN                       => RXN
      );
  end generate;

  fbus_ctrl_inst: fbus_ctrl
    generic map(
      ADDR_INFO => ADDR_INFO
    )
    port map(
      BUS_CLK   => BUS_CLK,
      BUS_WR    => BUS_WR,
      BUS_RD    => BUS_RD,
      PER_CLK   => CLK_156_25,
      PI        => PI,
      PO        => PO
    );

  --CTRL_REG
  PHY_CONFIG_CHANGE  <= CTRL_REG(1);
  PHY_RESET          <= CTRL_REG(2);
  PHY_TEST_MODE      <= CTRL_REG(4 downto 3);
  PHY_POWER_DOWN     <= CTRL_REG(5);
  PMA_PMD_TYPE       <= CTRL_REG(8 downto 6);
  SIGNAL_DETECT      <= CTRL_REG(9);
  TX_FAULT           <= CTRL_REG(10);
  FIBER_CTRL_MODSELL <= CTRL_REG(11);
  FIBER_CTRL_RESETL  <= CTRL_REG(12);
  FIBER_CTRL_LPMODE  <= CTRL_REG(13);
  RESET_MAC          <= CTRL_REG(14);
  RESET_STACK        <= CTRL_REG(15);
  DYNAMIC_IPv4       <= CTRL_REG(16);
  FIBER_CTRL_LINKSTATUS <= CTRL_REG(17);
  TX_TEST_MODE          <= CTRL_REG(18);
  TX_TEST_EN            <= CTRL_REG(19);
  
  --STATUS_REG
  STATUS_REG(0)            <= FIBER_CTRL_INTL;
  STATUS_REG(2)            <= FIBER_CTRL_MODPRSL;
  STATUS_REG(3)            <= TCP_TX_CTS_i;
  STATUS_REG(31)           <= '0' when SERVER = true else '1';
  
  --MTU_REG
  MTU                <= MTU_REG(13 downto 0);

  --IP4_ADDR_REG
  IPv4_ADDR <= IP4_ADDR_REG;

  --IP4_MCASTADDR_REG
  IPv4_MULTICAST_ADDR <= IP4_MCASTADDR_REG;

  --IP4_SUBNETMASK_REG
  IPv4_SUBNET_MASK <= IP4_SUBNETMASK_REG;

  --IP4_GATEWAYADDR_REG
  IPv4_GATEWAY_ADDR <= IP4_GATEWAYADDR_REG;

  --TCP_DEST_IP_ADDR_REG
  TCP_DEST_IP_ADDR <= x"0000_0000_0000_0000_0000_0000" & TCP_DEST_IP_ADDR_REG;

  --TCP_PORT_REG
  TCP_DEST_PORT   <= TCP_PORT_REG(15 downto 0);
  TCP_LOCAL_PORTS <= TCP_PORT_REG(31 downto 16);
  
  --TCP_STATE_REQUESTED_REG
  TCP_STATE_REQUESTED <= TCP_STATE_REQUESTED_REG(0);

  -- UDP_DEST_IP_ADDR_REG
  UDP_TX_DEST_IP_ADDR <= x"0000_0000_0000_0000_0000_0000" & UDP_DEST_IP_ADDR_REG;
  
  --UDP_PORT_REG
  UDP_TX_DEST_PORT_NO   <= UDP_PORT_REG(15 downto 0);
  UDP_TX_SOURCE_PORT_NO <= UDP_PORT_REG(31 downto 16);

  --CONNECTION_RESET_REG  
  CONNECTION_RESET <= CONNECTION_RESET_REG(0);

  --TCP_KEEPALIVE_REG
  TCP_KEEPALIVE_EN <= TCP_KEEPALIVE_REG(0);

  --TCP_STATE_STATUS0_REG
  TCP_STATE_STATUS0_REG(3 downto 0) <= TCP_STATE_STATUS;

  --TCP_STATUS_REG
  TCP_STATUS_REG(0) <= TCP_CONNECTED_FLAG;

  --MAC_ADDRx_REG
  MAC_ADDR(31 downto 0)  <= MAC_ADDR0_REG;
  MAC_ADDR(47 downto 32) <= MAC_ADDR1_REG(15 downto 0);

  --MAC_STATUSx_REG
  MAC_STATUS0_REG(15 downto 0)  <= MAC_N_TX_FRAMES;
  MAC_STATUS0_REG(31 downto 16) <= MAC_N_RX_FRAMES;
  MAC_STATUS1_REG(15 downto 0)  <= MAC_N_RX_BAD_CRCS;
  MAC_STATUS1_REG(31 downto 16) <= MAC_N_RX_FRAMES_TOO_SHORT;
  MAC_STATUS2_REG(15 downto 0)  <= MAC_N_RX_FRAMES_TOO_LONG;
  MAC_STATUS2_REG(31 downto 16) <= MAC_N_RX_WRONG_ADDR;
  MAC_STATUS3_REG(15 downto 0)  <= MAC_N_RX_LENGTH_ERRORS;
  MAC_STATUS3_REG(23 downto 16) <= MAC_RX_IPG;

  --PCS_STATUS_REG
  PCS_STATUS_REG(7 downto 0) <= PCS_CORE_STATUS;

  --PHY_STATUS_REG
  PHY_STATUS_REG(15 downto 0) <= PHY_ID;
  PHY_STATUS_REG(23 downto 16) <= PHY_STATUS;
  PHY_STATUS_REG(31 downto 24) <= PHY_STATUS2;

  process(CLK_156_25)
  begin
    if rising_edge(CLK_156_25) then
      PO.ACK <= '0';

      rw_reg(     REG => CTRL_REG                 ,PI=>PI,PO=>PO, A => x"0000", RW => x"000FFFFF", I => x"0000C025");
      ro_reg(     REG => STATUS_REG               ,PI=>PI,PO=>PO, A => x"0004", RO => x"FFFFFFFF");
      rw_reg(     REG => MTU_REG                  ,PI=>PI,PO=>PO, A => x"0008", RW => x"FFFFFFFF", I => x"000005DC");
      rw_reg(     REG => IP4_ADDR_REG             ,PI=>PI,PO=>PO, A => x"0010", RW => x"FFFFFFFF");
      rw_reg(     REG => IP4_MCASTADDR_REG        ,PI=>PI,PO=>PO, A => x"0014", RW => x"FFFFFFFF");
      rw_reg(     REG => IP4_SUBNETMASK_REG       ,PI=>PI,PO=>PO, A => x"0018", RW => x"FFFFFFFF");
      rw_reg(     REG => IP4_GATEWAYADDR_REG      ,PI=>PI,PO=>PO, A => x"001C", RW => x"FFFFFFFF");
      rw_reg(     REG => TCP_STATE_REQUESTED_REG  ,PI=>PI,PO=>PO, A => x"0020", RW => x"00000001");
      rw_reg(     REG => CONNECTION_RESET_REG     ,PI=>PI,PO=>PO, A => x"0024", RW => x"00000001");  
      rw_reg(     REG => TCP_KEEPALIVE_REG        ,PI=>PI,PO=>PO, A => x"0028", RW => x"00000001");
      ro_reg(     REG => TCP_STATE_STATUS0_REG    ,PI=>PI,PO=>PO, A => x"002C", RO => x"0000000F");
      ro_reg(     REG => TCP_STATUS_REG           ,PI=>PI,PO=>PO, A => x"0030", RO => x"00000001");
      rw_reg(     REG => MAC_ADDR0_REG            ,PI=>PI,PO=>PO, A => x"0034", RW => x"FFFFFFFF");
      rw_reg(     REG => MAC_ADDR1_REG            ,PI=>PI,PO=>PO, A => x"0038", RW => x"0000FFFF");
      ro_reg(     REG => MAC_STATUS0_REG          ,PI=>PI,PO=>PO, A => x"003C", RO => x"FFFFFFFF");
      ro_reg(     REG => MAC_STATUS1_REG          ,PI=>PI,PO=>PO, A => x"0040", RO => x"FFFFFFFF");
      ro_reg(     REG => MAC_STATUS2_REG          ,PI=>PI,PO=>PO, A => x"0044", RO => x"FFFFFFFF");
      ro_reg(     REG => MAC_STATUS3_REG          ,PI=>PI,PO=>PO, A => x"0048", RO => x"00FFFFFF");
      ro_reg(     REG => PCS_STATUS_REG           ,PI=>PI,PO=>PO, A => x"0050", RO => x"000000FF");
      ro_reg(     REG => PHY_STATUS_REG           ,PI=>PI,PO=>PO, A => x"0060", RO => x"FFFFFFFF");
      rw_reg(     REG => UDP_DEST_IP_ADDR_REG     ,PI=>PI,PO=>PO, A => x"0064", RW => x"FFFFFFFF");
      rw_reg(     REG => UDP_PORT_REG             ,PI=>PI,PO=>PO, A => x"0068", RW => x"FFFFFFFF");
      rw_reg(     REG => TCP_DEST_IP_ADDR_REG     ,PI=>PI,PO=>PO, A => x"0080", RW => x"FFFFFFFF");
      rw_reg(     REG => TCP_PORT_REG             ,PI=>PI,PO=>PO, A => x"00A0", RW => x"FFFFFFFF");
    end if;
  end process;
end synthesis;
