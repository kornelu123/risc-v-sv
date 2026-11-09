# FENCE.I with self-modifying code close behind the store. When the store
# commits, the next two instructions (FENCE.I and the rewritten one) are
# already in the pipeline; FENCE.I must refetch so the new encoding runs.
# The official rv32ui/fence_i test rewrites code far away from the stores,
# which a core without an instruction cache gets right even without the flush.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # Replace `addi a0, zero, 1` at label 1 with `addi a0, zero, 2`.
  TEST_CASE( 2, a0, 2, la t0, 1f; la t2, new_insn; lw t1, 0(t2); \
                       sw t1, 0(t0); fence.i; \
                       1: addi a0, zero, 1)

  # Same, with one instruction between the store and FENCE.I.
  TEST_CASE( 3, a0, 2, la t0, 1f; la t2, new_insn; lw t1, 0(t2); \
                       sw t1, 0(t0); nop; fence.i; \
                       1: addi a0, zero, 1)

  TEST_PASSFAIL

  # Never executed: only its encoding is copied.
new_insn:
  addi a0, zero, 2

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
