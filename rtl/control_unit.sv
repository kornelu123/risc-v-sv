// 2-stage pipeline on one clock edge:
//   stage 1: fetch + decode (+ register read with forwarding, jumps resolved)
//   stage 2: execute + writeback
module cu(input logic iclk,
          input logic rst_n);
  bit [31:0] instr;

  regs::reg_t rs1, rs2;
  bit [31:0]  rs1_val, rs2_val;

  operation_type decoded_instr_operation_type;
  bit [31:0]     decoded_instr_op1, decoded_instr_op2;
  regs::reg_t    decoded_result_reg;
  bit            decoded_we;
  bit            jump, illegal;
  bit [31:0]     jump_target;

  bit            toexecute_valid;
  operation_type toexecute_instr_operation_type;
  bit [31:0]     toexecute_instr_op1, toexecute_instr_op2;
  regs::reg_t    toexecute_result_reg;
  bit            toexecute_we;
  bit [31:0]     toexecute_pc, toexecute_instr;
  bit [31:0]     executed_instr_result;

  assign instr = mem::mem(regs::pc);

  // Forwarding: the instruction in execute is written only at the end of
  // this cycle, so a dependent instruction in decode takes its result directly.
  always_comb begin
    rs1_val = (rs1 == regs::ZERO) ? 32'd0 : regs::reg_page[rs1];
    rs2_val = (rs2 == regs::ZERO) ? 32'd0 : regs::reg_page[rs2];
    if (toexecute_we && toexecute_result_reg == rs1) rs1_val = executed_instr_result;
    if (toexecute_we && toexecute_result_reg == rs2) rs2_val = executed_instr_result;
  end

  decoder d(.instruction(instr),
            .instruction_pc(regs::pc),
            .rs1_val(rs1_val),
            .rs2_val(rs2_val),
            .rs1(rs1),
            .rs2(rs2),
            .op_type(decoded_instr_operation_type),
            .instr_op1(decoded_instr_op1),
            .instr_op2(decoded_instr_op2),
            .out_reg(decoded_result_reg),
            .out_we(decoded_we),
            .jump(jump),
            .jump_target(jump_target),
            .illegal(illegal));

  alu a(.op1(toexecute_instr_op1),
        .op2(toexecute_instr_op2),
        .op_type(toexecute_instr_operation_type),
        .res(executed_instr_result));

  always_ff @(posedge iclk) begin
    if (!rst_n) begin
      regs::pc        <= 32'd0;
      toexecute_valid <= 1'b0;
      toexecute_we    <= 1'b0;
    end else begin
      if (illegal)
        $fatal(1, "Illegal instruction 0x%08h at pc 0x%08h", instr, regs::pc);
      if (jump && jump_target[1:0] != 2'b00)
        $fatal(1, "Misaligned jump target 0x%08h at pc 0x%08h", jump_target, regs::pc);

      // Stage 1 -> stage 2
      regs::pc                       <= jump ? jump_target : regs::pc + 32'd4;
      toexecute_valid                <= 1'b1;
      toexecute_instr_operation_type <= decoded_instr_operation_type;
      toexecute_instr_op1            <= decoded_instr_op1;
      toexecute_instr_op2            <= decoded_instr_op2;
      toexecute_result_reg           <= decoded_result_reg;
      toexecute_we                   <= decoded_we;
      toexecute_pc                   <= regs::pc;
      toexecute_instr                <= instr;

      // Stage 2: writeback + one trace line per retired instruction
      if (toexecute_we)
        regs::reg_page[toexecute_result_reg] <= executed_instr_result;
      if (toexecute_valid) begin
        if (toexecute_we)
          $display("(0x%08h) 0x%08h  %p <= 0x%08h", toexecute_pc, toexecute_instr,
                   toexecute_result_reg, executed_instr_result);
        else
          $display("(0x%08h) 0x%08h", toexecute_pc, toexecute_instr);
      end
    end
  end
endmodule
