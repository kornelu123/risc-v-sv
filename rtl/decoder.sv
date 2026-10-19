// Combinational RV32I decoder (ID stage). It only looks at the instruction
// bits; operands are selected and branches resolved later, in EX.
module decoder import isa::*; (
  input  bit [31:0]  instruction,
  output regs::reg_t rs1,
  output regs::reg_t rs2,
  output bit         uses_rs1,   // rs1/rs2 are real operands (load-use check)
  output bit         uses_rs2,
  output ctrl_t      ctrl
);
  bit [6:0]  opcode;
  bit [6:0]  funct7;
  bit [2:0]  funct3;
  bit [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign opcode = instruction[6:0];
  assign funct3 = instruction[14:12];
  assign funct7 = instruction[31:25];
  assign rs1    = regs::reg_t'(instruction[19:15]);
  assign rs2    = regs::reg_t'(instruction[24:20]);

  assign imm_i = {{20{instruction[31]}}, instruction[31:20]};
  assign imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
  assign imm_b = {{20{instruction[31]}}, instruction[7], instruction[30:25],
                  instruction[11:8], 1'b0};
  assign imm_u = {instruction[31:12], 12'b0};
  assign imm_j = {{12{instruction[31]}}, instruction[19:12], instruction[20],
                  instruction[30:21], 1'b0};

  always_comb begin
    ctrl        = '0;
    ctrl.rd     = regs::reg_t'(instruction[11:7]);
    ctrl.funct3 = funct3;
    uses_rs1    = 1'b0;
    uses_rs2    = 1'b0;

    case (opcode)
      OPCODE_LUI: begin
        ctrl.rd_we   = 1'b1;
        ctrl.op1_sel = OP1_ZERO;
        ctrl.op2_sel = OP2_IMM;
        ctrl.imm     = imm_u;
      end

      OPCODE_AUIPC: begin
        ctrl.rd_we   = 1'b1;
        ctrl.op1_sel = OP1_PC;
        ctrl.op2_sel = OP2_IMM;
        ctrl.imm     = imm_u;
      end

      OPCODE_JAL: begin
        ctrl.rd_we   = 1'b1;                   // rd = pc + 4
        ctrl.op1_sel = OP1_PC;
        ctrl.op2_sel = OP2_FOUR;
        ctrl.imm     = imm_j;                  // target = pc + imm
        ctrl.jal     = 1'b1;
      end

      OPCODE_JALR: begin
        if (funct3 != FUNCT3_JALR) ctrl.illegal = 1'b1;
        ctrl.rd_we    = 1'b1;
        ctrl.op1_sel  = OP1_PC;
        ctrl.op2_sel  = OP2_FOUR;
        ctrl.imm      = imm_i;                 // target = (rs1 + imm) & ~1
        ctrl.jalr     = 1'b1;
        uses_rs1 = 1'b1;
      end

      OPCODE_BRANCH: begin
        case (funct3)
          FUNCT3_BEQ, FUNCT3_BNE, FUNCT3_BLT,
          FUNCT3_BGE, FUNCT3_BLTU, FUNCT3_BGEU: ;
          default: ctrl.illegal = 1'b1;
        endcase
        ctrl.imm      = imm_b;
        ctrl.branch   = 1'b1;
        uses_rs1 = 1'b1;
        uses_rs2 = 1'b1;
      end

      OPCODE_LOAD: begin
        case (funct3)
          FUNCT3_LB, FUNCT3_LH, FUNCT3_LW, FUNCT3_LBU, FUNCT3_LHU: ;
          default: ctrl.illegal = 1'b1;
        endcase
        ctrl.rd_we    = 1'b1;
        ctrl.mem_read = 1'b1;
        ctrl.op2_sel  = OP2_IMM;               // address = rs1 + imm
        ctrl.imm      = imm_i;
        uses_rs1 = 1'b1;
      end

      OPCODE_STORE: begin
        case (funct3)
          FUNCT3_SB, FUNCT3_SH, FUNCT3_SW: ;
          default: ctrl.illegal = 1'b1;
        endcase
        ctrl.mem_write = 1'b1;
        ctrl.op2_sel   = OP2_IMM;
        ctrl.imm       = imm_s;
        uses_rs1 = 1'b1;
        uses_rs2 = 1'b1;                     // store data
      end

      OPCODE_OP_IMM: begin
        ctrl.rd_we    = 1'b1;
        ctrl.op2_sel  = OP2_IMM;
        ctrl.imm      = imm_i;
        uses_rs1 = 1'b1;
        case (funct3)
          FUNCT3_ADD_SUB: ctrl.alu_op = ALU_ADD;
          FUNCT3_SLT:     ctrl.alu_op = ALU_SLT;
          FUNCT3_SLTU:    ctrl.alu_op = ALU_SLTU;
          FUNCT3_XOR:     ctrl.alu_op = ALU_XOR;
          FUNCT3_OR:      ctrl.alu_op = ALU_OR;
          FUNCT3_AND:     ctrl.alu_op = ALU_AND;
          FUNCT3_SLL: begin
            ctrl.alu_op = ALU_SLL;
            if (funct7 != FUNCT7_BASE) ctrl.illegal = 1'b1;
          end
          FUNCT3_SRL_SRA: begin
            if      (funct7 == FUNCT7_BASE) ctrl.alu_op = ALU_SRL;
            else if (funct7 == FUNCT7_ALT)  ctrl.alu_op = ALU_SRA;
            else ctrl.illegal = 1'b1;
          end
        endcase
      end

      OPCODE_OP: begin
        ctrl.rd_we    = 1'b1;
        uses_rs1 = 1'b1;
        uses_rs2 = 1'b1;
        if (funct7 == FUNCT7_BASE) begin
          case (funct3)
            FUNCT3_ADD_SUB: ctrl.alu_op = ALU_ADD;
            FUNCT3_SLL:     ctrl.alu_op = ALU_SLL;
            FUNCT3_SLT:     ctrl.alu_op = ALU_SLT;
            FUNCT3_SLTU:    ctrl.alu_op = ALU_SLTU;
            FUNCT3_XOR:     ctrl.alu_op = ALU_XOR;
            FUNCT3_SRL_SRA: ctrl.alu_op = ALU_SRL;
            FUNCT3_OR:      ctrl.alu_op = ALU_OR;
            FUNCT3_AND:     ctrl.alu_op = ALU_AND;
          endcase
        end else if (funct7 == FUNCT7_MULDIV) begin
          case (funct3)
            FUNCT3_MUL:    ctrl.alu_op = ALU_MUL;
            FUNCT3_MULH:   ctrl.alu_op = ALU_MULH;
            FUNCT3_MULHSU: ctrl.alu_op = ALU_MULHSU;
            FUNCT3_MULHU:  ctrl.alu_op = ALU_MULHU;
            FUNCT3_DIV:    ctrl.alu_op = ALU_DIV;
            FUNCT3_DIVU:   ctrl.alu_op = ALU_DIVU;
            FUNCT3_REM:    ctrl.alu_op = ALU_REM;
            FUNCT3_REMU:   ctrl.alu_op = ALU_REMU;
          endcase
        end else if (funct7 == FUNCT7_ALT) begin
          case (funct3)
            FUNCT3_ADD_SUB: ctrl.alu_op = ALU_SUB;
            FUNCT3_SRL_SRA: ctrl.alu_op = ALU_SRA;
            default:        ctrl.illegal = 1'b1;
          endcase
        end else begin
          ctrl.illegal = 1'b1;
        end
      end

      // FENCE orders memory between harts/devices; with one in-order hart and
      // a single memory it is a no-op.
      OPCODE_MISC_MEM: begin
        if (funct3 != FUNCT3_FENCE) ctrl.illegal = 1'b1;
      end

      OPCODE_SYSTEM: begin
        if (instruction == INSTR_ECALL || instruction == INSTR_EBREAK) ctrl.halt = 1'b1;
        else begin
          case (funct3)
            // Decode only; the CSR is read and written in MEM (control_unit).
            // The ALU produces the write operand: rs1 + 0, or 0 + zimm.
            FUNCT3_CSRRW, FUNCT3_CSRRS, FUNCT3_CSRRC,
            FUNCT3_CSRRWI, FUNCT3_CSRRSI, FUNCT3_CSRRCI: begin
              ctrl.csr     = 1'b1;
              ctrl.rd_we   = 1'b1;
              ctrl.op1_sel = funct3[2] ? OP1_ZERO : OP1_RS1;
              ctrl.op2_sel = OP2_IMM;
              ctrl.imm     = funct3[2] ? {27'd0, instruction[19:15]} : 32'd0;
              uses_rs1     = !funct3[2];
            end
            default: ctrl.illegal = 1'b1;
          endcase
        end
      end

      default: ctrl.illegal = 1'b1;
    endcase

    if (ctrl.illegal) begin
      ctrl.rd_we     = 1'b0;
      ctrl.mem_read  = 1'b0;
      ctrl.mem_write = 1'b0;
      ctrl.branch    = 1'b0;
      ctrl.jal       = 1'b0;
      ctrl.jalr      = 1'b0;
      ctrl.halt      = 1'b0;
      ctrl.csr       = 1'b0;
      uses_rs1       = 1'b0;
      uses_rs2       = 1'b0;
    end
    if (ctrl.rd == regs::ZERO) ctrl.rd_we = 1'b0;  // x0 is never written or forwarded
  end
endmodule
