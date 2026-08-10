//! Xtensa LX6 instruction decoder.
//!
//! Authority: Xtensa ISA Reference Manual <https://0x04.net/~mwk/doc/xtensa.pdf>,
//! chapter 7 (instruction descriptions) and the instruction-format section of chapter 3.
//! Every encoding here has been checked against `xtensa-esp-elf-objdump` output for
//! `examples/hello.elf`. `docs/PHASE1-NOTES.md` records the findings that were not
//! obvious from the manual — read it before changing anything in this file.
//!
//! Three properties of Xtensa shape the whole module:
//!
//! 1. **Variable length.** Core instructions are 24 bits. With the Code Density option,
//!    which the ESP32 has, there are also 16-bit "narrow" forms. Bit 3 of the *first
//!    byte* selects: set means 2 bytes, clear means 3. That bit is `op0`'s high bit, so
//!    `op0 >= 8` means narrow. It sits there so a fetch unit can size the instruction
//!    before decoding anything else.
//! 2. **Little-endian inside the instruction.** Bytes `b0 b1 b2` form `b0 | b1<<8 |
//!    b2<<16`. The manual numbers instruction bits from 0 = least significant and draws
//!    its field diagrams right to left, so `op0` is bits 3:0 and lives in the first byte.
//! 3. **Fields overlap.** `imm8` (23:16) covers the same bits as `op1` and `op2`; the
//!    `t` field (7:4) splits into `m` (7:6) and `n` (5:4) in the branch and call formats.
//!    [`Fields`] therefore exposes both views of the same word rather than pretending
//!    there is one layout.
//!
//! Decoding is a tree: `op0` picks a group, then `op1`, `op2`, `r`, `t` or `n` narrow it
//! down, in the same order the manual's tables do.

use core::fmt;

/// An address register index, always 0..=15.
///
/// A newtype because the raw 4-bit fields are trivially confusable with immediates, and
/// because it makes register-file indexing infallible.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Reg(u8);

impl Reg {
    pub const A0: Reg = Reg(0);
    pub const A1: Reg = Reg(1);

    pub const fn new(index: u8) -> Self {
        Reg(index & 0xF)
    }

    pub const fn index(self) -> usize {
        self.0 as usize
    }
}

impl fmt::Display for Reg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "a{}", self.0)
    }
}

impl fmt::Debug for Reg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "a{}", self.0)
    }
}

/// How a load extends its result into 32 bits.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LoadKind {
    U8,
    U16,
    I16,
    U32,
}

/// Store width. Xtensa has no sign extension on stores.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StoreKind {
    U8,
    U16,
    U32,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AluOp {
    Add,
    Sub,
    And,
    Or,
    Xor,
}

/// Register-to-register branch condition.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cond {
    Eq,
    Ne,
    /// Signed.
    Lt,
    /// Signed.
    Ge,
    Ltu,
    Geu,
}

/// Compare-against-zero branch condition. `Lt`/`Ge` are signed; equality needs no
/// signedness.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ZeroCond {
    Eq,
    Ne,
    Lt,
    Ge,
}

/// A decoded instruction.
///
/// Operands are fully resolved here: immediates are sign-extended and scaled, and
/// PC-relative destinations are absolute addresses. All the bit fiddling happens once, in
/// this module, so the executor is a flat `match` with no shifting in it.
///
/// Variants are grouped by semantics rather than one-per-mnemonic, so the executor
/// handles all five ALU operations or all six branch conditions in a single arm. The
/// exact mnemonic is recovered separately by [`Decoded::mnemonic`] for tracing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Inst {
    /// `AR[dst] <- mem[AR[base] + offset]`
    Load { kind: LoadKind, dst: Reg, base: Reg, offset: u32 },
    /// `mem[AR[base] + offset] <- AR[src]`
    Store { kind: StoreKind, src: Reg, base: Reg, offset: u32 },
    /// `AR[dst] <- mem[literal]`, where `literal` was resolved at decode time.
    L32r { dst: Reg, literal: u32 },
    Movi { dst: Reg, imm: i32 },
    /// Covers `addi`, `addmi` and `addi.n`; `imm` is already scaled.
    Addi { dst: Reg, src: Reg, imm: i32 },
    Alu { op: AluOp, dst: Reg, lhs: Reg, rhs: Reg },
    Mov { dst: Reg, src: Reg },
    Jump { target: u32 },
    JumpReg { target: Reg },
    /// `a0 <- return address; PC <- target`. Call0 ABI only: no window rotation.
    Call { target: u32 },
    CallReg { target: Reg },
    Ret,
    Branch { cond: Cond, lhs: Reg, rhs: Reg, target: u32 },
    BranchZero { cond: ZeroCond, src: Reg, target: u32 },
    /// Memory-access ordering barrier. An in-order interpreter that completes each
    /// access before starting the next already satisfies it, but firmware needs it to be
    /// *legal*.
    Memw,
    Nop,
}

/// Encoded length of an instruction. Xtensa has exactly these two.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InstSize {
    /// 16-bit, from the Code Density option.
    Narrow = 2,
    /// The 24-bit core encoding.
    Wide = 3,
}

impl InstSize {
    pub const fn bytes(self) -> u32 {
        self as u32
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Decoded {
    pub inst: Inst,
    pub size: InstSize,
}

impl Decoded {
    /// The assembler mnemonic this decoded from.
    ///
    /// [`Inst`] deliberately collapses the narrow and wide encodings of the same
    /// operation, but a trace should say which one actually executed — so the mnemonic is
    /// recovered from the variant plus the size rather than stored.
    pub fn mnemonic(&self) -> &'static str {
        let narrow = self.size == InstSize::Narrow;
        match self.inst {
            Inst::Load { kind: LoadKind::U8, .. } => "l8ui",
            Inst::Load { kind: LoadKind::U16, .. } => "l16ui",
            Inst::Load { kind: LoadKind::I16, .. } => "l16si",
            Inst::Load { kind: LoadKind::U32, .. } => {
                if narrow {
                    "l32i.n"
                } else {
                    "l32i"
                }
            }
            Inst::Store { kind: StoreKind::U8, .. } => "s8i",
            Inst::Store { kind: StoreKind::U16, .. } => "s16i",
            Inst::Store { kind: StoreKind::U32, .. } => {
                if narrow {
                    "s32i.n"
                } else {
                    "s32i"
                }
            }
            Inst::L32r { .. } => "l32r",
            Inst::Movi { .. } => {
                if narrow {
                    "movi.n"
                } else {
                    "movi"
                }
            }
            // `addmi` also decodes to Addi; it is distinguishable only by its scaled
            // immediate, which the trace shows anyway.
            Inst::Addi { .. } => {
                if narrow {
                    "addi.n"
                } else {
                    "addi"
                }
            }
            Inst::Alu { op, .. } => match op {
                AluOp::Add if narrow => "add.n",
                AluOp::Add => "add",
                AluOp::Sub => "sub",
                AluOp::And => "and",
                AluOp::Or => "or",
                AluOp::Xor => "xor",
            },
            Inst::Mov { .. } => "mov.n",
            Inst::Jump { .. } => "j",
            Inst::JumpReg { .. } => "jx",
            Inst::Call { .. } => "call0",
            Inst::CallReg { .. } => "callx0",
            Inst::Ret => {
                if narrow {
                    "ret.n"
                } else {
                    "ret"
                }
            }
            Inst::Branch { cond, .. } => match cond {
                Cond::Eq => "beq",
                Cond::Ne => "bne",
                Cond::Lt => "blt",
                Cond::Ge => "bge",
                Cond::Ltu => "bltu",
                Cond::Geu => "bgeu",
            },
            Inst::BranchZero { cond, .. } => match (cond, narrow) {
                (ZeroCond::Eq, false) => "beqz",
                (ZeroCond::Eq, true) => "beqz.n",
                (ZeroCond::Ne, false) => "bnez",
                (ZeroCond::Ne, true) => "bnez.n",
                (ZeroCond::Lt, _) => "bltz",
                (ZeroCond::Ge, _) => "bgez",
            },
            Inst::Memw => "memw",
            Inst::Nop => {
                if narrow {
                    "nop.n"
                } else {
                    "nop"
                }
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DecodeError {
    /// A reserved bit pattern: not a valid Xtensa instruction at all.
    Illegal { word: u32 },
    /// A real Xtensa instruction that Phase 1 does not implement. Distinct from
    /// `Illegal` because when a run dies, that distinction tells you immediately whether
    /// you found a bug or hit a known boundary. `what` names the missing feature.
    Unsupported { word: u32, what: &'static str },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            DecodeError::Illegal { word } => write!(f, "illegal instruction {word:#08x}"),
            DecodeError::Unsupported { word, what } => {
                write!(f, "unsupported instruction {word:#08x} ({what})")
            }
        }
    }
}

impl std::error::Error for DecodeError {}

/// How long the instruction starting with `first_byte` is.
pub const fn instruction_size(first_byte: u8) -> InstSize {
    if first_byte & 0x08 != 0 { InstSize::Narrow } else { InstSize::Wide }
}

/// The instruction word, with accessors for both the regular field layout and the
/// overlapping immediate/sub-opcode views of the same bits.
#[derive(Clone, Copy)]
struct Fields(u32);

#[rustfmt::skip]
impl Fields {
    // Regular fields, shared by most 24-bit formats and by the 16-bit RRRN layout.
    const fn op0(self) -> u8 { (self.0 & 0xF) as u8 }
    const fn t(self)   -> u8 { ((self.0 >> 4) & 0xF) as u8 }
    const fn s(self)   -> u8 { ((self.0 >> 8) & 0xF) as u8 }
    const fn r(self)   -> u8 { ((self.0 >> 12) & 0xF) as u8 }
    const fn op1(self) -> u8 { ((self.0 >> 16) & 0xF) as u8 }
    const fn op2(self) -> u8 { ((self.0 >> 20) & 0xF) as u8 }

    // Overlapping views. imm8/imm12/imm16/offset18 occupy the same bits as op1 and op2;
    // m and n are the two halves of the t field.
    const fn imm8(self)     -> u32 { (self.0 >> 16) & 0xFF }
    const fn imm12(self)    -> u32 { (self.0 >> 12) & 0xFFF }
    const fn imm16(self)    -> u32 { (self.0 >> 8) & 0xFFFF }
    const fn offset18(self) -> u32 { (self.0 >> 6) & 0x3_FFFF }
    const fn m(self)        -> u8  { ((self.0 >> 6) & 0x3) as u8 }
    const fn n(self)        -> u8  { ((self.0 >> 4) & 0x3) as u8 }

    const fn reg_t(self) -> Reg { Reg::new(self.t()) }
    const fn reg_s(self) -> Reg { Reg::new(self.s()) }
    const fn reg_r(self) -> Reg { Reg::new(self.r()) }
}

/// Sign-extend the low `bits` bits of `value`.
const fn sign_extend(value: u32, bits: u32) -> i32 {
    let shift = 32 - bits;
    ((value << shift) as i32) >> shift
}

/// Decode one instruction.
///
/// `pc` is this instruction's address; several Xtensa instructions are PC-relative and
/// are resolved to absolute addresses here. `word` holds the instruction bytes assembled
/// little-endian (`b0 | b1<<8 | b2<<16`), and `size` must come from
/// [`instruction_size`].
pub fn decode(pc: u32, word: u32, size: InstSize) -> Result<Decoded, DecodeError> {
    let inst = match size {
        InstSize::Wide => decode24(pc, word)?,
        InstSize::Narrow => decode16(pc, word)?,
    };
    Ok(Decoded { inst, size })
}

fn decode24(pc: u32, word: u32) -> Result<Inst, DecodeError> {
    let f = Fields(word);
    match f.op0() {
        0x0 => decode_qrst(word, f),
        0x1 => Ok(decode_l32r(pc, f)),
        0x2 => decode_lsai(word, f),
        0x5 => decode_call(pc, word, f),
        0x6 => decode_si(pc, word, f),
        0x7 => decode_b(pc, word, f),
        // 0x3 is LSCI (coprocessor loads), 0x4 is the extended-opcode escape.
        _ => Err(unsupported(word, "opcode group not implemented in phase 1")),
    }
}

/// `op0 = 0`: the QRST group, which holds all register-register operations. `op1` picks
/// a sub-table; Phase 1 only needs RST0.
fn decode_qrst(word: u32, f: Fields) -> Result<Inst, DecodeError> {
    if f.op1() != 0x0 {
        // op1 1..3 are shifts, extui, multiplies and special-register moves; 4..F are
        // floating point, MAC16 and the indexed load/store forms.
        return Err(unsupported(word, "shift/multiply/special-register group"));
    }

    let alu = |op| {
        Ok(Inst::Alu { op, dst: f.reg_r(), lhs: f.reg_s(), rhs: f.reg_t() })
    };

    match f.op2() {
        0x0 => decode_st0(word, f),
        0x1 => alu(AluOp::And),
        0x2 => alu(AluOp::Or),
        0x3 => alu(AluOp::Xor),
        0x8 => alu(AluOp::Add),
        0xC => alu(AluOp::Sub),
        // 0x9..0xB are ADDX2/4/8, 0xD..0xF SUBX2/4/8, 0x4..0x7 ST1/TLB/RT0.
        _ => Err(unsupported(word, "RST0 sub-opcode")),
    }
}

/// `op0 = 0, op1 = 0, op2 = 0`: the ST0 table, selected by `r`.
fn decode_st0(word: u32, f: Fields) -> Result<Inst, DecodeError> {
    match f.r() {
        0x0 => decode_snm0(word, f),
        0x2 => decode_sync(word, f),
        // 0x1 MOVSP, 0x3 RFEI, 0x4 BREAK, 0x5 SYSCALL, 0x6 RSIL, 0x7 WAITI,
        // 0x8..0xB the boolean ANY/ALL operations.
        _ => Err(unsupported(word, "ST0 sub-opcode")),
    }
}

/// ST0 with `r = 0`: indirect jumps and calls. Here `t` splits into `m = t[3:2]` and
/// `n = t[1:0]`:
///
/// ```text
/// m = 0  ILL           the canonical illegal instruction, 0x000000
/// m = 2  JR family     n = 0 RET, 1 RETW, 2 JX
/// m = 3  CALLX family  n = 0 CALLX0, 1 CALLX4, 2 CALLX8, 3 CALLX12
/// ```
fn decode_snm0(word: u32, f: Fields) -> Result<Inst, DecodeError> {
    let m = (f.t() >> 2) & 0x3;
    let n = f.t() & 0x3;

    match (m, n) {
        (0, _) => Err(DecodeError::Illegal { word }),
        (2, 0) => Ok(Inst::Ret),
        (2, 2) => Ok(Inst::JumpReg { target: f.reg_s() }),
        (2, 1) => Err(unsupported(word, "retw: requires register windows")),
        (3, 0) => Ok(Inst::CallReg { target: f.reg_s() }),
        (3, _) => Err(unsupported(word, "callx4/8/12: requires register windows")),
        _ => Err(DecodeError::Illegal { word }),
    }
}

/// ST0 with `r = 2`: the memory and pipeline barriers, selected by `t`.
fn decode_sync(word: u32, f: Fields) -> Result<Inst, DecodeError> {
    match f.t() {
        0xC => Ok(Inst::Memw),
        0xF => Ok(Inst::Nop),
        // ISYNC, RSYNC, ESYNC, DSYNC, EXCW, EXTW. All would be no-ops in an in-order
        // interpreter with no caches, but Phase 1 refuses instructions it has not
        // thought about rather than silently accepting them.
        _ => Err(unsupported(word, "sync/barrier variant")),
    }
}

/// `op0 = 1`: L32R, the PC-relative literal load.
///
/// Xtensa has no "load a 32-bit constant" instruction — MOVI reaches 12 bits — so
/// compilers park constants in a *literal pool* and fetch them with L32R. Two
/// consequences:
///
/// * The 16-bit field is OR-ed into `0xFFFC0000`, so the offset is always negative:
///   reachable range `PC-262144 ..= PC-4`. Literals always precede their use.
/// * The base is `(PC + 3) & !3` — the address after the instruction, rounded down to a
///   word. This matches binutils' `Operand_uimm16x4_ator`, and objdump on
///   `examples/hello.elf` settles it: the `l32r` at 0x4008000B (so `pc & 3 == 3`) encodes
///   offset -8 and resolves to 0x40080004. Using `PC & !3` would give 0x40080000 and load
///   the wrong literal. See `docs/PHASE1-NOTES.md`.
fn decode_l32r(pc: u32, f: Fields) -> Inst {
    let offset = 0xFFFC_0000 | (f.imm16() << 2);
    let base = pc.wrapping_add(3) & !3;
    Inst::L32r { dst: f.reg_t(), literal: base.wrapping_add(offset) }
}

/// `op0 = 2`: the LSAI group — loads, stores, and the immediate arithmetic that shares
/// the RRI8 format with them, selected by `r`.
///
/// Load and store offsets are *unsigned* and scaled by the access width, so they reach
/// forward only: `l32i` 0..=1020, `l16ui` 0..=510, `l8ui` 0..=255.
fn decode_lsai(word: u32, f: Fields) -> Result<Inst, DecodeError> {
    let imm8 = f.imm8();

    let load = |kind, scale: u32| Inst::Load {
        kind,
        dst: f.reg_t(),
        base: f.reg_s(),
        offset: imm8 * scale,
    };
    let store = |kind, scale: u32| Inst::Store {
        kind,
        src: f.reg_t(),
        base: f.reg_s(),
        offset: imm8 * scale,
    };

    match f.r() {
        0x0 => Ok(load(LoadKind::U8, 1)),
        0x1 => Ok(load(LoadKind::U16, 2)),
        0x2 => Ok(load(LoadKind::U32, 4)),
        0x4 => Ok(store(StoreKind::U8, 1)),
        0x5 => Ok(store(StoreKind::U16, 2)),
        0x6 => Ok(store(StoreKind::U32, 4)),
        0x9 => Ok(load(LoadKind::I16, 2)),
        // MOVI borrows the `s` field for the top 4 bits of a 12-bit signed immediate, so
        // it has no base register.
        0xA => Ok(Inst::Movi {
            dst: f.reg_t(),
            imm: sign_extend((u32::from(f.s()) << 8) | imm8, 12),
        }),
        0xC => Ok(Inst::Addi {
            dst: f.reg_t(),
            src: f.reg_s(),
            imm: sign_extend(imm8, 8),
        }),
        // ADDMI scales its sign-extended 8-bit value by 256 — the "medium immediate"
        // used for stack frame offsets beyond ADDI's reach.
        0xD => Ok(Inst::Addi {
            dst: f.reg_t(),
            src: f.reg_s(),
            imm: sign_extend(imm8, 8) * 256,
        }),
        // 0x3 and 0x8 reserved, 0x7 CACHE, 0xB L32AI, 0xE S32C1I, 0xF S32RI.
        0x3 | 0x8 => Err(DecodeError::Illegal { word }),
        _ => Err(unsupported(word, "cache/atomic load-store variant")),
    }
}

/// `op0 = 5`: the CALL group. Bits 5:4 pick the window increment; only CALL0 rotates no
/// window. The 18-bit offset is scaled by 4 and relative to the word-aligned PC, so call
/// targets are always 4-byte aligned — unlike J, whose offset is in bytes.
fn decode_call(pc: u32, word: u32, f: Fields) -> Result<Inst, DecodeError> {
    if f.n() != 0 {
        return Err(unsupported(word, "call4/8/12: requires register windows"));
    }
    let byte_offset = sign_extend(f.offset18(), 18) * 4;
    let target = (pc & !3).wrapping_add(4).wrapping_add(byte_offset as u32);
    Ok(Inst::Call { target })
}

/// `op0 = 6`: the SI group — jump and the compare-against-zero branches. Bits 5:4 (`n`)
/// select the sub-group.
fn decode_si(pc: u32, word: u32, f: Fields) -> Result<Inst, DecodeError> {
    match f.n() {
        // J: an 18-bit *byte* offset relative to PC + 4. Not scaled, unlike CALL0.
        0 => {
            let offset = sign_extend(f.offset18(), 18);
            Ok(Inst::Jump { target: pc.wrapping_add(4).wrapping_add(offset as u32) })
        }
        // BZ, in BRI12 format: imm12 is bits 23:12 and `m` picks the condition.
        1 => {
            let cond = match f.m() {
                0 => ZeroCond::Eq,
                1 => ZeroCond::Ne,
                2 => ZeroCond::Lt,
                _ => ZeroCond::Ge,
            };
            let offset = sign_extend(f.imm12(), 12);
            Ok(Inst::BranchZero {
                cond,
                src: f.reg_s(),
                target: pc.wrapping_add(4).wrapping_add(offset as u32),
            })
        }
        // BI0 (BEQI/BNEI/BLTI/BGEI) and BI1 (ENTRY/BF/BT/BLTUI/BGEUI) encode their
        // comparison constant through the B4CONST/B4CONSTU lookup tables. Phase 1 does
        // not need them, and guessing those tables would be worse than refusing.
        _ => Err(unsupported(word, "immediate-compare branch (B4CONST tables)")),
    }
}

/// `op0 = 7`: register-to-register conditional branches in BRI8 format. The 8-bit offset
/// is signed and relative to PC + 4, so the reach is -128..=127 bytes.
fn decode_b(pc: u32, word: u32, f: Fields) -> Result<Inst, DecodeError> {
    let cond = match f.r() {
        0x1 => Cond::Eq,
        0x2 => Cond::Lt,
        0x3 => Cond::Ltu,
        0x9 => Cond::Ne,
        0xA => Cond::Ge,
        0xB => Cond::Geu,
        // 0x0 BNONE, 0x4 BALL, 0x5 BBC, 0x6/0x7 BBCI, 0x8 BANY, 0xC BNALL,
        // 0xD BBS, 0xE/0xF BBSI: the bit-test branches.
        _ => return Err(unsupported(word, "bit-test branch")),
    };
    let offset = sign_extend(f.imm8(), 8);
    Ok(Inst::Branch {
        cond,
        lhs: f.reg_s(),
        rhs: f.reg_t(),
        target: pc.wrapping_add(4).wrapping_add(offset as u32),
    })
}

/// The 16-bit narrow forms (the Code Density option). `op0` 0x8..=0xD; 0xE and 0xF are
/// reserved in the LX6 core ISA.
fn decode16(pc: u32, word: u32) -> Result<Inst, DecodeError> {
    let f = Fields(word);
    match f.op0() {
        // L32I.N / S32I.N: address = AR[s] + r*4, reaching 0..=60. That covers most
        // stack-frame accesses, which is why the narrow form pays off.
        0x8 => Ok(Inst::Load {
            kind: LoadKind::U32,
            dst: f.reg_t(),
            base: f.reg_s(),
            offset: u32::from(f.r()) * 4,
        }),
        0x9 => Ok(Inst::Store {
            kind: StoreKind::U32,
            src: f.reg_t(),
            base: f.reg_s(),
            offset: u32::from(f.r()) * 4,
        }),
        0xA => Ok(Inst::Alu {
            op: AluOp::Add,
            dst: f.reg_r(),
            lhs: f.reg_s(),
            rhs: f.reg_t(),
        }),
        // ADDI.N: the `t` field encodes 1..=15 directly, and 0 means -1. There is no
        // "add zero" narrow form because that is what MOV.N is for.
        0xB => Ok(Inst::Addi {
            dst: f.reg_r(),
            src: f.reg_s(),
            imm: if f.t() == 0 { -1 } else { i32::from(f.t()) },
        }),
        0xC => Ok(decode_st2(pc, f)),
        0xD => decode_st3(word, f),
        _ => Err(DecodeError::Illegal { word }),
    }
}

/// `op0 = 0xC` (ST2). Bit 3 of `t` splits the table:
/// `t[3] = 0` is MOVI.N, `t[3] = 1` is BEQZ.N (`t[2] = 0`) or BNEZ.N (`t[2] = 1`).
fn decode_st2(pc: u32, f: Fields) -> Inst {
    if f.t() & 0x8 == 0 {
        // MOVI.N covers -32..=95 from a 7-bit field, encoded asymmetrically: 0..=95 hold
        // non-negative values and 96..=127 hold -32..=-1. It is *not* a sign-extended
        // 7-bit field — small positive constants are far more common, and this buys 32
        // extra of them. The 7 bits are split t[2:0]:r, and the destination is `s`,
        // unlike every other move. Confirmed against objdump: GCC emits 0x550c for
        // `movi.n a5, 5`.
        let imm7 = (u32::from(f.t() & 0x7) << 4) | u32::from(f.r());
        let imm = if imm7 >= 96 { imm7 as i32 - 128 } else { imm7 as i32 };
        return Inst::Movi { dst: f.reg_s(), imm };
    }

    // BEQZ.N / BNEZ.N: a 6-bit *unsigned* offset relative to PC + 4, so they branch
    // forward only, reaching 4..=67 bytes ahead. Backwards loops need the 24-bit form.
    let imm6 = (u32::from(f.t() & 0x3) << 4) | u32::from(f.r());
    let cond = if f.t() & 0x4 == 0 { ZeroCond::Eq } else { ZeroCond::Ne };
    Inst::BranchZero { cond, src: f.reg_s(), target: pc.wrapping_add(4).wrapping_add(imm6) }
}

/// `op0 = 0xD` (ST3), selected by `r`.
fn decode_st3(word: u32, f: Fields) -> Result<Inst, DecodeError> {
    match f.r() {
        0x0 => Ok(Inst::Mov { dst: f.reg_t(), src: f.reg_s() }),
        0xF => match f.t() {
            0x0 => Ok(Inst::Ret),
            0x3 => Ok(Inst::Nop),
            0x6 => Err(DecodeError::Illegal { word }), // ILL.N
            0x1 => Err(unsupported(word, "retw.n: requires register windows")),
            _ => Err(unsupported(word, "break.n / debug instruction")),
        },
        _ => Err(unsupported(word, "ST3 sub-opcode")),
    }
}

const fn unsupported(word: u32, what: &'static str) -> DecodeError {
    DecodeError::Unsupported { word, what }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Decode from the byte sequence you would see in a hex dump, so every expectation
    /// below can be checked directly against `xtensa-esp-elf-objdump -d`.
    fn decode_bytes(pc: u32, bytes: &[u8]) -> Result<Decoded, DecodeError> {
        let size = instruction_size(bytes[0]);
        let word = bytes
            .iter()
            .take(size.bytes() as usize)
            .enumerate()
            .fold(0u32, |acc, (i, &b)| acc | (u32::from(b) << (i * 8)));
        decode(pc, word, size)
    }

    fn inst(pc: u32, bytes: &[u8]) -> Inst {
        decode_bytes(pc, bytes).unwrap().inst
    }

    const A2: Reg = Reg::new(2);
    const A3: Reg = Reg::new(3);
    const A4: Reg = Reg::new(4);
    const A5: Reg = Reg::new(5);

    #[test]
    fn instruction_size_comes_from_bit_3_of_the_first_byte() {
        assert_eq!(instruction_size(0x00), InstSize::Wide); // op0 = 0
        assert_eq!(instruction_size(0x32), InstSize::Wide); // op0 = 2
        assert_eq!(instruction_size(0x07), InstSize::Wide); // op0 = 7
        assert_eq!(instruction_size(0x0D), InstSize::Narrow); // op0 = D
        assert_eq!(instruction_size(0x2B), InstSize::Narrow); // op0 = B
    }

    #[test]
    fn sign_extension() {
        assert_eq!(sign_extend(0x7F, 8), 127);
        assert_eq!(sign_extend(0xFF, 8), -1);
        assert_eq!(sign_extend(0x80, 8), -128);
        assert_eq!(sign_extend(0x7FF, 12), 2047);
        assert_eq!(sign_extend(0x800, 12), -2048);
        assert_eq!(sign_extend(0x3FFFF, 18), -1);
    }

    // --- no-operand instructions ---------------------------------------------------

    #[test]
    fn ret_is_0x000080_and_the_all_zero_word_is_illegal() {
        assert_eq!(inst(0, &[0x80, 0x00, 0x00]), Inst::Ret);
        assert_eq!(
            decode_bytes(0, &[0x00, 0x00, 0x00]),
            Err(DecodeError::Illegal { word: 0 })
        );
    }

    #[test]
    fn memw_and_nop() {
        assert_eq!(inst(0, &[0xC0, 0x20, 0x00]), Inst::Memw);
        assert_eq!(inst(0, &[0xF0, 0x20, 0x00]), Inst::Nop);
    }

    #[test]
    fn narrow_ret_and_nop() {
        // ret.n = 0xF00D, nop.n = 0xF03D.
        let r = decode_bytes(0, &[0x0D, 0xF0]).unwrap();
        assert_eq!(r.inst, Inst::Ret);
        assert_eq!(r.size, InstSize::Narrow);
        assert_eq!(r.mnemonic(), "ret.n");

        assert_eq!(inst(0, &[0x3D, 0xF0]), Inst::Nop);
    }

    // --- register-register ALU ------------------------------------------------------

    #[test]
    fn add_and_sub_write_the_r_field() {
        // add a3, a4, a5: op2=8 r=3 s=4 t=5 -> word 0x803450
        assert_eq!(
            inst(0, &[0x50, 0x34, 0x80]),
            Inst::Alu { op: AluOp::Add, dst: A3, lhs: A4, rhs: A5 }
        );
        // sub a1, a2, a3: op2=C -> word 0xC01230
        assert_eq!(
            inst(0, &[0x30, 0x12, 0xC0]),
            Inst::Alu { op: AluOp::Sub, dst: Reg::A1, lhs: A2, rhs: A3 }
        );
    }

    #[test]
    fn bitwise_ops_share_the_rst0_table() {
        for (op2, op) in [(0x10, AluOp::And), (0x20, AluOp::Or), (0x30, AluOp::Xor)] {
            assert_eq!(
                inst(0, &[0x30, 0x12, op2]),
                Inst::Alu { op, dst: Reg::A1, lhs: A2, rhs: A3 }
            );
        }
    }

    // --- loads, stores, immediates --------------------------------------------------

    #[test]
    fn l32i_scales_its_offset_by_four() {
        // l32i a2, a3, 8: r=2 s=3 t=2 imm8=2
        assert_eq!(
            inst(0, &[0x22, 0x23, 0x02]),
            Inst::Load { kind: LoadKind::U32, dst: A2, base: A3, offset: 8 }
        );
    }

    #[test]
    fn s32i_reaches_1020_bytes() {
        // s32i a4, a5, 1020: r=6 s=5 t=4 imm8=255
        assert_eq!(
            inst(0, &[0x42, 0x65, 0xFF]),
            Inst::Store { kind: StoreKind::U32, src: A4, base: A5, offset: 1020 }
        );
    }

    #[test]
    fn narrower_accesses_scale_differently() {
        assert_eq!(
            inst(0, &[0x22, 0x03, 0x05]),
            Inst::Load { kind: LoadKind::U8, dst: A2, base: A3, offset: 5 }
        );
        assert_eq!(
            inst(0, &[0x22, 0x13, 0x05]),
            Inst::Load { kind: LoadKind::U16, dst: A2, base: A3, offset: 10 }
        );
        assert_eq!(
            inst(0, &[0x22, 0x93, 0x05]),
            Inst::Load { kind: LoadKind::I16, dst: A2, base: A3, offset: 10 }
        );
        assert_eq!(
            inst(0, &[0x22, 0x43, 0x05]),
            Inst::Store { kind: StoreKind::U8, src: A2, base: A3, offset: 5 }
        );
    }

    #[test]
    fn movi_packs_its_immediate_across_two_fields() {
        // movi a2, 0x123: r=A, s=1 (imm bits 11:8), imm8=0x23
        assert_eq!(inst(0, &[0x22, 0xA1, 0x23]), Inst::Movi { dst: A2, imm: 0x123 });
        // movi a2, -1: imm12 = 0xFFF
        assert_eq!(inst(0, &[0x22, 0xAF, 0xFF]), Inst::Movi { dst: A2, imm: -1 });
    }

    #[test]
    fn addi_and_addmi() {
        assert_eq!(
            inst(0, &[0x22, 0xC3, 0xFF]),
            Inst::Addi { dst: A2, src: A3, imm: -1 }
        );
        // addmi scales by 256.
        assert_eq!(
            inst(0, &[0x22, 0xD3, 0xFF]),
            Inst::Addi { dst: A2, src: A3, imm: -256 }
        );
    }

    // --- l32r ------------------------------------------------------------------------

    #[test]
    fn l32r_resolves_backwards_to_an_absolute_address() {
        // imm16 = 0xFFFF -> offset -4. At pc 0x40080010 the base is 0x40080010.
        assert_eq!(
            inst(0x4008_0010, &[0x21, 0xFF, 0xFF]),
            Inst::L32r { dst: A2, literal: 0x4008_000C }
        );
        // imm16 = 0 -> offset -262144, the full backwards reach.
        assert_eq!(
            inst(0x4008_0000, &[0x21, 0x00, 0x00]),
            Inst::L32r { dst: A2, literal: 0x4008_0000 - 0x40000 }
        );
    }

    #[test]
    fn l32r_base_is_pc_plus_three_rounded_down() {
        // The case that distinguishes (PC+3)&!3 from PC&!3, taken verbatim from objdump
        // on examples/hello.elf:
        //     40080008: fffe31   l32r a3, 40080000
        //     4008000b: fffe41   l32r a4, 40080004
        assert_eq!(
            inst(0x4008_0008, &[0x31, 0xFE, 0xFF]),
            Inst::L32r { dst: A3, literal: 0x4008_0000 }
        );
        assert_eq!(
            inst(0x4008_000B, &[0x41, 0xFE, 0xFF]),
            Inst::L32r { dst: A4, literal: 0x4008_0004 }
        );
    }

    // --- control flow ----------------------------------------------------------------

    #[test]
    fn j_offsets_are_bytes_relative_to_pc_plus_four() {
        // offset -4 -> a branch to self, which is how firmware signals it is done.
        assert_eq!(
            inst(0x4008_0100, &[0x06, 0xFF, 0xFF]),
            Inst::Jump { target: 0x4008_0100 }
        );
        // offset +8
        assert_eq!(
            inst(0x4008_0000, &[0x06, 0x02, 0x00]),
            Inst::Jump { target: 0x4008_000C }
        );
    }

    #[test]
    fn call0_scales_its_offset_by_four_and_aligns_the_base() {
        // offset18 = 1 -> (pc & !3) + 4 + 4
        assert_eq!(inst(0x4008_0000, &[0x45, 0x00, 0x00]), Inst::Call { target: 0x4008_0008 });
        // From an unaligned PC the base is rounded down first, so the target is unchanged.
        assert_eq!(inst(0x4008_0003, &[0x45, 0x00, 0x00]), Inst::Call { target: 0x4008_0008 });
    }

    #[test]
    fn indirect_jump_and_call_take_a_register() {
        assert_eq!(inst(0, &[0xC0, 0x03, 0x00]), Inst::CallReg { target: A3 });
        assert_eq!(inst(0, &[0xA0, 0x05, 0x00]), Inst::JumpReg { target: A5 });
    }

    #[test]
    fn register_compare_branches_are_bri8() {
        assert_eq!(
            inst(0x4008_0000, &[0x37, 0x12, 0x00]),
            Inst::Branch { cond: Cond::Eq, lhs: A2, rhs: A3, target: 0x4008_0004 }
        );
        // imm8 = 0xF8 -> -8, so the target is pc + 4 - 8.
        assert_eq!(
            inst(0x4008_0010, &[0x37, 0x92, 0xF8]),
            Inst::Branch { cond: Cond::Ne, lhs: A2, rhs: A3, target: 0x4008_000C }
        );

        for (byte1, cond) in [
            (0x22, Cond::Lt),
            (0x32, Cond::Ltu),
            (0xA2, Cond::Ge),
            (0xB2, Cond::Geu),
        ] {
            assert!(matches!(
                inst(0, &[0x37, byte1, 0x00]),
                Inst::Branch { cond: c, .. } if c == cond
            ));
        }
    }

    #[test]
    fn compare_against_zero_branches_use_the_12_bit_bri12_offset() {
        // The t nibble is (m << 2) | n, with n = 1 selecting the BZ group.
        assert_eq!(
            inst(0x4008_0000, &[0x16, 0x02, 0x00]),
            Inst::BranchZero { cond: ZeroCond::Eq, src: A2, target: 0x4008_0004 }
        );
        for (byte0, cond) in [
            (0x56, ZeroCond::Ne),
            (0x96, ZeroCond::Lt),
            (0xD6, ZeroCond::Ge),
        ] {
            assert!(matches!(
                inst(0, &[byte0, 0x02, 0x00]),
                Inst::BranchZero { cond: c, .. } if c == cond
            ));
        }
        // imm12 = 0xFFC -> -4, so the target is the instruction itself.
        assert_eq!(
            inst(0x4008_0020, &[0x16, 0xC2, 0xFF]),
            Inst::BranchZero { cond: ZeroCond::Eq, src: A2, target: 0x4008_0020 }
        );
    }

    // --- narrow forms -----------------------------------------------------------------

    #[test]
    fn narrow_loads_and_stores() {
        assert_eq!(
            inst(0, &[0x28, 0x13]),
            Inst::Load { kind: LoadKind::U32, dst: A2, base: A3, offset: 4 }
        );
        assert_eq!(
            inst(0, &[0x29, 0xF3]),
            Inst::Store { kind: StoreKind::U32, src: A2, base: A3, offset: 60 }
        );
    }

    #[test]
    fn narrow_add_and_addi() {
        assert_eq!(
            inst(0, &[0x4A, 0x23]),
            Inst::Alu { op: AluOp::Add, dst: A2, lhs: A3, rhs: A4 }
        );
        assert_eq!(inst(0, &[0x5B, 0x23]), Inst::Addi { dst: A2, src: A3, imm: 5 });
        // t = 0 encodes -1, not 0.
        assert_eq!(inst(0, &[0x0B, 0x23]), Inst::Addi { dst: A2, src: A3, imm: -1 });
    }

    #[test]
    fn movi_n_uses_an_asymmetric_seven_bit_immediate() {
        assert_eq!(inst(0, &[0x0C, 0x02]), Inst::Movi { dst: A2, imm: 0 });
        // imm7 = 0x5F = 95, the largest positive.
        assert_eq!(inst(0, &[0x5C, 0xF2]), Inst::Movi { dst: A2, imm: 95 });
        // imm7 = 0x7F -> -1, and imm7 = 0x60 -> -32.
        assert_eq!(inst(0, &[0x7C, 0xF2]), Inst::Movi { dst: A2, imm: -1 });
        assert_eq!(inst(0, &[0x6C, 0x02]), Inst::Movi { dst: A2, imm: -32 });
        // The encoding GCC actually emitted for `movi.n a5, 5` in examples/hello.elf.
        assert_eq!(inst(0, &[0x0C, 0x55]), Inst::Movi { dst: A5, imm: 5 });
    }

    #[test]
    fn narrow_branches_go_forward_only() {
        assert_eq!(
            inst(0x4008_0000, &[0x8C, 0x02]),
            Inst::BranchZero { cond: ZeroCond::Eq, src: A2, target: 0x4008_0004 }
        );
        // imm6 = 63, the maximum forward reach.
        assert_eq!(
            inst(0x4008_0000, &[0xFC, 0xF2]),
            Inst::BranchZero { cond: ZeroCond::Ne, src: A2, target: 0x4008_0043 }
        );
    }

    #[test]
    fn mov_n() {
        assert_eq!(inst(0, &[0x2D, 0x03]), Inst::Mov { dst: A2, src: A3 });
    }

    // --- refusals ----------------------------------------------------------------------

    #[test]
    fn windowed_calls_are_refused_rather_than_mis_executed() {
        for bytes in [
            [0x15u8, 0x00, 0x00], // call4
            [0x90, 0x00, 0x00],   // retw
            [0xE0, 0x00, 0x00],   // callx8
        ] {
            assert!(matches!(
                decode_bytes(0, &bytes),
                Err(DecodeError::Unsupported { .. })
            ));
        }
    }

    #[test]
    fn reserved_narrow_opcodes_are_illegal() {
        assert!(matches!(decode_bytes(0, &[0x0E, 0x00]), Err(DecodeError::Illegal { .. })));
        assert!(matches!(decode_bytes(0, &[0x0F, 0x00]), Err(DecodeError::Illegal { .. })));
        // ill.n
        assert!(matches!(decode_bytes(0, &[0x6D, 0xF0]), Err(DecodeError::Illegal { .. })));
    }

    #[test]
    fn mnemonics_distinguish_narrow_from_wide() {
        assert_eq!(decode_bytes(0, &[0x22, 0x23, 0x02]).unwrap().mnemonic(), "l32i");
        assert_eq!(decode_bytes(0, &[0x28, 0x13]).unwrap().mnemonic(), "l32i.n");
        assert_eq!(decode_bytes(0, &[0x42, 0x65, 0xFF]).unwrap().mnemonic(), "s32i");
        assert_eq!(decode_bytes(0, &[0x29, 0xF3]).unwrap().mnemonic(), "s32i.n");
        assert_eq!(decode_bytes(0, &[0x22, 0xA1, 0x23]).unwrap().mnemonic(), "movi");
        assert_eq!(decode_bytes(0, &[0x0C, 0x55]).unwrap().mnemonic(), "movi.n");
        assert_eq!(decode_bytes(0, &[0x50, 0x34, 0x80]).unwrap().mnemonic(), "add");
        assert_eq!(decode_bytes(0, &[0x4A, 0x23]).unwrap().mnemonic(), "add.n");
        assert_eq!(decode_bytes(0, &[0x22, 0xC3, 0xFF]).unwrap().mnemonic(), "addi");
        assert_eq!(decode_bytes(0, &[0x5B, 0x23]).unwrap().mnemonic(), "addi.n");
        assert_eq!(decode_bytes(0, &[0x16, 0x02, 0x00]).unwrap().mnemonic(), "beqz");
        assert_eq!(decode_bytes(0, &[0x8C, 0x02]).unwrap().mnemonic(), "beqz.n");
    }
}
