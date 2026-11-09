// Minimal riscv-tests environment for this core: bare machine, no CSRs or
// traps needed. Tests start at the start of RAM (0x80000000, test/link.ld)
// and report through the `tohost` word, like the official environment:
// 1 = pass, otherwise (failing test number << 1) | 1. They never use ECALL
// to finish.
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
        sw TESTNUM, tohost, t5; \
1:      j 1b

#define RVTEST_FAIL \
        fence; \
        sll TESTNUM, TESTNUM, 1; \
        or TESTNUM, TESTNUM, 1; \
        sw TESTNUM, tohost, t5; \
1:      j 1b

#define RVTEST_DATA_BEGIN \
        .pushsection .tohost, "aw", @progbits; \
        .align 6; .globl tohost; tohost: .dword 0; .size tohost, 8; \
        .align 6; .globl fromhost; fromhost: .dword 0; .size fromhost, 8; \
        .popsection; \
        .align 4; \
        .globl begin_signature; \
begin_signature:

#define RVTEST_DATA_END \
        .align 4; \
        .globl end_signature; \
end_signature:

#endif
