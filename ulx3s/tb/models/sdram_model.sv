// Behavioural model of a 16-bit SDR SDRAM (IS42S16160G-like) for simulation.
// It stores data and stops the simulation with $fatal on any violation of the
// power-up sequence, command rules or minimum timings below. The timing
// parameters are the strictest values of the parts fitted to ULX3S boards.
module sdram_model #(
  parameter int  COL_BITS       = 9,
  parameter real T_POWERUP_NS   = 100_000.0,
  parameter real T_RCD_NS       = 21.0,
  parameter real T_RP_NS        = 21.0,
  parameter real T_RC_NS        = 66.0,
  parameter real T_RAS_NS       = 44.0,
  parameter real T_RRD_NS       = 15.0,
  parameter real T_WR_NS        = 15.0,
  parameter real T_RFC_NS       = 66.0,
  parameter real T_REFI_MAX_NS  = 7812.5,   // 64 ms / 8192
  parameter int  T_MRD_CYCLES   = 2,
  parameter int  INIT_REFRESHES = 2
) (
  input  logic        clk,
  input  logic        cke,
  input  logic        csn,
  input  logic        rasn,
  input  logic        casn,
  input  logic        wen,
  input  logic [12:0] a,
  input  logic [1:0]  ba,
  input  logic [1:0]  dqm,
  input  logic [15:0] dq_in,      // driven by the controller ...
  input  logic        dq_in_en,   // ... when this is high
  output logic [15:0] dq_out,
  output logic        dq_out_en
);
  typedef enum { CMD_INHIBIT, CMD_NOP, CMD_ACTIVE, CMD_READ, CMD_WRITE, CMD_BST,
                 CMD_PRECHARGE, CMD_REFRESH, CMD_MODE } cmd_t;

  // ---- State ------------------------------------------------------------------
  logic [15:0] mem [int];               // key = {bank, row, column}
  bit          bank_active [4];
  bit [12:0]   bank_row    [4];
  real         t_act       [4];         // last ACTIVE per bank
  real         t_idle      [4];         // bank precharged (ACTIVE allowed) from here
  real         t_wdata     [4];         // last write data latched per bank (tWR)
  real         t_last_act = -1.0e9;
  real         t_ref_done = 0.0;        // REFRESH finished
  real         t_last_ref = 0.0;
  real         t_mode     = -1.0e9;
  real         period     = 0.0;
  real         t_prev_edge = -1.0;
  bit          seen_command;            // first command other than NOP issued
  bit          precharged_all;          // init: PRECHARGE ALL done
  int          init_refreshes;
  bit          mode_set;
  int          cas_latency;
  int          burst_length;
  longint      nedge;                   // posedge counter
  int          refreshes;               // after initialisation

  typedef struct { longint due; int key; } beat_t;
  beat_t read_q[$];                     // read beats to drive
  beat_t write_q[$];                    // write beats still to latch

  // Pattern returned for never-written locations.
  function automatic logic [15:0] fill(int key);
    return 16'(key * 32'h9E37) ^ 16'h5A5A;
  endfunction

  function automatic int key_of(bit [1:0] b, bit [12:0] r, int col);
    return int'({b, r, 10'(col)});
  endfunction

  // Latch one write beat with the DQM of its own edge; masked bytes keep
  // their old contents.
  function automatic void store(int key);
    logic [15:0] old = mem.exists(key) != 0 ? mem[key] : fill(key);
    need(dq_in_en, "write data not driven");
    mem[key] = {dqm[1] ? old[15:8] : dq_in[15:8], dqm[0] ? old[7:0] : dq_in[7:0]};
    t_wdata[key >> 23] = $realtime;      // key = {bank, row, column}
  endfunction

  function automatic void fail(string msg);
    $fatal(1, "sdram_model @%0t: %s", $realtime, msg);
  endfunction

  function automatic void need(bit ok, string msg);
    if (!ok) fail(msg);
  endfunction

  function automatic cmd_t decode();
    if (csn) return CMD_INHIBIT;
    case ({rasn, casn, wen})
      3'b111:  return CMD_NOP;
      3'b011:  return CMD_ACTIVE;
      3'b101:  return CMD_READ;
      3'b100:  return CMD_WRITE;
      3'b110:  return CMD_BST;
      3'b010:  return CMD_PRECHARGE;
      3'b001:  return CMD_REFRESH;
      default: return CMD_MODE;
    endcase
  endfunction

  // Read data for testbench checks (without timing).
  function automatic logic [15:0] peek(bit [1:0] b, bit [12:0] r, int col);
    int k = key_of(b, r, col);
    return mem.exists(k) != 0 ? mem[k] : fill(k);
  endfunction

  // Write data without timing (testbench backdoor, e.g. to load a program).
  function automatic void poke(bit [1:0] b, bit [12:0] r, int col, logic [15:0] d);
    mem[key_of(b, r, col)] = d;
  endfunction

  // ---- Bus ------------------------------------------------------------------
  always @(clk or dq_in_en or dq_out_en)
    if (dq_in_en && dq_out_en) fail("data bus driven by controller and SDRAM at once");

  // ---- Commands -------------------------------------------------------------
  always @(posedge clk) begin
    real  now;
    cmd_t cmd;
    now = $realtime;
    if (t_prev_edge >= 0.0) period = now - t_prev_edge;
    t_prev_edge = now;
    nedge++;

    // Write beats latched on this edge.
    while (write_q.size() != 0 && write_q[0].due == nedge) begin
      beat_t w;
      w = write_q.pop_front();
      store(w.key);
    end

    // Read beats driven after this edge (valid until the next one).
    dq_out_en <= 1'b0;
    if (read_q.size() != 0 && read_q[0].due == nedge) begin
      beat_t r;
      r = read_q.pop_front();
      dq_out    <= mem.exists(r.key) != 0 ? mem[r.key] : fill(r.key);
      dq_out_en <= 1'b1;
    end else begin
      dq_out    <= 16'hDEAD;       // what a capture at the wrong time would see
    end

    if (mode_set && now - t_last_ref > T_REFI_MAX_NS)
      fail($sformatf("no REFRESH for %.1f ns", now - t_last_ref));

    need(cke, "CKE low (power-down / self refresh not modelled)");
    cmd = decode();
    if (cmd != CMD_INHIBIT && cmd != CMD_NOP) begin
      if (!seen_command)
        need(now >= T_POWERUP_NS, $sformatf("command after only %.1f ns of power-up", now));
      seen_command = 1'b1;
      need(now - t_mode >= T_MRD_CYCLES * period, "command within tMRD of MODE REGISTER SET");
      need(now >= t_ref_done, "command within tRFC of REFRESH");
    end

    case (cmd)
      CMD_ACTIVE: begin
        need(mode_set, "ACTIVE before the mode register is set");
        need(!bank_active[ba], $sformatf("ACTIVE to open bank %0d", ba));
        need(now >= t_idle[ba], $sformatf("ACTIVE to bank %0d within tRP/tWR of its precharge", ba));
        need(now - t_act[ba] >= T_RC_NS, $sformatf("ACTIVE to bank %0d within tRC", ba));
        need(now - t_last_act >= T_RRD_NS, "ACTIVE within tRRD of another ACTIVE");
        bank_active[ba] = 1'b1;
        bank_row[ba]    = a;
        t_act[ba]       = now;
        t_last_act      = now;
      end

      CMD_READ, CMD_WRITE: begin
        int  col;
        real end_t;
        need(bank_active[ba], $sformatf("READ/WRITE to closed bank %0d", ba));
        need(now - t_act[ba] >= T_RCD_NS, "READ/WRITE within tRCD of ACTIVE");
        col = int'(a[COL_BITS-1:0]);
        need(col % burst_length == 0, "burst start not aligned (wrap-around not modelled)");
        need(write_q.size() == 0, "READ/WRITE interrupts a write burst");
        for (int i = 0; i < burst_length; i++) begin
          beat_t b;
          b.key  = key_of(ba, bank_row[ba], col + i);
          if (cmd == CMD_READ) begin
            int offset;
            offset = cas_latency - 1 + i;   // beat i is driven after this edge
            b.due  = nedge + longint'(offset);
            if (i == 0)
              need(read_q.size() == 0 || read_q[$].due < b.due, "READ interrupts a read burst");
            read_q.push_back(b);
          end else begin
            b.due = nedge + longint'(i);
            if (i == 0) begin
              store(b.key);
            end else begin
              write_q.push_back(b);
            end
          end
        end
        if (a[10]) begin           // auto precharge after the burst
          if (cmd == CMD_READ) end_t = now + burst_length * period;
          else                 end_t = now + (burst_length - 1) * period + T_WR_NS;
          if (end_t < t_act[ba] + T_RAS_NS) end_t = t_act[ba] + T_RAS_NS;
          t_idle[ba]      = end_t + T_RP_NS;
          bank_active[ba] = 1'b0;
        end
      end

      CMD_PRECHARGE: begin
        for (int b = 0; b < 4; b++) begin
          if (a[10] || b == int'(ba)) begin
            if (bank_active[b]) begin
              need(now - t_act[b] >= T_RAS_NS, "PRECHARGE within tRAS");
              need(now - t_wdata[b] >= T_WR_NS, "PRECHARGE within tWR of the last write data");
            end
            bank_active[b] = 1'b0;
            if (t_idle[b] < now + T_RP_NS) t_idle[b] = now + T_RP_NS;
          end
        end
        if (a[10] && !mode_set) precharged_all = 1'b1;
      end

      CMD_REFRESH: begin
        for (int b = 0; b < 4; b++) begin
          need(!bank_active[b], "REFRESH with a bank open");
          need(now >= t_idle[b], "REFRESH within tRP of a precharge");
        end
        if (!mode_set) begin
          need(precharged_all, "init REFRESH before PRECHARGE ALL");
          init_refreshes++;
        end else begin
          refreshes++;
        end
        t_ref_done = now + T_RFC_NS;
        t_last_ref = now;
      end

      CMD_MODE: begin
        for (int b = 0; b < 4; b++) begin
          need(!bank_active[b], "MODE REGISTER SET with a bank open");
          need(now >= t_idle[b], "MODE REGISTER SET within tRP");
        end
        need(precharged_all, "MODE REGISTER SET before PRECHARGE ALL");
        need(init_refreshes >= INIT_REFRESHES, "MODE REGISTER SET before the init refreshes");
        need(a[3] == 1'b0, "interleaved bursts not modelled");
        need(a[9] == 1'b0, "single-location writes not modelled");
        need(a[6:4] == 3'd2 || a[6:4] == 3'd3, "CAS latency must be 2 or 3");
        need(a[2:0] <= 3'd3, "burst length must be 1, 2, 4 or 8");
        cas_latency  = int'(a[6:4]);
        burst_length = 1 << a[2:0];
        mode_set     = 1'b1;
        t_mode       = now;
        t_last_ref   = now;        // the refresh interval starts here
      end

      CMD_BST: fail("BURST TERMINATE not modelled");
      default: ;
    endcase

    // DQM high masks read data two cycles later: keep it low while reads are
    // in flight (masked reads are not used).
    if (read_q.size() != 0) need(dqm == 2'b00, "DQM high while read data is pending");
  end

  initial begin
    for (int b = 0; b < 4; b++) begin
      t_act[b]  = -1.0e9;
      t_idle[b] = 0.0;
      t_wdata[b] = -1.0e9;
    end
    dq_out    = 16'hDEAD;
    dq_out_en = 1'b0;
  end
endmodule
