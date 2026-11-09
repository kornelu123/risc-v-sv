// Physical memory map.
//
//   0x1000_1000 - 0x1000_1FFF  memory controller registers (rtl/sd_mem.sv)
//   0x8000_0000 - 0x8FFF_FFFF  main memory: 256 MB, stored on the SD card
//
// Main memory byte k is byte k of the SD card, used raw (no partition
// table). The SDRAM caches it in 512-byte blocks (rtl/sd_mem.sv), and the
// core's caches sit in front of that. It starts at 0x8000_0000 as on most
// RISC-V platforms (QEMU virt, riscv-tests, Linux's PHYS_RAM_BASE default).
// After reset the core runs from MEM_BASE, i.e. from the card's first
// block.
//
// Devices (the I/O windows) are not cached and take naturally aligned loads
// and stores of 1, 2 or 4 bytes, no atomics. Everything else is unmapped:
// loads, stores and fetches there are access faults. Fetches from the device
// windows fault too; they never reach the bus.
package memmap;
  localparam bit [31:0] MEM_BASE  = 32'h8000_0000;
  localparam int        MEM_BYTES = 256 * 1024 * 1024;
  localparam bit [31:0] RESET_PC  = MEM_BASE;           // no boot ROM

  localparam bit [31:0] CTRL_BASE  = 32'h1000_1000;
  localparam int        CTRL_BYTES = 4096;

  // True if a load/store of 2**width bytes at addr lies inside main memory.
  function automatic bit in_mem(bit [31:0] addr, bit [1:0] width);
    return addr - MEM_BASE <= 32'(MEM_BYTES) - (32'd1 << width);
  endfunction

  // True if addr is in a device window (uncached).
  function automatic bit in_io(bit [31:0] addr);
    return addr - CTRL_BASE < 32'(CTRL_BYTES);
  endfunction

  // True if a load/store (atomic or not) of 2**width bytes at addr reaches
  // memory or a device.
  function automatic bit access_ok(bit [31:0] addr, bit [1:0] width, bit atomic);
    bit aligned;
    aligned = (addr & ((32'd1 << width) - 32'd1)) == 32'd0;
    return in_mem(addr, width) || (in_io(addr) && aligned && !atomic);
  endfunction
endpackage
