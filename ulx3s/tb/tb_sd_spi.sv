// Self-checking testbench for sd_spi.sv against sd_card_model.sv. The model
// checks the SPI-mode protocol; this testbench checks data and error reporting.
//   CARD = 0: SDHC (block addressing), 1: SDSC v2, 2: SDSC v1 (no CMD8),
//          3: SDHC that never finishes ACMD41 (initialisation must fail).
module tb_sd_spi #(
  parameter int CARD = 0
);
  localparam int  CLK_HZ  = 50_000_000;
  localparam real PERIOD  = 1.0e9 / CLK_HZ;
  localparam bit  SDHC    = CARD == 0 || CARD == 3;
  localparam bit  V2      = CARD != 2;

  logic        clk = 1'b0, rst_n = 1'b0;
  logic        ready, init_error, sdhc, busy, done, error;
  logic        rd_start = 1'b0, wr_start = 1'b0, rd_valid, wr_valid = 1'b0, wr_ready;
  logic [31:0] block;
  logic [7:0]  rd_data, wr_data;
  logic        sck, mosi, miso, cs_n;

  always #(PERIOD / 2) clk = ~clk;

  // Short timeouts (1 ms = 1562 bytes at 12.5 MHz) so the timeout tests run quickly.
  sd_spi #(.CLK_HZ(CLK_HZ), .POWERUP_US(10), .ACMD41_TRIES(20),
           .READ_TIMEOUT_MS(1), .WRITE_TIMEOUT_MS(1)) dut (
    .clk, .rst_n, .ready, .init_error, .sdhc, .rd_start, .wr_start, .block,
    .busy, .done, .error, .rd_valid, .rd_data, .wr_valid, .wr_data, .wr_ready,
    .sd_sck(sck), .sd_mosi(mosi), .sd_cs_n(cs_n), .sd_miso(miso));

  sd_card_model #(.SDHC(SDHC), .V2(V2), .ACMD41_BUSY(CARD == 3 ? -1 : 5)) card (
    .sck, .mosi, .cs_n, .miso);

  int errors;

  // ---- Operations ---------------------------------------------------------------
  logic [7:0] rbuf [512];
  int         rcount;

  always @(posedge clk) if (rd_valid) begin
    if (rcount < 512) rbuf[rcount] = rd_data;
    rcount++;
  end

  task automatic read_block(input logic [31:0] b, output bit err);
    rcount = 0;
    @(negedge clk);
    block    = b;
    rd_start = 1'b1;
    @(negedge clk);
    rd_start = 1'b0;
    @(posedge done);
    @(negedge clk);
    err = error;
    if (!err && rcount != 512) begin
      $display("FAIL read %0d: %0d bytes", b, rcount);
      errors++;
    end
  endtask

  task automatic write_block(input logic [31:0] b, input logic [7:0] data [512], output bit err);
    int n = 0;
    @(negedge clk);
    block    = b;
    wr_start = 1'b1;
    @(negedge clk);
    wr_start = 1'b0;
    while (!done) begin
      wr_valid = n < 512 && $urandom_range(3) != 0;  // stall sometimes
      wr_data  = n < 512 ? data[n] : 8'hxx;
      @(posedge clk);
      if (wr_valid && wr_ready) n++;
      #0.1;
    end
    wr_valid = 1'b0;
    err = error;
    if (!err && n != 512) begin
      $display("FAIL write %0d: %0d bytes taken", b, n);
      errors++;
    end
  endtask

  // Byte address of a block on the card.
  function automatic longint addr_of(logic [31:0] b);
    return longint'(b) * 512;
  endfunction

  task automatic expect_card_block(input logic [31:0] b, input logic [7:0] data [512]);
    for (int i = 0; i < 512; i++)
      if (card.peek(addr_of(b) + longint'(i)) !== data[i]) begin
        $display("FAIL block %0d byte %0d on the card: %02h, expected %02h",
                 b, i, card.peek(addr_of(b) + longint'(i)), data[i]);
        errors++;
        return;
      end
  endtask

  task automatic expect_read(input logic [31:0] b, input logic [7:0] data [512]);
    bit err;
    read_block(b, err);
    if (err) begin
      $display("FAIL read %0d reported an error", b);
      errors++;
      return;
    end
    for (int i = 0; i < 512; i++)
      if (rbuf[i] !== data[i]) begin
        $display("FAIL read %0d byte %0d: %02h, expected %02h", b, i, rbuf[i], data[i]);
        errors++;
        return;
      end
  endtask

  function automatic void card_contents(input logic [31:0] b, output logic [7:0] data [512]);
    for (int i = 0; i < 512; i++) data[i] = card.peek(addr_of(b) + longint'(i));
  endfunction

  // ---- Tests ----------------------------------------------------------------------
  initial begin
    logic [7:0] d0 [512], d1 [512], d [512];
    bit err;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    wait (ready || init_error);

    if (CARD == 3) begin
      if (!init_error || ready) begin
        $display("FAIL a card that never leaves ACMD41 must fail initialisation");
        errors++;
      end
    end else begin
      if (init_error) $fatal(1, "initialisation failed");
      if (sdhc !== SDHC) begin
        $display("FAIL sdhc = %0d, expected %0d", sdhc, SDHC);
        errors++;
      end
      $display("initialised at %.2f ms, sdhc = %0d", $realtime / 1.0e6, sdhc);

      // Reads of never-written blocks return the card's contents.
      card_contents(0, d);
      expect_read(0, d);
      card_contents(12345, d);
      expect_read(12345, d);

      // Write two neighbouring blocks, check the card, read both back.
      foreach (d0[i]) d0[i] = 8'($urandom);
      foreach (d1[i]) d1[i] = 8'($urandom);
      write_block(77, d0, err);
      if (err) begin $display("FAIL write 77 reported an error"); errors++; end
      write_block(78, d1, err);
      if (err) begin $display("FAIL write 78 reported an error"); errors++; end
      expect_card_block(77, d0);
      expect_card_block(78, d1);
      expect_read(77, d0);
      expect_read(78, d1);

      // Errors are reported and the controller keeps working afterwards.
      card.inject_read_token_error = 1'b1;
      read_block(77, err);
      if (!err) begin $display("FAIL data error token not reported"); errors++; end
      card.inject_read_crc_error = 1'b1;
      read_block(77, err);
      if (!err) begin $display("FAIL read CRC16 mismatch not reported"); errors++; end
      card.inject_read_no_token = 1'b1;
      read_block(77, err);
      if (!err) begin $display("FAIL missing data token (timeout) not reported"); errors++; end
      card.inject_write_stuck_busy = 1'b1;
      write_block(79, d0, err);
      if (!err) begin $display("FAIL write busy timeout not reported"); errors++; end
      expect_read(77, d0);
      card.inject_write_reject = 1'b1;
      write_block(77, d1, err);
      if (!err) begin $display("FAIL rejected write not reported"); errors++; end
      expect_card_block(77, d0);
      write_block(77, d1, err);
      if (err) begin $display("FAIL write after a rejected write"); errors++; end
      expect_read(77, d1);

      $display("%0d reads, %0d writes on the card", card.reads, card.writes);
    end

    if (errors != 0) $fatal(1, "%0d errors", errors);
    $display("PASS tb_sd_spi (CARD=%0d)", CARD);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "timeout");
  end
endmodule
