module gateway (
    input wire clk,          // Global System Clock
    input wire rst,          // System Reset
    
    // Wishbone Slave Interface (Connects to teammate's topmod)
    input  wire [31:0] wbs_dat_i, // 32-bit data from Flash FSM
    input  wire        wbs_stb_i, // Strobe: High when data is valid
    input  wire        wbs_we_i,  // Write Enable: High for writing
    output reg         wbs_ack_o, // Acknowledge: Tells FSM we got it
    
    // NoC Interface
    output reg [31:0] packet_out,
    output reg        ready       // Pulse high when packet is injected to NoC
);

    reg [9:0] local_sram [0:9]; 
    
    // Internal registers to track the handshake
    reg ready_next;

    // Wishbone Latch & NoC Injection Logic
    always @(posedge clk) begin
        if (rst) begin
            packet_out <= 32'h0;
            ready <= 0;
            wbs_ack_o <= 0;
            ready_next <= 0;
        end else begin
            // 1. Detect a Wishbone Write Transaction
            if (wbs_stb_i && wbs_we_i && !wbs_ack_o) begin
                packet_out <= wbs_dat_i;
                wbs_ack_o  <= 1; // Signal to teammate's FSM that data is received
                ready_next <= 1; // Trigger the NoC 'ready' pulse

                // COORDINATE FILTER (Core 0,0 logic)
                // OpCode 1 (Write) AND Target X=0 AND Target Y=0
                if (wbs_dat_i[31:28] == 4'h1 && 
                    wbs_dat_i[23:22] == 2'b00 && 
                    wbs_dat_i[21:20] == 2'b00) begin
                    local_sram[wbs_dat_i[19:16]] <= wbs_dat_i[9:0];
                end
            end else begin
                wbs_ack_o <= 0;
                ready_next <= 0;
            end
            
            // Generate the one-cycle 'ready' pulse for the NoC routers
            ready <= ready_next;
        end
    end

endmodule
