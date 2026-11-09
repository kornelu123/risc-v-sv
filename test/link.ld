ENTRY(_start)

SECTIONS
{
  . = 0x80000000;   /* memmap::MEM_BASE: the start of main memory, where reset begins */

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
    . = ALIGN(4);
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  }

  /DISCARD/ : {
    *(*)
  }
}
