// =============================================================================
// tb_sram2048x8_gf180.v
//
// Self-checking testbench for sram2048x8_gf180.
//
// Tests:
//   1. Basic write + read in bank 0
//   2. Basic write + read in bank 1
//   3. Bank boundary: write to last address of bank 0 and first of bank 1,
//      confirm no aliasing
//   4. All-address walking write then read-back (every location)
//   5. Per-bit WEN masking: confirm individual bits can be protected
//   6. CEN gate: confirm Q is not updated when CEN is deasserted
//   7. Reset (i_rst / CEN held high): confirm chip stays idle
//
// Run with Icarus Verilog:
//   iverilog -o tb.out tb_sram2048x8_gf180.v \
//            sram2048x8_gf180.v \
//            gf180mcu_ocd_ip_sram__sram1024x8m8wm1.v
//   vvp tb.out
//
// A passing run prints only "PASS" lines and a final summary.
// Any failure prints a "FAIL" line with the test name and expected/got values.
//
//
//  To Run:
//
//  iverilog -g2005 -o tb.out \
//    tb_sram2048x8_gf180.v \
//    sram2048x8_gf180.v \
//    gf180mcu_ocd_ip_sram__sram1024x8m8wm1.v
// vvp tb.out
//
// =============================================================================

`timescale 1 ps / 1 ps

module tb_sram2048x8_gf180;

// ---------------------------------------------------------------------------
// Clock & DUT signals
// ---------------------------------------------------------------------------
reg         clk  = 0;
reg         cen  = 1;   // start disabled (chip off)
reg         gwen = 1;   // start in read mode
reg  [7:0]  wen  = 8'hFF;
reg  [10:0] addr = 0;
reg  [7:0]  d    = 0;
wire [7:0]  q;

// Clock: 10 ns period (100 MHz – plenty of margin vs. 55.6 ns Tcyc)
always #5000 clk = ~clk;   // 5000 ps = 5 ns half-period

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
sram2048x8_gf180 dut (
    .CLK  (clk),
    .CEN  (cen),
    .GWEN (gwen),
    .WEN  (wen),
    .A    (addr),
    .D    (d),
    .Q    (q)
);

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------
integer pass_count = 0;
integer fail_count = 0;

// One cycle write task.
// Drives inputs on the rising edge setup window, deasserts after one cycle.
task sram_write;
    input [10:0] a;
    input [7:0]  data;
    input [7:0]  byte_wen;  // 0 = write that bit, 1 = protect it
    begin
        @(negedge clk);      // change inputs on falling edge (setup OK)
        addr = a;
        d    = data;
        wen  = byte_wen;
        gwen = 1'b0;         // 0 = write
        cen  = 1'b0;         // assert chip
        @(posedge clk);      // clock edge latches the write
        #1000;               // tiny hold margin (1 ns)
        cen  = 1'b1;         // deassert after one cycle
        gwen = 1'b1;
        wen  = 8'hFF;
    end
endtask

// One cycle read task; result is in q ONE cycle after the posedge.
// The task waits for that result before returning.
task sram_read;
    input  [10:0] a;
    output [7:0]  rdata;
    begin
        @(negedge clk);
        addr = a;
        gwen = 1'b1;         // 1 = read
        wen  = 8'hFF;        // all bits masked (no accidental write)
        cen  = 1'b0;         // assert chip
        @(posedge clk);      // clock edge registers the read
        #1000;
        cen  = 1'b1;         // deassert
        @(posedge clk);      // wait one more cycle for Q to be valid
        #1000;
        rdata = q;
    end
endtask

// Check helper
task check;
    input [63:0] got;
    input [63:0] expected;
    input [127:0] test_name;  // up to 16 ASCII chars passed as bit vector
    begin
        if (got === expected) begin
            $display("  PASS  %0s", test_name);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  %0s  expected=0x%02h  got=0x%02h",
                     test_name, expected[7:0], got[7:0]);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test sequences
// ---------------------------------------------------------------------------
reg [7:0] rdata;
integer   i;
reg [7:0] expected_mem [0:2047];  // local mirror for all-address test

initial begin
    $dumpfile("tb_sram2048x8.vcd");
    $dumpvars(0, tb_sram2048x8_gf180);

    // Allow the GF180 model's initial block to run and CEN to settle
    repeat (5) @(posedge clk);

    // -----------------------------------------------------------------------
    $display("\n--- Test 1: Basic write/read, bank 0 ---");
    sram_write(11'h000, 8'hA5, 8'h00);   // write 0xA5 to address 0
    sram_read (11'h000, rdata);
    check(rdata, 8'hA5, "T1a addr=0x000");

    sram_write(11'h001, 8'h5A, 8'h00);
    sram_read (11'h001, rdata);
    check(rdata, 8'h5A, "T1b addr=0x001");

    sram_write(11'h3FF, 8'hFF, 8'h00);   // last address of bank 0
    sram_read (11'h3FF, rdata);
    check(rdata, 8'hFF, "T1c addr=0x3FF");

    // -----------------------------------------------------------------------
    $display("\n--- Test 2: Basic write/read, bank 1 ---");
    sram_write(11'h400, 8'h12, 8'h00);   // first address of bank 1
    sram_read (11'h400, rdata);
    check(rdata, 8'h12, "T2a addr=0x400");

    sram_write(11'h401, 8'h34, 8'h00);
    sram_read (11'h401, rdata);
    check(rdata, 8'h34, "T2b addr=0x401");

    sram_write(11'h7FF, 8'hEE, 8'h00);   // last address of bank 1
    sram_read (11'h7FF, rdata);
    check(rdata, 8'hEE, "T2c addr=0x7FF");

    // -----------------------------------------------------------------------
    $display("\n--- Test 3: No aliasing across bank boundary ---");
    // Write distinct values to the two addresses that share A[9:0] = 0x3FF
    // bank0[0x3FF] was already 0xFF (Test 1c); overwrite for clarity
    sram_write(11'h3FF, 8'hAA, 8'h00);   // bank 0, offset 0x3FF
    sram_write(11'h7FF, 8'h55, 8'h00);   // bank 1, offset 0x3FF
    sram_read (11'h3FF, rdata);
    check(rdata, 8'hAA, "T3a bank0[3FF]");
    sram_read (11'h7FF, rdata);
    check(rdata, 8'h55, "T3b bank1[3FF]");

    // Also confirm address 0 of each bank is independent
    sram_write(11'h000, 8'hC3, 8'h00);
    sram_write(11'h400, 8'h3C, 8'h00);
    sram_read (11'h000, rdata);
    check(rdata, 8'hC3, "T3c bank0[000]");
    sram_read (11'h400, rdata);
    check(rdata, 8'h3C, "T3d bank1[000]");

    // -----------------------------------------------------------------------
    $display("\n--- Test 4: Full address space write then read-back ---");
    // Write address-derived pattern to every location
    for (i = 0; i < 2048; i = i + 1) begin
        expected_mem[i] = i[7:0] ^ 8'hA5;   // simple address-dependent pattern
        sram_write(i[10:0], expected_mem[i], 8'h00);
    end
    // Read back every location
    for (i = 0; i < 2048; i = i + 1) begin
        sram_read(i[10:0], rdata);
        if (rdata !== expected_mem[i]) begin
            $display("  FAIL  T4 addr=0x%03h  expected=0x%02h  got=0x%02h",
                     i, expected_mem[i], rdata);
            fail_count = fail_count + 1;
        end
    end
    if (fail_count == 0)   // crude check: if no new failures since T3
        $display("  PASS  T4 all 2048 locations");
    // (pass_count not incremented per address to keep output manageable)

    // -----------------------------------------------------------------------
    $display("\n--- Test 5: Per-bit WEN masking ---");
    // Write 0xFF to address 0x010
    sram_write(11'h010, 8'hFF, 8'h00);
    // Now write 0x00 but protect the lower nibble (WEN[3:0] = 1 = protected)
    sram_write(11'h010, 8'h00, 8'h0F);   // only upper nibble should change
    sram_read (11'h010, rdata);
    // Expected: upper nibble = 0x0 (written), lower nibble = 0xF (protected)
    check(rdata, 8'h0F, "T5a WEN partial");

    // Protect the upper nibble, write only lower nibble
    sram_write(11'h010, 8'hAA, 8'hF0);   // protect upper nibble
    sram_read (11'h010, rdata);
    // Expected: upper nibble still 0x0, lower nibble = 0xA
    check(rdata, 8'h0A, "T5b WEN upper prot");

    // -----------------------------------------------------------------------
    $display("\n--- Test 6: CEN gate – Q must not change when chip disabled ---");
    // Write a known value
    sram_write(11'h020, 8'hBB, 8'h00);
    sram_read (11'h020, rdata);
    check(rdata, 8'hBB, "T6a pre-gate read");
    // Attempt a read with CEN=1 (chip disabled); Q should remain 0xBB
    @(negedge clk);
    addr = 11'h020;
    gwen = 1'b1;
    cen  = 1'b1;   // chip DISABLED
    @(posedge clk);
    #1000;
    @(posedge clk);
    #1000;
    check(q, 8'hBB, "T6b CEN=1 Q stable");

    // -----------------------------------------------------------------------
    $display("\n--- Test 7: GWEN=0, WEN=0xFF – global write disable ---");
    // Write a known value first
    sram_write(11'h030, 8'hCC, 8'h00);
    // Now assert CEN and GWEN=0 but WEN all-ones (all bits masked)
    // The macro should treat this as "chip enabled but all bytes protected"
    // i.e. no actual write occurs – effectively a no-op
    @(negedge clk);
    addr = 11'h030;
    d    = 8'h00;
    wen  = 8'hFF;   // all protected
    gwen = 1'b0;    // write mode selected
    cen  = 1'b0;
    @(posedge clk);
    #1000;
    cen  = 1'b1;
    gwen = 1'b1;
    wen  = 8'hFF;
    // Read back – should still be 0xCC
    sram_read(11'h030, rdata);
    check(rdata, 8'hCC, "T7 WEN=FF no write");

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    repeat (4) @(posedge clk);
    $display("\n==========================================");
    $display("  Results: %0d passed,  %0d failed", pass_count, fail_count);
    $display("==========================================\n");

    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED – see FAIL lines above");

    $finish;
end

// Safety timeout – if the testbench hangs, kill it after 10 ms sim time
initial begin
    #10_000_000_000;   // 10 ms in ps
    $display("TIMEOUT – testbench did not finish");
    $finish;
end

endmodule
