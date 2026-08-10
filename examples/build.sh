#!/bin/sh
#
# Build examples/hello.elf with the Espressif GCC toolchain.
#
#     ./examples/build.sh          (or: zig build firmware)
#
# Two flags here are not obvious and both are load-bearing:
#
#   -mdynconfig=.../xtensa_esp32.so
#       Xtensa is a configurable ISA, and the toolchain's *default* configuration is a
#       generic big-endian core. Without this the linker produces an elf32-xtensa-BE
#       image, which simulatr correctly rejects with NotLittleEndian. This flag selects
#       the real ESP32 core: little-endian, with the Code Density option.
#
#   -Wa,--text-section-literals
#       Honours the `.literal_position` directive in hello.S, placing the L32R literal
#       pool inline immediately before the code. Without it the assembler emits literals
#       to a separate `.literal.*` section that the linker may place *after* the code,
#       and since L32R can only reach backwards you get:
#           dangerous relocation: l32r: literal placed after use
#
set -eu

CC="${CC:-xtensa-esp-elf-gcc}"

command -v "$CC" > /dev/null 2>&1 || {
    echo "$0: $CC not found on PATH" >&2
    exit 1
}

# The core-configuration shared object lives in <toolchain prefix>/lib.
PREFIX="$(dirname "$(dirname "$(command -v "$CC")")")"
DYNCONFIG="$PREFIX/lib/xtensa_esp32.so"

[ -f "$DYNCONFIG" ] || {
    echo "$0: ESP32 core config not found at $DYNCONFIG" >&2
    exit 1
}

HERE="$(dirname "$0")"

"$CC" \
    -mdynconfig="$DYNCONFIG" \
    -Wa,--text-section-literals \
    -nostdlib -nostartfiles \
    -T "$HERE/hello.ld" \
    -o "$HERE/hello.elf" \
    "$HERE/hello.S"

echo "built $HERE/hello.elf"
