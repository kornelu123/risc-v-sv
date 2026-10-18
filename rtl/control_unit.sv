// In-order 5-stage RV32I pipeline:
//   IF   fetch at pc
//   ID   decode, register read (same-cycle WB write bypassed), load-use check
//   EX   ALU with operands forwarded from MEM/WB; branches and jumps resolved
//   MEM  data memory access
//   WB   register write-back
//
// Hazards:
//   - Data: results are forwarded to EX from the MEM and WB stages. A load
//     followed by a dependent instruction stalls IF/ID for one cycle.
//   - Control: fetch predicts not taken. A taken branch or jump in EX
//     redirects pc and squashes the two younger instructions in IF and ID.
//   - ECALL/EBREAK: fetch stops once it leaves ID; the core halts when it
//     reaches WB, after every older instruction has completed.
// Illegal instructions and misaligned jump targets are reported in EX, where
// an instruction can no longer be squashed.
module cu import isa::*; (
  input  logic iclk,
  input  logic rst_n
);
  bit trace_en;
  initial trace_en = $test$plusargs("trace");

  bit halting;   // ECALL/EBREAK has left ID; fetch is stopped
  bit halted;    // ECALL/EBREAK has retired; the core is frozen

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
  bit         ex_taken, ex_redirect;

  // ---- EX/MEM --------------------------------------------------------------
  bit         ma_valid;
  bit [31:0]  ma_pc, ma_instr;
  regs::reg_t ma_rd;
  bit         ma_rd_we, ma_mem_read, ma_mem_write, ma_halt;
  bit [2:0]   ma_funct3;
  bit [31:0]  ma_alu_result;   // also the load/store address
  bit [31:0]  ma_store_data;

  // ---- MEM -----------------------------------------------------------------
  bit [31:0]  ma_result;       // value for rd: load data or ALU result

  // ---- MEM/WB --------------------------------------------------------------
  bit         wb_valid;
  bit [31:0]  wb_pc, wb_instr;
  regs::reg_t wb_rd;
  bit         wb_rd_we, wb_halt, wb_store;
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
    ex_target   = ex_ctrl.jalr ? (ex_rs1_fwd + ex_ctrl.imm) & ~32'd1
                               : ex_pc + ex_ctrl.imm;
    ex_redirect = ex_valid && (ex_ctrl.jal || ex_ctrl.jalr || (ex_ctrl.branch && ex_taken));
  end

  // ==== MEM =================================================================
  assign ma_result = ma_mem_read ? mem::load(ma_alu_result, ma_funct3) : ma_alu_result;

  // ==== Pipeline registers ==================================================
  always_ff @(posedge iclk) begin
    if (!rst_n) begin
      regs::pc <= 32'd0;
      halting  <= 1'b0;
      halted   <= 1'b0;
      id_valid <= 1'b0;
      ex_valid <= 1'b0;
      ma_valid <= 1'b0;
      wb_valid <= 1'b0;
    end else if (!halted) begin
      // ---- WB --------------------------------------------------------------
      if (wb_valid) begin
        if (wb_rd_we) regs::reg_page[wb_rd] <= wb_result;
        if (wb_halt)  halted <= 1'b1;

        if (trace_en) begin
          if (wb_rd_we)
            $display("(0x%08h) 0x%08h  %p <= 0x%08h", wb_pc, wb_instr, wb_rd, wb_result);
          else if (wb_store)
            $display("(0x%08h) 0x%08h  mem[0x%08h] <= 0x%08h", wb_pc, wb_instr,
                     wb_store_addr, wb_store_data);
          else if (wb_halt)
            $display("(0x%08h) 0x%08h  %s", wb_pc, wb_instr,
                     wb_instr == INSTR_EBREAK ? "ebreak" : "ecall");
          else
            $display("(0x%08h) 0x%08h", wb_pc, wb_instr);
        end
      end

      // ---- MEM -> WB -------------------------------------------------------
      if (ma_valid && (ma_mem_read || ma_mem_write) &&
          !mem::access_ok(ma_alu_result, ma_funct3[1:0]))
        $fatal(1, "Memory access fault at 0x%08h (pc 0x%08h)", ma_alu_result, ma_pc);

      if (ma_valid && ma_mem_write) begin
        mem::mem_pages[ma_alu_result] <= ma_store_data[7:0];
        if (ma_funct3 != FUNCT3_SB)
          mem::mem_pages[ma_alu_result + 1] <= ma_store_data[15:8];
        if (ma_funct3 == FUNCT3_SW) begin
          mem::mem_pages[ma_alu_result + 2] <= ma_store_data[23:16];
          mem::mem_pages[ma_alu_result + 3] <= ma_store_data[31:24];
        end
      end

      wb_valid      <= ma_valid;
      wb_pc         <= ma_pc;
      wb_instr      <= ma_instr;
      wb_rd         <= ma_rd;
      wb_rd_we      <= ma_rd_we;
      wb_halt       <= ma_halt;
      wb_store      <= ma_mem_write;
      wb_result     <= ma_result;
      wb_store_addr <= ma_alu_result;
      wb_store_data <= ma_store_data;

      // ---- EX -> MEM -------------------------------------------------------
      if (ex_valid && ex_ctrl.illegal)
        $fatal(1, "Illegal instruction 0x%08h at pc 0x%08h", ex_instr, ex_pc);
      if (ex_redirect && ex_target[1:0] != 2'b00)
        $fatal(1, "Misaligned jump target 0x%08h at pc 0x%08h", ex_target, ex_pc);

      ma_valid      <= ex_valid;
      ma_pc         <= ex_pc;
      ma_instr      <= ex_instr;
      ma_rd         <= ex_ctrl.rd;
      ma_rd_we      <= ex_ctrl.rd_we;
      ma_mem_read   <= ex_ctrl.mem_read;
      ma_mem_write  <= ex_ctrl.mem_write;
      ma_halt       <= ex_ctrl.halt;
      ma_funct3     <= ex_ctrl.funct3;
      ma_alu_result <= ex_alu_result;
      ma_store_data <= ex_rs2_fwd;

      // ---- ID -> EX: bubble on a squash or a load-use stall ----------------
      if (ex_redirect || load_use || !id_valid) begin
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
      if (ex_redirect) begin
        regs::pc <= ex_target;              // squash IF and ID
        id_valid <= 1'b0;
      end else if (load_use) begin
        // hold pc and IF/ID
      end else if (halting || (id_valid && id_ctrl.halt)) begin
        halting  <= 1'b1;                   // nothing may follow ECALL/EBREAK
        id_valid <= 1'b0;
      end else begin
        regs::pc <= regs::pc + 32'd4;
        id_valid <= 1'b1;
        id_pc    <= regs::pc;
        id_instr <= if_instr;
      end
    end
  end
endmodule
