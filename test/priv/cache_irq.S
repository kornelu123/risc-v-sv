# Interrupts while MEM waits for the data cache. Each round raises the timer
# interrupt after a different delay while a loop runs AMOs that miss in the
# data cache (each on a new line), each followed by an independent division,
# which runs in EX meanwhile. The interrupt is taken on the waiting AMO in
# some rounds. Then the AMO must happen exactly once (after MRET), and the
# squashed division must not leak into the handler's division.

#include "riscv_test.h"
#include "test_macros.h"

#define ROUNDS 48
#define ITERS  4

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # RAM starts out with garbage: clear the words the AMOs add to. (Of these
  # lines, the data cache keeps only the last ones, which the loop has
  # evicted again by the time it gets there.)
  la   t0, buf
  li   t1, ROUNDS * ITERS
1:
  sw   zero, 0(t0)
  addi t0, t0, 64
  addi t1, t1, -1
  bnez t1, 1b

  li   a1, 100
  li   a2, 7
  li   s8, 14                    # a1 / a2
  li   s3, 0                     # interrupts taken
  li   s6, 0                     # wrong quotients in the handler
  li   s7, 0                     # wrong quotients in the loop
  li   s9, 1
  la   s0, buf
  li   t0, MIP_MTIP
  csrw mie, t0
  csrsi mstatus, MSTATUS_MIE

  li   s10, 0                    # this round's delay
round:
  slli t0, s10, 16
  ori  t0, t0, MIP_MTIP
  sw   t0, irq_lines, t1
  li   s11, ITERS
1:
  amoadd.w zero, s9, (s0)
  div  a3, a1, a2
  addi s0, s0, 64
  sub  t2, a3, s8
  snez t2, t2
  add  s7, s7, t2
  addi s11, s11, -1
  bnez s11, 1b
  addi s10, s10, 1
  li   t0, ROUNDS
  bne  s10, t0, round
  csrci mstatus, MSTATUS_MIE

  TEST_CASE( 2, s3, ROUNDS, )
  TEST_CASE( 3, s7, 0, )
  TEST_CASE( 4, s6, 0, )
  # Every word the AMOs touched is 1.
  TEST_CASE( 5, a0, ROUNDS * ITERS, \
    la t0, buf; li t1, ROUNDS * ITERS; li a0, 0; \
    1: lw t2, 0(t0); add a0, a0, t2; addi t0, t0, 64; addi t1, t1, -1; bnez t1, 1b)

  TEST_PASSFAIL

  # Uses only t5/t6, which the environment's trap vector clobbers anyway.
  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr t5, mcause
  bgez t5, fail                  # only interrupts are expected
  sw   zero, irq_lines, t5       # lower every line
  li   t5, 91
  li   t6, 7
  div  t5, t5, t6
  addi t5, t5, -13
  snez t5, t5
  add  s6, s6, t5
  addi s3, s3, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  .align 2
  .globl irq_lines
irq_lines: .word 0

RVTEST_DATA_END

  .bss
  .align 6
buf: .space ROUNDS * ITERS * 64
