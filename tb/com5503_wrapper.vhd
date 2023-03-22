library ieee;
use ieee.std_logic_1164.all;

library utils;
use utils.utils_pkg.all;

library com5501_lib;
library com5503_lib;
use com5503_lib.com5502pkg.all;

entity com5503_wrapper is
  port(
    -- 156.25MHz
    CLK                       : in std_logic;
    -- reset pulse must be > slowest clock period  (>400ns)
    -- synchronous with CLK
    RESET_MAC                 : in std_logic;
    RESET_STACK               : in std_logic;

    -- IP signals
    IPv4_ADDR                 : in std_logic_vector(31 downto 0);
    IPv4_SUBNET_MASK          : in std_logic_vector(31 downto 0);
    TCP_DEST_IP_ADDR          : in slv128a(NTCPSTREAMS-1 downto 0);
    TCP_DEST_PORT             : in slv16a(NTCPSTREAMS-1 downto 0);
    TCP_STATE_REQUESTED       : in std_logic_vector(NTCPSTREAMS-1 downto 0);
    TCP_STATE_STATUS          : out slv4a(NTCPSTREAMS-1 downto 0);
    CONNECTION_RESET          : in std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_KEEPALIVE_EN          : in std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_LOCAL_PORTS           : in slv16a(NTCPSTREAMS-1 downto 0);
    TCP_RX_DATA               : out slv64a(NTCPSTREAMS-1 downto 0);
    TCP_RX_DATA_VALID         : out slv8a(NTCPSTREAMS-1 downto 0);
    TCP_RX_RTS                : out std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_RX_CTS                : in std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_RX_CTS_ACK            : out std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_TX_DATA               : in slv64a(NTCPSTREAMS-1 downto 0);
    TCP_TX_DATA_VALID         : in slv8a(NTCPSTREAMS-1 downto 0);
    TCP_TX_DATA_FLUSH         : in std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_TX_CTS                : out std_logic_vector((NTCPSTREAMS-1) downto 0);
    TCP_CONNECTED_FLAG        : out std_logic_vector((NTCPSTREAMS-1) downto 0);
  );
end com5503_wrapper;

architecture testbench of com5503_wrapper is
begin
    
  COM5503_inst: entity com5503_lib.COM5503
    generic map(
      NTCPSTREAMS           => 1,
      NUDPTX                => 0,
      NUDPRX                => 0,
      MTU                   => 1500,
      TCP_TX_WINDOW_SIZE    => 12,
      TCP_RX_WINDOW_SIZE    => 11,
      DHCP_CLIENT_EN        => '0',
      IPv6_ENABLED          => '0',
      IGMP_EN               => '0',
      TX_IDLE_TIMEOUT       => 50,
      TCP_KEEPALIVE_PERIOD  => 60,
      CLK_FREQUENCY         => 156,
      SIMULATION            => '0'
    )
    port map(
      CLK                       => CLK,
      SYNC_RESET                => RESET_STACK,
      MAC_ADDR                  => MAC_ADDR,
      DYNAMIC_IPv4              => '0',
      REQUESTED_IPv4_ADDR       => IPv4_ADDR,
      IPv4_MULTICAST_ADDR       => (others=>'0'),
      IPv4_SUBNET_MASK          => IPv4_SUBNET_MASK,
      IPv4_GATEWAY_ADDR         => (others=>'0'),
      IPv6_ADDR                 => (others=>'0'),
      IPv6_SUBNET_PREFIX_LENGTH => (others=>'0'),
      IPv6_GATEWAY_ADDR         => (others=>'0'),
      TCP_DEST_IP_ADDR          => TCP_DEST_IP_ADDR,
      TCP_DEST_IPv4_6n          => '1',
      TCP_DEST_PORT             => TCP_DEST_PORT,
      TCP_STATE_REQUESTED       => TCP_STATE_REQUESTED,
      TCP_STATE_STATUS          => TCP_STATE_STATUS,
      TCP_KEEPALIVE_EN          => '1',
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
      TCP_LOCAL_PORTS           => TCP_LOCAL_PORTS_loc,
      TCP_RX_DATA               => TCP_RX_DATA_loc,
      TCP_RX_DATA_VALID         => TCP_RX_DATA_VALID_loc,
      TCP_RX_RTS                => TCP_RX_RTS,
      TCP_RX_CTS                => TCP_RX_CTS,
      TCP_RX_CTS_ACK            => TCP_RX_CTS_ACK,
      TCP_TX_DATA               => TCP_TX_DATA_loc,
      TCP_TX_DATA_VALID         => TCP_TX_DATA_VALID_loc,
      TCP_TX_DATA_FLUSH         => TCP_TX_DATA_FLUSH,
      TCP_TX_CTS                => TCP_TX_CTS,
      TCP_CONNECTED_FLAG        => TCP_CONNECTED_FLAG_loc,
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
      RX_MTU                    => MTU,
      RX_BUFFER                 => '0',
      RX_BUFFER_ADDR_NBITS      => 1,
      TX_MTU                    => MTU,
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
      RESET_N               => open,
      MDC                   => open,
      MDIO_OUT              => open,,
      MDIO_IN               => '1',
      MDIO_DIR              => open,
      PHY_CONFIG_CHANGE     => '0',
      PHY_RESET             => '0',
      TEST_MODE             => "00",
      POWER_DOWN            => '0',
      PHY_STATUS            => open,
      PHY_STATUS2           => open,
      PHY_ID                => open,
      N_TX_FRAMES           => open,
      N_RX_FRAMES           => open,
      N_RX_BAD_CRCS         => open,
      N_RX_FRAMES_TOO_SHORT => open,
      N_RX_FRAMES_TOO_LONG  => open,
      N_RX_WRONG_ADDR       => open,
      N_RX_LENGTH_ERRORS    => open,
      RX_IPG                => open,
      DEBUG1                => open,
      DEBUG2                => open,
      DEBUG3                => open,
      TP                    => open
   );

  XGMII_RESET <= not XGMII_RESET_N;

end testbench;

