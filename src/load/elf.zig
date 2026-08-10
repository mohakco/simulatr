//! ELF32 loader.
//!
//! An ELF file is a header, followed by a *program header table* describing how to lay the
//! file out in memory, followed by the segment bytes themselves. A loader only needs the
//! program headers; sections (.text, .rodata, ...) are a link-time view and are ignored
//! here. Phase 1 does not read the symbol table — that arrives with tracing in Phase 2.
//!
//! Layout we care about (all little-endian on Xtensa):
//!
//!   ELF header, 52 bytes
//!     0x00  e_ident[16]   magic 0x7F 'E' 'L' 'F', class, data encoding, version
//!     0x10  e_type        u16, 2 = ET_EXEC
//!     0x12  e_machine     u16, 94 = EM_XTENSA
//!     0x18  e_entry       u32, virtual address of the first instruction
//!     0x1C  e_phoff       u32, file offset of the program header table
//!     0x2A  e_phentsize   u16, bytes per program header (32 for ELF32)
//!     0x2C  e_phnum       u16, number of program headers
//!
//!   Program header, 32 bytes
//!     0x00  p_type        u32, 1 = PT_LOAD
//!     0x04  p_offset      u32, where the bytes live in the file
//!     0x08  p_vaddr       u32, where they must be placed in memory
//!     0x10  p_filesz      u32, how many bytes are in the file
//!     0x14  p_memsz       u32, how much memory the segment occupies
//!
//! When p_memsz > p_filesz the difference is .bss: memory that must exist and be zero but
//! that is not stored in the file.

const std = @import("std");
const Bus = @import("../mem/bus.zig").Bus;
const BusError = @import("../mem/bus.zig").BusError;

pub const LoadError = error{
    NotAnElfFile,
    NotElf32,
    NotLittleEndian,
    NotAnExecutable,
    NotXtensa,
    TruncatedFile,
    BadProgramHeaderSize,
    NoLoadableSegments,
    SegmentFileRangeOutOfBounds,
    SegmentMemorySizeTooSmall,
} || BusError;

// --- ELF constants ---------------------------------------------------------------------

const elf_magic = [4]u8{ 0x7F, 'E', 'L', 'F' };
const elfclass32: u8 = 1;
const elfdata2lsb: u8 = 1;
const et_exec: u16 = 2;
const em_xtensa: u16 = 94;
const pt_load: u32 = 1;

const ehdr_size = 52;
const phdr_size = 32;

/// What the loader hands back to the machine.
pub const LoadResult = struct {
    /// Virtual address of the first instruction to execute.
    entry: u32,
    /// Number of PT_LOAD segments actually copied into memory.
    segments_loaded: usize,
    /// Total bytes copied (not counting zero-filled .bss).
    bytes_loaded: usize,
};

/// Parse `file` and copy every PT_LOAD segment into `bus`.
///
/// `file` is a `[]const u8` — a slice of *immutable* bytes. The whole file is expected to
/// already be in memory; at Phase 1 sizes that is simpler and faster than streaming, and
/// it keeps this function free of any host I/O.
pub fn load(bus: *Bus, file: []const u8) LoadError!LoadResult {
    if (file.len < ehdr_size) return error.TruncatedFile;

    // --- identification ---------------------------------------------------------------
    if (!std.mem.eql(u8, file[0..4], &elf_magic)) return error.NotAnElfFile;
    if (file[4] != elfclass32) return error.NotElf32;
    if (file[5] != elfdata2lsb) return error.NotLittleEndian;

    const e_type = readU16(file, 0x10);
    const e_machine = readU16(file, 0x12);
    if (e_type != et_exec) return error.NotAnExecutable;
    if (e_machine != em_xtensa) return error.NotXtensa;

    const e_entry = readU32(file, 0x18);
    const e_phoff = readU32(file, 0x1C);
    const e_phentsize = readU16(file, 0x2A);
    const e_phnum = readU16(file, 0x2C);

    if (e_phentsize != phdr_size) return error.BadProgramHeaderSize;

    // Widen to u64 before multiplying so a hostile or corrupt file cannot make the
    // bounds check overflow and pass.
    const ph_table_end = @as(u64, e_phoff) + @as(u64, e_phentsize) * e_phnum;
    if (ph_table_end > file.len) return error.TruncatedFile;

    var result = LoadResult{ .entry = e_entry, .segments_loaded = 0, .bytes_loaded = 0 };

    var i: u16 = 0;
    while (i < e_phnum) : (i += 1) {
        const off: usize = @intCast(e_phoff + @as(u64, phdr_size) * i);

        const p_type = readU32(file, off + 0x00);
        if (p_type != pt_load) continue;

        const p_offset = readU32(file, off + 0x04);
        const p_vaddr = readU32(file, off + 0x08);
        const p_filesz = readU32(file, off + 0x10);
        const p_memsz = readU32(file, off + 0x14);

        // A zero-size PT_LOAD is legal and means nothing to do.
        if (p_memsz == 0) continue;
        if (p_memsz < p_filesz) return error.SegmentMemorySizeTooSmall;

        if (@as(u64, p_offset) + p_filesz > file.len) {
            return error.SegmentFileRangeOutOfBounds;
        }

        if (p_filesz > 0) {
            const bytes = file[p_offset..][0..p_filesz];
            try bus.writeBlock(p_vaddr, bytes);
            result.bytes_loaded += p_filesz;
        }

        // The .bss tail: present in memory, absent from the file, and required to be zero.
        // Bus.init already zeroed RAM, but a second load into the same machine must not
        // see the previous run's data, so we zero explicitly.
        if (p_memsz > p_filesz) {
            try bus.zeroBlock(p_vaddr +% p_filesz, p_memsz - p_filesz);
        }

        result.segments_loaded += 1;
    }

    if (result.segments_loaded == 0) return error.NoLoadableSegments;
    return result;
}

// `file[off..][0..2]` produces a `*const [2]u8` — a pointer to a fixed-size array, which
// is what readInt needs so it can check the size at compile time rather than at runtime.
fn readU16(file: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, file[off..][0..2], .little);
}

fn readU32(file: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, file[off..][0..4], .little);
}

// ---------------------------------------------------------------------------------------
// Tests
//
// The Xtensa toolchain is not a test dependency: rather than assemble a real firmware
// image, we build a valid ELF32 byte-for-byte here. `builder` below is deliberately
// literal so you can see exactly which byte means what.
// ---------------------------------------------------------------------------------------

const testing = std.testing;
const soc = @import("../soc/esp32.zig");
const Uart = @import("../periph/uart.zig").Uart;

/// Builds a minimal but genuine ELF32 executable with one PT_LOAD segment.
const TestElf = struct {
    /// Big enough for the header, one program header, and a small payload.
    bytes: [256]u8 = [_]u8{0} ** 256,
    len: usize = 0,

    const payload_offset = ehdr_size + phdr_size; // 52 + 32 = 84

    fn build(payload: []const u8, vaddr: u32, entry: u32, memsz: u32) TestElf {
        var e = TestElf{};

        // --- ELF header ---
        @memcpy(e.bytes[0..4], &elf_magic);
        e.bytes[4] = elfclass32;
        e.bytes[5] = elfdata2lsb;
        e.bytes[6] = 1; // EV_CURRENT
        e.bytes[7] = 0; // ELFOSABI_NONE
        putU16(&e.bytes, 0x10, et_exec);
        putU16(&e.bytes, 0x12, em_xtensa);
        putU32(&e.bytes, 0x14, 1); // e_version
        putU32(&e.bytes, 0x18, entry); // e_entry
        putU32(&e.bytes, 0x1C, ehdr_size); // e_phoff: table follows the header
        putU32(&e.bytes, 0x20, 0); // e_shoff: no section table
        putU32(&e.bytes, 0x24, 0x0000_0300); // e_flags (Xtensa ABI bits; unused by us)
        putU16(&e.bytes, 0x28, ehdr_size); // e_ehsize
        putU16(&e.bytes, 0x2A, phdr_size); // e_phentsize
        putU16(&e.bytes, 0x2C, 1); // e_phnum
        putU16(&e.bytes, 0x2E, 40); // e_shentsize
        putU16(&e.bytes, 0x30, 0); // e_shnum
        putU16(&e.bytes, 0x32, 0); // e_shstrndx

        // --- program header 0 ---
        const ph = ehdr_size;
        putU32(&e.bytes, ph + 0x00, pt_load);
        putU32(&e.bytes, ph + 0x04, payload_offset);
        putU32(&e.bytes, ph + 0x08, vaddr); // p_vaddr
        putU32(&e.bytes, ph + 0x0C, vaddr); // p_paddr
        putU32(&e.bytes, ph + 0x10, @intCast(payload.len)); // p_filesz
        putU32(&e.bytes, ph + 0x14, memsz); // p_memsz
        putU32(&e.bytes, ph + 0x18, 0x5); // p_flags: read + execute
        putU32(&e.bytes, ph + 0x1C, 4); // p_align

        @memcpy(e.bytes[payload_offset..][0..payload.len], payload);
        e.len = payload_offset + payload.len;
        return e;
    }

    fn slice(self: *const TestElf) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn putU16(buf: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], value, .little);
}

fn putU32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

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

test "loads a single PT_LOAD segment and reports the entry point" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const payload = [_]u8{ 0xDE, 0xC0, 0xAD, 0x0B };
    const elf = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);

    const result = try load(&h.bus, elf.slice());
    try testing.expectEqual(@as(u32, soc.iram_base), result.entry);
    try testing.expectEqual(@as(usize, 1), result.segments_loaded);
    try testing.expectEqual(@as(usize, 4), result.bytes_loaded);
    try testing.expectEqual(@as(u32, 0x0BAD_C0DE), try h.bus.read32(soc.iram_base));
}

test "entry point may differ from the segment base" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const elf = TestElf.build(&payload, soc.iram_base, soc.iram_base + 4, payload.len);
    const result = try load(&h.bus, elf.slice());
    try testing.expectEqual(@as(u32, soc.iram_base + 4), result.entry);
}

test "memsz larger than filesz zero-fills the bss tail" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // Dirty the memory first so we can prove the loader zeroed it.
    try h.bus.write32(soc.dram_base + 4, 0xFFFF_FFFF);

    const payload = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const elf = TestElf.build(&payload, soc.dram_base, soc.dram_base, 8);

    _ = try load(&h.bus, elf.slice());
    try testing.expectEqual(@as(u32, 0xDDCC_BBAA), try h.bus.read32(soc.dram_base));
    try testing.expectEqual(@as(u32, 0), try h.bus.read32(soc.dram_base + 4));
}

test "rejects files that are not Xtensa ELF32 executables" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const payload = [_]u8{ 0, 0, 0, 0 };

    var bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    bad.bytes[1] = 'X';
    try testing.expectError(error.NotAnElfFile, load(&h.bus, bad.slice()));

    bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    bad.bytes[4] = 2; // ELFCLASS64
    try testing.expectError(error.NotElf32, load(&h.bus, bad.slice()));

    bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    bad.bytes[5] = 2; // ELFDATA2MSB
    try testing.expectError(error.NotLittleEndian, load(&h.bus, bad.slice()));

    bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    putU16(&bad.bytes, 0x12, 40); // EM_ARM
    try testing.expectError(error.NotXtensa, load(&h.bus, bad.slice()));

    bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    putU16(&bad.bytes, 0x10, 1); // ET_REL, an object file
    try testing.expectError(error.NotAnExecutable, load(&h.bus, bad.slice()));

    try testing.expectError(error.TruncatedFile, load(&h.bus, "short"));
}

test "rejects a segment whose bytes are not in the file" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const payload = [_]u8{ 1, 2, 3, 4 };
    var bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    putU32(&bad.bytes, ehdr_size + 0x10, 4096); // p_filesz way past the end
    putU32(&bad.bytes, ehdr_size + 0x14, 4096);
    try testing.expectError(error.SegmentFileRangeOutOfBounds, load(&h.bus, bad.slice()));
}

test "rejects a segment aimed at an address with no RAM behind it" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const payload = [_]u8{ 1, 2, 3, 4 };
    const elf = TestElf.build(&payload, 0x1234_0000, 0x1234_0000, payload.len);
    try testing.expectError(error.UnmappedAddress, load(&h.bus, elf.slice()));
}

test "a file with no PT_LOAD segments is rejected" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    const payload = [_]u8{ 1, 2, 3, 4 };
    var bad = TestElf.build(&payload, soc.iram_base, soc.iram_base, payload.len);
    putU32(&bad.bytes, ehdr_size + 0x00, 4); // PT_NOTE
    try testing.expectError(error.NoLoadableSegments, load(&h.bus, bad.slice()));
}
