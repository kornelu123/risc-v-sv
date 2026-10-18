// RV32I encodings shared by the decoder, ALU and memory.
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

  typedef enum bit [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND
  } operation_type;
endpackage
