`default_nettype none

// ============================================================================
// spi_arbiter — Flash SPI bus arbiter
// ============================================================================
//
// Two masters share one SPI flash:
//   MASTER 0 — boot_loader    : loads firmware into tile SRAMs at startup
//   MASTER 1 — housekeeping   : reads GoL initial grid data after boot
//
// Arbitration rule (simple, safe for this design):
//   cpu_rst_n == 0  →  boot_loader owns the bus   (boot phase)
//   cpu_rst_n == 1  →  housekeeping owns the bus  (runtime phase)
//
// The two phases are strictly non-overlapping so no handshake is needed.
// ============================================================================

module spi_arbiter (
    // From boot_loader
    input  wire boot_csb,
    input  wire boot_clk,
    input  wire boot_mosi,
    output wire boot_miso,

    // From housekeeping_fsm
    input  wire hk_csb,
    input  wire hk_clk,
    input  wire hk_mosi,
    output wire hk_miso,

    // To SPI flash
    output wire flash_csb,
    output wire flash_clk,
    output wire flash_mosi,
    input  wire flash_miso,

    // Phase select: 0 = boot_loader, 1 = housekeeping
    input  wire cpu_rst_n
);

    // Mux all outputs to flash based on phase
    assign flash_csb  = cpu_rst_n ? hk_csb   : boot_csb;
    assign flash_clk  = cpu_rst_n ? hk_clk   : boot_clk;
    assign flash_mosi = cpu_rst_n ? hk_mosi  : boot_mosi;

    // MISO fans out to both masters; only the active one will be listening
    assign boot_miso = flash_miso;
    assign hk_miso   = flash_miso;

endmodule