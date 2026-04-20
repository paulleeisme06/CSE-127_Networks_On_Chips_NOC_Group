`default_nettype none

// ============================================================================
// host_spi_slave — Host ↔ Chip SPI gateway  (Mode 0: CPOL=0 CPHA=0)
// ============================================================================
//
// Command protocol (all MSB-first, one transaction per CS assertion):
//
//  CMD 0x00  WRITE_SRAM — write one byte to all 9 tile SRAMs simultaneously
//    Byte 0 : 0x00
//    Byte 1 : addr[9:8]  (upper 2 bits of 10-bit SRAM address)
//    Byte 2 : addr[7:0]  (lower 8 bits)
//    Byte 3 : data[7:0]  (byte to write)
//    → pulses sram_wen for one sys_clk, drives sram_waddr / sram_wdata
//      All 9 tiles share the same boot_addr/boot_data/boot_wen bus so they
//      all receive the same write simultaneously (matches boot_controller).
//
//  CMD 0x02  READ_RESULT — read one byte from one tile's SRAM
//    Byte 0 : 0x02
//    Byte 1 : tile_id = {tile_row[1:0], tile_col[1:0], 4'b0} (upper nibble)
//    Byte 2 : addr[9:8]
//    Byte 3 : addr[7:0]
//    Host then clocks one more byte while chip drives MISO with rd_data.
//
//  CMD 0x03  SET_RESET — control cpu_reset for all tiles
//    Byte 0 : 0x03
//    Byte 1 : 0xFF = assert reset (hold cores)
//             0x00 = release reset (let cores run)
//
// ============================================================================

module host_spi_slave (
    input  wire        sys_clk,
    input  wire        sys_rst,

    // SPI pins (host is master)
    input  wire        spi_csb,
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    output reg         spi_miso,

    // Broadcast SRAM write bus (connects to same bus as boot_controller)
    output reg  [9:0]  sram_waddr,
    output reg  [7:0]  sram_wdata,
    output reg         sram_wen,      // active-high, one sys_clk pulse

    // CPU reset override
    output reg         host_rst,      // 1 = hold cores in reset
    output reg         host_rst_en,   // 1 = host owns reset, 0 = boot_controller owns

    // Readback interface (to rd_crossbar)
    output reg  [3:0]  rd_tile,       // {tile_row[1:0], tile_col[1:0]}
    output reg  [9:0]  rd_addr,
    output reg         rd_req,        // one sys_clk pulse
    input  wire [7:0]  rd_data
);

    // -----------------------------------------------------------------------
    // SPI edge detection — double-register synchroniser into sys_clk domain
    // -----------------------------------------------------------------------
    reg sclk_r0, sclk_r1;
    reg csb_r0,  csb_r1,  csb_r2;
    reg mosi_r;

    always @(posedge sys_clk) begin
        sclk_r0 <= spi_sclk;
        sclk_r1 <= sclk_r0;
        csb_r0  <= spi_csb;
        csb_r1  <= csb_r0;
        csb_r2  <= csb_r1;
        mosi_r  <= spi_mosi;
    end

    wire sclk_rise   =  sclk_r0 & ~sclk_r1;
    wire sclk_fall   = ~sclk_r0 &  sclk_r1;
    wire cs_active   = ~csb_r1;
    wire cs_deassert =  csb_r1 & ~csb_r2;

    // -----------------------------------------------------------------------
    // RX — 8-bit shift register, sample on SCLK rising edge, MSB first
    // -----------------------------------------------------------------------
    reg [7:0] rx_shift;
    reg [2:0] rx_bit;
    reg       rx_byte_rdy;

    always @(posedge sys_clk) begin
        rx_byte_rdy <= 1'b0;
        if (!cs_active) begin
            rx_shift <= 8'h00;
            rx_bit   <= 3'd7;
        end else if (sclk_rise) begin
            rx_shift <= {rx_shift[6:0], mosi_r};
            if (rx_bit == 3'd0) begin
                rx_bit      <= 3'd7;
                rx_byte_rdy <= 1'b1;
            end else begin
                rx_bit <= rx_bit - 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // TX — 8-bit shift register, shift on SCLK falling edge, MSB first
    // -----------------------------------------------------------------------
    reg [7:0] tx_shift;
    reg       tx_load;
    reg [7:0] tx_next;

    always @(posedge sys_clk) begin
        if (!cs_active) begin
            tx_shift <= 8'hFF;
            spi_miso <= 1'b1;
        end else begin
            if (tx_load) begin
                tx_shift <= tx_next;
                spi_miso <= tx_next[7];
            end else if (sclk_fall) begin
                spi_miso <= tx_shift[6];
                tx_shift <= {tx_shift[6:0], 1'b1};
            end
        end
    end

    // -----------------------------------------------------------------------
    // Protocol FSM
    // -----------------------------------------------------------------------
    localparam ST_IDLE       = 4'd0;
    localparam ST_CMD        = 4'd1;
    localparam ST_WR_ADDRHI  = 4'd2;
    localparam ST_WR_ADDRLO  = 4'd3;
    localparam ST_WR_DATA    = 4'd4;
    localparam ST_WR_COMMIT  = 4'd5;
    localparam ST_RD_TILE    = 4'd6;
    localparam ST_RD_ADDRHI  = 4'd7;
    localparam ST_RD_ADDRLO  = 4'd8;
    localparam ST_RD_WAIT    = 4'd9;
    localparam ST_RD_SEND    = 4'd10;
    localparam ST_RST_ARG    = 4'd11;
    localparam ST_DONE       = 4'd12;

    reg [3:0] state;
    reg [1:0] addr_hi_r;

    always @(posedge sys_clk) begin
        sram_wen <= 1'b0;
        rd_req   <= 1'b0;
        tx_load  <= 1'b0;

        if (sys_rst) begin
            state       <= ST_IDLE;
            host_rst    <= 1'b0;
            host_rst_en <= 1'b0;
            sram_waddr  <= 10'h0;
            sram_wdata  <= 8'h0;
            rd_tile     <= 4'h0;
            rd_addr     <= 10'h0;
        end else if (cs_deassert) begin
            state <= ST_IDLE;
        end else begin
            case (state)

                ST_IDLE:
                    if (cs_active) state <= ST_CMD;

                ST_CMD:
                    if (rx_byte_rdy) begin
                        case (rx_shift)
                            8'h00:   state <= ST_WR_ADDRHI;
                            8'h02:   state <= ST_RD_TILE;
                            8'h03:   state <= ST_RST_ARG;
                            default: state <= ST_DONE;
                        endcase
                    end

                // ---- WRITE_SRAM ----
                ST_WR_ADDRHI:
                    if (rx_byte_rdy) begin
                        addr_hi_r <= rx_shift[1:0];
                        state     <= ST_WR_ADDRLO;
                    end

                ST_WR_ADDRLO:
                    if (rx_byte_rdy) begin
                        sram_waddr <= {addr_hi_r, rx_shift};
                        state      <= ST_WR_DATA;
                    end

                ST_WR_DATA:
                    if (rx_byte_rdy) begin
                        sram_wdata <= rx_shift;
                        state      <= ST_WR_COMMIT;
                    end

                ST_WR_COMMIT: begin
                    sram_wen <= 1'b1;   // one-cycle broadcast write
                    state    <= ST_DONE;
                end

                // ---- READ_RESULT ----
                ST_RD_TILE:
                    if (rx_byte_rdy) begin
                        rd_tile <= rx_shift[7:4];
                        state   <= ST_RD_ADDRHI;
                    end

                ST_RD_ADDRHI:
                    if (rx_byte_rdy) begin
                        addr_hi_r <= rx_shift[1:0];
                        state     <= ST_RD_ADDRLO;
                    end

                ST_RD_ADDRLO:
                    if (rx_byte_rdy) begin
                        rd_addr <= {addr_hi_r, rx_shift};
                        rd_req  <= 1'b1;
                        state   <= ST_RD_WAIT;
                    end

                ST_RD_WAIT: begin
                    // One cycle SRAM read latency
                    tx_next <= rd_data;
                    tx_load <= 1'b1;
                    state   <= ST_RD_SEND;
                end

                ST_RD_SEND:
                    state <= ST_DONE;   // shifting out; wait for CS deassert

                // ---- SET_RESET ----
                ST_RST_ARG:
                    if (rx_byte_rdy) begin
                        host_rst_en <= 1'b1;
                        host_rst    <= (rx_shift == 8'hFF);
                        state       <= ST_DONE;
                    end

                ST_DONE: ; // wait for CS deassert

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule