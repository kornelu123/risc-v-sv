// Minimal riscv-tests environment for this core: bare machine, no CSRs or
// traps. Tests start at address 0 and end with ECALL; a0 = 0 means pass,
// otherwise a0 = (failing test number << 1) | 1.
#ifndef RISCV_SV_TEST_H
#define RISCV_SV_TEST_H

#define TESTNUM gp

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U

#define RVTEST_CODE_BEGIN \
        .section .text.init, "ax"; \
        .align 2; \
        .globl _start; \
_start: \
        li TESTNUM, 0;

#define RVTEST_CODE_END

#define RVTEST_PASS \
        fence; \
        li TESTNUM, 1; \
        li a0, 0; \
        ecall

#define RVTEST_FAIL \
        fence; \
        sll TESTNUM, TESTNUM, 1; \
        or TESTNUM, TESTNUM, 1; \
        mv a0, TESTNUM; \
        ecall

#define RVTEST_DATA_BEGIN \
        .align 4; \
        .globl begin_signature; \
begin_signature:

#define RVTEST_DATA_END \
        .align 4; \
        .globl end_signature; \
end_signature:

#endif
