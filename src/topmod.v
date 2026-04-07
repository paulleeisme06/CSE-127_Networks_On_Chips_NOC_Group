// module topmod (
//     input  wire clk,
//     input  wire reset,
    
//     // Physical Pins
//     input  wire flash_miso,
//     output wire flash_mosi,
//     output wire flash_clk,
//     output wire flash_csb,
    
//     // Host Pins 
//     input  wire bypass_en,
//     input  wire host_mosi,
    
//     // Wishbone Bus (NoC Gateway)
//     output wire [31:0] wbs_adr,
//     output wire [31:0] wbs_dat,
//     output wire        wbs_cyc,
//     output wire        wbs_stb,
//     output wire        wbs_we,
//     input  wire        wbs_ack
// );

//     wire fetch_en;
//     wire h_csb;
//     wire [31:0] shifted_word;
//     wire word_ready;
//     wire fetch_o;

//     // Flash Clock Module (Flashs clock is slower than systems clock)
//     flash_clk slow_clk (
//         .clk(clk),
//         .reset(reset),
//         .enable(fetch_en),
//         .flash_clk(flash_clk)
//     );

//     //FSM Module
//     housekeeping_fsm FSM(
//         .clk(clk),
//         .reset(reset),
//         .bypass_en(bypass_en),
//         .word_ready(word_ready),
//         .shifted_word(shifted_word),
//         .fetch_en(fetch_en),
//         .fetch_o(fetch_o),
//         .flash_csb(h_csb),
//         .wbs_adr(wbs_adr),
//         .wbs_dat(wbs_dat),
//         .wbs_cyc(wbs_cyc),
//         .wbs_stb(wbs_stb),
//         .wbs_we(wbs_we),
//         .wbs_ack(wbs_ack)
//     );

//     reg flash_clk_delayed;
//     wire flash_tick;

//     always @(posedge clk) flash_clk_delayed <= flash_clk;
//     assign flash_tick = (flash_clk && !flash_clk_delayed); // High for 1 fast clock cycle

//     // Shift Register
//     shiftregister word (
//         .clk(clk),
//         .reset(reset || bypass_en),
//         .serial_in(flash_miso),
//         .shift_en(flash_tick), 
//         .fetch_o(fetch_o),
//         .shifted_word(shifted_word),
//         .done_word(word_ready)
//     );

//     // Change these from 'wire' or 'reg' to 'wire [7:0]'
// wire [9:0] sram_addr; 
// wire [7:0] sram_wen;  
// wire [7:0] sram_dout;
// wire sram_cen;
// wire [7:0] sram_din;
    
//     // SRAM
//     gf180mcu_fd_ip_sram__sram1024x8m8wm1 sram (
//     .CLK(clk),
//     .CEN(sram_cen),   // Driven by your FSM 
//     .WEN(sram_wen),   // Driven by your FSM 
//     .GWEN(!wbs_we),
//     .A(sram_addr),    // Driven by your FSM [10 bits]
//     .D(sram_din[7:0]), // Taking the first byte of your 32-bit shift register
//     .Q(sram_dout)     // Output from memory
// );

// // Select which byte to write based on address LSBs
// // wbs_adr is word-aligned (multiples of 4), so we use byte counter
// reg [1:0] byte_sel;
// always @(posedge clk) begin
//     if (reset) byte_sel <= 0;
//     else if (wbs_stb && wbs_we) byte_sel <= byte_sel + 1;
// end

// // Pick the right byte from the 32-bit word
// assign sram_din = (byte_sel == 2'd0) ? wbs_dat[7:0]  :
//                   (byte_sel == 2'd1) ? wbs_dat[15:8]  :
//                   (byte_sel == 2'd2) ? wbs_dat[23:16] :
//                                        wbs_dat[31:24];

// // Byte address: base offset + (word_index * 4) + byte_sel
// assign sram_addr = ((wbs_adr - 32'h1000) + byte_sel);

//     // If bypass is on, host_mosi directly to flash
//     assign flash_mosi = (bypass_en) ? host_mosi : 1'b0;
    
//     // If bypass is on, host controls CSB (usually low to write). Otherwise, FSM controls it.
//     assign flash_csb  = (bypass_en) ? 1'b0 : h_csb;

//     // 1. SRAM Control Signals
//     // The SRAM is active when the FSM starts a Wishbone STROBE
//     assign sram_cen = !wbs_stb; 
    
//     // The SRAM writes when the FSM says Write Enable
//     // We replicate the 1-bit wbs_we to the 8-bit mask WEN
//     assign sram_wen = {8'd0}; 

//     // Offsets address by the base address (h1000)
//     //assign sram_addr = (wbs_adr - 32'h1000) >> 2;

//     // WishBone handshake
//     reg wbs_ack_r;
//     always @(posedge clk) wbs_ack_r <= wbs_stb;
//     assign wbs_ack = wbs_ack_r;
// endmodule





`default_nettype none

// ============================================================================
// top.v — Full chip top level (GF180 tapeout + simulation)
// ============================================================================
//
// Boot + runtime sequence:
//
//   PHASE 1 — BOOT (cpu_rst_n = 0)
//     boot_controller reads firmware from SPI flash via spi_arbiter.
//     Broadcasts boot_addr/boot_data/boot_wen to all 9 tile SRAMs.
//     When done, asserts cpu_rst_n (goes high).
//     spi_arbiter switches flash ownership to housekeeping_top.
//
//   PHASE 2a — HOST SEED (bypass_en = 0, host alive)
//     host_spi_slave owns the SRAM write bus and reset control.
//     CMD 0x03/0xFF → hold reset, CMD 0x00 → write seed, CMD 0x03/0x00 → run.
//
//   PHASE 2b — FLASH SEED (bypass_en = 1, host dead)
//     housekeeping_top reads GoL seed from flash → Wishbone → gateway.
//     gateway converts to NOC flits → inject_00_nw → tiles.
//     bypass_en also resets housekeeping_fsm when host comes back.
//
//   PHASE 3 — RUN
//     All 9 SERV cores execute firmware (GoL).
//     Signals 0xCCCCCCCC on monitor_22_se when generation stable.
//
//   PHASE 4 — READBACK
//     Host sends CMD 0x02 to read result bytes back over SPI.
//     In simulation, Cocotb probes SRAM hierarchy directly (faster).
//
// SPI flash arbitration (spi_arbiter):
//   cpu_rst_n = 0  →  boot_controller owns flash bus
//   cpu_rst_n = 1  →  housekeeping_top owns flash bus
//
// NOC inject mux:
//   bypass_en = 0  →  inject_00_nw = 34'h0  (host seeds via SRAM write bus)
//   bypass_en = 1  →  inject_00_nw = gateway output (flash seeds via NOC)
//
// SRAM write bus mux:
//   boot_mode = 1  →  boot_controller
//   boot_mode = 0  →  host_spi_slave
//
// CPU reset arbitration:
//   host_rst_en = 0  →  boot_controller owns reset
//   host_rst_en = 1  →  host_spi_slave owns reset
// ============================================================================

module top (
    input  wire clk,
    input  wire rst,

    // SPI Flash (routed through spi_arbiter)
    output wire flash_csb,
    output wire flash_clk,
    output wire flash_mosi,
    input  wire flash_miso,

    // Host SPI (bidirectional: seed write + result read)
    input  wire host_csb,
    input  wire host_sclk,
    input  wire host_mosi,
    output wire host_miso,

    // Bypass strap: 0 = host alive (normal), 1 = host dead (use flash path)
    input  wire bypass_en,

    // Debug output ports (probe pads for tapeout)
    output wire cpu_rst_n,
    output wire host_rst,
    output wire host_rst_en
);

    // -----------------------------------------------------------------------
    // boot_controller wires
    // -----------------------------------------------------------------------
    wire [7:0] boot_data;
    wire [9:0] boot_addr;
    wire       boot_wen;

    wire boot_mode = ~cpu_rst_n;

    // -----------------------------------------------------------------------
    // boot_controller <-> spi_arbiter wires
    // -----------------------------------------------------------------------
    wire boot_csb_w, boot_clk_w, boot_mosi_w, boot_miso_w;

    // -----------------------------------------------------------------------
    // housekeeping_top <-> spi_arbiter wires
    // -----------------------------------------------------------------------
    wire hk_csb_w, hk_clk_w, hk_mosi_w, hk_miso_w;

    // -----------------------------------------------------------------------
    // housekeeping_top <-> gateway Wishbone wires
    // wbs_ack_gw: driven by gateway, fed back into topmod as input
    // topmod's internal ack logic is bypassed — gateway owns the ack
    // -----------------------------------------------------------------------
    wire [31:0] wbs_adr, wbs_dat;
    wire        wbs_cyc, wbs_stb, wbs_we;
    wire        wbs_ack_gw;  // gateway drives this, topmod reads it

    // -----------------------------------------------------------------------
    // gateway -> NOC inject wires
    // -----------------------------------------------------------------------
    wire [31:0] gw_packet_out;
    wire        gw_ready;

    // Pack into 34-bit NOC flit: bit33=valid, bit32=0, bits31:0=payload
    wire [33:0] gw_inject_flit = {gw_ready, 1'b0, gw_packet_out};

    // NOC inject mux:
    //   bypass_en=0 → host seeds via SRAM write bus, no NOC inject
    //   bypass_en=1 → gateway drives the inject port
    wire [33:0] inject_00_nw = bypass_en ? gw_inject_flit : 34'h0;

    // monitor output from mesh
    wire [33:0] monitor_22_se;

    // -----------------------------------------------------------------------
    // host_spi_slave wires
    // -----------------------------------------------------------------------
    wire [9:0] host_sram_waddr;
    wire [7:0] host_sram_wdata;
    wire       host_sram_wen;

    // -----------------------------------------------------------------------
    // readback crossbar wires
    // -----------------------------------------------------------------------
    wire [3:0] rd_tile;
    wire [9:0] rd_addr;
    wire       rd_req;
    wire [7:0] rd_data_from_xbar;

    wire [9:0] tile_rd_addr_0, tile_rd_addr_1, tile_rd_addr_2;
    wire [9:0] tile_rd_addr_3, tile_rd_addr_4, tile_rd_addr_5;
    wire [9:0] tile_rd_addr_6, tile_rd_addr_7, tile_rd_addr_8;

    wire tile_rd_req_0, tile_rd_req_1, tile_rd_req_2;
    wire tile_rd_req_3, tile_rd_req_4, tile_rd_req_5;
    wire tile_rd_req_6, tile_rd_req_7, tile_rd_req_8;

    wire [7:0] tile_rd_data_0, tile_rd_data_1, tile_rd_data_2;
    wire [7:0] tile_rd_data_3, tile_rd_data_4, tile_rd_data_5;
    wire [7:0] tile_rd_data_6, tile_rd_data_7, tile_rd_data_8;

    // -----------------------------------------------------------------------
    // SRAM write bus mux
    //   boot_mode=1 → boot_controller
    //   boot_mode=0 → host_spi_slave
    // -----------------------------------------------------------------------
    wire [9:0] mux_boot_addr = boot_mode ? boot_addr      : host_sram_waddr;
    wire [7:0] mux_boot_data = boot_mode ? boot_data      : host_sram_wdata;
    wire       mux_boot_wen  = boot_mode ? boot_wen       : host_sram_wen;

    // -----------------------------------------------------------------------
    // CPU reset arbitration
    //   host_rst_en=0 → boot_controller owns reset
    //   host_rst_en=1 → host_spi_slave owns reset
    // -----------------------------------------------------------------------
    wire tile_rst = host_rst_en ? host_rst : ~cpu_rst_n;

    // -----------------------------------------------------------------------
    // spi_arbiter
    //   cpu_rst_n=0 → boot_controller owns flash
    //   cpu_rst_n=1 → housekeeping_top owns flash
    // -----------------------------------------------------------------------
    spi_arbiter arb_inst (
        .boot_csb   (boot_csb_w),
        .boot_clk   (boot_clk_w),
        .boot_mosi  (boot_mosi_w),
        .boot_miso  (boot_miso_w),
        .hk_csb     (hk_csb_w),
        .hk_clk     (hk_clk_w),
        .hk_mosi    (hk_mosi_w),
        .hk_miso    (hk_miso_w),
        .flash_csb  (flash_csb),
        .flash_clk  (flash_clk),
        .flash_mosi (flash_mosi),
        .flash_miso (flash_miso),
        .cpu_rst_n  (cpu_rst_n)
    );

    // -----------------------------------------------------------------------
    // boot_controller — connects to spi_arbiter, not flash pads directly
    // -----------------------------------------------------------------------
    boot_controller boot_inst (
        .clk         (clk),
        .rst_n       (~rst),
        .flash_cs_n  (boot_csb_w),
        .flash_clk   (boot_clk_w),
        .flash_mosi  (boot_mosi_w),
        .flash_miso  (boot_miso_w),
        .sram_wdata  (boot_data),
        .sram_waddr  (boot_addr),
        .sram_wen    (boot_wen),
        .cpu_reset_n (cpu_rst_n)
    );

    // -----------------------------------------------------------------------
    // housekeeping_top (topmod) — flash fallback seed path
    //
    //   Active when bypass_en=1 (host dead).
    //   Held in reset during boot phase (~cpu_rst_n) so it doesn't
    //   fight boot_controller for the flash bus.
    //
    //   bypass_en polarity note:
    //     top.v bypass_en=1  → USE this path (host is dead)
    //     topmod bypass_en=1 → BYPASS this path (host override)
    //     So we invert: topmod gets ~bypass_en
    // -----------------------------------------------------------------------
    topmod housekeeping_top (
        .clk        (clk),
        .reset      (rst | ~cpu_rst_n),
        .flash_miso (hk_miso_w),
        .flash_mosi (hk_mosi_w),
        .flash_clk  (hk_clk_w),
        .flash_csb  (hk_csb_w),
        .bypass_en  (~bypass_en),
        .host_mosi  (1'b0),
        .wbs_adr    (wbs_adr),
        .wbs_dat    (wbs_dat),
        .wbs_cyc    (wbs_cyc),
        .wbs_stb    (wbs_stb),
        .wbs_we     (wbs_we),
        .wbs_ack    (wbs_ack_gw)  // gateway's ack fed back in
    );

    // -----------------------------------------------------------------------
    // gateway — Wishbone slave → NOC flit injector
    // -----------------------------------------------------------------------
    gateway gw_inst (
        .clk        (clk),
        .rst        (rst),
        .wbs_dat_i  (wbs_dat),
        .wbs_stb_i  (wbs_stb),
        .wbs_we_i   (wbs_we),
        .wbs_ack_o  (wbs_ack_gw),  // gateway drives ack
        .packet_out (gw_packet_out),
        .ready      (gw_ready)
    );

    // -----------------------------------------------------------------------
    // mesh_3x3
    // -----------------------------------------------------------------------
    mesh_3x3 mesh_inst (
        .clk           (clk),
        .rst           (tile_rst),
        .inject_00_nw  (inject_00_nw),
        .monitor_22_se (monitor_22_se),
        .boot_mode     (boot_mode),
        .boot_addr     (mux_boot_addr),
        .boot_data     (mux_boot_data),
        .boot_wen      (mux_boot_wen),
        .tile_rd_addr_0(tile_rd_addr_0), .tile_rd_req_0(tile_rd_req_0), .tile_rd_data_0(tile_rd_data_0),
        .tile_rd_addr_1(tile_rd_addr_1), .tile_rd_req_1(tile_rd_req_1), .tile_rd_data_1(tile_rd_data_1),
        .tile_rd_addr_2(tile_rd_addr_2), .tile_rd_req_2(tile_rd_req_2), .tile_rd_data_2(tile_rd_data_2),
        .tile_rd_addr_3(tile_rd_addr_3), .tile_rd_req_3(tile_rd_req_3), .tile_rd_data_3(tile_rd_data_3),
        .tile_rd_addr_4(tile_rd_addr_4), .tile_rd_req_4(tile_rd_req_4), .tile_rd_data_4(tile_rd_data_4),
        .tile_rd_addr_5(tile_rd_addr_5), .tile_rd_req_5(tile_rd_req_5), .tile_rd_data_5(tile_rd_data_5),
        .tile_rd_addr_6(tile_rd_addr_6), .tile_rd_req_6(tile_rd_req_6), .tile_rd_data_6(tile_rd_data_6),
        .tile_rd_addr_7(tile_rd_addr_7), .tile_rd_req_7(tile_rd_req_7), .tile_rd_data_7(tile_rd_data_7),
        .tile_rd_addr_8(tile_rd_addr_8), .tile_rd_req_8(tile_rd_req_8), .tile_rd_data_8(tile_rd_data_8)
    );

    // -----------------------------------------------------------------------
    // host_spi_slave
    // -----------------------------------------------------------------------
    host_spi_slave host_spi (
        .sys_clk     (clk),
        .sys_rst     (rst),
        .spi_csb     (host_csb),
        .spi_sclk    (host_sclk),
        .spi_mosi    (host_mosi),
        .spi_miso    (host_miso),
        .sram_waddr  (host_sram_waddr),
        .sram_wdata  (host_sram_wdata),
        .sram_wen    (host_sram_wen),
        .host_rst    (host_rst),
        .host_rst_en (host_rst_en),
        .rd_tile     (rd_tile),
        .rd_addr     (rd_addr),
        .rd_req      (rd_req),
        .rd_data     (rd_data_from_xbar)
    );

    // -----------------------------------------------------------------------
    // rd_crossbar
    // -----------------------------------------------------------------------
    rd_crossbar xbar_inst (
        .clk           (clk),
        .rd_tile       (rd_tile),
        .rd_addr       (rd_addr),
        .rd_req        (rd_req),
        .rd_data       (rd_data_from_xbar),
        .tile_rd_addr_0(tile_rd_addr_0), .tile_rd_req_0(tile_rd_req_0), .tile_rd_data_0(tile_rd_data_0),
        .tile_rd_addr_1(tile_rd_addr_1), .tile_rd_req_1(tile_rd_req_1), .tile_rd_data_1(tile_rd_data_1),
        .tile_rd_addr_2(tile_rd_addr_2), .tile_rd_req_2(tile_rd_req_2), .tile_rd_data_2(tile_rd_data_2),
        .tile_rd_addr_3(tile_rd_addr_3), .tile_rd_req_3(tile_rd_req_3), .tile_rd_data_3(tile_rd_data_3),
        .tile_rd_addr_4(tile_rd_addr_4), .tile_rd_req_4(tile_rd_req_4), .tile_rd_data_4(tile_rd_data_4),
        .tile_rd_addr_5(tile_rd_addr_5), .tile_rd_req_5(tile_rd_req_5), .tile_rd_data_5(tile_rd_data_5),
        .tile_rd_addr_6(tile_rd_addr_6), .tile_rd_req_6(tile_rd_req_6), .tile_rd_data_6(tile_rd_data_6),
        .tile_rd_addr_7(tile_rd_addr_7), .tile_rd_req_7(tile_rd_req_7), .tile_rd_data_7(tile_rd_data_7),
        .tile_rd_addr_8(tile_rd_addr_8), .tile_rd_req_8(tile_rd_req_8), .tile_rd_data_8(tile_rd_data_8)
    );

endmodule