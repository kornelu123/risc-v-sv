module alu import isa::*; (
  input  bit [31:0]     op1,
  input  bit [31:0]     op2,
  input  operation_type op_type,
  output bit [31:0]     res
);
  always_comb begin
    case (op_type)
      ALU_ADD:  res = op1 + op2;
      ALU_SUB:  res = op1 - op2;
      ALU_SLL:  res = op1 << op2[4:0];
      ALU_SLT:  res = {31'd0, $signed(op1) < $signed(op2)};
      ALU_SLTU: res = {31'd0, op1 < op2};
      ALU_XOR:  res = op1 ^ op2;
      ALU_SRL:  res = op1 >> op2[4:0];
      ALU_SRA:  res = $signed(op1) >>> op2[4:0];
      ALU_OR:   res = op1 | op2;
      ALU_AND:  res = op1 & op2;
      default:  res = 32'd0;
    endcase
  end
endmodule
