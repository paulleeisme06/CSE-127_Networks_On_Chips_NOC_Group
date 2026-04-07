`default_nettype none

// ============================================================================
// rd_crossbar — routes host_spi_slave readback requests to the right tile
// ============================================================================
//
// rd_tile  = {tile_row[1:0], tile_col[1:0]}  maps to tile index 0–8:
//   tile(0,0)=0  tile(0,1)=1  tile(0,2)=2
//   tile(1,0)=4  tile(1,1)=5  tile(1,2)=6
//   tile(2,0)=8  tile(2,1)=9  tile(2,2)=10
//
// We map these to flat indices 0–8 for the port arrays.
// ============================================================================

module rd_crossbar (
    input  wire        clk,

    // From host_spi_slave
    input  wire [3:0]  rd_tile,
    input  wire [9:0]  rd_addr,
    input  wire        rd_req,
    output reg  [7:0]  rd_data,

    // To/from mesh_3x3 tile readback ports (flat, 9 tiles)
    output reg  [9:0]  tile_rd_addr_0, tile_rd_addr_1, tile_rd_addr_2,
    output reg  [9:0]  tile_rd_addr_3, tile_rd_addr_4, tile_rd_addr_5,
    output reg  [9:0]  tile_rd_addr_6, tile_rd_addr_7, tile_rd_addr_8,

    output reg         tile_rd_req_0,  tile_rd_req_1,  tile_rd_req_2,
    output reg         tile_rd_req_3,  tile_rd_req_4,  tile_rd_req_5,
    output reg         tile_rd_req_6,  tile_rd_req_7,  tile_rd_req_8,

    input  wire [7:0]  tile_rd_data_0, tile_rd_data_1, tile_rd_data_2,
    input  wire [7:0]  tile_rd_data_3, tile_rd_data_4, tile_rd_data_5,
    input  wire [7:0]  tile_rd_data_6, tile_rd_data_7, tile_rd_data_8
);

    // Convert {row[1:0],col[1:0]} tile_id to flat 0-8 index
    // tile_id encoding: row*4 + col  (matches TILE_ID parameter in mesh_tile)
    // Valid tile_ids: 0,1,2,4,5,6,8,9,10 → flat 0-8
    function [3:0] tile_flat;
        input [3:0] tid;
        case (tid)
            4'h0: tile_flat = 4'd0;   // (0,0)
            4'h1: tile_flat = 4'd1;   // (0,1)
            4'h2: tile_flat = 4'd2;   // (0,2)
            4'h4: tile_flat = 4'd3;   // (1,0)
            4'h5: tile_flat = 4'd4;   // (1,1)
            4'h6: tile_flat = 4'd5;   // (1,2)
            4'h8: tile_flat = 4'd6;   // (2,0)
            4'h9: tile_flat = 4'd7;   // (2,1)
            4'hA: tile_flat = 4'd8;   // (2,2)
            default: tile_flat = 4'd0;
        endcase
    endfunction

    wire [3:0] sel = tile_flat(rd_tile);

    // Fan address to all tiles, req only to the selected one
    always @(posedge clk) begin
        // Default all reqs off
        tile_rd_req_0 <= 1'b0; tile_rd_req_1 <= 1'b0; tile_rd_req_2 <= 1'b0;
        tile_rd_req_3 <= 1'b0; tile_rd_req_4 <= 1'b0; tile_rd_req_5 <= 1'b0;
        tile_rd_req_6 <= 1'b0; tile_rd_req_7 <= 1'b0; tile_rd_req_8 <= 1'b0;

        // Broadcast address to all (only selected will be enabled)
        tile_rd_addr_0 <= rd_addr; tile_rd_addr_1 <= rd_addr;
        tile_rd_addr_2 <= rd_addr; tile_rd_addr_3 <= rd_addr;
        tile_rd_addr_4 <= rd_addr; tile_rd_addr_5 <= rd_addr;
        tile_rd_addr_6 <= rd_addr; tile_rd_addr_7 <= rd_addr;
        tile_rd_addr_8 <= rd_addr;

        if (rd_req) begin
            case (sel)
                4'd0: tile_rd_req_0 <= 1'b1;
                4'd1: tile_rd_req_1 <= 1'b1;
                4'd2: tile_rd_req_2 <= 1'b1;
                4'd3: tile_rd_req_3 <= 1'b1;
                4'd4: tile_rd_req_4 <= 1'b1;
                4'd5: tile_rd_req_5 <= 1'b1;
                4'd6: tile_rd_req_6 <= 1'b1;
                4'd7: tile_rd_req_7 <= 1'b1;
                4'd8: tile_rd_req_8 <= 1'b1;
                default: ;
            endcase
        end

        // Mux rd_data back from selected tile
        case (sel)
            4'd0: rd_data <= tile_rd_data_0;
            4'd1: rd_data <= tile_rd_data_1;
            4'd2: rd_data <= tile_rd_data_2;
            4'd3: rd_data <= tile_rd_data_3;
            4'd4: rd_data <= tile_rd_data_4;
            4'd5: rd_data <= tile_rd_data_5;
            4'd6: rd_data <= tile_rd_data_6;
            4'd7: rd_data <= tile_rd_data_7;
            4'd8: rd_data <= tile_rd_data_8;
            default: rd_data <= 8'h00;
        endcase
    end

endmodule