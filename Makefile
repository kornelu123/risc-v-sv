RISCV_PREFIX ?= riscv64-linux-gnu-
TEST         ?= test/test

.PHONY: simulate dasm clean

simulate: $(TEST).bin
	verilator --binary ./tb/top.sv -o out -f sources.f --top-module t -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -DTESTFILE_PATH='"$(TEST).bin"'
	./obj_dir/out

$(TEST).elf: $(TEST).S test/link.ld
	$(RISCV_PREFIX)gcc -nostdlib -nostartfiles -ffreestanding -march=rv32i -mabi=ilp32 \
	    -T test/link.ld -o $@ $<

$(TEST).bin: $(TEST).elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

dasm: $(TEST).elf
	$(RISCV_PREFIX)objdump -d $<

clean:
	rm -rf obj_dir/ $(TEST).elf $(TEST).bin
