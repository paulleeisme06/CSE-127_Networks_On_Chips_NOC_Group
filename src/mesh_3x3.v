// `default_nettype none

// module mesh_3x3 (
//     input wire clk,
//     input wire rst,
//     input  wire [33:0] inject_00_nw,
//     output wire [33:0] monitor_22_se,
//     input  wire flash_miso,
//     output wire flash_cs_n,
//     output wire flash_clk,
//     output wire flash_mosi
// );
//     wire [7:0] boot_data;
//     wire [9:0] boot_addr;
//     wire       boot_wen, cpu_rst_n;
//     wire       boot_mode = !cpu_rst_n;

//     boot_controller boot_inst (
//         .clk(clk), .rst_n(!rst),
//         .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi), .flash_miso(flash_miso),
//         .sram_wdata(boot_data), .sram_waddr(boot_addr), .sram_wen(boot_wen), .cpu_reset_n(cpu_rst_n)
//     );

//     wire [33:0] grid_n [0:2][0:2], grid_s [0:2][0:2], grid_e [0:2][0:2], grid_w [0:2][0:2];
//     wire [33:0] grid_ne[0:2][0:2], grid_nw[0:2][0:2], grid_se[0:2][0:2], grid_sw[0:2][0:2];

//     genvar r, c;
//     generate
//         for (r = 0; r < 3; r = r + 1) begin : rows
//             for (c = 0; c < 3; c = c + 1) begin : cols
//                 wire [33:0] n_i  = (r > 0) ? grid_s[r-1][c] : 34'b0;
//                 wire [33:0] s_i  = (r < 2) ? grid_n[r+1][c] : 34'b0;
//                 wire [33:0] e_i  = (c < 2) ? grid_w[r][c+1] : 34'b0;
//                 wire [33:0] w_i  = (c > 0) ? grid_e[r][c-1] : 34'b0;
//                 wire [33:0] ne_i = (r > 0 && c < 2) ? grid_sw[r-1][c+1] : 34'b0;
//                 wire [33:0] se_i = (r < 2 && c < 2) ? grid_nw[r+1][c+1] : 34'b0;
//                 wire [33:0] sw_i = (r < 2 && c > 0) ? grid_ne[r+1][c-1] : 34'b0;
//                 wire [33:0] nw_i = (r == 0 && c == 0) ? inject_00_nw : 
//                                   (r > 0 && c > 0)   ? grid_se[r-1][c-1] : 34'b0;

//                 mesh_tile #(.TILE_ID({2'(r), 2'(c)})) tile_inst (
//                     .clk(clk), .rst(!cpu_rst_n), .boot_mode(boot_mode),
//                     .boot_addr(boot_addr), .boot_data(boot_data), .boot_wen(boot_wen),
//                     .north_in(n_i), .south_in(s_i), .east_in(e_i), .west_in(w_i),
//                     .north_out(grid_n[r][c]), .south_out(grid_s[r][c]), .east_out(grid_e[r][c]), .west_out(grid_w[r][c]),
//                     .ne_in(ne_i), .nw_in(nw_i), .se_in(se_i), .sw_in(sw_i),
//                     .ne_out(grid_ne[r][c]), .nw_out(grid_nw[r][c]), .se_out(grid_se[r][c]), .sw_out(grid_sw[r][c])
//                 );
//             end
//         end
//     endgenerate

//     assign monitor_22_se = grid_se[2][2];
// endmodule



`default_nettype none

// ============================================================================
// mesh_3x3 — 3×3 SERV tile array
//
// Changes from v1:
//   - boot_controller removed; boot bus now driven from top.v
//   - SPI flash pins removed
//   - rst driven directly from top.v (no internal cpu_rst_n logic)
//   - Flat readback ports added for host_spi_slave via rd_crossbar
// ============================================================================

module mesh_3x3 (
    input wire clk,
    input wire rst,

    // Boot SRAM write bus (muxed at top: boot_controller or host_spi_slave)
    input wire        boot_mode,
    input wire [9:0]  boot_addr,
    input wire [7:0]  boot_data,
    input wire        boot_wen,

    // Host inject (NW diagonal of tile 0,0)
    input  wire [33:0] inject_00_nw,

    // Monitor (SE diagonal of tile 2,2)
    output wire [33:0] monitor_22_se,

    // Flat readback ports (tile index = row*3 + col, 0-8)
    input  wire [9:0]  tile_rd_addr_0, tile_rd_addr_1, tile_rd_addr_2,
    input  wire [9:0]  tile_rd_addr_3, tile_rd_addr_4, tile_rd_addr_5,
    input  wire [9:0]  tile_rd_addr_6, tile_rd_addr_7, tile_rd_addr_8,

    input  wire        tile_rd_req_0,  tile_rd_req_1,  tile_rd_req_2,
    input  wire        tile_rd_req_3,  tile_rd_req_4,  tile_rd_req_5,
    input  wire        tile_rd_req_6,  tile_rd_req_7,  tile_rd_req_8,

    output wire [7:0]  tile_rd_data_0, tile_rd_data_1, tile_rd_data_2,
    output wire [7:0]  tile_rd_data_3, tile_rd_data_4, tile_rd_data_5,
    output wire [7:0]  tile_rd_data_6, tile_rd_data_7, tile_rd_data_8
);

    wire [33:0] grid_n [0:2][0:2], grid_s [0:2][0:2];
    wire [33:0] grid_e [0:2][0:2], grid_w [0:2][0:2];
    wire [33:0] grid_ne[0:2][0:2], grid_nw[0:2][0:2];
    wire [33:0] grid_se[0:2][0:2], grid_sw[0:2][0:2];

    // Pack flat ports into arrays for the generate loop
    wire [9:0] rd_addr_arr[0:8];
    wire       rd_req_arr [0:8];
    wire [7:0] rd_data_arr[0:8];

    assign rd_addr_arr[0]=tile_rd_addr_0; assign rd_addr_arr[1]=tile_rd_addr_1;
    assign rd_addr_arr[2]=tile_rd_addr_2; assign rd_addr_arr[3]=tile_rd_addr_3;
    assign rd_addr_arr[4]=tile_rd_addr_4; assign rd_addr_arr[5]=tile_rd_addr_5;
    assign rd_addr_arr[6]=tile_rd_addr_6; assign rd_addr_arr[7]=tile_rd_addr_7;
    assign rd_addr_arr[8]=tile_rd_addr_8;

    assign rd_req_arr[0]=tile_rd_req_0; assign rd_req_arr[1]=tile_rd_req_1;
    assign rd_req_arr[2]=tile_rd_req_2; assign rd_req_arr[3]=tile_rd_req_3;
    assign rd_req_arr[4]=tile_rd_req_4; assign rd_req_arr[5]=tile_rd_req_5;
    assign rd_req_arr[6]=tile_rd_req_6; assign rd_req_arr[7]=tile_rd_req_7;
    assign rd_req_arr[8]=tile_rd_req_8;

    assign tile_rd_data_0=rd_data_arr[0]; assign tile_rd_data_1=rd_data_arr[1];
    assign tile_rd_data_2=rd_data_arr[2]; assign tile_rd_data_3=rd_data_arr[3];
    assign tile_rd_data_4=rd_data_arr[4]; assign tile_rd_data_5=rd_data_arr[5];
    assign tile_rd_data_6=rd_data_arr[6]; assign tile_rd_data_7=rd_data_arr[7];
    assign tile_rd_data_8=rd_data_arr[8];

    genvar r, c;
    generate
        for (r = 0; r < 3; r = r + 1) begin : rows
            for (c = 0; c < 3; c = c + 1) begin : cols
                localparam integer IDX = r * 3 + c;

                wire [33:0] n_i  = (r>0)           ? grid_s [r-1][c]   : 34'b0;
                wire [33:0] s_i  = (r<2)           ? grid_n [r+1][c]   : 34'b0;
                wire [33:0] e_i  = (c<2)           ? grid_w [r][c+1]   : 34'b0;
                wire [33:0] w_i  = (c>0)           ? grid_e [r][c-1]   : 34'b0;
                wire [33:0] ne_i = (r>0 && c<2)    ? grid_sw[r-1][c+1] : 34'b0;
                wire [33:0] se_i = (r<2 && c<2)    ? grid_nw[r+1][c+1] : 34'b0;
                wire [33:0] sw_i = (r<2 && c>0)    ? grid_ne[r+1][c-1] : 34'b0;
                wire [33:0] nw_i = (r==0 && c==0)  ? inject_00_nw :
                                   (r>0  && c>0)   ? grid_se[r-1][c-1] : 34'b0;

                mesh_tile #(.TILE_ID({2'(r),2'(c)})) tile_inst (
                    .clk      (clk),       .rst      (rst),
                    .boot_mode(boot_mode), .boot_addr(boot_addr),
                    .boot_data(boot_data), .boot_wen (boot_wen),
                    .north_in (n_i),       .south_in (s_i),
                    .east_in  (e_i),       .west_in  (w_i),
                    .north_out(grid_n[r][c]), .south_out(grid_s[r][c]),
                    .east_out (grid_e[r][c]), .west_out (grid_w[r][c]),
                    .ne_in    (ne_i),      .nw_in    (nw_i),
                    .se_in    (se_i),      .sw_in    (sw_i),
                    .ne_out   (grid_ne[r][c]), .nw_out(grid_nw[r][c]),
                    .se_out   (grid_se[r][c]), .sw_out(grid_sw[r][c]),
                    .rd_addr  (rd_addr_arr[IDX]),
                    .rd_req   (rd_req_arr[IDX]),
                    .rd_data  (rd_data_arr[IDX])
                );
            end
        end
    endgenerate

    assign monitor_22_se = grid_se[2][2];

endmodule
