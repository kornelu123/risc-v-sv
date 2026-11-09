# Boot stub. Reset starts here (0x8000_0000, memmap::MEM_BASE). It enters the
# kernel with a0 = hart id and a1 = the address of the device tree blob, which
# is loaded into RAM with the kernel (boot/boot.ld). Included by the Makefile:
# DTB_FILE names the blob (build/boot/risc-v-sv.dtb).

  .section .text.init
  .globl _start
_start:
  csrr a0, mhartid
  la   a1, dtb
  la   t0, kernel_entry
  jr   t0

  .section .dtb, "a"
  .balign 8
  .globl dtb
dtb:
  .incbin DTB_FILE
