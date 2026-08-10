//! Test root and library surface.
//!
//! Zig's test runner only compiles tests it can *reach* from the root source file, and
//! `@import` alone is not enough — an unreferenced import is dead code and gets dropped.
//! `std.testing.refAllDecls` forces every public declaration in a module to be analysed,
//! which pulls its test blocks in with it.
//!
//! Practical consequence: a new file only runs its tests once it is listed here.

const std = @import("std");

pub const soc = @import("soc/esp32.zig");
pub const bus = @import("mem/bus.zig");
pub const uart = @import("periph/uart.zig");
pub const elf = @import("load/elf.zig");
pub const decode = @import("cpu/decode.zig");
pub const core = @import("cpu/core.zig");
pub const trace = @import("trace.zig");
pub const machine = @import("machine.zig");
pub const cli = @import("cli.zig");
pub const host_io = @import("host_io.zig");

test {
    // `_ = @import(...)` inside a test block is the idiom that guarantees a file is
    // analysed, and therefore that its `test` blocks are collected and run. The `_ =`
    // discards the value; Zig refuses to let you ignore a result by accident.
    _ = @import("soc/esp32.zig");
    _ = @import("mem/bus.zig");
    _ = @import("periph/uart.zig");
    _ = @import("load/elf.zig");
    _ = @import("cpu/decode.zig");
    _ = @import("cpu/core.zig");
    _ = @import("trace.zig");
    _ = @import("machine.zig");
    _ = @import("cli.zig");
    _ = @import("host_io.zig");
}
