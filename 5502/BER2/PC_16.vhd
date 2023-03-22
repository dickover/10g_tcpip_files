	
-----------------------------------------------------------------
-- Parallel Counter
-- Counts the number of simultanous 1's in the input vector
-----------------------------------------------------------------
Library ieee;
Use ieee.std_logic_1164.all;

entity PC_16 is
	port (
		A: in std_logic_vector(15 downto 0);	-- input A
		O: out std_logic_vector(4 downto 0)	-- added value
	);
end PC_16;

architecture BEHAVIOR of PC_16 is  
-----------------------------------------------------------------
-- Components
-----------------------------------------------------------------

-- full adder
component FA is
	port (
		A: in std_logic;	-- input A
		B: in std_logic;	-- input B
		CI: in std_logic;	-- carry in
		O: out std_logic;	-- added value
		CO: out std_logic	-- carry out
	);
end component;

-- half adder
component HA is
	port (
		A: in std_logic;	-- input A
		B: in std_logic;	-- input B
		O: out std_logic;	-- added value
		CO: out std_logic	-- carry out
	);
end component;

-----------------------------------------------------------------
-- Signals
-----------------------------------------------------------------

signal P1: std_logic_vector(10 downto 0) := (others => '0'); 
	-- Partial products to compute partial sumA 
signal P2: std_logic_vector(7 downto 0) := (others => '0'); 
	-- Partial products to compute partial sumA 
signal P3: std_logic_vector(6 downto 0) := (others => '0');  
	-- Partial products to compute partial sumA
signal P4: std_logic_vector(5 downto 0) := (others => '0'); 
	-- Partial products to compute partial sumA 
signal P5: std_logic_vector(5 downto 2) := (others => '0'); 
	-- Partial products to compute partial sumA 

begin 
-- Compute the first wave of partial products 
FA01: FA port map( A => A(0), B => A(1), CI => A(2), O => P1(0), CO => P1(1));  
FA02: FA port map( A => A(3), B => A(4), CI => A(5), O => P1(2), CO => P1(3));  
FA03: FA port map( A => A(6), B => A(7), CI => A(8), O => P1(4), CO => P1(5));  
FA04: FA port map( A => A(9), B => A(10), CI => A(11), O => P1(6), CO => P1(7));  
FA05: FA port map( A => A(12), B => A(13), CI => A(14), O => P1(8), CO => P1(9));  
P1(10) <= A(15);

-- Compute the second wave of partial products 
FA09: FA port map( A => P1(0), B => P1(2), CI => P1(4), O => P2(0), CO => P2(1));  
FA10: FA port map( A => P1(1), B => P1(3), CI => P1(5), O => P2(4), CO => P2(5));  
FA11: FA port map( A => P1(6), B => P1(8), CI => P1(10), O => P2(2), CO => P2(3));  
HA12: HA port map( A => P1(7), B => P1(9), O => P2(6), CO => P2(7)); 
     
-- Compute the third wave of partial products 
HA13: HA port map( A => P2(0), B => P2(2), O => P3(0), CO => P3(1));  
FA14: FA port map( A => P2(1), B => P2(3), CI => P2(4), O => P3(2), CO => P3(3));
P3(4) <= P2(6);
HA15: HA port map( A => P2(5), B => P2(7), O => P3(5), CO => P3(6));  

-- Compute the fourth wave of partial products 
P4(0) <= P3(0);
FA17: FA port map( A => P3(1), B => P3(2), CI => P3(4), O => P4(1), CO => P4(2));  
FA18: HA port map( A => P3(3), B => P3(5), O => P4(3), CO => P4(4));
P4(5) <= P3(6);

-- Compute the fifth wave of partial products
HA03: HA port map( A => P4(2), B => P4(3), O => P5(2), CO => P5(3)); 
HA04: FA port map( A => P4(4), B => P4(5), CI => P5(3), O => P5(4), CO => P5(5)); 

-- The output of the partial addition is
o(0)<=P4(0); 
o(1)<=P4(1);
o(2)<=P5(2);
o(3)<=P5(4);
o(4)<=P5(5);

end BEHAVIOR;
	
