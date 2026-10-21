# ULX3S peripheral drivers: SDRAM controller and SD card (SPI mode) controller.
#   make / make test   - every testbench configuration (exits non-zero on failure)
#   make test-<name>   - one configuration, e.g. make test-sd_sdhc
#   make lint          - Verilator -Wall on the RTL
#   make synth         - yosys + nextpnr-ecp5 (LFE5U-85F) per controller, Fmax check
#   make clean

VERILATOR := verilator
VFLAGS    := --binary --timing --timescale 1ns/1ps -j 0
BUILD     := build
BUILD_TMP := $(CURDIR)/$(BUILD)/tmp

# <name>: top module, sources, parameters.
TESTS := sdram sdram_64mb_cl3_25mhz sdram_cl3_60mhz sdram_slow_timing \
         sd_sdhc sd_sdsc sd_v1 sd_init_fail

SDRAM_SRCS := rtl/sdram.sv tb/models/sdram_model.sv tb/tb_sdram.sv
SD_SRCS    := rtl/sd_spi.sv tb/models/sd_card_model.sv tb/tb_sd_spi.sv

TOP_sdram                 := tb_sdram
SRCS_sdram                := $(SDRAM_SRCS)
TOP_sdram_64mb_cl3_25mhz  := tb_sdram
SRCS_sdram_64mb_cl3_25mhz := $(SDRAM_SRCS)
PARAMS_sdram_64mb_cl3_25mhz := -GCOL_BITS=10 -GCAS_LATENCY=3 -GCLK_MHZ=25
TOP_sdram_cl3_60mhz       := tb_sdram
SRCS_sdram_cl3_60mhz      := $(SDRAM_SRCS)
PARAMS_sdram_cl3_60mhz    := -GCAS_LATENCY=3 -GCLK_MHZ=60
# Timings long enough that each per-bank timer, not the state sequence,
# sets the spacing of commands (tRC > tRAS + tRP, tRRD > ACTIVE-to-ACTIVE
# of back-to-back requests, tWR > write-to-PRECHARGE of the state sequence).
TOP_sdram_slow_timing     := tb_sdram
SRCS_sdram_slow_timing    := $(SDRAM_SRCS)
PARAMS_sdram_slow_timing  := -GT_RCD_NS=60 -GT_RP_NS=60 -GT_RAS_NS=200 -GT_RC_NS=300 \
                             -GT_RRD_NS=200 -GT_WR_NS=60
TOP_sd_sdhc               := tb_sd_spi
SRCS_sd_sdhc              := $(SD_SRCS)
PARAMS_sd_sdhc            := -GCARD=0
TOP_sd_sdsc               := tb_sd_spi
SRCS_sd_sdsc              := $(SD_SRCS)
PARAMS_sd_sdsc            := -GCARD=1
TOP_sd_v1                 := tb_sd_spi
SRCS_sd_v1                := $(SD_SRCS)
PARAMS_sd_v1              := -GCARD=2
TOP_sd_init_fail          := tb_sd_spi
SRCS_sd_init_fail         := $(SD_SRCS)
PARAMS_sd_init_fail       := -GCARD=3

RTL := rtl/sdram.sv rtl/sd_spi.sv

.PHONY: all test $(addprefix test-,$(TESTS)) lint synth clean

all: test

test: $(addprefix test-,$(TESTS))
	@echo "=== All ULX3S driver tests passed ==="

define TEST_template
$(BUILD)/$(1)/V$$(TOP_$(1)): $$(SRCS_$(1))
	@mkdir -p $$(@D) $(BUILD_TMP)
	TMPDIR=$(BUILD_TMP) $(VERILATOR) $(VFLAGS) --top-module $$(TOP_$(1)) $$(PARAMS_$(1)) \
	    --Mdir $$(@D) $$(SRCS_$(1)) > $$(@D)/build.log
test-$(1): $(BUILD)/$(1)/V$$(TOP_$(1))
	@echo "=== $(1) ==="
	@./$$<
endef

$(foreach t,$(TESTS),$(eval $(call TEST_template,$(t))))

lint:
	@for m in $(basename $(notdir $(RTL))); do \
	  $(VERILATOR) --lint-only -Wall rtl/$$m.sv --top-module $$m || exit 1; \
	done

# ------------------------------------------------------------------
# Synthesis check: each controller on its own, IOs placed by nextpnr.
# ------------------------------------------------------------------
YOSYS        ?= yosys
NEXTPNR      ?= nextpnr-ecp5
FPGA_DEVICE  ?= --85k
FPGA_PACKAGE ?= CABGA381
FPGA_SPEED   ?= 6
SYNTH_MHZ    ?= 50

synth: $(foreach m,$(basename $(notdir $(RTL))),$(BUILD)/synth/$(m).pnr.log)
	@for m in $(basename $(notdir $(RTL))); do \
	  printf '%-8s ' $$m; grep 'Max frequency' $(BUILD)/synth/$$m.pnr.log | tail -1; \
	done

$(BUILD)/synth/%.json: rtl/%.sv
	@mkdir -p $(@D) $(BUILD_TMP)
	TMPDIR=$(BUILD_TMP) $(YOSYS) -q -l $(@:.json=.yosys.log) \
	    -p 'read_verilog -sv $<; synth_ecp5 -top $* -json $@'

$(BUILD)/synth/%.pnr.log: $(BUILD)/synth/%.json
	TMPDIR=$(BUILD_TMP) $(NEXTPNR) $(FPGA_DEVICE) --package $(FPGA_PACKAGE) \
	    --speed $(FPGA_SPEED) --freq $(SYNTH_MHZ) --json $< \
	    --textcfg $(@:.pnr.log=.config) -l $@ > /dev/null

clean:
	rm -rf $(BUILD)
