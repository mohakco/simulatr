# Decisions

Design choices `docs/PLAN.md` did not specify, with one line of reasoning each.
Newest at the bottom. Phase 1 unless noted.

## Memory and SoC

- **IRAM is 0x40080000 + 128 KiB, DRAM is 0x3FFB0000 + 192 KiB.** These are the origins
  ESP-IDF's own linker script uses for `iram0_0_seg` / `dram0_0_seg`, so a real image
  lands where we expect; the lengths are rounded for tidiness since nothing depends on
  the exact end yet.
- **No instruction/data bus aliasing.** Real ESP32 SRAM appears at more than one address.
  Modelling that costs nothing in Phase 1 and buys nothing, so IRAM and DRAM are two
  independent buffers.
- **RAM is zeroed at power-up.** Real SRAM comes up with garbage, but a simulator that
  starts from garbage is not reproducible, and determinism is the product.
- **Unmapped and unimplemented addresses are errors, not silent zeroes.** A firmware bug
  that pokes an unmodelled peripheral should stop the run with an address, not quietly
  read 0 and diverge from hardware fifty instructions later. `UnmappedAddress` and
  `UnimplementedPeripheral` are separate errors so you can tell "nothing there" from
  "we haven't written it yet".
- **Misaligned 16/32-bit access is a bus error.** Real Xtensa raises
  `LoadStoreAlignmentCause`; Phase 1 has no exception machinery, so it halts instead.

## UART

- **UART0 covers its whole 0x80 register block; unknown registers accept writes and read
  as 0.** Firmware configures baud rate and line control before transmitting, and it must
  not fault while doing so. `UART_STATUS_REG` reads as 0, meaning "TX FIFO empty", so a
  firmware wait-for-space loop exits immediately.
- **Transmission is instantaneous and the FIFO never fills.** There is no clock model in
  Phase 1, so there is no meaningful baud rate.
- **The UART buffers into a 4 KiB array and writes through an optional `std.Io.Writer`.**
  With no writer attached it still records everything, which makes every unit test run
  without touching a file descriptor.

## Streams

- **stdout is the emulated UART and nothing else.** `simulatr run hello.elf > out.txt`
  produces exactly the bytes the firmware transmitted, which is what makes the output
  testable and diffable.
- **`--trace` JSON and all simulatr diagnostics go to stderr.** Follows from the rule
  above. Use `simulatr run f.elf --trace 2> trace.jsonl` to separate them.
- **The trace is JSON Lines, hand-formatted into a fixed buffer.** One self-contained
  object per line streams and greps well; the shape is fixed enough that `std.json` would
  add dependency surface without adding correctness.

## CPU

- **A run ends on one of four conditions**, since there is no OS to return to:
  1. `ret` to `halt_address` (0xDEADBEE0), which we plant in a0 before the first
     instruction — the clean exit for code that returns.
  2. A jump or taken branch to itself. Firmware spins when it is done; a fixed point in
     the control flow is the natural "finished" signal, and `j .` is how hello.S ends.
  3. Step budget exhausted (default 10,000,000).
  4. Any decode or bus error.
- **Decode failures are split into `IllegalInstruction` and `UnsupportedInstruction`.**
  The first means the bit pattern is reserved; the second means it is a real Xtensa
  instruction Phase 1 chose not to implement. When a run dies, that distinction tells you
  immediately whether you found a bug or hit a boundary.
- **The decoder refuses everything it has not verified.** CALL4/8/12, RETW, the
  `BEQI`/`BLTUI` family (which need the B4CONST/B4CONSTU lookup tables), shifts,
  multiplies and special-register moves all return `UnsupportedInstruction` rather than a
  guess. Guessing an encoding is worse than refusing one.
- **Immediates are sign-extended and scaled at decode time; branch targets are resolved
  to absolute addresses at decode time.** All the bit fiddling happens once, in one file,
  so the executor is a flat readable switch.
- **`a1` is initialised to the top of DRAM minus 16, 16-byte aligned.** Hand-written
  assembly usually does not set up its own stack, and the call0 ABI requires an aligned
  `a1`.

## Loader

- **The whole ELF is read into memory before parsing.** Phase 1 images are kilobytes;
  streaming would complicate the loader and drag host I/O into it for no benefit.
- **The loader only reads program headers.** Sections are a link-time view. The symbol
  table becomes interesting in Phase 2, when traces want function names.

## Project

- **`examples/hello.elf` is a real `xtensa-esp-elf-gcc` build of `examples/hello.S`,
  checked into the repo and embedded into the test binary with `@embedFile`.** Checking in
  the artefact keeps `zig build test` free of any toolchain dependency while still testing
  against genuine compiler output; `zig build firmware` regenerates it when you have the
  toolchain. (An earlier hand-assembling generator was deleted once GCC was available.)
- **Firmware is built with `-mdynconfig=.../xtensa_esp32.so`.** Xtensa is a configurable
  ISA and the toolchain's default core is generic *big-endian*, which produces an ELF
  simulatr rightly rejects. The flag selects the actual ESP32 core.
- **No abstraction over the SoC profile yet.** `src/soc/esp32.zig` is imported directly by
  name. Adding an S3 profile means introducing the seam then, with two real cases to look
  at, rather than guessing at one now.
