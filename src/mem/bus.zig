//! The memory bus: turns a 32-bit address into either RAM bytes or a peripheral access.
//!
//! Phase 1 is a *flat* model. Two RAM regions (IRAM and DRAM) sized and placed by the SoC
//! profile, plus one MMIO decode for UART0. No cache, no MMU, no flash, no address
//! aliasing between the instruction and data buses.
//!
//! Endianness: the ESP32's Xtensa core is little-endian, so a 32-bit word at address A is
//! stored as bytes A=LSB .. A+3=MSB. We use `std.mem.readInt`/`writeInt` with an explicit
//! `.little` so the emulator behaves identically on a big-endian host.

const std = @import("std");
const soc = @import("../soc/esp32.zig");
const Uart = @import("../periph/uart.zig").Uart;

/// Everything that can go wrong on a bus access.
///
/// `error{...}` declares an *error set*. A function returning `BusError!u32` returns
/// either a u32 or one of these errors — Zig's error union. There are no exceptions and
/// no null-on-failure; the caller must handle or propagate with `try`.
pub const BusError = error{
    /// No RAM region and no known peripheral covers this address.
    UnmappedAddress,
    /// A 16- or 32-bit access whose address is not a multiple of the access size.
    /// Real Xtensa raises a LoadStoreAlignmentCause exception here; Phase 1 has no
    /// exception machinery, so we surface it as a bus error and halt.
    UnalignedAccess,
    /// The access started inside a region but ran off its end.
    RegionOverrun,
    /// A peripheral register block exists but this offset has no model.
    UnimplementedPeripheral,
};

pub const Bus = struct {
    /// Backing store for the two RAM regions. These are *slices* — a pointer and a
    /// length — pointing at memory owned by the allocator passed to `init`.
    iram: []u8,
    dram: []u8,

    /// The one peripheral Phase 1 models. A pointer, not a value, so writes made through
    /// the bus are visible to whoever owns the UART.
    uart: *Uart,

    /// Allocate the RAM regions. The caller must call `deinit` with the same allocator.
    pub fn init(allocator: std.mem.Allocator, uart: *Uart) std.mem.Allocator.Error!Bus {
        const iram = try allocator.alloc(u8, soc.iram_size);
        errdefer allocator.free(iram);
        const dram = try allocator.alloc(u8, soc.dram_size);

        // Real SRAM powers up with undefined contents, but an emulator that starts from
        // garbage is not reproducible. Zeroing makes every run identical, which is the
        // whole point of this project.
        @memset(iram, 0);
        @memset(dram, 0);

        return .{ .iram = iram, .dram = dram, .uart = uart };
    }

    pub fn deinit(self: *Bus, allocator: std.mem.Allocator) void {
        allocator.free(self.iram);
        allocator.free(self.dram);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------------------
    // Region resolution
    // -----------------------------------------------------------------------------------

    /// Return the `len` bytes of RAM starting at `addr`, or null if `addr` is not RAM.
    /// Returns `RegionOverrun` if the access starts in RAM but crosses the region's end.
    fn ramSlice(self: *Bus, addr: u32, len: u32) BusError!?[]u8 {
        if (soc.isIram(addr)) return try sliceWithin(self.iram, addr - soc.iram_base, len);
        if (soc.isDram(addr)) return try sliceWithin(self.dram, addr - soc.dram_base, len);
        return null;
    }

    fn sliceWithin(region: []u8, offset: u32, len: u32) BusError![]u8 {
        if (@as(u64, offset) + len > region.len) return error.RegionOverrun;
        // `region[a..][0..n]` slices from `a` to the end, then takes the first `n` bytes.
        // It is the idiomatic way to get a fixed-length view for std.mem.readInt.
        return region[offset..][0..len];
    }

    // -----------------------------------------------------------------------------------
    // Loads
    // -----------------------------------------------------------------------------------

    pub fn read8(self: *Bus, addr: u32) BusError!u8 {
        if (try self.ramSlice(addr, 1)) |bytes| return bytes[0];
        // Peripheral registers on the ESP32 are word-oriented; a byte read of a register
        // returns the corresponding byte of the 32-bit value.
        const word = try self.readPeripheral(addr & ~@as(u32, 3));
        const shift: u5 = @intCast((addr & 3) * 8);
        return @truncate(word >> shift);
    }

    pub fn read16(self: *Bus, addr: u32) BusError!u16 {
        if (addr % 2 != 0) return error.UnalignedAccess;
        if (try self.ramSlice(addr, 2)) |bytes| {
            return std.mem.readInt(u16, bytes[0..2], .little);
        }
        const word = try self.readPeripheral(addr & ~@as(u32, 3));
        const shift: u5 = @intCast((addr & 2) * 8);
        return @truncate(word >> shift);
    }

    pub fn read32(self: *Bus, addr: u32) BusError!u32 {
        if (addr % 4 != 0) return error.UnalignedAccess;
        if (try self.ramSlice(addr, 4)) |bytes| {
            return std.mem.readInt(u32, bytes[0..4], .little);
        }
        return self.readPeripheral(addr);
    }

    // -----------------------------------------------------------------------------------
    // Stores
    // -----------------------------------------------------------------------------------

    pub fn write8(self: *Bus, addr: u32, value: u8) BusError!void {
        if (try self.ramSlice(addr, 1)) |bytes| {
            bytes[0] = value;
            return;
        }
        // A byte store to a peripheral is modelled as a word store of the byte value.
        // Only UART_FIFO_REG cares, and it only looks at the low 8 bits.
        return self.writePeripheral(addr & ~@as(u32, 3), value);
    }

    pub fn write16(self: *Bus, addr: u32, value: u16) BusError!void {
        if (addr % 2 != 0) return error.UnalignedAccess;
        if (try self.ramSlice(addr, 2)) |bytes| {
            std.mem.writeInt(u16, bytes[0..2], value, .little);
            return;
        }
        return self.writePeripheral(addr & ~@as(u32, 3), value);
    }

    pub fn write32(self: *Bus, addr: u32, value: u32) BusError!void {
        if (addr % 4 != 0) return error.UnalignedAccess;
        if (try self.ramSlice(addr, 4)) |bytes| {
            std.mem.writeInt(u32, bytes[0..4], value, .little);
            return;
        }
        return self.writePeripheral(addr, value);
    }

    // -----------------------------------------------------------------------------------
    // MMIO dispatch
    // -----------------------------------------------------------------------------------

    fn readPeripheral(self: *Bus, addr: u32) BusError!u32 {
        if (soc.isUart0(addr)) return self.uart.readReg(addr - soc.uart0_base);
        if (soc.isPeripheral(addr)) return error.UnimplementedPeripheral;
        return error.UnmappedAddress;
    }

    fn writePeripheral(self: *Bus, addr: u32, value: u32) BusError!void {
        if (soc.isUart0(addr)) return self.uart.writeReg(addr - soc.uart0_base, value);
        if (soc.isPeripheral(addr)) return error.UnimplementedPeripheral;
        return error.UnmappedAddress;
    }

    // -----------------------------------------------------------------------------------
    // Bulk access, used by the ELF loader
    // -----------------------------------------------------------------------------------

    /// Copy `bytes` into RAM starting at `addr`. Peripherals are not loadable.
    pub fn writeBlock(self: *Bus, addr: u32, bytes: []const u8) BusError!void {
        const dest = (try self.ramSlice(addr, @intCast(bytes.len))) orelse
            return error.UnmappedAddress;
        @memcpy(dest, bytes);
    }

    /// Fill `len` bytes of RAM at `addr` with zero. Used for the .bss part of a segment,
    /// where the ELF says memsz > filesz.
    pub fn zeroBlock(self: *Bus, addr: u32, len: u32) BusError!void {
        const dest = (try self.ramSlice(addr, len)) orelse return error.UnmappedAddress;
        @memset(dest, 0);
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

/// Small helper so each test does not repeat the setup. Zig has no test fixtures; a
/// struct plus explicit `start`/`deinit` calls is the usual pattern.
///
/// Note that `start` is separate from a constructor: `bus` holds a pointer to `uart`, and
/// a struct returned *by value* from a constructor would move in memory, leaving that
/// pointer dangling. Taking `&self.uart` only after the Harness has its final address is
/// the safe order. Zig will not catch this mistake for you.
const Harness = struct {
    uart: Uart = .{},
    bus: Bus = undefined,

    fn start(self: *Harness) !void {
        self.bus = try Bus.init(testing.allocator, &self.uart);
    }

    fn deinit(self: *Harness) void {
        self.bus.deinit(testing.allocator);
    }
};

test "word round-trip in dram" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.bus.write32(soc.dram_base + 16, 0xDEAD_BEEF);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try h.bus.read32(soc.dram_base + 16));
}

test "little-endian byte order" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.bus.write32(soc.dram_base, 0x1122_3344);
    // Least significant byte first.
    try testing.expectEqual(@as(u8, 0x44), try h.bus.read8(soc.dram_base + 0));
    try testing.expectEqual(@as(u8, 0x33), try h.bus.read8(soc.dram_base + 1));
    try testing.expectEqual(@as(u8, 0x22), try h.bus.read8(soc.dram_base + 2));
    try testing.expectEqual(@as(u8, 0x11), try h.bus.read8(soc.dram_base + 3));
    try testing.expectEqual(@as(u16, 0x3344), try h.bus.read16(soc.dram_base + 0));
    try testing.expectEqual(@as(u16, 0x1122), try h.bus.read16(soc.dram_base + 2));
}

test "iram and dram are independent regions" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.bus.write32(soc.iram_base, 0xAAAA_AAAA);
    try h.bus.write32(soc.dram_base, 0xBBBB_BBBB);
    try testing.expectEqual(@as(u32, 0xAAAA_AAAA), try h.bus.read32(soc.iram_base));
    try testing.expectEqual(@as(u32, 0xBBBB_BBBB), try h.bus.read32(soc.dram_base));
}

test "alignment is enforced for halfword and word access" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try testing.expectError(error.UnalignedAccess, h.bus.read32(soc.dram_base + 1));
    try testing.expectError(error.UnalignedAccess, h.bus.read32(soc.dram_base + 2));
    try testing.expectError(error.UnalignedAccess, h.bus.read16(soc.dram_base + 1));
    try testing.expectError(error.UnalignedAccess, h.bus.write32(soc.dram_base + 3, 0));
    // Byte access is never misaligned.
    try h.bus.write8(soc.dram_base + 1, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), try h.bus.read8(soc.dram_base + 1));
}

test "unmapped addresses are an error, not silent zeroes" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try testing.expectError(error.UnmappedAddress, h.bus.read32(0x0000_0000));
    try testing.expectError(error.UnmappedAddress, h.bus.read32(0x5000_0000));
    try testing.expectError(error.UnmappedAddress, h.bus.write32(soc.iram_base - 4, 1));
}

test "an access that runs off the end of a region is caught" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const last_word = soc.dram_base + soc.dram_size - 4;
    try h.bus.write32(last_word, 0x1234_5678);
    try testing.expectEqual(@as(u32, 0x1234_5678), try h.bus.read32(last_word));

    // One word past the end is not DRAM at all.
    try testing.expectError(error.UnmappedAddress, h.bus.read32(last_word + 4));

    // A bulk write that starts inside DRAM but overruns its end. (Single loads and
    // stores cannot trigger this: alignment is enforced and the region size is a
    // multiple of 4, so an aligned access either fits entirely or starts outside.)
    var scratch: [8]u8 = undefined;
    try testing.expectError(error.RegionOverrun, h.bus.writeBlock(last_word, &scratch));
}

test "unimplemented peripherals are reported, not ignored" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // GPIO base on the ESP32; no model in Phase 1.
    try testing.expectError(error.UnimplementedPeripheral, h.bus.write32(0x3FF4_4004, 1));
}

test "a word store to the uart fifo emits a byte" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.bus.write32(soc.uart0_base + soc.uart_reg.fifo, 'Z');
    try testing.expectEqualStrings("Z", h.uart.transmitted());
}

test "writeBlock and zeroBlock cover a segment load" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.bus.writeBlock(soc.iram_base, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u32, 0x0403_0201), try h.bus.read32(soc.iram_base));

    try h.bus.zeroBlock(soc.iram_base, 4);
    try testing.expectEqual(@as(u32, 0), try h.bus.read32(soc.iram_base));

    // A segment that does not fit in any region must fail loudly.
    try testing.expectError(error.UnmappedAddress, h.bus.writeBlock(0x1000, &[_]u8{0}));
}
