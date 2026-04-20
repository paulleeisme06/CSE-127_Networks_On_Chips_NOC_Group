// Copyright 2026 [Aan Yadav & Psi Padhya]
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// ============================================================================
// mesh_router — generic XY-routed mesh router
// ============================================================================
//
// Flit format (34 bits):
//   [33]     = Valid
//   [32:29]  = Destination ID {dest_row[1:0], dest_col[1:0]}
//   [28:0]   = Payload — 29 bits, opaque to hardware
//
// CPU interface (Wishbone):
//   WRITE 0x80000000 — inject flit:
//       word[31:28] = dest id  (stored in flit[32:29])
//       word[27:24] = type     (lives in payload[27:24])
//       word[9:0]   = bitmap   (lives in payload[9:0])
//   READ  0x80000004 — receive flit: returns {3'b0, flit[28:0]}
//       do_recv checks (p>>24)&0xF == FLIT_TYPE_GHOST, p&0x3FF == bitmap
//   READ  0x80000008 — tile ID: returns {28'b0, MY_ID}
//
// FIX LOG
// =======
// Fix 1 — inject_flit bit width:
//   Was: {1'b1, dat_o[31:28], 1'b0, dat_o[27:0]}  — 35 bits (Verilator
//        truncated MSB, losing valid flag; 1'b0 padding corrupted alignment).
//   Now: {1'b1, dat_o[31:28], dat_o[28:0]}         — 34 bits correct.
//
// Fix 2 — eject path (1-slot mailbox → 4-deep FIFO):
//   Was: single eject_reg overwritten unconditionally on every new flit.
//        A second ghost flit arriving before the CPU read the first was
//        silently dropped, causing do_recv() to hang forever.
//   Now: 4-deep FIFO; route_one only claims eject slot when !fifo_full;
//        CPU pops one entry per read transaction.
//
// SERV WISHBONE NOTE
// ==================
// SERV holds stb HIGH across multiple cycles; we latch inject_flit only on
// every stb+we write cycle. Since ack=stb (immediate), each transaction is
// Reads: ack = stb (combinatorial), so SERV samples dat_i on cycle 1. OK.
// ============================================================================

module mesh_router #(
    parameter [3:0] MY_ID = 4'b0000
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] local_wb_adr,
    input  wire [31:0] local_wb_dat_o,
    output wire [31:0] local_wb_dat_i,
    input  wire        local_wb_we,
    input  wire        local_wb_stb,
    output wire        local_wb_ack,

    output reg  [33:0] n_out, s_out, e_out, w_out,
    output reg  [33:0] ne_out, nw_out, se_out, sw_out,

    input  wire [33:0] n_in, s_in, e_in, w_in,
    input  wire [33:0] ne_in, nw_in, se_in, sw_in
);
    wire [1:0] my_row = MY_ID[3:2];
    wire [1:0] my_col = MY_ID[1:0];

    // -------------------------------------------------------------------------
    // Injection — latch every write cycle (no edge detection needed)
    // -------------------------------------------------------------------------
    // FIX 3: ack = stb (combinatorial, immediate). SERV deasserts stb the very
    // next cycle after receiving ack, so each transaction occupies exactly one
    // clock cycle. There is therefore no risk of double-latching the same write,
    // and no edge detection (stb_rise / we_rise) is needed or correct.
    //
    // The original stb_rise approach misfired in Verilator because stb_prev
    // and stb are updated in the same delta cycle, causing stb_rise to
    // occasionally evaluate to 0 on legitimate new write transactions.
    reg [33:0] inject_flit;

    wire inject_write_now = local_wb_stb && local_wb_we &&
                            (local_wb_adr == 32'h80000000);

    always @(posedge clk) begin
        if (rst) begin
            inject_flit <= 34'h0;
        end else begin
            inject_flit <= 34'h0;  // default: no active flit this cycle

            if (inject_write_now) begin
                // FIX 1: 34 bits — [33]=valid, [32:29]=dest(4b), [28:0]=payload(29b)
                inject_flit <= {1'b1,
                                local_wb_dat_o[31:28],
                                local_wb_dat_o[28:0]};

                $display("[NOC t=%0t] ID=%0d INJECT raw=0x%08x dest=%0d type=%0d bmap=0x%03x",
                         $time, MY_ID,
                         local_wb_dat_o,
                         local_wb_dat_o[31:28],
                         local_wb_dat_o[27:24],
                         local_wb_dat_o[9:0]);
            end

            // ── WB MONITORS ──────────────────────────────────────────────────
            // Tile 4 (1,0): show all WB transactions
            if (MY_ID == 4 && local_wb_stb) begin
                $display("[WB  t=%0t] ID=%0d stb=%b we=%b adr=0x%08x dat_o=0x%08x",
                         $time, MY_ID,
                         local_wb_stb, local_wb_we,
                         local_wb_adr, local_wb_dat_o);
            end
            // Tile 0 (0,0): show ALL WB transactions
            if (MY_ID == 0 && local_wb_stb) begin
                $display("[WB0 t=%0t] ID=0 we=%b adr=0x%08x dat_o=0x%08x dat_i=0x%08x",
                         $time,
                         local_wb_we,
                         local_wb_adr, local_wb_dat_o,
                         local_wb_dat_i);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Ejection — 4-deep synchronous FIFO  (FIX 2)
    // -------------------------------------------------------------------------
    // Depth 4: each tile receives at most 4 ghost flits (N/S/E/W), all of
    // which can arrive before the CPU reads the first one.
    //
    localparam FIFO_DEPTH = 4;
    localparam FIFO_BITS  = 2;   // log2(4)

    reg [33:0]          fifo_mem   [0:FIFO_DEPTH-1];
    reg [FIFO_BITS-1:0] fifo_wr_ptr, fifo_rd_ptr;
    reg [FIFO_BITS:0]   fifo_count;   // extra bit distinguishes full/empty

    wire fifo_empty = (fifo_count == 0);
    wire fifo_full  = (fifo_count == FIFO_DEPTH[FIFO_BITS:0]);

    wire cpu_read = local_wb_stb && !local_wb_we &&
                    (local_wb_adr == 32'h80000004);

    // eject_flit_next driven combinationally by route_one below.
    wire [33:0] eject_flit_next;

    wire fifo_push = eject_flit_next[33] && !fifo_full;

    // Pop 1 cycle after a cpu_read that saw a valid (non-empty) flit.
    // dat_i is now combinatorial from fifo_head_comb, so SERV sees the
    // flit on the same cycle it reads. We pop on the next cycle so the
    // flit is still present when SERV samples dat_i.
    reg cpu_read_q;
    always @(posedge clk) begin
        if (rst) cpu_read_q <= 1'b0;
        else     cpu_read_q <= cpu_read && !fifo_empty;
    end
    wire fifo_pop  = cpu_read_q && !fifo_empty;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            fifo_wr_ptr <= 0;
            fifo_rd_ptr <= 0;
            fifo_count  <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1)
                fifo_mem[i] <= 34'h0;
        end else begin
            if (fifo_push) begin
                fifo_mem[fifo_wr_ptr] <= eject_flit_next;
                fifo_wr_ptr           <= fifo_wr_ptr + 1;
                // ── DEBUG ────────────────────────────────────────────────────
                $display("[NOC t=%0t] ID=%0d EJECT_IN  type=%0d bmap=0x%03x count %0d->%0d",
                         $time, MY_ID,
                         eject_flit_next[27:24], eject_flit_next[9:0],
                         fifo_count, fifo_count + 1);
                // ── TILE(0,0) ghost decode ────────────────────────────────────
                // A ghost flit has bit10 (FLIT_VALID_BIT) set in payload[10].
                // The direction it came FROM tells us which ghost buffer it fills:
                //   sent by tile(1,0) via s_out→n_in  : ghost_N for (0,0) (N nbr bottom row)
                //   sent by tile(0,1) via e_out→w_in  : ghost_E for (0,0) (E nbr left col)
                // (0,0 has no N or W neighbour, so only S-sourced and E-sourced ghosts arrive)
                if (MY_ID == 0 && eject_flit_next[10]) begin
                    $display("[GHOST_IN t=%0t] TILE(0,0) ghost flit LANDED  bmap=0x%03x  raw_flit=0x%09x",
                             $time, eject_flit_next[9:0], eject_flit_next);
                end
            end
            // ── TILE(0,0): detect ghost flit arriving when FIFO is full (dropped) ──
            if (MY_ID == 0 && eject_flit_next[33] && eject_flit_next[10] && fifo_full) begin
                $display("[GHOST_DROP t=%0t] TILE(0,0) ghost DROPPED (FIFO full) bmap=0x%03x  raw_flit=0x%09x",
                         $time, eject_flit_next[9:0], eject_flit_next);
            end
            if (fifo_pop) begin
                // ── DEBUG ────────────────────────────────────────────────────
                $display("[NOC t=%0t] ID=%0d EJECT_OUT type=%0d bmap=0x%03x count %0d->%0d",
                         $time, MY_ID,
                         fifo_mem[fifo_rd_ptr][27:24], fifo_mem[fifo_rd_ptr][9:0],
                         fifo_count, fifo_count - 1);
                // ── TILE(0,0) ghost decode ────────────────────────────────────
                if (MY_ID == 0 && fifo_mem[fifo_rd_ptr][10]) begin
                    $display("[GHOST_OUT t=%0t] TILE(0,0) ghost flit CPU-READ bmap=0x%03x  raw_flit=0x%09x",
                             $time, fifo_mem[fifo_rd_ptr][9:0], fifo_mem[fifo_rd_ptr]);
                end
                fifo_rd_ptr <= fifo_rd_ptr + 1;
            end

            if      ( fifo_push && !fifo_pop) fifo_count <= fifo_count + 1;
            else if (!fifo_push &&  fifo_pop) fifo_count <= fifo_count - 1;
        end
    end

    // Combinatorial head — SERV samples dat_i on the same cycle ack fires.
    // We must present valid data combinatorially so SERV sees it immediately.
    // The pop is delayed by 1 cycle (cpu_read_q) so the flit stays in the
    // FIFO long enough for SERV to read it before it disappears.
    wire [33:0] fifo_head_comb = fifo_empty ? 34'h0 : fifo_mem[fifo_rd_ptr];

    // Keep fifo_head_reg for the WB monitor display only
    reg  [33:0] fifo_head_reg;
    always @(posedge clk) begin
        if (rst) fifo_head_reg <= 34'h0;
        else     fifo_head_reg <= fifo_head_comb;
    end

    assign local_wb_dat_i =
        (local_wb_stb && !local_wb_we && local_wb_adr == 32'h80000008)
            ? {28'b0, MY_ID}
        : (local_wb_stb && !local_wb_we && local_wb_adr == 32'h80000004)
            ? {3'b0, fifo_head_comb[28:0]}
        : 32'h0;

    assign local_wb_ack = (~rst) & local_wb_stb;

    // -------------------------------------------------------------------------
    // Routing — XY dimension-order, combinatorial
    // -------------------------------------------------------------------------
    reg [33:0] next_n, next_s, next_e, next_w;
    reg [33:0] next_ne, next_nw, next_se, next_sw;
    reg [33:0] next_eject;

    task automatic route_one;
        input [33:0] flit;
        reg [1:0] tgt_row, tgt_col;
        begin
            tgt_row = flit[32:31];
            tgt_col = flit[30:29];

            if (tgt_row == my_row && tgt_col == my_col) begin
                // Accept only if FIFO has room (FIX 2 back-pressure).
                if (!next_eject[33] && !fifo_full) next_eject = flit;
            end else if (tgt_row > my_row && tgt_col > my_col) begin
                if (!next_se[33]) next_se = flit;
            end else if (tgt_row > my_row && tgt_col < my_col) begin
                if (!next_sw[33]) next_sw = flit;
            end else if (tgt_row < my_row && tgt_col > my_col) begin
                if (!next_ne[33]) next_ne = flit;
            end else if (tgt_row < my_row && tgt_col < my_col) begin
                if (!next_nw[33]) next_nw = flit;
            end else if (tgt_row > my_row) begin
                if (!next_s[33])  next_s  = flit;
            end else if (tgt_row < my_row) begin
                if (!next_n[33])  next_n  = flit;
            end else if (tgt_col > my_col) begin
                if (!next_e[33])  next_e  = flit;
            end else begin
                if (!next_w[33])  next_w  = flit;
            end
        end
    endtask

    always @(*) begin
        {next_n, next_s, next_e, next_w,
         next_ne, next_nw, next_se, next_sw, next_eject} = 0;

        if (inject_flit[33]) route_one(inject_flit);
        if (n_in[33])        route_one(n_in);
        if (s_in[33])        route_one(s_in);
        if (e_in[33])        route_one(e_in);
        if (w_in[33])        route_one(w_in);
        if (ne_in[33])       route_one(ne_in);
        if (nw_in[33])       route_one(nw_in);
        if (se_in[33])       route_one(se_in);
        if (sw_in[33])       route_one(sw_in);
    end

    assign eject_flit_next = next_eject;

    // ── TILE(0,0) transit & misroute monitor ─────────────────────────────────
    // Shows every flit that passes THROUGH tile (0,0) without being ejected,
    // and flags any ghost flit that is being forwarded instead of ejected
    // (which would indicate a destination ID mismatch / routing bug).
    // Combinatorial — fires in the same always @(*) evaluation window.
    always @(*) begin
        if (MY_ID == 0) begin
            // South-bound transit (heading to row 1 or 2)
            if (next_s[33])
                $display("[TRANSIT t=%0t] TILE(0,0) ->S  dest=%0d bmap=0x%03x bit10=%0b raw=0x%09x",
                         $time, {next_s[32:29]}, next_s[9:0], next_s[10], next_s);
            // East-bound transit (heading to col 1 or 2)
            if (next_e[33])
                $display("[TRANSIT t=%0t] TILE(0,0) ->E  dest=%0d bmap=0x%03x bit10=%0b raw=0x%09x",
                         $time, {next_e[32:29]}, next_e[9:0], next_e[10], next_e);
            // SE diagonal transit
            if (next_se[33])
                $display("[TRANSIT t=%0t] TILE(0,0) ->SE dest=%0d bmap=0x%03x bit10=%0b raw=0x%09x",
                         $time, {next_se[32:29]}, next_se[9:0], next_se[10], next_se);
            // Ghost flit being forwarded instead of ejected — this is a bug
            if (next_s[33]  && next_s[10])
                $display("[MISROUTE t=%0t] TILE(0,0) ghost going ->S  dest=%0d (expected dest=0) raw=0x%09x",
                         $time, {next_s[32:29]}, next_s);
            if (next_e[33]  && next_e[10])
                $display("[MISROUTE t=%0t] TILE(0,0) ghost going ->E  dest=%0d (expected dest=0) raw=0x%09x",
                         $time, {next_e[32:29]}, next_e);
            if (next_se[33] && next_se[10])
                $display("[MISROUTE t=%0t] TILE(0,0) ghost going ->SE dest=%0d (expected dest=0) raw=0x%09x",
                         $time, {next_se[32:29]}, next_se);
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            {n_out, s_out, e_out, w_out,
             ne_out, nw_out, se_out, sw_out} <= 0;
        end else begin
            n_out  <= next_n;   s_out  <= next_s;
            e_out  <= next_e;   w_out  <= next_w;
            ne_out <= next_ne;  nw_out <= next_nw;
            se_out <= next_se;  sw_out <= next_sw;
        end
    end

endmodule