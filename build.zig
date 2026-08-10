//! Build script for simulatr.
//!
//! Zig has no separate build tool (no Makefile, no CMake). `build.zig` is an ordinary
//! Zig program: `zig build` compiles this file and runs `build()`, which *describes* a
//! graph of build steps. Nothing here compiles anything directly; it registers work.
//!
//! Targets:
//!   zig build            -> build the `simulatr` executable into zig-out/bin
//!   zig build run -- ... -> build then run it, forwarding args after `--`
//!   zig build test       -> compile and run every `test` block reachable from src/root.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    // `standardTargetOptions` exposes `-Dtarget=...` on the command line; with no flag it
    // means "the machine we are compiling on". simulatr is a host program (it *emulates*
    // Xtensa, it is never compiled *for* Xtensa), so the host default is what we want.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A "module" is a root source file plus its compilation settings. Since Zig 0.15 the
    // module is created explicitly and then handed to addExecutable/addTest.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "simulatr",
        .root_module = exe_module,
    });

    // Put the binary in zig-out/bin as part of the default `zig build`.
    b.installArtifact(exe);

    // --- `zig build run` -------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // `b.args` holds whatever followed `--` on the command line.
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run simulatr");
    run_step.dependOn(&run_cmd.step);

    // --- `zig build firmware` ---------------------------------------------------------
    // Rebuilds examples/hello.elf with the Espressif GCC toolchain. This is deliberately
    // NOT part of the default `zig build`: simulatr itself has no toolchain dependency,
    // and the resulting ELF is checked in so the emulator can be exercised without one.
    // See examples/build.sh for why the two GCC flags in there are needed.
    const firmware_cmd = b.addSystemCommand(&.{"./examples/build.sh"});
    const firmware_step = b.step("firmware", "Rebuild examples/hello.elf (needs xtensa-esp-elf-gcc)");
    firmware_step.dependOn(&firmware_cmd.step);

    // --- `zig build test` ------------------------------------------------------------
    // Zig's unit tests live inside the source files themselves, in `test "name" { ... }`
    // blocks. The test runner only sees tests in files that are *reachable* from the root
    // source file, which is why src/root.zig imports every module explicitly.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The firmware fixture lives outside src/, and `@embedFile` cannot escape a module's
    // root directory. Registering it as a named import makes it addressable as
    // `@embedFile("hello_elf")` from anywhere in the module.
    test_module.addAnonymousImport("hello_elf", .{
        .root_source_file = b.path("examples/hello.elf"),
    });

    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
