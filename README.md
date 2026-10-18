# risc-v-sv

In-order RV32I core in SystemVerilog, simulated with Verilator.

Classic 5-stage pipeline: IF, ID, EX, MEM, WB.

- Results are forwarded to EX from MEM and WB; ID bypasses the register
  being written back in the same cycle.
- A load followed by an instruction that uses its result stalls for one cycle.
- Fetch predicts branches not taken; a taken branch or jump is resolved in EX
  and squashes the two instructions behind it.
- ECALL/EBREAK stop fetch and halt the core when they retire; a test passes
  when a0 is 0 at that point.

## Requirements

- Verilator 5
- RISC-V GCC toolchain (`RISCV_PREFIX`, default `riscv64-linux-gnu-`)
- riscv-tests submodule: `git submodule update --init third_party/riscv-tests`

## Usage

    make simulate      # build test/test.S and run it with an instruction trace
    make riscv-tests   # run the official rv32ui tests (fence_i excluded: Zifencei)
    make               # both
    make lint
    make dasm          # disassemble test/test.S
    make simulate TEST=path/to/prog    # any program ending in ecall with a0 = 0

Testbench plusargs: `+bin=<file>`, `+max_cycles=<n>`, `+trace`.
