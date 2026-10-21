// SD card controller in SPI mode (ULX3S: sd_clk = SCK, sd_cmd = MOSI,
// sd_d[0] = MISO, sd_d[3] = CS#).
//
// After reset it initialises the card on its own at INIT_HZ: >= 74 clocks,
// CMD0, CMD8 (v1/v2 detection), CMD55 + ACMD41 until ready, CMD58 (block or
// byte addressing), CMD16(512) for byte-addressed cards, then switches SCK to
// FAST_HZ and raises `ready` (or `init_error`).
//
// Block access, 512 bytes, one at a time:
//   read:  pulse rd_start with `block`; the bytes arrive on rd_data/rd_valid.
//   write: pulse wr_start with `block`; supply 512 bytes on wr_data/wr_valid
//          when wr_ready is high (valid/ready handshake).
// `done` pulses at the end with `error` set if the card rejected the command,
// timed out, signalled an error, or (reads) the data CRC16 did not match.
// `block` is a block number for every card type (converted to a byte address
// for standard-capacity cards).
module sd_spi #(
  parameter int CLK_HZ           = 50_000_000,
  parameter int INIT_HZ          = 400_000,
  parameter int FAST_HZ          = 12_500_000,
  parameter int POWERUP_US       = 1000,    // wait before the first clocks
  parameter int ACMD41_TRIES     = 2500,    // about 1 s at 400 kHz
  parameter int CMD0_TRIES       = 16,
  parameter int READ_TIMEOUT_MS  = 100,
  parameter int WRITE_TIMEOUT_MS = 500
) (
  input  logic        clk,
  input  logic        rst_n,

  output logic        ready,       // initialised; accepts rd_start/wr_start
  output logic        init_error,  // initialisation failed (until reset)
  output logic        sdhc,        // block-addressed card (SDHC/SDXC)

  input  logic        rd_start,
  input  logic        wr_start,
  input  logic [31:0] block,
  output logic        busy,
  output logic        done,        // pulse: operation finished ...
  output logic        error,       // ... and failed

  output logic        rd_valid,
  output logic [7:0]  rd_data,
  input  logic        wr_valid,
  input  logic [7:0]  wr_data,
  output logic        wr_ready,

  output logic        sd_sck,
  output logic        sd_mosi,
  output logic        sd_cs_n,
  input  logic        sd_miso
);
  // ---- Derived constants ------------------------------------------------------
  // (Functions assign their result to their own name: yosys' SystemVerilog
  // frontend does not support `return`.)
  function automatic int max2(int a, int b);
    max2 = a > b ? a : b;
  endfunction

  // SCK half-period in clk cycles, rounded up so SCK never exceeds the target.
  localparam int INIT_DIV      = max2(1, (CLK_HZ + 2 * INIT_HZ - 1) / (2 * INIT_HZ));
  localparam int FAST_DIV      = max2(1, (CLK_HZ + 2 * FAST_HZ - 1) / (2 * FAST_HZ));
  localparam int BYTES_PER_MS  = max2(1, CLK_HZ / (2 * FAST_DIV) / 8 / 1000);
  localparam int READ_TIMEOUT  = READ_TIMEOUT_MS * BYTES_PER_MS;
  localparam int WRITE_TIMEOUT = WRITE_TIMEOUT_MS * BYTES_PER_MS;
  localparam int POWERUP       = max2(1, POWERUP_US * (CLK_HZ / 1_000_000));
  localparam int DW            = $clog2(INIT_DIV + 1);
  localparam int TW            = $clog2(max2(max2(POWERUP, WRITE_TIMEOUT),
                                             max2(READ_TIMEOUT, ACMD41_TRIES)) + 1);

  // ---- CRCs ---------------------------------------------------------------------
  function automatic logic [6:0] crc7(logic [39:0] d);
    crc7 = '0;
    for (int i = 39; i >= 0; i--)
      crc7 = {crc7[5:0], 1'b0} ^ ((crc7[6] ^ d[i]) ? 7'h09 : 7'h00);
  endfunction

  function automatic logic [15:0] crc16(logic [15:0] c, logic [7:0] d);
    crc16 = c;
    for (int i = 7; i >= 0; i--)
      crc16 = {crc16[14:0], 1'b0} ^ ((crc16[15] ^ d[i]) ? 16'h1021 : 16'h0000);
  endfunction

  // ---- Byte shifter (SPI mode 0, MSB first) -------------------------------------
  // MOSI changes while SCK is low; MISO is sampled on the rising SCK edge.
  logic          fast;
  logic          xfer_start, xfer_busy, xfer_done;
  logic [7:0]    xfer_tx, xfer_rx, tx_sh, rx_sh;
  logic [2:0]    bitn;
  logic [DW-1:0] div_cnt, div;

  assign div = fast ? DW'(FAST_DIV - 1) : DW'(INIT_DIV - 1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      xfer_busy <= 1'b0;
      xfer_done <= 1'b0;
      sd_sck    <= 1'b0;
      sd_mosi   <= 1'b1;
    end else begin
      xfer_done <= 1'b0;
      if (!xfer_busy) begin
        if (xfer_start) begin
          xfer_busy <= 1'b1;
          sd_mosi   <= xfer_tx[7];
          tx_sh     <= {xfer_tx[6:0], 1'b1};
          bitn      <= '0;
          div_cnt   <= div;
        end
      end else if (div_cnt != 0) begin
        div_cnt <= div_cnt - 1'b1;
      end else begin
        div_cnt <= div;
        if (!sd_sck) begin
          sd_sck <= 1'b1;
          rx_sh  <= {rx_sh[6:0], sd_miso};
        end else begin
          sd_sck <= 1'b0;
          if (bitn == 3'd7) begin
            xfer_busy <= 1'b0;
            xfer_done <= 1'b1;
            xfer_rx   <= rx_sh;
            sd_mosi   <= 1'b1;            // idle high
          end else begin
            sd_mosi <= tx_sh[7];
            tx_sh   <= {tx_sh[6:0], 1'b1};
            bitn    <= bitn + 1'b1;
          end
        end
      end
    end
  end

  // ---- Protocol state machine -------------------------------------------------------
  typedef enum logic [5:0] {
    S_POWERUP, S_CLOCKS,
    S_CMD_PRE, S_CMD_FRAME, S_CMD_R1, S_CMD_EXTRA,   // command subroutine
    S_DESELECT,
    S_CMD0, S_CMD0_CHK, S_CMD8, S_CMD8_CHK, S_CMD55, S_CMD55_CHK, S_ACMD41,
    S_ACMD41_CHK, S_CMD58, S_CMD58_CHK, S_CMD16, S_CMD16_CHK, S_INIT_DONE,
    S_INIT_FAIL, S_IDLE,
    S_RD_R1, S_RD_TOKEN, S_RD_DATA, S_RD_CRC,
    S_WR_R1, S_WR_GAP, S_WR_TOKEN, S_WR_DATA, S_WR_CRC, S_WR_RESP, S_WR_BUSY,
    S_OP_DONE
  } state_t;

  state_t        state, ret, after_deselect;
  logic          pending;             // a byte transfer started by this FSM
  logic [9:0]    cnt;
  logic [TW-1:0] timer;
  logic [7:0]    tries;
  logic          v2;                  // card answered CMD8
  logic          op_error;

  logic [5:0]    cmd_index;
  logic [31:0]   cmd_arg;
  logic [6:0]    cmd_crc;
  logic          cmd_extra;           // R3/R7: 4 bytes after R1
  logic          r1_ok;
  logic [7:0]    r1;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0]   resp;                // R3 (OCR) / R7 bytes; not every field is used
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0]   crc;
  logic [7:0]    crc_hi;              // first CRC16 byte of a read block
  logic [7:0]    wr_byte;

  // The byte the FSM sends in its current state.
  logic [7:0] tx_byte;
  always_comb begin
    tx_byte = 8'hFF;
    case (state)
      S_CMD_FRAME: case (cnt[2:0])
        3'd0:    tx_byte = {2'b01, cmd_index};
        3'd1:    tx_byte = cmd_arg[31:24];
        3'd2:    tx_byte = cmd_arg[23:16];
        3'd3:    tx_byte = cmd_arg[15:8];
        3'd4:    tx_byte = cmd_arg[7:0];
        default: tx_byte = {cmd_crc, 1'b1};
      endcase
      S_WR_TOKEN: tx_byte = 8'hFE;
      S_WR_DATA:  tx_byte = wr_byte;
      S_WR_CRC:   tx_byte = cnt[0] ? crc[7:0] : crc[15:8];
      default:    ;
    endcase
  end

  // States that move one byte at a time: the FSM starts a transfer of tx_byte
  // and acts on xfer_done. (A case, not `inside`, for yosys.)
  logic byte_state;
  always_comb begin
    case (state)
      S_CLOCKS, S_CMD_PRE, S_CMD_FRAME, S_CMD_R1, S_CMD_EXTRA, S_DESELECT,
      S_RD_TOKEN, S_RD_DATA, S_RD_CRC, S_WR_GAP, S_WR_TOKEN, S_WR_CRC,
      S_WR_RESP, S_WR_BUSY: byte_state = 1'b1;
      default:              byte_state = 1'b0;
    endcase
  end

  assign busy     = state != S_IDLE;
  assign wr_ready = state == S_WR_DATA && !pending && !xfer_start;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state      <= S_POWERUP;
      sd_cs_n    <= 1'b1;
      fast       <= 1'b0;
      ready      <= 1'b0;
      init_error <= 1'b0;
      sdhc       <= 1'b0;
      pending    <= 1'b0;
      xfer_start <= 1'b0;
      timer      <= '0;
      cnt        <= '0;
      done       <= 1'b0;
      error      <= 1'b0;
      rd_valid   <= 1'b0;
    end else begin
      xfer_start <= 1'b0;
      done       <= 1'b0;
      rd_valid   <= 1'b0;

      // Byte-level states: start a transfer, then handle its result.
      if (byte_state) begin
        if (!pending) begin
          xfer_tx    <= tx_byte;
          xfer_start <= 1'b1;
          pending    <= 1'b1;
        end
      end

      if (state == S_WR_DATA && wr_ready && wr_valid) begin
        wr_byte    <= wr_data;
        xfer_tx    <= wr_data;
        xfer_start <= 1'b1;
        pending    <= 1'b1;
        crc        <= crc16(crc, wr_data);
      end

      if (xfer_done) pending <= 1'b0;

      case (state)
        S_POWERUP: begin
          timer <= timer + 1'b1;
          if (timer == TW'(POWERUP - 1)) begin
            cnt   <= '0;
            state <= S_CLOCKS;
          end
        end

        // >= 74 clocks with CS high (10 bytes = 80).
        S_CLOCKS: if (xfer_done) begin
          cnt <= cnt + 1'b1;
          if (cnt == 10'd9) begin
            tries <= 8'(CMD0_TRIES);
            state <= S_CMD0;
          end
        end

        // ---- Command subroutine: 0xFF, 6-byte frame, R1 (up to 8 bytes),
        // optional 4 response bytes; then continue at `ret` with CS still low.
        S_CMD_PRE: if (xfer_done) begin
          cnt   <= '0;
          state <= S_CMD_FRAME;
        end
        S_CMD_FRAME: if (xfer_done) begin
          cnt <= cnt + 1'b1;
          if (cnt == 10'd5) begin
            cnt   <= '0;
            state <= S_CMD_R1;
          end
        end
        S_CMD_R1: if (xfer_done) begin
          cnt <= cnt + 1'b1;
          if (!xfer_rx[7]) begin
            r1    <= xfer_rx;
            r1_ok <= 1'b1;
            cnt   <= '0;
            state <= cmd_extra ? S_CMD_EXTRA : ret;
          end else if (cnt == 10'd7) begin
            r1_ok <= 1'b0;                           // no response
            state <= ret;
          end
        end
        S_CMD_EXTRA: if (xfer_done) begin
          resp <= {resp[23:0], xfer_rx};
          cnt  <= cnt + 1'b1;
          if (cnt == 10'd3) state <= ret;
        end

        // CS high and one more byte of clocks, then `after_deselect`.
        S_DESELECT: if (xfer_done) state <= after_deselect;

        // ---- Initialisation -------------------------------------------------
        S_CMD0:   issue(6'd0, 32'h0, 1'b0, S_CMD0_CHK);
        S_CMD0_CHK:
          if (r1_ok && r1 == 8'h01)  deselect(S_CMD8);
          else if (tries != 0)        begin tries <= tries - 1'b1; deselect(S_CMD0); end
          else                        fail_init();
        S_CMD8:   issue(6'd8, 32'h0000_01AA, 1'b1, S_CMD8_CHK);
        S_CMD8_CHK:
          if (r1_ok && r1 == 8'h01 && resp[11:0] == 12'h1AA) begin
            v2 <= 1'b1;
            timer <= TW'(ACMD41_TRIES);
            deselect(S_CMD55);
          end else if (r1_ok && r1[2]) begin         // illegal command: SD v1
            v2 <= 1'b0;
            timer <= TW'(ACMD41_TRIES);
            deselect(S_CMD55);
          end else begin
            fail_init();
          end
        S_CMD55:  issue(6'd55, 32'h0, 1'b0, S_CMD55_CHK);
        S_CMD55_CHK:
          if (r1_ok && r1[7:1] == 7'd0) deselect(S_ACMD41);
          else                          fail_init();
        S_ACMD41: issue(6'd41, v2 ? 32'h4000_0000 : 32'h0, 1'b0, S_ACMD41_CHK);  // HCS
        S_ACMD41_CHK:
          if (r1_ok && r1 == 8'h00)                     deselect(v2 ? S_CMD58 : S_CMD16);
          else if (r1_ok && r1 == 8'h01 && timer != 0) begin
            timer <= timer - 1'b1;
            deselect(S_CMD55);
          end else                                      fail_init();
        S_CMD58:  issue(6'd58, 32'h0, 1'b1, S_CMD58_CHK);
        S_CMD58_CHK:
          // OCR: bit 31 = power-up done (CCS is only valid then), bit 30 = CCS.
          if (r1_ok && r1 == 8'h00 && resp[31]) begin
            sdhc <= resp[30];
            deselect(resp[30] ? S_INIT_DONE : S_CMD16);
          end else begin
            fail_init();
          end
        S_CMD16:  issue(6'd16, 32'd512, 1'b0, S_CMD16_CHK);
        S_CMD16_CHK:
          if (r1_ok && r1 == 8'h00) deselect(S_INIT_DONE);
          else                      fail_init();
        S_INIT_DONE: begin
          fast  <= 1'b1;
          ready <= 1'b1;
          state <= S_IDLE;
        end
        S_INIT_FAIL: ;

        // ---- Block operations -----------------------------------------------
        S_IDLE: begin
          op_error <= 1'b0;
          if (rd_start)      issue(6'd17, sdhc ? block : block << 9, 1'b0, S_RD_R1);
          else if (wr_start) issue(6'd24, sdhc ? block : block << 9, 1'b0, S_WR_R1);
        end

        S_RD_R1:
          if (r1_ok && r1 == 8'h00) begin
            timer <= '0;
            state <= S_RD_TOKEN;
          end else begin
            finish(1'b1);
          end
        S_RD_TOKEN: if (xfer_done) begin
          timer <= timer + 1'b1;
          if (xfer_rx == 8'hFE) begin                 // start block token
            cnt   <= '0;
            crc   <= '0;
            state <= S_RD_DATA;
          end else if (xfer_rx != 8'hFF || timer == TW'(READ_TIMEOUT)) begin
            finish(1'b1);                             // data error token / timeout
          end
        end
        S_RD_DATA: if (xfer_done) begin
          rd_data  <= xfer_rx;
          rd_valid <= 1'b1;
          crc      <= crc16(crc, xfer_rx);
          cnt      <= cnt + 1'b1;
          if (cnt == 10'd511) begin
            cnt   <= '0;
            state <= S_RD_CRC;
          end
        end
        S_RD_CRC: if (xfer_done) begin
          crc_hi <= xfer_rx;
          cnt    <= cnt + 1'b1;
          if (cnt == 10'd1) finish({crc_hi, xfer_rx} != crc);
        end

        // At least one 0xFF byte between R1 and the start token.
        S_WR_R1:
          if (r1_ok && r1 == 8'h00) state <= S_WR_GAP;
          else                      finish(1'b1);
        S_WR_GAP: if (xfer_done) state <= S_WR_TOKEN;
        S_WR_TOKEN: if (xfer_done) begin
          cnt   <= '0;
          crc   <= '0;
          state <= S_WR_DATA;
        end
        S_WR_DATA: if (xfer_done) begin
          cnt <= cnt + 1'b1;
          if (cnt == 10'd511) begin
            cnt   <= '0;
            state <= S_WR_CRC;
          end
        end
        S_WR_CRC: if (xfer_done) begin
          cnt <= cnt + 1'b1;
          if (cnt == 10'd1) begin
            cnt   <= '0;
            state <= S_WR_RESP;
          end
        end
        // Data response token xxx0sss1: 010 = accepted.
        S_WR_RESP: if (xfer_done) begin
          cnt <= cnt + 1'b1;
          if (xfer_rx != 8'hFF) begin
            if (xfer_rx[4:0] == 5'b00101) begin
              timer <= '0;
              state <= S_WR_BUSY;
            end else begin
              finish(1'b1);
            end
          end else if (cnt == 10'd7) begin
            finish(1'b1);
          end
        end
        // The card holds MISO low while it programs the block.
        S_WR_BUSY: if (xfer_done) begin
          timer <= timer + 1'b1;
          if (xfer_rx == 8'hFF)                     finish(1'b0);
          else if (timer == TW'(WRITE_TIMEOUT))     finish(1'b1);
        end

        S_OP_DONE: begin
          done  <= 1'b1;
          error <= op_error;
          state <= S_IDLE;
        end

        default: state <= S_POWERUP;
      endcase
    end
  end

  // Start a command; continue at `next` after its response, CS still low.
  task automatic issue(input logic [5:0] index, input logic [31:0] arg,
                       input logic extra, input state_t next);
    cmd_index <= index;
    cmd_arg   <= arg;
    cmd_crc   <= crc7({2'b01, index, arg});
    cmd_extra <= extra;
    ret       <= next;
    sd_cs_n   <= 1'b0;
    state     <= S_CMD_PRE;
  endtask

  // Raise CS, clock one more byte, then continue at `next`.
  task automatic deselect(input state_t next);
    sd_cs_n        <= 1'b1;
    after_deselect <= next;
    state          <= S_DESELECT;
  endtask

  task automatic fail_init();
    sd_cs_n    <= 1'b1;
    init_error <= 1'b1;
    state      <= S_INIT_FAIL;
  endtask

  // End a block operation: deselect, then pulse done/error.
  task automatic finish(input logic err);
    op_error <= err;
    deselect(S_OP_DONE);
  endtask
endmodule
