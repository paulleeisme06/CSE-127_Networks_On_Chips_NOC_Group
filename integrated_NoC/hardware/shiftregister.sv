module shiftregister (
    input wire clk,
    input wire reset,
    input wire serial_in,
    input wire shift_en,
    input wire fetch_o,
    output reg [31:0] shifted_word,
    output reg done_word
);

    reg [5:0] bit_cnt;
    reg       fetch_o_prev;  // detect rising edge of fetch_o


    always @(posedge clk) begin
        if (reset) begin
            bit_cnt      <= 6'd0;
            shifted_word <= 32'd0;
            done_word    <= 1'b0;
            fetch_o_prev <= 1'b0;
        end else begin
            fetch_o_prev <= fetch_o;
       // Reset counter on RISING edge of fetch_o so "old word" doesnt get lot before its in a flip flop
            if (fetch_o && !fetch_o_prev) begin
                bit_cnt      <= 6'd0;
                done_word    <= 1'b0;
                shifted_word <= 32'd0;
            end else if (fetch_o && shift_en && !done_word) begin
                shifted_word <= {shifted_word[30:0], serial_in};
                if (bit_cnt == 6'd31) begin
                    done_word <= 1'b1;
                    // do NOT increment — stay at 31 so done_word holds
                end else begin
                    bit_cnt <= bit_cnt + 6'd1;
                end
            end
        end
    end
endmodule

