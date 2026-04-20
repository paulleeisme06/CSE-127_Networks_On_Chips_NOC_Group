// // SPDX-FileCopyrightText: © 2025 XXX Authors
// // SPDX-License-Identifier: Apache-2.0

// `default_nettype none

// module chip_core #(
//     parameter NUM_INPUT_PADS,
//     parameter NUM_BIDIR_PADS,
//     parameter NUM_ANALOG_PADS
//     )(
//     `ifdef USE_POWER_PINS
//     inout  wire VDD,
//     inout  wire VSS,
//     `endif
    
//     input  wire clk,       // clock
//     input  wire rst_n,     // reset (active low)
    
//     input  wire [NUM_INPUT_PADS-1:0] input_in,   // Input value
//     output wire [NUM_INPUT_PADS-1:0] input_pu,   // Pull-up
//     output wire [NUM_INPUT_PADS-1:0] input_pd,   // Pull-down

//     input  wire [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
//     output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
//     output wire [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
//     output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
//     output wire [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
//     output wire [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
//     output wire [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
//     output wire [NUM_BIDIR_PADS-1:0] bidir_pd,   // Pull-down

//     inout  wire [NUM_ANALOG_PADS-1:0] analog  // Analog
// );

//     // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html
    
//     // Disable pull-up and pull-down for input
//     assign input_pu = '0;
//     assign input_pd = '0;

//     // Set the bidir as output
//     assign bidir_oe = '1;
//     assign bidir_cs = '0;
//     assign bidir_sl = '0;
//     assign bidir_ie = ~bidir_oe;
//     assign bidir_pu = '0;
//     assign bidir_pd = '0;
    
//     logic _unused;
//     assign _unused = &bidir_in;

//     logic [NUM_BIDIR_PADS-1:0] count;

//     always_ff @(posedge clk) begin
//         if (!rst_n) begin
//             count <= '0;
//         end else begin
//             if (&input_in) begin
//                 count <= count + 1;
//             end
//         end
//     end

//     logic [7:0] sram_0_out;

//     gf180mcu_fd_ip_sram__sram512x8m8wm1 sram_0 (
//         `ifdef USE_POWER_PINS
//         .VDD  (VDD),
//         .VSS  (VSS),
//         `endif

//         .CLK  (clk),
//         .CEN  (1'b1),
//         .GWEN (1'b0),
//         .WEN  (8'b0),
//         .A    ('0),
//         .D    ('0),
//         .Q    (sram_0_out)
//     );

//     logic [7:0] sram_1_out;

//     gf180mcu_fd_ip_sram__sram512x8m8wm1 sram_1 (
//         `ifdef USE_POWER_PINS
//         .VDD  (VDD),
//         .VSS  (VSS),
//         `endif

//         .CLK  (clk),
//         .CEN  (1'b1),
//         .GWEN (1'b0),
//         .WEN  (8'b0),
//         .A    ('0),
//         .D    ('0),
//         .Q    (sram_1_out)
//     );

//     assign bidir_out = count ^ {24'd0, sram_0_out, sram_1_out};

// endmodule

// `default_nettype wire




// =============================================================================
// chip_core.sv
// NOC System — chip_core for gf180mcu wafer.space tapeout template
//
// Port interface matches chip_top.sv EXACTLY — do not rename ports here.
//
// Pad mapping (input_PAD vector):
//   input_in[0] = flash_miso
//   input_in[1] = bypass_en
//   input_in[2] = host_mosi
//   input_in[3] = spare
//   input_in[4] = spare
//
// Bidir pads used as outputs (OE tied high) for:
//   bidir[0]  = flash_mosi
//   bidir[1]  = flash_clk
//   bidir[2]  = flash_csb
//   bidir[3]  = host_miso  (tied low for now)
//   bidir[4]  = system_ready
//   bidir[5]  = noc_debug[3]  (noc_monitor_se[33] — valid bit)
//   bidir[6]  = noc_debug[2]  (noc_monitor_se[32])
//   bidir[7]  = noc_debug[1]  (noc_monitor_se[31])
//   bidir[8]  = noc_debug[0]  (noc_monitor_se[30])
//
// Why bidir pads for outputs?
//   The template's dedicated pad cells are input-only (gf180mcu_fd_io__in_c).
//   Outputs and bidirectionals use gf180mcu_fd_io__bi_24t. Setting OE=1 and
//   IE=0 makes a bidir pad behave as a pure output.
// =============================================================================

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS  = 5,
    parameter NUM_BIDIR_PADS  = 9,
    parameter NUM_ANALOG_PADS = 0
)(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    input  wire                        clk,
    input  wire                        rst_n,      // active-LOW reset from pad

    // Input pads
    input  wire [NUM_INPUT_PADS-1:0]   input_in,
    output wire [NUM_INPUT_PADS-1:0]   input_pu,   // pull-up  controls (to pad)
    output wire [NUM_INPUT_PADS-1:0]   input_pd,   // pull-down controls (to pad)

    // Bidirectional pads (driven as outputs here)
    input  wire [NUM_BIDIR_PADS-1:0]   bidir_in,
    output wire [NUM_BIDIR_PADS-1:0]   bidir_out,
    output wire [NUM_BIDIR_PADS-1:0]   bidir_oe,   // output enable: 1 = drive
    output wire [NUM_BIDIR_PADS-1:0]   bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0]   bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0]   bidir_ie,   // input enable:  0 = off
    output wire [NUM_BIDIR_PADS-1:0]   bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0]   bidir_pd,

    // Analog pads (unused)
    inout  wire [NUM_ANALOG_PADS-1:0]  analog
);

    // -------------------------------------------------------------------------
    // Convert active-low reset → active-high for internal logic
    // -------------------------------------------------------------------------
    wire rst = ~rst_n;

    // -------------------------------------------------------------------------
    // Unpack input pads
    // -------------------------------------------------------------------------
    wire flash_miso = input_in[0];
    wire bypass_en  = input_in[1];   // unused in basic tapeout config
    wire host_mosi  = input_in[2];   // unused in basic tapeout config
    // input_in[3:4] spare

    // No pull-ups or pull-downs on any input
    assign input_pu = {NUM_INPUT_PADS{1'b0}};
    assign input_pd = {NUM_INPUT_PADS{1'b0}};

    // -------------------------------------------------------------------------
    // Internal wires
    // -------------------------------------------------------------------------
    wire [33:0] noc_monitor_se;
    wire        flash_cs_n_int;
    wire        flash_clk_int;
    wire        flash_mosi_int;

    // system_ready: asserts once boot_controller finishes loading flash → SRAM
    reg system_ready_r;
    always @(posedge clk or posedge rst) begin
        if (rst)
            system_ready_r <= 1'b0;
        else if (!flash_cs_n_int)   // CS_N low = boot still in progress
            system_ready_r <= 1'b0;
        else
            system_ready_r <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // 3×3 SERV NoC Mesh
    // -------------------------------------------------------------------------
    // inject_00_nw tied to 0: no external packet injection in tapeout mode.
    // The boot_controller inside mesh_3x3 owns the flash SPI interface.
    // -------------------------------------------------------------------------
    mesh_3x3 noc_mesh (
        .clk           (clk),
        .rst           (rst),
        .inject_00_nw  (34'b0),
        .monitor_22_se (noc_monitor_se),
        .flash_miso    (flash_miso),
        .flash_cs_n    (flash_cs_n_int),
        .flash_clk     (flash_clk_int),
        .flash_mosi    (flash_mosi_int)
    );

    // -------------------------------------------------------------------------
    // Pack bidir outputs
    // Index [0] = LSB of bidir_PAD vector in chip_top
    // -------------------------------------------------------------------------
    assign bidir_out = {
        noc_monitor_se[30],   // bidir[8] — noc_debug bit 0
        noc_monitor_se[31],   // bidir[7] — noc_debug bit 1
        noc_monitor_se[32],   // bidir[6] — noc_debug bit 2
        noc_monitor_se[33],   // bidir[5] — noc_debug bit 3 (valid)
        system_ready_r,       // bidir[4] — system_ready
        1'b0,                 // bidir[3] — host_miso (tied off)
        flash_cs_n_int,       // bidir[2] — flash_csb
        flash_clk_int,        // bidir[1] — flash_clk
        flash_mosi_int        // bidir[0] — flash_mosi
    };

    // All bidir pads driven as outputs: OE=1, IE=0
    assign bidir_oe  = {NUM_BIDIR_PADS{1'b1}};
    assign bidir_ie  = {NUM_BIDIR_PADS{1'b0}};

    // Unused bidir pad controls
    assign bidir_cs  = {NUM_BIDIR_PADS{1'b0}};
    assign bidir_sl  = {NUM_BIDIR_PADS{1'b0}};
    assign bidir_pu  = {NUM_BIDIR_PADS{1'b0}};
    assign bidir_pd  = {NUM_BIDIR_PADS{1'b0}};

endmodule

`default_nettype wire
