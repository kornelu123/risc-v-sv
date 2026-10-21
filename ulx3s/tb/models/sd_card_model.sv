// Behavioural SD card in SPI mode (mode 0) for simulation. It answers the
// commands sd_spi.sv uses and stops the simulation with $fatal when the host
// breaks the protocol: fewer than 74 init clocks, SCK above 400 kHz before
// the card is ready (25 MHz after), a bad CRC7 or end bit, commands in the
// wrong state, no gap byte before a write token, a bad write CRC16, CS raised
// mid-byte or with response bytes unread.
module sd_card_model #(
  parameter bit  SDHC        = 1'b1,  // block addressing (OCR.CCS)
  parameter bit  V2          = 1'b1,  // answers CMD8 (SD 2.0+)
  parameter int  ACMD41_BUSY = 3,     // ACMD41 answers "idle" this often; < 0: never ready
  parameter int  NCR         = 1,     // 0xFF bytes before a command response (1..8)
  parameter int  NAC         = 4,     // 0xFF bytes before a read start token
  parameter int  BUSY_BYTES  = 6,     // busy (0x00) bytes after a write
  parameter real INIT_MIN_PERIOD_NS = 2500.0,  // 400 kHz
  parameter real FAST_MIN_PERIOD_NS = 40.0     // 25 MHz
) (
  input  logic sck,
  input  logic mosi,
  input  logic cs_n,
  output logic miso
);
  // ---- State ------------------------------------------------------------------
  logic [7:0] mem [longint];          // byte address
  bit         spi_mode;               // CMD0 seen with CS low
  bit         ready;                  // ACMD41 finished
  bit         app_cmd;                // previous command was CMD55
  bit         blocklen_set;
  int         acmd41_count;
  int         pre_clocks;             // clocks with CS and MOSI high before CMD0
  real        t_last_rise = -1.0;

  typedef enum { RX_CMD, RX_WR_TOKEN, RX_WR_DATA } rx_t;
  rx_t        rx_state;
  logic [7:0] cmd [6];
  int         cmd_n;
  int         wr_frames;              // frames since the CMD24 response was queued
  longint     wr_addr;
  logic [7:0] wr_buf [514];
  int         wr_n;

  logic [7:0] tx_q [$];
  logic [7:0] rx_sh, tx_sh;
  int         bit_cnt;
  bit         load_next;
  logic       miso_r = 1'b1;

  // Statistics and error injection, used by the testbench (one-shot flags).
  int         reads, writes;
  bit         inject_read_token_error, inject_read_crc_error, inject_write_reject;
  bit         inject_read_no_token;      // R1, then 0xFF forever: host must time out
  bit         inject_write_stuck_busy;   // busy far longer than any host timeout
  bit         stuck_busy;                // the host may give up and raise CS

  assign miso = cs_n ? 1'b1 : miso_r;

  // Contents of never-written bytes.
  function automatic logic [7:0] fill(longint addr);
    return 8'(addr * 37 + (addr >> 9));
  endfunction

  function automatic logic [7:0] peek(longint addr);
    return mem.exists(addr) != 0 ? mem[addr] : fill(addr);
  endfunction

  function automatic void fail(string msg);
    $fatal(1, "sd_card_model @%0t: %s", $realtime, msg);
  endfunction

  function automatic void need(bit ok, string msg);
    if (!ok) fail(msg);
  endfunction

  function automatic logic [6:0] crc7(logic [39:0] d);
    logic [6:0] c = '0;
    for (int i = 39; i >= 0; i--) c = {c[5:0], 1'b0} ^ ((c[6] ^ d[i]) ? 7'h09 : 7'h00);
    return c;
  endfunction

  function automatic logic [15:0] crc16(logic [15:0] c, logic [7:0] d);
    for (int i = 7; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h1021 : 16'h0000);
    return c;
  endfunction

  function automatic void respond_r1(logic [7:0] r1);
    repeat (NCR) tx_q.push_back(8'hFF);
    tx_q.push_back(r1);
  endfunction

  function automatic longint data_addr(logic [31:0] arg);
    if (SDHC) return longint'(arg) * 512;
    need(blocklen_set, "data command before CMD16 on a standard-capacity card");
    need(arg[8:0] == 9'd0, "byte address not a multiple of 512");
    return longint'(arg);
  endfunction

  // ---- Commands -------------------------------------------------------------------
  function automatic void process_cmd();
    logic [5:0]  idx = cmd[0][5:0];
    logic [31:0] arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
    logic [7:0]  idle = {7'd0, !ready};

    need(cmd[5][0] == 1'b1, "command end bit is 0");
    need(cmd[5][7:1] == crc7({cmd[0], arg}),
         $sformatf("CMD%0d CRC7 %02h, expected %02h", idx, cmd[5][7:1], crc7({cmd[0], arg})));
    if (!spi_mode) begin
      need(idx == 6'd0, $sformatf("CMD%0d before CMD0", idx));
      need(pre_clocks >= 74, $sformatf("only %0d init clocks before CMD0", pre_clocks));
      spi_mode = 1'b1;
    end

    if (app_cmd && idx != 6'd41) app_cmd = 1'b0;
    case (idx)
      6'd0: begin
        ready = 1'b0;
        acmd41_count = 0;
        blocklen_set = 1'b0;
        respond_r1(8'h01);
      end
      6'd8: begin
        if (!V2) begin
          respond_r1(8'h05);                              // illegal command, idle
        end else begin
          need(arg[11:8] == 4'h1, "CMD8 voltage is not 2.7-3.6 V");
          respond_r1(idle);
          tx_q.push_back(8'h00);
          tx_q.push_back(8'h00);
          tx_q.push_back({4'h0, arg[11:8]});
          tx_q.push_back(arg[7:0]);
        end
      end
      6'd55: begin
        app_cmd = 1'b1;
        respond_r1(idle);
      end
      6'd41: begin
        need(app_cmd, "CMD41 without CMD55");
        app_cmd = 1'b0;
        if (ready) begin
          respond_r1(8'h00);
        end else if (ACMD41_BUSY < 0 || (SDHC && !arg[30]) ||
                     acmd41_count < ACMD41_BUSY) begin
          acmd41_count++;
          respond_r1(8'h01);
        end else begin
          ready = 1'b1;
          respond_r1(8'h00);
        end
      end
      6'd58: begin
        respond_r1(idle);
        tx_q.push_back({ready, SDHC && ready, 6'd0});      // power-up done, CCS
        tx_q.push_back(8'hFF);                             // 2.7-3.6 V
        tx_q.push_back(8'h80);
        tx_q.push_back(8'h00);
      end
      6'd16: begin
        need(ready, "CMD16 before initialisation");
        need(SDHC || arg == 32'd512, "block length other than 512");
        blocklen_set = 1'b1;
        respond_r1(8'h00);
      end
      6'd17: begin
        logic [15:0] crc = '0;
        longint      addr;
        need(ready, "CMD17 before initialisation");
        addr = data_addr(arg);
        respond_r1(8'h00);
        repeat (NAC) tx_q.push_back(8'hFF);
        if (inject_read_no_token) begin
          inject_read_no_token = 1'b0;
        end else if (inject_read_token_error) begin
          inject_read_token_error = 1'b0;
          tx_q.push_back(8'h08);                           // data error token: out of range
        end else begin
          tx_q.push_back(8'hFE);
          for (int i = 0; i < 512; i++) begin
            tx_q.push_back(peek(addr + longint'(i)));
            crc = crc16(crc, peek(addr + longint'(i)));
          end
          if (inject_read_crc_error) begin
            inject_read_crc_error = 1'b0;
            crc = ~crc;
          end
          tx_q.push_back(crc[15:8]);
          tx_q.push_back(crc[7:0]);
        end
        reads++;
      end
      6'd24: begin
        need(ready, "CMD24 before initialisation");
        wr_addr   = data_addr(arg);
        respond_r1(8'h00);
        wr_frames = 0;
        rx_state  = RX_WR_TOKEN;
      end
      default: respond_r1(8'h04 | idle);                   // illegal command
    endcase
  endfunction

  function automatic void process_write();
    logic [15:0] crc = '0;
    for (int i = 0; i < 512; i++) crc = crc16(crc, wr_buf[i]);
    need({wr_buf[512], wr_buf[513]} == crc, "write data CRC16 mismatch");
    if (inject_write_reject) begin
      inject_write_reject = 1'b0;
      tx_q.push_back(8'hED);                               // xxx0_110_1: write error
    end else begin
      for (int i = 0; i < 512; i++) mem[wr_addr + longint'(i)] = wr_buf[i];
      tx_q.push_back(8'hE5);                               // xxx0_010_1: accepted
      if (inject_write_stuck_busy) begin
        inject_write_stuck_busy = 1'b0;
        stuck_busy = 1'b1;
        repeat (100_000) tx_q.push_back(8'h00);
      end else begin
        repeat (BUSY_BYTES) tx_q.push_back(8'h00);
      end
      writes++;
    end
  endfunction

  function automatic void handle_byte(logic [7:0] b);
    case (rx_state)
      RX_CMD:
        if (cmd_n == 0) begin
          if (b[7:6] == 2'b01) begin
            need(tx_q.size() == 0, "new command while the previous response is unread");
            cmd[0] = b;
            cmd_n  = 1;
          end
        end else begin
          cmd[cmd_n] = b;
          cmd_n++;
          if (cmd_n == 6) begin
            cmd_n = 0;
            process_cmd();
          end
        end
      // Frames NCR+1 carry the R1, so the host may send the token from frame
      // NCR+3 on (at least one gap byte).
      RX_WR_TOKEN: begin
        wr_frames++;
        if (b == 8'hFE) begin
          need(wr_frames >= NCR + 3, "no 0xFF byte between R1 and the start token");
          wr_n     = 0;
          rx_state = RX_WR_DATA;
        end else begin
          need(b == 8'hFF, $sformatf("byte %02h while waiting for the start token", b));
        end
      end
      RX_WR_DATA: begin
        wr_buf[wr_n] = b;
        wr_n++;
        if (wr_n == 514) begin
          rx_state = RX_CMD;
          process_write();
        end
      end
      default: ;
    endcase
  endfunction

  function automatic logic [7:0] next_tx();
    return tx_q.size() != 0 ? tx_q.pop_front() : 8'hFF;
  endfunction

  // ---- SPI bit level ------------------------------------------------------------
  always @(posedge sck) begin
    real now;
    now = $realtime;
    if (t_last_rise >= 0.0)
      need(now - t_last_rise >= (ready ? FAST_MIN_PERIOD_NS : INIT_MIN_PERIOD_NS) * 0.999,
           $sformatf("SCK period %.1f ns too short", now - t_last_rise));
    t_last_rise = now;
    if (cs_n) begin
      if (!spi_mode && mosi) pre_clocks++;
    end else begin
      rx_sh = {rx_sh[6:0], mosi};
      bit_cnt++;
      if (bit_cnt == 8) begin
        bit_cnt   = 0;
        load_next = 1'b1;
        handle_byte(rx_sh);
      end
    end
  end

  always @(negedge sck) begin
    if (!cs_n) begin
      if (load_next) begin
        load_next = 1'b0;
        tx_sh = next_tx();
      end else begin
        tx_sh = {tx_sh[6:0], 1'b1};
      end
      miso_r = tx_sh[7];
    end
  end

  always @(negedge cs_n) begin
    need(!sck, "CS asserted with SCK high");
    bit_cnt   = 0;
    load_next = 1'b0;
    tx_sh     = next_tx();
    miso_r    = tx_sh[7];
  end

  always @(posedge cs_n) begin
    need(bit_cnt == 0, "CS raised in the middle of a byte");
    need(rx_state != RX_WR_DATA, "CS raised during write data");
    // After a stuck write the host may give up; the card then finishes in
    // the background (modelled by dropping the busy bytes).
    if (stuck_busy) begin
      stuck_busy = 1'b0;
      tx_q.delete();
    end
    need(tx_q.size() == 0, $sformatf("CS raised with %0d response bytes unread", tx_q.size()));
    rx_state = RX_CMD;
    cmd_n    = 0;
  end
endmodule
