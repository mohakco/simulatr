# Phase 1 notes

Things worth understanding about the code, especially the Xtensa quirks it had to handle.
Read `src/cpu/decode.zig` alongside this.

---

## Xtensa quirks the decoder had to deal with

### Instruction length is one bit of the first byte

Xtensa instructions are 24 bits (3 bytes). With the Code Density option — which the ESP32
has — there are also 16-bit "narrow" forms. The length rule is: **bit 3 of the first byte
set means 2 bytes, clear means 3**. That bit is the high bit of `op0`, so `op0 >= 8` means
narrow. Xtensa deliberately put the length indicator where a fetch unit can read it
without decoding anything else, which is why `Cpu.fetch` is a two-stage read: one byte,
then the rest.

`op0` values 0xE and 0xF are reserved — we return `IllegalInstruction`.

### Little-endian *inside* the instruction

Bytes `b0 b1 b2` form the value `b0 | b1<<8 | b2<<16`. The ISA manual numbers instruction
bits from 0 = least significant and draws its field diagrams right-to-left, so `op0` is
bits 3:0 and lives in the *first* byte in memory.

This is why `Fields24` is a `packed struct(u24)` with `op0` declared first: Zig lays
packed-struct fields out starting at the least significant bit, so the declaration can be
read straight off the manual's diagram. `@bitCast` between the u24 and the struct is free.

### Fields overlap between formats

The same bits mean different things in different formats:

| Bits | RRR | RRI8 | BRI12 | CALL |
|---|---|---|---|---|
| 23:16 | `op2`,`op1` | `imm8` | part of `imm12` | part of `offset` |
| 7:6 | part of `t` | part of `t` | `m` (condition) | part of `offset` |
| 5:4 | part of `t` | part of `t` | `n` (sub-group) | `n` (window inc) |

So the packed struct only covers the *regular* fields; `imm8`, `imm12`, `imm16`,
`offset18`, `m` and `n` are pulled out by explicit shifting. That is not sloppiness — the
overlap is real and there is no single struct that describes all formats.

### Load and store offsets are unsigned and scaled

`l32i a2, a3, 8` encodes 8 as `imm8 = 2`, because the field is scaled by the access width.
`l32i` reaches 0..1020 bytes past the base register, `l16ui` 0..510, `l8ui` 0..255. All
**forward only** — there are no negative load offsets. The decoder pre-scales, so
`Instruction.imm` is always the byte offset.

Meanwhile `addi`'s immediate *is* signed (-128..127), and `movi`'s is a signed 12-bit
value (-2048..2047) assembled from two non-adjacent fields (`s` supplies bits 11:8,
`imm8` supplies 7:0).

### L32R: the literal pool, and why it only reaches backwards

Xtensa has no "load a 32-bit constant" instruction. `movi` reaches 12 bits. Anything
larger — including every peripheral address — comes from a **literal pool**: the constant
is stored in memory near the code and `l32r` fetches it PC-relatively.

The encoding is unusual. The 16-bit field is OR-ed into `0xFFFC0000`, so the offset is
*always negative*: the reachable range is PC-262144 .. PC-4. **Literals must precede the
code that uses them.** That is why `examples/hello.S` has `.literal_position` before
`_start`: the built image puts two literal words at 0x40080000 and the entry point at
0x40080008. Get the ordering wrong and the linker says
`dangerous relocation: l32r: literal placed after use`.

The base is `(PC + 3) & ~3` — the address after the instruction, rounded down to a word.
This matches binutils' `Operand_uimm16x4_ator`, and objdump settles it:

```
40080008: fffe31   l32r a3, 40080000
4008000b: fffe41   l32r a4, 40080004
```

Both encode `imm16 = 0xFFFE`, i.e. offset -8. The second one sits at `pc & 3 == 3`:
`(0x4008000B + 3) & ~3 = 0x4008000C`, minus 8 gives 0x40080004 — which is what objdump
says. The alternative reading of the manual, `PC & ~3`, would give 0x40080000 and load
the wrong literal. So `(PC + 3) & ~3` is correct, and the disagreement only ever shows up
at unaligned `l32r`, which is exactly the case GCC produced here.

### J and CALL0 scale their offsets differently

Both use an 18-bit signed field, but:

- `j` offset is in **bytes**, relative to `PC + 4`.
- `call0` offset is in **words** (scaled by 4), relative to `(PC & ~3) + 4`.

So call targets are always 4-byte aligned and jump targets are not. Getting these
backwards produces a plausible-looking address that is wrong by a factor of four.

### MOVI.N's immediate is asymmetric, not sign-extended

`movi.n` covers **-32..95** from a 7-bit field. Values 0..95 encode directly; -32..-1
encode as 96..127. It is not a sign-extended 7-bit field. Small positive constants are far
more common than negative ones, so the encoding buys 32 extra positive values.

The 7 bits are also split: `t[2:0]` supplies bits 6:4, `r` supplies bits 3:0. And the
destination register is the **`s`** field, not `t` — unlike every other move. Confirmed
against objdump: GCC emits `550c` for `movi.n a5, 5`, i.e. `r = 5` (the immediate) and
`s = 5` (the register), which only decodes correctly with that field split.

### BEQZ.N / BNEZ.N branch forward only

6-bit *unsigned* offset relative to `PC + 4`, reaching 4..67 bytes ahead. A backwards loop
needs the 24-bit `beqz`/`bnez` (12-bit signed, `PC + 4` relative). Do not assume the
narrow form is a drop-in replacement.

### Which field is the destination changes by format

There is no consistent rule, and this is the easiest place to introduce a silent bug:

| Format | Destination |
|---|---|
| RRR (`add`, `sub`, `and`) | `r` |
| RRI8 loads (`l32i`), `movi`, `addi` | `t` |
| RRRN (`add.n`, `addi.n`) | `r` |
| `l32i.n` | `t` |
| `mov.n` | `t` |
| `movi.n` | `s` |

Each arm of the executor's switch says which one it writes.

### RET is 0x000080, and the all-zero word is the illegal instruction

`0x000000` is `ILL`, the canonical illegal instruction — which is convenient, because
jumping into zeroed memory stops the run immediately instead of executing garbage.
`ret` is the same encoding with `t = 8`. `ret.n` is `0xF00D` and `nop.n` is `0xF03D`;
both are worth memorising because they show up constantly in hex dumps.

---

## Emulator design notes

### No register windows, and why `call0` needs a stack

Phase 1 implements only the **call0 ABI**: 16 flat registers, `a0` holds the return
address, `a1` is the stack pointer, and `CALL0` simply overwrites `a0`. A function that
both calls and returns therefore has to spill `a0` to the stack first — see the
`call0 saves the return address in a0` test in `src/cpu/core.zig`, which does exactly
that. Register windows (`CALL4/8/12`, `ENTRY`, `RETW`) exist precisely to avoid that
spill, and they are the first job of Phase 2. The decoder refuses them rather than
pretending.

### Halting

There is no operating system to return to, so `Cpu` stops on:

1. `ret` landing on `halt_address` (0xDEADBEE0), which is planted in `a0` at reset;
2. a jump or taken branch to itself (`j .`), which is how firmware signals it is done;
3. the step budget running out;
4. any decode or bus error, recorded in `Cpu.fault`.

The exit code reflects which: 0 for 1 and 2, 2 for the budget, 3 for a fault.

### Validated against the real toolchain

`examples/hello.elf` is built by `xtensa-esp-elf-gcc` from `examples/hello.S`, embedded
into the test binary with `@embedFile`, and executed by a unit test that checks both the
output and the instruction count. Two things this caught that hand-assembly alone would
not have:

- **GCC uses narrow forms unprompted.** The source says `movi`, `s32i`, `addi`; the
  assembler emits `movi.n`, `s32i.n`, `addi.n`. Any decoder that only handles 24-bit
  instructions dies on the second line of real compiler output.
- **The toolchain defaults to a big-endian generic Xtensa core.** Without
  `-mdynconfig=.../xtensa_esp32.so` you get an `elf32-xtensa-be` image. simulatr rejects
  it with `NotLittleEndian`, which is the right answer, but it is a confusing five minutes
  if you do not know to look. See `examples/build.sh`.

### Everything except `host_io.zig` is free of host I/O

The CPU, bus, loader, UART and tracer are pure computation over bytes in memory. That is
what lets all 78 unit tests run without opening a file, and it is what will make
snapshot/restore and deterministic replay tractable in Phase 7.

---

## Zig 0.16 notes

Zig 0.16 reworked I/O around an explicit `std.Io` value, passed in the same way an
`Allocator` is. Consequences you will hit if you are following older material:

- `std.fs.File` no longer exists. The file type is **`std.Io.File`**, the directory type is
  **`std.Io.Dir`**, and their methods take an `Io` as an argument.
- `main` can take a `std.process.Init` parameter, which carries `io`, `gpa`, `arena` and
  the command-line arguments. No hidden globals, and no `std.process.argsAlloc`.
- Writing goes through **`std.Io.Writer`**, which is buffered: bytes sit in a buffer *you*
  supply until `flush()`. Forgetting to flush means no output at all.
- `std.Io.Writer.fixed(&array)` gives a writer that drains into a byte array — the clean
  way to capture output in a test, used in the `HELLO` end-to-end test.
- `{t}` in a format string prints an error or enum by name, replacing `@errorName`.

Other Zig things this codebase leans on, in the order the plan wanted to teach them:
`build.zig`, slices vs arrays (`Uart.tx_buffer` is an array, `Bus.iram` is a slice),
`comptime` (`signExtend`'s width parameter, the firmware image built at compile time),
packed structs (`Fields24`), error unions and `try` (`BusError!u32`), `defer`/`errdefer`
(allocator cleanup), optionals (`?*Tracer`, `?*std.Io.Writer`), and allocator plumbing
(`Bus.init` takes one, `deinit` takes the same one back).

### One sharp edge worth internalising

`Bus` holds a `*Uart`, and `Machine` holds both. A constructor that returned a `Machine`
*by value* would copy the struct to the caller's storage and leave that pointer aimed at
the dead temporary. So `Machine.init` and `Bus.init` are written to be called on a struct
that is already in its final location. Zig has no move constructors and will not warn you
about this — the same pattern appears in every test harness in the codebase.

---

## Where the seams are for Phase 2

- `src/soc/esp32.zig` holds every chip-specific constant. An S3 profile is a sibling file.
- `src/cpu/decode.zig` returns `UnsupportedInstruction` for exactly the instructions
  Phase 2 must add; grep for it to get the work list.
- `src/machine.zig` is the "Node" boundary the orchestrator will multiply.
- `Cpu.run` takes a step budget, which is where a virtual clock will hook in.
