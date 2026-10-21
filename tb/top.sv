// Generic testbench: the SoC (rtl/soc.sv) with the SDRAM chip model
// (ulx3s/tb/models/sdram_model.sv, which checks the controller's commands
// and timing) at 50 MHz. It loads a raw binary at the start of RAM through
// the model's backdoor and runs until the program writes a nonzero value to
// its `tohost` word (riscv-tests convention): 1 = pass, otherwise (failing
// test number << 1) | 1. RAM the program does not load holds the model's
// fill pattern, not zeros.
//   +bin=<file>         program image (default test/test.bin)
//   +tohost=<hex>       address of `tohost` (the Makefile reads it from the ELF)
//   +irq=<hex>          address of the program's `irq_lines` word, if any. Bits
//                       3/7/11 drive the software/timer/external interrupt
//                       inputs (mip layout), standing in for the CLINT/PLIC.
//                       Bits 31:16 delay a new value by that many cycles, so
//                       an interrupt can arrive while the core sleeps in WFI.
//   +max_cycles=<n>     timeout (default 1000000), counted from reset; the
//                       SDRAM's power-up sequence takes the first ~10000
//   +trace              print one line per retired instruction
// The words are read as the program sees them: from the data cache if it
// holds them (it is write-back), otherwise from the SDRAM.
//
// Parameters (verilator -G...): the cache shapes (see rtl/cache.sv).
module t import memmap::*; #(
  parameter int IC_WAYS       = 2,
  parameter int IC_SETS       = 64,
  parameter int IC_LINE_WORDS = 8,
  parameter int DC_WAYS       = 2,
  parameter int DC_SETS       = 64,
  parameter int DC_LINE_WORDS = 8
);
  localparam int RAM_ADDR_BITS = $clog2(RAM_BYTES / 4);
  localparam int COL_BITS      = RAM_ADDR_BITS - 13 - 1;

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

  logic        init_done;
  logic        cke, csn, rasn, casn, wen, dq_oe;
  logic [12:0] a;
  logic [1:0]  ba, dqm;
  logic [15:0] dq_o, chip_dq;

  soc #(.IC_WAYS(IC_WAYS), .IC_SETS(IC_SETS), .IC_LINE_WORDS(IC_LINE_WORDS),
        .DC_WAYS(DC_WAYS), .DC_SETS(DC_SETS), .DC_LINE_WORDS(DC_LINE_WORDS),
        .CLK_MHZ(50)) s(
    .clk,
    .rst_n,
    .irq_software(irq_sw),
    .irq_timer(irq_tm),
    .irq_external(irq_ex),
    .init_done,
    .sdram_cke(cke), .sdram_csn(csn), .sdram_rasn(rasn), .sdram_casn(casn),
    .sdram_wen(wen), .sdram_a(a), .sdram_ba(ba), .sdram_dqm(dqm),
    .dq_o, .dq_oe, .dq_i(chip_dq));

  // As on the board: the chip is clocked by the inverted controller clock.
  sdram_model #(.COL_BITS(COL_BITS)) chip(
    .clk(~clk), .cke, .csn, .rasn, .casn, .wen, .a, .ba, .dqm,
    .dq_in(dq_o), .dq_in_en(dq_oe), .dq_out(chip_dq),
    // verilator lint_off PINCONNECTEMPTY
    .dq_out_en());
    // verilator lint_on PINCONNECTEMPTY

  // ---- Backdoor access to the SDRAM -------------------------------------------
  // RAM word w is the chip's {row, bank, column} = w, two 16-bit columns.
  function automatic void locate(bit [RAM_ADDR_BITS-1:0] w, output bit [1:0] b,
                                 output bit [12:0] r, output int col);
    b   = w[COL_BITS-1 +: 2];
    r   = 13'(w >> (COL_BITS + 1));
    col = int'(w[COL_BITS-2:0]) * 2;
  endfunction

  function automatic bit [31:0] ram_word(bit [31:0] addr);
    bit [1:0]  b;
    bit [12:0] r;
    int        col;
    if (!in_ram(addr, 2'd2)) return 32'd0;
    locate(RAM_ADDR_BITS'((addr - RAM_BASE) >> 2), b, r, col);
    return {chip.peek(b, r, col + 1), chip.peek(b, r, col)};
  endfunction

  // Load the image at RAM_BASE (the last word padded with zeros).
  function automatic void load(string path);
    int        fd, c, n, size;
    bit [31:0] w;
    bit [1:0]  b;
    bit [12:0] r;
    int        col;
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "Cannot open %0s", path);
    n    = 0;
    size = 0;
    w    = 32'd0;
    while (1) begin
      c = $fgetc(fd);
      if (c == -1 && n % 4 == 0) break;
      if (n == RAM_BYTES) $fatal(1, "%0s is larger than the %0d bytes of RAM", path, RAM_BYTES);
      if (c != -1) size++;
      w[8 * (n % 4) +: 8] = c == -1 ? 8'd0 : 8'(c);
      n++;
      if (n % 4 == 0) begin
        locate(RAM_ADDR_BITS'(n / 4 - 1), b, r, col);
        chip.poke(b, r, col, w[15:0]);
        chip.poke(b, r, col + 1, w[31:16]);
      end
    end
    $fclose(fd);
    $display("Loaded %0d bytes from %0s", size, path);
  endfunction

  // The word at (aligned) addr as the program sees it.
  function automatic bit [31:0] word_at(bit [31:0] addr);
    logic [31:0] w;
    if (!s.core.dcache.peek(addr[31:2], w)) w = ram_word(addr);
    return w;
  endfunction

  initial irq_en = $value$plusargs("irq=%h", irq_addr);

  always @(negedge clk) begin
    /* verilator lint_off UNUSEDSIGNAL */
    bit [31:0] w;      // bits 31:16 delay, bits 3/7/11 interrupt lines
    /* verilator lint_on UNUSEDSIGNAL */
    w = irq_en ? word_at(irq_addr) : 32'd0;
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
    forever #10 clk = ~clk;      // 50 MHz
  end

  initial begin
    rst_n = 1'b0;
    if (!$value$plusargs("bin=%s", bin_path)) bin_path = "test/test.bin";
    if (!$value$plusargs("tohost=%h", tohost)) $fatal(1, "Missing +tohost=<hex address>");
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 1000000;
    load(bin_path);

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    for (int cyc = 0; word_at(tohost) == 32'd0; cyc++) begin
      if (cyc == max_cycles) begin
        automatic string note = init_done ? "" : ", SDRAM not initialised";
        $fatal(1, "Timeout: nothing written to tohost (0x%08h) within %0d cycles (pc 0x%08h%0s)",
               tohost, max_cycles, regs::pc, note);
      end
      @(negedge clk);
    end

    result = word_at(tohost);
    if (result != 32'd1)
      $fatal(1, "FAIL: tohost = 0x%08h (riscv-tests: failed test %0d)", result, result >> 1);
    $display("PASS");
    $finish;
  end
endmodule
