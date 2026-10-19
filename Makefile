RISCV_PREFIX ?= riscv64-linux-gnu-
BUILD        ?= build
TEST         ?= test/test

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
NM      := $(RISCV_PREFIX)nm
CFLAGS  := -march=rv32ima_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany -fno-pie -no-pie \
           -nostdlib -nostartfiles -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
           -T test/link.ld

RTL := $(shell cat sources.f)
SIM := $(BUILD)/obj_dir/Vt

RISCV_TESTS_DIR := third_party/riscv-tests/isa
# <suite>/<test> names, e.g. rv32um/mul.
RISCV_TESTS := $(patsubst $(RISCV_TESTS_DIR)/%.S,%, \
                 $(wildcard $(RISCV_TESTS_DIR)/rv32ui/*.S $(RISCV_TESTS_DIR)/rv32um/*.S \
                            $(RISCV_TESTS_DIR)/rv32ua/*.S))
# Our own tests in the same minimal environment, for what riscv-tests does not
# cover (e.g. hazards around the multi-cycle divider).
OWN_ISA_TESTS := $(basename $(wildcard test/isa/*.S))

# Machine-mode tests (TODO.md step 1), built with the official riscv-tests
# "p" environment: rv32mi plus our own test/priv/*.S for what rv32mi does not
# check on an M-only hart. pmpaddr needs PMP and breakpoint needs debug
# triggers (Sdtrig); neither is planned yet.
RISCV_ENV_P := third_party/riscv-tests/env/p
PRIV_TESTS  := $(filter-out rv32mi/pmpaddr rv32mi/breakpoint, \
                 $(patsubst $(RISCV_TESTS_DIR)/%.S,%, \
                   $(wildcard $(RISCV_TESTS_DIR)/rv32mi/*.S)))
OWN_PRIV_TESTS := $(basename $(wildcard test/priv/*.S))

# Address of symbol $(2) in ELF $(1), empty if it is not defined.
sym = $$($(NM) $(1) | awk '$$3 == "$(2)" { print $$1 }')

# Testbench arguments for ELF $(1): the image, the `tohost` word, and the
# optional `irq_lines` word that drives the interrupt inputs.
sim-args = +bin=$(1:.elf=.bin) +tohost=$(call sym,$(1),tohost) \
           $$(a=$(call sym,$(1),irq_lines); [ -n "$$a" ] && echo +irq=$$a)

# $(call run-tests,<tests>): run $(BUILD)/<test>.bin for each test; one
# PASS/FAIL line per test, log in $(BUILD)/<test>.log, nonzero exit if any
# failed.
define run-tests
@fail=0; for t in $(1); do \
  if $(SIM) $(call sim-args,$(BUILD)/$$t.elf) > $(BUILD)/$$t.log 2>&1; \
  then echo "PASS  $$t"; \
  else echo "FAIL  $$t  ($(BUILD)/$$t.log)"; fail=1; fi; \
done; exit $$fail
endef

.PHONY: all simulate riscv-tests priv-tests lint dasm clean
# Keep intermediate .elf files for `make dasm` and the tohost lookup.
.SECONDARY:

all: simulate riscv-tests priv-tests

# Run $(TEST).S with an instruction trace.
simulate: $(SIM) $(BUILD)/$(TEST).bin
	$(SIM) $(call sim-args,$(BUILD)/$(TEST).elf) +trace

# Run rv32ui + rv32um + rv32ua and test/isa/*.S.
riscv-tests: $(SIM) $(RISCV_TESTS:%=$(BUILD)/isa/%.bin) $(OWN_ISA_TESTS:%=$(BUILD)/%.bin)
	$(call run-tests,$(RISCV_TESTS:%=isa/%) $(OWN_ISA_TESTS))

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

$(BUILD)/test/isa/%.elf: test/isa/%.S test/env/riscv_test.h test/link.ld
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
