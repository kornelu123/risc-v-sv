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

  // SYSTEM: only ECALL and EBREAK are part of RV32I (CSRs are Zicsr).
  localparam bit [31:0] INSTR_ECALL    = 32'h00000073;
  localparam bit [31:0] INSTR_EBREAK   = 32'h00100073;

  // RV32M funct3
  localparam bit [2:0] FUNCT3_MUL     = 3'b000;
  localparam bit [2:0] FUNCT3_MULH    = 3'b001;
  localparam bit [2:0] FUNCT3_MULHSU  = 3'b010;
  localparam bit [2:0] FUNCT3_MULHU   = 3'b011;
  localparam bit [2:0] FUNCT3_DIV     = 3'b100;
  localparam bit [2:0] FUNCT3_DIVU    = 3'b101;
  localparam bit [2:0] FUNCT3_REM     = 3'b110;
  localparam bit [2:0] FUNCT3_REMU    = 3'b111;

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
    bit            halt;       // ECALL / EBREAK
    bit            illegal;
  } ctrl_t;
endpackage
