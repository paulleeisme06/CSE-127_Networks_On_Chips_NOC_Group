module flash_clk (
    input clk,
    input reset,
    input enable,
    output reg flash_clk
);
    reg [7:0] clk_cnt;

    localparam CLK_PERIOD    = 8'd10;
    localparam DUTY_THRESHOLD = 8'd5;

    always @(posedge clk) begin
        if (reset) begin
            clk_cnt   <= 0;
            flash_clk <= 0;
        end else if (enable) begin
            if (clk_cnt < CLK_PERIOD - 1) begin
                clk_cnt <= clk_cnt + 1;
            end else begin
                clk_cnt <= 0;
            end
            flash_clk <= (clk_cnt < DUTY_THRESHOLD);
        end
    end
endmodule
