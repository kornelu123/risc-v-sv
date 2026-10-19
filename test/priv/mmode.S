# Machine-mode checks that rv32mi skips or allows either way on an M-only
# hart. Built with the official riscv-tests "p" environment, like rv32mi.

#include "riscv_test.h"
#include "test_macros.h"

# Address that no memory or device will ever answer in this SoC.
#define UNMAPPED 0x40000000

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # The instruction in `insn` (exactly one) must trap with this mcause and
  # mtval, with mepc pointing at it. mtvec_handler below records the trap
  # in s2..s5 and resumes after the instruction.
  .macro expect_trap testnum, cause, tval, insn:vararg
    li   TESTNUM, \testnum
    li   s2, -1
1:  \insn
    li   t0, \cause
    bne  s2, t0, fail
    li   t0, \tval
    bne  s3, t0, fail
    la   t0, 1b
    bne  s4, t0, fail
  .endm

  # misa: MXL = 1 (RV32), I and M present.
  TEST_CASE( 2, a0, 0x40001100, csrr a0, misa; li a1, 0xC0001100; and a0, a0, a1)
  # mstatus.MPP is hard-wired to M (3) when there is no U mode.
  TEST_CASE( 3, a0, 3, csrr a0, mstatus; srli a0, a0, 11; andi a0, a0, 3)

  # Writes to read-only CSRs (addr[11:10] = 11) are illegal.
  expect_trap  4, CAUSE_ILLEGAL_INSTRUCTION, 0xc0001073, .word 0xc0001073  # csrrw x0, cycle, x0
  expect_trap  5, CAUSE_ILLEGAL_INSTRUCTION, 0xf1101073, .word 0xf1101073  # csrrw x0, mvendorid, x0
  li a0, 1
  expect_trap  6, CAUSE_ILLEGAL_INSTRUCTION, 0xf1452073, .word 0xf1452073  # csrrs x0, mhartid, a0

  # Unimplemented CSRs are illegal and leave rd unchanged.
  li a0, 0x55
  expect_trap  7, CAUSE_ILLEGAL_INSTRUCTION, 0x18002573, .word 0x18002573  # csrr a0, satp
  TEST_CASE( 8, a0, 0x55, )

  # Access faults report the address in mtval; the store does not happen,
  # the load does not write rd.
  li a0, UNMAPPED
  li a1, 0x77
  expect_trap  9, CAUSE_STORE_ACCESS, UNMAPPED, sw a1, 0(a0)
  expect_trap 10, CAUSE_LOAD_ACCESS,  UNMAPPED, lw a1, 0(a0)
  TEST_CASE(11, a1, 0x77, )

  # Trap entry: MPIE <- MIE, MIE <- 0. MRET: MIE <- MPIE, MPIE <- 1.
  csrsi mstatus, MSTATUS_MIE
  expect_trap 12, CAUSE_ILLEGAL_INSTRUCTION, 0, .word 0
  TEST_CASE(13, a0, MSTATUS_MPIE, andi a0, s5, MSTATUS_MIE | MSTATUS_MPIE)
  TEST_CASE(14, a0, MSTATUS_MIE | MSTATUS_MPIE, csrr a0, mstatus; andi a0, a0, MSTATUS_MIE | MSTATUS_MPIE)
  csrci mstatus, MSTATUS_MIE

  # mepc has no low bits without the C extension.
  TEST_CASE(15, a1, 0x100, li a0, 0x103; csrw mepc, a0; csrr a1, mepc)

  # minstret counts retired instructions; a read returns the count before
  # the reading instruction retires: csrr + nop + nop = 3.
  TEST_CASE(16, a0, 3, csrr a1, minstret; nop; nop; csrr a0, minstret; sub a0, a0, a1)
  # A write to minstret replaces that instruction's own increment.
  TEST_CASE(17, a0, 5, csrwi minstret, 5; csrr a0, minstret)
  # mcycle advances.
  TEST_CASE(18, a0, 1, csrr a1, mcycle; nop; csrr a0, mcycle; sltu a0, a1, a0)

  # Tests 19-20 trap straight to label 1 (no handler, no MRET).
  # An instruction that traps does not retire: only the first csrr counts.
  TEST_CASE(19, a0, 1, la t0, 1f; csrrw s6, mtvec, t0; csrr a1, minstret; \
                       .word 0; 1: csrr a0, minstret; csrw mtvec, s6; sub a0, a0, a1)
  # A store behind a trapping instruction is squashed.
  TEST_CASE(20, a0, 0, la a2, tdat; sw zero, 0(a2); li a1, 1; la t0, 1f; \
                       csrrw s6, mtvec, t0; .word 0; sw a1, 0(a2); 1: csrw mtvec, s6; lw a0, 0(a2))

  # Performance counters and event selectors: read-only 0, writes ignored.
  TEST_CASE(21, a0, 0, li a0, -1; csrw mhpmcounter3, a0; csrr a0, mhpmcounter3)
  TEST_CASE(22, a0, 0, li a0, -1; csrw mhpmcounter31h, a0; csrr a0, mhpmcounter31h)
  TEST_CASE(23, a0, 0, li a0, -1; csrw mhpmevent3, a0; csrr a0, mhpmevent3)
  TEST_CASE(24, a0, 0, li a0, -1; csrw mhpmevent31, a0; csrr a0, mhpmevent31)
  # mconfigptr (0xf15) exists, reads 0 (no configuration structure) and is
  # read-only.
  TEST_CASE(25, a0, 0, li a0, -1; csrr a0, 0xf15)
  expect_trap 26, CAUSE_ILLEGAL_INSTRUCTION, 0xf1501073, .word 0xf1501073  # csrrw x0, mconfigptr, x0
  # Just outside those ranges there are no CSRs.
  expect_trap 27, CAUSE_ILLEGAL_INSTRUCTION, 0xb0102573, .word 0xb0102573  # csrr a0, 0xb01
  expect_trap 28, CAUSE_ILLEGAL_INSTRUCTION, 0xb2002573, .word 0xb2002573  # csrr a0, 0xb20
  expect_trap 29, CAUSE_ILLEGAL_INSTRUCTION, 0x32202573, .word 0x32202573  # csrr a0, 0x322
  expect_trap 30, CAUSE_ILLEGAL_INSTRUCTION, 0xf1602573, .word 0xf1602573  # csrr a0, 0xf16

  TEST_PASSFAIL

  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr s2, mcause
  csrr s3, mtval
  csrr s4, mepc
  csrr s5, mstatus
  addi t0, s4, 4
  csrw mepc, t0
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
tdat: .word 0

RVTEST_DATA_END
