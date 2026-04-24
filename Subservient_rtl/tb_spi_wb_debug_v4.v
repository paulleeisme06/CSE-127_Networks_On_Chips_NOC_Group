`timescale 1 ns / 1 ps
module tb_spi_wb_debug_v4;

localparam SYS_HALF = 27;    // 18.5 MHz
localparam SPI_HALF = 500;   // 1 MHz

reg sys_clk = 0;
always #SYS_HALF sys_clk = ~sys_clk;

reg  rst=0, cs_n=1, sck=0, mosi=0;
wire miso;
wire [31:0] wb_adr, wb_dat;
wire [3:0]  wb_sel;
wire        wb_we, wb_stb;
reg  [31:0] wb_rdt=0;
reg         wb_ack=0;

spi_wb_debug_v4 dut(
    .i_clk(sys_clk),.i_rst(rst),
    .i_spi_cs_n(cs_n),.i_spi_sck(sck),.i_spi_mosi(mosi),.o_spi_miso(miso),
    .o_wb_adr(wb_adr),.o_wb_dat(wb_dat),.o_wb_sel(wb_sel),
    .o_wb_we(wb_we),.o_wb_stb(wb_stb),.i_wb_rdt(wb_rdt),.i_wb_ack(wb_ack));

// Stub Wishbone slave with 2-cycle latency
reg [7:0] mem[0:2047];
reg [1:0] dly;
integer i;
always @(posedge sys_clk) begin
    wb_ack <= 0;
    if (wb_stb) begin
        dly <= dly + 1;
        if (dly == 1) begin
            wb_ack <= 1; dly <= 0;
            if (wb_we) mem[wb_adr[10:0]] <= wb_dat[7:0];
            else       wb_rdt <= {24'd0, mem[wb_adr[10:0]]};
        end
    end else dly <= 0;
end

// SPI primitives
task send_bit; input b;
    begin mosi=b; #SPI_HALF; sck=1; #SPI_HALF; sck=0; end
endtask

task send_byte; input [7:0] tx; integer b;
    begin for(b=7;b>=0;b=b-1) send_bit(tx[b]); end
endtask

task recv_byte; output [7:0] rx; integer b;
    begin
        rx=0;
        for(b=7;b>=0;b=b-1) begin
            mosi=0; #SPI_HALF; sck=1;
            #(SPI_HALF/4); rx[b]=miso;
            #(SPI_HALF*3/4); sck=0;
        end
    end
endtask

// High-level SPI tasks
task spi_write; input [10:0] addr; input [7:0] data;
    begin
        cs_n=0; #(SPI_HALF*2);
        send_byte(8'h01);
        send_byte({5'd0, addr[10:8]});
        send_byte(addr[7:0]);
        send_byte(data);
        #(SPI_HALF*4); cs_n=1;
        #(SPI_HALF*10);  // gap between transactions
    end
endtask

task spi_read; input [10:0] addr; output [7:0] rx;
    begin
        // Transaction A: send read command + address
        cs_n=0; #(SPI_HALF*2);
        send_byte(8'h02);
        send_byte({5'd0, addr[10:8]});
        send_byte(addr[7:0]);
        #(SPI_HALF*4); cs_n=1;
        #(SPI_HALF*20);  // wait for Wishbone ACK inside chip

        // Transaction B: clock out the result (1 byte)
        cs_n=0; #(SPI_HALF*2);
        recv_byte(rx);
        #(SPI_HALF*4); cs_n=1;
        #(SPI_HALF*10);
    end
endtask

integer pass=0, fail=0;
task check; input [7:0] got,exp; input [127:0] name;
    begin
        if(got===exp) begin $display("  PASS  %0s",name); pass=pass+1; end
        else begin $display("  FAIL  %0s  exp=0x%02h got=0x%02h",name,exp,got); fail=fail+1; end
    end
endtask

reg [7:0] rd;
initial begin
    $dumpfile("tb_spi_v2.vcd"); $dumpvars(0,tb_spi_wb_debug_v4);
    for(i=0;i<2048;i=i+1) mem[i]=8'hCC;

    repeat(10) @(posedge sys_clk);
    rst=1;
    repeat(5)  @(posedge sys_clk);

    $display("\n--- T1: basic write/read ---");
    spi_write(11'h010, 8'hA5);
    spi_read (11'h010, rd); check(rd, 8'hA5, "T1 addr=0x010");

    $display("\n--- T2: multiple addresses ---");
    spi_write(11'h000, 8'h11);
    spi_write(11'h001, 8'h22);
    spi_write(11'h002, 8'h33);
    spi_read(11'h002, rd); check(rd, 8'h33, "T2a 0x002");
    spi_read(11'h000, rd); check(rd, 8'h11, "T2b 0x000");
    spi_read(11'h001, rd); check(rd, 8'h22, "T2c 0x001");

    $display("\n--- T3: overwrite ---");
    spi_write(11'h020, 8'hFF);
    spi_read (11'h020, rd); check(rd, 8'hFF, "T3a first write");
    spi_write(11'h020, 8'h42);
    spi_read (11'h020, rd); check(rd, 8'h42, "T3b overwrite");

    $display("\n--- T4: bank boundary ---");
    spi_write(11'h3FF, 8'hAA);
    spi_write(11'h400, 8'h55);
    spi_read(11'h3FF, rd); check(rd, 8'hAA, "T4a bank0 last");
    spi_read(11'h400, rd); check(rd, 8'h55, "T4b bank1 first");
    spi_read(11'h3FF, rd); check(rd, 8'hAA, "T4c no aliasing");

    $display("\n--- T5: max address 0x7FF ---");
    spi_write(11'h7FF, 8'hBB);
    spi_read (11'h7FF, rd); check(rd, 8'hBB, "T5 max addr");

    $display("\n--- T6: unwritten canary ---");
    spi_read(11'h100, rd); check(rd, 8'hCC, "T6 canary");

    $display("\n--- T7: sequential scan of 8 bytes ---");
    begin : scan
        integer a;
        for(a=0; a<8; a=a+1) spi_write(a[10:0], a[7:0] ^ 8'hA5);
        for(a=0; a<8; a=a+1) begin
            spi_read(a[10:0], rd);
            if(rd !== (a[7:0] ^ 8'hA5)) begin
                $display("  FAIL  T7 addr=%0d exp=0x%02h got=0x%02h", a, a^8'hA5, rd);
                fail=fail+1;
            end
        end
        if(fail==0) begin $display("  PASS  T7 sequential scan"); pass=pass+1; end
    end

    #50000;
    $display("\n==========================================");
    $display("  spi_wb_debug_v4: %0d passed, %0d failed", pass, fail);
    $display("==========================================\n");
    if(fail==0) $display("ALL TESTS PASSED\n");
    $finish;
end
initial #10_000_000 begin $display("TIMEOUT"); $finish; end
endmodule
