-------------------------------------------------------------
-- MSS copyright 2019-2021
-- Filename:  TCP_RXBUFNDEMUX2_10G.VHD
-- Author: Alain Zarembowitch / MSS
-- Version: 3b
-- Date last modified: 3/13/21 AZ
-- Inheritance: COM-5402SOFT TCP_RXBUFNDEMUX2.VHD rev2 12/8/15
--
-- description:  This component has two objectives:
-- (1) tentatively hold a received TCP frame on the fly until its validity is confirmed at the end of frame.
-- Discard if invalid or further process if valid.
-- (2) demultiplex multiple TCP streams, based on the destination port number
-- 10G version. Portable.
--
-- Because of the TCP protocol, data can only be validated at the end of a packet.
-- So the buffer management has to be able to backtrack, discard previous data and 
-- reposition pointer. 
--
-- The overall buffer size (which affects overall throughput) is user selected in the generic section.
-- This component is written of a single TCP stream.
--
-- This component is written for NTCPSTREAMS TCP tx streams. Adjust as needed in the com5402pkg package.
-- 
-- Note: This component should work in all application case, at the expense of many block RAM. 
-- Use the more efficient TCP_RXBUFNDEMUX only when the application is reading data faster than the data source
-- and when RAMBs are at a premium.
--
-- Rev1 4/25/19 AZ
-- Corrected bug regarding RX_APP_DATA_VALID
-- Corrected sensitivity lists
-- Corrected bug regarding BUF_SIZE. 
--
-- Rev2 12/13/20 AZ
-- Corrected issue about word alignment
--
-- Rev3 1/15/21 AZ
-- Increased RX_FREE_SPACE to 32-bit in preparation for window scaling.
--
-- Rev 3b 3/13/21 AZ
-- Improved resilience to bad CRC frame
--
-- Minimum period: 4.537ns (Maximum Frequency: 220.410MHz)
-- FF: 386
-- LUT: 583
-- BRAM: 4
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.com5502pkg.all;	-- defines global types, number of TCP streams, etc

entity TCP_RXBUFNDEMUX2_10G is
	generic (
		NTCPSTREAMS: integer := 1;  
			-- number of concurrent TCP streams handled by this component
		ADDR_WIDTH: integer range 8 to 27:= 11
			-- size of the dual-port RAM buffers instantiated within for each stream = 64b * 2^ADDR_WIDTH
			-- Trade-off buffer depth and overall TCP throughput.
			-- Recommended value for 10GbE: at least 11 
	);
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;		-- synchronous clock	
			-- Must be global clocks. No BUFG instantiation within this component.

		--// TCP RX protocol -> RX BUFFER 
		RX_DATA: in std_logic_vector(63 downto 0);
			-- TCP payload data field. Each byte validity is in RX_DATA_VALID(I)
			-- IMPORTANT: always left aligned (MSB first): RX_DATA_VALID is x80,xc0,xe0,xf0,....x01,x00 
		RX_DATA_VALID: in std_logic_vector(7 downto 0);
			-- delineates the TCP payload data field
		RX_SOF: in std_logic;
			-- 1st word of RX_DATA
			-- Read ancillary information at this time:
			-- (a) destination RX_STREAM_NO (based on the destination TCP port)
		RX_TCP_STREAM_SEL: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- stream number based on the destination TCP port
		RX_EOF: in std_logic;
			-- 1 CLK pulse indicating that RX_DATA is the last byte in the TCP data field.
			-- ALWAYS CHECK RX_FRAME_VALID at the end of packet (RX_EOF = '1') to confirm
			-- that the TCP packet is valid. 
			-- Note: All packet information stored is tentative until
			-- the entire frame is confirmed (RX_EOF = '1') and (RX_FRAME_VALID = '1').
			-- MSbs are dropped.
			-- If the frame is invalid, the data and ancillary information just received is discarded.
			-- Reason: we only knows about bad TCP packets at the end.
		RX_FRAME_VALID: in std_logic;
			-- verify the entire frame validity at the end of frame (RX_EOF = '1')
		RX_FREE_SPACE: out SLV32xNTCPSTREAMStype;
			-- buffer available space, expressed in bytes. 
			-- Beware of delay (as data may be in transit and information is slightly old).
		RX_BUF_CLR: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- '1' to clear the elastic buffer (for example after closing the connection)
		
		--// RX BUFFER -> APPLICATION INTERFACE
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
		-- Usage: RX_APP_RTS goes high when at least one byte is in the output queue (i.e. not yet visible at the
		-- output RX_APP_DATA). The application should then raise RX_APP_CTS for one clock to fetch the next word 2 CLKs later.
		-- Note that the next word may be partial (<8 bytes) or full.
		-- RX_APP_DATA and RX_APP_DATA_VALID are updated automatically without the application intervention as the 
		-- 8-byte output is being filled.
		-- Thus, the application may have to check periodically RX_APP_DATA_VALID while waiting for the complete 8 bytes.
		-- RX_APP_CTS pulse will cause a move to the next word IF AND ONLY IF the next word has at least one available byte.
		RX_APP_DATA: out SLV64xNTCPSTREAMStype;
		RX_APP_DATA_VALID: out SLV8xNTCPSTREAMStype;
		RX_APP_RTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_CTS: in std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- 1 CLK pulse to read the next (partial) word RX_APP_DATA
			-- Latency: 2 CLKs to RX_APP_DATA, but only IF AND ONLY IF the next word has at least one available byte.
		RX_APP_CTS_ACK: out std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- '1' the RX_APP_CTS request for new data is accepted:
			-- indicating that a new (maybe partial) word will be placed on the output RX_APP_DATA at the next CLK.


		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_RXBUFNDEMUX2_10G is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT BRAM_DP2
	GENERIC(
		DATA_WIDTHA: integer;
		ADDR_WIDTHA: integer;
		DATA_WIDTHB: integer;
		ADDR_WIDTHB: integer
	);
	PORT(
		CLKA   : in  std_logic;
		CSA: in std_logic;	
		WEA    : in  std_logic;	
		OEA    : in  std_logic;	
		ADDRA  : in  std_logic_vector(ADDR_WIDTHA-1 downto 0);
		DIA   : in  std_logic_vector(DATA_WIDTHA-1 downto 0);
		DOA  : out std_logic_vector(DATA_WIDTHA-1 downto 0);
		CLKB   : in  std_logic;
		CSB: in std_logic;	
		WEB    : in  std_logic;	
		OEB    : in  std_logic;	
		ADDRB  : in  std_logic_vector(ADDR_WIDTHB-1 downto 0);
		DIB   : in  std_logic_vector(DATA_WIDTHB-1 downto 0);
		DOB  : out std_logic_vector(DATA_WIDTHB-1 downto 0)
		);
	END COMPONENT;
	
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal RESETn: std_logic := '0';
signal RESET_CNTR: unsigned(2 downto 0)  := (others => '0');

-- freeze ancilliary input data at the SOF
signal RX_TCP_STREAM_SEL_D: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');

--//-- ELASTIC BUFFER ---------------------------
signal RX_DATA_SHIFT: std_logic_vector(127 downto 0) := (others => '0');
signal RX_DATA_VALID1: std_logic_vector(15 downto 0) := (others => '0');
signal RX_DATA_REMAIN: std_logic_vector(63 downto 0) := (others => '0');
signal RX_DATA_REMAIN_VALID: std_logic_vector(7 downto 0) := (others => '0');
--signal FLUSH_RX_DATA_REMAIN: std_logic := '0';
signal RX_DATA_D: std_logic_vector(63 downto 0) := (others => '0');
signal RX_DATA_VALID_D: std_logic_vector(7 downto 0) := (others => '0');
signal RX_SOF_D: std_logic := '0';
signal RX_EOF_D: std_logic := '0';
signal RX_EOF_D2: std_logic := '0';
signal RX_EOF_D3: std_logic := '0';
signal RX_WORD_VALID_D: std_logic := '0';
signal RX_WORD_VALID_D2: std_logic := '0';
signal RX_FRAME_VALID_D: std_logic := '0';
signal RX_FRAME_VALID_D2: std_logic := '0';
signal WPTR_INCREMENT: integer range 0 to 8 := 0;
signal WPTRA_E: unsigned(ADDR_WIDTH+3 downto 0) := (others => '0');
signal WPTRA: unsigned(ADDR_WIDTH+3 downto 0) := (others => '0');
signal WPTRAb3_D: std_logic := '0';
signal RPTRA: unsigned(ADDR_WIDTH+3 downto 0) := (others => '0');
signal ADDRA: std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
signal WEA: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
signal DIA: std_logic_vector(63 downto 0) := (others => '0');
type PTRtype is array (integer range 0 to (NTCPSTREAMS-1)) of unsigned(ADDR_WIDTH+3 downto 0);
signal WPTR0: PTRtype := (others => (others => '0'));
signal WPTR_CONFIRMED: PTRtype := (others => (others => '0'));
signal RPTR: PTRtype := (others => (others => '0'));
signal RPTR_MIN: PTRtype := (others => (others => '0'));
signal BUF_SIZE: PTRtype := (others => (others => '0'));
signal BUF_SIZE_D: PTRtype := (others => (others => '0'));
type DOtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(63 downto 0);
signal DOA: DOtype := (others => (others => '0'));
signal DOB: DOtype := (others => (others => '0'));
signal FIRST_APP_DATA: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
signal RX_APP_RTS_local: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
signal RX_APP_CTS_ACK_local: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');
signal RX_APP_CTS_ACK_D: std_logic_vector(NTCPSTREAMS-1 downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin
-- create a local reset (because we want RPTR to be initialized to all '1's among other things
RESETN_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(RESET_CNTR(RESET_CNTR'left) = '0') then
			RESET_CNTR <= RESET_CNTR + 1;
		end if;
	end if;
end process;
RESETn <= RESET_CNTR(RESET_CNTR'left);

-- freeze ancilliary data at the SOF
FREEZE_INPUT: process(CLK) 
begin
	if rising_edge(CLK) then
		if(RX_SOF = '1') then
			RX_TCP_STREAM_SEL_D <= RX_TCP_STREAM_SEL;
		end if;
	end if;
end process;

-- clean unused input bytes (because of follow-on ORing)
-- Justification: TCP_SERVER_10G does a sloppy job filtering out unnecessary bytes
CLEAN_INPUT: process(CLK) 
begin
	if rising_edge(CLK) then
		RX_DATA_VALID_D <= RX_DATA_VALID;
		RX_SOF_D <= RX_SOF;
		RX_EOF_D <= RX_EOF;
		RX_EOF_D2 <= RX_EOF_D;
		RX_EOF_D3 <= RX_EOF_D2;
		RX_FRAME_VALID_D <= RX_FRAME_VALID;
		RX_FRAME_VALID_D2 <= RX_FRAME_VALID_D;
		RX_WORD_VALID_D <= RX_DATA_VALID(7);
		RX_WORD_VALID_D2 <= RX_WORD_VALID_D;
        
	   for I in 0 to 7 loop
			if(RX_DATA_VALID(I) = '1') then
				RX_DATA_D(8*I+7 downto 8*I) <= RX_DATA(8*I+7 downto 8*I);
			else
				RX_DATA_D(8*I+7 downto 8*I) <= x"00";
			end if;
	   end loop;

	end if;
end process;


--//-- ELASTIC BUFFER ---------------------------
-- write pointer management. 
WPTR_GEN_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if(RX_DATA_VALID(0) = '1') then
			WPTR_INCREMENT <= 8;
		elsif(RX_DATA_VALID(1) = '1') then
			WPTR_INCREMENT <= 7;
		elsif(RX_DATA_VALID(2) = '1') then
			WPTR_INCREMENT <= 6;
		elsif(RX_DATA_VALID(3) = '1') then
			WPTR_INCREMENT <= 5;
		elsif(RX_DATA_VALID(4) = '1') then
			WPTR_INCREMENT <= 4;
		elsif(RX_DATA_VALID(5) = '1') then
			WPTR_INCREMENT <= 3;
		elsif(RX_DATA_VALID(6) = '1') then
			WPTR_INCREMENT <= 2;
		elsif(RX_DATA_VALID(7) = '1') then
			WPTR_INCREMENT <= 1;
		else
			WPTR_INCREMENT <= 0;
		end if;
	end if;
end process;

-- 
WPTR_GEN_002a: process(CLK)
begin
	if rising_edge(CLK) then
		WPTRAb3_D <= WPTRA(3);
		
		if(SYNC_RESET = '1') or (RX_EOF_D3 = '1') then
			WPTRA_E <= (others => '0');
			WPTRA <= (others => '0');
		elsif(RX_SOF = '1') then
			-- for each received frame, position the write pointer as per the last confirmed pointer position
			for I in 0 to NTCPSTREAMS-1 loop
			     if(RX_TCP_STREAM_SEL(I) = '1') then
						WPTRA_E <= WPTR_CONFIRMED(I);
			     end if;
		    end loop;
		elsif(RX_WORD_VALID_D = '1') then
		   -- about to write at least one payload byte
			-- prepare the next address
			WPTRA_E <= WPTRA_E + WPTR_INCREMENT;
			WPTRA <= WPTRA_E;
		else
			WPTRA <= WPTRA_E;
		end if;
	end if;
end process;

WPTR_GEN_X: for I in 0 to NTCPSTREAMS-1 generate
	WPTR_GEN_002b: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				WPTR_CONFIRMED(I) <= (others => '0');
			elsif(RX_TCP_STREAM_SEL_D(I) = '1') then
				if(RX_BUF_CLR(I) = '1')  then
					WPTR_CONFIRMED(I) <= (others => '0');
				elsif (RX_EOF_D2 = '1') and (RX_FRAME_VALID_D2 = '1') then
					-- last frame confirmed valid. Remember the writer position (next location to write to)
					WPTR_CONFIRMED(I) <= WPTRA_E;
				end if;
			end if;

			-- keep track if this is the first output data for this session/stream
			-- Any output data before that is meaningless.
			if(SYNC_RESET = '1') or (RX_BUF_CLR(I) = '1') then
				FIRST_APP_DATA(I) <= '0';
			elsif(RX_APP_CTS_ACK_local(I) = '1') then
				-- first output data will appear at the next clock
				FIRST_APP_DATA(I) <= '1';
			end if;
		end if;
	end process;
end generate;

-- remember the wptr for each stream (we need it to compute free space)
WPTR_GEN_003: FOR I in 0 to (NTCPSTREAMS-1) generate
	WPTR_GEN_002: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') or (RX_BUF_CLR(I) = '1') then
				WPTR0(I) <= (others => '0');
			elsif(RX_TCP_STREAM_SEL_D(I) = '1') and (RX_WORD_VALID_D = '1')  then
				WPTR0(I) <= WPTRA_E + WPTR_INCREMENT;
			end if;
		end if;
	end process;
end generate;

-- shift input word depending on the next write byte address WPTRA(2 downto 0)
-- ready at RX_DATA_VALID_D2
SHIFT_RX_DATA_IN_001:process(CLK)
begin
    if rising_edge(CLK) then
         if(RX_SOF = '1') or (RX_EOF_D2 = '1') then
            RX_DATA_VALID1 <= (others => '0');
            RX_DATA_SHIFT <= (others => '0');
         elsif(RX_WORD_VALID_D = '1') then
           -- at RX_WORD_VALID_D
           case(WPTRA_E(2 downto 0)) is
                when "000" => RX_DATA_SHIFT <= RX_DATA_D & x"0000000000000000";
                            RX_DATA_VALID1 <= RX_DATA_VALID_D & "00000000";
                when "001" => RX_DATA_SHIFT <= x"00" & RX_DATA_D & x"00000000000000";
                            RX_DATA_VALID1 <= "0" & RX_DATA_VALID_D & "0000000";
                when "010" => RX_DATA_SHIFT <= x"0000" & RX_DATA_D & x"000000000000";
                            RX_DATA_VALID1 <= "00" & RX_DATA_VALID_D & "000000";                          
                when "011" => RX_DATA_SHIFT <= x"000000" & RX_DATA_D & x"0000000000";
                            RX_DATA_VALID1 <= "000" & RX_DATA_VALID_D & "00000";
                when "100" => RX_DATA_SHIFT <= x"00000000" & RX_DATA_D & x"00000000";
                            RX_DATA_VALID1 <= "0000" & RX_DATA_VALID_D & "0000";
                when "101" => RX_DATA_SHIFT <= x"0000000000" & RX_DATA_D & x"000000";
                            RX_DATA_VALID1 <= "00000" & RX_DATA_VALID_D & "000";	
                when "110" => RX_DATA_SHIFT <= x"000000000000" & RX_DATA_D & x"0000";
                            RX_DATA_VALID1 <= "000000" & RX_DATA_VALID_D & "00";
                when others => RX_DATA_SHIFT <= x"00000000000000" & RX_DATA_D & x"00";
                            RX_DATA_VALID1 <= "0000000" & RX_DATA_VALID_D & "0";    
            end case;
        end if;
        
			-- At the start of frame, we need to re-initialize RX_DATA_REMAIN as two successive frames
			-- may target different streams
			-- This is to avoid storing RX_DATA_REMAIN for each stream
         if (RX_EOF_D3 = '1') then
				-- cleaner
            RX_DATA_REMAIN <= (others => '0');
			elsif(RX_SOF_D = '1') then	-- *121320, *031321
				if (WPTRA_E(2 downto 0) /= "000") then
				-- read previous remainder if it exists
				for I in 0 to NTCPSTREAMS-1 loop
					if(RX_TCP_STREAM_SEL_D(I) = '1') then
						RX_DATA_REMAIN <= DOA(I);
					end if;
				end loop;
				else
					-- reset RX_DATA_REMAIN as it may have been not have been if previous frame was corrupted (bad CRC for instance). G.M. email 031121
					RX_DATA_REMAIN <= (others => '0');
				end if;
         elsif((RX_WORD_VALID_D2 = '1') and (RX_DATA_VALID1(8) = '1')) then
				-- writing complete word to memory. shift remaining bytes to the left
				RX_DATA_REMAIN <= RX_DATA_SHIFT(63 downto 0);
				RX_DATA_REMAIN_VALID <= RX_DATA_VALID1(7 downto 0);
         elsif(RX_WORD_VALID_D2 = '1') and (RX_DATA_VALID1(8) = '0') then
			  -- not enough new bytes to fill a 8-byte word and write to memory. No shift
			  RX_DATA_REMAIN <= DIA(63 downto 0);
			  RX_DATA_REMAIN_VALID <= RX_DATA_VALID1(15 downto 8);
			else
			  RX_DATA_REMAIN_VALID <= (others => '0');
         end if;
   end if;
end process;

-- create new hybrid word to write to memory
DIA <= RX_DATA_REMAIN or RX_DATA_SHIFT(127 downto 64);

-- Need to flush the last few bytes in RX_DATA_REMAIN 
--FLUSH_001: process(CLK)
--begin
--    if rising_edge(CLK) then
--         if(RX_EOF_D2 = '1') and (RX_DATA_VALID1(15) = '1') then
--            FLUSH_RX_DATA_REMAIN <= '1';
--         else
--            FLUSH_RX_DATA_REMAIN <= '0';
--         end if;
--   end if;
--end process;

-- select which RAMBlock to write to.
WEA_GENx: process(RX_TCP_STREAM_SEL_D, RX_EOF_D3, RX_DATA_REMAIN_VALID, WPTRA, WPTRAb3_D, RX_WORD_VALID_D2)
begin
    for I in 0 to (NTCPSTREAMS-1) loop
        if(RX_TCP_STREAM_SEL_D(I) = '1') then
				if(RX_EOF_D3 = '1') and (RX_DATA_REMAIN_VALID /= x"00") and (WPTRA(3) /= WPTRAb3_D) then
					-- Write flush remainder at RX_EOF_D3, when remainder is not empty and spills over the next 64-bit word
					WEA(I) <= '1';
				elsif(RX_WORD_VALID_D2 = '1') then
					-- Write partial or full word. 
					WEA(I) <= '1';
				else
					WEA(I) <= '0';
				end if;
        else
            WEA(I) <= '0';
        end if;
    end loop;
end process;

-- read the last (partial) word at the SOF, before writing the frame first (partial) word.
ADDRA_GEN_001: process(RX_TCP_STREAM_SEL, WPTR_CONFIRMED)
variable RPTRAv: unsigned(ADDR_WIDTH+3 downto 0);
begin
    -- for each received frame, position the write pointer as per the last confirmed pointer position
	 RPTRAv := (others => '0');
    for I in 0 to NTCPSTREAMS-1 loop
         if(RX_TCP_STREAM_SEL(I) = '1') then
             RPTRAv := WPTR_CONFIRMED(I);   
         end if;
    end loop;
	 RPTRA <= RPTRAv;
end process;

ADDRA_GEN: process(RPTRA, RX_SOF, WPTRA)
begin
    if(RX_SOF = '1') then
        ADDRA <= std_logic_vector(RPTRA(ADDR_WIDTH+2 downto 3));
    else
        ADDRA <= std_logic_vector(WPTRA(ADDR_WIDTH+2 downto 3));
    end if;
end process;

-- Latency 1 CLK from ADDRx to DOx
BRAM_DP2_X: for I in 0 to (NTCPSTREAMS-1) generate
    BRAM_DP2_001: BRAM_DP2
    GENERIC MAP(
        DATA_WIDTHA => 64,		
        ADDR_WIDTHA => ADDR_WIDTH,
        DATA_WIDTHB => 64,		 
        ADDR_WIDTHB => ADDR_WIDTH

    )
    PORT MAP(
        CSA => '1',
        CLKA => CLK,
        WEA => WEA(I),      -- Port A Write Enable Input
		  OEA => '1',
        ADDRA => ADDRA,  -- Port A  Address Input
        DIA => DIA,      -- Port A Data Input
        DOA => DOA(I),
        CSB => '1',
        CLKB => CLK,
        WEB => '0',
		  OEB => '1',
        ADDRB => std_logic_vector(RPTR(I)(ADDR_WIDTH+2 downto 3)),  -- Port B Address Input
        DIB => (others => '0'),      -- Port B Data Input
        DOB => DOB(I)      -- Port B Data Output
    );
end generate;

-- How many bytes are waiting to be read? 
-- BUF_SIZE can be slightly negative when waiting for a few more bytes to complete a word
RX_BUFFER_SIZE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate
	BUF_SIZE(I) <= WPTR_CONFIRMED(I) + (not RPTR(I));
	-- tell the application when data is available to read
	RX_APP_RTS_local(I) <= '0' when (BUF_SIZE(I) = 0) or (BUF_SIZE(I)(ADDR_WIDTH+3) = '1') or (RESETn = '0') else '1';
end generate;
RX_APP_RTS <= RX_APP_RTS_local;

-- read pointer management
-- Rule #1: RPTR points to the next memory location to be read (Units: words)
RPTR_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	RPTR_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			BUF_SIZE_D(I) <= BUF_SIZE(I);
			RX_APP_CTS_ACK_D(I) <= RX_APP_CTS_ACK_local(I);
			
			if(SYNC_RESET = '1') or (RESETn = '0') or (RX_BUF_CLR(I) = '1') then
				RPTR(I) <= (others => '1');
				RX_APP_CTS_ACK_local(I) <= '0';
			elsif(RX_APP_RTS_local(I) = '0') then
				-- current output word DOB is not full (when BUF_SIZE is slightly negative). Do not increment the read pointer.
				RX_APP_CTS_ACK_local(I) <= '0';
			elsif(BUF_SIZE(I) /= 0) and (RX_APP_CTS(I) = '1') then
				-- At least one byte is available to read in memory
				-- and the application is ready to accept it. Read one (full or partial) word.
				RPTR(I) <= RPTR(I) + 8;
				RX_APP_CTS_ACK_local(I) <= '1';
			else
				RX_APP_CTS_ACK_local(I) <= '0';
			end if;
		end if;
	end process;
	-- design note: RPTR(I) is always ending in 111. As we do not know exactly how many bytes are
	-- read by the application, RPTR(I) should be considered as a range spanning 8 bytes. 
	-- For example 3FFF really means 3FF8-3FFF.
	-- This is an important consideration in computing the available free space.
	RPTR_MIN(I) <= RPTR(I)(ADDR_WIDTH+3 downto 3) & "000";
end generate;
RX_APP_CTS_ACK <= RX_APP_CTS_ACK_local;

OUTPUT_GEN: process(DOB, FIRST_APP_DATA, BUF_SIZE, BUF_SIZE_D, RX_APP_CTS_ACK_D)
begin
    for I in 0 to (NTCPSTREAMS-1) loop
        RX_APP_DATA(I) <= DOB(I);

		  if(FIRST_APP_DATA(I) = '0') then
				-- nothing to read
				RX_APP_DATA_VALID(I) <= x"00";
		  elsif (BUF_SIZE_D(I)(ADDR_WIDTH+3) = '1') and (BUF_SIZE(I)(ADDR_WIDTH+3) = '0')then
				-- previously partial word is now filled
				RX_APP_DATA_VALID(I) <= x"FF";
		  elsif (BUF_SIZE_D(I)(ADDR_WIDTH+3) = '0') and (RX_APP_CTS_ACK_D(I) = '1')then
				-- new full word
				RX_APP_DATA_VALID(I) <= x"FF";
		  elsif (BUF_SIZE_D(I)(ADDR_WIDTH+3) = '1') then
			-- reading last word in buffer, 1-8 bytes
				case(BUF_SIZE_D(I)(2 downto 0)) is
					when "001" => RX_APP_DATA_VALID(I) <= x"80";
					when "010" => RX_APP_DATA_VALID(I) <= x"C0";
					when "011" => RX_APP_DATA_VALID(I) <= x"E0";
					when "100" => RX_APP_DATA_VALID(I) <= x"F0";
					when "101" => RX_APP_DATA_VALID(I) <= x"F8";
					when "110" => RX_APP_DATA_VALID(I) <= x"FC";
					when "111" => RX_APP_DATA_VALID(I) <= x"FE";
					when others => RX_APP_DATA_VALID(I) <= x"00";
				end case;
			else
				RX_APP_DATA_VALID(I) <= x"00";
			end if;
    end loop;
end process;    

-- report the worst case available space to the TCP engine (including space currently occupied by invalid frames)
FREE_SPACE_GEN_001: process(CLK)
begin
    if rising_edge(CLK) then
        for I in 0 to (NTCPSTREAMS-1) loop
            RX_FREE_SPACE(I) <= std_logic_vector(resize(RPTR_MIN(I)(ADDR_WIDTH+2 downto 0) - WPTR0(I)(ADDR_WIDTH+2 downto 0),RX_FREE_SPACE(I)'length));
        end loop;
    end if;
end process;

-- test points
TPs: process(CLK)
begin
	if rising_edge(CLK) then
		TP(1) <= WEA(0);
		
		if(WEA(0) = '1') then
			if(DIA = x"7bd4008003000001") then
				TP(2) <= '1';
			else
				TP(2) <= '0';
			end if;
			if(DIA = x"0203040506070809") then
				TP(3) <= '1';
			else
				TP(3) <= '0';
			end if;
			if(DIA = x"0a0b0c0d0e0f0000") then
				TP(4) <= '1';
			else
				TP(4) <= '0';
			end if;
		end if;
		if(WPTRA(2 downto 0) = "000") then
			TP(5) <= '1';
		else
			TP(5) <= '0';
		end if;
		if(RPTR(0)(2 downto 0) = "111") then
			TP(6) <= '1';
		else
			TP(6) <= '0';
		end if;
		
			
	end if;
end process;
TP(10 downto 7) <= (others => '0');

end Behavioral;
