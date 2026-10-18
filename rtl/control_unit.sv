// In-order RV32I core, 2 pipeline stages on one clock edge:
//   stage 1: fetch + decode + register read; jumps and branches resolved
//   stage 2: execute + memory access + writeback
// Memory reads are asynchronous, so the stage-2 result (ALU or load data) is
// forwarded to stage 1 in the same cycle: no stalls and no flushes are needed.
// ECALL/EBREAK halt the core; the testbench then inspects a0.
module cu import isa::*; (
  input  logic iclk,
  input  logic rst_n
);
  bit trace_en;
  initial trace_en = $test$plusargs("trace");

  // Stage 1
  bit [31:0]     instr;
  regs::reg_t    rs1, rs2;
  bit [31:0]     rs1_val, rs2_val;
  operation_type decoded_op_type;
  bit [31:0]     decoded_op1, decoded_op2;
  regs::reg_t    decoded_rd;
  bit            decoded_we, decoded_mem_read, decoded_mem_write;
  bit [2:0]      decoded_mem_funct3;
  bit [31:0]     decoded_store_data;
  bit            jump, halt, illegal;
  bit [31:0]     jump_target;
  bit            halted;

  // Stage 2
  bit            ex_valid;
  operation_type ex_op_type;
  bit [31:0]     ex_op1, ex_op2;
  regs::reg_t    ex_rd;
  bit            ex_we, ex_mem_read, ex_mem_write;
  bit [2:0]      ex_mem_funct3;
  bit [31:0]     ex_store_data, ex_pc, ex_instr;
  bit [31:0]     alu_result;   // also the load/store address
  bit [31:0]     ex_result;    // value written to rd

  assign instr     = mem::fetch(regs::pc);
  assign ex_result = ex_mem_read ? mem::load(alu_result, ex_mem_funct3) : alu_result;

  // Forwarding: the stage-2 instruction writes rd at the end of this cycle.
  always_comb begin
    rs1_val = (rs1 == regs::ZERO) ? 32'd0 : regs::reg_page[rs1];
    rs2_val = (rs2 == regs::ZERO) ? 32'd0 : regs::reg_page[rs2];
    if (ex_we && ex_rd == rs1) rs1_val = ex_result;
    if (ex_we && ex_rd == rs2) rs2_val = ex_result;
  end

  decoder d(.instruction(instr),
            .instruction_pc(regs::pc),
            .rs1_val(rs1_val),
            .rs2_val(rs2_val),
            .rs1(rs1),
            .rs2(rs2),
            .op_type(decoded_op_type),
            .instr_op1(decoded_op1),
            .instr_op2(decoded_op2),
            .out_reg(decoded_rd),
            .out_we(decoded_we),
            .mem_read(decoded_mem_read),
            .mem_write(decoded_mem_write),
            .mem_funct3(decoded_mem_funct3),
            .store_data(decoded_store_data),
            .jump(jump),
            .jump_target(jump_target),
            .halt(halt),
            .illegal(illegal));

  alu a(.op1(ex_op1),
        .op2(ex_op2),
        .op_type(ex_op_type),
        .res(alu_result));

  always_ff @(posedge iclk) begin
    if (!rst_n) begin
      regs::pc     <= 32'd0;
      halted       <= 1'b0;
      ex_valid     <= 1'b0;
      ex_we        <= 1'b0;
      ex_mem_read  <= 1'b0;
      ex_mem_write <= 1'b0;
    end else begin
      // ---- Stage 2: memory access + writeback ----------------------------
      if (ex_valid) begin
        if ((ex_mem_read || ex_mem_write) && !mem::access_ok(alu_result, ex_mem_funct3[1:0]))
          $fatal(1, "Memory access fault at 0x%08h (pc 0x%08h)", alu_result, ex_pc);

        if (ex_mem_write) begin
          mem::mem_pages[alu_result] <= ex_store_data[7:0];
          if (ex_mem_funct3 != FUNCT3_SB)
            mem::mem_pages[alu_result + 1] <= ex_store_data[15:8];
          if (ex_mem_funct3 == FUNCT3_SW) begin
            mem::mem_pages[alu_result + 2] <= ex_store_data[23:16];
            mem::mem_pages[alu_result + 3] <= ex_store_data[31:24];
          end
        end

        if (ex_we) regs::reg_page[ex_rd] <= ex_result;

        if (trace_en) begin
          if (ex_we)
            $display("(0x%08h) 0x%08h  %p <= 0x%08h", ex_pc, ex_instr, ex_rd, ex_result);
          else if (ex_mem_write)
            $display("(0x%08h) 0x%08h  mem[0x%08h] <= 0x%08h", ex_pc, ex_instr,
                     alu_result, ex_store_data);
          else
            $display("(0x%08h) 0x%08h", ex_pc, ex_instr);
        end
      end

      // ---- Stage 1 -> stage 2 ---------------------------------------------
      if (!halted) begin
        if (illegal)
          $fatal(1, "Illegal instruction 0x%08h at pc 0x%08h", instr, regs::pc);
        if (jump && jump_target[1:0] != 2'b00)
          $fatal(1, "Misaligned jump target 0x%08h at pc 0x%08h", jump_target, regs::pc);

        if (halt) begin
          halted       <= 1'b1;
          ex_valid     <= 1'b0;
          ex_we        <= 1'b0;
          ex_mem_read  <= 1'b0;
          ex_mem_write <= 1'b0;
          if (trace_en)
            $display("(0x%08h) 0x%08h  %s", regs::pc, instr,
                     instr == INSTR_EBREAK ? "ebreak" : "ecall");
        end else begin
          regs::pc      <= jump ? jump_target : regs::pc + 32'd4;
          ex_valid      <= 1'b1;
          ex_op_type    <= decoded_op_type;
          ex_op1        <= decoded_op1;
          ex_op2        <= decoded_op2;
          ex_rd         <= decoded_rd;
          ex_we         <= decoded_we;
          ex_mem_read   <= decoded_mem_read;
          ex_mem_write  <= decoded_mem_write;
          ex_mem_funct3 <= decoded_mem_funct3;
          ex_store_data <= decoded_store_data;
          ex_pc         <= regs::pc;
          ex_instr      <= instr;
        end
      end
    end
  end
endmodule
