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
