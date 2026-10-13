#!/usr/bin/env bash
# Assemble a hand-written AVR32 game blob.
#   AVR32_BIN=/path/to/avr32-gnu-toolchain/bin  ./build.sh [source.s]
# cc1 from the EOL toolchain SIGSEGVs on modern kernels, so the game is hand-written
# assembly; as/ld/objcopy run fine. LC_ALL=C is REQUIRED or the old binutils crash on
# modern glibc. Output: blob.bin (feed to ../tools/inject_patch.py).
set -e
export LC_ALL=C LANG=C
BIN="${AVR32_BIN:?set AVR32_BIN to the avr32-gnu-toolchain .../bin directory}"
cd "$(dirname "$0")"
SRC="${1:-pong.s}"
"$BIN/avr32-as" -mpart=uc3c0512c "$SRC" -o blob.o
"$BIN/avr32-ld" -T inject.ld blob.o -o blob.elf
"$BIN/avr32-objcopy" -O binary blob.elf blob.bin
echo "entry (must be 8002c000):"; "$BIN/avr32-nm" blob.elf | grep -iw game_entry
echo "built game/blob.bin ($(stat -c %s blob.bin) bytes)"
