SHELL      := /bin/bash
TCL        := vivado/mktdata_poc.tcl

KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
SCRIPTS    := list_uio.sh setup_host.sh
REMOTE_DIR := /home/$(KR260_USER)

VITIS_SETTINGS ?= /tools/Xilinx/Vitis/2024.1/settings64.sh

MAKEFLAGS += --no-print-directory

.PHONY: help \
        help-vivado help-bare-metal help-rtos help-poc help-kria \
        help-board help-util help-design help-vars \
        xsa xsa-clean \
        bare-metal-build bare-metal-run bare-metal-clean \
        rtos-build rtos-run rtos-clean \
        poc-build poc-deploy poc-run poc-clean \
        kria-build kria-stage kria-clean kria-list-staged kria-list-apps \
        kria-unload-app kria-deploy-staged kria-load-app kria-reload-app \
        board-setup board-info \
        jtag-reboot board-reset tty tty-list tty-stop list-all \
        list-resources list-gpio list-fifo list-dma-fifo

# Full help: title, every section, then variables. Each section is also a
# standalone target (help-vivado, help-util, ...) that prints just that block.
help:
	@echo "mktdata_poc — KR260 market data proof-of-concept"
	@echo ""
	@$(MAKE) help-vivado
	@echo ""
	@$(MAKE) help-bare-metal
	@echo ""
	@$(MAKE) help-rtos
	@echo ""
	@$(MAKE) help-poc
	@echo ""
	@$(MAKE) help-kria
	@echo ""
	@$(MAKE) help-board
	@echo ""
	@$(MAKE) help-util
	@echo ""
	@$(MAKE) help-design
	@echo ""
	@echo "Help:"
	@echo "  make help              Show this help (all sections)"
	@echo "  make help-vivado       Vivado section only (also: help-bare-metal,"
	@echo "                         help-rtos, help-poc, help-kria, help-board,"
	@echo "                         help-util, help-design, help-vars)"
	@echo ""
	@$(MAKE) help-vars

help-vivado:
	@echo "Vivado:"
	@echo "  make xsa               Build Vivado project and export XSA with bitstream"
	@echo "  make xsa-clean         Remove Vivado build artifacts"

help-bare-metal:
	@echo "Bare-metal (JTAG):"
	@echo "  make bare-metal-build  Build apps/mktdata_poc_bm (Vitis Classic, standalone)"
	@echo "  make bare-metal-run    Program PL + run ELF on Cortex-A53 #0 via JTAG"
	@echo "  make bare-metal-clean  Remove apps/mktdata_poc_bm workspace"

help-rtos:
	@echo "FreeRTOS (JTAG):"
	@echo "  make rtos-build        Build apps/mktdata_poc_rtos (Vitis Classic, FreeRTOS BSP)"
	@echo "  make rtos-run          Program PL + run FreeRTOS ELF on Cortex-A53 #0 via JTAG"
	@echo "  make rtos-clean        Remove apps/mktdata_poc_rtos workspace"

help-poc:
	@echo "Linux userspace POC (aarch64 cross-compile):"
	@echo "  make poc-build         Cross-compile apps/mktdata_poc_test (aarch64 Linux)"
	@echo "  make poc-deploy        scp the test binary to $(KR260_HOST):/home/ubuntu/"
	@echo "  make poc-run           Deploy and ssh-run the test binary as root"
	@echo "  make poc-clean         Remove apps/mktdata_poc_test binary"

help-kria:
	@echo "Kria runtime app (dfx-mgr / xmutil):"
	@echo "  make kria-build        Build kria_app/build/mktdata_poc/ package"
	@echo "  make kria-stage        scp the kria_app package to $(KR260_HOST):~/"
	@echo "  make kria-clean        Remove kria_app/build/"
	@echo "  make kria-list-staged  ls -l the staged package on the board, compare to local"
	@echo "  make kria-list-apps    List all xmutil apps and their status on the board"
	@echo "  make kria-unload-app   Unload the currently loaded xmutil app on the board"
	@echo "  make kria-deploy-staged  Copy the staged app into /lib/firmware/xilinx/ (overwrite)"
	@echo "  make kria-load-app     Load the kria app on the board (xmutil loadapp)"
	@echo "  make kria-reload-app   Unload then load the app (reapplies the overlay)"

help-board:
	@echo "Board (SSH to $(KR260_USER)@$(KR260_HOST)):"
	@echo "  make board-setup       scp helper scripts ($(SCRIPTS)) to the board"
	@echo "  make board-info        Run scripts/list_uio.sh on the board (list UIO devices)"

help-util:
	@echo "Utilities:"
	@echo "  make jtag-reboot       JTAG system reset (unreliable for return-to-Linux; power-cycle instead)"
	@echo "  make board-reset       System-reset the KR260 PS+PL via JTAG (xsct rst -system)"
	@echo "  make tty               Open KR260 PS-UART in tio (115200 8N1; Ctrl-t q to quit)"
	@echo "  make tty-list          List processes holding any /dev/ttyUSB*"
	@echo "  make tty-stop          Free the KR260 UART (kill whatever process holds it)"
	@echo "  make list-all          List all FPGA devices and which USB/tty port they are on"

help-design:
	@echo "Design introspection:"
	@echo "  make list-resources    Display all IP blocks in the design"
	@echo "  make list-gpio         Display AXI GPIO IPs"
	@echo "  make list-fifo         Display all FIFO IPs"
	@echo "  make list-dma-fifo     Display AXI Stream data FIFOs"

help-vars:
	@echo "Variables:"
	@echo "  KR260_HOST=$(KR260_HOST)      Board hostname/IP for SSH deploy"
	@echo "  KR260_USER=$(KR260_USER)      Board username"
	@echo "  KR260_UART=$(KR260_UART)  PS-UART device (auto-detected)"

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

# -- Userspace Linux POC (aarch64 cross-compile) -------------------------------

poc-build:
	$(MAKE) -C apps/mktdata_poc_test all

poc-deploy:
	$(MAKE) -C apps/mktdata_poc_test deploy

poc-run:
	$(MAKE) -C apps/mktdata_poc_test run

poc-clean:
	$(MAKE) -C apps/mktdata_poc_test clean

# -- Kria runtime app (dfx-mgr / xmutil package) -------------------------------

kria-build:
	$(MAKE) -C kria_app package

kria-stage:
	$(MAKE) -C kria_app stage

kria-clean:
	$(MAKE) -C kria_app clean

kria-list-staged:
	$(MAKE) -C kria_app list-staged

kria-list-apps:
	$(MAKE) -C kria_app list-apps

kria-unload-app:
	$(MAKE) -C kria_app unload-app

kria-deploy-staged:
	$(MAKE) -C kria_app deploy-staged

kria-load-app:
	$(MAKE) -C kria_app load-app

kria-reload-app:
	$(MAKE) -C kria_app reload-app

# -- Board-side helpers --------------------------------------------------------

board-setup:
	@echo "==> Copying scripts to $(KR260_USER)@$(KR260_HOST):$(REMOTE_DIR)/"
	@for s in $(SCRIPTS); do \
	    echo "  $$s"; \
	    scp scripts/$$s $(KR260_USER)@$(KR260_HOST):$(REMOTE_DIR)/ && \
	    ssh $(KR260_USER)@$(KR260_HOST) "chmod +x $(REMOTE_DIR)/$$s"; \
	done

board-info:
	@echo "==> Running $(SCRIPT) on $(KR260_HOST)"
	ssh $(KR260_USER)@$(KR260_HOST) 'chmod +x $(REMOTE_DIR)/$(SCRIPT) && $(REMOTE_DIR)/$(SCRIPT)'

# Reboot KR260 via JTAG (xsct rst -system). NOTE: this is UNRELIABLE for
# returning to Linux after a bare-metal/FreeRTOS session -- the session latches
# a halt-on-reset (reset-catch) state in the A53 debug logic, so the soft
# system reset just re-halts the core at the reset vector (silent UART, no
# boot). That state survives JTAG disconnect; only a power-on reset clears it.
# To get back to Linux, POWER-CYCLE the board (it boots Linux by default; there
# are no boot-mode DIP switches). Filters for the KR260 cable when multiple
# boards are connected.
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
	@echo "==> JTAG system reset (NOTE: unreliable for returning to Linux -- power-cycle if it stays silent)"
	@source $(VITIS_SETTINGS) && xsct -eval ' \
	    connect; \
	    targets -set -filter {name =~ "PSU" && jtag_cable_name =~ "Xilinx*"}; \
	    rst -system; \
	    puts "jtag-reboot: rst -system issued -- if UART stays silent, power-cycle the board to boot Linux"; \
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

# Open KR260 PS-UART in tio (tmux-friendly; Ctrl-t q to quit).
tty:
	@echo "==> KR260 UART: $(KR260_UART) (115200 8N1) via tio"
	@tio -b 115200 -d 8 -p none -s 1 -f none $(KR260_UART)

# Free the KR260 UART by killing whatever process (e.g. a stray tio) holds it.
tty-stop:
	@pids=$$(fuser $(KR260_UART) 2>/dev/null); \
	if [ -n "$$pids" ]; then \
	    fuser -k $(KR260_UART) 2>/dev/null; \
	    echo "==> freed $(KR260_UART) (killed$$pids)"; \
	else \
	    echo "==> nothing holding $(KR260_UART)"; \
	fi

# List any process holding a /dev/ttyUSB* device.
tty-list:
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
