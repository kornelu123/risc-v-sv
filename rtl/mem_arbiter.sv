// Shares one memory port (the request interface of ulx3s/rtl/sdram.sv)
// between two masters, master 0 first. A burst owns the port from its
// request until its last data word, so the write-ready and read-data pulses
// go to the master that asked for them.
module mem_arbiter (
  input  logic             clk,
  input  logic             rst_n,

  input  logic [1:0]       m_req_valid,
  output logic [1:0]       m_req_ready,
  input  logic [1:0]       m_req_we,
  input  logic [1:0][29:0] m_req_addr,
  input  logic [1:0][2:0]  m_req_len,
  input  logic [1:0][31:0] m_req_wdata,
  input  logic [1:0][3:0]  m_req_wstrb,
  output logic [1:0]       m_wr_ready,
  output logic [1:0]       m_rsp_valid,
  output logic [31:0]      m_rsp_rdata,   // shared; valid with m_rsp_valid

  output logic             req_valid,
  input  logic             req_ready,
  output logic             req_we,
  output logic [29:0]      req_addr,
  output logic [2:0]       req_len,
  output logic [31:0]      req_wdata,
  output logic [3:0]       req_wstrb,
  input  logic             wr_ready,
  input  logic             rsp_valid,
  input  logic [31:0]      rsp_rdata
);
  logic       busy;        // a burst is under way ...
  logic       owner;       // ... for this master
  logic       busy_we;
  logic [3:0] left;        // words still to transfer
  logic       cur;         // master connected to the port
  logic       we;          // the connected transfer is a write
  logic       beat;        // a word is transferred this cycle

  assign cur = busy ? owner : !m_req_valid[0];
  assign we  = busy ? busy_we : m_req_we[cur];

  assign req_valid = !busy && m_req_valid[cur];
  assign req_we    = m_req_we[cur];
  assign req_addr  = m_req_addr[cur];
  assign req_len   = m_req_len[cur];
  assign req_wdata = m_req_wdata[cur];
  assign req_wstrb = m_req_wstrb[cur];

  assign beat = we ? wr_ready : rsp_valid;

  always_comb begin
    m_req_ready      = '0;
    m_wr_ready       = '0;
    m_rsp_valid      = '0;
    m_req_ready[cur] = !busy && req_ready;
    m_wr_ready[cur]  = wr_ready;
    m_rsp_valid[cur] = rsp_valid;
  end
  assign m_rsp_rdata = rsp_rdata;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0;
    end else if (!busy) begin
      // Words of a burst may already come in the cycle it is accepted.
      if (req_valid && req_ready && {1'b0, req_len} + 4'd1 != 4'(beat)) begin
        busy    <= 1'b1;
        owner   <= cur;
        busy_we <= req_we;
        left    <= {1'b0, req_len} + 4'd1 - 4'(beat);
      end
    end else if (beat) begin
      left <= left - 4'd1;
      if (left == 4'd1) busy <= 1'b0;
    end
  end
endmodule
