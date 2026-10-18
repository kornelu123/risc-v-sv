module t;
  localparam int        MAX_CYCLES = 2000;
  localparam bit [31:0] HALT_INSTR = 32'h0000006f;   // jal x0, 0  (test_done)

  logic clk;
  logic rst_n = 1'b0;
  int   errors = 0;

  cu c(clk, rst_n);

  initial begin
    clk = 1'b0;
    forever #1 clk = ~clk;
  end

  function automatic bit [31:0] x(bit [4:0] i);
    return regs::reg_page[i];
  endfunction

  task automatic check(string name, bit [31:0] got, bit [31:0] exp);
    if (got != exp) begin
      $display("FAIL %s: got 0x%08h, expected 0x%08h", name, got, exp);
      errors++;
    end
  endtask

  initial begin
    mem::read_from_file(`TESTFILE_PATH);

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    for (int cyc = 0; c.instr != HALT_INSTR; cyc++) begin
      if (cyc == MAX_CYCLES) $fatal(1, "Timeout: test_done not reached in %0d cycles", MAX_CYCLES);
      @(negedge clk);
    end
    repeat (2) @(negedge clk);   // let the last instruction write back

    check("x3  lui",            x(3),          32'h12345000);
    check("x4  lui",            x(4),          32'h7ffff000);
    check("x7  addi overflow",  x(7),          32'h7fffffff);
    check("x8",                 x(8),          32'd1);
    check("x9  add overflow",   x(9),          32'h80000000);
    check("x13 auipc +1",       x(13) - x(12), 32'd4  + 32'h00001000);
    check("x14 auipc pattern",  x(14) - x(12), 32'd8  + 32'h12345000);
    check("x15 auipc -1",       x(15) - x(12), 32'd12 - 32'h00001000);
    check("x16 auipc sign",     x(16) - x(12), 32'd16 + 32'h80000000);
    check("x17 x0 after auipc", x(17),         32'd0);
    check("x1  jal link",       x(1)  - x(12), 32'd36);
    check("x2  jal back link",  x(2)  - x(1),  32'd24);
    check("x5-x6 jalr -2048",   x(5)  - x(6),  32'd2052);
    check("x10 far jal link",   x(10) - x(6),  32'd12);
    check("x11 far back link",  x(11) - x(10), 32'd12);
    for (int i = 18; i <= 30; i++)
      if (i != 20) check($sformatf("x%0d irp", i), x(5'(i)), 32'd0);
    check("x20 control flow",   x(20),         32'h000003ff);
    check("x31 signature",      x(31),         32'h0000600d);

    if (errors != 0) $fatal(1, "%0d check(s) failed", errors);
    $display("PASS");
    $finish;
  end
endmodule
