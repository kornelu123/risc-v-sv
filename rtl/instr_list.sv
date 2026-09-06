localparam bit [6:0] OPCODE_LUI     = 7'b0110111;
localparam bit [6:0] OPCODE_AUIPC   = 7'b0010111;
localparam bit [6:0] OPCODE_JAL     = 7'b1101111;
localparam bit [6:0] OPCODE_JALR    = 7'b1100111;
localparam bit [6:0] OPCODE_BRANCH  = 7'b1100011;
localparam bit [6:0] OPCODE_MATH    = 7'b0110011;
localparam bit [6:0] OPCODE_MATH_IMM= 7'b0010011;

localparam bit [2:0] FUNCT3_MATH_BASIC     = 3'b000;
localparam bit [2:0] FUNCT3_IMM_ADD        = 3'b000;

localparam bit [6:0] FUNCT7_MATH_BASIC_ADD = 7'b0000000;
localparam bit [6:0] FUNCT7_MATH_BASIC_SUB = 7'b0110000;

localparam bit [2:0] FUNCT3_BEQ     = 3'b000;
localparam bit [2:0] FUNCT3_BNE     = 3'b001;
localparam bit [2:0] FUNCT3_BLT     = 3'b100;
localparam bit [2:0] FUNCT3_BGE     = 3'b101;
localparam bit [2:0] FUNCT3_BLTU    = 3'b110;
localparam bit [2:0] FUNCT3_BGEU    = 3'b111;

function void throw_error();
  $error("ERROR THROWN");
endfunction

typedef struct {
  bit [6:0] opcode;
  bit       is_funct3;
  bit [2:0] funct3;
  bit       is_funct7;
  bit [6:0] funct7;
} instr_op_t;
