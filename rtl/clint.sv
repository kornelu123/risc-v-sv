// Core-local interruptor for the one hart, at the SiFive offsets that Linux's
// riscv,clint0 binding expects (word offsets within the 64 KB window):
//   0x0000  msip        bit 0: machine software interrupt
//   0x4000  mtimecmp    64 bits, lo at 0x4000, hi at 0x4004
//   0xBFF8  mtime       64 bits, lo at 0xBFF8, hi at 0xBFFC
// mtime counts core clock cycles from reset, so the DTS timebase-frequency is
// the core clock (50 MHz). mtimecmp resets to all ones: no timer interrupt
// until software arms it. Byte strobes merge into the 32-bit halves. A write
// to mtime wins over the increment in the same cycle. Reading the two halves
// of mtime is not atomic; a read that straddles a carry can be wrong by 2^32.
module clint (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        sel,
  input  logic        we,
  input  logic [13:0] addr,     // word address within the window
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic [31:0] rdata,
  output logic [63:0] mtime,
  output logic        irq_software,
  output logic        irq_timer
);
  localparam logic [13:0] A_MSIP     = 14'h0000;
  localparam logic [13:0] A_MTIMECMP = 14'h1000;  // 0x4000
  localparam logic [13:0] A_MTIME    = 14'h2FFE;  // 0xBFF8

  logic        msip;
  logic [63:0] mtimecmp;

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] new_, input logic [3:0] strb);
    logic [31:0] r;
    for (int i = 0; i < 4; i++)
      r[8*i +: 8] = strb[i] ? new_[8*i +: 8] : old[8*i +: 8];
    return r;
  endfunction

  assign irq_software = msip;
  assign irq_timer    = mtime >= mtimecmp;

  always_comb begin
    case (addr)
      A_MSIP:              rdata = {31'd0, msip};
      A_MTIMECMP:          rdata = mtimecmp[31:0];
      A_MTIMECMP + 14'd1:  rdata = mtimecmp[63:32];
      A_MTIME:             rdata = mtime[31:0];
      A_MTIME + 14'd1:     rdata = mtime[63:32];
      default:             rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      msip     <= 1'b0;
      mtimecmp <= '1;
      mtime    <= '0;
    end else begin
      mtime <= mtime + 64'd1;
      if (sel && we) begin
        case (addr)
          A_MSIP:              if (wstrb[0]) msip <= wdata[0];
          A_MTIMECMP:          mtimecmp[31:0]  <= merge(mtimecmp[31:0], wdata, wstrb);
          A_MTIMECMP + 14'd1:  mtimecmp[63:32] <= merge(mtimecmp[63:32], wdata, wstrb);
          A_MTIME:             mtime[31:0]     <= merge(mtime[31:0], wdata, wstrb);
          A_MTIME + 14'd1:     mtime[63:32]    <= merge(mtime[63:32], wdata, wstrb);
          default: ;
        endcase
      end
    end
  end
endmodule
