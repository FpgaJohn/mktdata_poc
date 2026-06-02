# mktdata_poc_bm — bare-metal test

Single-file bare-metal app to exercise three pieces of the `mktdata_poc` bitstream:

1. **GPIO accumulator** — `axi_gpio_control` (ch1 = opcode, ch2 = addend) + `axi_gpio_value` (ch1 = sum, ch2 = carry) driving the `my_state` 64-bit accumulator.
2. **`axi_fifo_echo`** — AXI4-Stream FIFO with its `TXD → RXD` looped in PL. Push N words, trigger TLR, pop N words back.
3. **`axi_dma_echo` + `axi_dma_fifo_echo`** — DDR → DMA MM2S → AXI-S FIFO (RX side) → software bridge (RDFD → TDFD + TLR) → AXI-S FIFO (TX side) → DMA S2MM → DDR.

Target: KR260 SOM, ZynqMP ZU5EV, Cortex-A53 #0.

## Address map

Matches `vivado/mktdata_poc.tcl` (HPM0_FPD aperture, `0xA000_0000+`):

| IP                          | Base                 |
|-----------------------------|----------------------|
| `axi_gpio_control`          | `0xA0040000`         |
| `axi_gpio_value`            | `0xA00C0000`         |
| `axi_fifo_echo` (lite)      | `0xA0100000`         |
| `axi_fifo_echo` (full data) | `0xA0110000`         |
| `axi_dma_echo` (lite)       | `0xA00D0000`         |
| `axi_dma_fifo_echo` (lite)  | `0xA00E0000`         |
| `axi_dma_fifo_echo` (data)  | `0xA00F0000`         |

## Build

```bash
source /tools/Xilinx/Vitis/2024.1/settings64.sh
cd apps/mktdata_poc_bm
xsct build.tcl
```

Produces `vitis_ws/mktdata_poc_bm/Debug/mktdata_poc_bm.elf` plus the platform and FSBL Vitis needs at JTAG-load time.

Prerequisite: `vivado/mktdata_poc.xsa` must exist — run `make xsa` in `vivado/` first.

## Run via JTAG

```bash
xsct load.tcl
```

`load.tcl` does:

1. `connect` to the KR260 JTAG cable
2. Stop A53 #0 (hot takeover from Linux) or `rst -system` + `psu_init` (cold JTAG boot — set `COLD_BOOT=1`)
3. `fpga <bit>` (program the PL)
4. Deassert PS-PL isolation, FPD AFI resets, and PS-PL reset
5. `rst -processor` on Cortex-A53 #0
6. `dow <elf>; con`

UART output: 115200 8N1 on whichever `/dev/ttyUSB*` the FTDI on the KR260's J7 enumerated as.

`make run` automates the whole thing — programs PL, downloads the ELF, captures the PS-UART output for `TIMEOUT_S` seconds, then prints it.
