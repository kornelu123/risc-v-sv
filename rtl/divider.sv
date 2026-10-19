// Iterative restoring divider for DIV/DIVU/REM/REMU: one quotient bit per
// cycle on the operand magnitudes, signs applied at the end. A division takes
// 34 cycles (start, 32 steps, done). EX stalls while it runs.
module divider import isa::*; (
  input  logic          clk,
  input  logic          rst_n,
  input  bit            start,     // begin a / b; only acted on when idle
  input  bit            consume,   // EX takes the result and moves on
  input  operation_type op,        // ALU_DIV, ALU_DIVU, ALU_REM or ALU_REMU
  input  bit [31:0]     a,
  input  bit [31:0]     b,
  output bit            done,
  output bit [31:0]     result
);
  typedef enum bit [1:0] { IDLE, BUSY, DONE } state_t;

  state_t    state;
  bit [4:0]  step;
  bit [31:0] q;          // dividend magnitude, shifted out as quotient bits come in
  bit [31:0] r;          // partial remainder
  bit [31:0] divisor;    // divisor magnitude
  bit [32:0] shifted;
  bit        is_rem, neg_q, neg_r, by_zero;
  bit [31:0] dividend;   // original a, the remainder of a division by zero

  bit        signed_op, neg_a, neg_b;

  assign signed_op = op == ALU_DIV || op == ALU_REM;
  assign neg_a     = signed_op && a[31];
  assign neg_b     = signed_op && b[31];
  assign shifted   = {r, q[31]};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      case (state)
        IDLE: if (start) begin
          q        <= neg_a ? -a : a;
          r        <= 32'd0;
          divisor  <= neg_b ? -b : b;
          step     <= 5'd0;
          is_rem   <= op == ALU_REM || op == ALU_REMU;
          neg_q    <= neg_a ^ neg_b;
          neg_r    <= neg_a;
          by_zero  <= b == 32'd0;
          dividend <= a;
          state    <= BUSY;
        end
        BUSY: begin
          if (shifted >= {1'b0, divisor}) begin
            r <= 32'(shifted - {1'b0, divisor});
            q <= {q[30:0], 1'b1};
          end else begin
            r <= shifted[31:0];
            q <= {q[30:0], 1'b0};
          end
          step <= step + 5'd1;
          if (step == 5'd31) state <= DONE;
        end
        DONE: if (consume) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end

  // Division by zero: quotient all ones, remainder = dividend. Overflow
  // (-2^31 / -1) needs no special case: the magnitudes give 2^31 rem 0.
  assign done   = state == DONE;
  assign result = by_zero ? (is_rem ? dividend : 32'hFFFFFFFF) :
                  is_rem  ? (neg_r ? -r : r) : (neg_q ? -q : q);
endmodule
