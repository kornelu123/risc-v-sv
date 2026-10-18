typedef enum logic [3:0] {
  ADD, SUB
} operation_type;

module alu(input  bit [31:0]     op1,
           input  bit [31:0]     op2,
           input  operation_type op_type,
           output bit [31:0]     res);

  always_comb begin
    case (op_type)
      ADD:     res = op1 + op2;
      SUB:     res = op1 - op2;
      default: res = 32'd0;
    endcase
  end
endmodule
