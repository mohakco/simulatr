//! The ONLY file in simulatr that touches the host operating system.
//!
//! Everything else — the CPU, the bus, the loader, the UART — is pure computation over
//! bytes in memory. That is deliberate: it keeps the emulator deterministic and makes
//! every unit test run without opening a file or writing to a terminal.
//!
//! ## Zig 0.16's `std.Io`
//!
//! Zig 0.16 reworked I/O around an explicit `std.Io` value. Instead of the standard
//! library reaching for syscalls behind your back, *you* pass an `Io` in — the same way
//! you pass an `Allocator` in. The program's `main` receives one from the runtime
//! (`init.io`), and it gets handed down to anything that reads or writes.
//!
//! Two consequences you will see throughout this project:
//!
//!   * `std.fs.File` is gone; the file type is `std.Io.File`, and its methods take an
//!     `Io` as their first real argument.
//!   * Writing goes through `std.Io.Writer`, a buffered writer. Bytes sit in *your*
//!     buffer until `flush()` is called, so anything that writes must also flush.

const std = @import("std");

/// Open a buffered writer onto the process's stdout.
///
/// `buffer` is borrowed, not copied: it must outlive the returned writer. Returning the
/// `File.Writer` by value is fine here, but note that the caller must take `&w.interface`
/// *after* storing `w` in its final location — see the note in cli.zig.
pub fn stdoutWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(io, buffer);
}

/// Open a buffered writer onto the process's stderr.
///
/// Streaming rather than positional, because stdout/stderr may be a pipe or a terminal
/// with no meaningful seek position.
pub fn stderrWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(io, buffer);
}

/// Read an entire file into a freshly allocated slice.
///
/// Zig has no garbage collector and no hidden global allocator: any function that
/// allocates takes an `allocator` parameter, and the *caller* owns and must free the
/// result (`defer allocator.free(bytes)` at the call site). Making that explicit is one
/// of Zig's core design choices.
pub fn readFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}
