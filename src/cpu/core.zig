//! The Xtensa LX6 execution core: fetch, decode, execute, repeat.
//!
//! Phase 1 models the *call0 ABI* only. That means:
//!
//!   * 16 address registers a0..a15, all general purpose, none hardwired to zero.
//!     a0 holds the return address, a1 is the stack pointer, a2..a7 are arguments and
//!     return values — but those are software conventions, not hardware rules.
//!   * No register windows. Real Xtensa has a rotating 64-entry physical register file
//!     that CALL4/CALL8/CALL12 rotate through; the decoder refuses those instructions
//!     rather than pretending. Windows are the first job of Phase 2.
//!   * No special registers (SAR, LBEG/LEND, PS, EPC...), no exceptions, no interrupts.
//!
//! ## How a run ends
//!
//! There is no operating system to return to, so we need explicit stopping rules:
//!
//!   1. `halt_address` — before the first instruction we set a0 to this magic address.
//!      When the entry function executes `ret`, the PC lands on it and we stop. This is
//!      the normal, clean exit.
//!   2. A jump or taken branch to itself — `j .` or `1: b 1b`. Firmware "spins forever"
//!      when it is done; we treat arriving at a fixed point as completion.
//!   3. Step budget exhausted — the safety net against a runaway program.
//!   4. Any decode or bus error — the program did something we cannot model.

const std = @import("std");
const decode = @import("decode.zig");
const Bus = @import("../mem/bus.zig").Bus;
const Tracer = @import("../trace.zig").Tracer;

/// The sentinel return address placed in a0 before the first instruction. It is outside
/// every mapped region, so if it is ever *executed* rather than detected the bus would
/// have caught it anyway. Low bits are zero so it cannot be confused with a real PC.
pub const halt_address: u32 = 0xDEAD_BEE0;

pub const HaltReason = enum {
    /// Not halted; only seen while a run is in progress.
    running,
    /// `ret` returned to `halt_address`: the entry function finished.
    returned,
    /// A jump or taken branch whose destination is itself.
    spin_loop,
    /// The step budget ran out.
    step_budget_exhausted,
    /// The decoder rejected the instruction.
    illegal_instruction,
    /// The decoder recognised a real instruction that Phase 1 does not implement.
    unsupported_instruction,
    /// A load, store or instruction fetch failed on the bus.
    bus_error,
};

pub const Cpu = struct {
    /// The 16 visible address registers. `a[0]` is a0, and so on.
    a: [16]u32 = [_]u32{0} ** 16,

    /// Program counter: the address of the *next* instruction to execute.
    pc: u32 = 0,

    /// Instructions retired so far.
    steps: u64 = 0,

    halt_reason: HaltReason = .running,

    /// Set when the run stopped because of an error, so the caller can report which one.
    /// `?anyerror` is an *optional*: either null or an error value. Zig has no null
    /// pointers; optionality is part of the type and the compiler makes you unwrap it.
    fault: ?anyerror = null,

    /// Prepare the core to execute from `entry`. `stack_pointer` becomes a1: the call0 ABI
    /// expects a valid downward-growing stack even in a program that never calls anything.
    pub fn reset(self: *Cpu, entry: u32, stack_pointer: u32) void {
        self.* = .{};
        self.pc = entry;
        self.a[0] = halt_address;
        self.a[1] = stack_pointer;
    }

    pub fn halted(self: *const Cpu) bool {
        return self.halt_reason != .running;
    }

    // -----------------------------------------------------------------------------------
    // The run loop
    // -----------------------------------------------------------------------------------

    /// Execute up to `max_steps` instructions, or until a halt condition fires.
    ///
    /// `tracer` is an optional pointer: pass null for a silent run, or a `*Tracer` to get
    /// one JSON line per instruction. The `if (tracer) |t|` form below unwraps the
    /// optional and binds the non-null pointer to `t` — Zig's way of making "check for
    /// null before use" impossible to forget.
    pub fn run(self: *Cpu, bus: *Bus, max_steps: u64, tracer: ?*Tracer) void {
        while (!self.halted()) {
            if (self.steps >= max_steps) {
                self.halt_reason = .step_budget_exhausted;
                return;
            }
            self.stepOnce(bus, tracer);
        }
    }

    /// Fetch, decode and execute exactly one instruction, updating `halt_reason` if the
    /// run should stop. Errors are recorded on the Cpu rather than returned, so the run
    /// loop stays a plain `while`.
    pub fn stepOnce(self: *Cpu, bus: *Bus, tracer: ?*Tracer) void {
        if (self.pc == halt_address) {
            self.halt_reason = .returned;
            return;
        }

        const pc = self.pc;

        const fetched = fetch(bus, pc) catch |err| {
            self.fault = err;
            self.halt_reason = .bus_error;
            return;
        };

        const insn = decode.decode(pc, fetched.raw, fetched.length) catch |err| {
            self.fault = err;
            self.halt_reason = switch (err) {
                error.IllegalInstruction => .illegal_instruction,
                error.UnsupportedInstruction => .unsupported_instruction,
            };
            return;
        };

        // Trace before executing, but report the register file *after* — the line then
        // shows the effect of the instruction it names, which is what you want when
        // reading a trace top to bottom.
        const next_pc = self.execute(bus, pc, insn) catch |err| {
            self.fault = err;
            self.halt_reason = .bus_error;
            return;
        };

        self.steps += 1;
        if (tracer) |t| t.emit(self.steps, pc, fetched.raw, insn, &self.a);

        // A control-flow instruction that lands on itself is our "firmware is done"
        // signal. Straight-line instructions can never satisfy this because their length
        // is at least 2.
        if (next_pc == pc) {
            self.pc = next_pc;
            self.halt_reason = .spin_loop;
            return;
        }

        self.pc = next_pc;
        if (self.pc == halt_address) self.halt_reason = .returned;
    }

    const Fetched = struct { raw: u32, length: u2 };

    /// Read one instruction's bytes. The length is only known after reading the first
    /// byte, so this is a two-stage read — which is exactly what the hardware does.
    fn fetch(bus: *Bus, pc: u32) !Fetched {
        const b0 = try bus.read8(pc);
        const length = decode.instructionLength(b0);

        var raw: u32 = b0;
        var i: u32 = 1;
        while (i < length) : (i += 1) {
            const byte = try bus.read8(pc +% i);
            raw |= @as(u32, byte) << @intCast(i * 8);
        }
        return .{ .raw = raw, .length = length };
    }

    // -----------------------------------------------------------------------------------
    // The executor
    // -----------------------------------------------------------------------------------

    /// Perform `insn` and return the address of the next instruction.
    ///
    /// Which of `r`, `s` and `t` is the destination varies by format, and it is not
    /// intuitive: RRR writes `r`, the RRI8 loads write `t`, MOVI.N writes `s`. Each arm
    /// below says which.
    fn execute(self: *Cpu, bus: *Bus, pc: u32, insn: decode.Instruction) !u32 {
        const sequential = pc +% @as(u32, insn.length);

        switch (insn.op) {
            // --- loads: AR[t] <- mem[AR[s] + imm] ---------------------------------------
            .l8ui => self.a[insn.t] = try bus.read8(self.address(insn)),
            .l16ui => self.a[insn.t] = try bus.read16(self.address(insn)),
            .l16si => {
                const half = try bus.read16(self.address(insn));
                // Sign-extend 16 -> 32 by casting through the signed types. Zig will not
                // do this implicitly; the widening has to say whether it is signed.
                const signed: i32 = @as(i16, @bitCast(half));
                self.a[insn.t] = @bitCast(signed);
            },
            .l32i, .l32i_n => self.a[insn.t] = try bus.read32(self.address(insn)),

            // L32R is the odd load: no base register, the address was resolved at decode.
            .l32r => self.a[insn.t] = try bus.read32(insn.target),

            // --- stores: mem[AR[s] + imm] <- AR[t] ---------------------------------------
            .s8i => try bus.write8(self.address(insn), @truncate(self.a[insn.t])),
            .s16i => try bus.write16(self.address(insn), @truncate(self.a[insn.t])),
            .s32i, .s32i_n => try bus.write32(self.address(insn), self.a[insn.t]),

            // --- immediates ---------------------------------------------------------------
            .movi => self.a[insn.t] = @bitCast(insn.imm),
            // MOVI.N is the exception: its destination is the `s` field.
            .movi_n => self.a[insn.s] = @bitCast(insn.imm),
            .addi, .addmi => self.a[insn.t] = self.a[insn.s] +% @as(u32, @bitCast(insn.imm)),
            .addi_n => self.a[insn.r] = self.a[insn.s] +% @as(u32, @bitCast(insn.imm)),

            // --- register-register --------------------------------------------------------
            // `+%` and `-%` wrap on overflow, which is what the hardware does. Plain `+`
            // would panic in a Debug build — a real hazard when emulating.
            .add, .add_n => self.a[insn.r] = self.a[insn.s] +% self.a[insn.t],
            .sub => self.a[insn.r] = self.a[insn.s] -% self.a[insn.t],
            .bitwise_and => self.a[insn.r] = self.a[insn.s] & self.a[insn.t],
            .bitwise_or => self.a[insn.r] = self.a[insn.s] | self.a[insn.t],
            .bitwise_xor => self.a[insn.r] = self.a[insn.s] ^ self.a[insn.t],
            .mov_n => self.a[insn.t] = self.a[insn.s],

            // --- barriers and no-ops -------------------------------------------------------
            // MEMW orders memory accesses around it. An in-order interpreter that
            // completes every access before starting the next already satisfies that, so
            // there is genuinely nothing to do — but firmware relies on it being *legal*.
            .memw, .nop, .nop_n => {},

            // --- unconditional control flow -------------------------------------------------
            .j => return insn.target,
            .jx => return self.a[insn.s],
            .ret, .ret_n => return self.a[0],
            .call0 => {
                // Read the target before writing a0, in case the target register *is* a0.
                self.a[0] = sequential;
                return insn.target;
            },
            .callx0 => {
                const destination = self.a[insn.s];
                self.a[0] = sequential;
                return destination;
            },

            // --- conditional branches -------------------------------------------------------
            // Signed comparisons cast through i32; unsigned ones compare the u32 directly.
            .beq => if (self.a[insn.s] == self.a[insn.t]) return insn.target,
            .bne => if (self.a[insn.s] != self.a[insn.t]) return insn.target,
            .blt => if (signedOf(self.a[insn.s]) < signedOf(self.a[insn.t])) return insn.target,
            .bge => if (signedOf(self.a[insn.s]) >= signedOf(self.a[insn.t])) return insn.target,
            .bltu => if (self.a[insn.s] < self.a[insn.t]) return insn.target,
            .bgeu => if (self.a[insn.s] >= self.a[insn.t]) return insn.target,

            .beqz, .beqz_n => if (self.a[insn.s] == 0) return insn.target,
            .bnez, .bnez_n => if (self.a[insn.s] != 0) return insn.target,
            .bltz => if (signedOf(self.a[insn.s]) < 0) return insn.target,
            .bgez => if (signedOf(self.a[insn.s]) >= 0) return insn.target,
        }

        return sequential;
    }

    /// Effective address of an RRI8 / RRRN load or store: base register plus offset.
    fn address(self: *const Cpu, insn: decode.Instruction) u32 {
        return self.a[insn.s] +% @as(u32, @bitCast(insn.imm));
    }
};

fn signedOf(value: u32) i32 {
    return @bitCast(value);
}

// ---------------------------------------------------------------------------------------
// Tests
//
// Each test hand-assembles a short program into IRAM and runs it. The byte sequences are
// the same encodings verified in cpu/decode.zig's tests.
// ---------------------------------------------------------------------------------------

const testing = std.testing;
const soc = @import("../soc/esp32.zig");
const Uart = @import("../periph/uart.zig").Uart;

const Harness = struct {
    uart: Uart = .{},
    bus: Bus = undefined,
    cpu: Cpu = .{},

    fn start(self: *Harness) !void {
        self.bus = try Bus.init(testing.allocator, &self.uart);
    }

    fn deinit(self: *Harness) void {
        self.bus.deinit(testing.allocator);
    }

    /// Place `program` at the start of IRAM and reset the CPU to run it. The stack
    /// pointer goes near the top of DRAM, growing down, as on real hardware.
    fn load(self: *Harness, program: []const u8) !void {
        try self.bus.writeBlock(soc.iram_base, program);
        self.cpu.reset(soc.iram_base, soc.dram_base + soc.dram_size - 16);
    }

    fn run(self: *Harness, max_steps: u64) void {
        self.cpu.run(&self.bus, max_steps, null);
    }
};

test "movi then add, ending with ret" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{
        0x22, 0xA0, 0x0A, // movi a2, 10
        0x32, 0xA0, 0x20, // movi a3, 32
        0x30, 0x42, 0x80, // add  a4, a2, a3   (r=4 dest, s=2, t=3)
        0x80, 0x00, 0x00, // ret
    });
    h.run(100);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqual(@as(u32, 10), h.cpu.a[2]);
    try testing.expectEqual(@as(u32, 32), h.cpu.a[3]);
    try testing.expectEqual(@as(u32, 42), h.cpu.a[4]);
    try testing.expectEqual(@as(u64, 4), h.cpu.steps);
}

test "arithmetic wraps instead of trapping" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{
        0x22, 0xAF, 0xFF, // movi a2, -1   (0xFFFFFFFF)
        0x32, 0xA0, 0x01, // movi a3, 1
        0x30, 0x42, 0x80, // add  a4, a2, a3  -> wraps to 0
        0x80, 0x00, 0x00, // ret
    });
    h.run(100);

    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), h.cpu.a[2]);
    try testing.expectEqual(@as(u32, 0), h.cpu.a[4]);
}

test "s32i and l32i through the stack pointer" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{
        0x22, 0xA1, 0x23, // movi a2, 0x123
        0x22, 0x61, 0x02, // s32i a2, a1, 8     (r=6, s=1, t=2, imm8=2 -> +8)
        0x32, 0x21, 0x02, // l32i a3, a1, 8     (r=2, s=1, t=3, imm8=2)
        0x80, 0x00, 0x00, // ret
    });
    h.run(100);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqual(@as(u32, 0x123), h.cpu.a[3]);
    try testing.expectEqual(@as(u32, 0x123), try h.bus.read32(h.cpu.a[1] + 8));
}

test "narrow forms execute identically to their wide counterparts" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{
        0x0C, 0x22, // movi.n a2, 2      (destination is the s field, not t)
        0x0C, 0x53, // movi.n a3, 5
        0x4A, 0x23, // add.n  a2, a3, a4  (r=2 dest, s=3, t=4)
        0x0D, 0xF0, // ret.n
    });
    h.run(100);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqual(@as(u32, 5), h.cpu.a[3]);
    // a4 is still 0, so add.n a2, a3, a4 leaves a2 = 5, overwriting the 2.
    try testing.expectEqual(@as(u32, 5), h.cpu.a[2]);
    try testing.expectEqual(@as(u64, 4), h.cpu.steps);
}

test "a backwards branch makes a counting loop" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // movi a2, 3          ; counter
    // movi a3, 0          ; accumulator
    // loop:
    //   addi a3, a3, 1
    //   addi a2, a2, -1
    //   bnez a2, loop     ; BRI12, offset = -6 from (pc + 4)
    // ret
    try h.load(&[_]u8{
        0x22, 0xA0, 0x03, // 0: movi a2, 3
        0x32, 0xA0, 0x00, // 3: movi a3, 0
        0x32, 0xC3, 0x01, // 6: addi a3, a3, 1
        0x22, 0xC2, 0xFF, // 9: addi a2, a2, -1
        0x56, 0x62, 0xFF, // 12: bnez a2, loop -> 12 + 4 + (-10) = 6
        0x80, 0x00, 0x00, // 15: ret
    });
    h.run(1000);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqual(@as(u32, 0), h.cpu.a[2]);
    try testing.expectEqual(@as(u32, 3), h.cpu.a[3]);
}

test "call0 saves the return address in a0 and ret uses it" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // CALL0 clobbers a0, so a function that both calls and returns must spill a0 to the
    // stack first. That is the entire reason the call0 ABI needs a stack pointer, and
    // exactly what register windows exist to avoid.
    //
    //   0x00: s32i a0, a1, 0   ; save the incoming return address
    //   0x03: call0 0x14       ; a0 <- 0x06, jump to the callee
    //   0x06: l32i a0, a1, 0   ; restore it
    //   0x09: movi a4, 1       ; proof that we came back
    //   0x0C: ret              ; -> halt_address
    //   0x0F: nop.n / nop      ; padding, because call0 targets must be 4-byte aligned
    //   0x14: movi a5, 7       ; the callee
    //   0x17: ret              ; -> 0x06
    try h.load(&[_]u8{
        0x02, 0x61, 0x00, // 0x00 s32i a0, a1, 0
        0x05, 0x01, 0x00, // 0x03 call0 0x14  (offset18 = 4: (3 & ~3) + 4 + 16)
        0x02, 0x21, 0x00, // 0x06 l32i a0, a1, 0
        0x42, 0xA0, 0x01, // 0x09 movi a4, 1
        0x80, 0x00, 0x00, // 0x0C ret
        0x3D, 0xF0, //       0x0F nop.n
        0xF0, 0x20, 0x00, // 0x11 nop
        0x52, 0xA0, 0x07, // 0x14 movi a5, 7
        0x80, 0x00, 0x00, // 0x17 ret
    });
    h.run(100);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqual(@as(u32, 7), h.cpu.a[5]); // callee ran
    try testing.expectEqual(@as(u32, 1), h.cpu.a[4]); // and we came back
}

test "l32r loads a literal placed before the code" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // Put a literal at IRAM+0, and the code at IRAM+4 so the literal is behind it.
    try h.bus.write32(soc.iram_base, 0x3FF4_0000);
    // At pc = IRAM+4: base = (IRAM+7) & ~3 = IRAM+4, so we need offset -4,
    // i.e. imm16 = 0xFFFF.
    try h.bus.writeBlock(soc.iram_base + 4, &[_]u8{
        0x21, 0xFF, 0xFF, // l32r a2, -4
        0x80, 0x00, 0x00, // ret
    });
    h.cpu.reset(soc.iram_base + 4, soc.dram_base + soc.dram_size - 16);
    h.run(100);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqual(@as(u32, 0x3FF4_0000), h.cpu.a[2]);
}

test "a jump to itself halts as a spin loop" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{
        0x06, 0xFF, 0xFF, // j .
    });
    h.run(100);

    try testing.expectEqual(HaltReason.spin_loop, h.cpu.halt_reason);
    try testing.expectEqual(@as(u64, 1), h.cpu.steps);
}

test "the step budget stops a runaway program" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // An infinite loop that is not a fixed point, so the spin-loop rule does not fire
    // and only the step budget can stop it.
    try h.load(&[_]u8{
        0xF0, 0x20, 0x00, // 0: nop
        0x46, 0xFE, 0xFF, // 3: j -7  -> 3 + 4 - 7 = 0
    });
    h.run(50);

    try testing.expectEqual(HaltReason.step_budget_exhausted, h.cpu.halt_reason);
    try testing.expectEqual(@as(u64, 50), h.cpu.steps);
}

test "an illegal instruction halts with a fault" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{ 0x00, 0x00, 0x00 }); // ILL
    h.run(100);

    try testing.expectEqual(HaltReason.illegal_instruction, h.cpu.halt_reason);
    try testing.expectEqual(@as(?anyerror, error.IllegalInstruction), h.cpu.fault);
}

test "an unsupported instruction is reported separately" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{ 0x15, 0x00, 0x00 }); // call4: needs register windows
    h.run(100);

    try testing.expectEqual(HaltReason.unsupported_instruction, h.cpu.halt_reason);
}

test "a store to an unmapped address halts with a bus error" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    try h.load(&[_]u8{
        0x22, 0xA0, 0x00, // movi a2, 0     (a2 = 0, an unmapped address)
        0x22, 0x62, 0x00, // s32i a2, a2, 0
        0x80, 0x00, 0x00, // ret
    });
    h.run(100);

    try testing.expectEqual(HaltReason.bus_error, h.cpu.halt_reason);
    try testing.expectEqual(@as(?anyerror, error.UnmappedAddress), h.cpu.fault);
}

test "storing to the uart fifo emits a byte" {
    var h = Harness{};
    try h.start();
    defer h.deinit();

    // Build 0x3FF40000 in a3 without l32r: movi cannot reach it, so use a literal.
    try h.bus.write32(soc.iram_base, soc.uart0_base);
    try h.bus.writeBlock(soc.iram_base + 4, &[_]u8{
        0x31, 0xFF, 0xFF, // l32r a3, -4       -> a3 = 0x3FF40000
        0x22, 0xA0, 0x48, // movi a2, 'H'
        0x22, 0x63, 0x00, // s32i a2, a3, 0
        0x80, 0x00, 0x00, // ret
    });
    h.cpu.reset(soc.iram_base + 4, soc.dram_base + soc.dram_size - 16);
    h.run(100);

    try testing.expectEqual(HaltReason.returned, h.cpu.halt_reason);
    try testing.expectEqualStrings("H", h.uart.transmitted());
}
