typedef enum {
  ADD, SUB
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
        default:
          throw_error();
      endcase
    end
  end
endmodule
