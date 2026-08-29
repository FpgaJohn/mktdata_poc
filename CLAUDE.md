# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Market data proof-of-concept for the **AMD/Xilinx KR260 Starter Kit** (Zynq UltraScale+ MPSoC, part `xck26-sfvc784-2LV-c`). The FPGA design receives 10G Ethernet frames via an SFP port (Xentech Robotics Card), processes them in PL logic, and transfers packets to the Zynq PS via AXI DMA. The repo also contains software that exercises the design three ways: bare-metal, FreeRTOS, and Linux userspace.

Toolchain: **Vivado / Vitis Classic / PetaLinux 2024.1**, all under `/tools/Xilinx/`. Vitis *Classic* is required (`xsct` is not in the new Vitis Unified IDE). The target board is reachable as ssh host `kr260u` (user `ubuntu`) and via JTAG/UART on the J7 micro-USB.

## Build Commands

Everything is driven from the root `Makefile` (`make help` lists all targets):

```bash
make xsa                # Vivado: create project from TCL, synth + impl, export vivado/mktdata_poc.xsa
make xsa-clean          # Remove Vivado build artifacts — REQUIRED before rebuilding after a LabVIEW netlist re-import (make xsa does not track it)
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
make kria-reload-app    # Unload then load (reapplies the overlay after a redeploy)
make jtag-reboot        # JTAG system reset (xsct rst -system) — UNRELIABLE for returning to Linux; power-cycle instead
                        # (make board-reset is the same rst -system with a settle+disconnect — same caveat)
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
| `scripts/` | Board-side helper scripts; `make board-setup` scp's+chmods them, `make board-info` runs list_uio.sh. Notable: `setup_host.sh` (reserve hugepages), `gpio.sh` / `fifo_probe.sh` (drive the accumulator / FIFO echo via `devmem` only — exercise the PL without the compiled test), `mod_probe.sh` (rebind `uio_pdrv_genirq` with `of_id=generic-uio`), `load_app.sh`/`update_app.sh`/`list_apps.sh` (xmutil app management) |
| `vitis/boot_jtag.tcl` | JTAG boot helper |
| `todo.txt` | Running design-decision log — the authoritative record of *why* things are the way they are (the LPD control-plane move, the `simple_fifo` swap). Read it before changing the BD |
| `recommendations.txt` / `advice.txt` / `advice.pipeline.txt` | LabVIEW-IP timing-closure playbook (untracked). `advice.pipeline.txt` is the current action item: where to put the Feedback Node in `bats.parser.vi` to close the remaining -0.25 ns (exact wire, consistency rules, rebuild flow). `recommendations.txt` is the routed-DCP analysis (root cause: data-dependent barrel shifters from variable field offsets in `new_uxx_be`/`AddOrder`/`add_data_to_buffer`); `advice.txt` is the click-by-click LabVIEW version. Per-VI screenshots in the root `*.pdf` (`new.uxx.be.pdf`, `AddOrder.pdf`, `add.data.to.buffer.pdf`, `zero.out.and.convert.pdf`, …). The fixes are made in LabVIEW and re-exported, never here |

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
- `simple_fifo.v` — custom AXI4-Lite push/pop FIFO (imported from `kr260_hw`); drop-in replacement for the standalone echo FIFO. Register map: push `0x00` W / pop `0x00` R, count `0x04`, status `0x08` (bit0 empty, bit1 full), clear `0x0C`. 256-entry, 32-bit storage (a 64-bit word is two pushes, LSB first)
- `NiFpgaAG_poc_ip_kria.v` / `NiFpgaIPWrapper_poc_ip_kria.vhd` — NI LabVIEW FPGA auto-generated market-data parsing IP; never hand-edit, re-export from LabVIEW. The BD uses `NiFpgaIPWrapper_poc_ip` as a **module reference**, so the netlist must be a *resolvable RTL/netlist source*: an encrypted Verilog netlist (`.v`), not a `.dcp`. LabVIEW now exports the netlist as a synthesized checkpoint (`NiFpgaAG_poc_ip_kria.dcp`, lives in `/mnt/c/NIFPGA/…/source_files/`); adding that `.dcp` directly makes the BD fail with `[BD::TCL 103-2021] module … not found`. Convert it once — `open_checkpoint …_kria.dcp; write_verilog -force -mode design vivado/ip/NiFpgaAG_poc_ip_kria.v` — and commit the `.v`. The BD's three output streams (DEBUG/CMD/MDEBUG) expose `TREADY` inputs wired back to the corresponding `axi_fifo_*/axi_str_rxd_tready` for real backpressure. NOTE: as of the 2026-07-26 LabVIEW re-export the design **closes timing** — post-route WNS **+0.863 ns**, 0 failing endpoints (was -0.25 after the 2026-07-14 barrel-shifter rework + the `clk_pl_0`↔`S02_ACLK_1` `set_max_delay -datapath_only` CDC exceptions in `constraints.xdc`; see `todo.txt` #21/#22). The old choke point (`zero.out.and.convert`'s `(1<<8n)-1` CARRY8 decrement) is gone; the new worst path ends in a Feedback Node register inside `bats.parser.vi`. Hardware re-verification of the parser output is still pending (see todo #22). When re-importing a LabVIEW export, remember `make xsa` does **not** track the netlist — run `make xsa-clean` first or the rebuild silently no-ops
- `kr260_starter_kit_wrapper.v` — auto-generated BD wrapper (top level); never hand-edit

The block design also contains a self-test path independent of Ethernet: a **FIFO echo** and a **DMA echo** — `axi_dma_echo` streams DDR → MM2S → a pure-PL `axis_data_fifo` passthrough → S2MM → DDR (a post-processing block in the TCL, ~line 2071, wires this; the earlier CPU-bridged `axi_fifo_mm_s` loopback swapped 32-bit halves). `axi_dma_fifo_echo` remains only as a self-loopback so no ports dangle. The DMA needs `PSU__AFI0_COHERENCY {1}` (TCL), `c_addr_width {49}` + the DDR_HIGH mapping (Linux hugepages sit above 4 GB), and `dma-coherent;` in the dtso — remove any of these and the DMA hangs under Linux while still passing in bare-metal. All three apps exercise the same three tests: GPIO accumulator, FIFO echo, DMA echo.

**FIFO-echo IP: `simple_fifo` is the settled choice (todo.txt #18/#19 — do not revisit without new evidence).** The TCL first instantiates `axi_fifo_echo` (Xilinx `axi_fifo_mm_s`), then a post-processing block at the *end* of `cr_bd_kr260_starter_kit` (`vivado/mktdata_poc.tcl` ~line 2086) **deletes it and swaps in `simple_fifo_echo`** (the custom `simple_fifo.v`) at the same `0x80100000`. The 2026-06-11 investigation (#19) confirmed `axi_fifo_mm_s` *cannot* drive a TXD→RXD echo from Linux userspace: each 64-bit UIO/MMIO store to its AXI4 data port lands as ~2 beats, breaking packet framing → Transmit Size Error on every TLR commit (bare-metal passes; not TLR units, not the compiler, not master width). `axi_fifo_mm_s` is kept only for RX-only capture (`cmd`/`debug`/`mdebug`, `C_USE_TX_DATA=0` → no TX → no TSE).

**32-bit PIO ceiling (todo.txt #19/#20 — hard platform constraints, all proven on hw):**
- Register PIO from Linux userspace (UIO mmap) to the PL **narrows to 32-bit** on the APU→HPM path regardless of BD widths — even explicit `str x` to a fully 64-bit AXI path loses the high word. Move real 64-bit data with the DMA engine; `simple_fifo`'s paired 32-bit pushes are the PIO ceiling.
- The shared **HPM0_LPD master must stay 32-bit** (it defaults to 32; the TCL does not override it — do not add a wider `PSU__MAXIGP2__DATA_WIDTH`). A 64/128-bit master breaks the dual-channel GPIO (ch2 `+0x08` addend writes vanish) and the `axi_interconnect` 64→32 downsizer drops writes to the high half of a 64-bit word (`addr[2]=1`, e.g. DMA `CURDESC_MSB`).
- Replacing `slave_axi_mux` with smartconnect is dead: smartconnect caps at 16 MI for mixed-width slaves and we have 18.

### PS Address Map (HPM0_LPD)

Shared by all apps and the device-tree overlay; must match `vivado/mktdata_poc.tcl`. All PL control-plane slaves hang off **`M_AXI_HPM0_LPD`** (the `0x80xx_xxxx` aperture) via the 18-way `slave_axi_mux` interconnect — **not** HPM0_FPD/`0xA0xx_xxxx`. The FPD→LPD move (`todo.txt` #17/#18) is what fixed the dual-channel GPIO and the DMA hang under Linux — though #19 later showed the GPIO part was really the *narrow* master (LPD defaults to 32-bit), not the aperture itself.

| IP | Base |
|----|------|
| `axi_gpio_control` (ch1=opcode, ch2=addend) | `0x80040000` |
| `axi_gpio_value` (ch1=sum, ch2=carry) | `0x800C0000` |
| `axi_dma_echo` (lite) | `0x800D0000` |
| `axi_dma_fifo_echo` (lite / data) | `0x800E0000` / `0x800F0000` |
| `simple_fifo_echo` (formerly `axi_fifo_echo`) | `0x80100000` |

(`apps/mktdata_poc_test/main.c` also maps the market-data debug FIFOs and `axi_gpio_1` in the same aperture: `axi_fifo_mdebug` `0x80050000`, `axi_fifo_debug` `0x80070000`, `axi_fifo_cmd` `0x800A0000`, `axi_gpio_1` `0x80090000`, each ctrl/data 0x10000 apart.)

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
- **`axi_fifo_mm_s` RLR is fault-prone when empty**: reading the RLR register with no complete frame in the RX FIFO raises a bus error (SIGBUS in userspace). Always gate the RLR read on `RDFO >= expected_words` first — `apps/mktdata_poc_test/main.c` does this in the DMA-FIFO-echo path. (The `simple_fifo` echo path has no RLR — poll `count`@`0x04` / `status`@`0x08` instead.)

## Board Workflow Notes

- The Kria runtime flow (no reflash): `make kria-build kria-stage kria-deploy-staged kria-load-app` (or do the install/load steps manually: move the package to `/lib/firmware/xilinx/` and `sudo xmutil unloadapp && sudo xmutil loadapp mktdata_poc`). Verify with `/sys/class/fpga_manager/fpga0/state` → `operating` and `/dev/uio*` entries. Details in `kria_app/INSTALL.md`.
- **dfx-mgr wedges on redeploy** ("remove from slot 0 returns: -1"): clear with `sudo rmdir /sys/kernel/config/device-tree/overlays/mktdata_poc_image_*` on the board, then reload the app.
- The userspace test needs hugepages: `echo 8 | sudo tee /proc/sys/vm/nr_hugepages` (or run `scripts/setup_host.sh` on the board, which the DMA-echo path's 2 MiB hugepage depends on).
- **To return to Linux after a JTAG (bare-metal/FreeRTOS) session, power-cycle the board.** `make jtag-reboot` (a JTAG `rst -system`) is *not* reliable for this — the bare-metal session latches a halt-on-reset (reset-catch) state in the A53 debug logic, so a soft system reset just re-halts the core at the reset vector (silent UART, no boot) instead of running BootROM→FSBL→U-Boot→Linux. That latched state survives JTAG disconnect and even killing `hw_server`; only a power-on reset clears it. The board has no boot-mode DIP switches — it boots Linux by default on every power cycle.
- UART auto-detection: the Makefiles find the KR260 PS-UART by looking for the Xilinx FT4232H, interface 01.
- **`load.tcl` JTAG quirks** (`apps/mktdata_poc_bm/load.tcl`), all hard-won:
  - **Physical writes target `PSU`, not the A53 core.** The PS-PL isolation-removal / FCLKRESETN writes hit LPD/FPD SLCR by physical address; with Linux's MMU on, issuing them through `Cortex-A53 #0` takes a translation fault. Select the **`PSU`** node — its DAP MEM-AP accesses are physical and bypass the core MMU. (There is no target literally named `DAP` in this board's xsct tree — that was a bug; `PSU` is that node.)
  - **`psu_init` does *not* release the PL.** It omits PS-PL isolation removal + reset release (that's `psu_post_config` in the FSBL). Both the hot and cold paths must run `psu_ps_pl_isolation_removal` + AFI deassert + `psu_ps_pl_reset_config` afterward, or the first AXI access to a PL slave hangs the core.
  - **Cold boot (`COLD_BOOT=1`) extras:** halt Cortex-A53 #0 (`stop`) after `rst -system` before sourcing `psu_init` (else `psu_init` writes fail "not stopped"); and wrap `::xsdb::mask_write`/`::xsdb::mask_poll` to tolerate AXI-AP faults on the unpowered USB/SATA/DP PHY registers (e.g. `0xFE20C200`) that `psu_init`'s serdes/resetout step would otherwise abort on. Override in the `::xsdb` namespace — `init_ps` resolves those names there, so a global override is bypassed.
