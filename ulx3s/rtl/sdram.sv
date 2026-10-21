// SDR SDRAM controller for the ULX3S board's 16-bit SDRAM (ISSI IS42S16160G,
// 32 MB, or compatible 32/64 MB parts).
//
// User side: a request is 1..MAX_BURST consecutive 32-bit words (req_len =
// words - 1) inside one SDRAM row, e.g. an aligned cache line. Write words are
// taken one per wr_ready pulse from req_wdata/req_wstrb (word 0 first), read
// words come back in order with rsp_valid. One request at a time.
//
// Memory side: the chip runs with a burst length of 2 (the two 16-bit halves
// of a word); a burst of N words is N READ or WRITE commands two cycles apart,
// which the chip pipelines into a continuous data stream. Rows stay open after
// an access ("open page"): a request to the open row of its bank needs no
// ACTIVE; another row costs PRECHARGE + ACTIVE; refresh closes all rows first.
// Per-bank timers enforce tRCD, tRAS, tRC, tRP, tWR and tRRD.
//
// Clocking: drive the chip's sdram_clk with the inverse of clk (e.g. an
// ODDRX1F with D0 = 0, D1 = 1). The chip then samples commands and write data
// in the middle of clk's cycle, and read data is captured CAS_LATENCY cycles
// after the READ command. This leaves (T/2 - tAC) of setup time, so keep clk at
// or below about 60 MHz; 50 MHz is the design point.
//
// Word address = {row, bank, column[COL_BITS-1:1]}; byte address = word * 4,
// little-endian (bits 15:0 of the word are the even column). A row holds
// 2^(COL_BITS-1) words; a burst must not cross the end of a row (it would wrap
// around inside the row).
module sdram #(
  parameter int CLK_MHZ      = 50,
  parameter int CAS_LATENCY  = 2,      // 2 or 3
  parameter int ROW_BITS     = 13,
  parameter int COL_BITS     = 9,      // 9: 32 MB (16M x 16), 10: 64 MB (32M x 16)
  parameter int MAX_BURST    = 8,      // words per request, a power of two >= 2
  // Timing, worst case of the parts fitted to ULX3S boards.
  parameter int T_POWERUP_US = 200,
  parameter int T_RCD_NS     = 21,     // ACTIVE to READ/WRITE
  parameter int T_RP_NS      = 21,     // PRECHARGE to ACTIVE/REFRESH
  parameter int T_RC_NS      = 66,     // ACTIVE to ACTIVE (same bank)
  parameter int T_RAS_NS     = 44,     // ACTIVE to PRECHARGE
  parameter int T_RRD_NS     = 15,     // ACTIVE to ACTIVE (other bank)
  parameter int T_WR_NS      = 15,     // last write data to PRECHARGE
  parameter int T_RFC_NS     = 66,     // REFRESH to any command
  parameter int T_REFI_NS    = 7800,   // refresh interval (64 ms / 8192 rows)
  localparam int ADDR_BITS   = ROW_BITS + 2 + COL_BITS - 1,
  localparam int LEN_BITS    = $clog2(MAX_BURST)
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 req_valid,
  output logic                 req_ready,
  input  logic                 req_we,
  input  logic [ADDR_BITS-1:0] req_addr,     // 32-bit word address of word 0
  input  logic [LEN_BITS-1:0]  req_len,      // words - 1
  input  logic [31:0]          req_wdata,    // current write word ...
  input  logic [3:0]           req_wstrb,
  output logic                 wr_ready,     // ... taken in this cycle
  output logic                 rsp_valid,    // one cycle per read word
  output logic [31:0]          rsp_rdata,
  output logic                 init_done,

  output logic                 sdram_cke,
  output logic                 sdram_csn,
  output logic                 sdram_rasn,
  output logic                 sdram_casn,
  output logic                 sdram_wen,
  output logic [12:0]          sdram_a,
  output logic [1:0]           sdram_ba,
  output logic [1:0]           sdram_dqm,
  output logic [15:0]          dq_o,
  output logic                 dq_oe,
  input  logic [15:0]          dq_i
);
  // ---- Timing in clock cycles -----------------------------------------------
  // (Functions assign their result to their own name: yosys' SystemVerilog
  // frontend does not support `return`.)
  function automatic int cycles(int ns);
    cycles = (ns * CLK_MHZ + 999) / 1000;         // round up
  endfunction

  function automatic int max2(int a, int b);
    max2 = a > b ? a : b;
  endfunction

  localparam int RCD        = max2(cycles(T_RCD_NS), 1);
  localparam int RP         = max2(cycles(T_RP_NS), 1);
  localparam int RC         = max2(cycles(T_RC_NS), 1);
  localparam int RAS        = max2(cycles(T_RAS_NS), 1);
  localparam int RRD        = max2(cycles(T_RRD_NS), 1);
  localparam int WR         = max2(cycles(T_WR_NS), 1);
  localparam int RFC        = max2(cycles(T_RFC_NS), 1);
  localparam int MRD        = 2;
  localparam int POWERUP    = T_POWERUP_US * CLK_MHZ;
  localparam int INIT_REFRESHES = 8;

  // Refresh early enough that the longest request plus closing all rows
  // cannot push it past tREFI.
  localparam int REQ_MAX    = RAS + WR + RP + RC + RRD + RCD + 2 * MAX_BURST + CAS_LATENCY + 4;
  localparam int REFI       = T_REFI_NS * CLK_MHZ / 1000 - REQ_MAX - RAS - WR - RP - 4;

  localparam int TW = $clog2(POWERUP + 1);
  localparam int RW = $clog2(REFI + 1);
  localparam int CW = $clog2(max2(max2(max2(RC, RFC), max2(RAS, WR)),
                                  max2(max2(RP, RCD), RRD)) + 1);

  // Mode register: burst length 2, sequential, CAS latency, burst writes.
  localparam bit [12:0] MODE = {3'b000, 1'b0, 2'b00, 3'(CAS_LATENCY), 1'b0, 3'b001};

  // ---- Commands {csn, rasn, casn, wen} --------------------------------------
  localparam bit [3:0] CMD_INHIBIT   = 4'b1111;
  localparam bit [3:0] CMD_NOP       = 4'b0111;
  localparam bit [3:0] CMD_ACTIVE    = 4'b0011;
  localparam bit [3:0] CMD_READ      = 4'b0101;
  localparam bit [3:0] CMD_WRITE     = 4'b0100;
  localparam bit [3:0] CMD_PRECHARGE = 4'b0010;
  localparam bit [3:0] CMD_REFRESH   = 4'b0001;
  localparam bit [3:0] CMD_MODE      = 4'b0000;

  typedef enum logic [3:0] {
    S_POWERUP, S_INIT_PRECHARGE, S_INIT_REFRESH, S_MODE,
    S_IDLE, S_OPEN, S_COL, S_DRAIN, S_REF_CLOSE, S_REF
  } state_t;

  state_t        state;
  logic [TW-1:0] t;               // init sequence timer
  logic [3:0]    refreshes;       // init refreshes still to issue
  logic [RW-1:0] refi;            // cycles since the last refresh
  logic          refresh_due;

  // Per bank: open row and timers that count down to 0 and stop. A command is
  // allowed while its timer reads 0, so a timer loaded with n - 1 allows the
  // command n cycles after the load.
  logic [3:0]          open;
  logic [ROW_BITS-1:0] open_row [4];
  logic [CW-1:0]       act_wait [4];   // ACTIVE: tRC, tRP, tRFC
  logic [CW-1:0]       pre_wait [4];   // PRECHARGE: tRAS, tWR
  logic [CW-1:0]       col_wait [4];   // READ/WRITE: tRCD
  logic [CW-1:0]       rrd_wait;       // ACTIVE to any bank: tRRD

  // Current request.
  logic                we;
  logic [ROW_BITS-1:0] row;
  logic [1:0]          bank;
  logic [COL_BITS-2:0] colw;           // word column of the next command
  logic [LEN_BITS-1:0] left;           // words still to issue - 1
  logic                beat2;          // second cycle of a column command
  logic [15:0]         wdata_hi;
  logic [1:0]          dqm_hi;

  // Read capture: bit k set = a READ was issued k+1 cycles ago.
  logic [CAS_LATENCY:0] rd_pipe;
  logic                 rd_cmd;

  logic [3:0] cmd;
  assign {sdram_csn, sdram_rasn, sdram_casn, sdram_wen} = cmd;
  assign refresh_due = refi >= RW'(REFI);
  assign req_ready   = state == S_IDLE && !refresh_due;
  assign wr_ready    = state == S_COL && we && !beat2;
  assign rd_cmd      = state == S_COL && !we && !beat2;

  // The request's row is open: skip S_OPEN. (tRCD has passed: after an
  // ACTIVE, S_OPEN waits for it before the column commands.)
  logic [1:0] req_bank;
  logic       req_hit;
  assign req_bank = req_addr[COL_BITS-1 +: 2];
  assign req_hit  = open[req_bank] &&
                    open_row[req_bank] == req_addr[ADDR_BITS-1 -: ROW_BITS];

  function automatic logic [CW-1:0] dec(logic [CW-1:0] c);
    dec = c != 0 ? c - 1'b1 : '0;
  endfunction

  // Counter after this cycle's decrement, but at least n.
  function automatic logic [CW-1:0] at_least(logic [CW-1:0] c, logic [CW-1:0] n);
    at_least = dec(c) > n ? dec(c) : n;
  endfunction

  // All banks can be precharged / activated now.
  logic all_pre_ok, all_act_ok;
  always_comb begin
    all_pre_ok = 1'b1;
    all_act_ok = 1'b1;
    for (int b = 0; b < 4; b++) begin
      if (pre_wait[b] != 0) all_pre_ok = 1'b0;
      if (act_wait[b] != 0) all_act_ok = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= S_POWERUP;
      t         <= '0;
      refi      <= '0;
      refreshes <= 4'(INIT_REFRESHES);
      init_done <= 1'b0;
      cmd       <= CMD_INHIBIT;
      sdram_cke <= 1'b1;
      sdram_a   <= '0;
      sdram_ba  <= '0;
      sdram_dqm <= 2'b11;
      dq_oe     <= 1'b0;
      dq_o      <= '0;
      rsp_valid <= 1'b0;
      rsp_rdata <= '0;
      rd_pipe   <= '0;
      open      <= '0;
      rrd_wait  <= '0;
      beat2     <= 1'b0;
      for (int b = 0; b < 4; b++) begin
        act_wait[b] <= '0;
        pre_wait[b] <= '0;
        col_wait[b] <= '0;
      end
    end else begin
      cmd       <= CMD_NOP;
      t         <= t + 1'b1;
      rsp_valid <= 1'b0;
      dq_oe     <= 1'b0;
      sdram_dqm <= 2'b00;                 // low except under masked write bytes
      if (init_done && !refresh_due) refi <= refi + 1'b1;
      rrd_wait  <= dec(rrd_wait);
      for (int b = 0; b < 4; b++) begin
        act_wait[b] <= dec(act_wait[b]);
        pre_wait[b] <= dec(pre_wait[b]);
        col_wait[b] <= dec(col_wait[b]);
      end

      // Read data: low half CAS_LATENCY cycles after READ, high half one later.
      rd_pipe <= {rd_pipe[CAS_LATENCY-1:0], rd_cmd};
      if (rd_pipe[CAS_LATENCY-1]) rsp_rdata[15:0] <= dq_i;
      if (rd_pipe[CAS_LATENCY]) begin
        rsp_rdata[31:16] <= dq_i;
        rsp_valid        <= 1'b1;
      end

      case (state)
        // ---- Power-up: NOPs, PRECHARGE ALL, refreshes, mode register -------
        S_POWERUP: if (t == TW'(POWERUP - 1)) begin
          cmd         <= CMD_PRECHARGE;
          sdram_a[10] <= 1'b1;                      // all banks
          t           <= '0;
          state       <= S_INIT_PRECHARGE;
        end
        S_INIT_PRECHARGE: if (t == TW'(RP - 1)) begin
          cmd       <= CMD_REFRESH;
          refreshes <= refreshes - 1'b1;
          t         <= '0;
          state     <= S_INIT_REFRESH;
        end
        S_INIT_REFRESH: if (t == TW'(RFC - 1)) begin
          t <= '0;
          if (refreshes != 0) begin
            cmd       <= CMD_REFRESH;
            refreshes <= refreshes - 1'b1;
          end else begin
            cmd      <= CMD_MODE;
            sdram_a  <= MODE;
            sdram_ba <= 2'b00;
            state    <= S_MODE;
          end
        end
        S_MODE: if (t == TW'(MRD - 1)) begin
          init_done <= 1'b1;
          state     <= S_IDLE;
        end

        // ---- Requests ---------------------------------------------------------
        S_IDLE:
          if (refresh_due) begin
            state <= S_REF_CLOSE;
          end else if (req_valid) begin
            we    <= req_we;
            row   <= req_addr[ADDR_BITS-1 -: ROW_BITS];
            bank  <= req_bank;
            colw  <= req_addr[COL_BITS-2:0];
            left  <= req_len;
            beat2 <= 1'b0;
            state <= req_hit ? S_COL : S_OPEN;
          end

        // Make the request's row the open row of its bank.
        S_OPEN:
          if (open[bank] && open_row[bank] == row) begin
            // S_COL issues the command in the next cycle.
            if (col_wait[bank] <= 1) state <= S_COL;
          end else if (open[bank]) begin
            if (pre_wait[bank] == 0) begin             // close the other row
              cmd            <= CMD_PRECHARGE;
              sdram_a[10]    <= 1'b0;
              sdram_ba       <= bank;
              open[bank]     <= 1'b0;
              act_wait[bank] <= at_least(act_wait[bank], CW'(RP - 1));
            end
          end else if (act_wait[bank] == 0 && rrd_wait == 0) begin
            cmd            <= CMD_ACTIVE;
            sdram_a        <= 13'(row);
            sdram_ba       <= bank;
            open[bank]     <= 1'b1;
            open_row[bank] <= row;
            act_wait[bank] <= CW'(RC - 1);
            pre_wait[bank] <= CW'(RAS - 1);
            col_wait[bank] <= CW'(RCD - 1);
            rrd_wait       <= CW'(RRD - 1);
          end

        // One READ/WRITE (no auto-precharge) every two cycles.
        S_COL: begin
          beat2 <= !beat2;
          if (!beat2) begin
            cmd      <= we ? CMD_WRITE : CMD_READ;
            sdram_a  <= 13'(colw) << 1;              // A10 = 0: row stays open
            sdram_ba <= bank;
            if (we) begin
              dq_o      <= req_wdata[15:0];
              sdram_dqm <= ~req_wstrb[1:0];
              dq_oe     <= 1'b1;
              wdata_hi  <= req_wdata[31:16];
              dqm_hi    <= ~req_wstrb[3:2];
            end
          end else begin
            if (we) begin
              dq_o           <= wdata_hi;
              sdram_dqm      <= dqm_hi;
              dq_oe          <= 1'b1;
              pre_wait[bank] <= at_least(pre_wait[bank], CW'(WR - 1));
            end
            colw <= colw + 1'b1;
            left <= left - 1'b1;
            if (left == 0) state <= we ? S_IDLE : S_DRAIN;
          end
        end

        // Wait for the last read data before the bus can turn around.
        S_DRAIN: if (rd_pipe == 0 && !rd_cmd) state <= S_IDLE;

        // ---- Refresh: close all rows, then REFRESH -----------------------------
        S_REF_CLOSE:
          if (open == 0) begin
            if (all_act_ok) begin
              cmd   <= CMD_REFRESH;
              refi  <= '0;
              for (int b = 0; b < 4; b++) act_wait[b] <= CW'(RFC - 1);
              state <= S_REF;
            end
          end else if (all_pre_ok) begin
            cmd         <= CMD_PRECHARGE;
            sdram_a[10] <= 1'b1;                       // all banks
            open        <= '0;
            for (int b = 0; b < 4; b++) act_wait[b] <= at_least(act_wait[b], CW'(RP - 1));
          end
        S_REF: if (all_act_ok) state <= S_IDLE;

        default: state <= S_POWERUP;
      endcase
    end
  end
endmodule
