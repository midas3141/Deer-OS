# Makefile — Bare-metal x86 bootloader + kernel
#
# Targets:
#   make         → build os.img (local, no timestamp)
#   make install → build timestamped image into ./ass/
#   make run     → launch in QEMU
#   make clean   → remove build artefacts

NASM    = nasm
QEMU    = qemu-system-x86_64
OUTDIR  = ass
TS      := $(shell date +%Y%m%d_%H%M%S)
IMG     = os.img
TSIMG   = $(OUTDIR)/os_$(TS).img

.PHONY: all install run clean

all: $(IMG)

bootloader.bin: bootloader.asm
	$(NASM) -f bin -o $@ $<

kernel.bin: kernel.asm
	$(NASM) -f bin -o $@ $<

$(IMG): bootloader.bin kernel.bin
	dd if=/dev/zero      of=$(IMG)  bs=512 count=2880   2>/dev/null
	dd if=bootloader.bin of=$(IMG)  bs=512 count=1 conv=notrunc 2>/dev/null
	dd if=kernel.bin     of=$(IMG)  bs=512 seek=1  conv=notrunc 2>/dev/null
	@echo ""
	@echo "  Built $(IMG)  (bootloader: $$(wc -c < bootloader.bin)B  kernel: $$(wc -c < kernel.bin)B)"

install: bootloader.bin kernel.bin
	@mkdir -p $(OUTDIR)
	dd if=/dev/zero      of=$(TSIMG) bs=512 count=2880   2>/dev/null
	dd if=bootloader.bin of=$(TSIMG) bs=512 count=1 conv=notrunc 2>/dev/null
	dd if=kernel.bin     of=$(TSIMG) bs=512 seek=1  conv=notrunc 2>/dev/null
	@echo ""
	@echo "  Exported: $(TSIMG)"
	@echo "  Run with: qemu-system-x86_64 -drive format=raw,file=$(TSIMG)"

run: $(IMG)
	$(QEMU) -drive format=raw,file=$(IMG) -nographic

clean:
	rm -f bootloader.bin kernel.bin $(IMG)