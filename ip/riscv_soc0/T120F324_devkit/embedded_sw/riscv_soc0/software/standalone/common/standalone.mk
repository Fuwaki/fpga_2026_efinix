OBJDIR ?= build

LDFLAGS += -lc

SPINAL_SIM ?= no
ifeq ($(SPINAL_SIM),yes)
    PROJ_NAME := $(PROJ_NAME)_spinal_sim
    CFLAGS += -DSPINAL_SIM
endif
CFLAGS += ${CFLAGS_ARGS}
CFLAGS += -I${STANDALONE}/include
CFLAGS += -I${STANDALONE}/driver
CFLAGS += -ffunction-sections -fdata-sections
LDFLAGS += -L${STANDALONE}/common
LDFLAGS += -specs=nosys.specs -lgcc -nostartfiles -ffreestanding -Wl,-Bstatic,-T,$(LDSCRIPT),-Map,$(OBJDIR)/$(PROJ_NAME).map,--print-memory-usage,--no-warn-rwx-segment,--gc-sections -lm

DOT:= .
COLON:=:

OBJS := $(SRCS)
OBJS := $(notdir $(OBJS))
OBJS := $(OBJS:.c=.o)
OBJS := $(OBJS:.cpp=.o)
OBJS := $(OBJS:.S=.o)
OBJS := $(OBJS:.s=.o)
OBJS := $(addprefix $(OBJDIR)/obj_files/,$(OBJS))

# Add syscalls.o to provide minimal syscall stubs and eliminate linker warnings
OBJS += $(OBJDIR)/obj_files/syscalls.o

all: $(OBJDIR)/$(PROJ_NAME).elf $(OBJDIR)/$(PROJ_NAME).hex $(OBJDIR)/$(PROJ_NAME).asm $(OBJDIR)/$(PROJ_NAME).bin

$(OBJDIR)/%.elf: $(OBJS) | $(OBJDIR)
	@echo "LD $(PROJ_NAME)"
	@$(RISCV_CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(LIBS)

%.hex: %.elf
	@$(RISCV_OBJCOPY) -O ihex $^ $@

%.bin: %.elf
	@$(RISCV_OBJCOPY) -O binary $^ $@

%.v: %.elf
	@$(RISCV_OBJCOPY) -O verilog $^ $@

%.asm: %.elf
	@$(RISCV_OBJDUMP) -S -d $^ > $@

define LIST_RULE
$(1)
	@mkdir -p $(dir $(word 1, $(subst $(COLON), ,$(1))))
	@echo "CC $(word 2,$(subst $(COLON), ,$(1)))"
	@$(RISCV_CC) -c $(CFLAGS)  $(INC) -o $(subst $(COLON), ,$(1))
endef

CAT:= $(addsuffix  $(COLON), $(OBJS))
CAT:= $(join  $(CAT), $(SRCS))
# Filter out syscalls.o from automatic rule generation (has explicit rule below)
CAT:= $(filter-out $(OBJDIR)/obj_files/syscalls.o:%,$(CAT))
$(foreach i,$(CAT),$(eval $(call LIST_RULE,$(i))))

# Rule to compile syscalls.c from common directory
$(OBJDIR)/obj_files/syscalls.o: ${STANDALONE}/common/syscalls.c | $(OBJDIR)/obj_files
	@echo "CC syscalls.c"
	@$(RISCV_CC) -c $(CFLAGS) $(INC) -o $@ $<

$(OBJDIR)/obj_files:
	@mkdir -p $@

$(OBJDIR):
	@mkdir -p $@

clean:
	@rm -rf $(OBJDIR)

.SECONDARY: $(OBJS)
