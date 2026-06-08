# Installing and loading the `mktdata_poc` app

This packages the Vivado design as a Kria App (XRT_FLAT shell) that can be loaded at runtime on the booted KR260 — no reflash required. It works on the factory Kria firmware as long as `dfx-mgr` / `xmutil` are present (default).

## 1. Build the package on the dev machine

```bash
cd kria_app
make
```

Produces `build/mktdata_poc/` containing:
- `mktdata_poc.bit.bin` — raw bitstream for `fpga_manager`
- `mktdata_poc.dtbo`    — device-tree overlay
- `shell.json`          — Kria manifest

The Makefile pulls `mktdata_poc.bit` out of `../vivado/mktdata_poc.xsa`, runs `bootgen -process_bitstream bin` to convert to the raw format `fpga_manager` needs, and `dtc` to compile the overlay.

## 2. Copy to the KR260

```bash
make deploy           # scp -r build/mktdata_poc/ ubuntu@kr260u:~/
```

## 3. Install into the firmware library and load

On the KR260:

```bash
# Place the app where dfx-mgr looks for it
sudo rm -rf /lib/firmware/xilinx/mktdata_poc
sudo mv ~/mktdata_poc /lib/firmware/xilinx/

# Unload whatever is currently active (the factory design)
sudo xmutil unloadapp

# Load ours
sudo xmutil loadapp mktdata_poc
```

## 4. Verify it took effect

```bash
# 4a. FPGA programmed?
cat /sys/class/fpga_manager/fpga0/state          # -> "operating"

# 4b. /dev/uio* entries for our PL IPs?
for i in /sys/class/uio/uio*; do
    name=$(cat $i/name 2>/dev/null)
    addr=$(cat $i/maps/map0/addr 2>/dev/null)
    echo "$(basename $i): $name @ $addr"
done
```

Seven new UIO entries should appear, mapped to:

| Address     | IP                         |
|-------------|----------------------------|
| `0xa0040000` | `axi_gpio_control`         |
| `0xa00c0000` | `axi_gpio_value`           |
| `0xa0100000` | `axi_fifo_echo` (control)  |
| `0xa0110000` | `axi_fifo_echo` (data)     |
| `0xa00d0000` | `axi_dma_echo`             |
| `0xa00e0000` | `axi_dma_fifo_echo` (ctrl) |
| `0xa00f0000` | `axi_dma_fifo_echo` (data) |

For an end-to-end smoke test from the repo root, run `scripts/gpio.sh` (devmem-only accumulator exerciser), or push the userspace test binary and run all three exercises:

```bash
cd apps/mktdata_poc_test
make
make deploy run
```

## 5. Unload when done

```bash
sudo xmutil unloadapp mktdata_poc
```

This removes the overlay nodes and clears the FPGA. You can now `loadapp` something else without rebooting.

## Troubleshooting

- **`loadapp` fails with `firmware not found`** — the app directory wasn't placed under `/lib/firmware/xilinx/`, or the `.bit.bin` filename inside `mktdata_poc.dtbo` doesn't match `firmware-name` in the dtso (must be `mktdata_poc/mktdata_poc.bit.bin`).
- **`fpga0/state` stays `unknown`** — bootgen produced the wrong bitstream variant. The Makefile passes `-process_bitstream bin`, which is correct; verify `file build/mktdata_poc.bit.bin` reports a raw binary of roughly the same size as `mktdata_poc.bit` extracted from the XSA.
- **Overlay applies but no `/dev/uio*` for our nodes** — `dmesg | grep -iE "uio|generic-uio|fpga|overlay"`. Often the `uio_pdrv_genirq` module didn't rebind to the new of_compatible — try `sudo modprobe -r uio_pdrv_genirq && sudo modprobe uio_pdrv_genirq of_id=generic-uio` (or run `scripts/mod_probe.sh`).
