// Set-associative write-back, write-allocate cache, used both as the
// instruction cache (never written) and as the data cache.
//
// CPU side: lookups are combinational (the arrays are registers). An access
// of 2**size bytes may have any alignment. If it spans two words, both are
// read (and written), and both lines if it spans two lines; consecutive lines
// fall in different sets, hence SETS >= 2. `hit` means every byte is present:
// rdata is valid and, with `we`, the bytes are written at the clock edge. A
// miss starts a refill, after writing back a dirty victim, and the refill
// completes even if the request goes away; the caller repeats the access
// until it hits. Other lines keep hitting during a refill or write-back.
//
// Replacement: an invalid way if the set has one, otherwise tree-PLRU (true
// LRU for 2 ways). WAYS = 1 is a direct-mapped cache.
//
// Memory side: the request interface of ulx3s/rtl/sdram.sv with 30-bit word
// addresses; each refill or write-back is one burst of LINE_WORDS words.
//
// Maintenance: while `clean` is held, dirty lines are written back and stay
// valid; `dirty` falls once none is left. `invalidate` drops every line in
// one cycle and is only allowed while the cache is neither `busy` nor
// `dirty`.
module cache #(
  parameter int WAYS       = 2,    // power of two
  parameter int SETS       = 64,   // power of two, >= 2
  parameter int LINE_WORDS = 8,    // power of two, 2..8 (one SDRAM burst)
  localparam int OFF_BITS  = $clog2(LINE_WORDS),
  localparam int IDX_BITS  = $clog2(SETS),
  localparam int TAG_BITS  = 30 - IDX_BITS - OFF_BITS,
  localparam int WAY_BITS  = WAYS > 1 ? $clog2(WAYS) : 1
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req,
  input  logic [31:0] addr,
  input  logic [1:0]  size,         // log2 of the byte count: 0, 1 or 2
  input  logic        we,           // write wdata if the access hits
  input  logic [31:0] wdata,        // in the low 2**size bytes
  output logic        hit,
  output logic [31:0] rdata,        // the four bytes starting at addr

  input  logic        invalidate,
  input  logic        clean,
  output logic        dirty,        // some line differs from memory
  output logic        busy,         // a refill or write-back is under way

  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic        mem_req_we,
  output logic [29:0] mem_req_addr, // word address of the line
  output logic [2:0]  mem_req_len,  // words - 1
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  input  logic        mem_wr_ready,
  input  logic        mem_rsp_valid,
  input  logic [31:0] mem_rsp_rdata
);
  initial begin
    if (WAYS < 1 || (WAYS & (WAYS - 1)) != 0) $fatal(1, "cache: WAYS must be a power of two");
    if (SETS < 2 || (SETS & (SETS - 1)) != 0) $fatal(1, "cache: SETS must be a power of two >= 2");
    if (LINE_WORDS < 2 || LINE_WORDS > 8 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
      $fatal(1, "cache: LINE_WORDS must be 2, 4 or 8");
  end

  localparam int LEVELS    = $clog2(WAYS);
  localparam int LINE_BITS = $clog2(SETS * WAYS);

  typedef logic [IDX_BITS-1:0] idx_t;
  typedef logic [TAG_BITS-1:0] tag_t;
  typedef logic [OFF_BITS-1:0] off_t;
  typedef logic [WAY_BITS-1:0] way_t;

  tag_t            tag_q   [SETS][WAYS];
  logic [31:0]     data_q  [SETS][WAYS][LINE_WORDS];
  logic [WAYS-1:0] valid_q [SETS];
  logic [WAYS-1:0] dirty_q [SETS];
  logic [WAYS-1:0] plru_q  [SETS];   // tree nodes 1..WAYS-1; bit 0 unused

  // ---- Tree-PLRU ---------------------------------------------------------------
  // Node n has children 2n and 2n+1; leaves WAYS..2*WAYS-1 are the ways. A
  // node bit set means the least recently used half is the right one.
  // (Functions assign their result to their own name, for yosys.)
  function automatic way_t plru_victim(logic [WAYS-1:0] t);
    int node;
    node = 1;
    for (int l = 0; l < LEVELS; l++) node = 2 * node + int'(t[node]);
    plru_victim = way_t'(node - WAYS);
  endfunction

  function automatic logic [WAYS-1:0] plru_touch(logic [WAYS-1:0] t, way_t way);
    int node;
    node = 1;
    for (int l = LEVELS - 1; l >= 0; l--) begin
      t[node] = !way[l];                      // point away from the used way
      node    = 2 * node + int'(way[l]);
    end
    plru_touch = t;
  endfunction

  // ---- Lookup ----------------------------------------------------------------
  typedef enum logic [1:0] { IDLE, WRITEBACK, FILL } state_t;

  state_t           state;
  idx_t             vic_set;       // line being written back or refilled
  way_t             vic_way;
  tag_t             fill_tag;
  logic             refill;        // write-back of a victim: refill afterwards
  logic             sent;          // the memory request was accepted
  off_t             cnt;           // words transferred
  logic [LINE_BITS-1:0] scan;      // next line `clean` looks at

  logic [29:0]      wa     [2];    // the (up to) two words of the access
  idx_t             set    [2];
  tag_t             tag    [2];
  off_t             off    [2];
  logic [WAYS-1:0]  match  [2];
  way_t             way    [2];
  logic [31:0]      word   [2];
  logic [31:0]      wword  [2];    // word after the write
  logic             two;           // the access spans two words
  logic [7:0]       wmask;         // bytes written, over the two words
  logic [63:0]      wdata2;
  logic             mk;            // the word whose line a miss refills
  way_t             vway;          // the way that line replaces

  always_comb begin
    two = {1'b0, addr[1:0]} + (3'd1 << size) > 3'd4;

    for (int k = 0; k < 2; k++) begin
      wa[k]  = addr[31:2] + 30'(k);
      off[k] = wa[k][OFF_BITS-1:0];
      set[k] = wa[k][OFF_BITS +: IDX_BITS];
      tag[k] = wa[k][29 -: TAG_BITS];
      way[k] = '0;
      for (int w = 0; w < WAYS; w++) begin
        // A line being written back must not change underneath.
        match[k][w] = valid_q[set[k]][w] && tag_q[set[k]][w] == tag[k] &&
                      !(state == WRITEBACK && set[k] == vic_set && way_t'(w) == vic_way);
        if (match[k][w]) way[k] = way_t'(w);
      end
      word[k] = data_q[set[k]][way[k]][off[k]];
    end

    hit   = |match[0] && (!two || |match[1]);
    rdata = 32'({word[1], word[0]} >> {addr[1:0], 3'b000});

    // A miss refills the first missing word's line, into an invalid way if
    // the set has one, else the PLRU way.
    mk   = |match[0];
    vway = plru_victim(plru_q[set[mk]]);
    for (int w = WAYS - 1; w >= 0; w--)
      if (!valid_q[set[mk]][w]) vway = way_t'(w);
  end

  // Store data merged into the words (a separate block: for an AMO, wdata
  // depends on rdata).
  always_comb begin
    case (size)
      2'd0:    wmask = 8'b0001 << addr[1:0];
      2'd1:    wmask = 8'b0011 << addr[1:0];
      default: wmask = 8'b1111 << addr[1:0];
    endcase
    wdata2 = {32'd0, wdata} << {addr[1:0], 3'b000};
    for (int k = 0; k < 2; k++)
      for (int b = 0; b < 4; b++)
        wword[k][8*b +: 8] = wmask[4*k + b] ? wdata2[32*k + 8*b +: 8] : word[k][8*b +: 8];
  end

  always_comb begin
    dirty = 1'b0;
    for (int s = 0; s < SETS; s++) dirty |= |dirty_q[s];
  end

  assign busy = state != IDLE;

  // ---- Memory requests -------------------------------------------------------
  assign mem_req_valid = busy && !sent;
  assign mem_req_we    = state == WRITEBACK;
  assign mem_req_addr  = {state == WRITEBACK ? tag_q[vic_set][vic_way] : fill_tag, vic_set, off_t'(0)};
  assign mem_req_len   = 3'(LINE_WORDS - 1);
  assign mem_req_wdata = data_q[vic_set][vic_way][cnt];
  assign mem_req_wstrb = 4'hF;

  // Next line for `clean` to look at.
  idx_t scan_set;
  way_t scan_way;
  assign scan_set = idx_t'(scan >> LEVELS);
  assign scan_way = WAYS > 1 ? way_t'(scan) : '0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      sent  <= 1'b0;
      cnt   <= '0;
      scan  <= '0;
      for (int s = 0; s < SETS; s++) begin
        valid_q[s] <= '0;
        dirty_q[s] <= '0;
        plru_q[s]  <= '0;
      end
    end else begin
      if (invalidate) begin
        assert (!busy && !dirty) else $error("cache: invalidate while busy or dirty");
        for (int s = 0; s < SETS; s++) valid_q[s] <= '0;
      end

      // A hit: write the bytes and mark both words' lines as used. (A
      // two-word access inside one line touches the same way twice.)
      if (req && hit) begin
        for (int k = 0; k < 2; k++) begin
          if (k == 0 || two) begin
            plru_q[set[k]] <= plru_touch(plru_q[set[k]], way[k]);
            if (we && wmask[4*k +: 4] != 4'd0) begin
              data_q[set[k]][way[k]][off[k]] <= wword[k];
              dirty_q[set[k]][way[k]] <= 1'b1;
            end
          end
        end
      end

      case (state)
        IDLE: begin
          sent <= 1'b0;
          cnt  <= '0;
          if (req && !hit) begin
            vic_set  <= set[mk];
            vic_way  <= vway;
            fill_tag <= tag[mk];
            refill   <= 1'b1;
            if (dirty_q[set[mk]][vway]) begin
              state <= WRITEBACK;
            end else begin
              valid_q[set[mk]][vway] <= 1'b0;
              state <= FILL;
            end
          end else if (clean && dirty) begin
            scan <= scan + 1'b1;
            if (dirty_q[scan_set][scan_way]) begin
              vic_set <= scan_set;
              vic_way <= scan_way;
              refill  <= 1'b0;
              state   <= WRITEBACK;
            end
          end
        end

        WRITEBACK: begin
          if (mem_req_valid && mem_req_ready) sent <= 1'b1;
          if (mem_wr_ready) begin
            cnt <= cnt + 1'b1;
            if (cnt == off_t'(LINE_WORDS - 1)) begin
              dirty_q[vic_set][vic_way] <= 1'b0;
              sent <= 1'b0;
              if (refill) begin
                valid_q[vic_set][vic_way] <= 1'b0;
                state <= FILL;
              end else begin
                state <= IDLE;
              end
            end
          end
        end

        FILL: begin
          if (mem_req_valid && mem_req_ready) sent <= 1'b1;
          if (mem_rsp_valid) begin
            data_q[vic_set][vic_way][cnt] <= mem_rsp_rdata;
            cnt <= cnt + 1'b1;
            if (cnt == off_t'(LINE_WORDS - 1)) begin
              tag_q[vic_set][vic_way]   <= fill_tag;
              valid_q[vic_set][vic_way] <= 1'b1;
              state <= IDLE;
            end
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

  // Simulation only (the testbench's view of memory): the word at word
  // address a if a line holds it, including one being written back.
  function automatic logic peek(logic [29:0] a, output logic [31:0] w);
    idx_t s;
    s    = a[OFF_BITS +: IDX_BITS];
    peek = 1'b0;
    w    = 32'd0;
    for (int i = 0; i < WAYS; i++)
      if (valid_q[s][i] && tag_q[s][i] == a[29 -: TAG_BITS]) begin
        peek = 1'b1;
        w    = data_q[s][i][a[OFF_BITS-1:0]];
      end
  endfunction
endmodule
