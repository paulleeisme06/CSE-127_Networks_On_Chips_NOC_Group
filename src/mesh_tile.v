`default_nettype none

module mesh_tile #(
    parameter [3:0] TILE_ID = 4'b0000
)(
    input wire clk,
    input wire rst,
    input wire boot_mode,
    input wire [10:0] boot_addr,
    input wire [7:0] boot_data,
    input wire       boot_wen,

    input  wire [33:0] north_in, south_in, east_in, west_in,
    output wire [33:0] north_out, south_out, east_out, west_out,
    input  wire [33:0] ne_in, nw_in, se_in, sw_in,
    output wire [33:0] ne_out, nw_out, se_out, sw_out,

    input  wire [9:0]  rd_addr,
    input  wire        rd_req,
    output wire [7:0]  rd_data

`ifdef USE_POWER_PINS
    ,inout wire VDD
    ,inout wire VSS
`endif
);

    wire [31:0] wb_adr, wb_dat_c2r, wb_dat_r2c;
    wire        wb_we, wb_stb, wb_ack;

    wire [10:0] sram_waddr, sram_raddr;
    wire [7:0]  sram_wdata, sram_rdata;
    wire        sram_wen, sram_ren;

    assign rd_data = 8'b0;

    // -----------------------------------------------------------------------
    // CEN startup-pulse generator
    // -----------------------------------------------------------------------
    reg boot_mode_q;
    always @(posedge clk or posedge rst)
        if (rst) boot_mode_q <= 1'b1;
        else     boot_mode_q <= boot_mode;

    wire cpu_sram_init_pulse = boot_mode_q & ~boot_mode;

    // -----------------------------------------------------------------------
    // Address / Data MUX
    // -----------------------------------------------------------------------
    wire [10:0] final_a = boot_mode ? boot_addr : (sram_wen ? sram_waddr : sram_raddr);
    wire [7:0]  final_d = boot_mode ? boot_data : sram_wdata;

    // -----------------------------------------------------------------------
    // SRAM control
    // -----------------------------------------------------------------------
    wire sram_active = boot_mode ? ~boot_wen : ~cpu_sram_init_pulse;
    wire sram_write  = boot_mode ? ~boot_wen : sram_wen;

    // -----------------------------------------------------------------------
    // 2 x 1024x8 = 2048x8 SRAM
    // final_a[10] selects bank, final_a[9:0] is within-bank address
    // -----------------------------------------------------------------------
    wire [9:0] bank_addr = final_a[9:0];
    wire       bank_sel  = final_a[10];

    wire cen_0 = ~(sram_active & (bank_sel == 1'b0));
    wire cen_1 = ~(sram_active & (bank_sel == 1'b1));

    wire [7:0] q0, q1;

    reg bank_sel_q;
    always @(posedge clk) bank_sel_q <= bank_sel;

    assign sram_rdata = (bank_sel_q == 1'b0) ? q0 : q1;

`ifdef USE_POWER_PINS
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 sram_lo (
        .CLK(clk), .CEN(cen_0), .GWEN(~sram_write),
        .WEN(8'b0), .A(bank_addr), .D(final_d), .Q(q0),
        .VDD(VDD), .VSS(VSS)
    );
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 sram_hi (
        .CLK(clk), .CEN(cen_1), .GWEN(~sram_write),
        .WEN(8'b0), .A(bank_addr), .D(final_d), .Q(q1),
        .VDD(VDD), .VSS(VSS)
    );
`else
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 sram_lo (
        .CLK(clk), .CEN(cen_0), .GWEN(~sram_write),
        .WEN(8'b0), .A(bank_addr), .D(final_d), .Q(q0)
    );
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 sram_hi (
        .CLK(clk), .CEN(cen_1), .GWEN(~sram_write),
        .WEN(8'b0), .A(bank_addr), .D(final_d), .Q(q1)
    );
`endif

    // -----------------------------------------------------------------------
    // Subservient RISC-V core
    // -----------------------------------------------------------------------
    subservient_core #(.memsize(2048)) core_inst (
        .i_clk       (clk),
        .i_rst       (rst | boot_mode),
        .o_sram_waddr(sram_waddr),
        .o_sram_wdata(sram_wdata),
        .o_sram_wen  (sram_wen),
        .o_sram_raddr(sram_raddr),
        .i_sram_rdata(sram_rdata),
        .o_sram_ren  (sram_ren),
        .o_wb_adr    (wb_adr),
        .o_wb_dat    (wb_dat_c2r),
        .i_wb_rdt    (wb_dat_r2c),
        .o_wb_we     (wb_we),
        .o_wb_stb    (wb_stb),
        .i_wb_ack    (wb_ack),
        .i_timer_irq (1'b0)
    );

    // -----------------------------------------------------------------------
    // Mesh router
    // -----------------------------------------------------------------------
    mesh_router #(.MY_ID(TILE_ID)) router_inst (
        .clk            (clk),
        .rst            (rst),
        .local_wb_adr   (wb_adr),
        .local_wb_dat_o (wb_dat_c2r),
        .local_wb_dat_i (wb_dat_r2c),
        .local_wb_we    (wb_we),
        .local_wb_stb   (wb_stb),
        .local_wb_ack   (wb_ack),
        .n_in (north_in),  .s_in (south_in),  .e_in (east_in),  .w_in (west_in),
        .n_out(north_out), .s_out(south_out), .e_out(east_out), .w_out(west_out),
        .ne_in(ne_in),  .nw_in(nw_in),  .se_in(se_in),  .sw_in(sw_in),
        .ne_out(ne_out),.nw_out(nw_out),.se_out(se_out),.sw_out(sw_out)
    );

endmodule