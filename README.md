# simulatr

A deterministic, headless simulator for ESP32-class microcontroller networks, written in
Rust. It interprets real Xtensa machine code — firmware is an unmodified `.elf`.

**Status: Phase 1.** One CPU, one peripheral, one command. See
[docs/PLAN.md](docs/PLAN.md) for where this is going.

## Requirements

Rust 1.97 or newer. That is all you need to build simulatr and run its tests.

The Espressif toolchain (`xtensa-esp-elf-gcc`) is only needed to *rebuild* the example
firmware; the built ELF is checked in and compiled into the test binary.

## Try it

```console
$ cargo build --release
$ ./target/release/simulatr run examples/hello.elf
HELLO
simulatr: esp32, entry 0x40080008, 29 instructions, 5 bytes transmitted, halt: spin_loop
```

`examples/hello.elf` is built by `xtensa-esp-elf-gcc` from [`examples/hello.S`](examples/hello.S).
Those 29 instructions are really decoded and executed: two `l32r` literal-pool loads, then
a loop of `l8ui` / `s32i.n` / `addi.n` / `addi.n` / `bnez` pushing one byte at a time into
the ESP32's UART0 TX FIFO register at `0x3FF40000`.

```console
$ ./target/release/simulatr run examples/hello.elf --trace 2>&1 >/dev/null | head -1
{"step":1,"pc":"0x40080008","raw":"0xfffe31","len":3,"op":"l32r","a":["0xdeadbee0", ...]}
```

**stdout carries the emulated UART and nothing else**, so `simulatr run f.elf > out.txt`
gives exactly the bytes the firmware transmitted. The trace and all diagnostics go to
stderr: `simulatr run f.elf --trace 2> trace.jsonl`.

## Commands

```
simulatr run <ELF> [--trace] [--max-steps N]

  --trace            one JSON object per executed instruction, on stderr
  --max-steps <N>    instruction budget for the run (default 10000000)
```

Exit codes: `0` finished, `2` step budget exhausted, `3` faulted, `1` bad arguments or an
unreadable image.

## Tests

```console
$ cargo test
$ cargo clippy --all-targets -- -D warnings
```

Tests are colocated with the code they cover: decoder encodings checked against
`objdump` output, memory alignment and region edges, ELF rejection cases, execution
semantics, and a fixture test that runs the real GCC-built `examples/hello.elf` — embedded
with `include_bytes!`, so `cargo test` needs no Xtensa toolchain.

## Rebuilding the firmware

```console
$ export PATH="$HOME/.local/opt/xtensa-esp-elf/bin:$PATH"
$ ./examples/build.sh
```

Two GCC flags in that script are load-bearing and non-obvious —
`-mdynconfig=.../xtensa_esp32.so` (the toolchain's default core is generic *big-endian*,
which simulatr correctly rejects) and `-Wa,--text-section-literals` (L32R can only reach
backwards, so its literal pool must precede the code). The script explains both.

## What Phase 1 does and does not model

**Does:** IRAM + DRAM with alignment checks, ELF32 loading, the Xtensa LX6 instruction
subset real firmware uses in both 24-bit and 16-bit narrow forms, a flat 16-register call0
execution core, and UART0 transmit.

**Does not:** register windows, interrupts, exceptions, cache or MMU, flash, the second
CPU core, FreeRTOS, any real ESP-IDF binary, or any peripheral other than UART TX. The
decoder returns `DecodeError::Unsupported` rather than guessing at anything it does not
implement.

Timing is not modelled at all in Phase 1 — not even approximately. Later phases model
instruction counts and peripheral deadlines, never pipeline stalls or cache misses: good
enough for protocol and logic bugs, useless for tight bit-banging.

## Layout

| Path | What |
|---|---|
| `crates/simulatr-core` | The emulator. **Zero dependencies, no `unsafe`, no host I/O.** |
| `crates/simulatr-cli` | The `simulatr` binary: arguments, files, streams, exit codes. |
| `examples/` | The demo firmware: `hello.S`, its linker script, `build.sh`, and the built ELF. |

Inside `simulatr-core`:

| Module | What |
|---|---|
| `soc::esp32` | Every chip-specific address. Adding a second chip means adding a sibling. |
| `mem::bus` | Address routing, RAM regions, MMIO dispatch |
| `load::elf` | Hand-rolled ELF32 loader |
| `cpu::decode` | Xtensa instruction decoder |
| `cpu::core` | Registers, execution, halt conditions |
| `periph::uart` | UART0 TX |
| `machine` | One node: CPU + bus + peripherals, plus the run loop and `Observer` |
| `trace` | JSON Lines instruction trace |

`simulatr-core` is dependency-free on purpose: it guarantees no crate can smuggle in
threads, time or randomness, which is what makes a run byte-for-byte reproducible.
Determinism is the product, not a nicety — it is what makes an agent's iterate-and-fix
loop converge instead of chasing ghosts.

## Docs

- [docs/PLAN.md](docs/PLAN.md) — scope and phases
- [docs/PHASE1-NOTES.md](docs/PHASE1-NOTES.md) — Xtensa encoding findings and Rust design
  notes; read this alongside `cpu::decode`
- [docs/DECISIONS.md](docs/DECISIONS.md) — design choices the plan did not specify

Phase 1 was originally built in Zig; that implementation is preserved at the git tag
`zig-phase1`. `docs/PLAN.md` explains why the project moved to Rust.
