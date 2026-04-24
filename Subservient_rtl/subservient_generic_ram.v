module subservient_generic_ram
  #(parameter depth = 256,
    parameter aw = $clog2(depth))
  (
   input wire i_clk,
   input wire i_rst,
   input wire [aw-1:0]  i_waddr,
   input wire [7:0]     i_wdata,
   input wire           i_wen,
   input wire [aw-1:0]  i_raddr,
   output wire [7:0]    o_rdata,
   input wire           i_ren
  );

  wire vdd = 1'b1;
  wire vss = 1'b0;
  
  wire sram_cen  = ~(i_ren | i_wen);
  wire sram_gwen = ~i_wen;
  wire [7:0] sram_wen = i_wen ? 8'h00 : 8'hFF;
  wire [7:0] sram_addr;
  wire [7:0] sram_dout;
  
  // Pad address to 8 bits if needed
  assign sram_addr = (aw < 8) ? {{(8-aw){1'b0}}, (i_wen ? i_waddr : i_raddr)} :
                                 (i_wen ? i_waddr[7:0] : i_raddr[7:0]);

  gf180mcu_ocd_ip_sram__sram1024x8m8wm1 sram (
    .CLK(i_clk),
    .CEN(sram_cen),
    .GWEN(sram_gwen),
    .WEN(sram_wen),
    .A(sram_addr),
    .D(i_wdata),
    .Q(sram_dout),
    .VDD(vdd),
    .VSS(vss)
  );
  
  // Register x0 handling
  reg r0;
  always @(posedge i_clk)
    r0 <= &i_raddr[aw-1:2];
  
  assign o_rdata = r0 ? 8'd0 : sram_dout;

endmodule