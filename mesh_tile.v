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
    output wire [33:0] ne_out, nw_out, se_out, sw_out
);

    wire [31:0] wb_adr, wb_dat_c2r, wb_dat_r2c;
    wire [3:0]  wb_sel;
    wire        wb_we, wb_stb, wb_ack;

    wire [10:0] sram_waddr, sram_raddr;
    wire [7:0] sram_wdata, sram_rdata;
    wire       sram_wen, sram_ren;

    // -----------------------------------------------------------------------
    // Address pipeline registers
    // -----------------------------------------------------------------------
    // The GF180 SRAM is fully synchronous: it captures address and control
    // signals on the RISING edge of CLK (when CEN=0), then presents read data
    // after an internal access time ta=45ns — well within the 60ns cycle.
    //
    // subservient drives ALL of its SRAM outputs (sram_raddr, sram_waddr,
    // sram_wdata, sram_wen, sram_ren) as REGISTERED signals: they are stable
    // AFTER a posedge and hold steady until the next posedge.
    //
    // Timeline WITHOUT registering (broken):
    //   posedge N-1 : subservient registers new raddr=ADDR_X
    //   [combinatorial settling after posedge N-1]
    //   posedge N   : SRAM captures final_a — but final_a = ADDR_X has only
    //                 just settled; SRAM sees whatever was on the bus BEFORE
    //                 the combinatorial path settled (setup violation risk),
    //                 or worse, captures ADDR_X-1 from the previous cycle.
    //   posedge N+1 : subservient reads i_sram_rdata expecting mem[ADDR_X]
    //                 but gets mem[previous address] — WRONG DATA.
    //
    // Timeline WITH registering (correct):
    //   posedge N-1 : subservient registers raddr=ADDR_X.
    //   posedge N   : our register captures ADDR_X → reg_raddr=ADDR_X.
    //                 SRAM sees reg_raddr=ADDR_X at posedge N and captures it.
    //                 (ADDR_X has been stable since shortly after posedge N-1,
    //                  giving the full cycle as setup time — no violations.)
    //   posedge N+1 : subservient reads i_sram_rdata = mem[ADDR_X]. ✓
    //
    // The same skew affects write address, write data, and write enable.
    // All four signals are registered here for identical reasons.
    //
    // -----------------------------------------------------------------------
    // CEN startup-pulse generator
    // -----------------------------------------------------------------------
    // The GF180 SRAM model requires CEN to perform a HIGH→LOW transition to
    // arm its internal cen_fell flag before any operation is accepted.
    // After that transition CEN is held LOW permanently (synchronous mode).
    //
    reg boot_mode_q;
    always @(posedge clk or posedge rst)
        if (rst) boot_mode_q <= 1'b1;
        else     boot_mode_q <= boot_mode;

    // One-cycle HIGH pulse on the clock edge where boot_mode falls.
    wire cpu_sram_init_pulse = boot_mode_q & ~boot_mode;

    // -----------------------------------------------------------------------
    // Address / Data MUX
    // -----------------------------------------------------------------------
    // Boot mode : use raw bootloader signals (the bootloader is slow enough
    //             that its address/data are stable well before the clock edge).
    // CPU mode  : bypass the extra register to provide 1-cycle latency.
    wire [10:0] final_a = boot_mode ? boot_addr  : (sram_wen ? sram_waddr : sram_raddr);
    wire [7:0] final_d = boot_mode ? boot_data  : sram_wdata;

    // -----------------------------------------------------------------------
    // SRAM control
    // -----------------------------------------------------------------------
    // Boot  : CEN pulses LOW per byte write (boot_wen active-LOW).
    // CPU   : CEN=HIGH for init-pulse cycle, then permanently LOW.
    wire sram_active = boot_mode ? ~boot_wen : ~cpu_sram_init_pulse;

    // GWEN (active-LOW): asserted during writes only.
    wire sram_write = boot_mode ? ~boot_wen : sram_wen;

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
    // GF180 2048×8 SRAM
    // -----------------------------------------------------------------------
    gf180mcu_fd_ip_sram__sram2048x8m8wm1 sram_inst (
        .CLK (clk),
        .CEN (~sram_active),  // Active-LOW chip enable
        .GWEN(~sram_write),   // Active-LOW global write enable
        .WEN (8'b0),          // All byte lanes active when GWEN asserted
        .A   (final_a),
        .D   (final_d),
        .Q   (sram_rdata),
        .VDD (),
        .VSS ()
    );

    // DEBUG: monitor ALL non-zero SRAM writes (to find where do_recv writes go)
    always @(posedge clk) begin
        if (!boot_mode && sram_wen && final_d != 8'h00 && TILE_ID == 4) begin
            $display("[SRAM t=%0t] MY_ID=%0d WRITE addr=0x%03x data=0x%02x",
                     $time, TILE_ID, final_a, final_d);
        end
    end

    // ── TILE(0,0) ghost buffer write monitor ─────────────────────────────────
    // ghost_N  @ 0x0600..0x0609  — bottom row of north neighbour  (none for (0,0), should stay 0)
    // ghost_S  @ 0x060A..0x0613  — top    row of south neighbour  tile(1,0)
    // ghost_W  @ 0x0614..0x061D  — right  col of west  neighbour  (none for (0,0), should stay 0)
    // ghost_E  @ 0x061E..0x0627  — left   col of east  neighbour  tile(0,1)
    // Watching these writes confirms recv_ghost() decoded the bitmap correctly
    // and stored it into the right buffer slot.
    always @(posedge clk) begin
        if (!boot_mode && TILE_ID == 0 && sram_wen) begin
            if (final_a >= 11'h600 && final_a <= 11'h609)
                $display("[GHOST_BUF t=%0t] TILE(0,0) ghost_N[%0d] <= %0d  (addr=0x%03x)",
                         $time, {21'b0, final_a} - 32'h600, final_d, final_a);
            if (final_a >= 11'h60A && final_a <= 11'h613)
                $display("[GHOST_BUF t=%0t] TILE(0,0) ghost_S[%0d] <= %0d  (addr=0x%03x)",
                         $time, {21'b0, final_a} - 32'h60A, final_d, final_a);
            if (final_a >= 11'h614 && final_a <= 11'h61D)
                $display("[GHOST_BUF t=%0t] TILE(0,0) ghost_W[%0d] <= %0d  (addr=0x%03x)",
                         $time, {21'b0, final_a} - 32'h614, final_d, final_a);
            if (final_a >= 11'h61E && final_a <= 11'h627)
                $display("[GHOST_BUF t=%0t] TILE(0,0) ghost_E[%0d] <= %0d  (addr=0x%03x)",
                         $time, {21'b0, final_a} - 32'h61E, final_d, final_a);
        end
    end

    // ── TILE(0,0) next_grid boundary cell write monitor ───────────────────────
    // next_grid @ 0x0640..0x06A3  (10x10 = 100 bytes, row-major)
    // Only prints border cells (row 0, row 9, col 0, col 9) because those are
    // the cells whose neighbour_count() uses ghost buffer values — interior
    // cells only touch grid[] which is always local and unambiguous.
    always @(posedge clk) begin
        if (!boot_mode && TILE_ID == 0 && sram_wen &&
            final_a >= 11'h640 && final_a <= 11'h6A3) begin
            begin : ng_block
                integer ng_off, ng_row, ng_col;
                ng_off = {21'b0, final_a} - 32'h640;
                ng_row = ng_off / 10;
                ng_col = ng_off % 10;
                if (ng_row == 0 || ng_row == 9 || ng_col == 0 || ng_col == 9)
                    $display("[NEXT_GRID t=%0t] TILE(0,0) next_grid[%0d][%0d] <= %0d  (addr=0x%03x)",
                             $time, ng_row, ng_col, final_d, final_a);
            end
        end
    end

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