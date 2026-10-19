// RV32I encodings and the decoded control word shared by the pipeline stages.
package isa;
  // Opcodes
  localparam bit [6:0] OPCODE_LUI      = 7'b0110111;
  localparam bit [6:0] OPCODE_AUIPC    = 7'b0010111;
  localparam bit [6:0] OPCODE_JAL      = 7'b1101111;
  localparam bit [6:0] OPCODE_JALR     = 7'b1100111;
  localparam bit [6:0] OPCODE_BRANCH   = 7'b1100011;
  localparam bit [6:0] OPCODE_LOAD     = 7'b0000011;
  localparam bit [6:0] OPCODE_STORE    = 7'b0100011;
  localparam bit [6:0] OPCODE_OP_IMM   = 7'b0010011;
  localparam bit [6:0] OPCODE_OP       = 7'b0110011;
  localparam bit [6:0] OPCODE_MISC_MEM = 7'b0001111;
  localparam bit [6:0] OPCODE_SYSTEM   = 7'b1110011;

  // OP / OP-IMM funct3
  localparam bit [2:0] FUNCT3_ADD_SUB  = 3'b000;
  localparam bit [2:0] FUNCT3_SLL      = 3'b001;
  localparam bit [2:0] FUNCT3_SLT      = 3'b010;
  localparam bit [2:0] FUNCT3_SLTU     = 3'b011;
  localparam bit [2:0] FUNCT3_XOR      = 3'b100;
  localparam bit [2:0] FUNCT3_SRL_SRA  = 3'b101;
  localparam bit [2:0] FUNCT3_OR       = 3'b110;
  localparam bit [2:0] FUNCT3_AND      = 3'b111;

  // OP / shift-immediate funct7
  localparam bit [6:0] FUNCT7_BASE     = 7'b0000000;
  localparam bit [6:0] FUNCT7_ALT      = 7'b0100000;  // SUB, SRA, SRAI
  localparam bit [6:0] FUNCT7_MULDIV   = 7'b0000001;  // RV32M

  // BRANCH funct3
  localparam bit [2:0] FUNCT3_BEQ      = 3'b000;
  localparam bit [2:0] FUNCT3_BNE      = 3'b001;
  localparam bit [2:0] FUNCT3_BLT      = 3'b100;
  localparam bit [2:0] FUNCT3_BGE      = 3'b101;
  localparam bit [2:0] FUNCT3_BLTU     = 3'b110;
  localparam bit [2:0] FUNCT3_BGEU     = 3'b111;

  // LOAD / STORE funct3
  localparam bit [2:0] FUNCT3_LB       = 3'b000;
  localparam bit [2:0] FUNCT3_LH       = 3'b001;
  localparam bit [2:0] FUNCT3_LW       = 3'b010;
  localparam bit [2:0] FUNCT3_LBU      = 3'b100;
  localparam bit [2:0] FUNCT3_LHU      = 3'b101;
  localparam bit [2:0] FUNCT3_SB       = 3'b000;
  localparam bit [2:0] FUNCT3_SH       = 3'b001;
  localparam bit [2:0] FUNCT3_SW       = 3'b010;

  // JALR / MISC-MEM funct3
  localparam bit [2:0] FUNCT3_JALR     = 3'b000;
  localparam bit [2:0] FUNCT3_FENCE    = 3'b000;

  // SYSTEM with funct3 = 000
  localparam bit [2:0]  FUNCT3_PRIV    = 3'b000;
  localparam bit [31:0] INSTR_ECALL    = 32'h00000073;
  localparam bit [31:0] INSTR_EBREAK   = 32'h00100073;
  localparam bit [31:0] INSTR_MRET     = 32'h30200073;
  localparam bit [31:0] INSTR_WFI      = 32'h10500073;

  // Exception causes (mcause, interrupt bit 31 = 0)
  localparam bit [31:0] CAUSE_MISALIGNED_FETCH = 32'd0;
  localparam bit [31:0] CAUSE_ILLEGAL_INSTR    = 32'd2;
  localparam bit [31:0] CAUSE_BREAKPOINT       = 32'd3;
  localparam bit [31:0] CAUSE_LOAD_ACCESS      = 32'd5;
  localparam bit [31:0] CAUSE_STORE_ACCESS     = 32'd7;
  localparam bit [31:0] CAUSE_ECALL_M          = 32'd11;

  // RV32M funct3
  localparam bit [2:0] FUNCT3_MUL     = 3'b000;
  localparam bit [2:0] FUNCT3_MULH    = 3'b001;
  localparam bit [2:0] FUNCT3_MULHSU  = 3'b010;
  localparam bit [2:0] FUNCT3_MULHU   = 3'b011;
  localparam bit [2:0] FUNCT3_DIV     = 3'b100;
  localparam bit [2:0] FUNCT3_DIVU    = 3'b101;
  localparam bit [2:0] FUNCT3_REM     = 3'b110;
  localparam bit [2:0] FUNCT3_REMU    = 3'b111;

  // Zicsr funct3; funct3[2] selects the immediate (zimm) form
  localparam bit [2:0] FUNCT3_CSRRW   = 3'b001;
  localparam bit [2:0] FUNCT3_CSRRS   = 3'b010;
  localparam bit [2:0] FUNCT3_CSRRC   = 3'b011;
  localparam bit [2:0] FUNCT3_CSRRWI  = 3'b101;
  localparam bit [2:0] FUNCT3_CSRRSI  = 3'b110;
  localparam bit [2:0] FUNCT3_CSRRCI  = 3'b111;

  // CSR addresses. addr[11:10] == 2'b11 marks a read-only CSR.
  localparam bit [11:0] CSR_MSTATUS   = 12'h300;
  localparam bit [11:0] CSR_MISA      = 12'h301;
  localparam bit [11:0] CSR_MIE       = 12'h304;
  localparam bit [11:0] CSR_MTVEC     = 12'h305;
  localparam bit [11:0] CSR_MSTATUSH  = 12'h310;
  localparam bit [11:0] CSR_MSCRATCH  = 12'h340;
  localparam bit [11:0] CSR_MEPC      = 12'h341;
  localparam bit [11:0] CSR_MCAUSE    = 12'h342;
  localparam bit [11:0] CSR_MTVAL     = 12'h343;
  localparam bit [11:0] CSR_MIP       = 12'h344;
  localparam bit [11:0] CSR_MCYCLE    = 12'hB00;
  localparam bit [11:0] CSR_MINSTRET  = 12'hB02;
  localparam bit [11:0] CSR_MCYCLEH   = 12'hB80;
  localparam bit [11:0] CSR_MINSTRETH = 12'hB82;
  localparam bit [11:0] CSR_CYCLE     = 12'hC00;
  localparam bit [11:0] CSR_TIME      = 12'hC01;
  localparam bit [11:0] CSR_INSTRET   = 12'hC02;
  localparam bit [11:0] CSR_CYCLEH    = 12'hC80;
  localparam bit [11:0] CSR_TIMEH     = 12'hC81;
  localparam bit [11:0] CSR_INSTRETH  = 12'hC82;
  localparam bit [11:0] CSR_MVENDORID = 12'hF11;
  localparam bit [11:0] CSR_MARCHID   = 12'hF12;
  localparam bit [11:0] CSR_MIMPID    = 12'hF13;
  localparam bit [11:0] CSR_MHARTID   = 12'hF14;

  localparam bit [31:0] MISA_VALUE    = 32'h40001100;  // MXL=1 (RV32), I, M
  localparam bit [31:0] MIE_MASK      = 32'h00000888;  // MSIE, MTIE, MEIE

  typedef enum bit [4:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND,
    ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU
  } operation_type;

  typedef enum bit [1:0] { OP1_RS1, OP1_PC, OP1_ZERO } op1_sel_t;
  typedef enum bit [1:0] { OP2_RS2, OP2_IMM, OP2_FOUR } op2_sel_t;

  // Everything the later stages need to know about one instruction.
  typedef struct packed {
    operation_type alu_op;
    op1_sel_t      op1_sel;
    op2_sel_t      op2_sel;
    bit [31:0]     imm;
    regs::reg_t    rd;
    bit            rd_we;
    bit            mem_read;
    bit            mem_write;
    bit [2:0]      funct3;     // load/store width, branch condition
    bit            branch;
    bit            jal;
    bit            jalr;
    bit            ecall;
    bit            ebreak;
    bit            mret;
    bit            csr;        // Zicsr; the ALU result is the CSR write operand
    bit            illegal;
  } ctrl_t;
endpackage
