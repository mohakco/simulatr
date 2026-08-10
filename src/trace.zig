//! Instruction trace: one JSON object per executed instruction, on stdout.
//!
//! Format (fields in a fixed order so a diff between two runs is readable):
//!
//!   {"step":3,"pc":"0x40080006","raw":"0x0020c0","len":3,"op":"memw","a":["0x0", ...]}
//!
//! It is JSON *Lines* — one self-contained object per line, no enclosing array — so it can
//! be streamed, grepped, and piped into `jq` while the run is still going.
//!
//! The formatting is done by hand into a fixed-size buffer rather than through
//! `std.json`. Two reasons: the output shape is fixed and trivial, and doing it this way
//! keeps the tracer allocation-free and the formatting logic unit-testable as a pure
//! function (`formatLine`) with no I/O.

const std = @import("std");
const decode = @import("cpu/decode.zig");

/// Worst case: ~90 bytes of scaffolding plus 16 registers at up to 13 bytes each.
pub const line_buffer_size = 512;

pub const Tracer = struct {
    /// Scratch space for one formatted line. Reused every instruction, so tracing does
    /// not allocate.
    buffer: [line_buffer_size]u8 = undefined,

    /// Where lines go. `null` formats and discards, which is useful for measuring the
    /// cost of tracing but is otherwise not something you would ask for.
    out: ?*std.Io.Writer = null,

    pub fn emit(
        self: *Tracer,
        step: u64,
        pc: u32,
        raw: u32,
        insn: decode.Instruction,
        regs: *const [16]u32,
    ) void {
        const line = formatLine(&self.buffer, step, pc, raw, insn, regs) catch return;
        if (self.out) |w| w.writeAll(line) catch {};
    }
};

/// Render one trace line into `buf` and return the slice that was written.
///
/// Returns `error.NoSpaceLeft` if the buffer is too small — `std.fmt.bufPrint` never
/// writes past the end of the slice it is given, which is why a fixed buffer is safe here.
pub fn formatLine(
    buf: []u8,
    step: u64,
    pc: u32,
    raw: u32,
    insn: decode.Instruction,
    regs: *const [16]u32,
) error{NoSpaceLeft}![]const u8 {
    // `bufPrint` returns the slice it filled; `written` tracks how much of `buf` is used
    // so the next call can start where the last one stopped.
    var written: usize = 0;

    // `@tagName` turns an enum value into its source-level name at compile time — this is
    // where the `bitwise_and` spelling from the Op enum shows up in the output.
    written += (try std.fmt.bufPrint(buf[written..], "{{\"step\":{d},\"pc\":\"0x{x:0>8}\",\"raw\":\"0x{x:0>6}\",\"len\":{d},\"op\":\"{s}\",\"a\":[", .{
        step,
        pc,
        raw,
        insn.length,
        @tagName(insn.op),
    })).len;

    for (regs, 0..) |value, i| {
        const sep = if (i == 0) "" else ",";
        written += (try std.fmt.bufPrint(buf[written..], "{s}\"0x{x}\"", .{ sep, value })).len;
    }

    written += (try std.fmt.bufPrint(buf[written..], "]}}\n", .{})).len;
    return buf[0..written];
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "trace line shape" {
    var buf: [line_buffer_size]u8 = undefined;
    var regs = [_]u32{0} ** 16;
    regs[2] = 0x48;

    const insn = decode.Instruction{ .op = .movi, .length = 3, .t = 2, .imm = 0x48 };
    const line = try formatLine(&buf, 7, 0x4008_0000, 0x4822_A0, insn, &regs);

    try testing.expect(std.mem.startsWith(u8, line, "{\"step\":7,\"pc\":\"0x40080000\","));
    try testing.expect(std.mem.indexOf(u8, line, "\"raw\":\"0x4822a0\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"op\":\"movi\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"a\":[\"0x0\",\"0x0\",\"0x48\",") != null);
    try testing.expect(std.mem.endsWith(u8, line, "]}\n"));
}

test "every register appears exactly once" {
    var buf: [line_buffer_size]u8 = undefined;
    var regs: [16]u32 = undefined;
    for (&regs, 0..) |*reg, i| reg.* = @intCast(i);

    const insn = decode.Instruction{ .op = .nop, .length = 3 };
    const line = try formatLine(&buf, 0, 0, 0x0020F0, insn, &regs);

    var commas: usize = 0;
    for (line) |c| {
        if (c == ',') commas += 1;
    }
    // 5 commas separating the six scalar fields, plus 15 between the 16 registers.
    try testing.expectEqual(@as(usize, 5 + 15), commas);
    try testing.expect(std.mem.indexOf(u8, line, "\"0xf\"]") != null);
}

test "a too-small buffer is an error, not an overrun" {
    var buf: [16]u8 = undefined;
    const regs = [_]u32{0} ** 16;
    const insn = decode.Instruction{ .op = .nop, .length = 3 };
    try testing.expectError(error.NoSpaceLeft, formatLine(&buf, 0, 0, 0, insn, &regs));
}
