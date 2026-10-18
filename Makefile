RISCV_PREFIX ?= riscv64-linux-gnu-
BUILD        ?= build
TEST         ?= test/test

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
NM      := $(RISCV_PREFIX)nm
CFLAGS  := -march=rv32im_zicsr -mabi=ilp32 -static -mcmodel=medany -fno-pie -no-pie \
           -nostdlib -nostartfiles -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
           -T test/link.ld

RTL := $(shell cat sources.f)
SIM := $(BUILD)/obj_dir/Vt

RISCV_TESTS_DIR := third_party/riscv-tests/isa
# <suite>/<test> names, e.g. rv32um/mul. fence_i needs Zifencei (not implemented).
RISCV_TESTS := $(filter-out rv32ui/fence_i, \
                 $(patsubst $(RISCV_TESTS_DIR)/%.S,%, \
                   $(wildcard $(RISCV_TESTS_DIR)/rv32ui/*.S $(RISCV_TESTS_DIR)/rv32um/*.S)))

# Machine-mode tests (TODO.md step 1), built with the official riscv-tests
# "p" environment: rv32mi plus our own test/priv/*.S for what rv32mi does not
# check on an M-only hart. pmpaddr needs PMP and breakpoint needs debug
# triggers (Sdtrig); neither is planned yet.
RISCV_ENV_P := third_party/riscv-tests/env/p
PRIV_TESTS  := $(filter-out rv32mi/pmpaddr rv32mi/breakpoint, \
                 $(patsubst $(RISCV_TESTS_DIR)/%.S,%, \
                   $(wildcard $(RISCV_TESTS_DIR)/rv32mi/*.S)))
OWN_PRIV_TESTS := $(basename $(wildcard test/priv/*.S))

# Address of the `tohost` word in an ELF, for the testbench's +tohost=.
tohost = $$($(NM) $(1) | awk '$$3 == "tohost" { print $$1 }')

# $(call run-tests,<tests>): run $(BUILD)/<test>.bin for each test; one
# PASS/FAIL line per test, log in $(BUILD)/<test>.log, nonzero exit if any
# failed.
define run-tests
@fail=0; for t in $(1); do \
  if $(SIM) +bin=$(BUILD)/$$t.bin +tohost=$(call tohost,$(BUILD)/$$t.elf) > $(BUILD)/$$t.log 2>&1; \
  then echo "PASS  $$t"; \
  else echo "FAIL  $$t  ($(BUILD)/$$t.log)"; fail=1; fi; \
done; exit $$fail
endef

.PHONY: all simulate riscv-tests priv-tests lint dasm clean
# Keep intermediate .elf files for `make dasm` and the tohost lookup.
.SECONDARY:

all: simulate riscv-tests

# Run $(TEST).S with an instruction trace.
simulate: $(SIM) $(BUILD)/$(TEST).bin
	$(SIM) +bin=$(BUILD)/$(TEST).bin +tohost=$(call tohost,$(BUILD)/$(TEST).elf) +trace

# Run rv32ui + rv32um.
riscv-tests: $(SIM) $(RISCV_TESTS:%=$(BUILD)/isa/%.bin)
	$(call run-tests,$(RISCV_TESTS:%=isa/%))

# Run the machine-mode tests.
priv-tests: $(SIM) $(PRIV_TESTS:%=$(BUILD)/isa-p/%.bin) $(OWN_PRIV_TESTS:%=$(BUILD)/%.bin)
	$(call run-tests,$(PRIV_TESTS:%=isa-p/%) $(OWN_PRIV_TESTS))

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

$(BUILD)/isa-p/%.elf: $(RISCV_TESTS_DIR)/%.S $(RISCV_ENV_P)/riscv_test.h test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -I $(RISCV_ENV_P) -I $(RISCV_TESTS_DIR)/macros/scalar -o $@ $<

$(BUILD)/test/priv/%.elf: test/priv/%.S $(RISCV_ENV_P)/riscv_test.h test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -I $(RISCV_ENV_P) -I $(RISCV_TESTS_DIR)/macros/scalar -o $@ $<

$(RISCV_ENV_P)/riscv_test.h:
	$(error $@ is missing; run: git submodule update --init --recursive)

$(BUILD)/%.elf: %.S test/link.ld
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@
