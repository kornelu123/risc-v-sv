module cu(input logic iclk,
          input logic en);
  bit [31:0] fetched_instr;
  bit [31:0] todecode_instr;

  bit [31:0] decoded_instr_op1, decoded_instr_op2;

  bit [31:0] toexecute_instr_op1, toexecute_instr_op2;
  bit [31:0] executed_instr_result;

  regs::reg_t decoded_result_reg, towrite_result_reg, toexecute_result_reg, written_result_reg;
  operation_type decoded_instr_operation_type;
  operation_type toexecute_instr_operation_type;

  int debug_counter;
  string debug_print[3];

  bit en_dec, en_alu, en_wb;

  decoder d(todecode_instr,
            iclk,
            decoded_instr_operation_type,
            decoded_instr_op1,
            decoded_instr_op2,
            decoded_result_reg,
            en_dec);

  alu a(toexecute_instr_op1,
        toexecute_instr_op2,
        toexecute_instr_operation_type,
        iclk,
        executed_instr_result,
        en_alu);

  always @(posedge iclk) begin
    static bit [31:0] dbg_instr   [0:2];
    static bit [31:0] dbg_op1     [0:2];
    static bit [31:0] dbg_op2     [0:2];
    static regs::reg_t dbg_rd     [0:2];
    static bit [31:0] dbg_result  [0:2];
    
    en_wb   <= en_alu;
    en_alu  <= en_dec;
    en_dec  <= en;

    written_result_reg             <= towrite_result_reg;

    towrite_result_reg             <= toexecute_result_reg;

    toexecute_instr_op1            <= decoded_instr_op1;
    toexecute_instr_op2            <= decoded_instr_op2;
    toexecute_instr_operation_type <= decoded_instr_operation_type;
    toexecute_result_reg           <= decoded_result_reg;
  
    todecode_instr                 <= fetched_instr;
    fetched_instr                  <= mem::mem(regs::pc);
  
    dbg_instr[0]  <= fetched_instr;
  
    dbg_instr[1]  <= dbg_instr[0];
    dbg_op1[1]    <= toexecute_instr_op1;
    dbg_op2[1]    <= toexecute_instr_op2;
    dbg_rd[1]     <= toexecute_result_reg;
  
    dbg_instr[2]  <= dbg_instr[1];
    dbg_op1[2]    <= dbg_op1[1];
    dbg_op2[2]    <= dbg_op2[1];
    dbg_rd[2]     <= dbg_rd[1];
    dbg_result[2] <= executed_instr_result;
  
    if (debug_counter >= 2) begin
      $display("<<< 0x%08h : op1(0x%08h) op2(0x%08h) res_reg(%p) <<< result(0x%08h)",
               dbg_instr[2],
               dbg_op1[2],
               dbg_op2[2],
               dbg_rd[2],
               dbg_result[2]);
    end
  
    debug_counter++;
    regs::pc <= regs::pc + 4;

    if (en_wb) begin
      if (written_result_reg != regs::ZERO) begin
        regs::reg_page[towrite_result_reg] <= executed_instr_result;
      end
    end
  end
endmodule
