RISCV_PREFIX ?= riscv64-linux-gnu-
BUILD        ?= build
TEST         ?= test/test

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
CFLAGS  := -march=rv32im -mabi=ilp32 -static -mcmodel=medany -fno-pie -no-pie \
           -nostdlib -nostartfiles -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
           -T test/link.ld

RTL := $(shell cat sources.f)
SIM := $(BUILD)/obj_dir/Vt

RISCV_TESTS_DIR := third_party/riscv-tests/isa
# <suite>/<test> names, e.g. rv32um/mul. fence_i needs Zifencei (not implemented).
RISCV_TESTS := $(filter-out rv32ui/fence_i, \
                 $(patsubst $(RISCV_TESTS_DIR)/%.S,%, \
                   $(wildcard $(RISCV_TESTS_DIR)/rv32ui/*.S $(RISCV_TESTS_DIR)/rv32um/*.S)))

.PHONY: all simulate riscv-tests lint dasm clean
# Keep intermediate .elf files for `make dasm`.
.SECONDARY:

all: simulate riscv-tests

# Run $(TEST).S with an instruction trace.
simulate: $(SIM) $(BUILD)/$(TEST).bin
	$(SIM) +bin=$(BUILD)/$(TEST).bin +trace

# Run the official riscv-tests; logs go to $(BUILD)/isa/<suite>/<test>.log.
riscv-tests: $(SIM) $(RISCV_TESTS:%=$(BUILD)/isa/%.bin)
	@fail=0; for t in $(RISCV_TESTS); do \
	  if $(SIM) +bin=$(BUILD)/isa/$$t.bin > $(BUILD)/isa/$$t.log 2>&1; \
	  then echo "PASS  $$t"; \
	  else echo "FAIL  $$t  ($(BUILD)/isa/$$t.log)"; fail=1; fi; \
	done; exit $$fail

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -f sources.f tb/top.sv --top-module t

dasm: $(BUILD)/$(TEST).elf
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD) obj_dir

$(SIM): $(RTL) tb/top.sv sources.f
	@mkdir -p $(BUILD)
	verilator --binary -j 0 --Mdir $(BUILD)/obj_dir -o Vt -f sources.f tb/top.sv --top-module t

$(BUILD)/isa/%.elf: $(RISCV_TESTS_DIR)/%.S test/env/riscv_test.h test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -I test/env -I $(RISCV_TESTS_DIR)/macros/scalar -o $@ $<

$(BUILD)/%.elf: %.S test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@
