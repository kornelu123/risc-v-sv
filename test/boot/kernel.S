# Stands in for the kernel Image until there is a Linux build. The stub
# (boot/boot.S) enters here with a0 = hart id and a1 = the DTB address. Checks
# both (the blob must start with the FDT magic), prints "OK" on the UART, and
# writes tohost: 1 = pass, otherwise (test number << 1) | 1.

  .equ UART, 0x10000000

  .section .text
  .globl kernel_entry
kernel_entry:
  la    t0, dtb
  li    t3, 3              # test 1 failure code
  bnez  a0, fail           # hart 0
  li    t3, 5              # test 2
  bne   a1, t0, fail       # a1 is the DTB address
  li    t3, 7              # test 3
  lw    t1, 0(a1)          # FDT magic 0xd00dfeed, stored big-endian
  li    t2, 0xedfe0dd0     # ... so a little-endian load gives this
  bne   t1, t2, fail

  li    t1, UART
  li    t2, 79             # 'O'
  sb    t2, 0(t1)
  li    t2, 75             # 'K'
  sb    t2, 0(t1)
  li    t2, 10             # newline
  sb    t2, 0(t1)
  li    t3, 1              # pass
fail:
  la    t0, tohost
  sw    t3, 0(t0)
1:
  j     1b

  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost:
  .word 0
