# Pipeline hazards around the multi-cycle divider, which rv32um does not
# cover: forwarding into and out of a division, a load feeding a division,
# back-to-back dependent divisions, and a division squashed by an older
# trapping instruction.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # Result forwarded to the next instructions (0, 1, 2 instructions later).
  TEST_RR_DEST_BYPASS( 2, 0, div,   3,  20,  6 );
  TEST_RR_DEST_BYPASS( 3, 1, divu,  3,  20,  6 );
  TEST_RR_DEST_BYPASS( 4, 2, rem,   2,  20,  6 );
  TEST_RR_DEST_BYPASS( 5, 0, remu,  2,  20,  6 );

  # Operands forwarded into the division.
  TEST_RR_SRC12_BYPASS( 6, 0, 0, div,  -3, -20,  6 );
  TEST_RR_SRC12_BYPASS( 7, 0, 1, rem,  -2, -20,  6 );
  TEST_RR_SRC21_BYPASS( 8, 0, 0, divu,  3,  20,  6 );
  TEST_RR_SRC21_BYPASS( 9, 1, 0, remu,  2,  20,  6 );

  # A load whose value the division uses right away (load-use stall).
  TEST_CASE(10, a4, 4, la a1, tdat; li a3, 40; lw a2, 0(a1); div a4, a3, a2)

  # Back-to-back dependent divisions: 100 / 5 = 20, 20 / 10 = 2.
  TEST_CASE(11, a4, 2, li a1, 100; li a2, 5; li a5, 10; div a3, a1, a2; div a4, a3, a5)

  # Quotient used by a branch right away.
  TEST_CASE(12, a4, 7, li a1, 49; li a2, 7; li a4, 0; div a3, a1, a2; \
                       bne a3, a2, 1f; li a4, 7; 1:)

  # Quotient used as store data right away.
  TEST_CASE(13, a4, 6, la a1, tdat2; li a2, 36; li a3, 6; div a3, a2, a3; \
                       sw a3, 0(a1); lw a4, 0(a1))

  # A division behind an older trapping instruction is squashed; the
  # division in the trap handler (label 1) must not see its operands.
  TEST_CASE(14, a4, 10, la t0, 1f; csrw mtvec, t0; li a1, 100; li a2, 7; \
                        .word 0; div a3, a1, a2; \
                        1: li a1, 50; li a2, 5; div a4, a1, a2)

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
tdat:  .word 10
tdat2: .word 0

RVTEST_DATA_END
