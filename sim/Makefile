# Verilator simulations for the video subsystem.
#   make -C sim             lint, then every test
#   make -C sim tb_ring     one test (sim/tb/tb_ring.sv, top module tb_ring)
#   make -C sim lint        lint the synthesisable library
#   SEED=7 make -C sim ...  other random seed
ROOT   := $(abspath ..)
OBJ    ?= $(ROOT)/sim/obj
SEED   ?= 1
VFLAGS := --binary --timing --assert -j 0 -Wall -Wno-fatal \
          -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
          --x-assign unique --x-initial unique -DVID_SVA --timescale 1ns/1ps

RTL := $(addprefix $(ROOT)/rtl/vid/, \
         common/vid_pkg.sv common/vstream_if.sv common/vpush_if.sv common/axi4_if.sv \
         common/mul_nodsp.sv common/fifo_sync_core.sv common/fifo_async_core.sv \
         common/vstream_fifo.sv \
         dma/ring_if.sv dma/frame_ring_core.sv dma/frame_ring.sv \
         dma/axi_arb.sv dma/vdma_wr.sv dma/vdma_rd.sv \
         dbg/vid_testgen.sv dbg/vid_testchk.sv vid_subsystem.sv)
SVA := $(ROOT)/rtl/vid/common/sva/vstream_sva.sv \
       $(ROOT)/rtl/vid/common/sva/axi4_sva.sv \
       $(ROOT)/sim/bind/vid_bind.sv
MODELS := $(ROOT)/sim/models/vstream_bfm.sv \
          $(ROOT)/sim/models/axi_mem_model.sv

TESTS := tb_fifo tb_ring tb_ring_tight tb_dma tb_vidsub tb_vidsub_badid sva_neg

.PHONY: all lint $(TESTS)
all: lint $(TESTS)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
	  --top-module sv_probe_top $(RTL) $(ROOT)/tools/sv_probe/sv_probe_top.sv
	@echo "PASS lint"

# build <obj-name> <tb-file> <top> <extra verilator flags>
# A warning located in synthesisable code (rtl/vid) fails the build.
define build
	@mkdir -p $(OBJ)/$(1)
	verilator $(VFLAGS) --top-module $(3) $(4) -Mdir $(OBJ)/$(1) \
	  $(RTL) $(SVA) $(MODELS) $(ROOT)/sim/tb/$(2).sv > $(OBJ)/$(1)/build.log 2>&1 \
	  || { tail -30 $(OBJ)/$(1)/build.log; exit 1; }
	@if grep -E '^%Warning-[A-Z]+: $(ROOT)/rtl/vid/' $(OBJ)/$(1)/build.log | grep -v '/sva/'; then \
	  echo "FAIL $(1): warnings in rtl/vid (see $(OBJ)/$(1)/build.log)"; exit 1; fi
endef

tb_fifo tb_ring tb_dma tb_vidsub:
	$(call build,$@,$@,$@,)
	$(OBJ)/$@/V$@ +verilator+seed+$(SEED) +verilator+rand+reset+2

# Fewer slots than NCONS + 2: drops are legal and the model must agree.
tb_ring_tight:
	$(call build,$@,tb_ring,tb_ring,-GSLOTS=3)
	$(OBJ)/$@/Vtb_ring +verilator+seed+$(SEED) +verilator+rand+reset+2

# A DDR controller that does not echo AXI IDs (the board's may not).
tb_vidsub_badid:
	$(call build,$@,tb_vidsub,tb_vidsub,-GBAD_IDS=1)
	$(OBJ)/$@/Vtb_vidsub +verilator+seed+$(SEED) +verilator+rand+reset+2

# The checkers must fire: a source that withdraws beats has to fail.
sva_neg:
	$(call build,$@,tb_fifo,tb_fifo,-GMISBEHAVE=1)
	@if $(OBJ)/$@/Vtb_fifo > $(OBJ)/$@/run.log 2>&1; then \
	  echo "FAIL sva_neg: misbehaving source was not caught"; exit 1; \
	else grep -m1 "withdrawn before transfer" $(OBJ)/$@/run.log && echo "PASS sva_neg"; fi
