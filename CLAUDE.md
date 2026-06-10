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
make poc-build          # Cross-compile Linux userspace test (needs gcc-aarch64-linux-gnu)
make poc-run            # scp to kr260u:/home/ubuntu/ and run as root over ssh
make kria-build         # Package bitstream as Kria app (bit.bin + dtbo + shell.json) — needs PetaLinux for bootgen/dtc
make kria-stage         # scp the package to the board
make kria-deploy-staged # Copy the staged package into /lib/firmware/xilinx/ (overwrite)
make kria-load-app      # Load the app on the board (xmutil loadapp)
make jtag-reboot        # JTAG system reset (xsct rst -system) — UNRELIABLE for returning to Linux; power-cycle instead
make tty                # Open the KR260 PS-UART in tio (115200 8N1); make tty-stop frees the port
make list-resources     # grep the BD TCL for all IP blocks (also: list-gpio, list-fifo, list-dma-fifo)
```

Build dependency chain: `make xsa` produces `vivado/mktdata_poc.xsa`, which every app build consumes (the bm/rtos Makefiles auto-build it if missing). The Vivado flow is `vivado/mktdata_poc.tcl` (recreates the project in `vivado/mktdata_poc/`) followed by `vivado/build.tcl` (synth → impl → `write_hw_platform`). There are no simulation testbenches and no automated test suite — verification is running the apps against the real board.

Common overrides: `KR260_HOST=...`, `KR260_UART=/dev/ttyUSB2` (else auto-detected), `TIMEOUT_S=30`, `VITIS_SETTINGS=...`, `JOBS=N` (Vivado parallelism).

## Layout

| Path | Contents |
|------|----------|
| `vivado/` | Project TCL, build TCL, merged `constraints.xdc`, and all RTL in `vivado/ip/` |
| `apps/mktdata_poc_bm/` | Bare-metal exerciser (Vitis Classic, standalone BSP, JTAG-loaded) |
| `apps/mktdata_poc_rtos/` | Same tests under FreeRTOS (`freertos10_xilinx` BSP) |
| `apps/mktdata_poc_test/` | Linux userspace exerciser (UIO + /proc/self/pagemap, runs as root on the board) |
| `kria_app/` | dfx-mgr/xmutil runtime-loadable package (bif, dtso, shell.json); see `INSTALL.md` |
| `scripts/` | Board-side helper scripts; `make board-setup` scp's+chmods them, `make board-info` runs list_uio.sh. Notable: `setup_host.sh` (reserve hugepages), `gpio.sh` (drive the accumulator via `devmem` only — exercise GPIO without the compiled test), `load_app.sh`/`update_app.sh` (xmutil app management) |
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
- **AXI-S FIFO RLR is fault-prone when empty**: reading the `axi_fifo_*` RLR register with no complete frame in the RX FIFO raises a bus error (SIGBUS in userspace). Always gate the RLR read on `RDFO >= expected_words` first — `apps/mktdata_poc_test/main.c` does this in both the FIFO-echo and DMA-FIFO-echo paths.

## Board Workflow Notes

- The Kria runtime flow (no reflash): `make kria-build kria-stage kria-deploy-staged kria-load-app` (or do the install/load steps manually: move the package to `/lib/firmware/xilinx/` and `sudo xmutil unloadapp && sudo xmutil loadapp mktdata_poc`). Verify with `/sys/class/fpga_manager/fpga0/state` → `operating` and `/dev/uio*` entries. Details in `kria_app/INSTALL.md`.
- The userspace test needs hugepages: `echo 8 | sudo tee /proc/sys/vm/nr_hugepages` (or run `scripts/setup_host.sh` on the board, which the DMA-echo path's 2 MiB hugepage depends on).
- **To return to Linux after a JTAG (bare-metal/FreeRTOS) session, power-cycle the board.** `make jtag-reboot` (a JTAG `rst -system`) is *not* reliable for this — the bare-metal session latches a halt-on-reset (reset-catch) state in the A53 debug logic, so a soft system reset just re-halts the core at the reset vector (silent UART, no boot) instead of running BootROM→FSBL→U-Boot→Linux. That latched state survives JTAG disconnect and even killing `hw_server`; only a power-on reset clears it. The board has no boot-mode DIP switches — it boots Linux by default on every power cycle.
- UART auto-detection: the Makefiles find the KR260 PS-UART by looking for the Xilinx FT4232H, interface 01.
- **`load.tcl` JTAG quirks** (`apps/mktdata_poc_bm/load.tcl`), all hard-won:
  - **Physical writes target `PSU`, not the A53 core.** The PS-PL isolation-removal / FCLKRESETN writes hit LPD/FPD SLCR by physical address; with Linux's MMU on, issuing them through `Cortex-A53 #0` takes a translation fault. Select the **`PSU`** node — its DAP MEM-AP accesses are physical and bypass the core MMU. (There is no target literally named `DAP` in this board's xsct tree — that was a bug; `PSU` is that node.)
  - **`psu_init` does *not* release the PL.** It omits PS-PL isolation removal + reset release (that's `psu_post_config` in the FSBL). Both the hot and cold paths must run `psu_ps_pl_isolation_removal` + AFI deassert + `psu_ps_pl_reset_config` afterward, or the first AXI access to a PL slave hangs the core.
  - **Cold boot (`COLD_BOOT=1`) extras:** halt Cortex-A53 #0 (`stop`) after `rst -system` before sourcing `psu_init` (else `psu_init` writes fail "not stopped"); and wrap `::xsdb::mask_write`/`::xsdb::mask_poll` to tolerate AXI-AP faults on the unpowered USB/SATA/DP PHY registers (e.g. `0xFE20C200`) that `psu_init`'s serdes/resetout step would otherwise abort on. Override in the `::xsdb` namespace — `init_ps` resolves those names there, so a global override is bypassed.
