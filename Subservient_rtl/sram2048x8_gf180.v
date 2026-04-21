// =============================================================================
// sram2048x8_gf180.v
//
// 2 KiB SRAM wrapper for subservient RISC-V SoC
// Implements 2048 x 8 by banking two
//   gf180mcu_ocd_ip_sram__sram1024x8m8wm1  (1024 x 8) macros.
//
// Interface is deliberately identical to the GF180 1K macro so this module
// can be used as a drop-in wherever a single larger macro would appear.
//
// Bank decode:
//   A[10] = 0  -->  bank0  (addresses 0x000 – 0x3FF)
//   A[10] = 1  -->  bank1  (addresses 0x400 – 0x7FF)
//
// GF180 macro signal conventions (inherited here):
//   CEN   active-low chip enable  (0 = chip active)
//   GWEN  global write enable     (0 = write, 1 = read)
//   WEN   per-bit write enables   (0 = write that bit, 1 = mask that bit)
//   Q     registered output       (data appears ONE cycle after CLK edge)
//
// Because Q is registered we must also register the bank-select bit and use
// that registered copy to steer the Q mux, ensuring the data and the mux
// control word arrive in the same clock domain.
// =============================================================================

`timescale 1 ps / 1 ps

module sram2048x8_gf180 (
`ifdef USE_POWER_PINS
    VDD,
    VSS,
`endif
    CLK,
    CEN,
    GWEN,
    WEN,
    A,
    D,
    Q
);

// ---------------------------------------------------------------------------
// Port declarations
// ---------------------------------------------------------------------------
`ifdef USE_POWER_PINS
    inout           VDD;
    inout           VSS;
`endif

input           CLK;
input           CEN;        // Chip enable, active-low
input           GWEN;       // Global write enable: 0=write, 1=read
input   [7:0]   WEN;        // Per-bit write enable, active-low
input   [10:0]  A;          // 11-bit address for 2048 locations
input   [7:0]   D;          // Write data
output  [7:0]   Q;          // Read data (registered)

// ---------------------------------------------------------------------------
// Internal signals
// ---------------------------------------------------------------------------

// Address bit [10] chooses the active bank.
wire        bank_sel;
assign bank_sel = A[10];

// Per-bank chip enables.
// bank0 is selected when bank_sel==0 AND the chip is enabled (CEN==0).
// bank1 is selected when bank_sel==1 AND the chip is enabled (CEN==0).
// Using OR logic:
//   cen_bank0 = 1 (disabled) unless CEN==0 AND bank_sel==0
//   cen_bank1 = 1 (disabled) unless CEN==0 AND bank_sel==1
wire        cen_bank0;
wire        cen_bank1;
assign cen_bank0 = CEN | ( bank_sel);   // disabled when bank_sel=1 or chip off
assign cen_bank1 = CEN | (~bank_sel);   // disabled when bank_sel=0 or chip off

// Raw Q outputs from each macro
wire [7:0] q_bank0;
wire [7:0] q_bank1;

// ---------------------------------------------------------------------------
// Registered bank-select for output mux
//
// The GF180 macro presents Q one clock cycle after the rising CLK edge, so
// we must delay bank_sel by the same one cycle before using it to steer the
// mux.  We only need to capture it when the chip is actually accessed; a
// power-on reset is not strictly required because both macros drive known
// values after initialisation, but guarding on !CEN avoids a spurious update
// when the chip is idle.
// ---------------------------------------------------------------------------
reg bank_sel_q;   // registered (delayed by 1 CLK) bank select
always @(posedge CLK) begin
    if (!CEN)
        bank_sel_q <= bank_sel;
end

// Output mux: select data from the bank that was addressed last cycle.
assign Q = bank_sel_q ? q_bank1 : q_bank0;

// ---------------------------------------------------------------------------
// SRAM macro instantiations
// ---------------------------------------------------------------------------

// --- Bank 0 : addresses 0x000 – 0x3FF ---
gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_bank0 (
`ifdef USE_POWER_PINS
    .VDD  (VDD),
    .VSS  (VSS),
`endif
    .CLK  (CLK),
    .CEN  (cen_bank0),  // disabled when bank1 is selected
    .GWEN (GWEN),
    .WEN  (WEN),
    .A    (A[9:0]),     // lower 10 bits are the intra-bank address
    .D    (D),
    .Q    (q_bank0)
);

// --- Bank 1 : addresses 0x400 – 0x7FF ---
gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_bank1 (
`ifdef USE_POWER_PINS
    .VDD  (VDD),
    .VSS  (VSS),
`endif
    .CLK  (CLK),
    .CEN  (cen_bank1),  // disabled when bank0 is selected
    .GWEN (GWEN),
    .WEN  (WEN),
    .A    (A[9:0]),     // lower 10 bits are the intra-bank address
    .D    (D),
    .Q    (q_bank1)
);

endmodule
