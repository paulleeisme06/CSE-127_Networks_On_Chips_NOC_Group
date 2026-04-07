module shiftregister (
    input wire clk,
    input wire reset,
    input wire serial_in,   
    input wire shift_en,    //high in fetch bit state
    input wire fetch_o,
    output reg [31:0] shifted_word,
    output reg done_word    // Goes high sfter we get 32 bits, trigger signal 
);

   reg [5:0] bit_cnt; // extra bits incase

    always @(posedge clk) begin
    if (reset) begin
        bit_cnt      <= 6'd0;
        shifted_word <= 32'd0;
        done_word    <= 1'b0;
    end 
    else if (!fetch_o) begin
        // fetch means we are in state FETCH
        bit_cnt   <= 6'd0;
        done_word <= 1'b0;
    end 
    else begin
        if (shift_en && !done_word) begin
            shifted_word <= {shifted_word[30:0], serial_in};
            if (bit_cnt == 6'd31) begin
                done_word <= 1'b1;  // stays high till transitions out of fetch state
            end else begin
                bit_cnt <= bit_cnt + 6'd1;
            end
        end
    end
end
endmodule

