// Physical memory map. RAM is the ULX3S board's SDRAM (32 MB part) behind
// rtl/sdram.sv's controller, at 0x8000_0000 as on most RISC-V platforms
// (QEMU virt, riscv-tests, OpenSBI's examples, Linux's PHYS_RAM_BASE default).
// Nothing else is mapped yet: fetches elsewhere read as 0 (an illegal
// instruction), loads and stores elsewhere are access faults. The program
// is linked at RAM_BASE (test/link.ld) and runs from there after reset.
package memmap;
  localparam bit [31:0] RAM_BASE  = 32'h8000_0000;
  localparam int        RAM_BYTES = 32 * 1024 * 1024;   // 64 MB parts: 64 * 1024 * 1024
  localparam bit [31:0] RESET_PC  = RAM_BASE;           // no boot ROM yet

  // True if a load/store of 2**width bytes at addr lies inside RAM.
  function automatic bit in_ram(bit [31:0] addr, bit [1:0] width);
    return addr - RAM_BASE <= 32'(RAM_BYTES) - (32'd1 << width);
  endfunction
endpackage
