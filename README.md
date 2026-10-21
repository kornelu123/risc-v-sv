# risc-v-sv

In-order RV32IMA (+ Zicsr, Zicntr, Zifencei) core in SystemVerilog, simulated
with Verilator.

Classic 5-stage pipeline: IF, ID, EX, MEM, WB.

- Results are forwarded to EX from MEM and WB; ID bypasses the register
  being written back in the same cycle.
- A load followed by an instruction that uses its result stalls for one cycle.
- Fetch predicts branches not taken; a taken branch or jump is resolved in EX
  and squashes the two instructions behind it.
- Multiplication is single-cycle; DIV/REM use a 34-cycle iterative divider
  (`rtl/divider.sv`) while IF/ID/EX stall.
- Atomics (LR/SC with a one-address reservation, AMO read-modify-write) run in
  MEM. FENCE.I flushes and refetches.
- Machine mode only, with precise traps: exceptions (illegal instruction,
  ECALL, EBREAK, misaligned jump target, misaligned atomic, load/store access
  fault), interrupts, MRET, FENCE.I and CSR instructions take effect in MEM and
  squash everything younger. The CSRs are in `rtl/csr.sv`; the performance
  counters `mhpmcounter3–31`/`mhpmevent3–31` and `mconfigptr` read as 0.
- Interrupts: machine software/timer/external inputs (`mip` bits 3/7/11),
  priority external > software > timer. WFI stops fetching until an
  interrupt enabled in `mie` is pending. The testbench drives the inputs from
  a program's `irq_lines` word (bits 31:16 delay a new value by that many
  cycles) until a CLINT/PLIC exists.

Tests report their result through a `tohost` word in memory, the riscv-tests
convention: 1 = pass, `(failing test number << 1) | 1` = fail. The testbench
watches that address; the Makefile reads it from the ELF.

## Requirements

- Verilator 5
- RISC-V GCC toolchain (`RISCV_PREFIX`, default `riscv64-linux-gnu-`)
- riscv-tests submodule with its `env` submodule:
  `git submodule update --init --recursive`

## Usage

    make simulate      # build test/test.S and run it with an instruction trace
    make riscv-tests   # rv32ui, rv32um, rv32ua + test/isa/*.S
    make priv-tests    # machine-mode tests: rv32mi + test/priv/*.S (TODO.md step 1)
    make               # simulate + riscv-tests + priv-tests
    make lint
    make dasm          # disassemble test/test.S
    make simulate TEST=path/to/prog    # any program that defines and writes `tohost`

Testbench plusargs: `+bin=<file>`, `+tohost=<hex address>`, `+irq=<hex address>`,
`+max_cycles=<n>`, `+trace`.

## ULX3S drivers

`ulx3s/` holds the board's SDRAM controller and SD card (SPI mode) controller
with their simulation models; see `ulx3s/README.md`. `make -C ulx3s` runs
their tests (also in CI), `make -C ulx3s synth` checks them with
yosys/nextpnr-ecp5. They are not connected to the core yet (TODO.md step 3).
