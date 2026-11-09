/* Boot image: the stub at reset, the device tree at 0x8010_0000, the kernel at
   0x8040_0000 (a 4 MB boundary, as RV32 kernels require). All of it is in main
   memory, which starts at 0x8000_0000 (memmap::MEM_BASE). */
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }

  . = 0x80100000;
  .dtb : { *(.dtb) }

  . = 0x80400000;
  .text : { *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }

  /* Word the testbench watches to learn the test result. */
  .tohost : { *(.tohost) }

  .data : { *(.data .data.* .sdata .sdata.*) }
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) }

  /DISCARD/ : { *(.eh_frame) }
}
