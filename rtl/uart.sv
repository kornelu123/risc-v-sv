// Minimal ns16550a-compatible UART: the register subset Linux's 8250 driver
// uses for polled output. Registers are bytes at the start of the window
// (rtl/memmap.sv); a word access takes each byte lane as its own register:
//   0  THR (write: transmit the byte)  RBR (read: 0, nothing is received)
//      with DLAB=1: DLL, divisor latch low
//   1  IER                             with DLAB=1: DLM, divisor latch high
//   2  IIR (read: 0x01, no interrupt, no FIFO)     FCR (write: ignored)
//   3  LCR (bit 7 is DLAB)
//   4  MCR
//   5  LSR (read: 0x60, transmitter empty and idle; read-only)
//   6  MSR (read: 0; read-only)
//   7  SCR (scratch)
// Transmission is instant: tx_valid pulses for one cycle with the byte. There
// is no receive side, no interrupt output (the PLIC comes later), and the
// divisor has no effect on timing. A word store writes each of its byte lanes
// separately, and DLAB is read as it was before that store.
module uart (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        sel,
  input  logic        we,
  input  logic [5:0]  addr,       // word address within the window
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic [31:0] rdata,
  output logic        tx_valid,   // one cycle per transmitted byte
  output logic [7:0]  tx_data
);
  logic [7:0] ier, lcr, mcr, scr, dll, dlm;
  wire        dlab = lcr[7];

  // Only words 0 and 1 (bytes 0..7) hold registers.
  wire in_regs = addr[5:1] == 5'd0;

  always_comb begin
    rdata = 32'd0;
    if (sel && in_regs)
      for (int b = 0; b < 4; b++)
        case ({addr[0], 2'(b)})
          3'd0:    rdata[8*b +: 8] = dlab ? dll : 8'd0;
          3'd1:    rdata[8*b +: 8] = dlab ? dlm : ier;
          3'd2:    rdata[8*b +: 8] = 8'h01;
          3'd3:    rdata[8*b +: 8] = lcr;
          3'd4:    rdata[8*b +: 8] = mcr;
          3'd5:    rdata[8*b +: 8] = 8'h60;
          3'd6:    rdata[8*b +: 8] = 8'd0;
          default: rdata[8*b +: 8] = scr;
        endcase
  end

  always_ff @(posedge clk) begin
    tx_valid <= 1'b0;
    if (!rst_n) begin
      ier <= '0;
      lcr <= '0;
      mcr <= '0;
      scr <= '0;
      dll <= '0;
      dlm <= '0;
    end else if (sel && we && in_regs) begin
      for (int b = 0; b < 4; b++)
        if (wstrb[b])
          case ({addr[0], 2'(b)})
            3'd0: if (dlab) dll <= wdata[8*b +: 8];
                  else begin
                    tx_valid <= 1'b1;
                    tx_data  <= wdata[8*b +: 8];
                  end
            3'd1: if (dlab) dlm <= wdata[8*b +: 8];
                  else      ier <= wdata[8*b +: 8];
            3'd3: lcr <= wdata[8*b +: 8];
            3'd4: mcr <= wdata[8*b +: 8];
            3'd7: scr <= wdata[8*b +: 8];
            default: ;   // FCR, LSR, MSR: not writable here
          endcase
    end
  end
endmodule
