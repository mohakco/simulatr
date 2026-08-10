# simulatr — Plan & Scope

> Test real firmware across a multi-MCU system. Inject sensor readings and watch your
> system react over CAN, Ethernet, and BLE. Design, program, test, iterate — in minutes,
> not weeks.

A deterministic, headless, agent-drivable simulator for ESP32-class microcontroller
networks, written in Rust.

---

## 1. Decisions

| Question | Decision |
|---|---|
| North star | **Ship the product.** This is a real tool, not a learning exercise. |
| Fidelity | **Real ISA emulation.** We interpret Xtensa machine code. Firmware is an unmodified `.elf` from ESP-IDF. |
| First target chip | **ESP32 classic (Xtensa LX6)**, then ESP32-S3 (LX7). |
| Multi-MCU | Heterogeneous is the goal; the node/CPU boundary is abstract from day one. v1 ships one CPU model. |
| Language | **Rust** (stable, currently 1.97.1). |
| Interface | Phase 1 = CLI. Phase 2 = MCP server. Native desktop UI in a later phase. |

### Why Rust, and why we switched off Zig after Phase 1

Phase 1 was built in Zig and worked — it ran a real GCC-built ESP32 ELF and printed
`HELLO`. It is preserved at the git tag `zig-phase1`. We moved because the north star
changed from "learn Zig" to "ship a product":

- **Pre-1.0 churn is a tax with no upside on a multi-year product.** Zig 0.16 landed
  April 2026 and reworked all of I/O around `std.Io`; 0.17 reworks the build system.
  That is a rewrite of the I/O and CLI layers roughly every six months.
- **A native desktop UI is on the roadmap.** Rust has Tauri, egui and iced. Zig has
  nothing production-ready. This alone was close to decisive.
- **Ecosystem where it matters**: MCP, serialization, async networking, CLI.
- **The original reason for avoiding Rust does not apply here.** An ISA emulator is
  fixed-width integer math, array indexing and large `match` statements — it needs
  essentially zero `unsafe`.

What Zig was genuinely better at, which we are giving up: `comptime` decode-table
generation, packed structs with exact bit layout, and no borrow checker to fight over
machine state. See "The one real Rust design risk" below.

### Why ESP32 classic before S3

- LX7 is a **superset** of LX6 (adds PIE/SIMD + extra load-store). Fewer instructions to
  write, and all of it carries forward.
- ESP32 classic has an **on-chip Ethernet MAC**. The S3 dropped it — S3 Ethernet is an
  external W5500/DM9051 over SPI, i.e. a whole extra device model.
- Espressif's QEMU fork supports both, so the differential-testing oracle works either way.

The SoC is a **profile** (memory map + peripheral set + CPU config). Adding the S3 later
means a new profile plus the LX7-only instructions — not a rewrite.

---

## 2. Hard constraints (know these now)

**Firmware is built by `xtensa-esp-elf-gcc`, not by us.** Neither Rust nor Zig can target
Xtensa. Installed at `~/.local/opt/xtensa-esp-elf/bin`. Note the required
`-mdynconfig=.../xtensa_esp32.so` flag — the toolchain's default core is generic
*big-endian* and produces an ELF we correctly reject.

**Wi-Fi is out of scope, permanently.** The ESP32 Wi-Fi stack is a closed binary blob
talking to an undocumented radio block. There is no clean seam. Do not plan around it.

**BLE is in scope, via HCI.** ESP-IDF's Bluetooth host (NimBLE/Bluedroid) talks to the
controller through **VHCI** — standard, documented HCI packets. We implement a *virtual
BLE controller* answering HCI commands against a virtual air medium. The real host stack
runs unmodified on our emulated CPU. This is the seam that makes BLE tractable.

**Timing is approximate, not cycle-accurate.** We model instruction *counts* and
peripheral *deadlines*, not pipeline stalls or cache misses. Good enough for protocol and
logic bugs; useless for tight bit-banging. Say so in the README.

---

## 3. Architecture

```
                      ┌──────────────────────────────────────┐
                      │  CLI   │   MCP server   │   Desktop   │
                      └───────────────────┬──────────────────┘
                                          │
                      ┌───────────────────▼──────────────────┐
                      │   Orchestrator / virtual clock       │
                      │   deterministic lockstep scheduler   │
                      └───┬───────────────┬──────────────┬───┘
                          │               │              │
                    ┌─────▼────┐    ┌─────▼────┐   ┌─────▼────┐
                    │  Node A  │    │  Node B  │   │  Node C  │
                    └─────┬────┘    └─────┬────┘   └─────┬────┘
                          │               │              │
                      ┌───▼───────────────▼──────────────▼───┐
                      │  Fabric: CAN bus │ Ethernet │ BLE air │
                      └──────────────────────────────────────┘
```

A **Node** is one CPU + one memory bus + one SoC profile's peripherals. The orchestrator
advances all nodes in lockstep on a shared virtual clock, so a run is byte-for-byte
reproducible given the same seed and inputs. Determinism is *the product* — it is what
makes an agent's iterate-and-fix loop converge instead of chasing ghosts.

### Cargo workspace layout

| Crate | Responsibility |
|---|---|
| `simulatr-core` | CPU, decoder, bus, peripherals, ELF loader, scheduler. **Zero dependencies, no host I/O, no `unsafe`.** This is what compiles to WASM later. |
| `simulatr-cli` | The `simulatr` binary. `clap`, file I/O, stdout/stderr wiring. |
| `simulatr-mcp` | MCP server binary (Phase 8). |
| `simulatr-ui` | Native desktop app (later). |

Within `simulatr-core`, module layout mirrors the Zig version, which was well-factored:
`cpu/` (decode, core), `mem/` (bus), `soc/` (chip profiles), `periph/`, `load/` (elf),
`fabric/`, `sched/`, `trace/`.

**`simulatr-core` stays dependency-free on purpose.** It keeps WASM builds small,
guarantees determinism (no crate can smuggle in threads, time or randomness), and makes
snapshot/restore tractable. Hand-rolling ELF parsing is ~300 lines and already designed.

### The one real Rust design risk

Emulator state is a cyclic mutable graph: peripherals raise interrupts on the CPU, the CPU
reads through the bus, the bus dispatches to peripherals. This is the classic borrow
checker fight and the most common way Rust emulators end up as `Rc<RefCell<>>` soup.

**Decided up front, to avoid that:**

- `Machine` owns everything. `Bus` owns its peripherals directly; nothing is shared.
- The CPU does **not** own the bus. `Cpu::step(&mut self, bus: &mut Bus)` takes it as a
  parameter. Two disjoint `&mut` borrows, no cell types.
- Peripherals never call back into the CPU. They **return** events (`Irq(n)`) which the
  step loop applies. Callbacks are what create the cycle; returning data breaks it.
- If something genuinely needs shared identity later (the CAN fabric across nodes), use
  **indices into a slab**, not `Rc`.

Deviating from this is allowed, but it goes in `DECISIONS.md` with a reason.

### Dependencies (deliberately few)

`clap` (CLI), `serde` + `serde_json` (trace + MCP), MCP SDK at Phase 8 — verify the
current official Rust SDK then rather than pinning a guess now. Nothing in `simulatr-core`.

---

## 4. Phase 1 — port the POC to Rust

Phase 1 is **already specified and already solved once**. `docs/PHASE1-NOTES.md` contains
the full Xtensa encoding reference discovered during the Zig build, and `DECISIONS.md`
records every design choice with reasoning. Both are language-independent. This is a port
against a known-good spec, not a fresh design.

**Goal, unchanged:** `simulatr run examples/hello.elf` prints `HELLO`, by actually
decoding and executing Xtensa instructions.

- [ ] Cargo workspace, `simulatr-core` + `simulatr-cli`, `cargo test` green
- [ ] SoC profile: ESP32 memory map + UART0 registers
- [ ] Flat memory model: IRAM + DRAM, byte/half/word access, alignment checks
- [ ] ELF32 loader: header parse, PT_LOAD segments, entry point, little-endian check
- [ ] Decoder for the ~25-30 opcode subset, both 24-bit and 16-bit narrow forms
- [ ] Execute loop: PC, 16 registers, step budget, four halt conditions
- [ ] MMIO dispatch: UART0 TX FIFO writes emit bytes to stdout
- [ ] CLI: `simulatr run <elf>`, `--trace` (JSON Lines to stderr)
- [ ] `examples/hello.elf` embedded in the test binary via `include_bytes!`, so
      `cargo test` needs no Xtensa toolchain

**Definition of done:** `cargo test` all green including the end-to-end HELLO test, and
`simulatr run examples/hello.elf` prints `HELLO`.

**Non-goals, unchanged:** register windows, interrupts, exceptions, cache/MMU, flash,
second core, FreeRTOS, any peripheral but UART TX.

---

## 5. Phases 2+ (sketch)

| Phase | Milestone | Unlocks |
|---|---|---|
| 2 | Register windows, exceptions, interrupt matrix, TIMG + SYSTIMER, full core ISA | Real compiled C runs; the windowed ABI is *the* hard Xtensa concept |
| 3 | Flash + cache MMU, ESP image format, ROM stub | A real ESP-IDF `hello_world` boots FreeRTOS and prints |
| 4 | GPIO, SPI, I2C + virtual sensor devices; **sensor injection API** | The "inject a reading, watch it react" half of the pitch |
| 5 | Multi-node orchestrator + **TWAI/CAN fabric** | The "multi-MCU" half of the pitch |
| 6 | EMAC + Ethernet switch; virtual BLE controller over VHCI | Full three-bus story |
| 7 | Determinism surface: replay, assertions, snapshot/restore, GDB stub, JSON everywhere | Agents can iterate |
| 8 | **MCP server** | Claude Code / Codex / amp drive it natively |
| 9 | ESP32-S3 profile (LX7 + PIE), then a RISC-V node (ESP32-C3) | Heterogeneous |
| 10 | Native desktop UI (Tauri or egui) | The shipped product |

---

## 6. Testing strategy

1. **Unit tests** — decoder round-trips, memory edge cases. From the first commit.
2. **Firmware fixtures** — real GCC-built `.elf` files, checked in, embedded with
   `include_bytes!`, asserted on output and instruction count.
3. **Differential testing against Espressif QEMU** — the big one. Run the same ELF in
   QEMU and simulatr, both under GDB, compare register state instruction by instruction.
   First divergence is our bug, with an exact address. Build it at Phase 2.

---

## 7. ESP32 concept ladder

What to actually understand, in the order the phases force you to learn it:

| Phase | Concepts |
|---|---|
| 1 | Harvard buses, memory-mapped I/O, ELF loading, variable-length instruction encoding, literal pools |
| 2 | **Register windows** (the defining Xtensa oddity), exception vectors, the interrupt matrix, PS/EPC special registers |
| 3 | Flash cache + MMU pages, the ESP image format, the two-stage boot flow, FreeRTOS scheduling |
| 4 | Peripheral register banks, DMA, clock trees, GPIO matrix routing |
| 5 | TWAI/CAN framing, arbitration, bit timing |
| 6 | EMAC descriptors, HCI packet format, the BLE link layer |

---

## 8. Open questions

- Dual-core ESP32: model both PRO and APP cores, or single-core first? Leaning
  single-core through Phase 3 (ESP-IDF supports `FREERTOS_UNICORE`).
- Interpreter performance: naive `match` dispatch first, then measure. Threaded dispatch
  or a decode cache only if a profiler demands it. **Do not optimise in Phase 1.**
- Sensor injection format: scripted timeline file, or live commands over a control socket?
  Probably both, timeline first.

---

## 9. References

- [Xtensa ISA Reference Manual](https://0x04.net/~mwk/doc/xtensa.pdf) — authority for the decoder
- [ESP32 Technical Reference Manual](https://www.espressif.com/sites/default/files/documentation/esp32_technical_reference_manual_en.pdf)
- [ESP32-S3 Technical Reference Manual](https://www.espressif.com/sites/default/files/documentation/esp32-s3_technical_reference_manual_en.pdf)
- [Espressif QEMU fork](https://github.com/espressif/qemu) — differential-testing oracle
- [Ebiroll/qemu_esp32](https://github.com/Ebiroll/qemu_esp32) — prior art on ROM behaviour
- `docs/PHASE1-NOTES.md` — our own Xtensa encoding findings. Read before touching the decoder.
- git tag `zig-phase1` — the working Zig implementation, for reference during the port
