library ieee;
use ieee.std_logic_1164.all;

package pcspma_shared_pkg is

  type PCS_PMA_SHARED_TYPE is record
    TXUSRCLK            : std_logic;
    TXUSRCLK2           : std_logic;
    ARESET_CORECLK      : std_logic;
    GTTXRESET           : std_logic;
    GTRXRESET           : std_logic;
    TXUSERRDY           : std_logic;
    QPLLLOCK            : std_logic;
    QPLLOUTCLK          : std_logic;
    QPLLOUTREFCLK       : std_logic;
    RESET_COUNTER_DONE  : std_logic;
  end record;

end pcspma_shared_pkg;
