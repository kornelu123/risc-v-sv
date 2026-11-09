// Self-checking testbench for sdram.sv against sdram_model.sv. The model
// checks the SDRAM protocol and timing; this testbench checks the data, the
// burst interface and that open rows are reused.
module tb_sdram #(
  parameter int CLK_MHZ     = 50,
  parameter int CAS_LATENCY = 2,
  parameter int COL_BITS    = 9,
  // Raised together in one configuration so that each timer, not the
  // controller's state sequence, sets the spacing of commands.
  parameter int T_RCD_NS    = 21,
  parameter int T_RP_NS     = 21,
  parameter int T_RC_NS     = 66,
  parameter int T_RAS_NS    = 44,
  parameter int T_RRD_NS    = 15,
  parameter int T_WR_NS     = 15
);
  localparam int  ROW_BITS  = 13;
  localparam int  MAX_BURST = 8;
  localparam int  ADDR_BITS = ROW_BITS + 2 + COL_BITS - 1;
  localparam int  LEN_BITS  = $clog2(MAX_BURST);
  localparam int  ROW_WORDS = 1 << (COL_BITS - 1);
  localparam real PERIOD    = 1000.0 / CLK_MHZ;
  // Read of n words with the row already open, from acceptance to the last
  // word: one READ every two cycles, CAS latency, the second half-word, and
  // the registered response seen by the testbench.
  function automatic longint hit_cycles(int n);
    int c = 2 * (n - 1) + CAS_LATENCY + 3;
    return longint'(c);
  endfunction

  logic                 clk = 1'b0;
  logic                 rst_n = 1'b0;
  logic                 req_valid = 1'b0, req_ready, req_we, wr_ready;
  logic [ADDR_BITS-1:0] req_addr;
  logic [LEN_BITS-1:0]  req_len;
  logic [31:0]          req_wdata, rsp_rdata;
  logic [3:0]           req_wstrb;
  logic                 rsp_valid, init_done;

  logic        cke, csn, rasn, casn, wen, dq_oe, model_oe;
  logic [12:0] a;
  logic [1:0]  ba, dqm;
  logic [15:0] dq_o, model_dq;

  always #(PERIOD / 2) clk = ~clk;

  sdram #(.CLK_MHZ(CLK_MHZ), .CAS_LATENCY(CAS_LATENCY), .ROW_BITS(ROW_BITS),
          .COL_BITS(COL_BITS), .MAX_BURST(MAX_BURST), .T_RCD_NS(T_RCD_NS),
          .T_RP_NS(T_RP_NS), .T_RC_NS(T_RC_NS), .T_RAS_NS(T_RAS_NS),
          .T_RRD_NS(T_RRD_NS), .T_WR_NS(T_WR_NS)) dut (
    .clk, .rst_n, .req_valid, .req_ready, .req_we, .req_addr, .req_len,
    .req_wdata, .req_wstrb, .wr_ready, .rsp_valid, .rsp_rdata, .init_done,
    .sdram_cke(cke), .sdram_csn(csn), .sdram_rasn(rasn), .sdram_casn(casn),
    .sdram_wen(wen), .sdram_a(a), .sdram_ba(ba), .sdram_dqm(dqm),
    .dq_o, .dq_oe, .dq_i(model_dq));

  // As on the board: the chip is clocked by the inverted controller clock.
  sdram_model #(.COL_BITS(COL_BITS), .T_RCD_NS(real'(T_RCD_NS)), .T_RP_NS(real'(T_RP_NS)),
                .T_RC_NS(real'(T_RC_NS)), .T_RAS_NS(real'(T_RAS_NS)),
                .T_RRD_NS(real'(T_RRD_NS)), .T_WR_NS(real'(T_WR_NS))) chip (
    .clk(~clk), .cke, .csn, .rasn, .casn, .wen, .a, .ba, .dqm,
    .dq_in(dq_o), .dq_in_en(dq_oe), .dq_out(model_dq), .dq_out_en(model_oe));

  // ---- Reference memory -------------------------------------------------------
  logic [31:0] ref_mem [int];
  int          errors, words_read, words_written, rsp_total;
  longint      cyc;

  always @(posedge clk) begin
    cyc++;
    if (rsp_valid) rsp_total++;
  end

  // What the chip holds for a word (fill pattern if never written).
  function automatic logic [31:0] chip_word(logic [ADDR_BITS-1:0] addr);
    bit [1:0]  b   = addr[COL_BITS-1 +: 2];
    bit [12:0] r   = 13'(addr[ADDR_BITS-1 -: ROW_BITS]);
    int        col = int'(addr[COL_BITS-2:0]) * 2;
    return {chip.peek(b, r, col + 1), chip.peek(b, r, col)};
  endfunction

  function automatic logic [31:0] expected(logic [ADDR_BITS-1:0] addr);
    return ref_mem.exists(int'(addr)) != 0 ? ref_mem[int'(addr)] : chip_word(addr);
  endfunction

  function automatic logic [ADDR_BITS-1:0] word_addr(int row, int bank, int col);
    return {ROW_BITS'(row), 2'(bank), (COL_BITS-1)'(col)};
  endfunction

  // ---- Requests -------------------------------------------------------------------
  // One request; returns the cycles from acceptance to the last word.
  task automatic burst(input bit we, input logic [ADDR_BITS-1:0] addr, input int n,
                       input logic [31:0] wd [$], input logic [3:0] ws [$],
                       output logic [31:0] rd [$], output longint cycles);
    longint start;
    int     k = 0;
    rd = {};
    @(negedge clk);
    req_valid = 1'b1;
    req_we    = we;
    req_addr  = addr;
    req_len   = LEN_BITS'(n - 1);
    req_wdata = $urandom;
    req_wstrb = 4'($urandom);
    do @(posedge clk); while (!req_ready);
    start = cyc;
    #0.1 req_valid = 1'b0;
    if (we) begin
      // Valid write data only in the cycles where wr_ready says the
      // controller takes it (sampled mid-cycle, taken at the next edge).
      while (k < n) begin
        @(negedge clk);
        if (wr_ready) begin
          req_wdata = wd[k];
          req_wstrb = ws[k];
          k++;
        end else begin
          req_wdata = $urandom;
          req_wstrb = 4'($urandom);
        end
      end
      @(posedge clk);
    end else begin
      while (rd.size() < n) begin
        @(negedge clk);
        if (rsp_valid) rd.push_back(rsp_rdata);
      end
    end
    cycles = cyc - start;
  endtask

  task automatic write(input logic [ADDR_BITS-1:0] addr, input logic [31:0] wd [$],
                       input logic [3:0] ws [$]);
    logic [31:0] rd [$];
    longint      c;
    foreach (wd[i]) begin
      logic [31:0] w = expected(addr + ADDR_BITS'(i));
      for (int j = 0; j < 4; j++) if (ws[i][j]) w[8*j +: 8] = wd[i][8*j +: 8];
      ref_mem[int'(addr) + i] = w;
    end
    burst(1'b1, addr, wd.size(), wd, ws, rd, c);
    words_written += wd.size();
  endtask

  task automatic check(input logic [ADDR_BITS-1:0] addr, input int n, output longint c);
    logic [31:0] rd [$], no_data [$];
    logic [3:0]  no_strb [$];
    burst(1'b0, addr, n, no_data, no_strb, rd, c);
    words_read += n;
    foreach (rd[i])
      if (rd[i] !== expected(addr + ADDR_BITS'(i))) begin
        $display("FAIL read 0x%0h (+%0d of %0d): got %08h, expected %08h",
                 addr, i, n, rd[i], expected(addr + ADDR_BITS'(i)));
        errors++;
      end
  endtask

  task automatic write1(input logic [ADDR_BITS-1:0] addr, input logic [31:0] d,
                        input logic [3:0] s = 4'hF);
    write(addr, {d}, {s});
  endtask

  task automatic check1(input logic [ADDR_BITS-1:0] addr);
    longint c;
    check(addr, 1, c);
  endtask

  // Random data and strobes for n words.
  function automatic void random_words(input int n, output logic [31:0] wd [$],
                                       output logic [3:0] ws [$]);
    wd = {};
    ws = {};
    repeat (n) begin
      wd.push_back($urandom);
      ws.push_back($urandom_range(3) == 0 ? 4'($urandom_range(1, 15)) : 4'hF);
    end
  endfunction

  // ---- Tests ----------------------------------------------------------------------
  initial begin
    logic [ADDR_BITS-1:0] addrs [$];
    logic [ADDR_BITS-1:0] max_addr;
    logic [31:0]          wd [$];
    logic [3:0]           ws [$];
    longint               c, c_hit, c_miss, c_one, c_stream;

    max_addr = '1;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    wait (init_done);
    if ($realtime < 200_000.0) begin
      $display("FAIL init_done after only %.0f ns", $realtime);
      errors++;
    end

    // Single words at the corners: first/last word, each bank, row boundary.
    addrs = '{0, 1, max_addr, max_addr - 1,
              word_addr(0, 1, 0), word_addr(0, 3, 0), word_addr(1, 0, 0),
              word_addr(0, 3, ROW_WORDS - 1)};
    foreach (addrs[i]) write1(addrs[i], 32'hC0DE_0000 + 32'(i));
    foreach (addrs[i]) check1(addrs[i]);

    // The address mapping as seen by the chip: word = {row, bank, column/2}.
    write1(word_addr(4097, 2, 77), 32'hAABB_CCDD);
    #1000;                                         // the write reaches the chip later
    if (chip.peek(2'd2, 13'd4097, 154) !== 16'hCCDD ||
        chip.peek(2'd2, 13'd4097, 155) !== 16'hAABB) begin
      $display("FAIL address mapping");
      errors++;
    end

    // Byte strobes.
    write1(5, 32'hFFFF_FFFF);
    write1(5, 32'h1122_3344, 4'b0101);
    check1(5);
    write1(5, 32'h5566_7788, 4'b1000);
    check1(5);

    // Full bursts: a line, the next line in the same row, the same line in
    // another row of the same bank (row miss), the last line of a row.
    random_words(MAX_BURST, wd, ws);
    write(word_addr(10, 1, 0), wd, ws);
    random_words(MAX_BURST, wd, ws);
    write(word_addr(10, 1, MAX_BURST), wd, ws);
    random_words(MAX_BURST, wd, ws);
    write(word_addr(11, 1, 0), wd, ws);
    random_words(MAX_BURST, wd, ws);
    write(word_addr(10, 1, ROW_WORDS - MAX_BURST), wd, ws);
    // (The last write left row 10 open in bank 1.)
    check(word_addr(11, 1, 0), MAX_BURST, c);
    check(word_addr(10, 1, 0), MAX_BURST, c_miss);      // row 11 was open: miss
    // Same row: hits. A refresh (which closes the row) can fall into at most
    // one of three back-to-back reads, so take the fastest.
    c_hit = 1000;
    c_one = 1000;
    repeat (3) begin
      check(word_addr(10, 1, MAX_BURST), MAX_BURST, c);
      if (c < c_hit) c_hit = c;
    end
    repeat (3) begin
      check(word_addr(10, 1, 3), 1, c);
      if (c < c_one) c_one = c;
    end
    check(word_addr(10, 1, ROW_WORDS - MAX_BURST), MAX_BURST, c);

    // Hits must not pay for PRECHARGE/ACTIVE.
    if (c_hit > hit_cycles(MAX_BURST) || c_one > hit_cycles(1)) begin
      $display("FAIL reads with the row open took %0d (%0d words) and %0d (1 word) cycles",
               c_hit, MAX_BURST, c_one);
      errors++;
    end
    if (c_miss <= c_hit) begin
      $display("FAIL row miss (%0d cycles) not slower than a hit (%0d)", c_miss, c_hit);
      errors++;
    end

    // A write issued while the previous read's data is still arriving (the
    // read is collected in parallel): the controller must not drive the bus
    // before the chip has stopped driving it. Row 10 is open: no ACTIVE delay.
    random_words(MAX_BURST, wd, ws);
    fork
      check(word_addr(10, 1, 0), MAX_BURST, c);
    join_none
    wait (req_valid === 1'b1);
    wait (req_valid === 1'b0);                         // read accepted
    write(word_addr(10, 1, 2 * MAX_BURST), wd, ws);
    wait fork;
    check(word_addr(10, 1, 2 * MAX_BURST), MAX_BURST, c);

    // Random traffic over a few rows of two banks: hits, misses, partial
    // bursts, byte strobes; long enough for many refresh intervals.
    for (int i = 0; i < 2000; i++) begin
      int row, bank, col, n;
      row  = $urandom_range(3) + (i % 2) * 4000;
      bank = $urandom_range(1);
      col  = $urandom_range(ROW_WORDS - 1);
      n    = $urandom_range(1, MAX_BURST);
      if (col + n > ROW_WORDS) n = ROW_WORDS - col;      // stay inside the row
      if ($urandom_range(1) == 0) begin
        random_words(n, wd, ws);
        write(word_addr(row, bank, col), wd, ws);
      end else begin
        check(word_addr(row, bank, col), n, c);
      end
    end

    // Streaming: 64 lines in a row, back to back.
    c_stream = 0;
    for (int i = 0; i < 64; i++) begin
      check(word_addr(20 + i / (ROW_WORDS / MAX_BURST), 2, (i * MAX_BURST) % ROW_WORDS),
            MAX_BURST, c);
      c_stream += c;
    end

    // Idle across several refresh intervals; the model checks the gaps.
    #50_000;
    foreach (ref_mem[k]) check1(ADDR_BITS'(k));

    repeat (2) @(posedge clk);                       // count the last rsp_valid
    if (rsp_total != words_read) begin
      $display("FAIL %0d read words returned, %0d requested", rsp_total, words_read);
      errors++;
    end
    $display("%0d words written, %0d read, %0d refreshes", words_written, words_read,
             chip.refreshes);
    $display("cycles: %0d-word read with the row open %0d, after a row miss %0d, single word %0d",
             MAX_BURST, c_hit, c_miss, c_one);
    $display("streaming line reads: %.1f cycles per line, %.1f MB/s",
             real'(c_stream) / 64, 64.0 * MAX_BURST * 4 * CLK_MHZ / real'(c_stream));
    if (errors != 0) $fatal(1, "%0d errors", errors);
    $display("PASS tb_sdram (CLK_MHZ=%0d CAS_LATENCY=%0d COL_BITS=%0d tRCD/RP/RC/RAS/RRD/WR=%0d/%0d/%0d/%0d/%0d/%0d ns)",
             CLK_MHZ, CAS_LATENCY, COL_BITS, T_RCD_NS, T_RP_NS, T_RC_NS, T_RAS_NS,
             T_RRD_NS, T_WR_NS);
    $finish;
  end

  initial begin
    #100_000_000;
    $fatal(1, "timeout");
  end
endmodule
