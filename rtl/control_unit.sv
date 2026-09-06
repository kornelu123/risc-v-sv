module cu(input logic iclk);
  bit [31:0] fetched_instr;

  bit [31:0] instr_op1, instr_op2;
  bit [31:0] instr_result;

  regs::reg_t result_reg;
  operation_type instr_operation_type;

  decoder d(fetched_instr, iclk, instr_operation_type,
            instr_op1, instr_op2, result_reg);
  alu a(instr_op1, instr_op2, instr_operation_type,
        iclk, instr_result);

  initial begin
    regs::pc = 0;
    fetched_instr = mem::mem(regs::pc);
  end

  always @(posedge iclk) begin
    fetched_instr = mem::mem(regs::pc);
  end

  always @(posedge iclk) begin
    regs::pc += 4;
  end
endmodule
