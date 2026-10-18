.section .text
.globl _start

.option norvc
.option norelax
.balign 4

_start:
    # ---------------------------------------------------------
    # Original arithmetic pattern, with initialized operands.
    # ---------------------------------------------------------
    addi x1, x4, -2048
    addi x2, x5, 2035
    add  x3, x6, x10
    sub  x4, x7, x11
    addi x5, x8, -1996
    addi x6, x9, 1983
    add  x7, x10, x14
    sub  x8, x11, x15
    addi x9, x12, -1944
    addi x10, x13, 1931
    add  x11, x14, x18
    sub  x12, x15, x19
    addi x13, x16, -1892
    addi x14, x17, 1879
    add  x15, x18, x22
    sub  x16, x19, x23

    # ---------------------------------------------------------
    # ADDI: sign extension, boundaries, and rd == rs1.
    # ---------------------------------------------------------
    addi x1, x0, -2048       # x1 = 0xfffff800
    addi x2, x0, 2047        # x2 = 0x000007ff
    addi x3, x0, -1          # x3 = 0xffffffff
    addi x4, x0, 0           # x4 = 0
    addi x5, x0, 1           # x5 = 1
    addi x6, x1, 2047        # x6 = 0xffffffff
    addi x7, x2, -2048       # x7 = 0xffffffff
    addi x8, x3, 1           # x8 = 0: wraparound
    addi x9, x0, 123
    addi x9, x9, -123        # x9 = 0

    # ADD/SUB: zero, negative results, wraparound, aliases.
    add  x10, x1, x2         # x10 = 0xffffffff
    sub  x11, x2, x1         # x11 = 4095
    sub  x12, x1, x2         # x12 = 0xfffff001
    add  x13, x3, x5         # x13 = 0
    sub  x14, x0, x5         # x14 = 0xffffffff
    sub  x15, x3, x3         # x15 = 0
    add  x16, x0, x2         # x16 = 2047
    addi x17, x0, 10
    add  x17, x17, x5        # rd == rs1: x17 = 11
    add  x17, x5, x17        # rd == rs2: x17 = 12
    sub  x17, x17, x5        # rd == rs1: x17 = 11
    sub  x17, x5, x17        # rd == rs2: x17 = -10

    # Writes to x0 must be discarded.
    addi x0, x0, 123
    add  x0, x2, x2
    sub  x0, x0, x5
    addi x18, x0, 0          # x18 must be zero

    # Exercise every nonzero rd/rs1/rs2 register encoding.
    .irp r,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
        addi x\r, x0, \r
        add  x\r, x\r, x\r
        sub  x\r, x\r, x\r   # Result must be zero.
    .endr

    # ---------------------------------------------------------
    # LUI: full 20-bit immediate, including the sign bit.
    # ---------------------------------------------------------
    lui x1, 0x00000          # x1 = 0x00000000
    lui x2, 0x00001          # x2 = 0x00001000
    lui x3, 0x12345          # x3 = 0x12345000
    lui x4, 0x7ffff          # x4 = 0x7ffff000
    lui x5, 0x80000          # x5 = 0x80000000
    lui x6, 0xfffff          # x6 = 0xfffff000

    # Arithmetic overflow using LUI-generated values.
    addi x7, x4, 2047        # x7 = 0x7ffff7ff
    addi x7, x7, 2047        # x7 = 0x7ffffffe
    addi x7, x7, 1           # x7 = 0x7fffffff
    addi x8, x0, 1
    add  x9, x7, x8          # x9 = 0x80000000
    sub  x10, x5, x8         # x10 = 0x7fffffff

    lui x0, 0x12345
    addi x11, x0, 0          # x11 must be zero

    # ---------------------------------------------------------
    # AUIPC: expected value uses the PC of each instruction.
    # ---------------------------------------------------------
auipc_zero:
    auipc x12, 0x00000       # x12 = address(auipc_zero)
auipc_positive:
    auipc x13, 0x00001       # x13 = address(auipc_positive) + 4096
auipc_pattern:
    auipc x14, 0x12345       # x14 = address(auipc_pattern) + 0x12345000
auipc_negative:
    auipc x15, 0xfffff       # x15 = address(auipc_negative) - 4096
auipc_sign_bit:
    auipc x16, 0x80000       # x16 = address(auipc_sign_bit) + 0x80000000

    auipc x0, 0x00001
    addi x17, x0, 0          # x17 must be zero

    # ---------------------------------------------------------
    # JAL: forward jump; link must equal jal_forward + 4.
    # x20 is a control-flow marker.
    # ---------------------------------------------------------
    addi x20, x0, 0

jal_forward:
    jal x1, .Lforward_target
    addi x20, x20, 100       # Must be skipped.

.Lforward_target:
    addi x20, x20, 1         # x20 = 1

    # Finite backward jump, then return using JALR.
    jal x0, .Lbackward_call

.Lbackward_target:
    addi x20, x20, 2         # x20 = 3
    jalr x0, 0(x2)

.Lbackward_call:
    jal x2, .Lbackward_target

    # ---------------------------------------------------------
    # JALR: zero, positive, and negative immediate.
    # Each instruction is 4 bytes because RVC is disabled.
    # Numeric offsets depend on the instruction layout below.
    # ---------------------------------------------------------
.Ljr_zero_base:
    auipc x5, 0
    addi x5, x5, 16          # Target = base + 16.
    jalr x6, 0(x5)
    addi x20, x20, 100       # Must be skipped.

.Ljr_zero_target:
    addi x20, x20, 4         # x20 = 7

.Ljr_positive_base:
    auipc x5, 0
    addi x5, x5, 4           # base + 4 + 12 = target.
    jalr x6, 12(x5)
    addi x20, x20, 100       # Must be skipped.

.Ljr_positive_target:
    addi x20, x20, 8         # x20 = 15

.Ljr_negative_base:
    auipc x5, 0
    addi x5, x5, 28          # base + 28 - 12 = target.
    jalr x6, -12(x5)
    addi x20, x20, 100       # Must be skipped.

.Ljr_negative_target:
    addi x20, x20, 16        # x20 = 31

    # JALR must clear target bit 0.
.Ljr_odd_base:
    auipc x5, 0
    addi x5, x5, 17          # Target address + 1.
    jalr x6, 0(x5)
    addi x20, x20, 100       # Must be skipped.

.Ljr_odd_target:
    addi x20, x20, 32        # x20 = 63

    # JALR with rd == rs1: target uses the OLD register value.
.Ljr_alias_base:
    auipc x5, 0
    addi x5, x5, 16
.Ljr_alias_instruction:
    jalr x5, 0(x5)           # x5 = address(.Ljr_alias_instruction) + 4
    addi x20, x20, 100       # Must be skipped.

.Ljr_alias_target:
    addi x20, x20, 64        # x20 = 127

    # JALR immediate maximum: +2047.
.Ljr_max_base:
    auipc x5, 0
    addi x5, x5, -2031       # base - 2031 + 2047 = target.
    jalr x6, 2047(x5)
    addi x20, x20, 100       # Must be skipped.

.Ljr_max_target:
    addi x20, x20, 128       # x20 = 255

    # JALR immediate minimum: -2048.
.Ljr_min_base:
    auipc x5, 0
    addi x5, x5, 2047
    addi x5, x5, 21          # base + 2047 + 21 - 2048 = base + 20.
    jalr x6, -2048(x5)
    addi x20, x20, 100       # Must be skipped.

.Ljr_min_target:
    addi x20, x20, 256       # x20 = 511

    # ---------------------------------------------------------
    # Larger positive/negative JAL offsets.
    # Padding is skipped in both directions.
    # ---------------------------------------------------------
.Lfar_call:
    jal x10, .Lfar_target

.Lfar_return:
    addi x20, x20, 512       # x20 = 1023
    jal x0, .Lafter_far

.Lfar_target:
    jal x11, .Lfar_return

.Lafter_far:
    # Completion signature. This indicates reaching the end;
    # the testbench must still check intermediate results.
    lui  x31, 0x00006
    addi x31, x31, 13        # x31 = 0x0000600d
                            # x20 = 0x000003ff

.globl test_done
test_done:
    jal x0, test_done        # Stop here in your testbench.
