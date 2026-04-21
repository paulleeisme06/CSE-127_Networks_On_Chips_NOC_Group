module boot_controller (
    input  wire clk,
    input  wire rst_n,
    output reg  flash_cs_n,
    output reg  flash_clk,
    output reg  flash_mosi,
    input  wire flash_miso,
    output reg  [7:0] sram_wdata,
    output reg  [10:0] sram_waddr,
    output reg        sram_wen,
    output reg        cpu_reset_n
);

    localparam IDLE=0, CMD=1, ADDR=2, READ=3, WRITE=4, DONE=5;
    reg [2:0] state;
    reg [7:0] bit_counter, shift_reg;
    reg [1:0] spi_phase; // Changed to 2-bit for 4-phase timing

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cpu_reset_n <= 0;
            sram_wen <= 1;
            sram_waddr <= 0;
            flash_cs_n <= 1;
            flash_clk <= 0;
            spi_phase <= 0;
        end else begin
            case (state)
                IDLE: begin
                    flash_cs_n <= 0;
                    bit_counter <= 0;
                    shift_reg <= 8'h03; // Read Command
                    state <= CMD;
                end
                
                CMD: begin
                    if (spi_phase == 0) begin
                        flash_clk <= 0;
                        flash_mosi <= shift_reg[7];
                        spi_phase <= 1;
                    end else if (spi_phase == 1) begin
                        flash_clk <= 1;
                        spi_phase <= 2;
                    end else begin
                        flash_clk <= 0;
                        shift_reg <= {shift_reg[6:0], 1'b0};
                        spi_phase <= 0;
                        if (bit_counter == 7) begin
                            state <= ADDR;
                            bit_counter <= 0;
                        end else bit_counter <= bit_counter + 1;
                    end
                end

                ADDR: begin
                    if (spi_phase == 0) begin
                        flash_clk <= 0;
                        flash_mosi <= 0;
                        spi_phase <= 1;
                    end else if (spi_phase == 1) begin
                        flash_clk <= 1;
                        spi_phase <= 2;
                    end else begin
                        flash_clk <= 0;
                        spi_phase <= 0;
                        if (bit_counter == 23) begin
                            state <= READ;
                            bit_counter <= 0;
                        end else bit_counter <= bit_counter + 1;
                    end
                end

                READ: begin
                    case (spi_phase)
                        2'b00: begin 
                            flash_clk <= 1;
                            spi_phase <= 2'b01;
                        end
                        2'b01: begin 
                            // Capture the bit from MISO
                            shift_reg <= {shift_reg[6:0], flash_miso};
                            spi_phase <= 2'b10;
                        end
                        2'b10: begin 
                            flash_clk <= 0;
                            spi_phase <= 2'b11;
                        end
                        2'b11: begin 
                            spi_phase <= 2'b00;
                            if (bit_counter == 7) begin
                                // The shift_reg now contains all 8 bits correctly
                                sram_wdata <= shift_reg; 
                                state <= WRITE;
                                bit_counter <= 0;
                            end else begin
                                bit_counter <= bit_counter + 1;
                            end
                        end
                    endcase
                end

                WRITE: begin
                    if (spi_phase == 0) begin
                        sram_wen <= 0; // Active low pulse start
                        spi_phase <= 1;
                    end else begin
                        sram_wen <= 1; // Pulse end
                        spi_phase <= 0;
                        if (sram_waddr == 11'h7FF) state <= DONE;
                        else begin
                            sram_waddr <= sram_waddr + 1;
                            state <= READ;
                        end
                    end
                end

                DONE: begin
                    flash_cs_n <= 1;
                    cpu_reset_n <= 1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule