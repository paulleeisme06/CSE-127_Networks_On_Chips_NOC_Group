// SPDX-FileCopyrightText: © 2026 Paul Lee
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
    
    input  wire clk,
    input  wire rst_n,
    
    input  wire [NUM_INPUT_PADS-1:0] input_in,
    output wire [NUM_INPUT_PADS-1:0] input_pu,
    output wire [NUM_INPUT_PADS-1:0] input_pd,

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,

    inout  wire [NUM_ANALOG_PADS-1:0] analog
);

    assign input_pu = '0;
    assign input_pd = '0;
    assign bidir_cs = '0;
    assign bidir_sl = '0;
    assign bidir_pu = '0;
    assign bidir_pd = '0;

    wire flash_cs_n, flash_clk, flash_mosi;
    wire flash_miso = input_in[0];

    assign bidir_oe  = {{(NUM_BIDIR_PADS-3){1'b0}}, 3'b111};
    assign bidir_ie  = ~bidir_oe;
    assign bidir_out = {{(NUM_BIDIR_PADS-3){1'b0}}, flash_mosi, flash_clk, flash_cs_n};

    logic _unused;
    assign _unused = &{bidir_in, analog};

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

endmodule

`default_nettype wire