library ieee;
use ieee.std_logic_1164.all;

library utils;
use utils.utils_pkg.all;

library com5501_lib;
library com5503_lib;
use com5503_lib.com5502pkg.all;

entity z7_10GbE_tcpip_client is
  generic(
    SIMULATION                : std_logic := '0';
    TCP_TX_WINDOW_SIZE        : integer;
    TCP_RX_WINDOW_SIZE        : integer;
    UDP_TX_EN                 : boolean := false;
    UDP_RX_EN                 : boolean := false;
    IPv6_ENABLED              : std_logic := '0';
    IGMP_EN                   : std_logic := '0';
    TX_IDLE_TIMEOUT           : integer := 50;
    TCP_KEEPALIVE_PERIOD      : integer := 60;
    TXPOLARITY                : std_logic;
    RXPOLARITY                : std_logic
  );
  port(
    -- 156.25MHz
    CLK                       : in std_logic;
    -- reset pulse must be > slowest clock period  (>400ns)
    -- synchronous with CLK
    RESET_MAC                 : in std_logic;
    RESET_STACK               : in std_logic;

    -- IP signals
    DYNAMIC_IPv4              : in std_logic;
    IPv4_ADDR                 : in std_logic_vector(31 downto 0);
    IPv4_MULTICAST_ADDR       : in std_logic_vector(31 downto 0);
    IPv4_SUBNET_MASK          : in std_logic_vector(31 downto 0);
    IPv4_GATEWAY_ADDR         : in std_logic_vector(31 downto 0);
    IPv6_ADDR                 : in std_logic_vector(127 downto 0);
    IPv6_SUBNET_PREFIX_LENGTH : in std_logic_vector(7 downto 0);
    IPv6_GATEWAY_ADDR         : in std_logic_vector(127 downto 0);
    TCP_DEST_IP_ADDR          : in std_logic_vector(127 downto 0);
    TCP_DEST_IPv4_6n          : in std_logic;
    TCP_DEST_PORT             : in std_logic_vector(15 downto 0);
    TCP_STATE_REQUESTED       : in std_logic;
    TCP_STATE_STATUS          : out std_logic_vector(3 downto 0);
    CONNECTION_RESET          : in std_logic;
    TCP_KEEPALIVE_EN          : in std_logic;
    TCP_LOCAL_PORTS           : in std_logic_vector(15 downto 0);
    TCP_RX_DATA               : out std_logic_vector(63 downto 0);
    TCP_RX_DATA_VALID         : out std_logic_vector(7 downto 0);
    TCP_RX_RTS                : out std_logic;
    TCP_RX_CTS                : in std_logic;
    TCP_RX_CTS_ACK            : out std_logic;
    TCP_TX_DATA               : in std_logic_vector(63 downto 0);
    TCP_TX_DATA_VALID         : in std_logic_vector(7 downto 0);
    TCP_TX_DATA_FLUSH         : in std_logic;
    TCP_TX_CTS                : out std_logic;
    TCP_CONNECTED_FLAG        : out std_logic;
    UDP_RX_DATA               : out std_logic_vector(63 downto 0);
    UDP_RX_DATA_VALID         : out std_logic_vector(7 downto 0);
    UDP_RX_SOF                : out std_logic;
    UDP_RX_EOF                : out std_logic;
    UDP_RX_FRAME_VALID        : out std_logic;
    UDP_RX_DEST_PORT_NO_IN    : in std_logic_vector(15 downto 0);
    CHECK_UDP_RX_DEST_PORT_NO : in std_logic;
    UDP_RX_DEST_PORT_NO_OUT   : out std_logic_vector(15 downto 0);
    UDP_TX_DATA               : in std_logic_vector(63 downto 0);
    UDP_TX_DATA_VALID         : in std_logic_vector(7 downto 0);
    UDP_TX_SOF                : in std_logic;
    UDP_TX_EOF                : in std_logic;
    UDP_TX_CTS                : out std_logic;
    UDP_TX_ACK                : out std_logic;
    UDP_TX_NAK                : out std_logic;
    UDP_TX_DEST_IP_ADDR       : in std_logic_vector(127 downto 0);
    UDP_TX_DEST_IPv4_6n       : in std_logic;
    UDP_TX_DEST_PORT_NO       : in std_logic_vector(15 downto 0);
    UDP_TX_SOURCE_PORT_NO     : in std_logic_vector(15 downto 0);

    -- PCS/PMA signals
    PMA_PMD_TYPE              : in std_logic_vector(2 downto 0);
    PCS_CORE_STATUS           : out std_logic_vector(7 downto 0);
    SIGNAL_DETECT             : in std_logic;
    TX_FAULT                  : in std_logic;
    TX_DISABLE                : out std_logic;

    -- PCS/PMA shared signals
    TXUSRCLK                  : in std_logic;
    TXUSRCLK2                 : in std_logic;
    ARESET_CORECLK            : in std_logic;
    TXOUTCLK                  : out std_logic;
    GTTXRESET                 : in std_logic;
    GTRXRESET                 : in std_logic;
    TXUSERRDY                 : in std_logic;
    QPLLLOCK                  : in std_logic;
    QPLLOUTCLK                : in std_logic;
    QPLLOUTREFCLK             : in std_logic;
    RESET_COUNTER_DONE        : in std_logic;

    -- MAC
    MAC_ADDR                  : in std_logic_vector(47 downto 0);
    MAC_N_TX_FRAMES           : out std_logic_vector(15 downto 0);
    MAC_N_RX_FRAMES           : out std_logic_vector(15 downto 0);
    MAC_N_RX_BAD_CRCS         : out std_logic_vector(15 downto 0);
    MAC_N_RX_FRAMES_TOO_SHORT : out std_logic_vector(15 downto 0);
    MAC_N_RX_FRAMES_TOO_LONG  : out std_logic_vector(15 downto 0);
    MAC_N_RX_WRONG_ADDR       : out std_logic_vector(15 downto 0);
    MAC_N_RX_LENGTH_ERRORS    : out std_logic_vector(15 downto 0);
    MAC_RX_IPG                : out std_logic_vector(7 downto 0);

    -- PHY
    PHY_CONFIG_CHANGE         : in std_logic;
    PHY_RESET                 : in std_logic;
    PHY_TEST_MODE             : in std_logic_vector(1 downto 0);
    PHY_POWER_DOWN            : in std_logic;
    PHY_STATUS                : out std_logic_vector(7 downto 0);
    PHY_STATUS2               : out std_logic_vector(7 downto 0);
    PHY_ID                    : out std_logic_vector(15 downto 0);

    MTU                       : in std_logic_vector(13 downto 0);

    -- SFP Module
    TXP                       : out std_logic;
    TXN                       : out std_logic;
    RXP                       : in std_logic;
    RXN                       : in std_logic
  );
end z7_10GbE_tcpip_client;

architecture synthesis of z7_10GbE_tcpip_client is

  impure function get_nudptx return integer is
  begin
    if UDP_TX_EN then
      return 1;
    else
      return 0;
    end if;
  end get_nudptx;
  
  impure function get_nudprx return integer is
  begin
    if UDP_RX_EN then
      return 1;
    else
      return 0;
    end if;
  end get_nudprx;
  
  component ten_gig_eth_pcs_pma_0
    port(
      rxrecclk_out : out std_logic;
      coreclk : in std_logic;
      dclk : in std_logic;
      txusrclk : in std_logic;
      txusrclk2 : in std_logic;
      areset : in std_logic;
      txoutclk : out std_logic;
      areset_coreclk : in std_logic;
      gttxreset : in std_logic;
      gtrxreset : in std_logic;
      txuserrdy : in std_logic;
      qplllock : in std_logic;
      qplloutclk : in std_logic;
      qplloutrefclk : in std_logic;
      reset_counter_done : in std_logic;
      txp : out std_logic;
      txn : out std_logic;
      rxp : in std_logic;
      rxn : in std_logic;
      sim_speedup_control : in std_logic;
      xgmii_txd : in std_logic_vector(63 downto 0);
      xgmii_txc : in std_logic_vector(7 downto 0);
      xgmii_rxd : out std_logic_vector(63 downto 0);
      xgmii_rxc : out std_logic_vector(7 downto 0);
      mdc : in std_logic;
      mdio_in : in std_logic;
      mdio_out : out std_logic;
      mdio_tri : out std_logic;
      prtad : in std_logic_vector(4 downto 0);
      core_status : out std_logic_vector(7 downto 0);
      tx_resetdone : out std_logic;
      rx_resetdone : out std_logic;
      signal_detect : in std_logic;
      tx_fault : in std_logic;
      drp_req : out std_logic;
      drp_gnt : in std_logic;
      drp_den_o : out std_logic;
      drp_dwe_o : out std_logic;
      drp_daddr_o : out std_logic_vector(15 downto 0);
      drp_di_o : out std_logic_vector(15 downto 0);
      drp_drdy_o : out std_logic;
      drp_drpdo_o : out std_logic_vector(15 downto 0);
      drp_den_i : in std_logic;
      drp_dwe_i : in std_logic;
      drp_daddr_i : in std_logic_vector(15 downto 0);
      drp_di_i : in std_logic_vector(15 downto 0);
      drp_drdy_i : in std_logic;
      drp_drpdo_i : in std_logic_vector(15 downto 0);
      tx_disable : out std_logic;
      pma_pmd_type : in std_logic_vector(2 downto 0);
      gt0_eyescanreset : in std_logic;
      gt0_eyescandataerror : out std_logic;
      gt0_txbufstatus : out std_logic_vector(1 downto 0);
      gt0_rxbufstatus : out std_logic_vector(2 downto 0);
      gt0_eyescantrigger : in std_logic;
      gt0_rxcdrhold : in std_logic;
      gt0_txprbsforceerr : in std_logic;
      gt0_txpolarity : in std_logic;
      gt0_rxpolarity : in std_logic;
      gt0_rxprbserr : out std_logic;
      gt0_txpmareset : in std_logic;
      gt0_rxpmareset : in std_logic;
      gt0_txresetdone : out std_logic;
      gt0_rxresetdone : out std_logic;
      gt0_rxdfelpmreset : in std_logic;
      gt0_rxlpmen : in std_logic;
      gt0_dmonitorout : out std_logic_vector(7 downto 0);
      gt0_rxrate : in std_logic_vector(2 downto 0);
      gt0_txprecursor : in std_logic_vector(4 downto 0);
      gt0_txpostcursor : in std_logic_vector(4 downto 0);
      gt0_txdiffctrl : in std_logic_vector(3 downto 0)
    );
  end component;

  -- PCS/PMA <-> MAC signals
  signal XGMII_TXD            : std_logic_vector(63 downto 0);
  signal XGMII_TXC            : std_logic_vector(7 downto 0);
  signal XGMII_RXD            : std_logic_vector(63 downto 0);
  signal XGMII_RXC            : std_logic_vector(7 downto 0);
  signal XGMII_RESET          : std_logic;
  signal XGMII_RESET_N        : std_logic;
  signal MDC                  : std_logic;
  signal MDIO_OUT             : std_logic;
  signal MDIO_IN              : std_logic;
  signal TX_RESETDONE         : std_logic;
  signal RX_RESETDONE         : std_logic;
  signal SIM_SPEEDUP_CONTROL  : std_logic := '0';

  -- MAC <-> TCP/UDP signals
  signal MAC_TX_DATA          : std_logic_vector(63 downto 0);
  signal MAC_TX_DATA_VALID    : std_logic_vector(7 downto 0);
  signal MAC_TX_EOF           : std_logic;
  signal MAC_TX_CTS           : std_logic;
  signal MAC_RX_DATA          : std_logic_vector(63 downto 0);
  signal MAC_RX_DATA_VALID    : std_logic_vector(7 downto 0);
  signal MAC_RX_SOF           : std_logic;
  signal MAC_RX_EOF           : std_logic;
  signal MAC_RX_FRAME_VALID   : std_logic;

  -- DRP signals
  signal DRP_REQ                  : std_logic;
  signal DRP_DEN                  : std_logic;
  signal DRP_DWE                  : std_logic;
  signal DRP_DADDR                : std_logic_vector(15 downto 0);
  signal DRP_DI                   : std_logic_vector(15 downto 0);
  signal DRP_DRDY                 : std_logic;
  signal DRP_DRPDO                : std_logic_vector(15 downto 0);

  signal TCP_STATE_REQUESTED_Q    : std_logic := '0';
  signal TCP_CONNECTED_FLAG_Q     : std_logic := '0';
  signal TCP_STATE_REQUESTED_loc  : std_logic := '0';
begin

  process(CLK)
  begin
    if rising_edge(CLK) then
      TCP_STATE_REQUESTED_Q <= TCP_STATE_REQUESTED;
      TCP_CONNECTED_FLAG_Q <= TCP_CONNECTED_FLAG;
      if (TCP_CONNECTED_FLAG = '0' and TCP_CONNECTED_FLAG_Q = '1') or (TCP_STATE_REQUESTED = '0' and TCP_STATE_REQUESTED_Q = '1') then
        TCP_STATE_REQUESTED_loc <= '0';
      elsif TCP_STATE_REQUESTED = '1' and TCP_STATE_REQUESTED_Q = '0' then
        TCP_STATE_REQUESTED_loc <= '1';
      end if;
    end if;
  end process;

  COM5503_inst: entity com5503_lib.COM5503
    generic map(
      NTCPSTREAMS           => 1,
      NUDPTX                => get_nudptx,
      NUDPRX                => get_nudprx,
      TCP_TX_WINDOW_SIZE    => TCP_TX_WINDOW_SIZE,
      TCP_RX_WINDOW_SIZE    => TCP_RX_WINDOW_SIZE,
      DHCP_CLIENT_EN        => '1',
      IPv6_ENABLED          => IPv6_ENABLED,
      IGMP_EN               => IGMP_EN,
      TX_IDLE_TIMEOUT       => TX_IDLE_TIMEOUT,
      TCP_KEEPALIVE_PERIOD  => TCP_KEEPALIVE_PERIOD,
      CLK_FREQUENCY         => 156,
      SIMULATION            => SIMULATION
    )
    port map(
      CLK                       => CLK,
      SYNC_RESET                => RESET_STACK,
      MAC_ADDR                  => MAC_ADDR,
      DYNAMIC_IPv4              => DYNAMIC_IPv4,
      REQUESTED_IPv4_ADDR       => IPv4_ADDR,
      IPv4_MULTICAST_ADDR       => IPv4_MULTICAST_ADDR,
      IPv4_SUBNET_MASK          => IPv4_SUBNET_MASK,
      IPv4_GATEWAY_ADDR         => IPv4_GATEWAY_ADDR,
      IPv6_ADDR                 => IPv6_ADDR,
      IPv6_SUBNET_PREFIX_LENGTH => IPv6_SUBNET_PREFIX_LENGTH,
      IPv6_GATEWAY_ADDR         => IPv6_GATEWAY_ADDR,
      TCP_DEST_IP_ADDR(0)       => TCP_DEST_IP_ADDR,
      TCP_DEST_IPv4_6n(0)       => TCP_DEST_IPv4_6n,
      TCP_DEST_PORT(0)          => TCP_DEST_PORT,
      TCP_STATE_REQUESTED(0)    => TCP_STATE_REQUESTED_loc,
      TCP_STATE_STATUS(0)       => TCP_STATE_STATUS,
      TCP_KEEPALIVE_EN(0)       => TCP_KEEPALIVE_EN,
      MAC_TX_DATA               => MAC_TX_DATA,
      MAC_TX_DATA_VALID         => MAC_TX_DATA_VALID,
      MAC_TX_SOF                => open,
      MAC_TX_EOF                => MAC_TX_EOF,
      MAC_TX_CTS                => MAC_TX_CTS,
      MAC_TX_RTS                => open,
      MAC_RX_DATA               => MAC_RX_DATA,
      MAC_RX_DATA_VALID         => MAC_RX_DATA_VALID,
      MAC_RX_SOF                => MAC_RX_SOF,
      MAC_RX_EOF                => MAC_RX_EOF,
      MAC_RX_FRAME_VALID        => MAC_RX_FRAME_VALID,
      UDP_RX_DATA               => UDP_RX_DATA,
      UDP_RX_DATA_VALID         => UDP_RX_DATA_VALID,
      UDP_RX_SOF                => UDP_RX_SOF,
      UDP_RX_EOF                => UDP_RX_EOF,
      UDP_RX_FRAME_VALID        => UDP_RX_FRAME_VALID,
      UDP_RX_DEST_PORT_NO_IN    => UDP_RX_DEST_PORT_NO_IN,
      CHECK_UDP_RX_DEST_PORT_NO => CHECK_UDP_RX_DEST_PORT_NO,
      UDP_RX_DEST_PORT_NO_OUT   => UDP_RX_DEST_PORT_NO_OUT,
      UDP_TX_DATA               => UDP_TX_DATA,
      UDP_TX_DATA_VALID         => UDP_TX_DATA_VALID,
      UDP_TX_SOF                => UDP_TX_SOF,
      UDP_TX_EOF                => UDP_TX_EOF,
      UDP_TX_CTS                => UDP_TX_CTS,
      UDP_TX_ACK                => UDP_TX_ACK,
      UDP_TX_NAK                => UDP_TX_NAK,
      UDP_TX_DEST_IP_ADDR       => UDP_TX_DEST_IP_ADDR,
      UDP_TX_DEST_IPv4_6n       => UDP_TX_DEST_IPv4_6n,
      UDP_TX_DEST_PORT_NO       => UDP_TX_DEST_PORT_NO,
      UDP_TX_SOURCE_PORT_NO     => UDP_TX_SOURCE_PORT_NO,
      TCP_LOCAL_PORTS(0)        => TCP_LOCAL_PORTS,
      TCP_RX_DATA(0)            => TCP_RX_DATA,
      TCP_RX_DATA_VALID(0)      => TCP_RX_DATA_VALID,
      TCP_RX_RTS(0)             => TCP_RX_RTS,
      TCP_RX_CTS(0)             => TCP_RX_CTS,
      TCP_RX_CTS_ACK(0)         => TCP_RX_CTS_ACK,
      TCP_TX_DATA(0)            => TCP_TX_DATA,
      TCP_TX_DATA_VALID(0)      => TCP_TX_DATA_VALID,
      TCP_TX_DATA_FLUSH(0)      => TCP_TX_DATA_FLUSH,
      TCP_TX_CTS(0)             => TCP_TX_CTS,
      TCP_CONNECTED_FLAG(0)     => TCP_CONNECTED_FLAG,
      MTU                       => MTU,
      CS1                       => open,
      CS1_CLK                   => open,
      CS2                       => open,
      CS2_CLK                   => open,
      DEBUG1                    => open,
      DEBUG2                    => open,
      DEBUG3                    => open,
      TP                        => open--,
--        COM5503_DEBUG             => COM5503_DEBUG,
--        COM5503_TCP_CLIENTS_DEBUG => COM5503_TCP_CLIENTS_DEBUG,
--        COM5503_TCP_TXBUF_DEBUG   => COM5503_TCP_TXBUF_DEBUG
   );

  COM5501_inst: entity com5501_lib.COM5501
    generic map(
      EXT_PHY_MDIO_ADDR         => "00000",
      RX_BUFFER                 => '0',
      RX_BUFFER_ADDR_NBITS      => 1,
      TX_BUFFER                 => '0',
      TX_BUFFER_ADDR_NBITS      => 0,
      MAC_CONTROL_PAUSE_ENABLE  => '1',
      SIMULATION                => '0'
    )
    port map(
      CLK                   => CLK,
      SYNC_RESET            => RESET_MAC,
      CLK156g               => CLK,
      MAC_TX_CONFIG         => "00000011",
      MAC_RX_CONFIG         => "00001111",
      MAC_ADDR              => MAC_ADDR,
      MAC_TX_DATA           => MAC_TX_DATA,
      MAC_TX_DATA_VALID     => MAC_TX_DATA_VALID,
      MAC_TX_EOF            => MAC_TX_EOF,
      MAC_TX_CTS            => MAC_TX_CTS,
      MAC_RX_DATA           => MAC_RX_DATA,
      MAC_RX_DATA_VALID     => MAC_RX_DATA_VALID,
      MAC_RX_SOF            => MAC_RX_SOF,
      MAC_RX_EOF            => MAC_RX_EOF,
      MAC_RX_FRAME_VALID    => MAC_RX_FRAME_VALID,
      MAC_RX_CTS            => '1',
      XGMII_TXD             => XGMII_TXD,
      XGMII_TXC             => XGMII_TXC,
      XGMII_RXD             => XGMII_RXD,
      XGMII_RXC             => XGMII_RXC,
      RESET_N               => XGMII_RESET_N,
      MDC                   => MDC,
      MDIO_OUT              => MDIO_IN,
      MDIO_IN               => MDIO_OUT,
      MDIO_DIR              => open,
      PHY_CONFIG_CHANGE     => PHY_CONFIG_CHANGE,
      PHY_RESET             => PHY_RESET,
      TEST_MODE             => PHY_TEST_MODE,
      POWER_DOWN            => PHY_POWER_DOWN,
      PHY_STATUS            => PHY_STATUS,
      PHY_STATUS2           => PHY_STATUS2,
      PHY_ID                => PHY_ID,
      N_TX_FRAMES           => MAC_N_TX_FRAMES,
      N_RX_FRAMES           => MAC_N_RX_FRAMES,
      N_RX_BAD_CRCS         => MAC_N_RX_BAD_CRCS,
      N_RX_FRAMES_TOO_SHORT => MAC_N_RX_FRAMES_TOO_SHORT,
      N_RX_FRAMES_TOO_LONG  => MAC_N_RX_FRAMES_TOO_LONG,
      N_RX_WRONG_ADDR       => MAC_N_RX_WRONG_ADDR,
      N_RX_LENGTH_ERRORS    => MAC_N_RX_LENGTH_ERRORS,
      RX_IPG                => MAC_RX_IPG,
      TX_MTU                => MTU,
      RX_MTU                => MTU,
      DEBUG1                => open,
      DEBUG2                => open,
      DEBUG3                => open,
      TP                    => open
   );

  XGMII_RESET <= not XGMII_RESET_N;

  sim_true: if SIMULATION = '1' generate
    process
    begin
      SIM_SPEEDUP_CONTROL <= '0';
      wait for 200 ns;
      SIM_SPEEDUP_CONTROL <= '1';
      wait;
    end process;
  end generate;

  ten_gig_eth_pcs_pma_0_inst: ten_gig_eth_pcs_pma_0
    port map(
      RXRECCLK_OUT          => open,
      CORECLK               => CLK,
      DCLK                  => CLK,
      TXUSRCLK              => TXUSRCLK,
      TXUSRCLK2             => TXUSRCLK2,
      ARESET                => XGMII_RESET,
      TXOUTCLK              => TXOUTCLK,
      ARESET_CORECLK        => ARESET_CORECLK,
      GTTXRESET             => GTTXRESET,
      GTRXRESET             => GTRXRESET,
      TXUSERRDY             => TXUSERRDY,
      QPLLLOCK              => QPLLLOCK,
      QPLLOUTCLK            => QPLLOUTCLK,
      QPLLOUTREFCLK         => QPLLOUTREFCLK,
      RESET_COUNTER_DONE    => RESET_COUNTER_DONE,
      TXP                   => TXP,
      TXN                   => TXN,
      RXP                   => RXP,
      RXN                   => RXN,
      SIM_SPEEDUP_CONTROL   => SIM_SPEEDUP_CONTROL,
      XGMII_TXD             => XGMII_TXD,
      XGMII_TXC             => XGMII_TXC,
      XGMII_RXD             => XGMII_RXD,
      XGMII_RXC             => XGMII_RXC,
      MDC                   => MDC,
      MDIO_IN               => MDIO_IN,
      MDIO_OUT              => MDIO_OUT,
      MDIO_TRI              => open,
      PRTAD                 => "00000",
      CORE_STATUS           => PCS_CORE_STATUS,
      TX_RESETDONE          => TX_RESETDONE,
      RX_RESETDONE          => RX_RESETDONE,
      SIGNAL_DETECT         => SIGNAL_DETECT,
      TX_FAULT              => TX_FAULT,
      DRP_REQ               => DRP_REQ,
      DRP_GNT               => DRP_REQ,
      DRP_DEN_O             => DRP_DEN,
      DRP_DWE_O             => DRP_DWE,
      DRP_DADDR_O           => DRP_DADDR,
      DRP_DI_O              => DRP_DI,
      DRP_DRDY_O            => DRP_DRDY,
      DRP_DRPDO_O           => DRP_DRPDO,
      DRP_DEN_I             => DRP_DEN,
      DRP_DWE_I             => DRP_DWE,
      DRP_DADDR_I           => DRP_DADDR,
      DRP_DI_I              => DRP_DI,
      DRP_DRDY_I            => DRP_DRDY,
      DRP_DRPDO_I           => DRP_DRPDO,
      TX_DISABLE            => TX_DISABLE,
      PMA_PMD_TYPE          => PMA_PMD_TYPE,
      GT0_EYESCANRESET      => '0',
      GT0_EYESCANDATAERROR  => open,
      GT0_TXBUFSTATUS       => open,
      GT0_RXBUFSTATUS       => open,
      GT0_EYESCANTRIGGER    => '0',
      GT0_RXCDRHOLD         => '0',
      GT0_TXPRBSFORCEERR    => '0',
      GT0_TXPOLARITY        => TXPOLARITY,
      GT0_RXPOLARITY        => RXPOLARITY,
      GT0_RXPRBSERR         => open,
      GT0_TXPMARESET        => '0',
      GT0_RXPMARESET        => '0',
      GT0_TXRESETDONE       => open,
      GT0_RXRESETDONE       => open,
      GT0_RXDFELPMRESET     => '0',
      GT0_RXLPMEN           => '0',
      GT0_DMONITOROUT       => open,
      GT0_RXRATE            => "000",
      GT0_TXPRECURSOR       => "00000",
      GT0_TXPOSTCURSOR      => "00000",
      GT0_TXDIFFCTRL        => "1110"
    );

end synthesis;
