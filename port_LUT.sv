module port_LUT(
    input logic clk,
    input logic [3:0] port,
    output logic [15:0] port_addr
);

always_comb begin
    case (port)
        4'd0:  port_addr = 16'h1000;
        4'd1:  port_addr = 16'h1004;
        4'd2:  port_addr = 16'h1008;
        4'd3:  port_addr = 16'h100C;
        4'd4:  port_addr = 16'h1010;
        4'd5:  port_addr = 16'h1014;
        4'd6:  port_addr = 16'h1018;
        4'd7:  port_addr = 16'h101C;
        4'd8:  port_addr = 16'h1020;
        4'd9:  port_addr = 16'h1024;
        4'd10: port_addr = 16'h1028;
        4'd11: port_addr = 16'h102C;
        4'd12: port_addr = 16'h1030;
        4'd13: port_addr = 16'h1034;
        4'd14: port_addr = 16'h1038;
        4'd15: port_addr = 16'h103C;
        
        default: port_addr = 16'h1FFC;
    endcase

end

`ifndef BSG_HIDE_FROM_SYNTHESIS
    always_ff @(posedge clk) begin
        $display("port address: %x", port_addr);
    end
`endif
endmodule