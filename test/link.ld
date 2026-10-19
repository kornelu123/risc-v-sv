ENTRY(_start)

SECTIONS
{
  . = 0x0;

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
