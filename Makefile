SHELL      := /bin/bash
TCL        := vivado/mktdata_poc.tcl

KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
REMOTE_DIR := /home/$(KR260_USER)

VITIS_SETTINGS ?= /tools/Xilinx/Vitis/2024.1/settings64.sh

MAKEFLAGS += --no-print-directory

.PHONY: help \
        xsa xsa-clean \
        bare-metal-build bare-metal-run bare-metal-clean \
        rtos-build rtos-run rtos-clean \
        test-build test-deploy test-run test-clean \
        kria-build kria-deploy kria-clean \
        info deploy deploy-run \
        jtag-reboot board-reset tty tty-list tty-stop list-all \
        list-resources list-gpio list-fifo list-dma-fifo

help:
	@echo "mktdata_poc — KR260 market data proof-of-concept"
	@echo ""
	@echo "Vivado:"
	@echo "  make xsa               Build Vivado project and export XSA with bitstream"
	@echo "  make xsa-clean         Remove Vivado build artifacts"
	@echo ""
	@echo "Bare-metal (JTAG):"
	@echo "  make bare-metal-build  Build apps/mktdata_poc_bm (Vitis Classic, standalone)"
	@echo "  make bare-metal-run    Program PL + run ELF on Cortex-A53 #0 via JTAG"
	@echo "  make bare-metal-clean  Remove apps/mktdata_poc_bm workspace"
	@echo ""
	@echo "FreeRTOS (JTAG):"
	@echo "  make rtos-build        Build apps/mktdata_poc_rtos (Vitis Classic, FreeRTOS BSP)"
	@echo "  make rtos-run          Program PL + run FreeRTOS ELF on Cortex-A53 #0 via JTAG"
	@echo "  make rtos-clean        Remove apps/mktdata_poc_rtos workspace"
	@echo ""
	@echo "Linux userspace test (aarch64 cross-compile):"
	@echo "  make test-build        Cross-compile apps/mktdata_poc_test (aarch64 Linux)"
	@echo "  make test-deploy       scp the test binary to $(KR260_HOST):/tmp/"
	@echo "  make test-run          Deploy and ssh-run the test binary as root"
	@echo "  make test-clean        Remove apps/mktdata_poc_test binary"
	@echo ""
	@echo "Kria runtime app (dfx-mgr / xmutil):"
	@echo "  make kria-build        Build kria_app/build/mktdata_poc/ package"
	@echo "  make kria-deploy       scp the kria_app package to $(KR260_HOST):~/"
	@echo "  make kria-clean        Remove kria_app/build/"
	@echo ""
	@echo "Board (SSH to $(KR260_USER)@$(KR260_HOST)):"
	@echo "  make info              scp + run scripts/list_uio.sh on the board"
	@echo "  make deploy            scp scripts/* to $(KR260_HOST):~/"
	@echo "  make deploy-run        Install kria app + run /tmp/mktdata_poc_test on the board"
	@echo ""
	@echo "Utilities:"
	@echo "  make jtag-reboot       Reset the KR260 via JTAG (resumes the SD/QSPI boot path)"
	@echo "  make board-reset       System-reset the KR260 PS+PL via JTAG (xsct rst -system)"
	@echo "  make tty               Open KR260 PS-UART (115200 8N1; default: tio, Ctrl-t q to quit)"
	@echo "  make tty-list          List screen sessions and processes holding any /dev/ttyUSB*"
	@echo "  make tty-stop          Kill any screen session attached to the KR260 UART"
	@echo "  make list-all          List all FPGA devices and which USB/tty port they are on"
	@echo ""
	@echo "Design introspection:"
	@echo "  make list-resources    Display all IP blocks in the design"
	@echo "  make list-gpio         Display AXI GPIO IPs"
	@echo "  make list-fifo         Display all FIFO IPs"
	@echo "  make list-dma-fifo     Display AXI Stream data FIFOs"
	@echo ""
	@echo "Help:"
	@echo "  make help              Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  KR260_HOST=$(KR260_HOST)      Board hostname/IP for SSH deploy"
	@echo "  KR260_USER=$(KR260_USER)      Board username"
	@echo "  KR260_UART=$(KR260_UART)  PS-UART device (auto-detected)"
	@echo "  TTY_TOOL=$(TTY_TOOL)           Serial terminal for 'make tty'"

# -- Vivado --------------------------------------------------------------------

xsa:
	$(MAKE) -C vivado xsa

xsa-clean:
	$(MAKE) -C vivado xsa-clean

# -- Bare-metal app (Vitis Classic, standalone, JTAG) --------------------------

bare-metal-build:
	$(MAKE) -C apps/mktdata_poc_bm build

bare-metal-run:
	$(MAKE) -C apps/mktdata_poc_bm run

bare-metal-clean:
	$(MAKE) -C apps/mktdata_poc_bm clean

# -- FreeRTOS app (Vitis Classic, freertos10_xilinx, JTAG) ---------------------

rtos-build:
	$(MAKE) -C apps/mktdata_poc_rtos build

rtos-run:
	$(MAKE) -C apps/mktdata_poc_rtos run

rtos-clean:
	$(MAKE) -C apps/mktdata_poc_rtos clean

# -- Userspace Linux test (aarch64 cross-compile) ------------------------------

test-build:
	$(MAKE) -C apps/mktdata_poc_test all

test-deploy:
	$(MAKE) -C apps/mktdata_poc_test deploy

test-run:
	$(MAKE) -C apps/mktdata_poc_test run

test-clean:
	$(MAKE) -C apps/mktdata_poc_test clean

# -- Kria runtime app (dfx-mgr / xmutil package) -------------------------------

kria-build:
	$(MAKE) -C kria_app package

kria-deploy:
	$(MAKE) -C kria_app deploy

kria-clean:
	$(MAKE) -C kria_app clean

# -- Board-side helpers --------------------------------------------------------

info:
	@echo "==> Copying $(SCRIPT) to $(KR260_USER)@$(KR260_HOST):$(REMOTE_DIR)/"
	scp scripts/$(SCRIPT) $(KR260_USER)@$(KR260_HOST):$(REMOTE_DIR)/
	@echo "==> Running $(SCRIPT) on $(KR260_HOST)"
	ssh $(KR260_USER)@$(KR260_HOST) 'chmod +x $(REMOTE_DIR)/$(SCRIPT) && $(REMOTE_DIR)/$(SCRIPT)'

deploy:
	@scp ./scripts/* $(KR260_USER)@$(KR260_HOST):~/

# End-to-end smoke test: install the freshly-scp'd kria app, load it, and run
# the userspace test. Assumes:
#   - `make kria-deploy`  has put ~/mktdata_poc on the board
#   - `make test-deploy`  has put /tmp/mktdata_poc_test on the board
deploy-run:
	ssh $(KR260_USER)@$(KR260_HOST) ' \
	    sudo rm -rf /lib/firmware/xilinx/mktdata_poc && \
	    sudo mv ~/mktdata_poc /lib/firmware/xilinx/ && \
	    (sudo xmutil unloadapp 2>/dev/null || true) && \
	    sudo xmutil loadapp mktdata_poc && \
	    cat /sys/class/fpga_manager/fpga0/state && \
	    echo 8 | sudo tee /proc/sys/vm/nr_hugepages > /dev/null && \
	    sudo /tmp/mktdata_poc_test test \
	'

# Reboot KR260 via JTAG -- restores normal boot from DIP switches (SD/QSPI).
# Use after a bare-metal or FreeRTOS session to get back to Linux without
# physically power-cycling. Filters for the KR260 cable when multiple boards
# are connected.
jtag-reboot:
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "error: Vitis Classic not found at $(VITIS_SETTINGS)" >&2; \
	    exit 1; \
	fi
	@for dev in /sys/bus/usb/devices/*; do \
	    if [ -f "$$dev/manufacturer" ] && [ "$$(cat $$dev/manufacturer 2>/dev/null)" = "Xilinx" ] && \
	       [ "$$(cat $$dev/idProduct 2>/dev/null)" = "6011" ]; then \
	        intf="$$(basename $$dev):1.0"; \
	        if [ -e "/sys/bus/usb/drivers/ftdi_sio/$$intf" ]; then \
	            echo "==> Unbinding $$intf from ftdi_sio (JTAG channel)"; \
	            echo "$$intf" | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind > /dev/null; \
	        fi; \
	    fi; \
	done
	@echo "==> Rebooting KR260 via JTAG (will boot from DIP switches)"
	@source $(VITIS_SETTINGS) && xsct -eval ' \
	    connect; \
	    targets -set -filter {name =~ "PSU" && jtag_cable_name =~ "Xilinx*"}; \
	    rst -system; \
	    puts "jtag-reboot: system reset issued -- board will boot from DIP switches"; \
	    exit \
	'

# System-reset the KR260 via JTAG (PS + PL). Equivalent to pressing the reset
# button. Unlike jtag-reboot, waits for the reset to settle and disconnects.
board-reset:
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "error: Vitis Classic not found at $(VITIS_SETTINGS)" >&2; \
	    exit 1; \
	fi
	@for dev in /sys/bus/usb/devices/*; do \
	    if [ -f "$$dev/manufacturer" ] && [ "$$(cat $$dev/manufacturer 2>/dev/null)" = "Xilinx" ] && \
	       [ "$$(cat $$dev/idProduct 2>/dev/null)" = "6011" ]; then \
	        intf="$$(basename $$dev):1.0"; \
	        if [ -e "/sys/bus/usb/drivers/ftdi_sio/$$intf" ]; then \
	            echo "==> Unbinding $$intf from ftdi_sio (JTAG channel)"; \
	            echo "$$intf" | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind > /dev/null; \
	        fi; \
	    fi; \
	done
	@echo "==> System-resetting KR260 PS+PL via JTAG"
	@source $(VITIS_SETTINGS) && xsct -eval ' \
	    connect; \
	    targets -set -filter {name =~ "PSU" && jtag_cable_name =~ "Xilinx*"}; \
	    rst -system; \
	    after 1000; \
	    disconnect'
	@echo "==> Reset complete"

# Auto-detect KR260 PS-UART (Xilinx FT4232H, interface 01).
KR260_UART ?= $(or $(shell for dev in /sys/class/tty/ttyUSB*; do \
    mfg=$$(cat "$$dev/device/../../manufacturer" 2>/dev/null); \
    intf=$$(cat "$$(readlink -f $$dev/device/..)/bInterfaceNumber" 2>/dev/null); \
    if [ "$$mfg" = "Xilinx" ] && [ "$$intf" = "01" ]; then \
        echo "/dev/$$(basename $$dev)"; break; \
    fi; \
done),/dev/ttyUSB1)

SCREEN_SESSION ?= kr260-uart

# Open KR260 PS-UART in tio (tmux-friendly; Ctrl-t q to quit).
# Override TTY_TOOL=screen / picocom / minicom if preferred.
TTY_TOOL ?= tio
tty:
	@echo "==> KR260 UART: $(KR260_UART) (115200 8N1) via $(TTY_TOOL)"
	@case "$(TTY_TOOL)" in \
	    tio)     tio -b 115200 -d 8 -p none -s 1 -f none $(KR260_UART) ;; \
	    screen)  screen -S $(SCREEN_SESSION) $(KR260_UART) 115200 ;; \
	    picocom) picocom -b 115200 $(KR260_UART) ;; \
	    minicom) minicom -D $(KR260_UART) -b 115200 ;; \
	    *)       echo "unknown TTY_TOOL=$(TTY_TOOL)" >&2; exit 1 ;; \
	esac

# Kill any screen session whose name contains "kr260". Asks `screen -ls`
# for the session list (immune to the recipe shell's own command line),
# greps for kr260, and runs `screen -X -S <id> quit` on each match.
tty-stop:
	@ids=$$(screen -ls 2>/dev/null | awk '/kr260/ {print $$1}'); \
	if [ -n "$$ids" ]; then \
	    for id in $$ids; do \
	        screen -X -S "$$id" quit && echo "==> killed $$id"; \
	    done; \
	else \
	    echo "==> no kr260 screen session running"; \
	fi

# List screen sessions and any process holding a /dev/ttyUSB* device.
tty-list:
	@echo "==> screen sessions:"
	@out=$$(screen -ls 2>/dev/null | awk '/[0-9]+\./ {print "  " $$0}'); \
	if [ -n "$$out" ]; then echo "$$out"; else echo "  (none)"; fi
	@echo "==> /dev/ttyUSB* holders:"
	@found=0; \
	for dev in /dev/ttyUSB*; do \
	    [ -e "$$dev" ] || continue; \
	    pids=$$(fuser "$$dev" 2>/dev/null); \
	    if [ -n "$$pids" ]; then \
	        for p in $$pids; do \
	            cmd=$$(ps -p $$p -o comm= 2>/dev/null); \
	            args=$$(ps -p $$p -o args= 2>/dev/null); \
	            printf "  %-15s pid=%-7s %s   (%s)\n" "$$dev" "$$p" "$$cmd" "$$args"; \
	        done; \
	        found=1; \
	    fi; \
	done; \
	if [ $$found -eq 0 ]; then echo "  (none)"; fi
	@echo "==> KR260 PS-UART (auto-detected): $(KR260_UART)"

# List all FPGA dev boards: USB serial ports per cable, then the JTAG scan
# chain per cable as seen by xsct (a cable whose JTAG channel is blocked by
# ftdi_sio may appear in the USB list but not the JTAG list).
list-all:
	@echo "==> USB serial ports:"
	@found=0; \
	for dev in /sys/class/tty/ttyUSB*; do \
	    [ -e "$$dev" ] || continue; \
	    mfg=$$(cat "$$dev/device/../../manufacturer" 2>/dev/null); \
	    prod=$$(cat "$$dev/device/../../product" 2>/dev/null); \
	    ser=$$(cat "$$dev/device/../../serial" 2>/dev/null); \
	    intf=$$(cat "$$(readlink -f $$dev/device/..)/bInterfaceNumber" 2>/dev/null); \
	    usbpath=$$(basename "$$(readlink -f $$dev/device/../..)"); \
	    printf "  /dev/%-9s usb=%-10s if=%s  %s %s  serial=%s\n" \
	        "$$(basename $$dev)" "$$usbpath" "$$intf" "$$mfg" "$$prod" "$$ser"; \
	    found=1; \
	done; \
	if [ $$found -eq 0 ]; then echo "  (none)"; fi
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "==> JTAG: skipped (Vitis Classic not found at $(VITIS_SETTINGS))"; \
	    exit 0; \
	fi; \
	echo "==> JTAG scan chains (xsct):"; \
	source $(VITIS_SETTINGS) && xsct -eval ' \
	    connect; \
	    foreach t [jtag targets -target-properties] { \
	        set level [dict get $$t level]; \
	        set name  [dict get $$t name]; \
	        if {$$level == 0} { \
	            puts "  cable: $$name" \
	        } else { \
	            puts "    device: $$name" \
	        } \
	    }; \
	    disconnect' 2>/dev/null | grep -E "cable:|device:" \
	    || echo "  (no JTAG cables found)"

# -- Design resource listing ---------------------------------------------------

list-resources:
	@echo "=== All design resources ==="
	@grep 'create_bd_cell -type ip' $(TCL) | \
	    sed 's/.*-vlnv \([^ ]*\) \([^ ]*\) .*/  \2  (\1)/' | sort

list-gpio:
	@echo "=== GPIO resources ==="
	@grep 'create_bd_cell -type ip' $(TCL) | grep 'axi_gpio' | \
	    sed 's/.*-vlnv \([^ ]*\) \([^ ]*\) .*/  \2  (\1)/' | sort

list-fifo:
	@echo "=== FIFO resources ==="
	@grep 'create_bd_cell -type ip' $(TCL) | grep -i 'fifo' | \
	    sed 's/.*-vlnv \([^ ]*\) \([^ ]*\) .*/  \2  (\1)/' | sort

list-dma-fifo:
	@echo "=== DMA data-path FIFOs (axis_data_fifo) ==="
	@grep 'create_bd_cell -type ip' $(TCL) | grep 'axis_data_fifo' | \
	    sed 's/.*-vlnv \([^ ]*\) \([^ ]*\) .*/  \2  (\1)/' | sort
