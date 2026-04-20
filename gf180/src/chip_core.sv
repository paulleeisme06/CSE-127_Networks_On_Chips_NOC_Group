// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif
    
    input  wire clk,       // clock
    input  wire rst_n,     // reset (active low)
    
    input  wire [NUM_INPUT_PADS-1:0] input_in,   // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,   // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,   // Pull-down

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,   // Pull-down

    inout  wire [NUM_ANALOG_PADS-1:0] analog  // Analog
);

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html
    
    // Disable unused input pad controls
    assign input_pu = '0;
    assign input_pd = '0;

    // Flash SPI signals mapped to pads
    wire flash_miso = input_in[0];

    wire flash_cs_n, flash_clk, flash_mosi;

    // Set bidir pad directions
    assign bidir_oe = '0;
    assign bidir_oe[0] = 1'b1;  // flash_cs_n output
    assign bidir_oe[1] = 1'b1;  // flash_clk output
    assign bidir_oe[2] = 1'b1;  // flash_mosi output

    assign bidir_cs = '0;
    assign bidir_sl = '0;
    assign bidir_ie = ~bidir_oe;
    assign bidir_pu = '0;
    assign bidir_pd = '0;

    assign bidir_out = '0;
    assign bidir_out[0] = flash_cs_n;
    assign bidir_out[1] = flash_clk;
    assign bidir_out[2] = flash_mosi;

    // Unused bidir inputs
    logic _unused;
    assign _unused = &bidir_in;

    mesh_3x3 mesh_inst (
        .clk          (clk),
        .rst          (~rst_n),
        .inject_00_nw (34'b0),
        .monitor_22_se(),
        .flash_miso   (flash_miso),
        .flash_cs_n   (flash_cs_n),
        .flash_clk    (flash_clk),
        .flash_mosi   (flash_mosi)
    );

    logic [7:0] sram_0_out;

    gf180mcu_fd_ip_sram__sram512x8m8wm1 sram_0 (
        `ifdef USE_POWER_PINS
        .VDD  (VDD),
        .VSS  (VSS),
        `endif

        .CLK  (clk),
        .CEN  (1'b1),
        .GWEN (1'b0),
        .WEN  (8'b0),
        .A    ('0),
        .D    ('0),
        .Q    (sram_0_out)
    );

    logic [7:0] sram_1_out;

    gf180mcu_fd_ip_sram__sram512x8m8wm1 sram_1 (
        `ifdef USE_POWER_PINS
        .VDD  (VDD),
        .VSS  (VSS),
        `endif

        .CLK  (clk),
        .CEN  (1'b1),
        .GWEN (1'b0),
        .WEN  (8'b0),
        .A    ('0),
        .D    ('0),
        .Q    (sram_1_out)
    );

    assign bidir_out = count ^ {24'd0, sram_0_out, sram_1_out};

endmodule

`default_nettype wire
