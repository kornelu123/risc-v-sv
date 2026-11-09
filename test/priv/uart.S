# UART (rtl/uart.sv): the ns16550a register subset, byte accesses, DLAB, and
# transmit. The bytes it sends are printed by the testbench: "OK" and a newline.

#include "riscv_test.h"
#include "test_macros.h"
#include "expect_trap.h"

  .equ UART,     0x10000000
  .equ UART_END, 0x10000100     # first address past the window

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # Reset: IIR says no interrupt pending, LSR says the transmitter is empty.
  TEST_CASE( 2, a0, 0x01, li t1, UART; lbu a0, 2(t1))
  TEST_CASE( 3, a0, 0x60, li t1, UART; lbu a0, 5(t1))

  # IER, LCR, MCR and SCR keep the byte written.
  TEST_CASE( 4, a0, 0x0F, li t1, UART; li t0, 0x0F; sb t0, 1(t1); lbu a0, 1(t1))
  TEST_CASE( 5, a0, 0x03, li t1, UART; li t0, 0x03; sb t0, 3(t1); lbu a0, 3(t1))
  TEST_CASE( 6, a0, 0x13, li t1, UART; li t0, 0x13; sb t0, 4(t1); lbu a0, 4(t1))
  TEST_CASE( 7, a0, 0xA5, li t1, UART; li t0, 0xA5; sb t0, 7(t1); lbu a0, 7(t1))

  # FCR (write) is ignored: IIR still reads no interrupt, no FIFO.
  TEST_CASE( 8, a0, 0x01, li t1, UART; li t0, 0xC7; sb t0, 2(t1); lbu a0, 2(t1))

  # DLAB (LCR bit 7): offsets 0 and 1 are the divisor latch, not THR and IER.
  TEST_CASE( 9, a0, 0x34, li t1, UART; li t0, 0x83; sb t0, 3(t1); li t0, 0x34; \
                       sb t0, 0(t1); lbu a0, 0(t1))
  TEST_CASE(10, a0, 0x12, li t1, UART; li t0, 0x12; sb t0, 1(t1); lbu a0, 1(t1))
  TEST_CASE(11, a0, 0x83, li t1, UART; lbu a0, 3(t1))
  TEST_CASE(12, a0, 0x0F, li t1, UART; li t0, 0x03; sb t0, 3(t1); lbu a0, 1(t1))

  # Nothing is received: RBR reads zero.
  TEST_CASE(13, a0, 0, li t1, UART; lbu a0, 0(t1))

  # Transmit: 'O', 'K' and a newline go out; LSR stays empty and idle.
  TEST_CASE(14, a0, 0x60, li t1, UART; li t0, 79; sb t0, 0(t1); li t0, 75; \
                       sb t0, 0(t1); li t0, 10; sb t0, 0(t1); lbu a0, 5(t1))

  # With DLAB set, a store to offset 0 goes to the divisor, not out ('X' is
  # not printed).
  TEST_CASE(15, a0, 0x60, li t1, UART; li t0, 0x83; sb t0, 3(t1); li t0, 88; \
                       sb t0, 0(t1); li t0, 0x03; sb t0, 3(t1); lbu a0, 5(t1))

  # Just past the window nothing is mapped.
  li   a0, UART_END
  expect_trap 16, CAUSE_LOAD_ACCESS, UART_END, lbu a1, 0(a0)

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
