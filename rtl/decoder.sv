// Combinational RV32I decoder. Register operands arrive already forwarded,
// so jumps and branches are resolved here (no wrong-path fetch, no flush).
module decoder import isa::*; (
  input  bit [31:0]     instruction,
  input  bit [31:0]     instruction_pc,
  input  bit [31:0]     rs1_val,
  input  bit [31:0]     rs2_val,
  output regs::reg_t    rs1,
  output regs::reg_t    rs2,
  output operation_type op_type,
  output bit [31:0]     instr_op1,
  output bit [31:0]     instr_op2,
  output regs::reg_t    out_reg,
  output bit            out_we,
  output bit            mem_read,
  output bit            mem_write,
  output bit [2:0]      mem_funct3,
  output bit [31:0]     store_data,
  output bit            jump,
  output bit [31:0]     jump_target,
  output bit            halt,       // ECALL / EBREAK
  output bit            illegal
);
  bit [6:0]  opcode;
  bit [6:0]  funct7;
  bit [2:0]  funct3;
  bit [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign opcode  = instruction[6:0];
  assign funct3  = instruction[14:12];
  assign funct7  = instruction[31:25];
  assign out_reg = regs::reg_t'(instruction[11:7]);
  assign rs1     = regs::reg_t'(instruction[19:15]);
  assign rs2     = regs::reg_t'(instruction[24:20]);

  assign imm_i = {{20{instruction[31]}}, instruction[31:20]};
  assign imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
  assign imm_b = {{20{instruction[31]}}, instruction[7], instruction[30:25],
                  instruction[11:8], 1'b0};
  assign imm_u = {instruction[31:12], 12'b0};
  assign imm_j = {{12{instruction[31]}}, instruction[19:12], instruction[20],
                  instruction[30:21], 1'b0};

  assign mem_funct3 = funct3;
  assign store_data = rs2_val;

  always_comb begin
    op_type     = ALU_ADD;
    instr_op1   = 32'd0;
    instr_op2   = 32'd0;
    out_we      = 1'b0;
    mem_read    = 1'b0;
    mem_write   = 1'b0;
    jump        = 1'b0;
    jump_target = 32'd0;
    halt        = 1'b0;
    illegal     = 1'b0;

    case (opcode)
      OPCODE_LUI: begin
        out_we    = 1'b1;
        instr_op2 = imm_u;                     // 0 + imm
      end

      OPCODE_AUIPC: begin
        out_we    = 1'b1;
        instr_op1 = instruction_pc;
        instr_op2 = imm_u;
      end

      OPCODE_JAL: begin
        out_we      = 1'b1;                    // rd = pc + 4 via the ALU
        instr_op1   = instruction_pc;
        instr_op2   = 32'd4;
        jump        = 1'b1;
        jump_target = instruction_pc + imm_j;
      end

      OPCODE_JALR: begin
        if (funct3 != FUNCT3_JALR) illegal = 1'b1;
        out_we      = 1'b1;
        instr_op1   = instruction_pc;
        instr_op2   = 32'd4;
        jump        = 1'b1;
        jump_target = (rs1_val + imm_i) & ~32'd1;
      end

      OPCODE_BRANCH: begin
        case (funct3)
          FUNCT3_BEQ:  jump = rs1_val == rs2_val;
          FUNCT3_BNE:  jump = rs1_val != rs2_val;
          FUNCT3_BLT:  jump = $signed(rs1_val) <  $signed(rs2_val);
          FUNCT3_BGE:  jump = $signed(rs1_val) >= $signed(rs2_val);
          FUNCT3_BLTU: jump = rs1_val <  rs2_val;
          FUNCT3_BGEU: jump = rs1_val >= rs2_val;
          default:     illegal = 1'b1;
        endcase
        jump_target = instruction_pc + imm_b;
      end

      OPCODE_LOAD: begin
        case (funct3)
          FUNCT3_LB, FUNCT3_LH, FUNCT3_LW, FUNCT3_LBU, FUNCT3_LHU: ;
          default: illegal = 1'b1;
        endcase
        out_we    = 1'b1;
        mem_read  = 1'b1;
        instr_op1 = rs1_val;                   // address = rs1 + imm
        instr_op2 = imm_i;
      end

      OPCODE_STORE: begin
        case (funct3)
          FUNCT3_SB, FUNCT3_SH, FUNCT3_SW: ;
          default: illegal = 1'b1;
        endcase
        mem_write = 1'b1;
        instr_op1 = rs1_val;
        instr_op2 = imm_s;
      end

      OPCODE_OP_IMM: begin
        out_we    = 1'b1;
        instr_op1 = rs1_val;
        instr_op2 = imm_i;
        case (funct3)
          FUNCT3_ADD_SUB: op_type = ALU_ADD;
          FUNCT3_SLT:     op_type = ALU_SLT;
          FUNCT3_SLTU:    op_type = ALU_SLTU;
          FUNCT3_XOR:     op_type = ALU_XOR;
          FUNCT3_OR:      op_type = ALU_OR;
          FUNCT3_AND:     op_type = ALU_AND;
          FUNCT3_SLL: begin
            op_type = ALU_SLL;
            if (funct7 != FUNCT7_BASE) illegal = 1'b1;
          end
          FUNCT3_SRL_SRA: begin
            if      (funct7 == FUNCT7_BASE) op_type = ALU_SRL;
            else if (funct7 == FUNCT7_ALT)  op_type = ALU_SRA;
            else illegal = 1'b1;
          end
        endcase
      end

      OPCODE_OP: begin
        out_we    = 1'b1;
        instr_op1 = rs1_val;
        instr_op2 = rs2_val;
        if (funct7 == FUNCT7_BASE) begin
          case (funct3)
            FUNCT3_ADD_SUB: op_type = ALU_ADD;
            FUNCT3_SLL:     op_type = ALU_SLL;
            FUNCT3_SLT:     op_type = ALU_SLT;
            FUNCT3_SLTU:    op_type = ALU_SLTU;
            FUNCT3_XOR:     op_type = ALU_XOR;
            FUNCT3_SRL_SRA: op_type = ALU_SRL;
            FUNCT3_OR:      op_type = ALU_OR;
            FUNCT3_AND:     op_type = ALU_AND;
          endcase
        end else if (funct7 == FUNCT7_ALT) begin
          case (funct3)
            FUNCT3_ADD_SUB: op_type = ALU_SUB;
            FUNCT3_SRL_SRA: op_type = ALU_SRA;
            default:        illegal = 1'b1;
          endcase
        end else begin
          illegal = 1'b1;
        end
      end

      // FENCE orders memory between harts/devices; with one in-order hart and
      // a single memory it is a no-op.
      OPCODE_MISC_MEM: begin
        if (funct3 != FUNCT3_FENCE) illegal = 1'b1;
      end

      OPCODE_SYSTEM: begin
        if (instruction == INSTR_ECALL || instruction == INSTR_EBREAK) halt = 1'b1;
        else illegal = 1'b1;
      end

      default: illegal = 1'b1;
    endcase

    if (illegal) begin
      out_we    = 1'b0;
      mem_read  = 1'b0;
      mem_write = 1'b0;
      jump      = 1'b0;
      halt      = 1'b0;
    end
    if (out_reg == regs::ZERO) out_we = 1'b0;  // x0 is never written or forwarded
  end
endmodule
