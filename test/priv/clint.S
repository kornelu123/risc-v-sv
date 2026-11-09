# CLINT (rtl/clint.sv): msip, mtimecmp, mtime, and the time and timeh CSRs
# that read mtime.

#include "riscv_test.h"
#include "test_macros.h"
#include "expect_trap.h"

  .equ MSIP,      0x02000000
  .equ MTIMECMP,  0x02004000
  .equ MTIME,     0x0200BFF8
  .equ CLINT_END, 0x02010000     # first address past the window

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # Reset: msip clear, mtimecmp all ones (no timer pending).
  TEST_CASE( 2, a0, 0, li t1, MSIP; lw a0, 0(t1))
  TEST_CASE( 3, a0, -1, li t1, MTIMECMP; lw a0, 0(t1))
  TEST_CASE( 4, a0, -1, li t1, MTIMECMP; lw a0, 4(t1))

  # msip: bit 0 is the software interrupt; the other bits are not stored.
  TEST_CASE( 5, a0, 1, li t1, MSIP; li t0, 1; sw t0, 0(t1); lw a0, 0(t1))
  TEST_CASE( 6, a0, MIP_MSIP, csrr a0, mip; andi a0, a0, MIP_MSIP)
  TEST_CASE( 7, a0, 0, li t1, MSIP; li t0, -2; sw t0, 0(t1); lw a0, 0(t1))
  TEST_CASE( 8, a0, 0, csrr a0, mip; andi a0, a0, MIP_MSIP)

  # mtime counts up.
  TEST_CASE( 9, a0, 1, li t1, MTIME; lw a1, 0(t1); nop; nop; nop; nop; \
                       lw a0, 0(t1); sltu a0, a1, a0)

  # mtime can be written; it keeps counting from the written value.
  TEST_CASE(10, a0, 9, li t1, MTIME; li t0, 0x12345678; sw t0, 0(t1); \
                       li t0, 9; sw t0, 4(t1); lw a0, 4(t1))
  TEST_CASE(11, a0, 1, li t1, MTIME; li a1, 0x12345678; lw a0, 0(t1); \
                       sub a0, a0, a1; sltiu a0, a0, 1000)

  # The time CSR reads mtime (timeh: the high word).
  TEST_CASE(12, a0, 9, csrr a0, timeh)
  TEST_CASE(13, a0, 1, li t1, MTIME; lw a1, 0(t1); csrr a0, time; \
                       sub a0, a0, a1; sltiu a0, a0, 64)

  # mtimecmp at or below mtime raises MTIP; all ones clears it.
  TEST_CASE(14, a0, MIP_MTIP, li t1, MTIMECMP; li t0, 0; sw t0, 4(t1); \
                       sw t0, 0(t1); csrr a0, mip; andi a0, a0, MIP_MTIP)
  TEST_CASE(15, a0, 0, li t1, MTIMECMP; li t0, -1; sw t0, 4(t1); \
                       sw t0, 0(t1); csrr a0, mip; andi a0, a0, MIP_MTIP)

  # mtimecmp above mtime (by 1M cycles) is not pending.
  TEST_CASE(16, a0, 0, li t1, MTIMECMP; li t0, 9; sw t0, 4(t1); \
                       li t0, 0x12445678; sw t0, 0(t1); \
                       csrr a0, mip; andi a0, a0, MIP_MTIP)

  # A byte store changes only its byte.
  TEST_CASE(17, a0, 0xFFFFFF12, li t1, MTIMECMP; li t0, -1; sw t0, 0(t1); \
                       li t0, 0x12; sb t0, 0(t1); lw a0, 0(t1))

  # Just past the window nothing is mapped.
  li   a0, CLINT_END
  expect_trap 18, CAUSE_LOAD_ACCESS, CLINT_END, lw a1, 0(a0)

  TEST_PASSFAIL

  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr s2, mcause
  csrr s3, mtval
  csrr s4, mepc
  addi t0, s4, 4
  csrw mepc, t0
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
