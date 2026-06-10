SHELL           := /bin/bash
APP_NAME := mktdata_poc
XSA      := ../vivado/mktdata_poc.xsa
XSA_BIT  := mktdata_poc.bit
BUILD    := build
BIT      := $(BUILD)/$(APP_NAME).bit
BIT_BIN  := $(BUILD)/$(APP_NAME).bit.bin
DTSO     := $(APP_NAME).dtso
DTBO     := $(BUILD)/$(APP_NAME).dtbo
SHELL_J  := shell.json
PKG      := $(BUILD)/$(APP_NAME)

PETALINUX_SETTINGS ?= /tools/Xilinx/PetaLinux/2024.1/settings.sh

.PHONY: all package clean stage list-staged list-apps unload-app deploy-staged load-app reload-app

all: package

$(BUILD):
	mkdir -p $(BUILD)

$(BIT): $(XSA) | $(BUILD)
	unzip -p $(XSA) $(XSA_BIT) > $@

$(BIT_BIN): $(BIT) $(APP_NAME).bif
	. $(PETALINUX_SETTINGS) && \
		bootgen -arch zynqmp -image $(APP_NAME).bif -w -o $@ -process_bitstream bin

$(DTBO): $(DTSO) | $(BUILD)
	. $(PETALINUX_SETTINGS) && \
		dtc -@ -O dtb -I dts -o $@ $(DTSO)

package: $(BIT_BIN) $(DTBO) $(SHELL_J)
	rm -rf $(PKG)
	mkdir -p $(PKG)
	cp $(BIT_BIN) $(PKG)/$(APP_NAME).bit.bin
	cp $(DTBO)    $(PKG)/$(APP_NAME).dtbo
	cp $(SHELL_J) $(PKG)/shell.json
	@echo "----"
	@echo "App package ready at: $(PKG)"
	@ls -la $(PKG)

clean:
	rm -rf $(BUILD)

stage: package
	scp -r build/$(APP_NAME) ubuntu@kr260u:~/

# Show the package staged on the board (~/$(APP_NAME), where `stage` scp's it)
# with `ls -l` timestamps, then md5-compare each file against the locally built
# package. scp does not preserve mtimes, so the staged timestamps reflect when
# it was copied -- the md5 column is the real "do they match" answer.
HOST ?= ubuntu@kr260u
list-staged:
	@echo "==> Local package ($(PKG)):"
	@if [ -d "$(PKG)" ]; then ls -l "$(PKG)"; \
	else echo "  (not built -- run 'make package')"; fi
	@echo "==> Staged on $(HOST) (~/$(APP_NAME)):"
	@if ssh $(HOST) 'ls -ld ~/$(APP_NAME) >/dev/null 2>&1'; then \
	    ssh $(HOST) 'ls -l ~/$(APP_NAME)'; \
	else \
	    echo "  (nothing staged -- run 'make stage')"; \
	    exit 0; \
	fi
	@echo "==> Content comparison (md5):"
	@if [ ! -d "$(PKG)" ]; then \
	    echo "  (no local package to compare)"; \
	else \
	    rsums=$$(ssh $(HOST) 'md5sum ~/$(APP_NAME)/* 2>/dev/null'); \
	    for f in "$(PKG)"/*; do \
	        b=$$(basename "$$f"); \
	        l=$$(md5sum "$$f" | awk '{print $$1}'); \
	        r=$$(echo "$$rsums" | awk -v b="$$b" '{n=split($$2,a,"/"); if (a[n]==b) print $$1}'); \
	        if [ -z "$$r" ]; then \
	            printf "  %-24s LOCAL-ONLY (not staged)\n" "$$b"; \
	        elif [ "$$l" = "$$r" ]; then \
	            printf "  %-24s MATCH\n" "$$b"; \
	        else \
	            printf "  %-24s DIFFERS (local=%s staged=%s)\n" "$$b" "$$l" "$$r"; \
	        fi; \
	    done; \
	fi

# List all dfx-mgr / xmutil apps on the board and their loaded status.
list-apps:
	@echo "==> xmutil apps on $(HOST):"
	@ssh $(HOST) 'sudo xmutil listapps'

# Unload the currently loaded dfx-mgr / xmutil app on the board.
unload-app:
	@echo "==> unloading xmutil app on $(HOST):"
	@ssh $(HOST) 'sudo xmutil unloadapp'

# Load the kria app (must already be installed under the firmware dir, e.g.
# via `deploy-staged`).
load-app:
	@echo "==> loading xmutil app $(APP_NAME) on $(HOST):"
	@ssh $(HOST) 'sudo xmutil loadapp $(APP_NAME)'

# Unload (tolerating "nothing loaded") then load -- forces dfx-mgr to reapply
# the overlay, e.g. after deploy-staged installs a new dtbo/bitstream. A bare
# loadapp can leave a previously applied (stale) overlay in place.
reload-app:
	@echo "==> reloading xmutil app $(APP_NAME) on $(HOST):"
	@ssh $(HOST) '(sudo xmutil unloadapp 2>/dev/null || true) && sudo xmutil loadapp $(APP_NAME)'

# Copy the staged package (~/$(APP_NAME), put there by `stage`) into the
# firmware dir where xmutil looks for it, overwriting any app of the same name.
FW_DIR ?= /lib/firmware/xilinx
deploy-staged:
	@echo "==> deploying ~/$(APP_NAME) -> $(FW_DIR)/$(APP_NAME) on $(HOST)"
	@ssh $(HOST) 'set -e; \
	    if [ ! -d ~/$(APP_NAME) ]; then \
	        echo "  (nothing staged -- run make stage)"; exit 1; \
	    fi; \
	    sudo rm -rf $(FW_DIR)/$(APP_NAME); \
	    sudo cp -r ~/$(APP_NAME) $(FW_DIR)/; \
	    echo "  installed:"; sudo ls -l $(FW_DIR)/$(APP_NAME)'
