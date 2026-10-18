module cu(input logic iclk,
          input logic en);
  bit [31:0] fetched_instr;
  bit [31:0] todecode_instr;

  bit [31:0] decoded_instr_op1, decoded_instr_op2;

  bit [31:0] toexecute_instr_op1, toexecute_instr_op2;
  bit [31:0] executed_instr_result;

  bit [31:0] fetched_pc, todecode_pc;

  regs::reg_t decoded_result_reg, towrite_result_reg, toexecute_result_reg, written_result_reg;
  operation_type decoded_instr_operation_type;
  operation_type toexecute_instr_operation_type;

  int debug_counter;
  string debug_print[3];

  bit en_dec, en_alu, en_wb;
  bit pc_upd;

  decoder d(mem::mem(regs::pc),
            regs::pc,
            iclk,
            decoded_instr_operation_type,
            decoded_instr_op1,
            decoded_instr_op2,
            decoded_result_reg,
            en_dec,
            pc_upd);

  alu a(toexecute_instr_op1,
        toexecute_instr_op2,
        toexecute_instr_operation_type,
        iclk,
        executed_instr_result,
        en_alu);

  always @(negedge iclk) begin
    if (!pc_upd) regs::pc += 4;
  end

  always @(posedge iclk) begin
    static bit [31:0] dbg_instr   [0:1];
    static bit [31:0] dbg_op1     [0:1];
    static bit [31:0] dbg_op2     [0:1];
    static regs::reg_t dbg_rd     [0:1];
    static bit [31:0] dbg_result  [0:1];
    static bit [31:0] dbg_pc      [0:1];
    
    en_wb   <= en_alu;
    en_alu  <= en_dec;
    en_dec  <= en;

    written_result_reg             <= towrite_result_reg;

    towrite_result_reg             <= toexecute_result_reg;

    toexecute_instr_op1            <= decoded_instr_op1;
    toexecute_instr_op2            <= decoded_instr_op2;
    toexecute_instr_operation_type <= decoded_instr_operation_type;
    toexecute_result_reg           <= decoded_result_reg;

    dbg_instr[0]  <= mem::mem(regs::pc);
    dbg_op1[0]    <= toexecute_instr_op1;
    dbg_op2[0]    <= toexecute_instr_op2;
    dbg_rd[0]     <= toexecute_result_reg;
    dbg_pc[0]     <= regs::pc;
  
    dbg_instr[1]  <= dbg_instr[0];
    dbg_op1[1]    <= dbg_op1[0];
    dbg_op2[1]    <= dbg_op2[0];
    dbg_rd[1]     <= dbg_rd[0];
    dbg_result[1] <= executed_instr_result;
    dbg_pc[1]     <= dbg_pc[0];
  
    if (debug_counter >= 1) begin
      $display("(0x%08h) <<< 0x%08h(%7b) : op1(0x%08h) op2(0x%08h) res_reg(%p) <<< result(0x%08h)",
               dbg_pc[1],
               dbg_instr[1],
               dbg_instr[1][6:0],
               dbg_op1[1],
               dbg_op2[1],
               dbg_rd[1],
               dbg_result[1]);
    end
  
    debug_counter++;

    if (en_wb) begin
      if (written_result_reg != regs::ZERO) begin
        regs::reg_page[towrite_result_reg] <= executed_instr_result;
      end
    end
  end
endmodule
