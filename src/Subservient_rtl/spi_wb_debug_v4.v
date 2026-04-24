`timescale 1 ns / 1 ps
`default_nettype none
// spi_wb_debug_v4.v — corrected, all bugs fixed from simulation
// Protocol unchanged from v3. Fixes: max_byte_idx race condition eliminated.
module spi_wb_debug_v4 (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_spi_cs_n,
    input  wire        i_spi_sck,
    input  wire        i_spi_mosi,
    output reg         o_spi_miso,
    output reg  [31:0] o_wb_adr,
    output reg  [31:0] o_wb_dat,
    output reg  [3:0]  o_wb_sel,
    output reg         o_wb_we,
    output reg         o_wb_stb,
    input  wire [31:0] i_wb_rdt,
    input  wire        i_wb_ack
);

localparam CMD_WRITE = 8'h01;
localparam CMD_READ  = 8'h02;

reg [2:0] sck_r, cs_r, mosi_r;
always @(posedge i_clk) begin
    sck_r  <= {sck_r[1:0],  i_spi_sck};
    cs_r   <= {cs_r[1:0],   i_spi_cs_n};
    mosi_r <= {mosi_r[1:0], i_spi_mosi};
end
wire sck_rise = ~sck_r[2] &  sck_r[1];
wire sck_fall =  sck_r[2] & ~sck_r[1];
wire cs_act   = ~cs_r[1];
wire mosi_bit =  mosi_r[1];

reg [7:0] byte_shreg;
reg [2:0] bit_pos;
reg [1:0] byte_idx;    // which byte within frame (0=cmd, 1=addr_hi, etc.)
reg [1:0] frame_end;   // byte index at which frame is complete (set after byte 0)

reg [7:0] cmd_byte;
reg [7:0] addr_hi;
reg [7:0] addr_lo;
reg [7:0] data_byte;
wire [10:0] full_addr = {addr_hi[2:0], addr_lo};

reg [7:0] miso_reg;
reg [7:0] miso_shift;

localparam ST_IDLE    = 3'd0;
localparam ST_SHIFT   = 3'd1;
localparam ST_WB_SET  = 3'd2;
localparam ST_WB_WAIT = 3'd3;
localparam ST_DONE    = 3'd4;
reg [2:0] state;

// Combinatorial: number of bytes-1 for each command (frame_end set after cmd byte received)
function [1:0] cmd_to_frame_end;
    input [7:0] cmd;
    begin
        case (cmd)
            CMD_WRITE: cmd_to_frame_end = 2'd3;  // 4 bytes (0..3)
            CMD_READ:  cmd_to_frame_end = 2'd2;  // 3 bytes (0..2)
            default:   cmd_to_frame_end = 2'd0;  // 1 byte  (0 only) = FETCH
        endcase
    end
endfunction

always @(posedge i_clk) begin
    o_wb_stb <= 0;
    o_wb_we  <= 0;

    if (!i_rst) begin
        state      <= ST_IDLE;
        bit_pos    <= 0; byte_idx <= 0;
        byte_shreg <= 0; frame_end <= 0;
        cmd_byte   <= 0; addr_hi <= 0; addr_lo <= 0; data_byte <= 0;
        miso_reg   <= 0; miso_shift <= 0;
        o_spi_miso <= 0;
    end else begin

        case (state)

        ST_IDLE: begin
            bit_pos    <= 0;
            byte_idx   <= 0;
            byte_shreg <= 0;
            frame_end  <= 0;     // reset so byte 0 sets it fresh
            if (cs_act) begin
                o_spi_miso <= miso_reg[7];             // pre-drive bit 7
                miso_shift <= {miso_reg[6:0], 1'b0};   // pre-shift
                state      <= ST_SHIFT;
            end
        end

        ST_SHIFT: begin
            if (!cs_act) begin state <= ST_IDLE; end  // abort

            if (sck_rise) begin
                byte_shreg <= {byte_shreg[6:0], mosi_bit};
                bit_pos    <= bit_pos + 1;

                if (bit_pos == 3'd7) begin
                    // Complete byte received — latch by position
                    bit_pos  <= 0;
                    case (byte_idx)
                        2'd0: begin
                            cmd_byte  <= {byte_shreg[6:0], mosi_bit};
                            // Set frame length based on this command byte.
                            // frame_end is set here so bytes 1+ compare correctly.
                            frame_end <= cmd_to_frame_end({byte_shreg[6:0], mosi_bit});
                            // For 1-byte commands (FETCH), frame_end = 0 = byte_idx:
                            // cannot compare yet (frame_end not updated until next cycle).
                            // Solve by checking cmd directly:
                            if (cmd_to_frame_end({byte_shreg[6:0], mosi_bit}) == 2'd0) begin
                                state <= ST_WB_SET;  // 1-byte frame done
                            end else begin
                                byte_idx <= byte_idx + 1;
                            end
                        end
                        2'd1: begin
                            addr_hi  <= {byte_shreg[6:0], mosi_bit};
                            if (frame_end == 2'd1) state <= ST_WB_SET;
                            else                   byte_idx <= 2;
                        end
                        2'd2: begin
                            addr_lo  <= {byte_shreg[6:0], mosi_bit};
                            if (frame_end == 2'd2) state <= ST_WB_SET;
                            else                   byte_idx <= 3;
                        end
                        2'd3: begin
                            data_byte <= {byte_shreg[6:0], mosi_bit};
                            state     <= ST_WB_SET;  // WRITE is always 4 bytes
                        end
                    endcase
                end
            end

            if (sck_fall) begin
                o_spi_miso <= miso_shift[7];
                miso_shift <= {miso_shift[6:0], 1'b0};
            end
        end

        ST_WB_SET: begin
            case (cmd_byte)
                CMD_WRITE: begin
                    o_wb_adr <= {21'd0, full_addr};
                    o_wb_dat <= {24'd0, data_byte};
                    o_wb_sel <= 4'b0001;
                    o_wb_we  <= 1;
                    o_wb_stb <= 1;
                    state    <= ST_WB_WAIT;
                end
                CMD_READ: begin
                    o_wb_adr <= {21'd0, full_addr};
                    o_wb_dat <= 0;
                    o_wb_sel <= 4'b0001;
                    o_wb_we  <= 0;
                    o_wb_stb <= 1;
                    state    <= ST_WB_WAIT;
                end
                default: state <= ST_DONE;  // FETCH: nothing to do
            endcase
        end

        ST_WB_WAIT: begin
            o_wb_stb <= 1;
            o_wb_we  <= o_wb_we;
            if (i_wb_ack) begin
                o_wb_stb <= 0;
                o_wb_we  <= 0;
                if (cmd_byte == CMD_READ)
                    miso_reg <= i_wb_rdt[7:0];
                state <= ST_DONE;
            end
        end

        ST_DONE: begin
            if (!cs_act) state <= ST_IDLE;
            if (sck_fall) begin
                o_spi_miso <= miso_shift[7];
                miso_shift <= {miso_shift[6:0], 1'b0};
            end
        end

        default: state <= ST_IDLE;
        endcase
    end
end
endmodule
`default_nettype wire
