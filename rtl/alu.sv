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

  // Signed quotient/remainder in their own signals: inside a ?: with unsigned
  // operands, SystemVerilog would evaluate the division as unsigned.
  bit signed [31:0]   quotient, remainder;

  // Division never traps; the spec defines these results instead.
  bit                 div_by_zero, div_overflow;

  assign op1_signed   = op_type == ALU_MULH || op_type == ALU_MULHSU;
  assign op2_signed   = op_type == ALU_MULH;
  assign product      = $signed({op1_signed & op1[31], op1}) *
                        $signed({op2_signed & op2[31], op2});

  assign quotient     = $signed(op1) / $signed(op2);
  assign remainder    = $signed(op1) % $signed(op2);
  assign div_by_zero  = op2 == 32'd0;
  assign div_overflow = op1 == 32'h80000000 && op2 == 32'hFFFFFFFF;

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
      ALU_DIV:    res = div_by_zero  ? 32'hFFFFFFFF :
                        div_overflow ? op1 : quotient;
      ALU_DIVU:   res = div_by_zero  ? 32'hFFFFFFFF : op1 / op2;
      ALU_REM:    res = div_by_zero  ? op1 :
                        div_overflow ? 32'd0 : remainder;
      ALU_REMU:   res = div_by_zero  ? op1 : op1 % op2;
      default:    res = 32'd0;
    endcase
  end
endmodule
