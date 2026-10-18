# risc-v-sv

In-order RV32I core in SystemVerilog, simulated with Verilator.

Classic 5-stage pipeline: IF, ID, EX, MEM, WB.

- Results are forwarded to EX from MEM and WB; ID bypasses the register
  being written back in the same cycle.
- A load followed by an instruction that uses its result stalls for one cycle.
- Fetch predicts branches not taken; a taken branch or jump is resolved in EX
  and squashes the two instructions behind it.
- ECALL/EBREAK halt the core when they retire (machine-mode traps are the next
  step, see TODO.md).

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
    make riscv-tests   # run the official rv32ui and rv32um tests (fence_i excluded: Zifencei)
    make priv-tests    # machine-mode tests: rv32mi + test/priv/*.S (TODO.md step 1)
    make               # simulate + riscv-tests
    make lint
    make dasm          # disassemble test/test.S
    make simulate TEST=path/to/prog    # any program that defines and writes `tohost`

Testbench plusargs: `+bin=<file>`, `+tohost=<hex address>`, `+max_cycles=<n>`,
`+trace`.
