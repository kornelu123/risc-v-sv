// Generic testbench: loads a raw binary at address 0 and runs until the
// program writes a nonzero value to its `tohost` word (riscv-tests
// convention): 1 = pass, otherwise (failing test number << 1) | 1.
//   +bin=<file>         program image (default test/test.bin)
//   +tohost=<hex>       address of `tohost` (the Makefile reads it from the ELF)
//   +irq=<hex>          address of the program's `irq_lines` word, if any. Bits
//                       3/7/11 drive the software/timer/external interrupt
//                       inputs (mip layout), standing in for the CLINT/PLIC.
//                       Bits 31:16 delay a new value by that many cycles, so
//                       an interrupt can arrive while the core sleeps in WFI.
//   +max_cycles=<n>     timeout (default 100000)
//   +trace              print one line per retired instruction
module t;
  logic      clk;
  logic      rst_n;
  string     bin_path;
  bit [31:0] tohost;
  bit [31:0] irq_addr;
  bit        irq_en;
  bit        irq_sw, irq_tm, irq_ex;
  bit [31:0] irq_seen;       // last value read from irq_lines
  int        irq_delay;      // cycles until irq_seen is applied
  bit [31:0] result;
  int        max_cycles;

  cu c(.iclk(clk),
       .rst_n(rst_n),
       .irq_software(irq_sw),
       .irq_timer(irq_tm),
       .irq_external(irq_ex));

  initial irq_en = $value$plusargs("irq=%h", irq_addr);

  always @(negedge clk) begin
    /* verilator lint_off UNUSEDSIGNAL */
    bit [31:0] w;      // bits 31:16 delay, bits 3/7/11 interrupt lines
    /* verilator lint_on UNUSEDSIGNAL */
    w = irq_en ? mem::word_at(irq_addr) : 32'd0;
    if (w != irq_seen) begin
      irq_seen  <= w;
      irq_delay <= int'(w[31:16]);
    end else if (irq_delay != 0) begin
      irq_delay <= irq_delay - 1;
    end else begin
      {irq_ex, irq_tm, irq_sw} <= {irq_seen[11], irq_seen[7], irq_seen[3]};
    end
  end

  initial begin
    clk = 1'b0;
    forever #1 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    if (!$value$plusargs("bin=%s", bin_path)) bin_path = "test/test.bin";
    if (!$value$plusargs("tohost=%h", tohost)) $fatal(1, "Missing +tohost=<hex address>");
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 100000;
    mem::read_from_file(bin_path);

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    for (int cyc = 0; mem::word_at(tohost) == 32'd0; cyc++) begin
      if (cyc == max_cycles)
        $fatal(1, "Timeout: nothing written to tohost (0x%08h) within %0d cycles (pc 0x%08h)",
               tohost, max_cycles, regs::pc);
      @(negedge clk);
    end

    result = mem::word_at(tohost);
    if (result != 32'd1)
      $fatal(1, "FAIL: tohost = 0x%08h (riscv-tests: failed test %0d)", result, result >> 1);
    $display("PASS");
    $finish;
  end
endmodule
