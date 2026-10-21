# TODO: towards running Linux

Linux (checked against 7.3-rc7) builds the RISC-V kernel for `rv32ima` +
`zicsr_zifencei` (`arch/riscv/Makefile`). RV32 kernels are only selectable with
`CONFIG_NONPORTABLE=y` (`CONFIG_ARCH_RV32I`). C and F/D are optional.

Two milestones, in order:

1. **NOMMU Linux** — kernel runs in M-mode (`CONFIG_MMU=n`,
   `CONFIG_RISCV_M_MODE=y`), no firmware. Smallest step; proven by
   [mini-rv32ima](https://github.com/cnlohr/mini-rv32ima).
2. **Full Linux** — S/U modes, Sv32 MMU, OpenSBI in M-mode.

Every step ends with a test that must pass in `make` and CI.

## Done

- [x] RV32I, 5-stage pipeline with forwarding, load-use stall, branch flush
- [x] M extension (`rv32um`)
- [x] riscv-tests `rv32ui` + `rv32um` in `make riscv-tests` and GitHub Actions
- [x] Machine mode (step 1 below): `rv32mi` + `test/priv` in `make priv-tests`
      and GitHub Actions
- [x] A, Zifencei, interrupts, multi-cycle divider (step 2 below): `rv32ua`,
      `rv32ui/fence_i`, `test/isa`, `test/priv/interrupts.S`
- [x] Split write-back I/D caches (`rtl/cache.sv`, N-way, tree-PLRU):
      `test/isa/cache.S`, `test/priv/cache_irq.S`, every suite again in
      `make cache-configs`
- [x] SDRAM as main RAM: `rtl/soc.sv` = core + address decoder
      (`rtl/bus.sv`, `rtl/memmap.sv`) + `ulx3s/rtl/sdram.sv`. Every test runs
      against the SDRAM chip model, which checks protocol and timing.

## 1. Core: privileged basics (M-mode)

- [x] **Zicsr**: CSR register file and `csrrw/csrrs/csrrc[i]`. Execute CSR
      instructions at one stage and flush younger instructions after CSR writes.
- [x] **Precise traps**: carry an exception flag + cause down the pipeline,
      take it at one commit stage, squash younger instructions, write
      `mepc/mcause/mtval`, jump to `mtvec`; `mret`.
      Causes: illegal instruction, `ecall`, `ebreak`, misaligned fetch,
      load/store access faults. (`$fatal` in `rtl/control_unit.sv` goes away.)
- [x] **M-mode CSRs**: `mstatus` (MIE/MPIE/MPP), `misa`, `mhartid`,
      `mvendorid/marchid/mimpid` (0), `mtvec`, `mscratch`, `mepc`, `mcause`,
      `mtval`, `mie`, `mip`.
- [x] `wfi` (see step 2: it now sleeps).
- [x] **Zicntr**: `cycle/time/instret` (+ `cycleh/timeh/instreth` on RV32).
      `time` mirrors `mcycle` until the CLINT (step 3) provides `mtime`.
- [x] `mhpmcounter3–31` (+`h`), `mhpmevent3–31`: read-only 0 (writes ignored),
      as the spec allows; `mconfigptr` reads 0 (no configuration structure).
      Acceptance: `test/priv/mmode.S` tests 21–30.
- [x] **Test infra**: tests end by writing `tohost` (testbench watches it), so
      `ecall` is free to become a real trap. `make priv-tests` builds `rv32mi`
      with the official riscv-tests `p` environment, plus `test/priv/mmode.S`
      for what `rv32mi` does not check on an M-only hart.
      Acceptance: `rv32ui`, `rv32um` still pass; `make priv-tests` passes and
      runs in CI.

## 2. Core: remaining Linux ISA requirements

- [x] **A extension**: `lr.w/sc.w` (reservation valid bit + address; cleared on
      trap/`sc`) and `amo*.w` (read-modify-write in MEM; a single cycle with
      the asynchronous memory model, more with block RAM).
      Acceptance: `rv32ua`.
- [x] **Zifencei**: `fence.i` flushes the pipeline and refetches.
      Acceptance: `rv32ui/fence_i`, `test/isa/fence_i.S` (stale instructions
      already in the pipeline).
- [x] **Interrupts**: timer, software and external interrupts via `mie/mip`,
      taken at the commit stage like exceptions. The inputs come from the
      testbench (`irq_lines`) until the CLINT/PLIC in step 3.
      Acceptance: `test/priv/interrupts.S`.
- [x] Iterative divider with an EX stall instead of combinational `/` and `%`
      (needed for FPGA timing, not for correctness).
      Acceptance: `rv32um`, `test/isa/div_hazards.S`.
- [x] `wfi` sleeps: fetch stops until an interrupt enabled in `mie` is
      pending (regardless of `mstatus.MIE`); a taken interrupt then has
      `mepc` = `wfi` + 4. Acceptance: `test/priv/interrupts.S` tests 18–23.

## 3. SoC: memory and devices

- [x] **ULX3S drivers** (`ulx3s/`): SDRAM controller (bursts of up to 8
      32-bit words for cache lines, open-row policy, 32/64 MB parts) and SD
      card controller (SPI mode, 512-byte blocks), each with a
      protocol/timing-checking simulation model. Not on hardware yet.
- [x] Attach SDRAM as main RAM (wait states, refresh): 32 MB at
      `0x8000_0000`, where reset starts; see `rtl/memmap.sv`. Tested in
      simulation only.
- [ ] SD card as an MMIO block device (or behind a boot ROM that loads the
      kernel). Needs the uncached MMIO path below, plus a register interface
      around `ulx3s/rtl/sd_spi.sv`: block number, start, status, and a
      512-byte buffer or a data FIFO.
- [ ] **Memory map + bus, MMIO**: `rtl/bus.sv` decodes RAM and answers
      everything else with zeros. Devices need an uncached path: every access
      goes through the write-back data cache now. That means an address
      range the data cache passes through as single-word accesses with byte
      enables, `memmap::in_ram` widened to cover the devices for access
      faults, and instruction access faults for fetches outside RAM
      (illegal instructions now).
- [ ] **CLINT**: `mtime`, `mtimecmp`, `msip` (machine timer/software
      interrupts).
- [ ] **UART**: ns16550a-compatible subset (THR/RBR/LSR/IER) for the console;
      the testbench prints transmitted characters.
- [ ] **Device tree** (`.dts`): CPU (`riscv,isa-base`, `riscv,isa-extensions`),
      memory, CLINT, UART, `chosen/stdout-path`.
- [ ] **Boot**: load kernel `Image` + DTB into RAM; enter with `a0` = hart id,
      `a1` = DTB address. RV32 kernels must sit at a 4 MB-aligned address
      (docs.kernel.org/arch/riscv/boot.html).
- [ ] Bare-metal smoke test: C program printing over the UART with timer
      interrupts.

## 4. Milestone: NOMMU Linux

- [ ] Kernel config: `CONFIG_NONPORTABLE=y`, `CONFIG_ARCH_RV32I=y`,
      `CONFIG_MMU=n`, `CONFIG_RISCV_M_MODE=y`, no FPU, no C if not implemented.
- [ ] Buildroot `rv32ima` NOMMU userspace (see mini-rv32ima's
      `configs/buildroot_config`); initramfs built into the kernel.
- [ ] Boot to a shell in simulation. Expect slow Verilator runs; add a
      `+max_cycles` large enough and a UART-only (no trace) mode.

## 5. Core + SoC: S/U modes and MMU

- [ ] **S and U modes**: `medeleg/mideleg`, S-mode CSRs (`sstatus`, `stvec`,
      `sepc`, `scause`, `stval`, `sscratch`, `sie`, `sip`, `satp`), `sret`,
      `mstatus` fields MPP/SPP/SUM/MXR/MPRV.
- [ ] **Sv32**: hardware page-table walker, I/D TLBs, `sfence.vma`,
      instruction/load/store page faults, permission checks; A/D bits either
      set by hardware or reported as page faults.
      Acceptance: `rv32si` and the riscv-tests `v` environment.
- [ ] **PLIC** for UART (external) interrupts.
- [ ] **OpenSBI** (`fw_jump` or `fw_dynamic`, generic platform with FDT).
      Check whether it boots with no PMP regions before implementing PMP.

## 6. Milestone: full Linux

- [ ] Kernel with `CONFIG_MMU=y`, OpenSBI, Buildroot `rv32ima` userspace.
- [ ] Boot to a shell in simulation, then on the FPGA.

## Later / optional

- [ ] C extension (most prebuilt userspaces assume it).
- [ ] F/D for hard-float userspace (otherwise build soft-float `ilp32`).
- [ ] FPGA: synchronous BRAM for the caches (lookups are combinational now,
      so they map to LUT RAM), DSP multiplier, DDR controller, timing
      closure.
- [ ] Compliance against a reference model with
      [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test).

## Risks

- RV32 is behind `NONPORTABLE`, and the kernel community is discussing the
  future of 32-bit support (https://lwn.net/Articles/1035727). RV64 is the
  safer long-term target for full Linux.
- A 2024 patch proposed deprecating RISC-V `CONFIG_MMU=n`
  (lists.infradead.org/pipermail/linux-riscv/2024-February/049602.html);
  NOMMU is still present in 7.3-rc7 but niche.
