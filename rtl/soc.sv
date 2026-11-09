// The system: the core (with its caches), the address decoder, the CLINT, the UART,
// and main memory: the SD card, cached in the SDRAM by rtl/sd_mem.sv (rtl/memmap.sv
// has the map). The SDRAM pins come out as in ulx3s/rtl/sdram.sv; on the
// board, drive sdram_clk with the inverted clk and join dq_o/dq_oe/dq_i into
// the tristate data bus. SD card (SPI mode): sd_clk = sd_sck, sd_cmd =
// sd_mosi, sd_d[3] = sd_cs_n, sd_miso = sd_d[0] (see ulx3s/README.md).
module soc import memmap::*; #(
  parameter int IC_WAYS       = 2,
  parameter int IC_SETS       = 64,
  parameter int IC_LINE_WORDS = 8,
  parameter int DC_WAYS       = 2,
  parameter int DC_SETS       = 64,
  parameter int DC_LINE_WORDS = 8,
  parameter int CLK_MHZ       = 50,
  parameter int CAS_LATENCY   = 2,
  parameter int SDRAM_BYTES   = 32 * 1024 * 1024,   // 64 MB parts: 64 * 1024 * 1024
  localparam int MEM_WORD_BITS   = $clog2(MEM_BYTES / 4),
  localparam int SDRAM_WORD_BITS = $clog2(SDRAM_BYTES / 4),
  localparam int ROW_BITS        = 13,
  // Word address = {row, bank, word column}: 9 for 32 MB, 10 for 64 MB.
  localparam int COL_BITS        = SDRAM_WORD_BITS - ROW_BITS - 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        irq_external,
  output logic        sdram_ready,   // SDRAM initialised
  output logic        mem_ready,     // SD card initialised: misses can be served

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
  input  logic [15:0] dq_i,

  output logic        sd_sck,
  output logic        sd_mosi,
  output logic        sd_cs_n,
  input  logic        sd_miso,

  output logic        uart_tx_valid,   // a byte the program sent to the UART
  output logic [7:0]  uart_tx_data
);
  logic        req_valid, req_ready, req_we, wr_ready, rsp_valid;
  logic [29:0] req_addr;
  logic [2:0]  req_len;
  logic [31:0] req_wdata, rsp_rdata;
  logic [3:0]  req_wstrb;

  logic                     mem_req_valid, mem_req_ready, mem_req_we;
  logic                     mem_wr_ready, mem_rsp_valid;
  logic [MEM_WORD_BITS-1:0] mem_req_addr;
  logic [2:0]               mem_req_len;
  logic [31:0]              mem_req_wdata, mem_rsp_rdata;
  logic [3:0]               mem_req_wstrb;

  logic                       dr_req_valid, dr_req_ready, dr_req_we;
  logic                       dr_wr_ready, dr_rsp_valid;
  logic [SDRAM_WORD_BITS-1:0] dr_req_addr;
  logic [2:0]                 dr_req_len;
  logic [31:0]                dr_req_wdata, dr_rsp_rdata;
  logic [3:0]                 dr_req_wstrb;

  logic                     ctrl_sel, clint_sel, uart_sel, dev_we;
  logic [13:0]              dev_addr;
  logic [31:0]              dev_wdata;
  logic [3:0]               dev_wstrb;
  logic [31:0]              ctrl_rdata, clint_rdata, uart_rdata;
  logic [63:0]              mtime;
  logic                     clint_sw, clint_tm;

  cu #(.IC_WAYS(IC_WAYS), .IC_SETS(IC_SETS), .IC_LINE_WORDS(IC_LINE_WORDS),
       .DC_WAYS(DC_WAYS), .DC_SETS(DC_SETS), .DC_LINE_WORDS(DC_LINE_WORDS)) core(
    .iclk(clk),
    .rst_n,
    .irq_software(clint_sw),
    .irq_timer(clint_tm),
    .mtime,
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
    .mem_req_valid, .mem_req_ready, .mem_req_we, .mem_req_addr, .mem_req_len,
    .mem_req_wdata, .mem_req_wstrb, .mem_wr_ready, .mem_rsp_valid, .mem_rsp_rdata,
    .ctrl_sel, .clint_sel, .uart_sel, .dev_we, .dev_addr, .dev_wdata, .dev_wstrb,
    .ctrl_rdata, .clint_rdata, .uart_rdata);

  sd_mem #(.CLK_HZ(CLK_MHZ * 1_000_000), .SDRAM_BYTES(SDRAM_BYTES)) mem(
    .clk, .rst_n,
    .req_valid(mem_req_valid),
    .req_ready(mem_req_ready),
    .req_we(mem_req_we),
    .req_addr(mem_req_addr),
    .req_len(mem_req_len),
    .req_wdata(mem_req_wdata),
    .req_wstrb(mem_req_wstrb),
    .wr_ready(mem_wr_ready),
    .rsp_valid(mem_rsp_valid),
    .rsp_rdata(mem_rsp_rdata),
    .sel(ctrl_sel), .we(dev_we), .addr(dev_addr[9:0]), .rdata(ctrl_rdata),
    .ready(mem_ready),
    .dr_req_valid, .dr_req_ready, .dr_req_we, .dr_req_addr, .dr_req_len,
    .dr_req_wdata, .dr_req_wstrb, .dr_wr_ready, .dr_rsp_valid, .dr_rsp_rdata,
    .sd_sck, .sd_mosi, .sd_cs_n, .sd_miso);

  clint clint0(
    .clk, .rst_n,
    .sel(clint_sel), .we(dev_we), .addr(dev_addr), .wdata(dev_wdata), .wstrb(dev_wstrb),
    .rdata(clint_rdata), .mtime, .irq_software(clint_sw), .irq_timer(clint_tm));

  uart uart0(
    .clk, .rst_n,
    .sel(uart_sel), .we(dev_we), .addr(dev_addr[5:0]), .wdata(dev_wdata), .wstrb(dev_wstrb),
    .rdata(uart_rdata), .tx_valid(uart_tx_valid), .tx_data(uart_tx_data));

  sdram #(.CLK_MHZ(CLK_MHZ), .CAS_LATENCY(CAS_LATENCY), .ROW_BITS(ROW_BITS),
          .COL_BITS(COL_BITS), .MAX_BURST(8)) ram(
    .clk, .rst_n,
    .req_valid(dr_req_valid),
    .req_ready(dr_req_ready),
    .req_we(dr_req_we),
    .req_addr(dr_req_addr),
    .req_len(dr_req_len),
    .req_wdata(dr_req_wdata),
    .req_wstrb(dr_req_wstrb),
    .wr_ready(dr_wr_ready),
    .rsp_valid(dr_rsp_valid),
    .rsp_rdata(dr_rsp_rdata),
    .init_done(sdram_ready),
    .sdram_cke, .sdram_csn, .sdram_rasn, .sdram_casn, .sdram_wen, .sdram_a,
    .sdram_ba, .sdram_dqm, .dq_o, .dq_oe, .dq_i);
endmodule
