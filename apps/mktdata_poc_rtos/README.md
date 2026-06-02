# mktdata_poc_rtos — FreeRTOS test

Same three exercises as `apps/mktdata_poc_bm`, but the BSP is FreeRTOS
(`freertos10_xilinx`) rather than standalone. A single task wraps:

1. GPIO accumulator (`axi_gpio_control` + `axi_gpio_value` + `my_state`)
2. `axi_fifo_echo` push/pop via the PL-internal `TXD → RXD` loopback
3. `axi_dma_echo` + `axi_dma_fifo_echo` DDR round-trip

Then idles forever (so the output stays on screen).

Target: KR260 SOM, ZynqMP ZU5EV, Cortex-A53 #0 at EL3.

## Build

```bash
source /tools/Xilinx/Vitis/2024.1/settings64.sh
cd apps/mktdata_poc_rtos
xsct build.tcl
```

Produces `vitis_ws/mktdata_poc_rtos/Debug/mktdata_poc_rtos.elf` plus the
FreeRTOS-flavored platform and FSBL Vitis needs at JTAG-load time.

Prerequisite: `vivado/mktdata_poc.xsa` must exist — run `make xsa` in `vivado/` first.

## Run via JTAG

```bash
xsct load.tcl
```

Identical to `apps/mktdata_poc_bm/load.tcl` — the JTAG flow doesn't care that the ELF contains a FreeRTOS scheduler. UART: 115200 8N1 on whichever `/dev/ttyUSB*` the FTDI at J7 enumerated as.

## Differences vs. apps/mktdata_poc_bm

- **BSP**: FreeRTOS (`freertos10_xilinx`) instead of standalone.
- **`main.c`** wraps the test sequence in an `xTaskCreate`'d task and starts the scheduler. DMA buffers stay in `.bss` so they don't blow the task stack.
- Everything else (address map, register layout, log format) is the same.
