.PHONY: xsa xsa-clean help

help:
	@echo "Targets:"
	@echo "  xsa       - Build Vivado project and export XSA with bitstream"
	@echo "  xsa-clean - Remove all generated build artifacts"

xsa:
	$(MAKE) -C vivado xsa

xsa-clean:
	$(MAKE) -C vivado xsa-clean
