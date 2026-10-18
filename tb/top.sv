// Generic testbench: loads a raw binary at address 0, runs until the program
// executes ECALL/EBREAK, then checks a0: 0 = pass, anything else = fail code.
//   +bin=<file>         program image (default test/test.bin)
//   +max_cycles=<n>     timeout (default 100000)
//   +trace              print one line per retired instruction
module t;
  logic  clk;
  logic  rst_n;
  string bin_path;
  int    max_cycles;

  cu c(clk, rst_n);

  initial begin
    clk = 1'b0;
    forever #1 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    if (!$value$plusargs("bin=%s", bin_path)) bin_path = "test/test.bin";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 100000;
    mem::read_from_file(bin_path);

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    for (int cyc = 0; !c.halted; cyc++) begin
      if (cyc == max_cycles)
        $fatal(1, "Timeout: no ecall/ebreak within %0d cycles (pc 0x%08h)", max_cycles, regs::pc);
      @(negedge clk);
    end

    if (regs::reg_page[regs::A0] != 32'd0)
      $fatal(1, "FAIL: a0 = %0d (riscv-tests: failed test %0d)",
             regs::reg_page[regs::A0], regs::reg_page[regs::A0] >> 1);
    $display("PASS");
    $finish;
  end
endmodule
