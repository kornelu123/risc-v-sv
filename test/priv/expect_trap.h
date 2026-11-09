# The instruction in `insn` (exactly one) must trap with this mcause and
# mtval, with mepc pointing at it. The test's mtvec_handler records the trap
# in s2..s4 and resumes after the instruction.
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
