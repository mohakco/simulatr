//! UART0 transmit — the one and only peripheral in Phase 1.
//!
//! Real hardware: firmware writes a byte to UART_FIFO_REG, the byte enters a 128-byte
//! hardware FIFO, and the transmitter shifts it out a pin at the configured baud rate.
//! Firmware polls UART_STATUS_REG's TXFIFO_CNT field to avoid overflowing the FIFO.
//!
//! Our model: a write to UART_FIFO_REG appends a byte to a buffer, and TXFIFO_CNT always
//! reads as 0 ("the FIFO is empty, go ahead"). Transmission is instantaneous, so we can
//! neither overflow nor stall. There is no baud rate because there is no clock model yet.
//! Every configuration register (baud divider, line control, interrupt enables) accepts
//! writes and discards them — firmware configures the UART before using it and must not
//! fault while doing so.
//!
//! Output is buffered rather than written straight to stdout so that unit tests can
//! inspect exactly what the firmware transmitted without capturing a file descriptor.

const std = @import("std");
const soc = @import("../soc/esp32.zig");

/// How many transmitted bytes we hold before flushing to stdout. A fixed-size array
/// keeps `Uart` allocation-free: no allocator to plumb, nothing to free, and the struct
/// can live on the stack.
pub const tx_buffer_capacity = 4096;

pub const Uart = struct {
    /// Bytes the firmware has transmitted but that we have not flushed yet.
    ///
    /// `[N]u8` is an *array*: its length is part of its type and it is stored inline in
    /// the struct. `[]u8` (used elsewhere) is a *slice*: a pointer plus a runtime length.
    /// `tx_buffer[0..tx_len]` turns the array into a slice of the part we have filled.
    tx_buffer: [tx_buffer_capacity]u8 = undefined,
    tx_len: usize = 0,

    /// Where flushed bytes go. `null` means "nowhere": the UART still records everything
    /// in `tx_buffer` and `bytes_transmitted`, which is exactly what unit tests want.
    /// The CLI points this at a buffered stdout writer.
    ///
    /// `std.Io.Writer` is the standard library's buffered-writer interface, and it is the
    /// one piece of indirection in Phase 1 — using std's rather than inventing our own.
    sink: ?*std.Io.Writer = null,

    /// Total bytes ever transmitted, across flushes. Useful in the run summary.
    bytes_transmitted: u64 = 0,

    /// Handle a 32-bit MMIO write inside the UART0 register block.
    /// `offset` is relative to `soc.uart0_base`.
    pub fn writeReg(self: *Uart, offset: u32, value: u32) void {
        switch (offset) {
            soc.uart_reg.fifo => {
                // Only the low 8 bits reach the shift register; the rest are ignored by
                // hardware. `@truncate` says "drop the high bits, I mean it" — Zig will
                // not narrow an integer implicitly.
                self.pushByte(@truncate(value));
            },
            // Baud rate, line control, interrupt masks, ... accepted and discarded.
            else => {},
        }
    }

    /// Handle a 32-bit MMIO read inside the UART0 register block.
    pub fn readReg(self: *Uart, offset: u32) u32 {
        _ = self;
        return switch (offset) {
            // TXFIFO_CNT (bits 23:16) = 0 and RXFIFO_CNT (bits 7:0) = 0.
            // Firmware that spins until there is room in the TX FIFO exits immediately.
            soc.uart_reg.status => 0,
            // Reading the FIFO with nothing to receive yields 0. Phase 1 has no RX path.
            soc.uart_reg.fifo => 0,
            else => 0,
        };
    }

    fn pushByte(self: *Uart, byte: u8) void {
        if (self.tx_len == tx_buffer_capacity) self.flush();
        self.tx_buffer[self.tx_len] = byte;
        self.tx_len += 1;
        self.bytes_transmitted += 1;
    }

    /// Emit everything buffered so far and reset the buffer.
    ///
    /// A write error is swallowed: if the terminal or pipe has gone away there is nothing
    /// useful an emulator can do about it, and a broken pipe must not change the emulated
    /// CPU's behaviour. Determinism beats error reporting here.
    pub fn flush(self: *Uart) void {
        if (self.tx_len == 0) return;
        if (self.sink) |out| out.writeAll(self.tx_buffer[0..self.tx_len]) catch {};
        self.tx_len = 0;
    }

    /// The bytes currently buffered, for tests and assertions.
    pub fn transmitted(self: *const Uart) []const u8 {
        return self.tx_buffer[0..self.tx_len];
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

test "writing the fifo register transmits the low byte" {
    var uart = Uart{};
    uart.writeReg(soc.uart_reg.fifo, 'H');
    uart.writeReg(soc.uart_reg.fifo, 'I');
    // 0x0000_FF21 -> only 0x21 ('!') is transmitted.
    uart.writeReg(soc.uart_reg.fifo, 0x0000_FF21);

    try std.testing.expectEqualStrings("HI!", uart.transmitted());
    try std.testing.expectEqual(@as(u64, 3), uart.bytes_transmitted);
}

test "configuration registers are accepted and ignored" {
    var uart = Uart{};
    uart.writeReg(0x14, 0x0000_02B6); // UART_CLKDIV_REG, 115200 baud @ 80 MHz
    uart.writeReg(0x20, 0x0000_001C); // UART_CONF0_REG
    try std.testing.expectEqual(@as(usize, 0), uart.transmitted().len);
}

test "status register reports an empty tx fifo" {
    var uart = Uart{};
    // TXFIFO_CNT lives in bits 23:16; zero means "the FIFO has room".
    const status = uart.readReg(soc.uart_reg.status);
    try std.testing.expectEqual(@as(u32, 0), (status >> 16) & 0xFF);
}

test "flush clears the buffer but not the running total" {
    var uart = Uart{};
    uart.writeReg(soc.uart_reg.fifo, 'A');
    uart.flush();
    try std.testing.expectEqual(@as(usize, 0), uart.transmitted().len);
    try std.testing.expectEqual(@as(u64, 1), uart.bytes_transmitted);
}

test "buffer overflow flushes instead of overrunning the array" {
    var uart = Uart{};
    var i: usize = 0;
    while (i < tx_buffer_capacity + 3) : (i += 1) {
        uart.writeReg(soc.uart_reg.fifo, 'x');
    }
    try std.testing.expectEqual(@as(usize, 3), uart.transmitted().len);
    try std.testing.expectEqual(@as(u64, tx_buffer_capacity + 3), uart.bytes_transmitted);
}
