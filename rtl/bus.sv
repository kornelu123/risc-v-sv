// Address decoder between the core's memory port (the request interface of
// ulx3s/rtl/sdram.sv) and the devices (rtl/memmap.sv):
//   - Main memory goes to rtl/sd_mem.sv (SDRAM cache in front of the card).
//   - Single-word requests to the register window go to rtl/sd_mem.sv's
//     register interface, one cycle after they are accepted.
//   - Anything else is answered here, one word per cycle: reads return
//     zeros and writes are dropped. Only instruction refills get there (also
//     those from the register window); the core turns other loads and stores
//     into access faults.
//
// The core issues one burst at a time and waits for its last word, so the
// responses of main memory and of the local responder never overlap.
module bus import memmap::*; #(
  localparam int MEM_WORD_BITS = $clog2(MEM_BYTES / 4)
) (
  input  logic                     clk,
  input  logic                     rst_n,

  input  logic                     req_valid,
  output logic                     req_ready,
  input  logic                     req_we,
  input  logic [29:0]              req_addr,
  input  logic [2:0]               req_len,
  input  logic [31:0]              req_wdata,
  input  logic [3:0]               req_wstrb,
  output logic                     wr_ready,
  output logic                     rsp_valid,
  output logic [31:0]              rsp_rdata,

  output logic                     mem_req_valid,
  input  logic                     mem_req_ready,
  output logic                     mem_req_we,
  output logic [MEM_WORD_BITS-1:0] mem_req_addr,
  output logic [2:0]               mem_req_len,
  output logic [31:0]              mem_req_wdata,
  output logic [3:0]               mem_req_wstrb,
  input  logic                     mem_wr_ready,
  input  logic                     mem_rsp_valid,
  input  logic [31:0]              mem_rsp_rdata,

  output logic                     ctrl_sel,
  output logic                     ctrl_we,
  output logic [9:0]               ctrl_addr,   // word in the window
  input  logic [31:0]              ctrl_rdata
);
  initial begin
    if ((MEM_BASE & 32'(MEM_BYTES - 1)) != 0 || (MEM_BYTES & (MEM_BYTES - 1)) != 0)
      $fatal(1, "bus: MEM_BYTES must be a power of two and MEM_BASE aligned to it");
    if (CTRL_BYTES != 4096 || (CTRL_BASE & 32'(CTRL_BYTES - 1)) != 0)
      $fatal(1, "bus: the register window must be 4 KB, aligned");
  end

  logic [29:0] mem_off;     // word offset into main memory
  logic        to_mem, to_ctrl;

  // A burst (an aligned cache line) never crosses the end of main memory.
  assign mem_off = req_addr - MEM_BASE[31:2];
  assign to_mem  = mem_off < 30'(MEM_BYTES / 4);
  assign to_ctrl = req_addr[29:10] == CTRL_BASE[31:12] && req_len == 3'd0;

  assign mem_req_valid = req_valid && to_mem;
  assign mem_req_we    = req_we;
  assign mem_req_addr  = mem_off[MEM_WORD_BITS-1:0];
  assign mem_req_len   = req_len;
  assign mem_req_wdata = req_wdata;
  assign mem_req_wstrb = req_wstrb;

  // ---- Registers and unmapped addresses -----------------------------------------
  logic       loc_busy, loc_we, loc_ctrl;
  logic [3:0] loc_left;     // words still to move
  logic [9:0] loc_addr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      loc_busy <= 1'b0;
    end else if (!loc_busy) begin
      if (req_valid && !to_mem) begin
        loc_busy <= 1'b1;
        loc_we   <= req_we;
        loc_ctrl <= to_ctrl;
        loc_left <= {1'b0, req_len} + 4'd1;
        loc_addr <= req_addr[9:0];
      end
    end else begin
      loc_left <= loc_left - 4'd1;
      if (loc_left == 4'd1) loc_busy <= 1'b0;
    end
  end

  assign ctrl_sel  = loc_busy && loc_ctrl;
  assign ctrl_we   = loc_we;
  assign ctrl_addr = loc_addr;

  assign req_ready = to_mem ? mem_req_ready : !loc_busy;
  assign wr_ready  = mem_wr_ready || (loc_busy && loc_we);
  assign rsp_valid = mem_rsp_valid || (loc_busy && !loc_we);
  assign rsp_rdata = mem_rsp_valid ? mem_rsp_rdata : ctrl_sel ? ctrl_rdata : 32'd0;
endmodule
