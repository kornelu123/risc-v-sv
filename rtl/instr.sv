class instr;
  bit [6:0] opcode;

  virtual function bit is_R_type(); return 1'b0; endfunction
  virtual function bit is_I_type(); return 1'b0; endfunction
  virtual function bit is_S_type(); return 1'b0; endfunction
  virtual function bit is_U_type(); return 1'b0; endfunction

  virtual function instr get_instr(bit [31:0] encoded); return null; endfunction

  virtual function bit execute(); return 1'b0;; endfunction

  static function instr create(bit [31:0] encoded);
    bit [6:0] opcode = encoded[6:0];
    bit [2:0] funct3 = encoded[14:12];
    bit [6:0] funct7 = encoded[31:25];
    instr obj;

    case (opcode)
      // ---------- R-type ----------
      7'b0110011,   // OP
      7'b0111011:   // OP-32
        obj = R_instr::new(encoded);

      // ---------- I-type ----------
      7'b0010011,   // OP-IMM
      7'b0000011,   // LOAD
      7'b1100111,   // JALR
      7'b0011011,   // OP-IMM-32
      7'b1110011:   // SYSTEM
        obj = I_instr::new(encoded);

      // ---------- S-type ----------
      7'b0100011:   // STORE
        obj = S_instr::new(encoded);

      // ---------- U-type ----------
      7'b0110111,   // LUI
      7'b0010111:   // AUIPC
        obj = U_instr::new(encoded);
      default:
        obj = null;
    endcase

    if (obj == null) return obj;

    obj.opcode = opcode;   // store the opcode in the object
    obj = obj.get_instr(encoded);
    return  obj;
  endfunction
endclass

class R_instr extends instr;
  bit [6:0] funct7;
  regs::reg_t rs2;
  regs::reg_t rs1;
  bit [2:0] funct3;
  regs::reg_t rd;

  function new(bit [31:0] encoded);
    funct7 = encoded[31:25];
    rs2 = regs::reg_t'(encoded[24:20]);
    rs1 = regs::reg_t'(encoded[19:15]);
    funct3 = encoded[14:12];
    rd = regs::reg_t'(encoded[11:7]);
    opcode = encoded[6:0];
  endfunction

  function instr get_instr(bit [31:0] encoded);
    return null;
  endfunction
endclass

class I_instr extends instr;
  bit [11:0] imm;
  regs::reg_t rs1;
  bit [2:0] funct3;
  regs::reg_t rd;

  function new(bit [31:0] encoded);
    imm = encoded[31:20];
    rs1 = regs::reg_t'(encoded[19:15]);
    funct3 = encoded[14:12];
    rd = regs::reg_t'(encoded[11:7]);
    opcode = encoded[6:0];
  endfunction

  function instr get_instr(bit [31:0] encoded);
    return null;
  endfunction
endclass

class S_instr extends instr;
  bit [11:0] imm;
  regs::reg_t rs2;
  regs::reg_t rs1;
  bit [2:0] funct3;
  regs::reg_t rd;

  function new(bit [31:0] encoded);
    imm[11:5] = encoded[31:25];
    rs2 = regs::reg_t'(encoded[24:20]);
    rs1 = regs::reg_t'(encoded[19:15]);
    funct3 = encoded[14:12];
    imm[4:0] = encoded[11:7];
    opcode = encoded[6:0];
  endfunction

  function instr get_instr(bit [31:0] encoded);
    return null;
  endfunction
endclass

typedef class LUI_instr;
typedef class AUIPC_instr;

class U_instr extends instr;
  bit [19:0] imm;
  regs::reg_t rd;

  function new(bit [31:0] encoded);
    imm = encoded[31:12];
    rd = regs::reg_t'(encoded[11:7]);
    opcode = encoded[6:0];
  endfunction

  function instr get_instr(bit [31:0] encoded);
    if (opcode == OPCODE_LUI) begin
      LUI_instr obj = new(encoded);
      return obj;
    end
    if (opcode == OPCODE_AUIPC) begin
      AUIPC_instr obj = new(encoded);
      return obj;
    end
    return null;
  endfunction
endclass

class LUI_instr extends U_instr;
  function new(bit [31:0] encoded);
    super.new(encoded);
  endfunction

  function bit execute();
    if (rd == regs::ZERO) return 1'b1;
    regs::reg_page[rd] = imm << 12;
    return 1'b1;
  endfunction
endclass

class AUIPC_instr extends U_instr;
  function new(bit [31:0] encoded);
    super.new(encoded);
  endfunction

  function bit execute();
    if (rd == regs::ZERO) return 1'b1;
    regs::reg_page[rd] = (imm << 12) + regs::pc;
    return 1'b1;
  endfunction
endclass

class ADDI_instr extends I_instr;
  function new(bit [31:0] encoded);
    super.new(encoded);
  endfunction

  function bit execute();
    if (rd == regs::ZERO) return 1'b1;
    regs::reg_page[rd] = regs::reg_page[rs1] + 32'(signed'(imm));
    return 1'b1;
  endfunction
endclass

class SLTI_instr extends I_instr;
  function new(bit [31:0] encoded);
    super.new(encoded);
  endfunction

  function bit execute();
    if (rd == regs::ZERO) return 1'b1;
    regs::reg_page[rd] = (32'(signed'(regs::reg_page[rs1])) < 32'(signed'(imm))) ? 1 : 0;
    return 1'b1;
  endfunction
endclass
