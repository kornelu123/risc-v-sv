# Machine-mode interrupts. The timer and software interrupts come from the
# CLINT (mtimecmp and msip, rtl/clint.sv). The external interrupt is driven by
# the testbench from bit 11 of `irq_lines` (standing in for the PLIC).

#include "riscv_test.h"
#include "test_macros.h"

  # CLINT registers (rtl/clint.sv). mtime and mtimecmp are 64-bit: lo, then hi.
  .equ MSIP,     0x02000000
  .equ MTIMECMP, 0x02004000
  .equ MTIME,    0x0200BFF8

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # Set the software, timer and external lines; the core sees the change a
  # cycle later. The timer line is mtimecmp = 0 (pending) or all ones.
  .macro set_lines bits
    li   t1, MSIP
    li   t0, ((\bits) >> 3) & 1
    sw   t0, 0(t1)
    li   t1, MTIMECMP
    li   t0, (((\bits) >> 7) & 1) - 1
    sw   t0, 4(t1)
    sw   t0, 0(t1)
    li   t0, (\bits) & MIP_MEIP
    sw   t0, irq_lines, t1
    nop
    nop
  .endm

  # Timer interrupt `delay` cycles from now: mtimecmp = mtime + delay. The
  # high half is disarmed first, so a stale low half cannot fire early.
  .macro timer_in delay
    li   t1, MTIMECMP
    li   t0, -1
    sw   t0, 4(t1)
    li   t1, MTIME
    lw   t0, 0(t1)
    addi t0, t0, \delay
    li   t1, MTIMECMP
    sw   t0, 0(t1)
    sw   zero, 4(t1)
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
  csrci mstatus, MSTATUS_MIE    # raise the lines with MIE clear, or the first write traps alone
  set_lines MIP_MSIP | MIP_MTIP | MIP_MEIP
  csrsi mstatus, MSTATUS_MIE
  TEST_CASE(13, s2, 0x8000000b, nop; nop; nop; nop)
  TEST_CASE(14, s3, 1, )
  csrci mstatus, MSTATUS_MIE
  set_lines MIP_MSIP | MIP_MTIP
  csrsi mstatus, MSTATUS_MIE
  TEST_CASE(15, s2, 0x80000003, nop; nop; nop; nop)

  # WFI with an interrupt pending but MIE = 0 does not hang.
  csrci mstatus, MSTATUS_MIE
  set_lines MIP_MTIP
  TEST_CASE(16, a0, 1, li a0, 0; wfi; li a0, 1)
  set_lines 0

  # mip's machine bits are read-only: writes are ignored.
  TEST_CASE(17, a0, 0, li a0, -1; csrw mip, a0; nop; nop; csrr a0, mip)

  # WFI sleeps until an enabled interrupt arrives (200 cycles later); the
  # interrupt is taken on the instruction after WFI (mepc = pc + 4). A WFI
  # that does not wait would reach wfi_next before the interrupt arrives.
  csrsi mstatus, MSTATUS_MIE
  li   s3, 0
  timer_in 200
  wfi
wfi_next:
  mv   a0, s3
  TEST_CASE(18, a0, 1, )
  TEST_CASE(19, a1, 0, la t0, wfi_next; sub a1, s4, t0)

  # With MIE = 0, WFI still wakes up when an enabled interrupt becomes pending
  # and continues without a trap. Elapsed time is read from the time CSR (mtime).
  csrci mstatus, MSTATUS_MIE
  li   s3, 0
  csrr s6, time
  timer_in 200
  wfi
  csrr a1, time
  TEST_CASE(20, a0, 0, sub a1, a1, s6; sltiu a0, a1, 200)   # slept >= 200 cycles
  TEST_CASE(21, s3, 0, )
  TEST_CASE(22, a0, MIP_MTIP, csrr a0, mip; andi a0, a0, MIP_MTIP)
  set_lines 0

  # WFI keeps sleeping while only a non-enabled interrupt is pending (the
  # software interrupt is pending throughout; mie enables only the timer,
  # which arrives 200 cycles later). The spec only says "should" here.
  li   t0, MIP_MTIP
  csrw mie, t0
  set_lines MIP_MSIP
  csrr s6, time
  timer_in 200
  wfi
  csrr a1, time
  TEST_CASE(23, a0, 0, sub a1, a1, s6; sltiu a0, a1, 200)   # slept >= 200 cycles
  set_lines 0

  TEST_PASSFAIL

  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr s2, mcause
  bgez s2, fail                  # only interrupts are expected
  csrr s4, mepc
  csrr s5, mstatus
  li   t5, MSIP                  # lower every line
  sw   zero, 0(t5)
  li   t5, MTIMECMP
  li   t6, -1
  sw   t6, 4(t5)
  sw   t6, 0(t5)
  sw   zero, irq_lines, t5
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
