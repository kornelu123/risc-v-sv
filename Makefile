RISCV_PREFIX ?= riscv64-linux-gnu-
BUILD        ?= build
TEST         ?= test/test

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
CFLAGS  := -march=rv32i -mabi=ilp32 -static -mcmodel=medany -fno-pie -no-pie \
           -nostdlib -nostartfiles -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
           -T test/link.ld

RTL := $(shell cat sources.f)
SIM := $(BUILD)/obj_dir/Vt

.PHONY: simulate lint dasm clean
# Keep intermediate .elf files for `make dasm`.
.SECONDARY:

# Run $(TEST).S with an instruction trace.
simulate: $(SIM) $(BUILD)/$(TEST).bin
	$(SIM) +bin=$(BUILD)/$(TEST).bin +trace

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -f sources.f tb/top.sv --top-module t

dasm: $(BUILD)/$(TEST).elf
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD) obj_dir

$(SIM): $(RTL) tb/top.sv sources.f
	@mkdir -p $(BUILD)
	verilator --binary -j 0 --Mdir $(BUILD)/obj_dir -o Vt -f sources.f tb/top.sv --top-module t

$(BUILD)/%.elf: %.S test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@
