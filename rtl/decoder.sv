module decoder(input  bit [31:0]     instruction,
               input  bit [31:0]     instruction_pc,
               input  bit [31:0]     rs1_val,      // already forwarded
               input  bit [31:0]     rs2_val,      // already forwarded
               output regs::reg_t    rs1,
               output regs::reg_t    rs2,
               output operation_type op_type,
               output bit [31:0]     instr_op1,
               output bit [31:0]     instr_op2,
               output regs::reg_t    out_reg,
               output bit            out_we,
               output bit            jump,
               output bit [31:0]     jump_target,
               output bit            illegal);

  bit [6:0]  opcode;
  bit [6:0]  funct7;
  bit [2:0]  funct3;
  bit [31:0] imm_i, imm_u, imm_j;

  assign opcode  = instruction[6:0];
  assign funct3  = instruction[14:12];
  assign funct7  = instruction[31:25];
  assign out_reg = regs::reg_t'(instruction[11:7]);
  assign rs1     = regs::reg_t'(instruction[19:15]);
  assign rs2     = regs::reg_t'(instruction[24:20]);

  assign imm_i = {{20{instruction[31]}}, instruction[31:20]};
  assign imm_u = {instruction[31:12], 12'b0};
  assign imm_j = {{12{instruction[31]}}, instruction[19:12], instruction[20],
                  instruction[30:21], 1'b0};

  always_comb begin
    op_type     = ADD;
    instr_op1   = 32'd0;
    instr_op2   = 32'd0;
    out_we      = 1'b0;
    jump        = 1'b0;
    jump_target = 32'd0;
    illegal     = 1'b0;

    case (opcode)
      OPCODE_MATH: begin
        out_we    = 1'b1;
        instr_op1 = rs1_val;
        instr_op2 = rs2_val;
        if      (funct3 == FUNCT3_MATH_BASIC && funct7 == FUNCT7_MATH_BASIC_ADD) op_type = ADD;
        else if (funct3 == FUNCT3_MATH_BASIC && funct7 == FUNCT7_MATH_BASIC_SUB) op_type = SUB;
        else illegal = 1'b1;
      end
      OPCODE_MATH_IMM: begin
        out_we    = 1'b1;
        instr_op1 = rs1_val;
        instr_op2 = imm_i;
        case (funct3)
          FUNCT3_IMM_ADD: op_type = ADD;
          default:        illegal = 1'b1;   // SLTI/XORI/... not implemented yet
        endcase
      end
      OPCODE_LUI: begin
        out_we    = 1'b1;
        instr_op1 = 32'd0;
        instr_op2 = imm_u;
      end
      OPCODE_AUIPC: begin
        out_we    = 1'b1;
        instr_op1 = instruction_pc;
        instr_op2 = imm_u;
      end
      OPCODE_JAL: begin
        out_we      = 1'b1;               // rd = pc + 4, computed by the ALU
        instr_op1   = instruction_pc;
        instr_op2   = 32'd4;
        jump        = 1'b1;
        jump_target = instruction_pc + imm_j;
      end
      OPCODE_JALR: begin
        if (funct3 != FUNCT3_JALR) illegal = 1'b1;
        else begin
          out_we      = 1'b1;
          instr_op1   = instruction_pc;
          instr_op2   = 32'd4;
          jump        = 1'b1;
          jump_target = (rs1_val + imm_i) & ~32'd1;
        end
      end
      default: illegal = 1'b1;
    endcase

    if (illegal) begin
      out_we = 1'b0;
      jump   = 1'b0;
    end
    if (out_reg == regs::ZERO) out_we = 1'b0;   // x0 is never written or forwarded
  end
endmodule
