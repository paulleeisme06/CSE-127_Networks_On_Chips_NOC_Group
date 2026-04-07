// Copyright 2026 [Aan Yadav & Psi Padhya]
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// ============================================================================
// mesh_router — generic XY-routed mesh router
// ============================================================================
//
// Flit format (34 bits):
//   [33]     = Valid
//   [32:29]  = Destination ID {dest_row[1:0], dest_col[1:0]}  (routing only)
//   [28:0]   = Payload — OPAQUE to hardware, never inspected or modified
//
// CPU <-> Router interface (Wishbone):
//   WRITE to NOC_INJECT_BASE (0x80000000):
//     The CPU writes a full 32-bit word.  The hardware uses ONLY bits [32:29]
//     (i.e. wb_dat_o[32:29] — but since Wishbone data is 32-bit, the dest
//     is encoded in wb_dat_o[31:28] and payload in wb_dat_o[27:0]).
//
//     Flit wire layout packed from a single 32-bit CPU write:
//       flit[33]    = 1 (valid, set by hardware on inject)
//       flit[32:29] = wb_dat_o[31:28]  (destination ID — 4 bits)
//       flit[28:0]  = wb_dat_o[27: 0]  (payload — 29 bits, opaque)
//
//     This means the C code owns the full encoding.  To send payload P to
//     tile (r,c), the CPU writes:
//       *NOC_INJECT = ((r << 2 | c) << 28) | (P & 0x0FFFFFFF)
//
//   READ from NOC_RECV_BASE (0x80000004):
//     Returns the most-recently-received flit payload as a 32-bit word:
//       [31:28] = source routing bits (dest field from the flit, which equals
//                 this tile's own ID since it was addressed here) — useful
//                 for the CPU to confirm delivery but otherwise opaque.
//       [27: 0] = payload bits [27:0] (same 28 bits the sender put there)
//     Hardware delivers the full flit[28:0] zero-extended to 32 bits.
//     The C code interprets the meaning of every bit.
//
// Routing:
//   XY dimension-order routing.  No virtual channels, no backpressure.
//   Collision policy: first-come-first-served (inject > N > S > E > W > diagonals).
//   Packets for this tile are placed in a one-entry eject register and
//   NOT forwarded onto any output link.
//
// ============================================================================

module mesh_router #(
    parameter [3:0] MY_ID = 4'b0000   // {row[1:0], col[1:0]}
)(
    input  wire        clk,
    input  wire        rst,

    // Wishbone interface to local SERV CPU
    input  wire [31:0] local_wb_adr,
    input  wire [31:0] local_wb_dat_o,
    output reg  [31:0] local_wb_dat_i,
    input  wire        local_wb_we,
    input  wire        local_wb_stb,
    output wire        local_wb_ack,

    // Mesh links — 34-bit flits
    output reg  [33:0] n_out, s_out, e_out, w_out,
    output reg  [33:0] ne_out, nw_out, se_out, sw_out,

    input  wire [33:0] n_in, s_in, e_in, w_in,
    input  wire [33:0] ne_in, nw_in, se_in, sw_in
);
    wire [1:0] my_row = MY_ID[3:2];
    wire [1:0] my_col = MY_ID[1:0];

    // -------------------------------------------------------------------------
    // Injection: CPU write to 0x80000000 injects a flit for one cycle.
    //
    // The CPU encodes the full 32-bit word as:
    //   bits [31:28] = destination ID  (4 bits: {dest_row, dest_col})
    //   bits [27: 0] = payload         (28 bits, opaque)
    //
    // Hardware packs this into the 34-bit flit:
    //   flit[33]    = valid (1)
    //   flit[32:29] = dest ID  (= wb_dat_o[31:28])
    //   flit[28: 0] = {1'b0, payload[27:0]}  — bit 28 always 0, payload in [27:0]
    //
    // The CPU therefore gets 28 bits of usable payload per flit.
    // -------------------------------------------------------------------------
    reg [33:0] inject_flit;

    always @(posedge clk) begin
        if (rst)
            inject_flit <= 34'h0;
        else if (local_wb_stb && local_wb_we && local_wb_adr == 32'h80000000)
            // Pack: valid=1, dest=dat[31:28], payload=dat[27:0] (bit28 set to 0)
            inject_flit <= {1'b1, local_wb_dat_o[31:28], 1'b0, local_wb_dat_o[27:0]};
        else
            inject_flit <= 34'h0;
    end

    // -------------------------------------------------------------------------
    // Ejection: one-entry register for packets addressed to this tile.
    // Written by the routing combinatorial block (eject_flit_next).
    // CPU reads it at 0x80000004; hardware delivers flit[28:0] zero-extended.
    // The register is cleared one cycle after the CPU reads it.
    // -------------------------------------------------------------------------
    reg  [33:0] eject_reg;
    wire [33:0] eject_flit_next;   // driven by routing block below

    // Track whether the CPU has read the ejected flit
    wire cpu_read = local_wb_stb && !local_wb_we && (local_wb_adr == 32'h80000004);

    always @(posedge clk) begin
        if (rst)
            eject_reg <= 34'h0;
        else if (eject_flit_next[33])
            // New packet arrived for us — latch it (overwrites unread data)
            eject_reg <= eject_flit_next;
        else if (cpu_read)
            // CPU has consumed it — clear valid so it doesn't re-read stale data
            eject_reg <= 34'h0;
    end

    // CPU read data: full flit payload zero-extended to 32 bits
    always @(posedge clk) begin
        if (rst)
            local_wb_dat_i <= 32'h0;
        else if (cpu_read)
            local_wb_dat_i <= {3'b0, eject_reg[28:0]};
        else
            local_wb_dat_i <= 32'h0;
    end

    // Wishbone ACK: combinatorial, one cycle
    assign local_wb_ack = (~rst) & local_wb_stb;

    // -------------------------------------------------------------------------
    // Routing — XY dimension-order, combinatorial
    //
    // Priority: inject > n_in > s_in > e_in > w_in > ne_in > nw_in > se_in > sw_in
    // First valid flit wins each output port.  This is a simple but correct
    // approach for low-traffic scenarios; add arbitration for production use.
    //
    // Packets addressed to this tile go to eject_flit_next (NOT onto any link).
    // -------------------------------------------------------------------------
    reg [33:0] next_n, next_s, next_e, next_w;
    reg [33:0] next_ne, next_nw, next_se, next_sw;
    reg [33:0] next_eject;

    // Route a single flit — updates the appropriate next_* register only if
    // that register hasn't already been claimed this cycle (first-wins).
    task automatic route_one;
        input [33:0] flit;
        reg [1:0] tgt_row, tgt_col;
        begin
            tgt_row = flit[32:31];
            tgt_col = flit[30:29];

            if (tgt_row == my_row && tgt_col == my_col) begin
                // Local delivery
                if (!next_eject[33]) next_eject = flit;

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

            end else begin   // tgt_col < my_col
                if (!next_w[33])  next_w  = flit;
            end
        end
    endtask

    always @(*) begin
        {next_n, next_s, next_e, next_w,
         next_ne, next_nw, next_se, next_sw, next_eject} = 0;

        // Priority order: inject first, then cardinal, then diagonal
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

    // Register all output links
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