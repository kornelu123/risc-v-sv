# ULX3S peripheral drivers

Controllers for the ULX3S board's SDRAM and micro-SD card slot, with
simulation models that check the chips' protocols and timing. They are not
yet connected to the core; that is TODO.md step 3 (bus and memory map).

    rtl/sdram.sv               SDR SDRAM controller (bursts of 32-bit words, open rows)
    rtl/sd_spi.sv              SD card controller, SPI mode (512-byte blocks)
    tb/models/sdram_model.sv   SDRAM model: timing/protocol checks + storage
    tb/models/sd_card_model.sv SD card model (SPI mode): protocol checks + storage
    tb/tb_sdram.sv, tb/tb_sd_spi.sv   self-checking testbenches

    make          # all testbench configurations
    make lint     # Verilator -Wall on the RTL
    make synth    # yosys + nextpnr-ecp5 (LFE5U-85F, CABGA381), Fmax at 50 MHz

## SDRAM (`sdram.sv`)

For the 16-bit SDR SDRAM on ULX3S boards (ISSI IS42S16160G 32 MB, or
compatible 32/64 MB parts). Default timing is the worst case of those parts
(tRCD/tRP 21 ns, tRC/tRFC 66 ns, tRAS 44 ns, tWR 15 ns, refresh every 7.8 µs).

| Signal | Meaning |
|---|---|
| `req_valid`/`req_ready` | request handshake; one request at a time |
| `req_we`, `req_addr`, `req_len` | write?, 32-bit word address of the first word, words - 1 (up to `MAX_BURST` = 8) |
| `req_wdata`, `req_wstrb`, `wr_ready` | write words in order; the current word is taken in each cycle with `wr_ready` |
| `rsp_valid`, `rsp_rdata` | read words in order, one pulse each |
| `init_done` | power-up sequence finished (after ~200 µs) |
| `sdram_*`, `dq_o`/`dq_oe`/`dq_i` | chip pins; the data bus is split for the top-level tristate |

- Word address = `{row, bank, column[COL_BITS-1:1]}`; little-endian, bits 15:0
  of a word are the even column. `COL_BITS = 9` for 32 MB, `10` for 64 MB.
  A row holds 256 (512) words; a burst must not cross the end of a row (an
  aligned cache line never does).
- Bursts: the chip's burst length stays 2 (one word); a request of N words
  is N READ/WRITE commands two cycles apart, which the chip streams at 16 bits
  per cycle.
- Open rows: each bank's row stays open after an access. The same row again
  needs no ACTIVE; another row costs PRECHARGE + ACTIVE; refresh closes all
  rows first. Per-bank timers enforce tRCD/tRAS/tRC/tRP/tWR/tRRD.
- Read latency at 50 MHz, CAS latency 2 (cycles from acceptance to the last
  word, from `tb_sdram`):

  | Access | Cycles |
  |---|---|
  | 1 word, row open | 5 |
  | 8 words, row open | 19 |
  | 8 words, other row open in the bank | 23 |

  Back-to-back 8-word reads stream at ~83 MB/s (the old closed-page,
  one-word-per-access controller: ~33 MB/s).
- Power-up: 200 µs of NOPs, PRECHARGE ALL, 8 refreshes, mode register.
- Clocking: drive `sdram_clk` with the inverted controller clock, so the chip
  samples commands and data mid-cycle. Read data is captured CAS_LATENCY
  cycles after READ, which leaves (T/2 - tAC) of setup time: keep the clock at
  or below about 60 MHz (50 MHz is the design point).

Top-level wiring (ECP5):

```systemverilog
ODDRX1F sdram_clk_out (.D0(1'b0), .D1(1'b1), .SCLK(clk), .RST(1'b0), .Q(sdram_clk));
assign sdram_d = dq_oe ? dq_o : 16'bz;
sdram #(.CLK_MHZ(50)) ram (
  .clk, .rst_n, .req_valid, .req_ready, .req_we, .req_addr, .req_len,
  .req_wdata, .req_wstrb, .wr_ready, .rsp_valid, .rsp_rdata, .init_done,
  .sdram_cke, .sdram_csn, .sdram_rasn, .sdram_casn, .sdram_wen, .sdram_a,
  .sdram_ba, .sdram_dqm, .dq_o, .dq_oe, .dq_i(sdram_d));
```

## SD card (`sd_spi.sv`)

SPI mode, the simplest mode every SD card supports. After reset it
initialises the card on its own at 400 kHz (≥ 74 clocks, CMD0, CMD8,
CMD55+ACMD41, CMD58, CMD16 for standard-capacity cards), then switches to
`FAST_HZ` (12.5 MHz by default, ~1.5 MB/s) and raises `ready`. SDHC/SDXC
(block addressing), SDSC v2 and SD v1 cards are handled.

| Signal | Meaning |
|---|---|
| `ready`, `init_error`, `sdhc` | initialisation result |
| `rd_start`/`wr_start`, `block` | start a 512-byte read/write of block number `block` |
| `rd_valid`, `rd_data` | read bytes, in order |
| `wr_valid`/`wr_ready`, `wr_data` | write bytes, valid/ready handshake |
| `busy`, `done`, `error` | `done` pulses at the end; `error` = rejected, timed out, error token or bad read CRC |

- Commands carry a correct CRC7; write data a CRC16; read data is
  CRC16-checked. Timeouts: 8 bytes for R1, 100 ms for read data, 500 ms for
  write busy, ~1 s for ACMD41.
- One block per command (CMD17/CMD24).

Top-level wiring: `sd_clk = sd_sck`, `sd_cmd = sd_mosi`, `sd_d[3] = sd_cs_n`,
`sd_miso = sd_d[0]`; leave `sd_d[2:1]` undriven. These pins are shared with
the ESP32 module (WiFi_GPIO2/4/12/13/14/15); hold the ESP32 in reset
(`wifi_en` low) or make sure its firmware does not use them.

## Verification

The models stop the simulation with an explanation whenever the controller
breaks a rule:
- **SDRAM model:** the power-up delay, the init sequence and mode register, and
  the tRCD/tRP/tRC/tRAS/tRRD/tWR/tRFC timings (tWR also before an explicit
  PRECHARGE). It also checks the refresh interval, commands to open or closed
  banks, that write data is driven when latched, that DQM stays low while read
  data is pending, that a burst is not cut short by another command, and that
  the data bus is never driven from both sides at once.
- **SD model:** ≥ 74 init clocks, the SCK frequency limits, CRC7 and command
  order, the gap byte before a write token, and the write CRC16. CS must not
  rise mid-byte or with response bytes unread.

The testbenches check data against reference copies, cover corner addresses,
byte strobes and several clock/latency/size configurations, and inject card
errors: an error token, a bad CRC, a rejected write, a missing token, and a
write that stays busy too long. The SDRAM testbench also runs random bursts of
1–8 words over a few rows of two banks (row hits and misses across refreshes),
drives garbage write data outside `wr_ready` cycles, issues a write while a
read's data is still arriving, and requires row hits to take the cycle counts
above. One configuration stretches all timings so that each timer, not the
state sequence, spaces the commands. Breaking the SDRAM controller in 28 ways
(each timer dropped, wrong row tracking, refresh with rows open, missing bus
turnaround, `wr_ready` on the wrong cycle, …) and the SD controller in typical
ways (missing gap byte, wrong CRC, unchecked timeouts, …) made at least one
test fail each time.

Not verified: behaviour on real hardware (board delays, actual cards).
