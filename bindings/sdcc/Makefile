# Makefile - UNET C binding demo for the SDCC Sprinter SDK.
#
# The SDK targets SDCC 2.9.0. Point SDK_DIR at your SDK checkout (default: the
# sibling sdcc-sprinter-sdk beside this project) and, if needed, set
# SDCC290_BIN_DIR in the SDK's config.local.mk.
#
#   make SDK_DIR=/path/to/sdcc-sprinter-sdk/
#
# Compact layout (CODE_LOC = 0x8100, window 2) so the DLL owns window 1.

APP       = unetdemo
SRCS      = unetdemo.c unet.c
ASMS      = unetll.s

SDK_DIR  ?= ../../../../sdcc-sprinter-sdk/
include $(SDK_DIR)toolchain.mk

CODE_LOC ?= 0x8100
STACK    ?= 0xBFFF
CRT0      = $(SDK_DIR)build/crt0.rel
SPRLIB    = $(SDK_DIR)build/sprinter.lib

BUILD     = _build
INC       = -I$(SDK_DIR)include -I.

C_RELS    = $(patsubst %.c,$(BUILD)/%.rel,$(SRCS))
ASM_RELS  = $(patsubst %.s,$(BUILD)/%.rel,$(ASMS))

.PHONY: all clean
all: $(APP).exe

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.rel: %.c | $(BUILD)
	$(SDCPP) $(SDCPPFLAGS) $(INC) $< > $(basename $@).i
	$(SDCC) $(SDCC_CFLAGS) --c1mode -o $(basename $@).asm < $(basename $@).i
	$(SDASZ80) -plosgff $@ $(basename $@).asm

$(BUILD)/%.rel: %.s | $(BUILD)
	$(SDASZ80) -plosgff $@ $<

$(BUILD)/$(APP).ihx: $(CRT0) $(SPRLIB) $(C_RELS) $(ASM_RELS)
	printf '%s\n' '-mjx' > $(BUILD)/$(APP).lk
	printf '%s\n' '-i $@' >> $(BUILD)/$(APP).lk
	printf '%s\n' '-b _CODE = $(CODE_LOC)' >> $(BUILD)/$(APP).lk
	printf '%s\n' '-l $(abspath $(SPRLIB))' >> $(BUILD)/$(APP).lk
	printf '%s\n' '$(abspath $(CRT0))' >> $(BUILD)/$(APP).lk
	for rel in $(C_RELS) $(ASM_RELS); do printf '%s\n' "$$rel" >> $(BUILD)/$(APP).lk; done
	printf '%s\n' '-e' >> $(BUILD)/$(APP).lk
	$(SDLDZ80) -n -f $(BUILD)/$(APP).lk

$(APP).exe: $(BUILD)/$(APP).ihx
	$(PYTHON) $(SDK_DIR)tools/ihx2exe.py $< $@ --load $(CODE_LOC) --entry $(CODE_LOC) --stack $(STACK)
	@echo "Built: $@"

clean:
	rm -rf $(BUILD) $(APP).exe
