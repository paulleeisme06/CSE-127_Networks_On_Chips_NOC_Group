// =============================================================================
// subservient_debug_top.v
//
// Architecture overview:
//
//   ┌──────────────────┐  waddr/wdata/wen     ┌──────────────────────┐
//   │  subservient_core│ ────────────────────► │                      │
//   │  (SERV RISC-V)   │  raddr/ren           │   3-way SRAM mux     │──► sram2048x8_gf180
//   │                  │ ────────────────────► │                      │◄── (sram_q / Q)
//   │  o_wb_* (periph) │  i_sram_rdata        │  sel_debug/sel_mbist │
//   └──────────────────┘ ◄────────────────────  └──────────────────────┘
//           │                                            ▲           ▲
//           ▼                                   ┌────────┴───┐ ┌─────┴──────┐
//   ┌──────────────┐                            │ WB-to-SRAM │ │ sram_mbist │
//   │ subservient  │                            │  adapter   │ │            │
//   │   _gpio      │                            └────────────┘ └────────────┘
//   └──────────────┘                                  ▲
//                                               ┌─────┴──────┐
//                                               │spi_wb_debug│
//                                               │    _v4     │
//                                               └────────────┘
//
// Mode control (i_rst is active-high):
//   i_rst=0, any TM  →  CPU runs, drives SRAM
//   i_rst=1, TM=0    →  SPI debug; CPU in reset, SPI bridge owns SRAM
//   i_rst=1, TM=1    →  MBIST;     CPU in reset, MBIST owns SRAM
//
// SPI debug read protocol (2-cycle WB slave adapter):
//   Edge N  : stb seen → latch addr/data/we, go to DBG_ACCESS
//   Edge N+1: SRAM samples CEN=0 → Q valid after this edge (ta=45 ns < 55 ns period)
//             go to DBG_DONE
//   Edge N+2: combinational ack=1, rdt=Q; master captures; go to DBG_IDLE
// =============================================================================

`timescale 1 ps / 1 ps
`default_nettype none

module subservient_debug_top
  #(parameter memsize = 2048)
(
    input  wire        i_clk,
    input  wire        i_rst,        // active-high: 1 = debug/MBIST, 0 = run
    output wire        o_gpio,

    // Test interface
    input  wire        i_test_mode,  // 0 = SPI debug, 1 = MBIST (only when i_rst=1)
    input  wire        i_spi_cs_n,
    input  wire        i_spi_sck,
    input  wire        i_spi_mosi,
    output wire        o_spi_miso,
    output wire        o_mbist_busy,
    output wire        o_mbist_pass,
    output wire        o_mbist_fail
);

localparam aw = $clog2(memsize);   // 11 for 2048

// ---------------------------------------------------------------------------
// Mode select
// ---------------------------------------------------------------------------
wire sel_mbist = i_rst &  i_test_mode;
wire sel_debug = i_rst & ~i_test_mode;

// ---------------------------------------------------------------------------
// SRAM Q output wire (shared by all three consumers via u_sram.Q)
// ---------------------------------------------------------------------------
wire [7:0] sram_q;

// ===========================================================================
// 1. SERV RISC-V core
// ===========================================================================

// CPU SRAM port wires
wire [aw-1:0] cpu_waddr;
wire [7:0]    cpu_wdata;
wire          cpu_wen;
wire [aw-1:0] cpu_raddr;
wire          cpu_ren;

// Derive GF180-style signals from the CPU's split-bus interface.
// Write has priority for the address mux (matches subservient_gf180_ram_1024x8).
wire [aw-1:0] cpu_sram_addr = cpu_wen ? cpu_waddr : cpu_raddr;
wire          cpu_sram_cen  = ~(cpu_wen | cpu_ren);
wire          cpu_sram_gwen = ~cpu_wen;
wire [7:0]    cpu_sram_wen  = cpu_wen ? 8'h00 : 8'hFF;

// x0 register forcing: SERV stores x0 at the top of the RF region
// (all upper address bits = 1). Force reads from that location to 0.
reg cpu_r0;
always @(posedge i_clk)
    cpu_r0 <= &cpu_raddr[aw-1:2];

wire [7:0] cpu_rdata = cpu_r0 ? 8'd0 : sram_q;

// CPU peripheral Wishbone wires
wire [31:0] cpu_wb_adr;
wire [31:0] cpu_wb_dat;
wire [3:0]  cpu_wb_sel;
wire        cpu_wb_we;
wire        cpu_wb_stb;
wire [31:0] cpu_wb_rdt;
wire        cpu_wb_ack;

wire        gpio_wb_rdt;
assign cpu_wb_rdt = {31'd0, gpio_wb_rdt};

subservient_core #(.memsize(memsize)) u_core (
    .i_clk       (i_clk),
    .i_rst       (i_rst),
    .i_timer_irq (1'b0),

    // SRAM interface — both address buses connected
    .o_sram_waddr (cpu_waddr),
    .o_sram_wdata (cpu_wdata),
    .o_sram_wen   (cpu_wen),
    .o_sram_raddr (cpu_raddr),
    .i_sram_rdata (cpu_rdata),
    .o_sram_ren   (cpu_ren),

    // Peripheral bus → GPIO
    .o_wb_adr    (cpu_wb_adr),
    .o_wb_dat    (cpu_wb_dat),
    .o_wb_sel    (cpu_wb_sel),
    .o_wb_we     (cpu_wb_we),
    .o_wb_stb    (cpu_wb_stb),
    .i_wb_rdt    (cpu_wb_rdt),
    .i_wb_ack    (cpu_wb_ack)
);

// ===========================================================================
// 2. GPIO — directly on the CPU peripheral Wishbone bus
// ===========================================================================
subservient_gpio u_gpio (
    .i_wb_clk (i_clk),
    .i_wb_rst (i_rst),
    .i_wb_dat (cpu_wb_dat[0]),
    .i_wb_we  (cpu_wb_we),
    .i_wb_stb (cpu_wb_stb),
    .o_wb_rdt (gpio_wb_rdt),
    .o_wb_ack (cpu_wb_ack),
    .o_gpio   (o_gpio)
);

// ===========================================================================
// 3. SPI → Wishbone debug bridge
// ===========================================================================
wire [31:0] dbg_wb_adr;
wire [31:0] dbg_wb_dat;
wire [3:0]  dbg_wb_sel;
wire        dbg_wb_we;
wire        dbg_wb_stb;
wire [31:0] dbg_wb_rdt;
wire        dbg_wb_ack;

spi_wb_debug_v4 u_spi_dbg (
    .i_clk      (i_clk),
    .i_rst      (i_rst),
    .i_spi_cs_n (i_spi_cs_n),
    .i_spi_sck  (i_spi_sck),
    .i_spi_mosi (i_spi_mosi),
    .o_spi_miso (o_spi_miso),
    .o_wb_adr   (dbg_wb_adr),
    .o_wb_dat   (dbg_wb_dat),
    .o_wb_sel   (dbg_wb_sel),
    .o_wb_we    (dbg_wb_we),
    .o_wb_stb   (dbg_wb_stb),
    .i_wb_rdt   (dbg_wb_rdt),
    .i_wb_ack   (dbg_wb_ack)
);

// ===========================================================================
// 4. Wishbone-to-SRAM adapter (SPI debug path)
//
// 3-state FSM with registered state, combinational SRAM drive and ack.
//   DBG_IDLE   — wait for stb; latch request; → DBG_ACCESS
//   DBG_ACCESS — SRAM sees CEN=0 on this clock edge; Q valid after; → DBG_DONE
//   DBG_DONE   — assert ack combinationally; read data = sram_q; → DBG_IDLE
// ===========================================================================
reg [1:0]    dbg_state;
reg [aw-1:0] dbg_addr_r;
reg [7:0]    dbg_wdata_r;
reg          dbg_we_r;

localparam DBG_IDLE   = 2'd0;
localparam DBG_ACCESS = 2'd1;
localparam DBG_DONE   = 2'd2;

always @(posedge i_clk) begin
    if (!i_rst) begin
        dbg_state   <= DBG_IDLE;
        dbg_addr_r  <= {aw{1'b0}};
        dbg_wdata_r <= 8'd0;
        dbg_we_r    <= 1'b0;
    end else begin
        case (dbg_state)
            DBG_IDLE: begin
                if (dbg_wb_stb & sel_debug) begin
                    dbg_addr_r  <= dbg_wb_adr[aw-1:0];
                    dbg_wdata_r <= dbg_wb_dat[7:0];
                    dbg_we_r    <= dbg_wb_we;
                    dbg_state   <= DBG_ACCESS;
                end
            end
            DBG_ACCESS: dbg_state <= DBG_DONE;
            DBG_DONE:   dbg_state <= DBG_IDLE;
            default:    dbg_state <= DBG_IDLE;
        endcase
    end
end

// Combinational SRAM signals from debug adapter.
// CEN=0 only during DBG_ACCESS to trigger exactly one SRAM operation.
wire dbg_active = (dbg_state == DBG_ACCESS) & sel_debug;

wire [aw-1:0] dbg_sram_addr  = dbg_addr_r;
wire [7:0]    dbg_sram_wdata = dbg_wdata_r;
wire          dbg_sram_cen   = ~dbg_active;
wire          dbg_sram_gwen  = ~dbg_we_r;
wire [7:0]    dbg_sram_wen   = dbg_we_r ? 8'h00 : 8'hFF;

// Wishbone response: combinational ack in DBG_DONE.
// sram_q is the registered SRAM output from the DBG_ACCESS cycle — valid now.
assign dbg_wb_ack = (dbg_state == DBG_DONE) & sel_debug;
assign dbg_wb_rdt = (dbg_state == DBG_DONE) ? {24'd0, sram_q} : 32'd0;

// ===========================================================================
// 5. MBIST engine (active when i_rst=1 and i_test_mode=1)
// ===========================================================================
wire [aw-1:0] mbist_sram_addr;
wire [7:0]    mbist_sram_d;
wire          mbist_sram_we;
wire          mbist_sram_ce;

sram_mbist u_mbist (
    .i_clk       (i_clk),
    .i_rst       (sel_mbist),      // held in reset unless MBIST mode active
    .i_test_mode (i_test_mode),
    .o_sram_addr (mbist_sram_addr),
    .o_sram_d    (mbist_sram_d),
    .o_sram_we   (mbist_sram_we),
    .o_sram_ce   (mbist_sram_ce),
    .i_sram_q    (sram_q),
    .o_busy      (o_mbist_busy),
    .o_pass      (o_mbist_pass),
    .o_fail      (o_mbist_fail)
);

// ===========================================================================
// 6. 3-way SRAM control mux  (priority: MBIST > SPI debug > CPU)
// ===========================================================================
wire [aw-1:0] sram_addr;
wire [7:0]    sram_wdata;
wire          sram_cen;
wire          sram_gwen;
wire [7:0]    sram_wen;

assign sram_addr  = sel_mbist ? mbist_sram_addr                  :
                    sel_debug ? dbg_sram_addr                     :
                                cpu_sram_addr;

assign sram_wdata = sel_mbist ? mbist_sram_d                     :
                    sel_debug ? dbg_sram_wdata                    :
                                cpu_wdata;

assign sram_cen   = sel_mbist ? ~mbist_sram_ce                   :
                    sel_debug ? dbg_sram_cen                      :
                                cpu_sram_cen;

assign sram_gwen  = sel_mbist ? ~mbist_sram_we                   :
                    sel_debug ? dbg_sram_gwen                     :
                                cpu_sram_gwen;

assign sram_wen   = sel_mbist ? (mbist_sram_we ? 8'h00 : 8'hFF) :
                    sel_debug ? dbg_sram_wen                      :
                                cpu_sram_wen;

// ===========================================================================
// 7. Physical 2 KiB SRAM (two banked 1024×8 GF180 macros)
// ===========================================================================
sram2048x8_gf180 u_sram (
    .CLK  (i_clk),
    .CEN  (sram_cen),
    .GWEN (sram_gwen),
    .WEN  (sram_wen),
    .A    (sram_addr),
    .D    (sram_wdata),
    .Q    (sram_q)
);

endmodule
`default_nettype wire
