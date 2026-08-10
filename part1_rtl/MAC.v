module MAC
#(
    parameter DATA_BW = 8
)(
    input CLK, 
    input RSTN, 
    input EN,
    input signed [DATA_BW-1:0] IFMAP_DATA_IN,
    input signed [DATA_BW-1:0] FILTER_DATA_IN,
    output signed [2*DATA_BW-1:0] MUL_DATA_OUT
);

reg signed [2*DATA_BW-1:0] mult_result_reg;
reg signed [DATA_BW-1:0] ifmap_data_in_buf;
reg signed [DATA_BW-1:0] filter_data_in_buf;

assign MUL_DATA_OUT = mult_result_reg;

always @(posedge CLK or negedge RSTN) begin
    if(!RSTN) begin
        ifmap_data_in_buf <= 0;
        filter_data_in_buf <= 0;
        mult_result_reg <= 0;
    end
    else if(EN) begin
        ifmap_data_in_buf <= IFMAP_DATA_IN;
        filter_data_in_buf <= FILTER_DATA_IN;
        mult_result_reg <= ifmap_data_in_buf * filter_data_in_buf + mult_result_reg;
    end
end

endmodule

