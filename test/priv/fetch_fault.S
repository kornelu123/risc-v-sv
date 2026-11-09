# Instruction access faults: a fetch outside memory traps with
# CAUSE_FETCH_ACCESS and mtval = mepc = the fetched address. A fall-through
# fetch past the end of RAM is squashed by a jump in EX and never traps.
# Built with the official riscv-tests "p" environment, like mmode.S.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # Jump to `addr`. The fetch traps and control goes straight to label 1
  # (no handler, no MRET), where the trap registers are checked.
  .macro fetch_fault testnum, addr
    li   TESTNUM, \testnum
    la   t0, 1f
    csrrw s6, mtvec, t0
    li   t1, \addr
    jr   t1
1:  csrr t2, mcause
    csrr t3, mtval
    csrr t4, mepc
    csrw mtvec, s6
    li   t5, CAUSE_FETCH_ACCESS
    bne  t2, t5, fail
    li   t5, \addr
    bne  t3, t5, fail
    bne  t4, t5, fail
  .endm

  fetch_fault 2, 0x00000000   # address 0: no memory there
  fetch_fault 3, 0x10001000   # device window (memory controller registers)
  fetch_fault 4, 0x40000000   # unmapped
  fetch_fault 5, 0x90000000   # first address past the end of RAM

  # A jump in the last word of RAM. Its fall-through fetch at 0x9000_0000 is
  # a fetch fault that sits in ID when the jump resolves in EX: it must be
  # squashed, not trap. The jump is `jalr x0, 0(t3)` (t3 = x28) at 0x8fff_fffc,
  # written by a store and made visible to fetch with FENCE.I.
  li   TESTNUM, 6
  la   t5, bad                # any trap now is a failure
  csrrw s7, mtvec, t5
  li   t0, 0x8ffffffc
  li   t1, 0x000e0067
  sw   t1, 0(t0)
  fence.i
  la   t3, 2f
  jr   t0
2:
  csrw mtvec, s7

  TEST_PASSFAIL

bad:
  j fail

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
