.PHONY: xsa xsa-clean

xsa:
	$(MAKE) -C vivado xsa

xsa-clean:
	$(MAKE) -C vivado xsa-clean
