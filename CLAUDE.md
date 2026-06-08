# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Market data proof-of-concept for the **AMD/Xilinx KR260 Starter Kit** (Zynq UltraScale+ MPSoC, part `xck26-sfvc784-2LV-c`). The FPGA design receives 10G Ethernet frames via an SFP port (Xentech Robotics Card), processes them in PL logic, and transfers packets to the Zynq PS via AXI DMA. The repo also contains software that exercises the design three ways: bare-metal, FreeRTOS, and Linux userspace.

Toolchain: **Vivado / Vitis Classic / PetaLinux 2024.1**, all under `/tools/Xilinx/`. Vitis *Classic* is required (`xsct` is not in the new Vitis Unified IDE). The target board is reachable as ssh host `kr260u` (user `ubuntu`) and via JTAG/UART on the J7 micro-USB.

## Build Commands

Everything is driven from the root `Makefile` (`make help` lists all targets):

```bash
make xsa                # Vivado: create project from TCL, synth + impl, export vivado/mktdata_poc.xsa
make bare-metal-build   # Vitis Classic standalone app (apps/mktdata_poc_bm)
make bare-metal-run     # Program PL + run ELF on Cortex-A53 #0 via JTAG, capture UART to bm.log
make rtos-build         # Same but FreeRTOS BSP (apps/mktdata_poc_rtos)
make rtos-run
make test-build         # Cross-compile Linux userspace test (needs gcc-aarch64-linux-gnu)
make test-run           # scp to kr260u:/tmp/ and run as root over ssh
make kria-build         # Package bitstream as Kria app (bit.bin + dtbo + shell.json) — needs PetaLinux for bootgen/dtc
make kria-deploy        # scp the package to the board
make deploy-run         # Install kria app via xmutil loadapp + run the userspace test (end-to-end smoke test)
make jtag-reboot        # System reset via JTAG — returns board to SD/QSPI Linux boot after a JTAG session
make tty                # Attach screen to the KR260 PS-UART (115200 8N1); make tty-stop to kill it
make list-resources     # grep the BD TCL for all IP blocks (also: list-gpio, list-fifo, list-dma-fifo)
```

Build dependency chain: `make xsa` produces `vivado/mktdata_poc.xsa`, which every app build consumes (the bm/rtos Makefiles auto-build it if missing). The Vivado flow is `vivado/mktdata_poc.tcl` (recreates the project in `vivado/mktdata_poc/`) followed by `vivado/build.tcl` (synth → impl → `write_hw_platform`). There are no simulation testbenches and no automated test suite — verification is running the apps against the real board.

Common overrides: `KR260_HOST=...`, `UART_DEV=/dev/ttyUSB2`, `TIMEOUT_S=30`, `VITIS_SETTINGS=...`, `JOBS=N` (Vivado parallelism).

## Layout

| Path | Contents |
|------|----------|
| `vivado/` | Project TCL, build TCL, merged `constraints.xdc`, and all RTL in `vivado/ip/` |
| `apps/mktdata_poc_bm/` | Bare-metal exerciser (Vitis Classic, standalone BSP, JTAG-loaded) |
| `apps/mktdata_poc_rtos/` | Same tests under FreeRTOS (`freertos10_xilinx` BSP) |
| `apps/mktdata_poc_test/` | Linux userspace exerciser (UIO + /proc/self/pagemap, runs as root on the board) |
| `kria_app/` | dfx-mgr/xmutil runtime-loadable package (bif, dtso, shell.json); see `INSTALL.md` |
| `scripts/` | Board-side helper scripts (list_uio.sh, load_app.sh, …) deployed with `make deploy` |
| `vitis/boot_jtag.tcl` | JTAG boot helper |

The bm/rtos `build.tcl` scripts generate disposable `vitis_ws/` workspaces — never edit inside them; change `main.c`/`build.tcl` and rebuild.

## Hardware Architecture

```
SFP (10G) ─── xxv_ethernet IP ─── XGMII (156.25 MHz, 64-bit)
                                       │
                                  xgmii2axis.v
                                  ┌────┴──────┐
                                  zy_* stream  lv_* stream
                                  (→ AXI DMA   (→ NI FPGA IP
                                   → Zynq PS)   → CMD/DEBUG/MDEBUG
                                                  AXI-S FIFOs)
```

Key RTL in `vivado/ip/`:
- `xgmii2axis.v` / `axis2xgmii.v` — XGMII↔AXI-Stream adapters (preamble/FCS handling, CRC check/insert)
- `xgmii_includes.vh` — XGMII control chars and parallel (non-LFSR) inline CRC-32 functions crc1B–crc8B
- `my_state.v` — 64-bit accumulator driven via GPIO (control opcode + addend in, sum + carry out)
- `NiFpgaAG_poc_ip.v` / `NiFpgaIPWrapper_poc_ip.vhd` — NI LabVIEW FPGA auto-generated market data parsing IP; never hand-edit, re-export from LabVIEW
- `kr260_starter_kit_wrapper.v` — auto-generated BD wrapper (top level); never hand-edit

The block design also contains a self-test path independent of Ethernet: `axi_fifo_echo` (AXI-S FIFO with TXD→RXD looped back in PL) and `axi_dma_echo` + `axi_dma_fifo_echo` (DDR → MM2S → FIFO → S2MM → DDR round trip). All three apps exercise the same three tests: GPIO accumulator, FIFO echo, DMA echo.

### PS Address Map (HPM0_FPD)

Shared by all apps and the device-tree overlay; must match `vivado/mktdata_poc.tcl`:

| IP | Base |
|----|------|
| `axi_gpio_control` (ch1=opcode, ch2=addend) | `0xA0040000` |
| `axi_gpio_value` (ch1=sum, ch2=carry) | `0xA00C0000` |
| `axi_dma_echo` (lite) | `0xA00D0000` |
| `axi_dma_fifo_echo` (lite / data) | `0xA00E0000` / `0xA00F0000` |
| `axi_fifo_echo` (lite / data) | `0xA0100000` / `0xA0110000` |

If you change the address map in the BD, update `apps/*/main.c` and `kria_app/mktdata_poc.dtso` to match.

### Clock Domains

| Domain | Frequency | Used for |
|--------|-----------|----------|
| `Clk40MhzDerived5x2B00MHz` | 100 MHz | AXI/PS control, AXI DMA |
| `Clk40MhzDerived168x43B56_28MHz` | 156.25 MHz | XGMII, xgmii2axis, axis2xgmii, NI FPGA IP data path |

## Key RTL Conventions

- **TUSER**: in both XGMII adapters, `TUSER[0] = 1` means a **good** frame (CRC pass + valid terminator) — inverted from the typical error convention.
- **Lane alignment**: XGMII frames may start on lane 0 or lane 4; both adapters handle both.
- **DIC**: `axis2xgmii` keeps a 2-bit Deficit Idle Count for 802.3 IPG compliance when frames terminate mid-quadword.

## Board Workflow Notes

- The Kria runtime flow (no reflash): `make kria-build kria-deploy`, then on the board move the package to `/lib/firmware/xilinx/` and `sudo xmutil unloadapp && sudo xmutil loadapp mktdata_poc`. Verify with `/sys/class/fpga_manager/fpga0/state` → `operating` and `/dev/uio*` entries. Details in `kria_app/INSTALL.md`.
- The userspace test needs hugepages: `echo 8 | sudo tee /proc/sys/vm/nr_hugepages` (done automatically by `make deploy-run`).
- After a JTAG (bare-metal/FreeRTOS) session, `make jtag-reboot` restores the normal SD/QSPI Linux boot without a power cycle.
- UART auto-detection: the Makefiles find the KR260 PS-UART by looking for the Xilinx FT4232H, interface 01.
