module t;
  logic clk;
  logic en;
  cu c(clk, en);

  initial forever #1 clk = ~clk;

  initial begin
    mem::read_from_file(`TESTFILE_PATH);
    en = 1'b1;
    repeat (100) begin
      @(posedge clk);
    end
    $finish();
  end
endmodule
