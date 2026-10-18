typedef enum {
  ADD, SUB, SLLI, SHL12ADD, NONE
} operation_type;

module alu(input bit [31:0] op1,
           input bit [31:0] op2,
           input operation_type op_type,
           input bit iclk,
           output bit [31:0] res,
           input bit en);

  function void throw_error();
    $error("ERROR THROWN");
  endfunction

  always @(negedge iclk) begin
    if (en) begin
      case (op_type)
        ADD:
          res = op1 + op2;
        SUB:
          res = op1 - op2;
        SLLI:
          res = op1 << op2;
        SHL12ADD:
          res = op1 + (op2 << 12);
        NONE:; // Do nothing
        default:
          throw_error();
      endcase
    end
  end
endmodule
