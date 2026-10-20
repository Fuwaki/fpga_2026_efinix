# Verilator simulations for the video subsystem.
#   make -C sim            build and run every test
#   make -C sim tb_fifo    one test
#   make -C sim lint       lint the synthesisable library
ROOT   := $(abspath ..)
OBJ    ?= $(ROOT)/sim/obj
VFLAGS := --binary --timing --assert -j 0 -Wall -Wno-fatal \
          -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
          --x-assign unique --x-initial unique -DVID_SVA --timescale 1ns/1ps

RTL_COMMON := $(ROOT)/rtl/vid/common/vid_pkg.sv \
              $(ROOT)/rtl/vid/common/vstream_if.sv \
              $(ROOT)/rtl/vid/common/vpush_if.sv \
              $(ROOT)/rtl/vid/common/axi4_if.sv \
              $(ROOT)/rtl/vid/common/mul_nodsp.sv \
              $(ROOT)/rtl/vid/common/fifo_sync_core.sv \
              $(ROOT)/rtl/vid/common/fifo_async_core.sv \
              $(ROOT)/rtl/vid/common/vstream_fifo.sv
SVA        := $(ROOT)/rtl/vid/common/sva/vstream_sva.sv \
              $(ROOT)/rtl/vid/common/sva/axi4_sva.sv \
              $(ROOT)/sim/bind/vid_bind.sv
MODELS     := $(ROOT)/sim/models/vstream_bfm.sv \
              $(ROOT)/sim/models/axi_mem_model.sv

TESTS := tb_fifo sva_neg

.PHONY: all lint $(TESTS)
all: lint $(TESTS)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
	  --top-module sv_probe_top $(RTL_COMMON) $(ROOT)/tools/sv_probe/sv_probe_top.sv
	@echo "PASS lint"

tb_fifo:
	@mkdir -p $(OBJ)/$@
	verilator $(VFLAGS) --top-module $@ -Mdir $(OBJ)/$@ \
	  $(RTL_COMMON) $(SVA) $(MODELS) $(ROOT)/sim/tb/$@.sv
	$(OBJ)/$@/V$@ +verilator+seed+$${SEED:-1} +verilator+rand+reset+2

# The checkers must fire: a source that withdraws beats has to fail.
sva_neg:
	@mkdir -p $(OBJ)/$@
	verilator $(VFLAGS) --top-module tb_fifo -GMISBEHAVE=1 -Mdir $(OBJ)/$@ \
	  $(RTL_COMMON) $(SVA) $(MODELS) $(ROOT)/sim/tb/tb_fifo.sv
	@if $(OBJ)/$@/Vtb_fifo > $(OBJ)/$@/run.log 2>&1; then \
	  echo "FAIL sva_neg: misbehaving source was not caught"; exit 1; \
	else grep -m1 "withdrawn before transfer" $(OBJ)/$@/run.log && echo "PASS sva_neg"; fi
