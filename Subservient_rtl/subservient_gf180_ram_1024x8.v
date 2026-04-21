/*
 * subservient_gf180_ram_1024x8.v : GF180 1024x8 SRAM wrapper for Subservient
 *
 * Drop-in replacement for subservient_generic_ram
 * Uses Open Circuit Design 1024x8 SRAM (3.3V version)
 * 
 * Key differences from 256x8 version:
 * - 1024 words instead of 256 (4× capacity)
 * - Address bus is 10 bits instead of 8 bits
 * - Same 8-bit data width
 */

`default_nettype none
module subservient_gf180_ram_1024x8
  #(parameter depth = 1024,
    parameter aw = $clog2(depth))
   (input wire         i_clk,
    input wire         i_rst,
    // SRAM interface (same as subservient_generic_ram)
    input wire [aw-1:0]  i_waddr,
    input wire [7:0]     i_wdata,
    input wire           i_wen,
    input wire [aw-1:0]  i_raddr,
    output wire [7:0]    o_rdata,
    input wire           i_ren);

   // Validation
   initial begin
      if (depth > 1024) begin
         $display("ERROR: OCD 1024x8 SRAM supports max 1024 words");
         $display("       Current depth=%0d", depth);
         $finish;
      end
      if (aw > 10) begin
         $display("ERROR: OCD 1024x8 SRAM requires max 10-bit address");
         $display("       Current address width=%0d", aw);
         $finish;
      end
   end

   // Power supplies
   // For simulation: tie to logic levels
   // For synthesis: connect to actual power rails in top-level
`ifdef USE_POWER_PINS
   wire vdd = 1'b1;
   wire vss = 1'b0;
`endif

   // GF180 SRAM control signals (active low)
   wire        sram_cen;    // Chip enable (active low)
   wire        sram_gwen;   // Global write enable (active low)
   wire [7:0]  sram_wen;    // Per-bit write enable (active low)
   wire [9:0]  sram_addr;   // 10-bit address (for 1024 words)
   wire [7:0]  sram_dout;   // Data output

   // Convert active-high to active-low
   assign sram_cen  = ~(i_ren | i_wen);  // Enable when reading OR writing
   assign sram_gwen = ~i_wen;             // Write enable (active low)
   assign sram_wen  = i_wen ? 8'h00 : 8'hFF;  // All bits enabled/disabled

   // Address mux: prioritize write address (matches generic_ram behavior)
   // Pad to 10 bits if address width is less than 10
   generate
      if (aw == 10) begin : gen_addr_10bit
         assign sram_addr = i_wen ? i_waddr : i_raddr;
      end else begin : gen_addr_padded
         assign sram_addr = i_wen ? {{(10-aw){1'b0}}, i_waddr} : 
                                     {{(10-aw){1'b0}}, i_raddr};
      end
   endgenerate

   // Instantiate OCD 1024x8 SRAM
   gf180mcu_ocd_ip_sram__sram1024x8m8wm1 sram_inst (
`ifdef USE_POWER_PINS
      .VDD  (vdd),
      .VSS  (vss),
`endif
      .CLK  (i_clk),
      .CEN  (sram_cen),
      .GWEN (sram_gwen),
      .WEN  (sram_wen),
      .A    (sram_addr),
      .D    (i_wdata),
      .Q    (sram_dout)
   );

   // Register x0 handling - must always read as 0
   // This matches the logic in subservient_generic_ram.v
   // When all upper address bits are 1, we're reading from register x0
   reg r0;

   always @(posedge i_clk)
     r0 <= &i_raddr[aw-1:2];

   // Gate output: force to 0 when reading register x0
   assign o_rdata = r0 ? 8'd0 : sram_dout;

   /* Memory Layout for 1024 bytes:
    * 
    * Address Range | Usage                          | Size
    * --------------+--------------------------------+--------
    * 0x000-0x003   | x0 (always reads 0)           | 4 bytes
    * 0x004-0x07F   | x1-x31 (31 GPRs)              | 124 bytes
    * 0x080-0x08F   | CSR0-CSR3 (4 CSRs, optional)  | 16 bytes
    * --------------+--------------------------------+--------
    *               | Register File Total:           | 144 bytes
    * --------------+--------------------------------+--------
    * 0x090-0x3FF   | Program + Data Memory          | 880 bytes
    * --------------+--------------------------------+--------
    *               | Total:                         | 1024 bytes
    * 
    * This gives 880 bytes of program/data memory (6.9× more than 256x8!)
    */

endmodule
`default_nettype wire
