`default_nettype none
module subservient_fpga
(
 input wire  i_clk,
 input wire  i_rst,
 output wire q);

   //parameter memfile = "hello.hex";  gf180 SRAM doesn't support loading hex files at startup 

   parameter memsize = 2048;   // size of the SRAM beign used

   localparam aw    = $clog2(memsize);

   wire      clk;
   wire      rst;

   wire [aw-1:0] sram_waddr;
   wire [7:0] 	 sram_wdata;
   wire 	 sram_wen;
   wire [aw-1:0] sram_raddr;
   wire [7:0] 	 sram_rdata;
   wire 	 sram_ren;

   subservient_fpga_clock_gen clock_gen
     (.i_clk (i_clk),
      .i_rst (i_rst),
      .o_clk (clk),
      .o_rst (rst));

   subservient_ram
    #(.depth (memsize))
   memory
    (.i_clk   (clk),
   .i_rst   (rst),
   .i_waddr (sram_waddr),
   .i_wdata (sram_wdata),
   .i_wen   (sram_wen),
   .i_raddr (sram_raddr),
   .o_rdata (sram_rdata),
   .i_ren   (sram_ren));
     
   subservient
     #(.memsize  (memsize),
       .WITH_CSR (0))
   dut
     (// Clock & reset
      .i_clk (clk),
      .i_rst (rst),

      //SRAM interface
      .o_sram_waddr (sram_waddr),
      .o_sram_wdata (sram_wdata),
      .o_sram_wen   (sram_wen),
      .o_sram_raddr (sram_raddr),
      .i_sram_rdata (sram_rdata),
      .o_sram_ren   (sram_ren),

      // External I/O
      .o_gpio (q));

endmodule
