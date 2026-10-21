ENTRY(_start)

SECTIONS
{
  . = 0x80000000;   /* memmap::RAM_BASE: the start of RAM, where reset begins */

  .text : {
    *(.text.init)
    *(.text .text.*)
  }

  .rodata : {
    *(.rodata .rodata.* .srodata .srodata.*)
  }

  /* Word the testbench watches to learn the test result. */
  .tohost : {
    *(.tohost)
  }

  .data : {
    *(.data .data.* .sdata .sdata.*)
  }

  .bss : {
    *(.bss .bss.* .sbss .sbss.* COMMON)
  }

  /DISCARD/ : {
    *(*)
  }
}
