localparam bit [6:0] OPCODE_LUI     = 7'b0110111;
localparam bit [6:0] OPCODE_AUIPC   = 7'b0010111;
localparam bit [6:0] OPCODE_OP_IMM  = 7'b0010011;

typedef struct {
  bit [6:0] opcode;
  bit       is_funct3;
  bit [2:0] funct3;
  bit       is_funct7;
  bit [6:0] funct7;
} instr_op_t;
