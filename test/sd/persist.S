# Main memory on the SD card (rtl/sd_mem.sv). `make sd-tests` boots this
# program twice from the same disk image: first from an image holding just
# the program, then from the image the first run left behind (no other
# loading). Each boot counts itself in `boot_count`, checks what the
# previous boot left in memory, writes three blocks that share one SDRAM
# slot (and one data cache set), so writing them evicts dirty blocks to the
# card and reads them back from it, and finally syncs: FENCE.I (writes back
# the data cache), FLUSH, wait. The Makefile then expects boot_count = 2 in
# the image.

#include "riscv_test.h"
#include "test_macros.h"

#define CTRL       0x10001000
#define REG_STATUS 0
#define REG_FLUSH  4
#define ST_READY   1
#define ST_BUSY    2
#define ST_ERROR   4
#define AREA       0x80010000    // past the program
#define FAR        0x02000000    // the SDRAM's size: the same slot

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # Word i of block k (at AREA + k * FAR) is (k << 28) + i * 0x01000193.
  # \op: `sw` writes the pattern; `lw` adds the number of words that differ
  # to a0. Uses t2-t6.
  .macro blocks op
    li   t2, AREA
    li   t3, 0
1:  li   t4, 0
2:  slli t5, t3, 28
    li   t6, 0x01000193
    mul  t6, t6, t4
    add  t5, t5, t6
    slli t6, t4, 2
    add  t6, t6, t2
    .ifc \op, sw
    sw   t5, 0(t6)
    .else
    lw   t6, 0(t6)
    sub  t5, t5, t6
    snez t5, t5
    add  a0, a0, t5
    .endif
    addi t4, t4, 1
    li   t5, 128
    bne  t4, t5, 2b
    li   t5, FAR
    add  t2, t2, t5
    addi t3, t3, 1
    li   t5, 3
    bne  t3, t5, 1b
  .endm

  li   s0, CTRL
  la   s1, boot_count
  lw   s2, 0(s1)

  TEST_CASE( 2, a0, 1, sltiu a0, s2, 2)
  TEST_CASE( 3, a0, ST_READY, lw a0, REG_STATUS(s0); andi a0, a0, ST_READY | ST_ERROR)
  # A later boot finds the blocks of the previous one on the card.
  TEST_CASE( 4, a0, 0, li a0, 0; beqz s2, 3f; blocks lw; 3:)
  # Write them; reading them back goes through the card for all but one.
  TEST_CASE( 5, a0, 0, blocks sw; li a0, 0; blocks lw)
  # Count the boot and sync.
  TEST_CASE( 6, a0, 0, addi s2, s2, 1; sw s2, 0(s1); fence.i; sw zero, REG_FLUSH(s0); \
                       4: lw t0, REG_STATUS(s0); andi t1, t0, ST_BUSY; bnez t1, 4b; \
                       andi a0, t0, ST_ERROR)

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  .align 2
  .globl boot_count
boot_count: .word 0

RVTEST_DATA_END
