//! Command-line surface.
//!
//! Phase 1 has exactly one command:
//!
//!     simulatr run <elf> [--trace] [--max-steps N]
//!
//! Argument parsing is done by hand. There is no third-party dependency and no clever
//! reflection: a handful of string comparisons is easier to read than any framework, and
//! Phase 2 replaces this surface with an MCP server anyway.
//!
//! ## Which stream gets what
//!
//! **stdout is the emulated UART, and nothing else.** `simulatr run hello.elf > out.txt`
//! must produce exactly the bytes the firmware transmitted — that is what makes the
//! output testable and diffable.
//!
//! Everything simulatr says about itself, including the `--trace` JSON, goes to stderr:
//!
//!     simulatr run hello.elf --trace 2> trace.jsonl

const std = @import("std");
const host_io = @import("host_io.zig");
const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const Tracer = @import("trace.zig").Tracer;
const soc = @import("soc/esp32.zig");

pub const usage =
    \\simulatr - a deterministic ESP32 simulator
    \\
    \\usage:
    \\  simulatr run <elf> [options]
    \\
    \\options:
    \\  --trace            emit one JSON object per executed instruction on stderr
    \\  --max-steps <n>    instruction budget for the run (default 10000000)
    \\  -h, --help         show this message
    \\
;

/// Largest ELF we will read. Phase 1 firmware is a few kilobytes; this is a sanity bound,
/// not a real limit.
const max_elf_bytes = 16 * 1024 * 1024;

pub const Options = struct {
    elf_path: []const u8,
    trace: bool = false,
    max_steps: u64 = machine_mod.default_step_budget,
};

pub const ParseError = error{
    NoCommand,
    UnknownCommand,
    MissingElfPath,
    UnknownOption,
    MissingOptionValue,
    BadNumber,
    HelpRequested,
};

/// Parse `args` (excluding argv[0]) into Options.
///
/// Kept separate from `main` and free of I/O so it can be unit-tested directly. The
/// returned slices point into `args`, so they live exactly as long as the arguments do.
pub fn parse(args: []const []const u8) ParseError!Options {
    if (args.len == 0) return error.NoCommand;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        }
    }

    if (!std.mem.eql(u8, args[0], "run")) return error.UnknownCommand;
    if (args.len < 2) return error.MissingElfPath;

    var options = Options{ .elf_path = args[1] };

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--trace")) {
            options.trace = true;
        } else if (std.mem.eql(u8, arg, "--max-steps")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.max_steps = std.fmt.parseInt(u64, args[i], 10) catch
                return error.BadNumber;
        } else {
            return error.UnknownOption;
        }
    }

    return options;
}

/// Load and run one ELF. Returns the process exit code.
pub fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !u8 {
    const image = host_io.readFileAlloc(io, allocator, options.elf_path, max_elf_bytes) catch |err| {
        // `{t}` prints an error (or enum) by its name — new shorthand in Zig 0.16 for
        // what used to be `@errorName(err)`.
        stderr.print("simulatr: cannot read '{s}': {t}\n", .{ options.elf_path, err }) catch {};
        return 1;
    };
    defer allocator.free(image);

    // `Machine` must be constructed in place; see the comment on Machine.init.
    var machine: Machine = .{};
    try machine.init(allocator);
    defer machine.deinit(allocator);

    // Now that `machine` has its final address, it is safe to hand out interior pointers.
    machine.uart.sink = stdout;

    const load_result = machine.loadElf(image) catch |err| {
        stderr.print("simulatr: cannot load '{s}': {t}\n", .{ options.elf_path, err }) catch {};
        return 1;
    };

    var tracer = Tracer{ .out = stderr };
    const summary = machine.run(options.max_steps, if (options.trace) &tracer else null);

    // The UART's bytes are in the stdout writer's buffer; push them out before the
    // summary appears on stderr, so the two do not interleave confusingly on a terminal.
    stdout.flush() catch {};

    return reportSummary(stderr, load_result.entry, summary);
}

fn reportSummary(stderr: *std.Io.Writer, entry: u32, summary: machine_mod.RunSummary) u8 {
    stderr.print(
        "simulatr: {s}, entry 0x{x:0>8}, {d} instructions, {d} bytes transmitted, halt: {t}\n",
        .{ soc.name, entry, summary.steps, summary.bytes_transmitted, summary.halt_reason },
    ) catch {};

    switch (summary.halt_reason) {
        // Both of these mean "the firmware finished the way firmware finishes".
        .returned, .spin_loop => return 0,
        .step_budget_exhausted => return 2,
        else => {
            if (summary.fault) |err| {
                stderr.print(
                    "simulatr: fault at pc 0x{x:0>8}: {t}\n",
                    .{ summary.final_pc, err },
                ) catch {};
            }
            return 3;
        },
    }
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "parses the run command" {
    const options = try parse(&[_][]const u8{ "run", "hello.elf" });
    try testing.expectEqualStrings("hello.elf", options.elf_path);
    try testing.expect(!options.trace);
    try testing.expectEqual(machine_mod.default_step_budget, options.max_steps);
}

test "parses flags in any order" {
    const options = try parse(&[_][]const u8{ "run", "a.elf", "--trace", "--max-steps", "500" });
    try testing.expect(options.trace);
    try testing.expectEqual(@as(u64, 500), options.max_steps);

    const reordered = try parse(&[_][]const u8{ "run", "a.elf", "--max-steps", "500", "--trace" });
    try testing.expect(reordered.trace);
    try testing.expectEqual(@as(u64, 500), reordered.max_steps);
}

test "rejects malformed command lines" {
    try testing.expectError(error.NoCommand, parse(&[_][]const u8{}));
    try testing.expectError(error.UnknownCommand, parse(&[_][]const u8{"walk"}));
    try testing.expectError(error.MissingElfPath, parse(&[_][]const u8{"run"}));
    try testing.expectError(error.UnknownOption, parse(&[_][]const u8{ "run", "a.elf", "--fast" }));
    try testing.expectError(error.MissingOptionValue, parse(&[_][]const u8{ "run", "a.elf", "--max-steps" }));
    try testing.expectError(error.BadNumber, parse(&[_][]const u8{ "run", "a.elf", "--max-steps", "lots" }));
}

test "help is requested from anywhere on the line" {
    try testing.expectError(error.HelpRequested, parse(&[_][]const u8{"--help"}));
    try testing.expectError(error.HelpRequested, parse(&[_][]const u8{ "run", "a.elf", "-h" }));
}
