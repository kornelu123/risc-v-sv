module decoder(input bit [31:0] instruction,
               input bit iclk,
               output operation_type op_type,
               output bit [31:0] instr_op1,
               output bit [31:0] instr_op2,
               output regs::reg_t out_reg);

  bit[6:0] opcode;
  bit[6:0] funct7;
  regs::reg_t rs2;
  regs::reg_t rs1;
  bit[2:0] funct3;
  regs::reg_t rd;
  bit[11:0] imm;

  assign opcode = instruction[6:0];
  assign funct7 = instruction[31:25];
  assign rs2    = regs::reg_t'(instruction[24:20]);
  assign rs1    = regs::reg_t'(instruction[19:15]);
  assign funct3 = instruction[14:12];
  assign rd     = regs::reg_t'(instruction[11:7]);
  assign imm    = instruction[31:20];

  always @(posedge iclk) begin
    case (opcode)
      OPCODE_MATH: handle_math_opcode();
      OPCODE_MATH_IMM: handle_imm_math_opcode();
      default: $error("Unknown %h opcode", opcode);
    endcase
  end

  function void handle_math_opcode();
    case (funct3)
      FUNCT3_MATH_BASIC: begin
        case (funct7)
          FUNCT7_MATH_BASIC_ADD: begin
            op_type = ADD;
            out_reg = rd;
            instr_op1 = regs::reg_page[rs1];
            instr_op2 = regs::reg_page[rs2];
          end

          FUNCT7_MATH_BASIC_SUB: begin
            op_type = SUB;
            out_reg = rd;
            instr_op1 = regs::reg_page[rs1];
            instr_op2 = regs::reg_page[rs2];
          end
          default: $error("Unknown funct7 %h for %h opcode %h funct3", funct7, opcode, funct3);
        endcase
      end
      default: $error("Unknown funct3 %h for %h opcode", funct7, opcode);
    endcase
  endfunction

  function void handle_imm_math_opcode();
    FUNCT3_IMM_ADD: begin
      op_type = ADD;
      out_reg = rd;
      instr_op1 = regs::reg_page[rs1];
      instr_op2 = 32'(signed'(imm));
    end
  endfunction
endmodule
