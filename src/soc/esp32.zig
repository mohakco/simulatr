//! ESP32 "classic" (Xtensa LX6) SoC profile.
//!
//! EVERY chip-specific constant lives in this file. The CPU, the bus and the peripherals
//! must never hard-code an address; they ask this profile. When we add an ESP32-S3
//! profile later it becomes a second file next to this one, and nothing in cpu/ changes.
//!
//! Source: ESP32 Technical Reference Manual, chapter "System and Memory" (address map)
//! and chapter "UART Controller" (register offsets).

const std = @import("std");

/// Human-readable name, used in trace output and error messages.
pub const name = "esp32";

// ---------------------------------------------------------------------------------------
// Memory map
// ---------------------------------------------------------------------------------------
//
// The ESP32 has separate instruction and data buses onto the same internal SRAM, so the
// same physical bytes appear at more than one address. Phase 1 does not model that
// aliasing: we expose two independent, flat regions, one for code and one for data,
// matching the two segments an ESP-IDF linker script actually uses:
//
//     iram0_0_seg : org = 0x40080000, len = 0x20000   (128 KiB, instructions)
//     dram0_0_seg : org = 0x3FFB0000, len = 0x2C200   (~176 KiB, data)
//
// We round DRAM up to 0x30000 (192 KiB) so the region size is a tidy power-of-two-ish
// number; nothing in Phase 1 depends on the exact end address.

/// Instruction RAM: where PT_LOAD segments holding code land.
pub const iram_base: u32 = 0x4008_0000;
pub const iram_size: u32 = 0x0002_0000; // 128 KiB

/// Data RAM: where .data / .bss / the stack land.
pub const dram_base: u32 = 0x3FFB_0000;
pub const dram_size: u32 = 0x0003_0000; // 192 KiB

// ---------------------------------------------------------------------------------------
// Peripheral (MMIO) map
// ---------------------------------------------------------------------------------------
//
// The whole peripheral block on the ESP32 is 0x3FF0_0000 .. 0x3FF7_FFFF. Phase 1 decodes
// exactly one peripheral inside it — UART0 — and treats any other peripheral access as an
// error, so that an unimplemented device shows up loudly instead of silently reading 0.

pub const periph_base: u32 = 0x3FF0_0000;
pub const periph_size: u32 = 0x0008_0000;

/// UART0 register block. Each UART on the ESP32 gets 0x80 bytes of register space.
pub const uart0_base: u32 = 0x3FF4_0000;
pub const uart_regs_size: u32 = 0x80;

/// Byte offsets within a UART register block that Phase 1 knows about.
pub const uart_reg = struct {
    /// UART_FIFO_REG. Writing the low 8 bits pushes a byte into the TX FIFO;
    /// reading pops a byte from the RX FIFO. This is the register the POC firmware pokes.
    pub const fifo: u32 = 0x00;
    /// UART_STATUS_REG. Bits 23:16 are TXFIFO_CNT, bits 7:0 are RXFIFO_CNT.
    /// Firmware polls this to wait for room in the TX FIFO.
    pub const status: u32 = 0x1C;
};

// ---------------------------------------------------------------------------------------
// Region helpers
// ---------------------------------------------------------------------------------------

/// True if `addr` falls inside `[base, base + size)`.
///
/// `+%` is Zig's *wrapping* add. Plain `+` would panic in Debug builds if the sum
/// overflowed a u32; for address arithmetic we want the hardware behaviour (wrap around),
/// so we ask for it explicitly.
pub fn inRange(addr: u32, base: u32, size: u32) bool {
    return addr >= base and addr -% base < size;
}

pub fn isIram(addr: u32) bool {
    return inRange(addr, iram_base, iram_size);
}

pub fn isDram(addr: u32) bool {
    return inRange(addr, dram_base, dram_size);
}

pub fn isPeripheral(addr: u32) bool {
    return inRange(addr, periph_base, periph_size);
}

pub fn isUart0(addr: u32) bool {
    return inRange(addr, uart0_base, uart_regs_size);
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

test "iram range boundaries" {
    try std.testing.expect(isIram(iram_base));
    try std.testing.expect(isIram(iram_base + iram_size - 1));
    try std.testing.expect(!isIram(iram_base + iram_size));
    try std.testing.expect(!isIram(iram_base - 1));
}

test "dram range boundaries" {
    try std.testing.expect(isDram(dram_base));
    try std.testing.expect(isDram(dram_base + dram_size - 1));
    try std.testing.expect(!isDram(dram_base + dram_size));
}

test "uart0 sits inside the peripheral block" {
    try std.testing.expect(isPeripheral(uart0_base));
    try std.testing.expect(isUart0(uart0_base + uart_reg.status));
    try std.testing.expect(!isUart0(uart0_base + uart_regs_size));
    // The peripheral block and RAM must not overlap, or bus decoding is ambiguous.
    try std.testing.expect(!isDram(uart0_base));
    try std.testing.expect(!isIram(uart0_base));
}

test "address arithmetic does not overflow at the top of the address space" {
    // inRange must be safe even when base + size would wrap past 0xFFFFFFFF.
    try std.testing.expect(inRange(0xFFFF_FFFF, 0xFFFF_0000, 0x1_0000));
    try std.testing.expect(!inRange(0x0000_0000, 0xFFFF_0000, 0x1_0000));
}
