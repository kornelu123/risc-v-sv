module t;
  logic clk;
  cu c(clk);

  initial forever #1 clk = ~clk;

  initial begin
    $display("Creating instr");
    @(posedge clk);
    $display("Fetched instr: %h", c.fetched_instr);
    $display("Decoded instr: %p", c.decoded_instr);
    @(posedge clk);
    $display("Fetched instr: %h", c.fetched_instr);
    $display("Decoded instr: %p", c.decoded_instr);
    @(posedge clk);
    $display("Fetched instr: %h", c.fetched_instr);
    $display("Decoded instr: %p", c.decoded_instr);

    repeat(10) @(posedge clk);
    $display("All finished");
    $finish();
  end
endmodule
