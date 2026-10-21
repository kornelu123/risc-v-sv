// The system: the core (with its caches), the address decoder and the SDRAM
// controller for the RAM. The SDRAM pins come out as in ulx3s/rtl/sdram.sv;
// on the board, drive sdram_clk with the inverted clk and join dq_o/dq_oe/dq_i
// into the tristate data bus (see ulx3s/README.md).
module soc import memmap::*; #(
  parameter int IC_WAYS       = 2,
  parameter int IC_SETS       = 64,
  parameter int IC_LINE_WORDS = 8,
  parameter int DC_WAYS       = 2,
  parameter int DC_SETS       = 64,
  parameter int DC_LINE_WORDS = 8,
  parameter int CLK_MHZ       = 50,
  parameter int CAS_LATENCY   = 2,
  localparam int RAM_ADDR_BITS = $clog2(RAM_BYTES / 4),
  localparam int ROW_BITS      = 13,
  // Word address = {row, bank, word column}: 9 for 32 MB, 10 for 64 MB.
  localparam int COL_BITS      = RAM_ADDR_BITS - ROW_BITS - 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        irq_software,
  input  logic        irq_timer,
  input  logic        irq_external,
  output logic        init_done,     // SDRAM initialised (the core waits for it)

  output logic        sdram_cke,
  output logic        sdram_csn,
  output logic        sdram_rasn,
  output logic        sdram_casn,
  output logic        sdram_wen,
  output logic [12:0] sdram_a,
  output logic [1:0]  sdram_ba,
  output logic [1:0]  sdram_dqm,
  output logic [15:0] dq_o,
  output logic        dq_oe,
  input  logic [15:0] dq_i
);
  logic        req_valid, req_ready, req_we, wr_ready, rsp_valid;
  logic [29:0] req_addr;
  logic [2:0]  req_len;
  logic [31:0] req_wdata, rsp_rdata;
  logic [3:0]  req_wstrb;

  logic                     ram_req_valid, ram_req_ready, ram_req_we;
  logic                     ram_wr_ready, ram_rsp_valid;
  logic [RAM_ADDR_BITS-1:0] ram_req_addr;
  logic [2:0]               ram_req_len;
  logic [31:0]              ram_req_wdata, ram_rsp_rdata;
  logic [3:0]               ram_req_wstrb;

  cu #(.IC_WAYS(IC_WAYS), .IC_SETS(IC_SETS), .IC_LINE_WORDS(IC_LINE_WORDS),
       .DC_WAYS(DC_WAYS), .DC_SETS(DC_SETS), .DC_LINE_WORDS(DC_LINE_WORDS)) core(
    .iclk(clk),
    .rst_n,
    .irq_software,
    .irq_timer,
    .irq_external,
    .mem_req_valid(req_valid),
    .mem_req_ready(req_ready),
    .mem_req_we(req_we),
    .mem_req_addr(req_addr),
    .mem_req_len(req_len),
    .mem_req_wdata(req_wdata),
    .mem_req_wstrb(req_wstrb),
    .mem_wr_ready(wr_ready),
    .mem_rsp_valid(rsp_valid),
    .mem_rsp_rdata(rsp_rdata));

  bus decoder(
    .clk, .rst_n,
    .req_valid, .req_ready, .req_we, .req_addr, .req_len, .req_wdata, .req_wstrb,
    .wr_ready, .rsp_valid, .rsp_rdata,
    .ram_req_valid, .ram_req_ready, .ram_req_we, .ram_req_addr, .ram_req_len,
    .ram_req_wdata, .ram_req_wstrb, .ram_wr_ready, .ram_rsp_valid, .ram_rsp_rdata);

  sdram #(.CLK_MHZ(CLK_MHZ), .CAS_LATENCY(CAS_LATENCY), .ROW_BITS(ROW_BITS),
          .COL_BITS(COL_BITS), .MAX_BURST(8)) ram(
    .clk, .rst_n,
    .req_valid(ram_req_valid),
    .req_ready(ram_req_ready),
    .req_we(ram_req_we),
    .req_addr(ram_req_addr),
    .req_len(ram_req_len),
    .req_wdata(ram_req_wdata),
    .req_wstrb(ram_req_wstrb),
    .wr_ready(ram_wr_ready),
    .rsp_valid(ram_rsp_valid),
    .rsp_rdata(ram_rsp_rdata),
    .init_done,
    .sdram_cke, .sdram_csn, .sdram_rasn, .sdram_casn, .sdram_wen, .sdram_a,
    .sdram_ba, .sdram_dqm, .dq_o, .dq_oe, .dq_i);
endmodule
