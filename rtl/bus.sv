// Address decoder between the core's memory port and the devices, all with
// the request interface of ulx3s/rtl/sdram.sv. RAM (memmap::RAM_BASE,
// RAM_BYTES) goes to the SDRAM controller. Any other address is answered
// here: reads return zeros, writes are dropped, one word per cycle. Only
// instruction refills get there; the core turns loads and stores outside RAM
// into access faults.
//
// The core issues one burst at a time and waits for its last word, so the
// responses of RAM and of the local responder never overlap.
module bus import memmap::*; #(
  localparam int RAM_ADDR_BITS = $clog2(RAM_BYTES / 4)
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

  output logic                     ram_req_valid,
  input  logic                     ram_req_ready,
  output logic                     ram_req_we,
  output logic [RAM_ADDR_BITS-1:0] ram_req_addr,
  output logic [2:0]               ram_req_len,
  output logic [31:0]              ram_req_wdata,
  output logic [3:0]               ram_req_wstrb,
  input  logic                     ram_wr_ready,
  input  logic                     ram_rsp_valid,
  input  logic [31:0]              ram_rsp_rdata
);
  initial if ((RAM_BASE & 32'(RAM_BYTES - 1)) != 0 || (RAM_BYTES & (RAM_BYTES - 1)) != 0)
    $fatal(1, "bus: RAM_BYTES must be a power of two and RAM_BASE aligned to it");

  logic [29:0] ram_off;     // word offset into RAM
  logic        to_ram;

  // A burst (an aligned cache line) never crosses the end of RAM.
  assign ram_off = req_addr - RAM_BASE[31:2];
  assign to_ram  = ram_off < 30'(RAM_BYTES / 4);

  assign ram_req_valid = req_valid && to_ram;
  assign ram_req_we    = req_we;
  assign ram_req_addr  = ram_off[RAM_ADDR_BITS-1:0];
  assign ram_req_len   = req_len;
  assign ram_req_wdata = req_wdata;
  assign ram_req_wstrb = req_wstrb;

  // ---- Unmapped addresses ----------------------------------------------------
  logic       none_busy, none_we;
  logic [3:0] none_left;    // words still to move

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      none_busy <= 1'b0;
    end else if (!none_busy) begin
      if (req_valid && !to_ram) begin
        none_busy <= 1'b1;
        none_we   <= req_we;
        none_left <= {1'b0, req_len} + 4'd1;
      end
    end else begin
      none_left <= none_left - 4'd1;
      if (none_left == 4'd1) none_busy <= 1'b0;
    end
  end

  assign req_ready = to_ram ? ram_req_ready : !none_busy;
  assign wr_ready  = ram_wr_ready || (none_busy && none_we);
  assign rsp_valid = ram_rsp_valid || (none_busy && !none_we);
  assign rsp_rdata = ram_rsp_valid ? ram_rsp_rdata : 32'd0;
endmodule
