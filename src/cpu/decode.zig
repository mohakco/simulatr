//! Xtensa LX6 instruction decoder.
//!
//! Reference: Xtensa Instruction Set Architecture (ISA) Reference Manual,
//! https://0x04.net/~mwk/doc/xtensa.pdf — chapter 7 (instruction descriptions) and the
//! "Instruction Formats" section of chapter 3.
//!
//! ## Three things about Xtensa that shape this file
//!
//! **1. Variable length.** Core instructions are 24 bits (3 bytes). With the Code Density
//! option — which the ESP32 has — there are also 16-bit "narrow" forms. The length is
//! decided by bit 3 of the *first byte*: set means 2 bytes, clear means 3. That single bit
//! is `op0`'s high bit, so `op0 >= 8` means narrow.
//!
//! **2. Little-endian, including inside the instruction.** A 24-bit instruction stored as
//! bytes `b0 b1 b2` has the value `b0 | b1<<8 | b2<<16`. The manual numbers instruction
//! bits from 0 = least significant, and its field diagrams read right-to-left. So `op0` is
//! bits 3:0 and lives in the *first* byte in memory.
//!
//! **3. Fields overlap.** Xtensa reuses the same bit positions for different purposes
//! depending on the format. `imm8` (bits 23:16) covers the same bits as `op1` and `op2`;
//! `t` (bits 7:4) is split into `m` (7:6) and `n` (5:4) in the branch formats. We extract
//! the regular fields with a packed struct and pull the overlapping ones out by hand.
//!
//! ## Decoding is a tree
//!
//! `op0` selects a group; inside a group `op1`, `op2`, `r`, `t` or `n` narrow it down.
//! The switch below walks that tree in exactly the order the manual's tables do.

const std = @import("std");

/// Every instruction Phase 1 understands.
///
/// `and`, `or` and `xor` are Zig keywords, so those three are spelled out.
pub const Op = enum {
    // --- 24-bit: load / store / immediate arithmetic (op0 = 2, "LSAI") ---
    l8ui,
    l16ui,
    l16si,
    l32i,
    s8i,
    s16i,
    s32i,
    movi,
    addi,
    addmi,

    // --- 24-bit: PC-relative load (op0 = 1) ---
    l32r,

    // --- 24-bit: register-register ALU (op0 = 0, op1 = 0) ---
    add,
    sub,
    bitwise_and,
    bitwise_or,
    bitwise_xor,

    // --- 24-bit: control flow and sync (op0 = 0, op1 = 0, op2 = 0) ---
    ret,
    callx0,
    jx,
    memw,
    nop,

    // --- 24-bit: call and jump (op0 = 5 and 6) ---
    call0,
    j,

    // --- 24-bit: branch on register vs zero (op0 = 6, n = 1) ---
    beqz,
    bnez,
    bltz,
    bgez,

    // --- 24-bit: branch on register vs register (op0 = 7) ---
    beq,
    bne,
    blt,
    bltu,
    bge,
    bgeu,

    // --- 16-bit narrow forms (op0 >= 8) ---
    l32i_n,
    s32i_n,
    add_n,
    addi_n,
    movi_n,
    mov_n,
    beqz_n,
    bnez_n,
    ret_n,
    nop_n,
};

pub const DecodeError = error{
    /// The encoding is not a valid Xtensa instruction at all (reserved bit pattern).
    IllegalInstruction,
    /// A real Xtensa instruction that Phase 1 chose not to implement — anything using
    /// register windows, exceptions, special registers, shifts, multiplies, and so on.
    /// Distinct from IllegalInstruction so a failing run tells you which it was.
    UnsupportedInstruction,
};

/// A decoded instruction: what to do, plus every operand already extracted and scaled.
///
/// Immediates are stored sign-extended and pre-scaled, and branch/jump destinations are
/// stored as absolute addresses. All the fiddly bit work happens here, once, so that the
/// executor in cpu/core.zig is a plain, readable switch.
pub const Instruction = struct {
    op: Op,
    /// 2 or 3. The executor adds this to the PC for non-branching instructions.
    length: u2,

    /// The three register fields, straight from the encoding. Which of them is a source
    /// and which is a destination depends on `op`; see the comments in the executor.
    r: u4 = 0,
    s: u4 = 0,
    t: u4 = 0,

    /// Immediate operand, already sign-extended and scaled (e.g. an l32i offset is the
    /// byte offset, not the raw 8-bit field).
    imm: i32 = 0,

    /// Absolute destination address for j / call0 / branches, and the absolute literal
    /// address for l32r. Meaningless for other ops.
    target: u32 = 0,
};

// ---------------------------------------------------------------------------------------
// Instruction fields
// ---------------------------------------------------------------------------------------

/// The regular field layout of a 24-bit instruction.
///
/// A `packed struct` has a guaranteed bit layout with no padding, and — importantly here —
/// Zig lays the *first* field out at the *least significant* bits. That matches how the
/// Xtensa manual numbers instruction bits, so this declaration can be read straight off
/// the manual's format diagram (reading its diagram right to left).
///
/// `packed struct(u24)` states the backing integer type; `@bitCast` then converts between
/// the u24 and the struct for free, with the compiler checking the widths add up.
const Fields24 = packed struct(u24) {
    op0: u4, // bits 3:0
    t: u4, // bits 7:4
    s: u4, // bits 11:8
    r: u4, // bits 15:12
    op1: u4, // bits 19:16
    op2: u4, // bits 23:20
};

/// The 16-bit narrow layout ("RRRN" in the manual).
const Fields16 = packed struct(u16) {
    op0: u4, // bits 3:0
    t: u4, // bits 7:4
    s: u4, // bits 11:8
    r: u4, // bits 15:12
};

/// How many bytes the instruction starting with `first_byte` occupies.
///
/// This is the whole rule: bit 3 of the first byte. Xtensa deliberately put the length
/// indicator where it can be read without decoding anything else, so a fetch unit can
/// decide how much to read up front.
pub fn instructionLength(first_byte: u8) u2 {
    return if (first_byte & 0x08 != 0) 2 else 3;
}

/// Sign-extend the low `bits` bits of `value` to a full i32.
///
/// `comptime bits` means the width is required to be known at compile time, so the shift
/// amounts are constants and the compiler can check them. `comptime` is Zig's single
/// mechanism for generics, constant folding and compile-time checks — no macros, no
/// preprocessor, just ordinary code the compiler runs while compiling.
fn signExtend(comptime bits: u6, value: u32) i32 {
    comptime std.debug.assert(bits > 0 and bits <= 32);
    if (bits == 32) return @bitCast(value);

    const shift: u5 = @intCast(32 - bits);
    const mask: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
    // Push the sign bit up to bit 31, then shift back down. On a *signed* integer `>>` is
    // an arithmetic shift, so it replicates the sign bit — which is exactly the extension
    // we want. `@bitCast` reinterprets the bits without changing them.
    const shifted: u32 = (value & mask) << shift;
    return @as(i32, @bitCast(shifted)) >> shift;
}

/// Add a signed offset to an address with hardware wraparound semantics.
fn addSigned(base: u32, offset: i32) u32 {
    // `+%` wraps instead of panicking on overflow. `@bitCast` turns the i32 into the u32
    // with the same bit pattern, which for two's complement makes wrapping addition do
    // signed arithmetic for free.
    return base +% @as(u32, @bitCast(offset));
}

// ---------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------

/// Decode one instruction.
///
/// `pc` is the address of this instruction; it is needed because several Xtensa
/// instructions are PC-relative and we resolve them to absolute addresses here.
/// `raw` holds the instruction bytes already assembled little-endian (b0 | b1<<8 | b2<<16).
/// `length` must come from `instructionLength`.
pub fn decode(pc: u32, raw: u32, length: u2) DecodeError!Instruction {
    return switch (length) {
        3 => decode24(pc, @truncate(raw)),
        2 => decode16(pc, @truncate(raw)),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------------------
// 24-bit instructions
// ---------------------------------------------------------------------------------------

fn decode24(pc: u32, raw: u24) DecodeError!Instruction {
    const f: Fields24 = @bitCast(raw);
    const w: u32 = raw; // for the overlapping fields, extracted by shifting

    return switch (f.op0) {
        0x0 => decodeQrst(f),
        0x1 => decodeL32r(pc, w),
        0x2 => decodeLsai(f, w),
        0x5 => decodeCall(pc, w),
        0x6 => decodeSi(pc, f, w),
        0x7 => decodeB(pc, f, w),
        // op0 3 (LSCI, coprocessor loads), 4 (extended), 8+ handled elsewhere.
        else => error.UnsupportedInstruction,
    };
}

/// op0 = 0: the "QRST" group, which holds all register-register operations.
/// `op1` picks a sub-table; Phase 1 only needs RST0 (op1 = 0).
fn decodeQrst(f: Fields24) DecodeError!Instruction {
    if (f.op1 != 0x0) {
        // op1 1..3 are shifts, extui, multiplies and special-register moves; 4..F are
        // floating point, MAC16 and the load/store-with-index forms. Phase 2 territory.
        return error.UnsupportedInstruction;
    }

    // RST0: op2 selects the operation.
    return switch (f.op2) {
        0x0 => decodeSt0(f),
        0x1 => rrr(.bitwise_and, f),
        0x2 => rrr(.bitwise_or, f),
        0x3 => rrr(.bitwise_xor, f),
        0x8 => rrr(.add, f),
        0xC => rrr(.sub, f),
        // 0x9..0xB are ADDX2/4/8, 0xD..0xF SUBX2/4/8; 0x4..0x7 are ST1/TLB/RT0.
        else => error.UnsupportedInstruction,
    };
}

/// RRR format: AR[r] <- AR[s] op AR[t].
fn rrr(op: Op, f: Fields24) Instruction {
    return .{ .op = op, .length = 3, .r = f.r, .s = f.s, .t = f.t };
}

/// op0 = 0, op1 = 0, op2 = 0: the "ST0" table. `r` selects.
fn decodeSt0(f: Fields24) DecodeError!Instruction {
    return switch (f.r) {
        0x0 => decodeSnm0(f),
        0x2 => decodeSync(f),
        // 0x1 MOVSP, 0x3 RFEI, 0x4 BREAK, 0x5 SYSCALL, 0x6 RSIL, 0x7 WAITI,
        // 0x8..0xB the boolean ANY/ALL operations.
        else => error.UnsupportedInstruction,
    };
}

/// ST0 with r = 0: the indirect jumps and calls. Here the `t` field is split into
/// `m` = t[3:2] and `n` = t[1:0]:
///     m = 0  ILL          (the canonical illegal instruction, 0x000000)
///     m = 2  JR family    n = 0 RET, n = 1 RETW, n = 2 JX
///     m = 3  CALLX family n = 0 CALLX0, 1 CALLX4, 2 CALLX8, 3 CALLX12
fn decodeSnm0(f: Fields24) DecodeError!Instruction {
    const m: u2 = @truncate(f.t >> 2);
    const n: u2 = @truncate(f.t);

    return switch (m) {
        0 => error.IllegalInstruction, // ILL
        2 => switch (n) {
            0 => Instruction{ .op = .ret, .length = 3 },
            2 => Instruction{ .op = .jx, .length = 3, .s = f.s },
            else => error.UnsupportedInstruction, // RETW: needs register windows
        },
        3 => switch (n) {
            0 => Instruction{ .op = .callx0, .length = 3, .s = f.s },
            else => error.UnsupportedInstruction, // CALLX4/8/12: register windows
        },
        else => error.IllegalInstruction,
    };
}

/// ST0 with r = 2: the memory/pipeline barriers. `t` selects.
fn decodeSync(f: Fields24) DecodeError!Instruction {
    return switch (f.t) {
        0xC => Instruction{ .op = .memw, .length = 3 },
        0xF => Instruction{ .op = .nop, .length = 3 },
        // ISYNC, RSYNC, ESYNC, DSYNC, EXCW, EXTW. All are no-ops in an in-order
        // interpreter with no caches, but Phase 1 leaves them unimplemented rather than
        // silently accepting instructions it has not thought about.
        else => error.UnsupportedInstruction,
    };
}

/// op0 = 1: L32R, the PC-relative literal load.
///
/// Xtensa has no "load a 32-bit constant" instruction — MOVI only reaches 12 bits. The
/// compiler instead parks the constant in a *literal pool* just before the code and emits
/// L32R to fetch it. Two consequences worth knowing:
///
///   * The 16-bit field is a *negative* word offset: the encoded value is OR-ed into
///     0xFFFC0000, so the reachable range is PC-262144 .. PC-4. Literals always precede
///     the instruction that uses them.
///   * The base is `(PC + 3) & ~3`, i.e. the address after the instruction rounded down
///     to a word boundary. This matches binutils' `Operand_uimm16x4_ator`, which computes
///     the field as `target - ((pc + 3) & ~3)`, and is confirmed by objdump on
///     examples/hello.elf: the `l32r` at 0x4008000B encodes imm16 = 0xFFFE (offset -8)
///     and resolves to 0x40080004. Using `PC & ~3` as the base would give 0x40080000 and
///     load the wrong literal. See docs/PHASE1-NOTES.md.
fn decodeL32r(pc: u32, w: u32) DecodeError!Instruction {
    // RI16 format: imm16 is bits 23:8, t is bits 7:4.
    const imm16: u32 = (w >> 8) & 0xFFFF;
    const t: u4 = @truncate((w >> 4) & 0xF);

    const offset: u32 = 0xFFFC_0000 | (imm16 << 2);
    const base: u32 = (pc +% 3) & ~@as(u32, 3);

    return .{ .op = .l32r, .length = 3, .t = t, .target = base +% offset };
}

/// op0 = 2: the "LSAI" group — loads, stores, and the immediate arithmetic that shares
/// the RRI8 format with them. `r` selects. Load and store offsets are *unsigned* and
/// scaled by the access width, so l32i reaches 0..1020 bytes past the base register.
fn decodeLsai(f: Fields24, w: u32) DecodeError!Instruction {
    const imm8: u32 = (w >> 16) & 0xFF;

    return switch (f.r) {
        0x0 => mem(.l8ui, f, @intCast(imm8)),
        0x1 => mem(.l16ui, f, @intCast(imm8 << 1)),
        0x2 => mem(.l32i, f, @intCast(imm8 << 2)),
        0x4 => mem(.s8i, f, @intCast(imm8)),
        0x5 => mem(.s16i, f, @intCast(imm8 << 1)),
        0x6 => mem(.s32i, f, @intCast(imm8 << 2)),
        0x9 => mem(.l16si, f, @intCast(imm8 << 1)),
        // MOVI is the odd one out: it borrows the `s` field for the top 4 bits of a
        // 12-bit signed immediate, so it has no base register.
        0xA => Instruction{
            .op = .movi,
            .length = 3,
            .t = f.t,
            .imm = signExtend(12, (@as(u32, f.s) << 8) | imm8),
        },
        0xC => Instruction{
            .op = .addi,
            .length = 3,
            .t = f.t,
            .s = f.s,
            .imm = signExtend(8, imm8),
        },
        // ADDMI adds a sign-extended 8-bit value scaled by 256 — the "medium immediate"
        // used to build stack frame offsets larger than ADDI can reach.
        0xD => Instruction{
            .op = .addmi,
            .length = 3,
            .t = f.t,
            .s = f.s,
            .imm = signExtend(8, imm8) * 256,
        },
        // 0x3 reserved, 0x7 CACHE ops, 0x8 reserved, 0xB L32AI, 0xE S32C1I, 0xF S32RI.
        else => error.UnsupportedInstruction,
    };
}

/// RRI8 load or store: address = AR[s] + offset, data register is AR[t].
fn mem(op: Op, f: Fields24, offset: i32) Instruction {
    return .{ .op = op, .length = 3, .t = f.t, .s = f.s, .imm = offset };
}

/// op0 = 5: the CALL group. Bits 5:4 pick the window increment; only CALL0 (no window
/// rotation) exists for us. The 18-bit offset is scaled by 4 and relative to the *word
/// aligned* PC, so call targets are always 4-byte aligned.
fn decodeCall(pc: u32, w: u32) DecodeError!Instruction {
    const n: u2 = @truncate((w >> 4) & 0x3);
    if (n != 0) return error.UnsupportedInstruction; // CALL4/CALL8/CALL12

    const offset18: u32 = (w >> 6) & 0x3_FFFF;
    const byte_offset = signExtend(18, offset18) * 4;
    const target = addSigned((pc & ~@as(u32, 3)) +% 4, byte_offset);

    return .{ .op = .call0, .length = 3, .target = target };
}

/// op0 = 6: the "SI" group — jump and the compare-against-zero branches.
/// Bits 5:4 (`n`) select the sub-group.
fn decodeSi(pc: u32, f: Fields24, w: u32) DecodeError!Instruction {
    const n: u2 = @truncate((w >> 4) & 0x3);

    switch (n) {
        // J: an 18-bit *byte* offset (unlike CALL0, not scaled), relative to PC + 4.
        0 => {
            const offset18: u32 = (w >> 6) & 0x3_FFFF;
            return .{
                .op = .j,
                .length = 3,
                .target = addSigned(pc +% 4, signExtend(18, offset18)),
            };
        },
        // BZ: BRI12 format. imm12 is bits 23:12, and bits 7:6 (`m`) pick the condition.
        1 => {
            const imm12: u32 = (w >> 12) & 0xFFF;
            const m: u2 = @truncate((w >> 6) & 0x3);
            const op: Op = switch (m) {
                0 => .beqz,
                1 => .bnez,
                2 => .bltz,
                3 => .bgez,
            };
            return .{
                .op = op,
                .length = 3,
                .s = f.s,
                .target = addSigned(pc +% 4, signExtend(12, imm12)),
            };
        },
        // BI0 (BEQI/BNEI/BLTI/BGEI) and BI1 (ENTRY/BF/BT/BLTUI/BGEUI). These encode their
        // comparison constant through the B4CONST/B4CONSTU lookup tables; Phase 1 does
        // not need them and guessing those tables would be worse than refusing.
        else => return error.UnsupportedInstruction,
    }
}

/// op0 = 7: register-to-register conditional branches, BRI8 format.
/// The 8-bit offset is signed and relative to PC + 4, giving a -128..+127 byte reach.
fn decodeB(pc: u32, f: Fields24, w: u32) DecodeError!Instruction {
    const imm8: u32 = (w >> 16) & 0xFF;

    const op: Op = switch (f.r) {
        0x1 => .beq,
        0x2 => .blt,
        0x3 => .bltu,
        0x9 => .bne,
        0xA => .bge,
        0xB => .bgeu,
        // 0x0 BNONE, 0x4 BALL, 0x5 BBC, 0x6/0x7 BBCI, 0x8 BANY, 0xC BNALL,
        // 0xD BBS, 0xE/0xF BBSI — bit-test branches, not needed yet.
        else => return error.UnsupportedInstruction,
    };

    return .{
        .op = op,
        .length = 3,
        .s = f.s,
        .t = f.t,
        .target = addSigned(pc +% 4, signExtend(8, imm8)),
    };
}

// ---------------------------------------------------------------------------------------
// 16-bit narrow instructions (the Code Density option)
// ---------------------------------------------------------------------------------------

fn decode16(pc: u32, raw: u16) DecodeError!Instruction {
    const f: Fields16 = @bitCast(raw);

    return switch (f.op0) {
        // L32I.N / S32I.N: address = AR[s] + (r * 4). The 4-bit offset reaches 0..60,
        // which covers most stack-frame accesses — that is why the narrow form pays off.
        0x8 => Instruction{ .op = .l32i_n, .length = 2, .t = f.t, .s = f.s, .imm = @as(i32, f.r) * 4 },
        0x9 => Instruction{ .op = .s32i_n, .length = 2, .t = f.t, .s = f.s, .imm = @as(i32, f.r) * 4 },

        // ADD.N: AR[r] <- AR[s] + AR[t].
        0xA => Instruction{ .op = .add_n, .length = 2, .r = f.r, .s = f.s, .t = f.t },

        // ADDI.N: AR[r] <- AR[s] + imm, where the `t` field encodes 1..15 directly and
        // 0 means -1. There is no "add zero" narrow form because that is what MOV.N is for.
        0xB => Instruction{
            .op = .addi_n,
            .length = 2,
            .r = f.r,
            .s = f.s,
            .imm = if (f.t == 0) -1 else @as(i32, f.t),
        },

        0xC => decodeSt2(pc, f),
        0xD => decodeSt3(f),

        // 0xE and 0xF are reserved in the LX6 core ISA.
        else => error.IllegalInstruction,
    };
}

/// op0 = 0xC ("ST2"). Bit 3 of `t` splits the table:
///   t[3] = 0 -> MOVI.N, a 7-bit immediate assembled from t[2:0] and r
///   t[3] = 1 -> BEQZ.N (t[2] = 0) or BNEZ.N (t[2] = 1), with a 6-bit *unsigned* offset
fn decodeSt2(pc: u32, f: Fields16) DecodeError!Instruction {
    if (f.t & 0x8 == 0) {
        // MOVI.N covers -32..95, encoded asymmetrically: the 7-bit field holds 0..95 for
        // non-negative values, and 96..127 for -32..-1. It is NOT a plain sign-extended
        // 7-bit field, because small positive constants are far more common than negative
        // ones and this buys 32 extra positive values.
        const imm7: u32 = (@as(u32, f.t & 0x7) << 4) | @as(u32, f.r);
        const value: i32 = if (imm7 >= 96)
            @as(i32, @intCast(imm7)) - 128
        else
            @intCast(imm7);

        return .{ .op = .movi_n, .length = 2, .s = f.s, .imm = value };
    }

    // BEQZ.N / BNEZ.N. The offset is 6 bits, unsigned, relative to PC + 4 — these branch
    // *forward only*, reaching 4..67 bytes ahead. Backwards loops need the 24-bit form.
    const imm6: u32 = (@as(u32, f.t & 0x3) << 4) | @as(u32, f.r);
    const op: Op = if (f.t & 0x4 == 0) .beqz_n else .bnez_n;

    return .{ .op = op, .length = 2, .s = f.s, .target = pc +% 4 +% imm6 };
}

/// op0 = 0xD ("ST3"). `r` selects.
fn decodeSt3(f: Fields16) DecodeError!Instruction {
    return switch (f.r) {
        // MOV.N at, as -> AR[t] <- AR[s].
        0x0 => Instruction{ .op = .mov_n, .length = 2, .t = f.t, .s = f.s },
        0xF => switch (f.t) {
            0x0 => Instruction{ .op = .ret_n, .length = 2 },
            0x3 => Instruction{ .op = .nop_n, .length = 2 },
            // 0x1 RETW.N (register windows), 0x2 BREAK.N (debug), 0x6 ILL.N.
            0x6 => error.IllegalInstruction,
            else => error.UnsupportedInstruction,
        },
        else => error.UnsupportedInstruction,
    };
}

// ---------------------------------------------------------------------------------------
// Tests
//
// Every expected encoding below is written as the little-endian byte sequence you would
// see in a hex dump, so it can be checked against `xtensa-esp-elf-objdump` once the
// toolchain exists.
// ---------------------------------------------------------------------------------------

const testing = std.testing;

/// Assemble bytes into the raw word the decoder expects, then decode at `pc`.
fn decodeBytes(pc: u32, bytes: []const u8) DecodeError!Instruction {
    const length = instructionLength(bytes[0]);
    var raw: u32 = 0;
    var i: usize = 0;
    while (i < length) : (i += 1) {
        raw |= @as(u32, bytes[i]) << @intCast(i * 8);
    }
    return decode(pc, raw, length);
}

test "instruction length comes from bit 3 of the first byte" {
    try testing.expectEqual(@as(u2, 3), instructionLength(0x00)); // op0 = 0
    try testing.expectEqual(@as(u2, 3), instructionLength(0x32)); // op0 = 2
    try testing.expectEqual(@as(u2, 3), instructionLength(0x07)); // op0 = 7
    try testing.expectEqual(@as(u2, 2), instructionLength(0x0D)); // op0 = D
    try testing.expectEqual(@as(u2, 2), instructionLength(0x2B)); // op0 = B
}

test "sign extension" {
    try testing.expectEqual(@as(i32, 127), signExtend(8, 0x7F));
    try testing.expectEqual(@as(i32, -1), signExtend(8, 0xFF));
    try testing.expectEqual(@as(i32, -128), signExtend(8, 0x80));
    try testing.expectEqual(@as(i32, 2047), signExtend(12, 0x7FF));
    try testing.expectEqual(@as(i32, -2048), signExtend(12, 0x800));
    try testing.expectEqual(@as(i32, -1), signExtend(18, 0x3FFFF));
}

// --- no-operand instructions -----------------------------------------------------------

test "ret is 0x000080" {
    const insn = try decodeBytes(0x4008_0000, &[_]u8{ 0x80, 0x00, 0x00 });
    try testing.expectEqual(Op.ret, insn.op);
    try testing.expectEqual(@as(u2, 3), insn.length);
}

test "memw is 0x0020C0 and nop is 0x0020F0" {
    const memw_insn = try decodeBytes(0, &[_]u8{ 0xC0, 0x20, 0x00 });
    try testing.expectEqual(Op.memw, memw_insn.op);

    const nop_insn = try decodeBytes(0, &[_]u8{ 0xF0, 0x20, 0x00 });
    try testing.expectEqual(Op.nop, nop_insn.op);
}

test "ret.n is 0xF00D and nop.n is 0xF03D" {
    const ret_insn = try decodeBytes(0, &[_]u8{ 0x0D, 0xF0 });
    try testing.expectEqual(Op.ret_n, ret_insn.op);
    try testing.expectEqual(@as(u2, 2), ret_insn.length);

    const nop_insn = try decodeBytes(0, &[_]u8{ 0x3D, 0xF0 });
    try testing.expectEqual(Op.nop_n, nop_insn.op);
}

test "the all-zero word is the canonical illegal instruction" {
    try testing.expectError(error.IllegalInstruction, decodeBytes(0, &[_]u8{ 0x00, 0x00, 0x00 }));
}

// --- register-register ALU -------------------------------------------------------------

test "add a3, a4, a5" {
    // RRR: op2=8 op1=0 r=3 s=4 t=5 op0=0 -> word 0x803450
    // bytes little-endian: 0x50, 0x34, 0x80
    const insn = try decodeBytes(0, &[_]u8{ 0x50, 0x34, 0x80 });
    try testing.expectEqual(Op.add, insn.op);
    try testing.expectEqual(@as(u4, 3), insn.r);
    try testing.expectEqual(@as(u4, 4), insn.s);
    try testing.expectEqual(@as(u4, 5), insn.t);
}

test "sub a1, a2, a3" {
    // op2=C op1=0 r=1 s=2 t=3 op0=0 -> word 0xC01230, bytes 0x30, 0x12, 0xC0
    const insn = try decodeBytes(0, &[_]u8{ 0x30, 0x12, 0xC0 });
    try testing.expectEqual(Op.sub, insn.op);
    try testing.expectEqual(@as(u4, 1), insn.r);
    try testing.expectEqual(@as(u4, 2), insn.s);
    try testing.expectEqual(@as(u4, 3), insn.t);
}

test "and / or / xor share the RST0 table" {
    // op2 = 1, 2, 3 with r=1 s=2 t=3.
    try testing.expectEqual(Op.bitwise_and, (try decodeBytes(0, &[_]u8{ 0x30, 0x12, 0x10 })).op);
    try testing.expectEqual(Op.bitwise_or, (try decodeBytes(0, &[_]u8{ 0x30, 0x12, 0x20 })).op);
    try testing.expectEqual(Op.bitwise_xor, (try decodeBytes(0, &[_]u8{ 0x30, 0x12, 0x30 })).op);
}

// --- loads, stores, immediates ---------------------------------------------------------

test "l32i a2, a3, 8" {
    // RRI8: imm8=2 (8/4) r=2 s=3 t=2 op0=2 -> word 0x02_23_22, bytes 0x22, 0x23, 0x02
    const insn = try decodeBytes(0, &[_]u8{ 0x22, 0x23, 0x02 });
    try testing.expectEqual(Op.l32i, insn.op);
    try testing.expectEqual(@as(u4, 2), insn.t); // destination
    try testing.expectEqual(@as(u4, 3), insn.s); // base
    try testing.expectEqual(@as(i32, 8), insn.imm); // offset, already scaled by 4
}

test "s32i a4, a5, 1020 is the largest reachable offset" {
    // imm8 = 255, scaled by 4 -> 1020. r=6 s=5 t=4.
    const insn = try decodeBytes(0, &[_]u8{ 0x42, 0x65, 0xFF });
    try testing.expectEqual(Op.s32i, insn.op);
    try testing.expectEqual(@as(u4, 4), insn.t);
    try testing.expectEqual(@as(u4, 5), insn.s);
    try testing.expectEqual(@as(i32, 1020), insn.imm);
}

test "byte and halfword loads scale their offsets differently" {
    // l8ui a2, a3, 5   -> r=0, imm8=5, unscaled
    const l8 = try decodeBytes(0, &[_]u8{ 0x22, 0x03, 0x05 });
    try testing.expectEqual(Op.l8ui, l8.op);
    try testing.expectEqual(@as(i32, 5), l8.imm);

    // l16ui a2, a3, 10 -> r=1, imm8=5, scaled by 2
    const l16 = try decodeBytes(0, &[_]u8{ 0x22, 0x13, 0x05 });
    try testing.expectEqual(Op.l16ui, l16.op);
    try testing.expectEqual(@as(i32, 10), l16.imm);

    // s8i a2, a3, 5 -> r=4
    const s8 = try decodeBytes(0, &[_]u8{ 0x22, 0x43, 0x05 });
    try testing.expectEqual(Op.s8i, s8.op);
    try testing.expectEqual(@as(i32, 5), s8.imm);
}

test "movi a2, 0x123 packs its immediate across two fields" {
    // r=A, imm12 = 0x123 -> s = 0x1 (high nibble), imm8 = 0x23. t=2.
    // word: imm8=0x23 r=0xA s=0x1 t=0x2 op0=0x2 -> 0x23_A1_22
    const insn = try decodeBytes(0, &[_]u8{ 0x22, 0xA1, 0x23 });
    try testing.expectEqual(Op.movi, insn.op);
    try testing.expectEqual(@as(u4, 2), insn.t);
    try testing.expectEqual(@as(i32, 0x123), insn.imm);
}

test "movi a2, -1 sign-extends the 12-bit immediate" {
    // imm12 = 0xFFF -> s = 0xF, imm8 = 0xFF.
    const insn = try decodeBytes(0, &[_]u8{ 0x22, 0xAF, 0xFF });
    try testing.expectEqual(Op.movi, insn.op);
    try testing.expectEqual(@as(i32, -1), insn.imm);
}

test "addi and addmi" {
    // addi a2, a3, -1 : r=C s=3 t=2 imm8=0xFF
    const addi_insn = try decodeBytes(0, &[_]u8{ 0x22, 0xC3, 0xFF });
    try testing.expectEqual(Op.addi, addi_insn.op);
    try testing.expectEqual(@as(u4, 2), addi_insn.t);
    try testing.expectEqual(@as(u4, 3), addi_insn.s);
    try testing.expectEqual(@as(i32, -1), addi_insn.imm);

    // addmi a2, a3, -256 : r=D, imm8=0xFF, scaled by 256
    const addmi_insn = try decodeBytes(0, &[_]u8{ 0x22, 0xD3, 0xFF });
    try testing.expectEqual(Op.addmi, addmi_insn.op);
    try testing.expectEqual(@as(i32, -256), addmi_insn.imm);
}

// --- l32r ------------------------------------------------------------------------------

test "l32r resolves to an absolute address before the instruction" {
    // imm16 = 0xFFFF -> offset = 0xFFFC0000 | 0x3FFFC = 0xFFFFFFFC = -4.
    // At pc = 0x40080010: base = (0x40080013) & ~3 = 0x40080010, target = 0x4008000C.
    // word: imm16=0xFFFF t=2 op0=1 -> 0xFF_FF_21, bytes 0x21, 0xFF, 0xFF
    const insn = try decodeBytes(0x4008_0010, &[_]u8{ 0x21, 0xFF, 0xFF });
    try testing.expectEqual(Op.l32r, insn.op);
    try testing.expectEqual(@as(u4, 2), insn.t);
    try testing.expectEqual(@as(u32, 0x4008_000C), insn.target);
}

test "l32r reaches its full 256 KiB backwards range" {
    // imm16 = 0 -> offset = 0xFFFC0000 = -262144.
    const insn = try decodeBytes(0x4008_0000, &[_]u8{ 0x21, 0x00, 0x00 });
    try testing.expectEqual(@as(u32, 0x4008_0000 - 0x40000), insn.target);
}

// --- control flow ----------------------------------------------------------------------

test "j with a negative offset (a self-loop is j -4... at pc+4-4)" {
    // J: offset18 in bits 23:6, target = pc + 4 + offset.
    // For a branch to self at pc: offset = -4 = 0x3FFFC.
    // word = (0x3FFFC << 6) | 0x6 = 0xFFFF06, bytes 0x06, 0xFF, 0xFF
    const insn = try decodeBytes(0x4008_0100, &[_]u8{ 0x06, 0xFF, 0xFF });
    try testing.expectEqual(Op.j, insn.op);
    try testing.expectEqual(@as(u32, 0x4008_0100), insn.target);
}

test "j with a positive offset" {
    // offset = +8 -> word = (8 << 6) | 6 = 0x206, bytes 0x06, 0x02, 0x00
    const insn = try decodeBytes(0x4008_0000, &[_]u8{ 0x06, 0x02, 0x00 });
    try testing.expectEqual(@as(u32, 0x4008_000C), insn.target); // pc + 4 + 8
}

test "call0 scales its offset by four and aligns the base" {
    // offset18 = 1 -> target = (pc & ~3) + 4 + 4.
    // word = (1 << 6) | 5 = 0x45, bytes 0x45, 0x00, 0x00
    const insn = try decodeBytes(0x4008_0000, &[_]u8{ 0x45, 0x00, 0x00 });
    try testing.expectEqual(Op.call0, insn.op);
    try testing.expectEqual(@as(u32, 0x4008_0008), insn.target);

    // From an unaligned PC the base is rounded down first.
    const insn2 = try decodeBytes(0x4008_0003, &[_]u8{ 0x45, 0x00, 0x00 });
    try testing.expectEqual(@as(u32, 0x4008_0008), insn2.target);
}

test "callx0 and jx take their destination from a register" {
    // callx0 a3: r=0 s=3 t=0xC op0=0 -> word 0x0003C0, bytes 0xC0, 0x03, 0x00
    const callx = try decodeBytes(0, &[_]u8{ 0xC0, 0x03, 0x00 });
    try testing.expectEqual(Op.callx0, callx.op);
    try testing.expectEqual(@as(u4, 3), callx.s);

    // jx a5: t=0xA -> word 0x0005A0, bytes 0xA0, 0x05, 0x00
    const jx_insn = try decodeBytes(0, &[_]u8{ 0xA0, 0x05, 0x00 });
    try testing.expectEqual(Op.jx, jx_insn.op);
    try testing.expectEqual(@as(u4, 5), jx_insn.s);
}

test "beq / bne / bltu are all BRI8 with an 8-bit signed offset" {
    // beq a2, a3, +4: r=1 s=2 t=3 imm8=0 -> target = pc + 4
    const beq_insn = try decodeBytes(0x4008_0000, &[_]u8{ 0x37, 0x12, 0x00 });
    try testing.expectEqual(Op.beq, beq_insn.op);
    try testing.expectEqual(@as(u4, 2), beq_insn.s);
    try testing.expectEqual(@as(u4, 3), beq_insn.t);
    try testing.expectEqual(@as(u32, 0x4008_0004), beq_insn.target);

    // bne with imm8 = 0xF8 (-8) -> target = pc + 4 - 8 = pc - 4
    const bne_insn = try decodeBytes(0x4008_0010, &[_]u8{ 0x37, 0x92, 0xF8 });
    try testing.expectEqual(Op.bne, bne_insn.op);
    try testing.expectEqual(@as(u32, 0x4008_000C), bne_insn.target);

    // bltu: r = 3
    const bltu_insn = try decodeBytes(0, &[_]u8{ 0x37, 0x32, 0x00 });
    try testing.expectEqual(Op.bltu, bltu_insn.op);

    try testing.expectEqual(Op.blt, (try decodeBytes(0, &[_]u8{ 0x37, 0x22, 0x00 })).op);
    try testing.expectEqual(Op.bge, (try decodeBytes(0, &[_]u8{ 0x37, 0xA2, 0x00 })).op);
    try testing.expectEqual(Op.bgeu, (try decodeBytes(0, &[_]u8{ 0x37, 0xB2, 0x00 })).op);
}

test "beqz and friends use the 12-bit BRI12 offset" {
    // BZ: op0=6, n=1 (bits 5:4), m (bits 7:6) picks the condition, s = register.
    // beqz a2, +4: m=0 -> t nibble = (m<<2)|n = 0b0001 = 0x1. imm12 = 0.
    // word = (0 << 12) | (2 << 8) | (0x1 << 4) | 6 = 0x0216, bytes 0x16, 0x02, 0x00
    const beqz_insn = try decodeBytes(0x4008_0000, &[_]u8{ 0x16, 0x02, 0x00 });
    try testing.expectEqual(Op.beqz, beqz_insn.op);
    try testing.expectEqual(@as(u4, 2), beqz_insn.s);
    try testing.expectEqual(@as(u32, 0x4008_0004), beqz_insn.target);

    // bnez a2: m=1 -> t nibble = 0b0101 = 0x5.
    const bnez_insn = try decodeBytes(0, &[_]u8{ 0x56, 0x02, 0x00 });
    try testing.expectEqual(Op.bnez, bnez_insn.op);

    // bltz: m=2 -> 0x9;  bgez: m=3 -> 0xD
    try testing.expectEqual(Op.bltz, (try decodeBytes(0, &[_]u8{ 0x96, 0x02, 0x00 })).op);
    try testing.expectEqual(Op.bgez, (try decodeBytes(0, &[_]u8{ 0xD6, 0x02, 0x00 })).op);

    // A negative 12-bit offset: imm12 = 0xFFC = -4 -> target = pc + 4 - 4 = pc.
    const back = try decodeBytes(0x4008_0020, &[_]u8{ 0x16, 0xC2, 0xFF });
    try testing.expectEqual(@as(u32, 0x4008_0020), back.target);
}

// --- narrow forms ----------------------------------------------------------------------

test "l32i.n and s32i.n" {
    // l32i.n a2, a3, 4 -> op0=8, r=1 (4/4), s=3, t=2 -> 0x1328, bytes 0x28, 0x13
    const l = try decodeBytes(0, &[_]u8{ 0x28, 0x13 });
    try testing.expectEqual(Op.l32i_n, l.op);
    try testing.expectEqual(@as(u4, 2), l.t);
    try testing.expectEqual(@as(u4, 3), l.s);
    try testing.expectEqual(@as(i32, 4), l.imm);

    // s32i.n a2, a3, 60 -> op0=9, r=15
    const s = try decodeBytes(0, &[_]u8{ 0x29, 0xF3 });
    try testing.expectEqual(Op.s32i_n, s.op);
    try testing.expectEqual(@as(i32, 60), s.imm);
}

test "add.n and addi.n" {
    // add.n a2, a3, a4 -> op0=A, r=2, s=3, t=4 -> 0x234A, bytes 0x4A, 0x23
    const a = try decodeBytes(0, &[_]u8{ 0x4A, 0x23 });
    try testing.expectEqual(Op.add_n, a.op);
    try testing.expectEqual(@as(u4, 2), a.r);
    try testing.expectEqual(@as(u4, 3), a.s);
    try testing.expectEqual(@as(u4, 4), a.t);

    // addi.n a2, a3, 5 -> op0=B, r=2, s=3, t=5 -> bytes 0x5B, 0x23
    const imm5 = try decodeBytes(0, &[_]u8{ 0x5B, 0x23 });
    try testing.expectEqual(Op.addi_n, imm5.op);
    try testing.expectEqual(@as(i32, 5), imm5.imm);

    // addi.n a2, a3, -1 -> t = 0
    const im1 = try decodeBytes(0, &[_]u8{ 0x0B, 0x23 });
    try testing.expectEqual(@as(i32, -1), im1.imm);
}

test "movi.n uses an asymmetric 7-bit immediate" {
    // movi.n a2, 0 -> t[3]=0, imm7=0 -> r=0, t=0, s=2 -> 0x020C, bytes 0x0C, 0x02
    const zero = try decodeBytes(0, &[_]u8{ 0x0C, 0x02 });
    try testing.expectEqual(Op.movi_n, zero.op);
    try testing.expectEqual(@as(u4, 2), zero.s);
    try testing.expectEqual(@as(i32, 0), zero.imm);

    // imm7 = 0x5F = 95, the largest positive: t[2:0] = 5, r = 0xF.
    const max_pos = try decodeBytes(0, &[_]u8{ 0x5C, 0xF2 });
    try testing.expectEqual(@as(i32, 95), max_pos.imm);

    // imm7 = 0x7F = 127 -> -1: t[2:0] = 7, r = 0xF.
    const minus_one = try decodeBytes(0, &[_]u8{ 0x7C, 0xF2 });
    try testing.expectEqual(@as(i32, -1), minus_one.imm);

    // imm7 = 0x60 = 96 -> -32: t[2:0] = 6, r = 0.
    const min_neg = try decodeBytes(0, &[_]u8{ 0x6C, 0x02 });
    try testing.expectEqual(@as(i32, -32), min_neg.imm);
}

test "beqz.n and bnez.n branch forward only" {
    // beqz.n a2, +4 -> t = 0b1000 = 8, imm6 = 0 -> r = 0, s = 2 -> bytes 0x8C, 0x02
    const b = try decodeBytes(0x4008_0000, &[_]u8{ 0x8C, 0x02 });
    try testing.expectEqual(Op.beqz_n, b.op);
    try testing.expectEqual(@as(u4, 2), b.s);
    try testing.expectEqual(@as(u32, 0x4008_0004), b.target);

    // bnez.n with imm6 = 63: t[3:2] = 0b11, t[1:0] = 0b11 -> t = 0xF, r = 0xF.
    const n = try decodeBytes(0x4008_0000, &[_]u8{ 0xFC, 0xF2 });
    try testing.expectEqual(Op.bnez_n, n.op);
    try testing.expectEqual(@as(u32, 0x4008_0043), n.target); // pc + 4 + 63
}

test "mov.n" {
    // mov.n a2, a3 -> op0=D, r=0, s=3, t=2 -> 0x032D, bytes 0x2D, 0x03
    const m = try decodeBytes(0, &[_]u8{ 0x2D, 0x03 });
    try testing.expectEqual(Op.mov_n, m.op);
    try testing.expectEqual(@as(u4, 2), m.t);
    try testing.expectEqual(@as(u4, 3), m.s);
}

// --- refusals --------------------------------------------------------------------------

test "windowed calls are refused rather than silently mis-executed" {
    // call4: op0=5, n=1 -> bytes 0x15, 0x00, 0x00
    try testing.expectError(error.UnsupportedInstruction, decodeBytes(0, &[_]u8{ 0x15, 0x00, 0x00 }));
    // retw: m=2, n=1 -> t = 0x9 -> bytes 0x90, 0x00, 0x00
    try testing.expectError(error.UnsupportedInstruction, decodeBytes(0, &[_]u8{ 0x90, 0x00, 0x00 }));
    // callx8: m=3, n=2 -> t = 0xE -> bytes 0xE0, 0x00, 0x00
    try testing.expectError(error.UnsupportedInstruction, decodeBytes(0, &[_]u8{ 0xE0, 0x00, 0x00 }));
}

test "reserved narrow opcodes are illegal" {
    try testing.expectError(error.IllegalInstruction, decodeBytes(0, &[_]u8{ 0x0E, 0x00 }));
    try testing.expectError(error.IllegalInstruction, decodeBytes(0, &[_]u8{ 0x0F, 0x00 }));
    // ill.n: op0=D, r=F, t=6 -> bytes 0x6D, 0xF0
    try testing.expectError(error.IllegalInstruction, decodeBytes(0, &[_]u8{ 0x6D, 0xF0 }));
}
