#!/bin/bash

riscv64-linux-gnu-gcc -nostdlib -nostartfiles -ffreestanding \
    -march=rv32i -mabi=ilp32 \
    -T link.ld \
    -o test.elf test.S
riscv64-unknown-elf-objcopy -O binary test.elf test.bin
