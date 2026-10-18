module decoder(input bit [31:0] instruction,
               input bit [31:0] instruction_pc,
               input bit iclk,
               output operation_type op_type,
               output bit [31:0] instr_op1,
               output bit [31:0] instr_op2,
               output regs::reg_t out_reg, 
               input bit en,
               output bit pc_upd);

  bit[6:0] opcode;
  bit[6:0] funct7;
  regs::reg_t rs2;
  regs::reg_t rs1;
  bit[2:0] funct3;
  regs::reg_t rd;
  bit[11:0] imm;
  bit[20:0] Jimm;

  assign opcode         = instruction[6:0];
  assign funct7         = instruction[31:25];
  assign rs2            = regs::reg_t'(instruction[24:20]);
  assign rs1            = regs::reg_t'(instruction[19:15]);
  assign funct3         = instruction[14:12];
  assign rd             = regs::reg_t'(instruction[11:7]);
  assign imm            = instruction[31:20];

  assign Jimm[10:1]     = instruction[30:21];
  assign Jimm[19:12]    = instruction[19:12];
  assign Jimm[20]       = instruction[31];
  assign Jimm[11]       = instruction[20];

  always @(posedge iclk) begin
    pc_upd = 1'b0;
    if (en) begin
      case (opcode)
        OPCODE_MATH: handle_math_opcode();
        OPCODE_MATH_IMM: handle_imm_math_opcode();
        OPCODE_LUI: begin
          op_type = SLLI;
          out_reg = rd;
          instr_op1 = 32'(signed'(imm));
          instr_op2 = 32'(signed'(12));
        end
        OPCODE_AUIPC: begin
          op_type = SHL12ADD;
          out_reg = rd;
          instr_op1 = 32'(signed'(imm));
          instr_op2 = 32'(signed'(instruction_pc));
        end
        // We need to handle unconditional jump instr
        // ASAP, so we do it here
        OPCODE_JAL: begin
          $display("JAL");
          op_type = NONE;
          regs::reg_page[rd] = regs::pc + 4;
          if (rd == regs::ZERO) begin
            regs::pc = signed'(Jimm);
          end else begin
            regs::pc = signed'(Jimm) + instruction_pc;
          end
          if (regs::pc[3:0] & 2'b11) $error("Misaligned instr access");
          $display("Updated pc to %h", regs::pc);
          pc_upd = 1'b1;
        end
        OPCODE_JALR: begin
          op_type = NONE;
          regs::reg_page[rd]  <= regs::pc + 4;
          regs::pc            <= (signed'(imm) + regs::reg_page[rs1]) & 32'hFFFFFFFE;
        end
        default: $display("Unknown %h opcode", opcode);// $error("Unknown %h opcode", opcode);
      endcase
    end
  end

  function void handle_jumps_opcode();
  endfunction

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
          default: $error("Unknown funct7(%b) for opcode(%b) funct3(%b):: instr: %08h", funct7, opcode, funct3, instruction);
        endcase
      end
      default: $error("Unknown funct3(%b) for opcode(%b):: instr:%08h", funct7, opcode, instruction);
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
