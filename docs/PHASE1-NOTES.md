# Phase 1 notes

Things worth understanding about the code, especially the Xtensa quirks it had to handle.
Read `crates/simulatr-core/src/cpu/decode.rs` alongside this.

Phase 1 was originally built in Zig and then ported to Rust; everything in the Xtensa
sections below is language-independent and was validated against real
`xtensa-esp-elf-gcc` output before the port. The Zig implementation is preserved at the
git tag `zig-phase1`.

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

The Zig version expressed this as a `packed struct(u24)` with `op0` declared first, since
Zig lays packed-struct fields out from the least significant bit — the declaration could
be read straight off the manual's diagram. Rust has no equivalent guarantee, so the port
uses a `Fields` newtype over the raw `u32` with one accessor per field. That turns out to
be the better shape anyway, because of the next section.

### Fields overlap between formats

The same bits mean different things in different formats:

| Bits | RRR | RRI8 | BRI12 | CALL |
|---|---|---|---|---|
| 23:16 | `op2`,`op1` | `imm8` | part of `imm12` | part of `offset` |
| 7:6 | part of `t` | part of `t` | `m` (condition) | part of `offset` |
| 5:4 | part of `t` | part of `t` | `n` (sub-group) | `n` (window inc) |

There is no single struct that describes all formats, so `Fields` simply exposes both
views of the same word: `op1`/`op2` *and* `imm8`, `t` *and* its `m`/`n` halves. Callers
pick the view their format uses. The overlap is real; pretending otherwise is what
produces subtly wrong decoders.

### Load and store offsets are unsigned and scaled

`l32i a2, a3, 8` encodes 8 as `imm8 = 2`, because the field is scaled by the access width.
`l32i` reaches 0..1020 bytes past the base register, `l16ui` 0..510, `l8ui` 0..255. All
**forward only** — there are no negative load offsets. The decoder pre-scales, so the
`offset` field of `Inst::Load` / `Inst::Store` is always a byte offset.

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

In the Rust port this table is encoded in the `Inst` enum itself: every variant names its
operands (`dst`, `src`, `base`, `lhs`, `rhs`), so the mapping is decided once in the
decoder and the executor cannot get it wrong. That is the single biggest correctness win
of the port.

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
`call0_clobbers_a0_so_the_caller_must_spill_it` test in
`crates/simulatr-core/src/cpu/core.rs`, which does exactly that. Register windows (`CALL4/8/12`, `ENTRY`, `RETW`) exist precisely to avoid that
spill, and they are the first job of Phase 2. The decoder refuses them rather than
pretending.

### Halting

There is no operating system to return to, so `Cpu` stops on:

1. `ret` landing on `HALT_ADDRESS` (0xDEADBEE0), which is planted in `a0` at reset;
2. a jump or taken branch to itself (`j .`), which is how firmware signals it is done;
3. the step budget running out;
4. any decode or bus error, carried in `HaltReason::Fault`.

The exit code reflects which: 0 for 1 and 2, 2 for the budget, 3 for a fault.

### Validated against the real toolchain

`examples/hello.elf` is built by `xtensa-esp-elf-gcc` from `examples/hello.S`, embedded
into the test binary with `include_bytes!`, and executed by a unit test that checks the
output, the instruction count, and that narrow forms were exercised. Two things this
caught that hand-assembly alone would not have:

- **GCC uses narrow forms unprompted.** The source says `movi`, `s32i`, `addi`; the
  assembler emits `movi.n`, `s32i.n`, `addi.n`. Any decoder that only handles 24-bit
  instructions dies on the second line of real compiler output.
- **The toolchain defaults to a big-endian generic Xtensa core.** Without
  `-mdynconfig=.../xtensa_esp32.so` you get an `elf32-xtensa-be` image. simulatr rejects
  it with `NotLittleEndian`, which is the right answer, but it is a confusing five minutes
  if you do not know to look. See `examples/build.sh`.

### The whole emulator is free of host I/O

`simulatr-core` is pure computation over bytes in memory: no filesystem, no clock, no
threads, no randomness, and no dependencies. That is what lets every core test run without
opening a file, what will make snapshot/restore and deterministic replay tractable in
Phase 7, and what keeps a WASM build viable. All host I/O lives in `simulatr-cli`.

---

## Rust notes

Things about the port worth knowing before you change it.

### The borrow-checker design, and why there is no `Rc<RefCell<_>>`

Emulator state looks like a cyclic mutable graph — peripherals raise interrupts on the
CPU, the CPU reads through the bus, the bus dispatches to peripherals — and that is how
most Rust emulators end up as `Rc<RefCell<_>>` soup. Three rules avoid it, and they are
load-bearing rather than stylistic:

- **`Machine` owns everything.** `Bus` owns its peripherals by value; nothing is shared.
- **The CPU does not own the bus.** `Cpu::step(&mut self, bus: &mut Bus)` takes it as a
  parameter, so `Machine::run` can pass `&mut self.cpu` and `&mut self.bus` as two
  disjoint field borrows. That single signature choice is what makes the rest work.
- **Peripherals never call back into the CPU.** The UART accumulates transmitted bytes,
  and the run loop drains them into an `Observer` after each instruction. Callbacks are
  what create the cycle; returning data breaks it.

Nothing in Phase 1 needed to bend these. If something later genuinely does — the CAN
fabric shared across nodes is the likely candidate — the answer is indices into a slab,
not `Rc`.

### Where the type system does work Zig could not

- **`Inst` is an enum whose variants name their operands.** The per-format
  destination-register table above is encoded in the type, so the executor's `match` can
  only read `dst`, never guess between `r`, `s` and `t`.
- **`Reg` is a newtype** constructed by masking to 4 bits, so register-file indexing is
  infallible and a raw immediate cannot be passed where a register belongs.
- **`InstSize` is an enum**, not a `u32`, which makes `decode` total: there is no "size 5"
  case to panic on.
- **`DecodeError` keeps `Illegal` and `Unsupported` apart**, with `Unsupported` carrying a
  `&'static str` naming the missing feature ("call4/8/12: requires register windows"). A
  failing run tells you immediately whether you found a bug or hit a known boundary.
- **Exhaustive `match`** means adding an `Inst` variant is a compile error everywhere it
  must be handled — the decoder, the executor and `Decoded::mnemonic`.

What was genuinely nicer in Zig: `comptime` decode-table generation, and packed structs
with a guaranteed bit layout. Neither mattered enough here to miss.

### `Decoded::mnemonic` exists because `Inst` is deliberately lossy

`Inst` groups by semantics — one `Alu` variant for five operations, one `Load` for four
widths — so the executor stays small. But a trace should say `s32i.n`, not "a 32-bit
store", so the exact mnemonic is recovered from the variant plus the size. Note that
`addmi` decodes to `Inst::Addi` and therefore traces as `addi`; its scaled immediate is
what distinguishes it, and the trace shows that.

### `wrapping_add` / `wrapping_sub` everywhere, on purpose

Every address computation and every ALU operation wraps, because that is what the
hardware does. Plain `+` would panic in a debug build the first time firmware overflows a
register — which is normal, expected behaviour for a CPU. The Zig version used `+%` and
`-%` for the same reason.

### Tests are colocated, and the fixture is compiled in

`#[cfg(test)] mod tests` at the bottom of each module, so a module and its tests move
together. `examples/hello.elf` is pulled in with `include_bytes!`, so `cargo test` needs
no Xtensa toolchain even though it runs genuine GCC output.

### Formatting

`rustfmt.toml` sets `use_small_heuristics = "Max"`. The decoder tables and the SoC memory
map read as one-line records; default rustfmt explodes them to one field per line and the
tabular structure disappears.

---

## Where the seams are for Phase 2

- `soc/esp32.rs` holds every chip-specific constant, and `esp32::decode` is the only
  place an address is interpreted. An S3 profile is a sibling module with its own
  `decode`.
- `cpu/decode.rs` returns `DecodeError::Unsupported` for exactly the instructions Phase 2
  must add, each with a `what` string. `grep -o 'unsupported(word, "[^"]*"' ` gives the
  work list.
- `machine.rs` is the "Node" boundary the orchestrator will multiply, and `Observer` is
  where a scheduler or a snapshotter hooks in.
- `Machine::run` takes a step budget, which is where the virtual clock replaces it.
