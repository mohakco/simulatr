//! One emulated node: a CPU, a memory bus, and the SoC's peripherals.
//!
//! In the architecture sketch this is a "Node". Phase 1 has exactly one, driven directly
//! by the CLI. Phase 5's orchestrator will own several of these and advance them in
//! lockstep on a shared virtual clock, which is why the run loop lives here rather than
//! being tangled into the command-line code.

const std = @import("std");
const soc = @import("soc/esp32.zig");
const Bus = @import("mem/bus.zig").Bus;
const Uart = @import("periph/uart.zig").Uart;
const Cpu = @import("cpu/core.zig").Cpu;
const HaltReason = @import("cpu/core.zig").HaltReason;
const elf = @import("load/elf.zig");
const Tracer = @import("trace.zig").Tracer;

/// Default instruction budget for a run. Generous enough for any Phase 1 firmware,
/// small enough that a mistake finishes in well under a second.
pub const default_step_budget: u64 = 10_000_000;

pub const RunSummary = struct {
    /// Where the PC stopped. For a clean exit this is `core.halt_address`.
    final_pc: u32,
    steps: u64,
    halt_reason: HaltReason,
    fault: ?anyerror,
    bytes_transmitted: u64,
};

pub const Machine = struct {
    uart: Uart = .{},
    bus: Bus = undefined,
    cpu: Cpu = .{},

    /// Initialise in place.
    ///
    /// This takes `*Machine` rather than returning a `Machine` on purpose: `bus` stores a
    /// pointer to `uart`, and a struct returned by value is copied to the caller's
    /// storage, which would leave that pointer aimed at the dead temporary. Constructing
    /// through a pointer means the addresses are already final. Zig will not warn you
    /// about this — it is one of the sharp edges of having no hidden moves or copies.
    pub fn init(self: *Machine, allocator: std.mem.Allocator) !void {
        self.bus = try Bus.init(allocator, &self.uart);
    }

    pub fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        self.bus.deinit(allocator);
    }

    /// Load an ELF image and point the CPU at its entry symbol.
    ///
    /// The stack pointer is set 16 bytes below the top of DRAM. Real firmware sets up its
    /// own stack in the reset vector; hand-written Phase 1 assembly generally does not, so
    /// we give it a usable one. Xtensa's call0 ABI requires a1 to stay 16-byte aligned.
    pub fn loadElf(self: *Machine, image: []const u8) !elf.LoadResult {
        const result = try elf.load(&self.bus, image);
        const stack_top = (soc.dram_base + soc.dram_size - 16) & ~@as(u32, 15);
        self.cpu.reset(result.entry, stack_top);
        return result;
    }

    pub fn run(self: *Machine, max_steps: u64, tracer: ?*Tracer) RunSummary {
        self.cpu.run(&self.bus, max_steps, tracer);
        // Anything the firmware transmitted but that is still sitting in our buffer needs
        // to reach the terminal before we print the summary.
        self.uart.flush();

        return .{
            .final_pc = self.cpu.pc,
            .steps = self.cpu.steps,
            .halt_reason = self.cpu.halt_reason,
            .fault = self.cpu.fault,
            .bytes_transmitted = self.uart.bytes_transmitted,
        };
    }
};

// ---------------------------------------------------------------------------------------
// Tests
//
// This is the Phase 1 vertical slice end to end: build an ELF in memory, load it, execute
// real Xtensa encodings, and check that "HELLO" came out of the UART. It is the same path
// `simulatr run hello.elf` takes, minus the filesystem.
// ---------------------------------------------------------------------------------------

const testing = std.testing;

/// Build a minimal ELF32 executable holding `payload` at `vaddr`, entry at `entry`.
/// Deliberately duplicated from load/elf.zig's tests: this one is checking the *machine*,
/// and sharing test scaffolding between modules tends to make both harder to read.
fn buildElf(buf: []u8, payload: []const u8, vaddr: u32, entry: u32) []const u8 {
    const ehdr_size = 52;
    const phdr_size = 32;
    const payload_offset = ehdr_size + phdr_size;

    @memset(buf, 0);
    @memcpy(buf[0..4], &[_]u8{ 0x7F, 'E', 'L', 'F' });
    buf[4] = 1; // ELFCLASS32
    buf[5] = 1; // ELFDATA2LSB
    buf[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, buf[0x10..][0..2], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, buf[0x12..][0..2], 94, .little); // EM_XTENSA
    std.mem.writeInt(u32, buf[0x18..][0..4], entry, .little);
    std.mem.writeInt(u32, buf[0x1C..][0..4], ehdr_size, .little); // e_phoff
    std.mem.writeInt(u16, buf[0x28..][0..2], ehdr_size, .little); // e_ehsize
    std.mem.writeInt(u16, buf[0x2A..][0..2], phdr_size, .little); // e_phentsize
    std.mem.writeInt(u16, buf[0x2C..][0..2], 1, .little); // e_phnum

    const ph = ehdr_size;
    std.mem.writeInt(u32, buf[ph + 0x00 ..][0..4], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, buf[ph + 0x04 ..][0..4], payload_offset, .little);
    std.mem.writeInt(u32, buf[ph + 0x08 ..][0..4], vaddr, .little);
    std.mem.writeInt(u32, buf[ph + 0x0C ..][0..4], vaddr, .little);
    std.mem.writeInt(u32, buf[ph + 0x10 ..][0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buf[ph + 0x14 ..][0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buf[ph + 0x18 ..][0..4], 5, .little); // PF_R | PF_X

    @memcpy(buf[payload_offset..][0..payload.len], payload);
    return buf[0 .. payload_offset + payload.len];
}

/// The Phase 1 POC firmware, hand-assembled.
///
///   .literal_position
///   uart:  .word 0x3FF40000          ; UART0_FIFO_REG
///   msg:   .ascii "HELLO"            ; 5 bytes, padded to 8
///
///   start:
///          l32r  a3, uart            ; a3 = FIFO address
///          l32r  a4, msg_ptr         ; a4 = address of the string
///          movi  a5, 5               ; a5 = bytes remaining
///   loop:
///          l8ui  a2, a4, 0           ; a2 = *a4
///          s32i  a2, a3, 0           ; write it to the TX FIFO
///          addi  a4, a4, 1
///          addi  a5, a5, -1
///          bnez  a5, loop
///          ret
///
/// The literals sit before the code because L32R can only reach *backwards*.
const hello_firmware = blk: {
    // Layout, relative to the segment base:
    //   0x00  .word UART0 FIFO address
    //   0x04  .word address of the message
    //   0x08  "HELLO\0\0\0"
    //   0x10  code
    var image: [0x28]u8 = [_]u8{0} ** 0x28;

    // Literal 0: the UART FIFO register address.
    image[0x00] = 0x00;
    image[0x01] = 0x00;
    image[0x02] = 0xF4;
    image[0x03] = 0x3F; // 0x3FF40000, little-endian

    // Literal 1: the address of the message, IRAM base + 0x08.
    const msg_addr = soc.iram_base + 0x08;
    image[0x04] = @truncate(msg_addr);
    image[0x05] = @truncate(msg_addr >> 8);
    image[0x06] = @truncate(msg_addr >> 16);
    image[0x07] = @truncate(msg_addr >> 24);

    @memcpy(image[0x08..0x0D], "HELLO");

    // Code, starting at 0x10. L32R base is (pc + 3) & ~3.
    const code = [_]u8{
        // 0x10: l32r a3, 0x00  -> base (0x13 & ~3) = 0x10, offset -0x10 -> imm16 = 0xFFFC
        0x31, 0xFC, 0xFF,
        // 0x13: l32r a4, 0x04  -> base (0x16 & ~3) = 0x14, offset -0x10 -> imm16 = 0xFFFC
        0x41, 0xFC, 0xFF,
        // 0x16: movi a5, 5
        0x52, 0xA0, 0x05,
        // 0x19: l8ui a2, a4, 0
        0x22, 0x04, 0x00,
        // 0x1C: s32i a2, a3, 0
        0x22, 0x63, 0x00,
        // 0x1F: addi a4, a4, 1
        0x42, 0xC4, 0x01,
        // 0x22: addi a5, a5, -1
        0x52, 0xC5, 0xFF,
        // 0x25: bnez a5, 0x19  -> imm12 = 0x19 - (0x25 + 4) = -0x10 = 0xFF0
        0x56, 0x05, 0xFF,
        // 0x28: ret   (appended below; see `image` length)
    };
    @memcpy(image[0x10..][0..code.len], &code);
    break :blk image;
};

test "the vertical slice: an ELF that prints HELLO" {
    var machine: Machine = .{};
    try machine.init(testing.allocator);
    defer machine.deinit(testing.allocator);

    // `std.Io.Writer.fixed` is a writer that drains into a plain byte array and fails
    // with error.WriteFailed once it is full. It lets a test capture output through
    // exactly the same path the real program uses, with no file descriptors involved.
    var captured: [64]u8 = undefined;
    var sink = std.Io.Writer.fixed(&captured);
    machine.uart.sink = &sink;

    // The firmware above ends with `bnez`; append the final `ret` here so the constant
    // above stays a readable listing.
    var payload: [0x2B]u8 = undefined;
    @memcpy(payload[0..hello_firmware.len], &hello_firmware);
    payload[0x28] = 0x80; // ret
    payload[0x29] = 0x00;
    payload[0x2A] = 0x00;

    var elf_buf: [256]u8 = undefined;
    const image = buildElf(&elf_buf, &payload, soc.iram_base, soc.iram_base + 0x10);

    const load_result = try machine.loadElf(image);
    try testing.expectEqual(@as(u32, soc.iram_base + 0x10), load_result.entry);

    const summary = machine.run(default_step_budget, null);

    try testing.expectEqual(HaltReason.returned, summary.halt_reason);
    try testing.expectEqual(@as(u64, 5), summary.bytes_transmitted);
    // machine.run() flushed the UART, so the bytes are in the sink, not the UART buffer.
    try testing.expectEqualStrings("HELLO", sink.buffered());
}

/// Testing-strategy layer 2: a firmware fixture. `@embedFile` reads the file at *compile
/// time* and hands back a `[]const u8` constant, so this test exercises a real
/// GCC-produced ELF without opening a file at runtime.
///
/// Regenerate the fixture with `zig build firmware`. If this test ever fails after a
/// toolchain upgrade, disassemble it (`xtensa-esp-elf-objdump -d examples/hello.elf`) and
/// check whether GCC picked an instruction the decoder does not implement yet.
///
/// The name "hello_elf" is registered in build.zig, because `@embedFile` cannot reach
/// outside the module's root directory (src/) by relative path.
const hello_elf_fixture = @embedFile("hello_elf");

test "a real xtensa-esp-elf-gcc build of hello.S prints HELLO" {
    var machine: Machine = .{};
    try machine.init(testing.allocator);
    defer machine.deinit(testing.allocator);

    var captured: [64]u8 = undefined;
    var sink = std.Io.Writer.fixed(&captured);
    machine.uart.sink = &sink;

    _ = try machine.loadElf(hello_elf_fixture);
    const summary = machine.run(default_step_budget, null);

    // hello.S ends in `j .` rather than `ret`, which is how firmware actually finishes.
    try testing.expectEqual(HaltReason.spin_loop, summary.halt_reason);
    try testing.expectEqualStrings("HELLO", sink.buffered());

    // GCC compiled the loop body into narrow forms (s32i.n, addi.n, movi.n), so this
    // fixture also proves the 16-bit decode path against a real assembler.
    try testing.expectEqual(@as(u64, 29), summary.steps);
}

test "a machine can be reused for a second image" {
    var machine: Machine = .{};
    try machine.init(testing.allocator);
    defer machine.deinit(testing.allocator);

    // A program that transmits nothing and returns immediately.
    var elf_buf: [256]u8 = undefined;
    const image = buildElf(&elf_buf, &[_]u8{ 0x80, 0x00, 0x00 }, soc.iram_base, soc.iram_base);

    _ = try machine.loadElf(image);
    const summary = machine.run(default_step_budget, null);

    try testing.expectEqual(HaltReason.returned, summary.halt_reason);
    try testing.expectEqual(@as(u64, 1), summary.steps);
    try testing.expectEqual(@as(u64, 0), summary.bytes_transmitted);
}
