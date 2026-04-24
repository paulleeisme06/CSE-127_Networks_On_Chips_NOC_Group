// =============================================================================
// subservient_pad_ring.v  —  CORRECTED with real gf180mcu_fd_io cell names
//
// Source of truth: https://github.com/google/globalfoundries-pdk-libs-gf180mcu_fd_io
//
// COMPLETE CELL LIST in this library (there are only these):
//
//   gf180mcu_fd_io__in_c      Digital input, Schmitt trigger (hysteresis)
//   gf180mcu_fd_io__in_s      Digital input, standard (no hysteresis)
//   gf180mcu_fd_io__bi_24t    Bidirectional, 24 mA fixed drive strength
//   gf180mcu_fd_io__bi_t      Bidirectional, programmable drive (PDRV0/1)
//   gf180mcu_fd_io__dvdd      DVDD supply pad  (I/O ring VDD)
//   gf180mcu_fd_io__dvss      DVSS supply pad  (I/O ring GND)
//   gf180mcu_fd_io__cor       Corner cell (required at all 4 die corners)
//   gf180mcu_fd_io__fill1     1-unit filler
//   gf180mcu_fd_io__fill5     5-unit filler
//   gf180mcu_fd_io__fill10    10-unit filler
//   gf180mcu_fd_io__fillnc    Filler, no connect
//   gf180mcu_fd_io__brk2      Power domain break, 2-unit
//   gf180mcu_fd_io__brk5      Power domain break, 5-unit
//   gf180mcu_fd_io__asig_5p0  Analog signal pad 5V
//
// IMPORTANT: There is NO dedicated output-only cell.
// For outputs use bi_24t with OE=1, IE=0.
// For inputs  use in_c (with Schmitt trigger, recommended for digital signals).
//
// PORT REFERENCE:
//
//  gf180mcu_fd_io__in_c:
//    PU   — pull-up enable  (1 = enable internal pull-up to DVDD)
//    PD   — pull-down enable (1 = enable internal pull-down to DVSS)
//    PAD  — bond-wire connection (input from outside world)
//    Y    — signal output to core logic
//    DVDD, DVSS, VDD, VSS — power connections (all inout)
//
//  gf180mcu_fd_io__bi_24t:
//    A    — data input from core  (drives PAD when OE=1)
//    Y    — data output to core   (driven from PAD when IE=1)
//    OE   — output enable: 1 = drive PAD from A
//    IE   — input enable:  1 = sample PAD into Y
//    CS   — Schmitt trigger select on input path (1 = enable hysteresis)
//    SL   — slew rate control (0 = fast, 1 = slow)
//    PU   — pull-up enable
//    PD   — pull-down enable
//    PAD  — bond-wire connection (inout)
//    DVDD, DVSS, VDD, VSS — power connections
//
// USAGE PATTERNS:
//   Pure output:  OE=1, IE=0, A=<core_signal>, Y left unconnected
//   Pure input:   OE=0, IE=1, A=1'b0, Y=<core_signal>
//
// SUPPLY WIRES:
//   VDD  / VSS  — core logic supply  (connect to your 3.3V / GND rails)
//   DVDD / DVSS — I/O ring supply    (connect to your 3.3V / GND rails)
//   On this process both can be the same 3.3V supply.
//   Separate them if you need different I/O voltage domains.
//
// PAD RING RULES (OpenROAD / OpenLane):
//   - Place gf180mcu_fd_io__cor at every die corner (4 total, mandatory)
//   - Fill ALL gaps between pads with fill1/fill5/fill10 cells
//   - Use brk2 or brk5 to separate power domains if needed
//   - dvdd/dvss pads inject supply into the I/O ring (place several)
// =============================================================================

`timescale 1 ns / 1 ps
`default_nettype none

module subservient_pad_ring (
    // ── I/O ring power (bond wires) ──────────────────────────────────────────
    inout  wire DVDD,   // I/O ring VDD  (3.3 V)
    inout  wire DVSS,   // I/O ring GND
    inout  wire VDD,    // Core logic VDD (3.3 V)
    inout  wire VSS,    // Core logic GND

    // ── Signal bond wires (connect these to your package pins) ───────────────
    input  wire PAD_CLK,
    input  wire PAD_RST_N,
    output wire PAD_GPIO,
    input  wire PAD_TEST_MODE,
    input  wire PAD_SPI_CS_N,
    input  wire PAD_SPI_SCK,
    input  wire PAD_SPI_MOSI,
    output wire PAD_SPI_MISO,
    output wire PAD_MBIST_BUSY,
    output wire PAD_MBIST_PASS,
    output wire PAD_MBIST_FAIL
);

// ── Core-side wires ──────────────────────────────────────────────────────────
wire core_clk;
wire core_rst_n;
wire core_gpio;
wire core_test_mode;
wire core_spi_cs_n;
wire core_spi_sck;
wire core_spi_mosi;
wire core_spi_miso;
wire core_mbist_busy;
wire core_mbist_pass;
wire core_mbist_fail;

wire core_rst = ~core_rst_n;   // active-high reset for subservient_debug_top

// ── Corner cells (mandatory, one at each die corner) ────────────────────────
gf180mcu_fd_io__cor u_corner_nw (.DVDD(DVDD),.DVSS(DVSS),.VDD(VDD),.VSS(VSS));
gf180mcu_fd_io__cor u_corner_ne (.DVDD(DVDD),.DVSS(DVSS),.VDD(VDD),.VSS(VSS));
gf180mcu_fd_io__cor u_corner_se (.DVDD(DVDD),.DVSS(DVSS),.VDD(VDD),.VSS(VSS));
gf180mcu_fd_io__cor u_corner_sw (.DVDD(DVDD),.DVSS(DVSS),.VDD(VDD),.VSS(VSS));

// ── I/O ring supply pads ─────────────────────────────────────────────────────
// dvdd injects DVDD into the ring rail; dvss injects DVSS.
// Place at least 2 of each, spread around the perimeter.
// The behavioral model has no PAD port — supply is connected via the DVDD/DVSS
// inout ports which connect directly to your package power pins.
gf180mcu_fd_io__dvdd u_dvdd_0 (.DVDD(DVDD),.DVSS(DVSS),.VSS(VSS));
gf180mcu_fd_io__dvdd u_dvdd_1 (.DVDD(DVDD),.DVSS(DVSS),.VSS(VSS));
gf180mcu_fd_io__dvss u_dvss_0 (.DVDD(DVDD),.DVSS(DVSS),.VDD(VDD));
gf180mcu_fd_io__dvss u_dvss_1 (.DVDD(DVDD),.DVSS(DVSS),.VDD(VDD));

// ── Input pads ───────────────────────────────────────────────────────────────
// in_c = Schmitt trigger input (recommended for all digital signals —
// improves noise immunity at 3.3V, especially for slow edges like SPI SCK)
//   PU=0, PD=0: no internal pull (drive from external source)

gf180mcu_fd_io__in_c u_pad_clk (
    .PAD(PAD_CLK), .Y(core_clk),
    .PU(1'b0), .PD(1'b0),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

// RST_N has a pull-up so the chip runs normally if the pin is left open
gf180mcu_fd_io__in_c u_pad_rst_n (
    .PAD(PAD_RST_N), .Y(core_rst_n),
    .PU(1'b1), .PD(1'b0),   // pull-up: float = run mode
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__in_c u_pad_test_mode (
    .PAD(PAD_TEST_MODE), .Y(core_test_mode),
    .PU(1'b0), .PD(1'b1),   // pull-down: float = normal mode
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__in_c u_pad_spi_cs_n (
    .PAD(PAD_SPI_CS_N), .Y(core_spi_cs_n),
    .PU(1'b1), .PD(1'b0),   // pull-up: float = SPI idle (CS_N=1)
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__in_c u_pad_spi_sck (
    .PAD(PAD_SPI_SCK), .Y(core_spi_sck),
    .PU(1'b0), .PD(1'b1),   // pull-down: idle SCK=0 (SPI Mode 0)
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__in_c u_pad_spi_mosi (
    .PAD(PAD_SPI_MOSI), .Y(core_spi_mosi),
    .PU(1'b0), .PD(1'b0),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

// ── Output pads (bi_24t with OE=1, IE=0) ────────────────────────────────────
// There is no dedicated output-only cell in this library.
// bi_24t is the correct choice. With OE=1 and IE=0:
//   - PAD is driven from A (core signal)
//   - Y is gated off (IE=0 means PAD is never sampled back)
// SL=0 for fast slew (fine at these low frequencies)
// CS=0 (Schmitt not needed on output path; IE=0 so it has no effect anyway)

gf180mcu_fd_io__bi_24t u_pad_gpio (
    .A(core_gpio), .Y(),        // Y unconnected — pure output
    .OE(1'b1), .IE(1'b0),
    .CS(1'b0), .SL(1'b0),
    .PU(1'b0), .PD(1'b0),
    .PAD(PAD_GPIO),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__bi_24t u_pad_spi_miso (
    .A(core_spi_miso), .Y(),
    .OE(1'b1), .IE(1'b0),
    .CS(1'b0), .SL(1'b0),
    .PU(1'b0), .PD(1'b0),
    .PAD(PAD_SPI_MISO),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__bi_24t u_pad_mbist_busy (
    .A(core_mbist_busy), .Y(),
    .OE(1'b1), .IE(1'b0),
    .CS(1'b0), .SL(1'b0),
    .PU(1'b0), .PD(1'b0),
    .PAD(PAD_MBIST_BUSY),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__bi_24t u_pad_mbist_pass (
    .A(core_mbist_pass), .Y(),
    .OE(1'b1), .IE(1'b0),
    .CS(1'b0), .SL(1'b0),
    .PU(1'b0), .PD(1'b0),
    .PAD(PAD_MBIST_PASS),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

gf180mcu_fd_io__bi_24t u_pad_mbist_fail (
    .A(core_mbist_fail), .Y(),
    .OE(1'b1), .IE(1'b0),
    .CS(1'b0), .SL(1'b0),
    .PU(1'b0), .PD(1'b0),
    .PAD(PAD_MBIST_FAIL),
    .DVDD(DVDD), .DVSS(DVSS), .VDD(VDD), .VSS(VSS)
);

// ── Core instantiation ───────────────────────────────────────────────────────
subservient_debug_top u_core (
    .i_clk        (core_clk),
    .i_rst        (core_rst),
    .o_gpio       (core_gpio),
    .i_test_mode  (core_test_mode),
    .i_spi_cs_n   (core_spi_cs_n),
    .i_spi_sck    (core_spi_sck),
    .i_spi_mosi   (core_spi_mosi),
    .o_spi_miso   (core_spi_miso),
    .o_mbist_busy (core_mbist_busy),
    .o_mbist_pass (core_mbist_pass),
    .o_mbist_fail (core_mbist_fail)
);

endmodule
`default_nettype wire
