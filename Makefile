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

RV32UI_DIR   := third_party/riscv-tests/isa/rv32ui
# fence_i exercises Zifencei, which is not part of RV32I.
RV32UI_TESTS := $(filter-out fence_i,$(basename $(notdir $(wildcard $(RV32UI_DIR)/*.S))))

.PHONY: all simulate riscv-tests lint dasm clean
# Keep intermediate .elf files for `make dasm`.
.SECONDARY:

all: simulate riscv-tests

# Run $(TEST).S with an instruction trace.
simulate: $(SIM) $(BUILD)/$(TEST).bin
	$(SIM) +bin=$(BUILD)/$(TEST).bin +trace

# Run the official RV32I (rv32ui) tests; logs go to $(BUILD)/rv32ui/<test>.log.
riscv-tests: $(SIM) $(RV32UI_TESTS:%=$(BUILD)/rv32ui/%.bin)
	@fail=0; for t in $(RV32UI_TESTS); do \
	  if $(SIM) +bin=$(BUILD)/rv32ui/$$t.bin > $(BUILD)/rv32ui/$$t.log 2>&1; \
	  then echo "PASS  $$t"; \
	  else echo "FAIL  $$t  ($(BUILD)/rv32ui/$$t.log)"; fail=1; fi; \
	done; exit $$fail

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -f sources.f tb/top.sv --top-module t

dasm: $(BUILD)/$(TEST).elf
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD) obj_dir

$(SIM): $(RTL) tb/top.sv sources.f
	@mkdir -p $(BUILD)
	verilator --binary -j 0 --Mdir $(BUILD)/obj_dir -o Vt -f sources.f tb/top.sv --top-module t

$(BUILD)/rv32ui/%.elf: $(RV32UI_DIR)/%.S test/env/riscv_test.h test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -I test/env -I third_party/riscv-tests/isa/macros/scalar -o $@ $<

$(BUILD)/%.elf: %.S test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@
