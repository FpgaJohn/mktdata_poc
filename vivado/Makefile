VIVADO    ?= vivado
PROJ_NAME  = mktdata_poc
XPR        = $(PROJ_NAME)/$(PROJ_NAME).xpr
XSA        = $(PROJ_NAME).xsa
JOBS      ?= 4

.PHONY: xsa xsa-clean

xsa: $(XSA)

$(XSA): $(XPR)
	$(VIVADO) -mode batch -source build.tcl -tclargs $(JOBS) \
		-log build.log -journal build.jou

$(XPR):
	$(VIVADO) -mode batch -source $(PROJ_NAME).tcl \
		-log create_project.log -journal create_project.jou

xsa-clean:
	rm -rf $(PROJ_NAME) $(XSA) *.log *.jou .Xil
