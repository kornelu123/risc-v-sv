module alu import isa::*; (
  input  bit [31:0]     op1,
  input  bit [31:0]     op2,
  input  operation_type op_type,
  output bit [31:0]     res
);
  // One 33x33-bit signed multiplier serves all four multiplies: each operand
  // gets a 33rd bit that is its sign bit if the instruction treats it as
  // signed, or 0 if unsigned. Only product[63:0] is meaningful.
  bit                 op1_signed, op2_signed;
  /* verilator lint_off UNUSEDSIGNAL */
  bit signed [65:0]   product;
  /* verilator lint_on UNUSEDSIGNAL */

  // DIV/DIVU/REM/REMU are done by the multi-cycle divider (divider.sv).
  assign op1_signed   = op_type == ALU_MULH || op_type == ALU_MULHSU;
  assign op2_signed   = op_type == ALU_MULH;
  assign product      = $signed({op1_signed & op1[31], op1}) *
                        $signed({op2_signed & op2[31], op2});

  always_comb begin
    case (op_type)
      ALU_ADD:    res = op1 + op2;
      ALU_SUB:    res = op1 - op2;
      ALU_SLL:    res = op1 << op2[4:0];
      ALU_SLT:    res = {31'd0, $signed(op1) < $signed(op2)};
      ALU_SLTU:   res = {31'd0, op1 < op2};
      ALU_XOR:    res = op1 ^ op2;
      ALU_SRL:    res = op1 >> op2[4:0];
      ALU_SRA:    res = $signed(op1) >>> op2[4:0];
      ALU_OR:     res = op1 | op2;
      ALU_AND:    res = op1 & op2;
      ALU_MUL:    res = product[31:0];
      ALU_MULH,
      ALU_MULHSU,
      ALU_MULHU:  res = product[63:32];
      default:    res = 32'd0;
    endcase
  end
endmodule
