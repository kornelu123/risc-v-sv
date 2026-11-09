// Generic testbench: the SoC (rtl/soc.sv) at 50 MHz with an SD card
// (ulx3s/tb/models/sd_card_model.sv, which checks the SPI-mode protocol) and
// the SDRAM chip model (ulx3s/tb/models/sdram_model.sv, which checks the
// controller's commands and timing). Main memory lives on the card, so the
// program is put on the card: it boots from the card's first block. The run
// ends when the program writes a nonzero value to its `tohost` word
// (riscv-tests convention): 1 = pass, otherwise (failing test number << 1) | 1.
//   +bin=<file>         program, written to the start of the card (main
//                       memory at 0x8000_0000) over the disk image, if any
//   +sd_image=<file>    disk image: the card's contents (byte k = byte k of
//                       main memory, zeros past its end), written back when
//                       the simulation finishes, so it persists like a disk.
//                       Only what reached the card is saved: software must
//                       flush (rtl/sd_mem.sv). Without an image the card holds
//                       the model's fill pattern and nothing is saved.
//   +tohost=<hex>       address of `tohost` (the Makefile reads it from the ELF)
//   +irq=<hex>          address of the program's `irq_lines` word, if any. Bit 11
//                       drives the machine external interrupt (MEIP), standing in
//                       for the PLIC. (Timer and software interrupts: rtl/clint.sv.)
//   +max_cycles=<n>     timeout (default 4000000), counted from reset; the
//                       card's initialisation takes the first ~150000
//   +trace              print one line per retired instruction
// `tohost` and `irq_lines` are read as the program sees them: from the data
// cache, else the SDRAM if it holds the block, else the card.
// The bytes the program sends to the UART (rtl/uart.sv) are printed on stdout.
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
  localparam int SDRAM_BYTES     = 32 * 1024 * 1024;
  localparam int SDRAM_WORD_BITS = $clog2(SDRAM_BYTES / 4);
  localparam int MEM_WORD_BITS   = $clog2(MEM_BYTES / 4);
  localparam int COL_BITS        = SDRAM_WORD_BITS - 13 - 1;

  logic      clk;
  logic      rst_n;
  string     bin_path, sd_image;
  bit        bin_en, sd_image_en;
  bit [31:0] tohost;
  bit [31:0] irq_addr;
  bit        irq_en;
  bit        irq_ex;
  bit [31:0] result;
  int        max_cycles;

  logic        sdram_ready, mem_ready;
  logic        cke, csn, rasn, casn, wen, dq_oe;
  logic [12:0] a;
  logic [1:0]  ba, dqm;
  logic [15:0] dq_o, chip_dq;
  logic        sd_sck, sd_mosi, sd_cs_n, sd_miso;
  logic        uart_tx_valid;
  logic [7:0]  uart_tx_data;

  soc #(.IC_WAYS(IC_WAYS), .IC_SETS(IC_SETS), .IC_LINE_WORDS(IC_LINE_WORDS),
        .DC_WAYS(DC_WAYS), .DC_SETS(DC_SETS), .DC_LINE_WORDS(DC_LINE_WORDS),
        .CLK_MHZ(50), .SDRAM_BYTES(SDRAM_BYTES)) s(
    .clk,
    .rst_n,
    .irq_external(irq_ex),
    .sdram_ready,
    .mem_ready,
    .sdram_cke(cke), .sdram_csn(csn), .sdram_rasn(rasn), .sdram_casn(casn),
    .sdram_wen(wen), .sdram_a(a), .sdram_ba(ba), .sdram_dqm(dqm),
    .dq_o, .dq_oe, .dq_i(chip_dq),
    .sd_sck, .sd_mosi, .sd_cs_n, .sd_miso,
    .uart_tx_valid, .uart_tx_data);

  sd_card_model card(.sck(sd_sck), .mosi(sd_mosi), .cs_n(sd_cs_n), .miso(sd_miso));

  // As on the board: the chip is clocked by the inverted controller clock.
  sdram_model #(.COL_BITS(COL_BITS)) chip(
    .clk(~clk), .cke, .csn, .rasn, .casn, .wen, .a, .ba, .dqm,
    .dq_in(dq_o), .dq_in_en(dq_oe), .dq_out(chip_dq),
    // verilator lint_off PINCONNECTEMPTY
    .dq_out_en());
    // verilator lint_on PINCONNECTEMPTY

  // Console: the bytes the program sends to the UART.
  always @(posedge clk)
    if (uart_tx_valid) $write("%c", uart_tx_data);

  // ---- Backdoor access ------------------------------------------------------------
  // SDRAM word w is the chip's {row, bank, column} = w, two 16-bit columns.
  function automatic bit [31:0] sdram_word(bit [SDRAM_WORD_BITS-1:0] w);
    bit [1:0]  b;
    bit [12:0] r;
    int        col;
    b   = w[COL_BITS-1 +: 2];
    r   = 13'(w >> (COL_BITS + 1));
    col = int'(w[COL_BITS-2:0]) * 2;
    return {chip.peek(b, r, col + 1), chip.peek(b, r, col)};
  endfunction

  // The word at (aligned) addr as the program sees it.
  function automatic bit [31:0] word_at(bit [31:0] addr);
    logic [31:0]                w;
    logic [SDRAM_WORD_BITS-1:0] dw;
    longint                     off;
    if (s.core.dcache.peek(addr[31:2], w)) return w;
    if (!in_mem(addr, 2'd2)) return 32'd0;
    off = longint'(32'(addr - MEM_BASE));
    if (s.mem.peek(MEM_WORD_BITS'(off >> 2), dw)) return sdram_word(dw);
    return {card.peek(off + 3), card.peek(off + 2), card.peek(off + 1), card.peek(off)};
  endfunction

  // Write the program to the start of the card.
  function automatic void load(string path);
    int     fd, c;
    longint n;
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "Cannot open %0s", path);
    n = 0;
    for (c = $fgetc(fd); c != -1; c = $fgetc(fd)) begin
      if (n == longint'(MEM_BYTES)) $fatal(1, "%0s is larger than main memory", path);
      card.poke(n, 8'(c));
      n++;
    end
    $fclose(fd);
    $display("Loaded %0d bytes from %0s", n, path);
  endfunction

  initial irq_en = $value$plusargs("irq=%h", irq_addr);

  always @(negedge clk) begin
    /* verilator lint_off UNUSEDSIGNAL */
    bit [31:0] w;      // only bit 11, the external interrupt line, is used
    /* verilator lint_on UNUSEDSIGNAL */
    w = irq_en ? word_at(irq_addr) : 32'd0;
    irq_ex <= w[11];
  end

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;      // 50 MHz
  end

  final if (sd_image_en) card.save_image(sd_image);

  initial begin
    rst_n = 1'b0;
    sd_image_en = $value$plusargs("sd_image=%s", sd_image);
    bin_en      = $value$plusargs("bin=%s", bin_path);
    if (!bin_en && !sd_image_en) $fatal(1, "Nothing to run: give +bin=<file> and/or +sd_image=<file>");
    if (!$value$plusargs("tohost=%h", tohost)) $fatal(1, "Missing +tohost=<hex address>");
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 4000000;
    if (sd_image_en) card.load_image(sd_image);
    if (bin_en) load(bin_path);

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    for (int cyc = 0; word_at(tohost) == 32'd0; cyc++) begin
      if (cyc == max_cycles) begin
        automatic string note = !sdram_ready ? ", SDRAM not initialised" :
                                !mem_ready   ? ", SD card not initialised" : "";
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
