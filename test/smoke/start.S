# Entry point for the bare-metal C smoke test: zero .bss (the simulator's RAM is
# not zero), set up the stack, call main.

  .section .text.init
  .globl _start
_start:
  la   t0, __bss_start
  la   t1, __bss_end
2:
  bgeu t0, t1, 3f
  sw   zero, 0(t0)
  addi t0, t0, 4
  j    2b
3:
  la   sp, stack_top
  call main
1:
  j    1b

  .section .bss
  .balign 16
stack:
  .space 4096
stack_top:
