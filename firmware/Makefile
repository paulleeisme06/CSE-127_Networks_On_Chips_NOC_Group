#Toolchain configuration
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy

# File Paths
TARGET_BIN = ../firmware.bin
TARGET_HEX = firmware.hex

# --- FLAGS ---
CFLAGS = -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib -fno-builtin
LDFLAGS = -T link.ld -nostdlib

all: $(TARGET_HEX) size_check

firmware.elf: main.c link.ld
	$(CC) $(CFLAGS) -o $@ main.c $(LDFLAGS)

# This now outputs to the parent directory
$(TARGET_BIN): firmware.elf
	$(OBJCOPY) -O binary $< $@

# Updated to reference the bin file in the parent directory
$(TARGET_HEX): $(TARGET_BIN)
	python3 bin2hex.py $< $@

size_check: firmware.elf
	@echo "--- FIRMWARE SIZE REPORT ---"
	@riscv64-unknown-elf-size firmware.elf
	@echo "Targeting Grid Base @ 0x2F8 (760 bytes). Text + Data must be smaller than this."

clean:
	rm -f *.elf *.hex
	rm -f $(TARGET_BIN)