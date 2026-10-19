# Machine-mode interrupts. The testbench drives the software, timer and
# external interrupt inputs from bits 3/7/11 of `irq_lines` (the mip bit
# layout), standing in for the CLINT and PLIC.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # Set the interrupt lines; the core sees the change a cycle later.
  .macro set_lines bits
    li   t0, \bits
    sw   t0, irq_lines, t1
    nop
    nop
  .endm

  li   s3, 0                     # number of interrupts taken
  csrw mie, zero
  csrsi mstatus, MSTATUS_MIE

  # Pending shows in mip, but nothing is taken while mie disables it.
  set_lines MIP_MTIP
  TEST_CASE( 2, a0, MIP_MTIP, nop; nop; nop; nop; csrr a0, mip; andi a0, a0, MIP_MTIP)
  TEST_CASE( 3, s3, 0, )

  # Enabled in mie, but nothing is taken while mstatus.MIE = 0.
  csrci mstatus, MSTATUS_MIE
  li   t0, MIP_MTIP
  csrw mie, t0
  TEST_CASE( 4, s3, 0, nop; nop; nop; nop)

  # Setting MIE takes the pending timer interrupt. The interrupted
  # instruction is not executed before the trap and runs exactly once
  # after MRET, so a0 counts all eight additions.
  li   a0, 0
  csrsi mstatus, MSTATUS_MIE
irq_window:
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
irq_window_end:
  TEST_CASE( 5, s3, 1, )
  TEST_CASE( 6, a0, 8, )
  TEST_CASE( 7, s2, 0x80000007, )
  # mepc is one of the instructions in the window: 8 instructions, so an
  # offset of 0..32 counting irq_window_end.
  TEST_CASE( 8, a1, 1, la t0, irq_window; sub a1, s4, t0; sltiu a1, a1, 33)
  # Inside the handler MIE = 0, MPIE = 1; MRET restores MIE.
  TEST_CASE( 9, a1, MSTATUS_MPIE, andi a1, s5, MSTATUS_MIE | MSTATUS_MPIE)
  TEST_CASE(10, a1, MSTATUS_MIE | MSTATUS_MPIE, csrr a1, mstatus; \
                    andi a1, a1, MSTATUS_MIE | MSTATUS_MPIE)

  # Software and external interrupt causes.
  li   t0, MIP_MSIP | MIP_MTIP | MIP_MEIP
  csrw mie, t0
  set_lines MIP_MSIP
  TEST_CASE(11, s2, 0x80000003, nop; nop; nop; nop)
  set_lines MIP_MEIP
  TEST_CASE(12, s2, 0x8000000b, nop; nop; nop; nop)

  # Priority: external > software > timer. The handler lowers every line,
  # so only the first interrupt is taken.
  li   s3, 0
  set_lines MIP_MSIP | MIP_MTIP | MIP_MEIP
  TEST_CASE(13, s2, 0x8000000b, nop; nop; nop; nop)
  TEST_CASE(14, s3, 1, )
  set_lines MIP_MSIP | MIP_MTIP
  TEST_CASE(15, s2, 0x80000003, nop; nop; nop; nop)

  # WFI with an interrupt pending but MIE = 0 does not hang.
  csrci mstatus, MSTATUS_MIE
  set_lines MIP_MTIP
  TEST_CASE(16, a0, 1, li a0, 0; wfi; li a0, 1)
  set_lines 0

  # mip's machine bits are read-only: writes are ignored.
  TEST_CASE(17, a0, 0, li a0, -1; csrw mip, a0; nop; nop; csrr a0, mip)

  TEST_PASSFAIL

  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr s2, mcause
  bgez s2, fail                  # only interrupts are expected
  csrr s4, mepc
  csrr s5, mstatus
  sw   zero, irq_lines, t5       # lower every line
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
