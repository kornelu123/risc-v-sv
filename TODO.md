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

## 1. Core: privileged basics (M-mode)

- [ ] **Zicsr**: CSR register file and `csrrw/csrrs/csrrc[i]`. Execute CSR
      instructions at one stage and flush younger instructions after CSR writes.
- [ ] **Precise traps**: carry an exception flag + cause down the pipeline,
      take it at one commit stage, squash younger instructions, write
      `mepc/mcause/mtval`, jump to `mtvec`; `mret`.
      Causes: illegal instruction, `ecall`, `ebreak`, misaligned fetch,
      load/store access faults. (`$fatal` in `rtl/control_unit.sv` goes away.)
- [ ] **M-mode CSRs**: `mstatus` (MIE/MPIE/MPP), `misa`, `mhartid`,
      `mvendorid/marchid/mimpid` (0), `mtvec`, `mscratch`, `mepc`, `mcause`,
      `mtval`, `mie`, `mip`.
- [ ] `wfi` (may be a no-op).
- [ ] **Zicntr**: `cycle/time/instret` (+ `cycleh/timeh/instreth` on RV32).
- [ ] **Test infra**: `ecall` becomes a real trap, so stop ending tests on it.
      Use the official riscv-tests `p` environment (`git submodule update
      --init` inside `third_party/riscv-tests` for `env/`) and end tests via
      writes to `tohost`; the testbench watches that address.
      Acceptance: `rv32ui`, `rv32um` still pass; `rv32mi` passes.

## 2. Core: remaining Linux ISA requirements

- [ ] **A extension**: `lr.w/sc.w` (reservation valid bit + address; cleared on
      trap/`sc`) and `amo*.w` (read-modify-write in MEM, one extra cycle).
      Acceptance: `rv32ua`.
- [ ] **Zifencei**: `fence.i` flushes the pipeline and refetches.
      Acceptance: drop the `rv32ui/fence_i` exclusion in the Makefile.
- [ ] **Interrupts**: timer, software and external interrupts via `mie/mip`,
      taken at the commit stage like exceptions.
- [ ] Iterative divider with an EX stall instead of combinational `/` and `%`
      (needed for FPGA timing, not for correctness).

## 3. SoC: memory and devices

- [ ] **Memory map + bus**: replace the `mem` package with RAM and MMIO
      modules behind an address decoder (byte enables, wait states).
      RAM: a few MB for NOMMU, 32–64 MB for full Linux.
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
- [ ] FPGA: synchronous BRAM/caches, DSP multiplier, DDR controller, timing
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
