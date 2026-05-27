TCL := vivado/mktdata_poc.tcl

.PHONY: xsa xsa-clean app-build app-run app-clean \
        list-resources list-gpio list-fifo list-dma-fifo help

help:
	@echo "Targets:"
	@echo "  xsa             - Build Vivado project and export XSA with bitstream"
	@echo "  xsa-clean       - Remove all Vivado build artifacts"
	@echo "  app-build       - Build the FreeRTOS poller application"
	@echo "  app-run         - Load and run the application on the connected KR260"
	@echo "  app-clean       - Remove application build artifacts"
	@echo "  list-resources  - Display all IP blocks in the design"
	@echo "  list-gpio       - Display GPIO IP blocks"
	@echo "  list-fifo       - Display all FIFO IP blocks"
	@echo "  list-dma-fifo   - Display AXI Stream data FIFOs (DMA data path)"

# ── Vivado ────────────────────────────────────────────────────────────────────

xsa:
	$(MAKE) -C vivado xsa

xsa-clean:
	$(MAKE) -C vivado xsa-clean

# ── Application ───────────────────────────────────────────────────────────────

app-build:
	$(MAKE) -C apps/poller_app build

app-run:
	$(MAKE) -C apps/poller_app run

app-clean:
	$(MAKE) -C apps/poller_app clean

# ── Design resource listing ───────────────────────────────────────────────────

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
