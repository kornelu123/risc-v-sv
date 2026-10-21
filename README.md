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
  MEM. FENCE.I writes back the data cache, invalidates the instruction cache
  and refetches.
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

## System

`rtl/soc.sv` is the whole system: the core (`cu`, with its caches), the
address decoder `rtl/bus.sv` and the board's SDRAM controller
`ulx3s/rtl/sdram.sv` at 50 MHz. Memory map (`rtl/memmap.sv`):

| Range | Device |
|---|---|
| `0x8000_0000`–`0x81FF_FFFF` | RAM: 32 MB SDRAM. Programs are linked here (`test/link.ld`) and reset starts here |
| everything else | nothing. Fetches read 0 (illegal instruction); loads and stores are access faults |

The testbench (`tb/top.sv`) wires the SoC to the SDRAM chip model
`ulx3s/tb/models/sdram_model.sv`, which stops the simulation on any protocol
or timing violation. As on the board, the chip runs on the inverted clock.
The testbench writes the program into the chip through a backdoor before
reset. RAM the program does not load holds the model's fill pattern, not
zeros. The core then waits about 10000 cycles for the SDRAM power-up
sequence before its first fetch.

## Caches

Split instruction and data caches (`rtl/cache.sv`) share one memory port
through `rtl/mem_arbiter.sv`, with the data cache first. The port uses the
request interface of `ulx3s/rtl/sdram.sv` (one burst per line) with 30-bit
word addresses. A line refill from an open SDRAM row takes about 19 cycles;
periodic refreshes add more.

- N-way set-associative, tree-PLRU replacement (true LRU at 2 ways),
  write-back and write-allocate. Shape per cache: `WAYS` (1 = direct-mapped),
  `SETS` (≥ 2) and `LINE_WORDS` (2–8, one SDRAM burst). The default is
  2 ways × 64 sets × 8 words = 4 KB each.
- Lookups are combinational, so a hit costs no extra cycle. An instruction
  cache miss sends bubbles into ID. A data cache miss holds MEM and
  everything behind it; an interrupt can still be taken meanwhile. A dirty
  victim is written back before the refill.
- Misaligned loads and stores still work. One that spans two lines needs
  both lines present.
- FENCE.I waits until every dirty line is written back (the lines stay
  cached, clean), then invalidates the instruction cache.
- The testbench reads `tohost` and `irq_lines` through the data cache.

Choose the shapes with top-level parameters `IC_WAYS`, `IC_SETS`,
`IC_LINE_WORDS`, `DC_WAYS`, `DC_SETS` and `DC_LINE_WORDS` (`tb/top.sv`,
passed through `rtl/soc.sv`). Build each setting in its own directory:

    make riscv-tests BUILD=build/dm SIMFLAGS="-GIC_WAYS=1 -GDC_WAYS=1"

`make cache-configs` runs `riscv-tests` and `priv-tests` again with
direct-mapped, 4-way and tiny caches (2 sets of 2-word lines, constant
evictions). Cache-specific tests: `test/isa/cache.S` and
`test/priv/cache_irq.S` (interrupts while MEM waits for a refill).

## Requirements

- Verilator 5
- RISC-V GCC toolchain (`RISCV_PREFIX`, default `riscv64-linux-gnu-`)
- riscv-tests submodule with its `env` submodule:
  `git submodule update --init --recursive`

## Usage

    make simulate      # build test/test.S and run it with an instruction trace
    make riscv-tests   # rv32ui, rv32um, rv32ua + test/isa/*.S
    make priv-tests    # machine-mode tests: rv32mi + test/priv/*.S (TODO.md step 1)
    make               # simulate + riscv-tests + priv-tests + cache-configs
    make cache-configs # both suites again with other cache shapes
    make lint
    make dasm          # disassemble test/test.S
    make simulate TEST=path/to/prog    # any program that defines and writes `tohost`

Testbench plusargs: `+bin=<file>`, `+tohost=<hex address>`, `+irq=<hex address>`,
`+max_cycles=<n>` (default 1000000, counted from reset), `+trace`.

## ULX3S drivers

`ulx3s/` holds the board's SDRAM controller and SD card (SPI mode) controller
with their simulation models; see `ulx3s/README.md`. `make -C ulx3s` runs
their tests (also in CI), `make -C ulx3s synth` checks them with
yosys/nextpnr-ecp5. The SDRAM controller is the SoC's RAM. The SD card is not
connected yet (TODO.md step 3).
