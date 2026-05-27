VIVADO    ?= /tools/Xilinx/Vivado/2024.1/bin/vivado
PROJ_NAME  = mktdata_poc
XPR        = $(PROJ_NAME)/$(PROJ_NAME).xpr
XSA        = $(PROJ_NAME).xsa
JOBS      ?= 4

.PHONY: xsa xsa-clean help

help:
	@echo "Targets:"
	@echo "  xsa       - Create project, run synthesis/implementation, export XSA with bitstream"
	@echo "  xsa-clean - Remove all generated build artifacts (project dir, XSA, logs)"
	@echo ""
	@echo "Variables:"
	@echo "  JOBS=N    - Number of parallel jobs for synthesis/implementation (default: 4)"
	@echo "  VIVADO=   - Path to Vivado executable (default: $(VIVADO))"

xsa: $(XSA)

$(XSA): $(XPR)
	$(VIVADO) -mode batch -source build.tcl -tclargs $(JOBS) \
		-log build.log -journal build.jou

$(XPR):
	$(VIVADO) -mode batch -source $(PROJ_NAME).tcl \
		-log create_project.log -journal create_project.jou

xsa-clean:
	rm -rf $(PROJ_NAME) $(XSA) *.log *.jou .Xil
