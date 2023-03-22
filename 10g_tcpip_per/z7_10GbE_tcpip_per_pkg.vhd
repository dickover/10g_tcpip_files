library ieee;
use ieee.std_logic_1164.all;

library utils;
use utils.utils_pkg.all;

library per_lib;
use per_lib.perbus_pkg.all;

use work.pcspma_shared_pkg.all;

package z7_10GbE_tcpip_per_pkg is

  component z7_10GbE_tcpip_per is
    generic(
      ADDR_INFO             : PER_ADDR_INFO;
      SIMULATION            : std_logic := '0';
      TCP_TX_WINDOW_SIZE    : integer;
      TCP_RX_WINDOW_SIZE    : integer;
      UDP_TX_EN             : boolean := false;
      UDP_RX_EN             : boolean := false;
      TX_IDLE_TIMEOUT       : integer := 50;
      TCP_KEEPALIVE_PERIOD  : integer := 60;
      SERVER                : boolean;
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
  end component;
  
end z7_10GbE_tcpip_per_pkg;
