/*
 * Minimal linker script for the Phase 1 POC firmware.
 *
 * These two regions match src/soc/esp32.zig exactly. If you change one, change the other.
 * They are the same origins ESP-IDF's esp32.ld uses for iram0_0_seg and dram0_0_seg,
 * trimmed to what a nine-instruction program needs.
 *
 * The .text input order below puts .literal before .text on purpose: L32R can only
 * reach backwards, so a literal placed after its use is a link error. In practice
 * build.sh passes -Wa,--text-section-literals, which honours the .literal_position
 * directive in hello.S and interleaves the pool inline instead - but the ordering here
 * keeps the script correct without that flag too.
 */

MEMORY
{
    iram (rx)  : ORIGIN = 0x40080000, LENGTH = 0x20000   /* 128 KiB instruction RAM */
    dram (rw)  : ORIGIN = 0x3FFB0000, LENGTH = 0x30000   /* 192 KiB data RAM        */
}

ENTRY(_start)

SECTIONS
{
    /* Everything - code, the L32R literal pool, and the message - goes into IRAM as a
     * single PT_LOAD segment. The literal pool must land immediately before the code
     * that references it, which the default input-section order already gives us. */
    .text : ALIGN(4)
    {
        *(.literal .literal.*)
        *(.text.start)
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > iram

    /* No .data or .bss: this firmware writes to no variables. Discard the metadata
     * sections GCC emits so the ELF stays small and has exactly one loadable segment. */
    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.xt.prop .xt.prop.*)
        *(.xt.lit .xt.lit.*)
    }
}
