# Data cache: twice as much data as the default 4 KB data cache, so lines
# are evicted dirty and refilled; accesses spanning two lines that are both
# missing; atomics and SC.W missing in the cache; dirty data written back by
# FENCE.I. `make cache-configs` also runs it with tiny caches.

#include "riscv_test.h"
#include "test_macros.h"

#define BUF_BYTES 8192

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # Read the whole buffer (one load per 8 bytes, the smallest line): evicts
  # the first half of it from a 4 KB cache. Uses t5, t6.
  .macro thrash
    la   t5, buf
    li   t6, BUF_BYTES / 8
1:  lw   zero, 0(t5)
    addi t5, t5, 8
    addi t6, t6, -1
    bnez t6, 1b
  .endm

  # Word i = i * 0x9e3779b9, written forwards and read back backwards: a0
  # counts the wrong words.
  TEST_CASE( 2, a0, 0, \
    la t0, buf; li t1, BUF_BYTES / 4; li t2, 0x9e3779b9; li t3, 0; \
    1: sw t3, 0(t0); add t3, t3, t2; addi t0, t0, 4; addi t1, t1, -1; bnez t1, 1b; \
    li t1, BUF_BYTES / 4; li a0, 0; \
    2: addi t0, t0, -4; sub t3, t3, t2; lw t4, 0(t0); \
       sub t4, t4, t3; snez t4, t4; add a0, a0, t4; \
       addi t1, t1, -1; bnez t1, 2b)

  # A word spanning two lines, neither of them cached: bytes 30..33.
  thrash
  TEST_CASE( 3, a0, 0x11223344, la t0, buf; li t1, 0x11223344; sw t1, 30(t0); \
                                lw a0, 30(t0))
  thrash
  TEST_CASE( 4, a0, 0x2233, la t0, buf; lhu a0, 31(t0))
  TEST_CASE( 5, a0, 0x22, la t0, buf; lbu a0, 32(t0))
  TEST_CASE( 6, a0, 0x01223344, la t0, buf; li t1, 0x01; sb t1, 33(t0); \
                                thrash; lw a0, 30(t0))

  # AMO on a line that is not cached: returns the old word, writes the sum.
  thrash
  TEST_CASE( 7, a0, 16 * 0x9e3779b9, la t0, buf + 64; li t1, 5; amoadd.w a0, t1, (t0))
  TEST_CASE( 8, a0, 16 * 0x9e3779b9 + 5, la t0, buf; thrash; lw a0, 64(t0))

  # LR.W, then the line is evicted: the SC.W misses and waits for the
  # refill. This core keeps the reservation (an address) meanwhile.
  TEST_CASE( 9, a0, 0, la t0, buf + 128; lr.w t1, (t0); thrash; li t2, 77; \
                       sc.w a0, t2, (t0))
  TEST_CASE(10, a0, 77, la t0, buf; thrash; lw a0, 128(t0))

  # FENCE.I writes dirty lines back and keeps them, clean: once evicted
  # (without another write-back) the data comes from memory.
  TEST_CASE(11, a0, 1234, la t0, buf; li t1, 1234; sw t1, 256(t0); fence.i; \
                          thrash; lw a0, 256(t0))

  # A load waiting for a refill retires once: instret counts the first
  # CSRR and the two loads.
  TEST_CASE(12, a0, 3, la t0, buf; thrash; csrr t1, instret; lw t2, 0(t0); \
                       lw t2, 512(t0); csrr a0, instret; sub a0, a0, t1)

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END

  .bss
  .align 6
buf: .space BUF_BYTES
