// =============================================================================
// sram_mbist.v
//
// Minimal Memory Built-In Self-Test (MBIST) for the 2 KiB SRAM
// (two gf180mcu_ocd_ip_sram__sram1024x8m8wm1 macros via sram2048x8_gf180).
//
// Algorithm: March C- (industry standard, detects stuck-at, transition,
// address decoder, and most coupling faults)
//
// March C- sequence (N = 2048 locations, W = write, R = read):
//   M0: ↑{W0}            write 0x00 to all addresses ascending
//   M1: ↑{R0, W1}        ascending: read expect 0, write 1
//   M2: ↑{R1, W0}        ascending: read expect 1, write 0
//   M3: ↓{R0, W1}        descending: read expect 0, write 1
//   M4: ↓{R1, W0}        descending: read expect 1, write 0
//   M5: ↑{R0}            ascending: read expect 0 (verify)
//
// Total operations: 10N = 20,480 clock cycles + control overhead ≈ 25,000 CLKs
// At 18 MHz: < 1.4 ms per MBIST run.
//
// PINS:
//   i_test_mode   1   assert to enter MBIST (hold i_rst high too)
//   o_busy        1   high while test is running
//   o_pass        1   latches high when test completes with no errors
//   o_fail        1   latches high if any read mismatch detected
//
// SRAM interface: same debug port signals as spi_sram_debug.v
// Only ONE of spi_sram_debug or sram_mbist may drive the debug port at once;
// use a mode mux in the top-level (e.g. select based on i_test_mode).
// =============================================================================

`timescale 1 ps / 1 ps

module sram_mbist (
    input  wire        i_clk,
    input  wire        i_rst,        // must be high to enable debug access
    input  wire        i_test_mode,  // rising edge starts test

    // SRAM debug port
    output reg  [10:0] o_sram_addr,
    output reg  [7:0]  o_sram_d,
    output reg         o_sram_we,
    output reg         o_sram_ce,
    input  wire [7:0]  i_sram_q,

    // Status outputs
    output reg         o_busy,
    output reg         o_pass,
    output reg         o_fail
);

// ---------------------------------------------------------------------------
// March C- phases
// ---------------------------------------------------------------------------
localparam MARCH_PHASES = 6;
localparam MEM_DEPTH    = 2048;   // 11-bit address space

// Phase encoding
localparam PH_M0 = 3'd0;   // ↑ W0
localparam PH_M1 = 3'd1;   // ↑ R0 W1
localparam PH_M2 = 3'd2;   // ↑ R1 W0
localparam PH_M3 = 3'd3;   // ↓ R0 W1
localparam PH_M4 = 3'd4;   // ↓ R1 W0
localparam PH_M5 = 3'd5;   // ↑ R0

// Step within each phase (some phases have 2 ops: read then write)
localparam STEP_READ  = 1'b0;
localparam STEP_WRITE = 1'b1;

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------
localparam ST_IDLE     = 3'd0;
localparam ST_ISSUE    = 3'd1;   // drive SRAM for one cycle
localparam ST_SAMPLE   = 3'd2;   // latch Q and check (read phases only)
localparam ST_ADVANCE  = 3'd3;   // update address and step
localparam ST_DONE     = 3'd4;

reg [2:0]  state;
reg [2:0]  phase;      // current March phase
reg [10:0] addr;       // current address (0..2047)
reg        step;       // STEP_READ or STEP_WRITE
reg        dir;        // 0=ascending, 1=descending
reg        bg;         // background data: 0=0x00, 1=0xFF

// For registered read: save what we expected so we can compare next cycle
reg [7:0]  expected_q;
reg        check_next; // "sample Q and compare" flag

// Error accumulator
reg        error_seen;

// Edge detect on i_test_mode
reg test_mode_prev;
wire test_start = i_test_mode & ~test_mode_prev;

always @(posedge i_clk) begin
    test_mode_prev <= i_test_mode;
    o_sram_we <= 1'b0;
    o_sram_ce <= 1'b1;  // default: disabled
    check_next <= 1'b0;

    if (!i_rst) begin
        state      <= ST_IDLE;
        phase      <= PH_M0;
        addr       <= 11'd0;
        step       <= STEP_WRITE;
        dir        <= 1'b0;
        bg         <= 1'b0;
        o_busy     <= 1'b0;
        o_pass     <= 1'b0;
        o_fail     <= 1'b0;
        error_seen <= 1'b0;
        expected_q <= 8'd0;
    end else begin
        case (state)
            // ----------------------------------------------------------------
            ST_IDLE: begin
                o_busy <= 1'b0;
                if (test_start & i_rst) begin
                    // Kick off test
                    phase      <= PH_M0;
                    addr       <= 11'd0;
                    dir        <= 1'b0;   // ascending
                    bg         <= 1'b0;   // background = 0
                    step       <= STEP_WRITE;
                    error_seen <= 1'b0;
                    o_pass     <= 1'b0;
                    o_fail     <= 1'b0;
                    o_busy     <= 1'b1;
                    state      <= ST_ISSUE;
                end
            end

            // ----------------------------------------------------------------
            ST_ISSUE: begin
                // Determine what to drive based on phase + step
                o_sram_addr <= addr;
                o_sram_ce   <= 1'b0;   // enable

                case (phase)
                    PH_M0: begin   // ↑ W0: write 0x00
                        o_sram_d  <= 8'h00;
                        o_sram_we <= 1'b1;
                        state     <= ST_ADVANCE;
                    end
                    PH_M1: begin   // ↑ R0 W1
                        if (step == STEP_READ) begin
                            o_sram_we  <= 1'b0;
                            expected_q <= 8'h00;
                            check_next <= 1'b1;
                            state      <= ST_SAMPLE;
                        end else begin
                            o_sram_d  <= 8'hFF;
                            o_sram_we <= 1'b1;
                            state     <= ST_ADVANCE;
                        end
                    end
                    PH_M2: begin   // ↑ R1 W0
                        if (step == STEP_READ) begin
                            o_sram_we  <= 1'b0;
                            expected_q <= 8'hFF;
                            check_next <= 1'b1;
                            state      <= ST_SAMPLE;
                        end else begin
                            o_sram_d  <= 8'h00;
                            o_sram_we <= 1'b1;
                            state     <= ST_ADVANCE;
                        end
                    end
                    PH_M3: begin   // ↓ R0 W1
                        if (step == STEP_READ) begin
                            o_sram_we  <= 1'b0;
                            expected_q <= 8'h00;
                            check_next <= 1'b1;
                            state      <= ST_SAMPLE;
                        end else begin
                            o_sram_d  <= 8'hFF;
                            o_sram_we <= 1'b1;
                            state     <= ST_ADVANCE;
                        end
                    end
                    PH_M4: begin   // ↓ R1 W0
                        if (step == STEP_READ) begin
                            o_sram_we  <= 1'b0;
                            expected_q <= 8'hFF;
                            check_next <= 1'b1;
                            state      <= ST_SAMPLE;
                        end else begin
                            o_sram_d  <= 8'h00;
                            o_sram_we <= 1'b1;
                            state     <= ST_ADVANCE;
                        end
                    end
                    PH_M5: begin   // ↑ R0
                        o_sram_we  <= 1'b0;
                        expected_q <= 8'h00;
                        check_next <= 1'b1;
                        state      <= ST_SAMPLE;
                    end
                    default: state <= ST_DONE;
                endcase
            end

            // ----------------------------------------------------------------
            // ST_SAMPLE: GF180 SRAM Q is registered — valid one cycle after
            // the posedge where CEN was asserted. We stay one extra cycle here.
            ST_SAMPLE: begin
                // Q is now valid from the previous cycle's read
                if (i_sram_q !== expected_q)
                    error_seen <= 1'b1;

                // For two-step phases, now do the write
                case (phase)
                    PH_M1, PH_M2, PH_M3, PH_M4:
                        step  <= STEP_WRITE;
                    default: ;   // PH_M5 is read-only
                endcase
                state <= ST_ISSUE;

                // If M5 read-only phase: advance address after sample
                if (phase == PH_M5)
                    state <= ST_ADVANCE;
            end

            // ----------------------------------------------------------------
            ST_ADVANCE: begin
                step <= STEP_READ;   // next step in each phase starts with read

                // Advance address
                if (!dir) begin
                    // Ascending
                    if (addr == (MEM_DEPTH - 1)) begin
                        // End of phase — move to next phase
                        addr  <= 11'd0;
                        phase <= phase + 1;
                        if (phase == PH_M5)
                            state <= ST_DONE;
                        else begin
                            // Set direction and step for next phase
                            case (phase + 1)
                                PH_M3, PH_M4: begin
                                    dir  <= 1'b1;          // switch to descending
                                    addr <= MEM_DEPTH - 1;
                                end
                                default: dir <= 1'b0;
                            endcase
                            state <= ST_ISSUE;
                        end
                    end else begin
                        addr  <= addr + 1;
                        state <= ST_ISSUE;
                    end
                end else begin
                    // Descending
                    if (addr == 11'd0) begin
                        // End of descending phase
                        phase <= phase + 1;
                        dir   <= 1'b0;          // back to ascending
                        addr  <= 11'd0;
                        state <= ST_ISSUE;
                    end else begin
                        addr  <= addr - 1;
                        state <= ST_ISSUE;
                    end
                end
            end

            // ----------------------------------------------------------------
            ST_DONE: begin
                o_busy <= 1'b0;
                o_pass <= ~error_seen;
                o_fail <=  error_seen;
                state  <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
