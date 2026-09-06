module t;
  logic clk;
  cu c(clk);

  initial forever #1 clk = ~clk;

  initial begin
    @(posedge clk);
    $display("cu.instr_op1 : %h, cu.instr_op2: %h", c.instr_op1, c.instr_op2);
    $display("cu.result: %h", c.instr_result);
    @(posedge clk);
    $display("cu.instr_op1 : %h, cu.instr_op2: %h", c.instr_op1, c.instr_op2);
    $display("cu.result: %h", c.instr_result);
    @(posedge clk);
    $display("cu.instr_op1 : %h, cu.instr_op2: %h", c.instr_op1, c.instr_op2);
    $display("cu.result: %h", c.instr_result);
    $display("All finished");
    $finish();
  end
endmodule
