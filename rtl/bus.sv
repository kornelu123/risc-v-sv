// Address decoder between the core's memory port (the request interface of
// ulx3s/rtl/sdram.sv) and the devices (rtl/memmap.sv):
//   - Main memory goes to rtl/sd_mem.sv (SDRAM cache in front of the card).
//   - Single-word requests to the register window go to rtl/sd_mem.sv's
//     register interface, one cycle after they are accepted.
//   - Single-word requests to the CLINT go to rtl/clint.sv, same timing.
//   - Single-word requests to the UART go to rtl/uart.sv, same timing.
//   - Anything else is answered here, one word per cycle: reads return
//     zeros and writes are dropped. The core checks memmap before it requests
//     anything (loads, stores and fetches outside memory are access faults),
//     so only a core bug reaches this.
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
  output logic                     clint_sel,
  output logic                     uart_sel,
  output logic                     dev_we,
  output logic [13:0]              dev_addr,    // word in the device's window
  output logic [31:0]              dev_wdata,
  output logic [3:0]               dev_wstrb,
  input  logic [31:0]              ctrl_rdata,
  input  logic [31:0]              clint_rdata,
  input  logic [31:0]              uart_rdata
);
  initial begin
    if ((MEM_BASE & 32'(MEM_BYTES - 1)) != 0 || (MEM_BYTES & (MEM_BYTES - 1)) != 0)
      $fatal(1, "bus: MEM_BYTES must be a power of two and MEM_BASE aligned to it");
    if (CTRL_BYTES != 4096 || (CTRL_BASE & 32'(CTRL_BYTES - 1)) != 0)
      $fatal(1, "bus: the register window must be 4 KB, aligned");
    if (CLINT_BYTES != 65536 || (CLINT_BASE & 32'(CLINT_BYTES - 1)) != 0)
      $fatal(1, "bus: the CLINT window must be 64 KB, aligned");
    if (UART_BYTES != 256 || (UART_BASE & 32'(UART_BYTES - 1)) != 0)
      $fatal(1, "bus: the UART window must be 256 bytes, aligned");
  end

  logic [29:0] mem_off;     // word offset into main memory
  logic        to_mem, to_ctrl, to_clint, to_uart;

  // A burst (an aligned cache line) never crosses the end of main memory.
  assign mem_off = req_addr - MEM_BASE[31:2];
  assign to_mem  = mem_off < 30'(MEM_BYTES / 4);
  assign to_ctrl = req_addr[29:10] == CTRL_BASE[31:12] && req_len == 3'd0;
  assign to_clint = req_addr[29:14] == CLINT_BASE[31:16] && req_len == 3'd0;
  assign to_uart  = req_addr[29:6] == UART_BASE[31:8] && req_len == 3'd0;

  assign mem_req_valid = req_valid && to_mem;
  assign mem_req_we    = req_we;
  assign mem_req_addr  = mem_off[MEM_WORD_BITS-1:0];
  assign mem_req_len   = req_len;
  assign mem_req_wdata = req_wdata;
  assign mem_req_wstrb = req_wstrb;

  // ---- Registers, device requests and unmapped addresses ------------------------
  logic        loc_busy, loc_we, loc_ctrl, loc_clint, loc_uart;
  logic [3:0]  loc_left;    // words still to move
  logic [13:0] loc_addr;
  logic [31:0] loc_wdata;
  logic [3:0]  loc_wstrb;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      loc_busy <= 1'b0;
    end else if (!loc_busy) begin
      if (req_valid && !to_mem) begin
        loc_busy  <= 1'b1;
        loc_we    <= req_we;
        loc_ctrl  <= to_ctrl;
        loc_clint <= to_clint;
        loc_uart  <= to_uart;
        loc_left  <= {1'b0, req_len} + 4'd1;
        loc_addr  <= req_addr[13:0];
        loc_wdata <= req_wdata;
        loc_wstrb <= req_wstrb;
      end
    end else begin
      loc_left <= loc_left - 4'd1;
      if (loc_left == 4'd1) loc_busy <= 1'b0;
    end
  end

  assign ctrl_sel  = loc_busy && loc_ctrl;
  assign clint_sel = loc_busy && loc_clint;
  assign uart_sel = loc_busy && loc_uart;
  assign dev_we    = loc_we;
  assign dev_addr  = loc_addr;
  assign dev_wdata = loc_wdata;
  assign dev_wstrb = loc_wstrb;

  assign req_ready = to_mem ? mem_req_ready : !loc_busy;
  assign wr_ready  = mem_wr_ready || (loc_busy && loc_we);
  assign rsp_valid = mem_rsp_valid || (loc_busy && !loc_we);
  assign rsp_rdata = mem_rsp_valid ? mem_rsp_rdata : ctrl_sel ? ctrl_rdata :
                     clint_sel ? clint_rdata : uart_sel ? uart_rdata : 32'd0;
endmodule
