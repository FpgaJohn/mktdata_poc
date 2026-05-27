XSCT      ?= /tools/Xilinx/Vitis/2024.1/bin/xsct
XSA       := ../../vivado/mktdata_poc.xsa
WORKSPACE  = workspace
ELF        = $(WORKSPACE)/poller_app/Debug/poller_app.elf

.PHONY: build run clean help

help:
	@echo "Targets:"
	@echo "  build  - Create Vitis platform and build the FreeRTOS poller application"
	@echo "  run    - Download and start the application on the connected KR260"
	@echo "  clean  - Remove the Vitis workspace and all build artifacts"
	@echo ""
	@echo "Prerequisites:"
	@echo "  build: requires $(XSA)  (run 'make xsa' from the repo root first)"
	@echo "  run:   requires hw_server running with KR260 connected via USB/JTAG"

build: $(ELF)

$(ELF): $(XSA) src/main.c
	$(XSCT) vitis_build.tcl

run: $(ELF)
	$(XSCT) vitis_run.tcl

clean:
	rm -rf $(WORKSPACE)
