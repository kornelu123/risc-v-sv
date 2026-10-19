// In-order 5-stage RV32I pipeline:
//   IF   fetch at pc
//   ID   decode, register read (same-cycle WB write bypassed), load-use check
//   EX   ALU with operands forwarded from MEM/WB; branches and jumps resolved;
//        DIV/REM run in a multi-cycle divider while EX, ID and IF stall
//   MEM  data memory access; commit point for traps, MRET and CSR instructions
//   WB   register write-back
//
// Hazards:
//   - Data: results are forwarded to EX from the MEM and WB stages. A load
//     followed by a dependent instruction stalls IF/ID for one cycle.
//   - Control: fetch predicts not taken. A taken branch or jump in EX
//     redirects pc and squashes the two younger instructions in IF and ID.
//   - Traps, MRET and CSR instructions take effect in MEM: everything older
//     has completed, everything younger (EX/ID/IF) is squashed and fetch
//     restarts at mtvec, mepc or the next instruction. CSR instructions
//     flush so nothing younger runs with stale CSR state (MEM->EX forwarding
//     only carries the ALU result).
//
// Exceptions found before MEM (illegal instruction, ECALL, EBREAK, jump to a
// misaligned target) travel down the pipeline with their instruction. A
// trapping instruction does not write rd or memory and does not retire.
module cu import isa::*; (
  input  logic iclk,
  input  logic rst_n,
  input  logic irq_software,   // machine software interrupt (mip.MSIP)
  input  logic irq_timer,      // machine timer interrupt (mip.MTIP)
  input  logic irq_external    // machine external interrupt (mip.MEIP)
);
  bit trace_en;
  initial trace_en = $test$plusargs("trace");

  // ---- IF ------------------------------------------------------------------
  bit [31:0] if_instr;
  assign if_instr = mem::fetch(regs::pc);

  // ---- IF/ID ---------------------------------------------------------------
  bit         id_valid;
  bit [31:0]  id_pc, id_instr;

  // ---- ID ------------------------------------------------------------------
  regs::reg_t id_rs1, id_rs2;
  ctrl_t      id_ctrl;
  bit [31:0]  id_rs1_val, id_rs2_val;
  bit         id_uses_rs1, id_uses_rs2;
  bit         load_use;

  // ---- ID/EX ---------------------------------------------------------------
  bit         ex_valid;
  bit [31:0]  ex_pc, ex_instr;
  ctrl_t      ex_ctrl;
  regs::reg_t ex_rs1, ex_rs2;
  bit [31:0]  ex_rs1_val, ex_rs2_val;

  // ---- EX ------------------------------------------------------------------
  bit [31:0]  ex_rs1_fwd, ex_rs2_fwd;
  bit [31:0]  ex_op1, ex_op2, ex_alu_result, ex_target;
  bit         ex_is_div, div_done, div_stall;
  bit [31:0]  div_result, ex_result;
  bit         ex_taken, ex_jump, ex_misaligned, ex_redirect;
  bit         ex_exc;
  bit [31:0]  ex_cause, ex_tval;

  // ---- EX/MEM --------------------------------------------------------------
  bit         ma_valid;
  bit [31:0]  ma_pc, ma_instr;
  regs::reg_t ma_rd;
  bit         ma_rd_we, ma_mem_read, ma_mem_write, ma_csr, ma_mret;
  bit         ma_fence_i, ma_lr, ma_sc, ma_amo;
  bit         ma_exc;          // exception found before MEM
  bit [31:0]  ma_cause, ma_tval;
  bit [2:0]   ma_funct3;
  bit [31:0]  ma_alu_result;   // also the load/store address
  bit [31:0]  ma_store_data;

  // ---- MEM -----------------------------------------------------------------
  bit [31:0]  ma_result;       // value for rd: load data, CSR value or ALU result
  bit [31:0]  ma_csr_old;
  bit         ma_csr_write, csr_illegal;
  bit         ma_access_fault;
  bit         ma_atomic_misaligned;
  bit         resv_valid;      // LR.W reservation
  bit [31:0]  resv_addr;
  bit         sc_ok;           // SC.W in MEM finds its reservation
  bit [31:0]  ma_mem_old;      // memory word an AMO reads
  bit [31:0]  ma_amo_result;
  bit         ma_do_store;     // MEM writes memory (failed SC.W does not)
  bit [31:0]  ma_wdata;
  bit         trap, flush;
  bit [31:0]  trap_cause, trap_tval, flush_pc, mtvec, mepc;
  bit         irq;             // an enabled interrupt is pending
  bit [31:0]  irq_cause;

  // ---- MEM/WB --------------------------------------------------------------
  bit         wb_valid;
  bit [31:0]  wb_pc, wb_instr;
  regs::reg_t wb_rd;
  bit         wb_rd_we, wb_store;
  bit [31:0]  wb_result, wb_store_addr, wb_store_data;

  // ==== ID ==================================================================
  decoder d(.instruction(id_instr),
            .rs1(id_rs1),
            .rs2(id_rs2),
            .uses_rs1(id_uses_rs1),
            .uses_rs2(id_uses_rs2),
            .ctrl(id_ctrl));

  // Register read; WB writes at the end of this cycle, so bypass it.
  always_comb begin
    id_rs1_val = (id_rs1 == regs::ZERO) ? 32'd0 : regs::reg_page[id_rs1];
    id_rs2_val = (id_rs2 == regs::ZERO) ? 32'd0 : regs::reg_page[id_rs2];
    if (wb_valid && wb_rd_we && wb_rd == id_rs1) id_rs1_val = wb_result;
    if (wb_valid && wb_rd_we && wb_rd == id_rs2) id_rs2_val = wb_result;
  end

  // A load in EX has no data until the end of MEM: hold a dependent
  // instruction in ID for one cycle.
  assign load_use = id_valid && ex_valid && ex_ctrl.mem_read && ex_ctrl.rd_we &&
                    ((id_uses_rs1 && id_rs1 == ex_ctrl.rd) ||
                     (id_uses_rs2 && id_rs2 == ex_ctrl.rd));

  // ==== EX ==================================================================
  // Forwarding; the younger producer (MEM) wins over WB.
  always_comb begin
    ex_rs1_fwd = ex_rs1_val;
    ex_rs2_fwd = ex_rs2_val;
    if (wb_valid && wb_rd_we && wb_rd == ex_rs1) ex_rs1_fwd = wb_result;
    if (wb_valid && wb_rd_we && wb_rd == ex_rs2) ex_rs2_fwd = wb_result;
    if (ma_valid && ma_rd_we && ma_rd == ex_rs1) ex_rs1_fwd = ma_alu_result;
    if (ma_valid && ma_rd_we && ma_rd == ex_rs2) ex_rs2_fwd = ma_alu_result;
  end

  always_comb begin
    case (ex_ctrl.op1_sel)
      OP1_PC:   ex_op1 = ex_pc;
      OP1_ZERO: ex_op1 = 32'd0;
      default:  ex_op1 = ex_rs1_fwd;
    endcase
    case (ex_ctrl.op2_sel)
      OP2_IMM:  ex_op2 = ex_ctrl.imm;
      OP2_FOUR: ex_op2 = 32'd4;
      default:  ex_op2 = ex_rs2_fwd;
    endcase
  end

  alu a(.op1(ex_op1),
        .op2(ex_op2),
        .op_type(ex_ctrl.alu_op),
        .res(ex_alu_result));

  // Divisions run in the multi-cycle divider: EX holds the division (and
  // IF/ID hold behind it) until the result is ready; MEM receives bubbles.
  // The operands are latched when the division starts, so later changes in
  // the forwarding sources do not matter. A flush can only squash a division
  // in its first EX cycle (afterwards MEM holds only bubbles, so nothing can
  // trap), which is why the divider is simply not started then.
  assign ex_is_div = ex_valid && !ex_ctrl.illegal &&
                     (ex_ctrl.alu_op == ALU_DIV || ex_ctrl.alu_op == ALU_DIVU ||
                      ex_ctrl.alu_op == ALU_REM || ex_ctrl.alu_op == ALU_REMU);
  assign div_stall = ex_is_div && !div_done;

  divider div(.clk(iclk),
              .rst_n(rst_n),
              .start(ex_is_div && !flush),
              .consume(ex_is_div && div_done),
              .op(ex_ctrl.alu_op),
              .a(ex_rs1_fwd),
              .b(ex_rs2_fwd),
              .done(div_done),
              .result(div_result));

  assign ex_result = ex_is_div ? div_result : ex_alu_result;

  always_comb begin
    case (ex_ctrl.funct3)
      FUNCT3_BEQ:  ex_taken = ex_rs1_fwd == ex_rs2_fwd;
      FUNCT3_BNE:  ex_taken = ex_rs1_fwd != ex_rs2_fwd;
      FUNCT3_BLT:  ex_taken = $signed(ex_rs1_fwd) <  $signed(ex_rs2_fwd);
      FUNCT3_BGE:  ex_taken = $signed(ex_rs1_fwd) >= $signed(ex_rs2_fwd);
      FUNCT3_BLTU: ex_taken = ex_rs1_fwd <  ex_rs2_fwd;
      FUNCT3_BGEU: ex_taken = ex_rs1_fwd >= ex_rs2_fwd;
      default:     ex_taken = 1'b0;
    endcase
    ex_target     = ex_ctrl.jalr ? (ex_rs1_fwd + ex_ctrl.imm) & ~32'd1
                                 : ex_pc + ex_ctrl.imm;
    ex_jump       = ex_valid && (ex_ctrl.jal || ex_ctrl.jalr || (ex_ctrl.branch && ex_taken));
    // A jump to a misaligned target traps on the jump itself: no redirect,
    // and (because it traps) no rd write.
    ex_misaligned = ex_jump && ex_target[1:0] != 2'b00;
    ex_redirect   = ex_jump && !ex_misaligned;

    // At most one exception per instruction, in priority order.
    ex_exc   = 1'b1;
    ex_cause = 32'd0;
    ex_tval  = 32'd0;
    if (ex_ctrl.illegal) begin
      ex_cause = CAUSE_ILLEGAL_INSTR;
      ex_tval  = ex_instr;
    end else if (ex_ctrl.ecall) begin
      ex_cause = CAUSE_ECALL_M;
    end else if (ex_ctrl.ebreak) begin
      ex_cause = CAUSE_BREAKPOINT;
    end else if (ex_misaligned) begin
      ex_cause = CAUSE_MISALIGNED_FETCH;
      ex_tval  = ex_target;
    end else begin
      ex_exc   = 1'b0;
    end
  end

  // ==== MEM =================================================================
  // CSR: the ALU result (ma_alu_result) is the write operand. CSRRW* always
  // write; CSRRS*/CSRRC* only write if the rs1/zimm field is not zero.
  assign ma_csr_write = ma_funct3[1:0] == FUNCT3_CSRRW[1:0] || ma_instr[19:15] != 5'd0;

  assign ma_access_fault = (ma_mem_read || ma_mem_write) &&
                           !mem::access_ok(ma_alu_result, ma_funct3[1:0]);

  // ---- A extension -----------------------------------------------------------
  // AMOs read and write memory in the same MEM cycle (asynchronous read,
  // write at the clock edge). Atomics must be naturally aligned.
  assign ma_atomic_misaligned = (ma_lr || ma_sc || ma_amo) && ma_alu_result[1:0] != 2'b00;
  assign sc_ok                = resv_valid && resv_addr == ma_alu_result;
  assign ma_mem_old           = mem::word_at(ma_alu_result);

  always_comb begin
    case (ma_instr[31:27])
      AMO_SWAP: ma_amo_result = ma_store_data;
      AMO_ADD:  ma_amo_result = ma_mem_old + ma_store_data;
      AMO_XOR:  ma_amo_result = ma_mem_old ^ ma_store_data;
      AMO_AND:  ma_amo_result = ma_mem_old & ma_store_data;
      AMO_OR:   ma_amo_result = ma_mem_old | ma_store_data;
      AMO_MIN:  ma_amo_result = $signed(ma_mem_old) < $signed(ma_store_data) ? ma_mem_old : ma_store_data;
      AMO_MAX:  ma_amo_result = $signed(ma_mem_old) > $signed(ma_store_data) ? ma_mem_old : ma_store_data;
      AMO_MINU: ma_amo_result = ma_mem_old < ma_store_data ? ma_mem_old : ma_store_data;
      default:  ma_amo_result = ma_mem_old > ma_store_data ? ma_mem_old : ma_store_data;  // MAXU
    endcase
  end

  assign ma_do_store = ma_mem_write && (!ma_sc || sc_ok);
  assign ma_wdata    = ma_amo ? ma_amo_result : ma_store_data;

  csr csrs(.clk(iclk),
           .rst_n(rst_n),
           .access(ma_valid && ma_csr && !ma_exc),
           .addr(ma_instr[31:20]),
           .op(ma_funct3[1:0]),
           .src(ma_alu_result),
           .write(ma_csr_write),
           .retire(ma_valid && !trap),
           .rdata(ma_csr_old),
           .illegal(csr_illegal),
           .trap(trap),
           .trap_pc(ma_pc),
           .trap_cause(trap_cause),
           .trap_tval(trap_tval),
           .mret(ma_valid && ma_mret && !trap),
           .mtvec(mtvec),
           .mepc(mepc),
           .irq_software(irq_software),
           .irq_timer(irq_timer),
           .irq_external(irq_external),
           .irq(irq),
           .irq_cause(irq_cause));

  // Trap decision for the instruction in MEM. An interrupt is taken on that
  // instruction before it executes (mepc points at it, so it runs after
  // MRET); then exceptions found earlier, then the ones only MEM can detect.
  always_comb begin
    trap       = ma_valid;
    trap_cause = ma_cause;
    trap_tval  = ma_tval;
    if (irq) begin
      trap_cause = irq_cause;
      trap_tval  = 32'd0;
    end else if (ma_exc) begin
      // cause and tval from EX
    end else if (ma_atomic_misaligned) begin
      trap_cause = ma_lr ? CAUSE_MISALIGNED_LOAD : CAUSE_MISALIGNED_STORE;
      trap_tval  = ma_alu_result;
    end else if (ma_access_fault) begin
      trap_cause = ma_mem_write ? CAUSE_STORE_ACCESS : CAUSE_LOAD_ACCESS;
      trap_tval  = ma_alu_result;
    end else if (ma_csr && csr_illegal) begin
      trap_cause = CAUSE_ILLEGAL_INSTR;
      trap_tval  = ma_instr;
    end else begin
      trap       = 1'b0;
    end

    flush    = ma_valid && (trap || ma_mret || ma_csr || ma_fence_i);
    flush_pc = trap ? mtvec : ma_mret ? mepc : ma_pc + 32'd4;
  end

  assign ma_result = ma_sc       ? {31'd0, !sc_ok} :          // 0 = success
                     ma_mem_read ? mem::load(ma_alu_result, ma_funct3) :
                     ma_csr      ? ma_csr_old : ma_alu_result;

  // ==== Pipeline registers ==================================================
  always_ff @(posedge iclk) begin
    if (!rst_n) begin
      regs::pc   <= 32'd0;
      id_valid   <= 1'b0;
      ex_valid   <= 1'b0;
      ma_valid   <= 1'b0;
      wb_valid   <= 1'b0;
      resv_valid <= 1'b0;
    end else begin
      // ---- WB --------------------------------------------------------------
      if (wb_valid) begin
        if (wb_rd_we) regs::reg_page[wb_rd] <= wb_result;

        if (trace_en) begin
          if (wb_rd_we)
            $display("(0x%08h) 0x%08h  %p <= 0x%08h", wb_pc, wb_instr, wb_rd, wb_result);
          else if (wb_store)
            $display("(0x%08h) 0x%08h  mem[0x%08h] <= 0x%08h", wb_pc, wb_instr,
                     wb_store_addr, wb_store_data);
          else
            $display("(0x%08h) 0x%08h", wb_pc, wb_instr);
        end
      end

      // ---- MEM -> WB -------------------------------------------------------
      if (trace_en && trap)
        $display("(0x%08h) 0x%08h  trap mcause=%0d mtval=0x%08h", ma_pc, ma_instr,
                 trap_cause, trap_tval);

      if (ma_valid && ma_do_store && !trap) begin
        mem::mem_pages[ma_alu_result] <= ma_wdata[7:0];
        if (ma_funct3 != FUNCT3_SB)
          mem::mem_pages[ma_alu_result + 1] <= ma_wdata[15:8];
        if (ma_funct3 == FUNCT3_SW) begin
          mem::mem_pages[ma_alu_result + 2] <= ma_wdata[23:16];
          mem::mem_pages[ma_alu_result + 3] <= ma_wdata[31:24];
        end
      end

      // A trap (including an interrupt) drops the reservation; every SC.W
      // consumes it, successful or not.
      if (trap)
        resv_valid <= 1'b0;
      else if (ma_valid && ma_lr) begin
        resv_valid <= 1'b1;
        resv_addr  <= ma_alu_result;
      end else if (ma_valid && ma_sc)
        resv_valid <= 1'b0;

      wb_valid      <= ma_valid && !trap;
      wb_pc         <= ma_pc;
      wb_instr      <= ma_instr;
      wb_rd         <= ma_rd;
      wb_rd_we      <= ma_rd_we;
      wb_store      <= ma_do_store;
      wb_result     <= ma_result;
      wb_store_addr <= ma_alu_result;
      wb_store_data <= ma_wdata;

      // ---- EX -> MEM -------------------------------------------------------
      ma_valid      <= ex_valid && !flush && !div_stall;
      ma_pc         <= ex_pc;
      ma_instr      <= ex_instr;
      ma_rd         <= ex_ctrl.rd;
      ma_rd_we      <= ex_ctrl.rd_we;
      ma_mem_read   <= ex_ctrl.mem_read;
      ma_mem_write  <= ex_ctrl.mem_write;
      ma_csr        <= ex_ctrl.csr;
      ma_mret       <= ex_ctrl.mret;
      ma_fence_i    <= ex_ctrl.fence_i;
      ma_lr         <= ex_ctrl.lr;
      ma_sc         <= ex_ctrl.sc;
      ma_amo        <= ex_ctrl.amo;
      ma_exc        <= ex_exc;
      ma_cause      <= ex_cause;
      ma_tval       <= ex_tval;
      ma_funct3     <= ex_ctrl.funct3;
      ma_alu_result <= ex_result;
      ma_store_data <= ex_rs2_fwd;

      // ---- ID -> EX: bubble on squash / load-use, hold during a division -----
      if (div_stall && !flush) begin
        // hold EX
      end else if (flush || ex_redirect || load_use || !id_valid) begin
        ex_valid <= 1'b0;
      end else begin
        ex_valid   <= 1'b1;
        ex_pc      <= id_pc;
        ex_instr   <= id_instr;
        ex_ctrl    <= id_ctrl;
        ex_rs1     <= id_rs1;
        ex_rs2     <= id_rs2;
        ex_rs1_val <= id_rs1_val;
        ex_rs2_val <= id_rs2_val;
      end

      // ---- IF -> ID and next pc --------------------------------------------
      if (flush) begin
        regs::pc <= flush_pc;               // squash IF, ID and EX
        id_valid <= 1'b0;
      end else if (div_stall) begin
        // hold pc and IF/ID behind the division
      end else if (ex_redirect) begin
        regs::pc <= ex_target;              // squash IF and ID
        id_valid <= 1'b0;
      end else if (load_use) begin
        // hold pc and IF/ID
      end else begin
        regs::pc <= regs::pc + 32'd4;
        id_valid <= 1'b1;
        id_pc    <= regs::pc;
        id_instr <= if_instr;
      end
    end
  end
endmodule
