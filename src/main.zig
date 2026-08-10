//! Executable entry point. Everything interesting is one layer down in cli.zig; this file
//! only deals with process concerns: arguments, the two output streams, and the exit code.

const std = @import("std");
const cli = @import("cli.zig");
const host_io = @import("host_io.zig");

/// Zig 0.16 hands `main` a `std.process.Init` containing the things a process needs but
/// cannot invent for itself: command-line arguments, an allocator, an arena that lives
/// for the whole process, and an `Io` implementation. Nothing is a hidden global.
///
/// Returning `!u8` makes the u8 the process exit code.
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    // Writers buffer into memory we provide. Nothing reaches the terminal until `flush`,
    // which is why both are flushed on the way out.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = host_io.stdoutWriter(io, &stdout_buffer);
    // `&stdout_file.interface` must be taken after `stdout_file` is in its final storage:
    // the interface holds a pointer back into the struct it lives in.
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = host_io.stderrWriter(io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};

    // `toSlice` materialises the platform's argv as a slice of strings, allocated from
    // the process arena — so there is nothing to free.
    const argv = try init.minimal.args.toSlice(arena);

    // argv[0] is the program name; the command starts at index 1.
    const args = if (argv.len > 1) argv[1..] else argv[0..0];

    const options = cli.parse(args) catch |err| switch (err) {
        error.HelpRequested => {
            try stdout.writeAll(cli.usage);
            return 0;
        },
        else => {
            try stderr.print("simulatr: {t}\n\n{s}", .{ err, cli.usage });
            return 1;
        },
    };

    return cli.execute(io, gpa, stdout, stderr, options);
}
