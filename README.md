# simulatr

A deterministic, headless simulator for ESP32-class microcontroller networks, written in
Zig. It interprets real Xtensa machine code — firmware is an unmodified `.elf`.

**Status: Phase 1 (POC).** One CPU, one peripheral, one command. See
[docs/PLAN.md](docs/PLAN.md) for where this is going.

## Requirements

Zig 0.16.0. That is all you need to build simulatr and run its tests.

The Espressif toolchain (`xtensa-esp-elf-gcc`) is only needed to *rebuild* the example
firmware; the built ELF is checked in. `zig build firmware` regenerates it.

## Try it

```console
$ zig build
$ ./zig-out/bin/simulatr run examples/hello.elf
HELLO
simulatr: esp32, entry 0x40080008, 29 instructions, 5 bytes transmitted, halt: spin_loop
```

`examples/hello.elf` is built by `xtensa-esp-elf-gcc` from `examples/hello.S`. Those 29
instructions are really decoded and executed: two `l32r` literal loads, then a loop of
`l8ui` / `s32i.n` / `addi.n` / `addi.n` / `bnez` that pushes one byte at a time into the
ESP32's UART0 TX FIFO register at `0x3FF40000`.

```console
$ ./zig-out/bin/simulatr run examples/hello.elf --trace 2>&1 >/dev/null | head -1
{"step":1,"pc":"0x40080008","raw":"0xfffe31","len":3,"op":"l32r","a":["0xdeadbee0", ...]}
```

**stdout is the emulated UART and nothing else**, so `simulatr run f.elf > out.txt` gives
exactly the bytes the firmware transmitted. The trace and all diagnostics go to stderr:
`simulatr run f.elf --trace 2> trace.jsonl`.

## Commands

```
simulatr run <elf> [options]

  --trace            one JSON object per executed instruction, on stderr
  --max-steps <n>    instruction budget for the run (default 10000000)
  -h, --help
```

Exit codes: `0` finished, `2` step budget exhausted, `3` faulted, `1` bad arguments or
unreadable file.

## Tests

```console
$ zig build test --summary all
```

Unit tests live in the source files themselves. They cover decoder encodings, memory
alignment and region edges, ELF rejection cases, execution semantics, an end-to-end test
that builds an ELF in memory, and a fixture test that runs the real GCC-built
`examples/hello.elf` and checks that `HELLO` comes out of the UART.

## What Phase 1 does and does not model

**Does:** IRAM + DRAM with alignment checks, ELF32 loading, ~40 Xtensa LX6 instructions in
both 24-bit and 16-bit forms, a flat 16-register call0 execution core, and UART0 transmit.

**Does not:** register windows, interrupts, exceptions, cache or MMU, flash, the second
CPU core, FreeRTOS, any real ESP-IDF binary, or any peripheral other than UART TX. The
decoder returns `UnsupportedInstruction` rather than guessing at anything it does not
implement.

Timing is not modelled at all — not even approximately — in Phase 1.

## Layout

| Path | What |
|---|---|
| `src/soc/esp32.zig` | Every chip-specific address. Add a second chip by adding a sibling. |
| `src/mem/bus.zig` | Address decode, RAM regions, MMIO dispatch |
| `src/load/elf.zig` | ELF32 loader |
| `src/cpu/decode.zig` | Xtensa instruction decoder |
| `src/cpu/core.zig` | Registers, execution, halt conditions |
| `src/periph/uart.zig` | UART0 TX |
| `src/machine.zig` | One node: CPU + bus + peripherals |
| `src/trace.zig` | JSON Lines instruction trace |
| `src/cli.zig` | Command surface |
| `src/host_io.zig` | The only file that touches the host OS |
| `examples/` | The demo firmware: `hello.S`, its linker script, `build.sh`, and the built ELF |

## Docs

- [docs/PLAN.md](docs/PLAN.md) — scope and phases
- [docs/PHASE1-NOTES.md](docs/PHASE1-NOTES.md) — Xtensa quirks and Zig 0.16 notes; read
  this alongside the decoder
- [docs/DECISIONS.md](docs/DECISIONS.md) — design choices the plan did not specify
