module housekeeping_fsm (
    input  wire clk,
    input  wire reset,
    input  wire bypass_en,
    
    // Shift Register 
    input  wire word_ready,
    input  wire [31:0] shifted_word,
    output reg  fetch_en,
    output wire fetch_o,
    
    // SPI Flash
    output reg  flash_csb,
    
    // Wishbone Master
    output reg [31:0] wbs_adr,
    output reg [31:0] wbs_dat,
    output reg        wbs_cyc,
    output reg        wbs_stb,
    output reg        wbs_we,
    input  wire       wbs_ack,
    
    // System Status
    output reg        done_loading //0 is when Housekepeing its shifting its data in. 1 is when the data can go to the SRAM.
);
    reg [31:0] word_latched;
    localparam IDLE      = 3'd0;
    localparam FETCH     = 3'd1;
    localparam WB_WRITE  = 3'd2;
    localparam NEXT_NODE = 3'd3;
    localparam DONE      = 3'd4;
    localparam SR_RESET  = 3'd5;
    assign fetch_o = (state == FETCH);
    reg [2:0] state;
    reg [3:0] row_counter;    // 0-9
    reg [3:0] soclet_counter; // 0-8

    always @(posedge clk) begin
        if (reset || bypass_en) begin
            state <= IDLE;
            row_counter <= 0;
            soclet_counter <= 0;
            wbs_cyc <= 0;
            wbs_stb <= 0;
            flash_csb <= 1;
            fetch_en <= 0;
            done_loading <= 0;
        end else begin
            case (state)
                IDLE: begin
                    flash_csb <= 0;
                    wbs_adr <= 32'h1000;
                    state <= FETCH;
                end

               FETCH: begin
                fetch_en <= 1;
                if (word_ready) begin
                    word_latched <= shifted_word;
                    wbs_dat  <= shifted_word;  // Latch the data NOW, this cycle
                    wbs_cyc  <= 1;
                    wbs_stb  <= 1;
                    wbs_we   <= 1;
                    fetch_en <= 0;
                    state    <= WB_WRITE;
                end
            end

                WB_WRITE: begin
                    wbs_dat <= word_latched; 
                    if (wbs_ack) begin
                        wbs_cyc <= 0;
                        wbs_stb <= 0;
                        wbs_we <=0;
                        state   <= NEXT_NODE;
                    end
                end

                NEXT_NODE: begin
                    if (row_counter < 9) begin
                        row_counter <= row_counter + 1;
                         // Matches Python Test: 0x1000 + (S*64) + (R*4)
                        wbs_adr <= 32'h1000 + (soclet_counter << 6) + ((row_counter+1) << 2);
                        state <= FETCH;
                    end else if (soclet_counter < 8) begin
                        row_counter <= 0;
                        soclet_counter <= soclet_counter + 1;
                        wbs_adr <= 32'h1000 + (soclet_counter << 6);
                        state <= SR_RESET;
                    end else begin
                        state <= DONE;
                    end
                end
                
                SR_RESET: begin
                // extra cycle so fetch can catch that the word is done signal, and it can restart
                wbs_adr <= 32'h1000 + (soclet_counter << 6);
                state <= FETCH;
                end

                DONE: begin
                    flash_csb <= 1;
                    done_loading <= 1;
                end
            endcase
        end
    end
endmodule

