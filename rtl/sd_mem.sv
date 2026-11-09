// Main memory stored on the SD card, with the SDRAM as a cache of it.
//
// Main memory (memmap::MEM_BYTES) is the card's first MEM_BYTES bytes: byte k
// of memory is byte k of the card. The SDRAM holds 512-byte blocks of it,
// direct-mapped: block b sits in SDRAM slot b mod SLOTS, and a tag per slot
// (on-chip, synchronous read) says which block is there and whether it was
// written. A request for a block that is in the SDRAM goes straight to the
// SDRAM controller. Otherwise the slot's dirty block is first written to the
// card, then the requested block is read from the card into the slot, and
// the request continues as a hit. The two transfers go through a 512-byte
// buffer: SDRAM <-> buffer in bursts, buffer <-> card one block at a time via
// ulx3s/rtl/sd_spi.sv. A miss costs one or two card blocks, about 0.35 ms
// each at 12.5 MHz SCK.
//
// Written data reaches the card when its block is evicted, or on FLUSH. Data
// that is only in the SDRAM (or the core's data cache) is lost when power
// goes. Software syncs with FENCE.I (which writes back this core's data
// cache), then FLUSH, then waits until STATUS.BUSY falls.
//
// Registers (word offsets in the register window):
//   0  STATUS  read-only: bit 0 READY (card initialised, tags cleared),
//              1 BUSY (flush in progress), 2 ERROR (some card transfer failed,
//              sticky until reset), 3 INIT_ERROR (no usable card), 4 SDHC
//   1  FLUSH   write anything: write every dirty block to the card
// Other words read as 0 and ignore writes.
//
// Without a usable card (INIT_ERROR), misses skip the card and leave the
// slot's contents undefined, and ERROR is set. After reset nothing is
// served until the tags are cleared (SLOTS cycles) and, for a miss, until
// the card is initialised.
module sd_mem import memmap::*; #(
  parameter int CLK_HZ          = 50_000_000,
  parameter int SDRAM_BYTES     = 32 * 1024 * 1024,
  localparam int MEM_WORD_BITS   = $clog2(MEM_BYTES / 4),
  localparam int SDRAM_WORD_BITS = $clog2(SDRAM_BYTES / 4),
  localparam int SLOT_BITS       = SDRAM_WORD_BITS - 7,     // 128 words per block
  localparam int TAG_BITS        = MEM_WORD_BITS - SDRAM_WORD_BITS
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // Main memory: the request interface of ulx3s/rtl/sdram.sv, word offsets
  // from MEM_BASE. A burst stays inside one block (aligned cache lines do).
  input  logic                       req_valid,
  output logic                       req_ready,
  input  logic                       req_we,
  input  logic [MEM_WORD_BITS-1:0]   req_addr,
  input  logic [2:0]                 req_len,
  input  logic [31:0]                req_wdata,
  input  logic [3:0]                 req_wstrb,
  output logic                       wr_ready,
  output logic                       rsp_valid,
  output logic [31:0]                rsp_rdata,

  // Registers: `sel` for one cycle per access; `rdata` valid in that cycle.
  input  logic                       sel,
  input  logic                       we,
  input  logic [9:0]                 addr,
  output logic [31:0]                rdata,
  output logic                       ready,

  // The SDRAM controller.
  output logic                       dr_req_valid,
  input  logic                       dr_req_ready,
  output logic                       dr_req_we,
  output logic [SDRAM_WORD_BITS-1:0] dr_req_addr,
  output logic [2:0]                 dr_req_len,
  output logic [31:0]                dr_req_wdata,
  output logic [3:0]                 dr_req_wstrb,
  input  logic                       dr_wr_ready,
  input  logic                       dr_rsp_valid,
  input  logic [31:0]                dr_rsp_rdata,

  output logic                       sd_sck,
  output logic                       sd_mosi,
  output logic                       sd_cs_n,
  input  logic                       sd_miso
);
  initial if (TAG_BITS < 1) $fatal(1, "sd_mem: main memory must be larger than the SDRAM");

  localparam int SLOTS = 1 << SLOT_BITS;

  typedef logic [SLOT_BITS-1:0] slot_t;
  typedef logic [TAG_BITS-1:0]  tag_t;

  typedef enum logic [3:0] {
    CLEAR,        // after reset: invalidate every slot
    IDLE,
    LOOKUP,       // the request's tag entry is read
    PASS,         // a hit: the request goes to the SDRAM
    WB_LOAD,      // dirty block: SDRAM -> buffer
    WB_CARD,      //              buffer -> card
    FILL_CARD,    // missing block: card -> buffer
    FILL_STORE,   //                buffer -> SDRAM
    FLUSH_SCAN,   // flush: read the next slot's tag entry
    FLUSH_CHECK   //        write the slot back if it is dirty
  } state_t;

  state_t                state;
  logic [TAG_BITS+1:0]   tags [SLOTS];   // {valid, dirty, tag}
  logic [TAG_BITS+1:0]   ent;            // tags[rd_slot] of the previous cycle
  slot_t                 rd_slot, clr, scan;
  slot_t                 slot;           // the block being moved
  tag_t                  old_tag, new_tag;
  logic                  flushing;       // the write-back is part of a flush
  logic                  flush_req, err_q;
  logic [SLOT_BITS:0]    dirty_n;        // dirty slots
  logic                  accepted;       // PASS: the SDRAM took the request
  logic [3:0]            left;           // PASS: words still to move
  logic [31:0]           buf_q [128];
  logic [6:0]            bw;             // buffer word of the SDRAM transfer
  logic                  sent;           // its burst was accepted
  logic                  card_started;
  logic [9:0]            cnt;            // bytes moved to/from the card

  slot_t                 up_slot;
  tag_t                  up_tag;
  logic                  ent_valid, ent_dirty;
  tag_t                  ent_tag;
  logic                  hit, card_ok, beat;

  logic                  card_ready, init_error, sdhc, done, error;
  logic                  rd_start, wr_start, rd_valid, wr_valid, wr_ready_card;
  logic [7:0]            rd_data, wr_data;
  logic [31:0]           block;
  logic [31:0]           fill_word;

  assign up_slot   = req_addr[7 +: SLOT_BITS];
  assign up_tag    = req_addr[MEM_WORD_BITS-1 -: TAG_BITS];
  assign {ent_valid, ent_dirty, ent_tag} = ent;
  assign hit       = ent_valid && ent_tag == up_tag;
  assign card_ok   = card_ready || init_error;
  assign rd_slot   = state == FLUSH_SCAN ? scan : up_slot;
  assign ready     = card_ready && state != CLEAR;

  // ---- The card -----------------------------------------------------------------
  assign block    = 32'({state == WB_CARD ? old_tag : new_tag, slot});
  assign wr_start = state == WB_CARD   && !card_started && card_ready;
  assign rd_start = state == FILL_CARD && !card_started && card_ready;
  assign wr_valid = state == WB_CARD   &&  card_started && !cnt[9];
  assign wr_data  = buf_q[cnt[8:2]][8 * cnt[1:0] +: 8];

  sd_spi #(.CLK_HZ(CLK_HZ)) card(
    .clk, .rst_n,
    .ready(card_ready), .init_error, .sdhc,
    .rd_start, .wr_start, .block,
    // verilator lint_off PINCONNECTEMPTY
    .busy(),
    // verilator lint_on PINCONNECTEMPTY
    .done, .error,
    .rd_valid, .rd_data,
    .wr_valid, .wr_data, .wr_ready(wr_ready_card),
    .sd_sck, .sd_mosi, .sd_cs_n, .sd_miso);

  always_comb begin
    fill_word = buf_q[cnt[8:2]];
    fill_word[8 * cnt[1:0] +: 8] = rd_data;
  end

  // ---- SDRAM and the requester ----------------------------------------------------
  always_comb begin
    dr_req_valid = 1'b0;
    dr_req_we    = 1'b0;
    dr_req_addr  = {slot, bw[6:3], 3'd0};
    dr_req_len   = 3'd7;
    dr_req_wdata = buf_q[bw];
    dr_req_wstrb = 4'hF;
    req_ready    = 1'b0;
    wr_ready     = 1'b0;
    rsp_valid    = 1'b0;
    rsp_rdata    = dr_rsp_rdata;
    case (state)
      PASS: begin
        dr_req_valid = req_valid && !accepted;
        dr_req_we    = req_we;
        dr_req_addr  = {up_slot, req_addr[6:0]};
        dr_req_len   = req_len;
        dr_req_wdata = req_wdata;
        dr_req_wstrb = req_wstrb;
        req_ready    = !accepted && dr_req_ready;
        wr_ready     = dr_wr_ready;
        rsp_valid    = dr_rsp_valid;
      end
      WB_LOAD:    dr_req_valid = !sent;
      FILL_STORE: begin
        dr_req_valid = !sent;
        dr_req_we    = 1'b1;
      end
      default: ;
    endcase
  end
  assign beat = dr_req_we ? dr_wr_ready : dr_rsp_valid;

  // ---- Registers -------------------------------------------------------------------
  always_comb begin
    case (addr)
      10'd0:   rdata = {27'd0, sdhc, init_error, err_q, flush_req, ready};
      default: rdata = 32'd0;
    endcase
  end

  // ---- Control -----------------------------------------------------------------------
  always_ff @(posedge clk) ent <= tags[rd_slot];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= CLEAR;
      clr       <= '0;
      scan      <= '0;
      dirty_n   <= '0;
      flush_req <= 1'b0;
      err_q     <= 1'b0;
    end else begin
      if (sel && we && addr == 10'd1) flush_req <= 1'b1;

      case (state)
        CLEAR: begin
          tags[clr] <= '0;
          clr <= clr + 1'b1;
          if (clr == slot_t'(SLOTS - 1)) state <= IDLE;
        end

        IDLE:
          if (flush_req)      state <= FLUSH_SCAN;
          else if (req_valid) state <= LOOKUP;

        LOOKUP:
          if (hit) begin
            accepted <= 1'b0;
            state    <= PASS;
          end else if (card_ok) begin
            slot     <= up_slot;
            old_tag  <= ent_tag;
            new_tag  <= up_tag;
            flushing <= 1'b0;
            bw       <= '0;
            sent     <= 1'b0;
            card_started <= 1'b0;
            state    <= ent_dirty ? WB_LOAD : FILL_CARD;
          end

        PASS: begin
          if (dr_req_valid && dr_req_ready) begin
            accepted <= 1'b1;
            left     <= {1'b0, req_len} + 4'd1;
            if (req_we) begin
              tags[up_slot] <= {1'b1, 1'b1, up_tag};
              if (!ent_dirty) dirty_n <= dirty_n + 1'b1;
            end
          end
          assert (!(beat && !accepted)) else $error("sd_mem: data before the request was taken");
          if (accepted && beat) begin
            left <= left - 4'd1;
            if (left == 4'd1) state <= IDLE;
          end
        end

        WB_LOAD: begin
          if (dr_req_valid && dr_req_ready) sent <= 1'b1;
          if (dr_rsp_valid) begin
            buf_q[bw] <= dr_rsp_rdata;
            bw <= bw + 1'b1;
            if (bw[2:0] == 3'd7) sent <= 1'b0;
            if (bw == 7'd127) begin
              card_started <= 1'b0;
              state <= WB_CARD;
            end
          end
        end

        WB_CARD: begin
          if (wr_start) begin
            card_started <= 1'b1;
            cnt <= '0;
          end
          if (wr_valid && wr_ready_card) cnt <= cnt + 1'b1;
          if ((card_started && done) || init_error) begin
            if (error || init_error) err_q <= 1'b1;
            tags[slot]   <= {1'b1, 1'b0, old_tag};
            dirty_n      <= dirty_n - 1'b1;
            card_started <= 1'b0;
            state        <= flushing ? FLUSH_SCAN : FILL_CARD;
          end
        end

        FILL_CARD: begin
          if (rd_start) begin
            card_started <= 1'b1;
            cnt <= '0;
          end
          if (rd_valid) begin
            buf_q[cnt[8:2]] <= fill_word;
            cnt <= cnt + 1'b1;
          end
          if ((card_started && done) || init_error) begin
            if (error || init_error) err_q <= 1'b1;
            tags[slot] <= '0;               // the slot's data changes now
            bw    <= '0;
            sent  <= 1'b0;
            state <= FILL_STORE;
          end
        end

        FILL_STORE: begin
          if (dr_req_valid && dr_req_ready) sent <= 1'b1;
          if (dr_wr_ready) begin
            bw <= bw + 1'b1;
            if (bw[2:0] == 3'd7) sent <= 1'b0;
            if (bw == 7'd127) begin
              tags[slot] <= {1'b1, 1'b0, new_tag};
              state <= IDLE;
            end
          end
        end

        FLUSH_SCAN:
          if (dirty_n == '0) begin
            flush_req <= 1'b0;
            state     <= IDLE;
          end else begin
            state <= FLUSH_CHECK;
          end

        FLUSH_CHECK: begin
          scan <= scan + 1'b1;
          if (ent_dirty) begin
            slot     <= scan;
            old_tag  <= ent_tag;
            flushing <= 1'b1;
            bw       <= '0;
            sent     <= 1'b0;
            state    <= WB_LOAD;
          end else begin
            state <= FLUSH_SCAN;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

  // Simulation only (the testbench's view of memory): whether the SDRAM holds
  // main-memory word w, and at which SDRAM word.
  function automatic logic peek(logic [MEM_WORD_BITS-1:0] w,
                                output logic [SDRAM_WORD_BITS-1:0] dw);
    logic [TAG_BITS+1:0] e;
    e    = tags[w[7 +: SLOT_BITS]];
    dw   = w[SDRAM_WORD_BITS-1:0];
    peek = e[TAG_BITS+1] && e[TAG_BITS-1:0] == w[MEM_WORD_BITS-1 -: TAG_BITS];
  endfunction
endmodule
