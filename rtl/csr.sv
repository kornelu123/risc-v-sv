module csr import isa::*; (
  input  logic       clk,
  input  logic       rst_n,

  input  bit         access,
  input  bit [11:0]  addr,
  input  bit [1:0]   op,
  input  bit [31:0]  src,
  input  bit         write,
  input  bit         retire,
  output bit [31:0]  rdata,
  output bit         illegal,

  input  bit         trap,
  input  bit [31:0]  trap_pc,
  input  bit [31:0]  trap_cause,
  input  bit [31:0]  trap_tval,
  input  bit         mret,
  output bit [31:0]  mtvec,
  output bit [31:0]  mepc,

  input  bit         irq_software,
  input  bit         irq_timer,
  input  bit         irq_external,
  output bit         irq,         // an enabled interrupt is pending and MIE = 1
  output bit [31:0]  irq_cause
);
  bit [31:0] mip, pending;
  bit        mstatus_mie, mstatus_mpie;
  bit [31:0] mie, mscratch, mcause, mtval;
  bit [63:0] mcycle, minstret;

  bit        known;
  bit [31:0] wdata;
  bit        do_write;

  always_comb begin
    known = 1'b1;
    case (addr)
      CSR_MSTATUS:   rdata = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
      CSR_MISA:      rdata = MISA_VALUE;
      CSR_MIE:       rdata = mie;
      CSR_MTVEC:     rdata = mtvec;
      CSR_MSTATUSH:  rdata = 32'd0;
      CSR_MSCRATCH:  rdata = mscratch;
      CSR_MEPC:      rdata = mepc;
      CSR_MCAUSE:    rdata = mcause;
      CSR_MTVAL:     rdata = mtval;
      CSR_MIP:       rdata = mip;
      CSR_MCYCLE,
      CSR_CYCLE,
      CSR_TIME:      rdata = mcycle[31:0];
      CSR_MCYCLEH,
      CSR_CYCLEH,
      CSR_TIMEH:     rdata = mcycle[63:32];
      CSR_MINSTRET,
      CSR_INSTRET:   rdata = minstret[31:0];
      CSR_MINSTRETH,
      CSR_INSTRETH:  rdata = minstret[63:32];
      CSR_MVENDORID,
      CSR_MARCHID,
      CSR_MIMPID,
      CSR_MHARTID:   rdata = 32'd0;
      default: begin
        rdata = 32'd0;
        known = 1'b0;
      end
    endcase

    illegal = !known || (write && addr[11:10] == 2'b11);

    case (op)
      FUNCT3_CSRRS[1:0]: wdata = rdata | src;
      FUNCT3_CSRRC[1:0]: wdata = rdata & ~src;
      default:           wdata = src;
    endcase
  end

  // mip's machine bits mirror the interrupt inputs (read-only).
  assign mip     = {20'd0, irq_external, 3'd0, irq_timer, 3'd0, irq_software, 3'd0};
  assign pending = mip & mie;
  assign irq     = mstatus_mie && pending != 32'd0;

  // Priority: external > software > timer.
  always_comb begin
    if      (pending[11]) irq_cause = 32'h8000000B;
    else if (pending[3])  irq_cause = 32'h80000003;
    else                  irq_cause = 32'h80000007;
  end

  assign do_write = access && write && !illegal;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie          <= 32'd0;
      mtvec        <= 32'd0;
      mscratch     <= 32'd0;
      mepc         <= 32'd0;
      mcause       <= 32'd0;
      mtval        <= 32'd0;
      mcycle       <= 64'd0;
      minstret     <= 64'd0;
    end else begin
      mcycle <= mcycle + 64'd1;
      if (retire) minstret <= minstret + 64'd1;

      if (trap) begin
        mepc         <= trap_pc;
        mcause       <= trap_cause;
        mtval        <= trap_tval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
      end else if (mret) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end else if (do_write) begin
        case (addr)
          CSR_MSTATUS: begin
            mstatus_mie  <= wdata[3];
            mstatus_mpie <= wdata[7];
          end
          CSR_MIE:       mie      <= wdata & MIE_MASK;
          CSR_MTVEC:     mtvec    <= {wdata[31:2], 2'b00};
          CSR_MSCRATCH:  mscratch <= wdata;
          CSR_MEPC:      mepc     <= {wdata[31:2], 2'b00};
          CSR_MCAUSE:    mcause   <= wdata;
          CSR_MTVAL:     mtval    <= wdata;
          CSR_MCYCLE:    mcycle   <= {mcycle[63:32], wdata};
          CSR_MCYCLEH:   mcycle   <= {wdata, mcycle[31:0]};
          CSR_MINSTRET:  minstret <= {minstret[63:32], wdata};
          CSR_MINSTRETH: minstret <= {wdata, minstret[31:0]};
          default: ;
        endcase
      end
    end
  end
endmodule
