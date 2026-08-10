# simulatr — Plan & Scope

> Test real firmware across a multi-MCU system. Inject sensor readings and watch your
> system react over CAN, Ethernet, and BLE. Design, program, test, iterate — in minutes,
> not weeks.

A deterministic, headless, agent-drivable simulator for ESP32-class microcontroller
networks, written in Zig.

---

## 1. Decisions already made

| Question | Decision |
|---|---|
| Fidelity | **Real ISA emulation.** We interpret Xtensa machine code. Firmware is an unmodified `.elf` from ESP-IDF. |
| First target chip | **ESP32 classic (Xtensa LX6)**, then ESP32-S3 (LX7). |
| Multi-MCU | Heterogeneous is the goal; the node/CPU boundary is abstract from day one. v1 ships one CPU model. |
| Language | Zig for the simulator. (Zig has no Xtensa backend — firmware comes from `xtensa-esp-elf-gcc`.) |
| Interface | Phase 1 = CLI. Phase 2 = MCP server binary. |
| Working style | Explain-as-we-go. Every new Zig construct and ESP32 concept gets explained the first time it appears. |

### Why ESP32 classic before S3

- LX7 is a **superset** of LX6 (adds PIE/SIMD + extra load-store). Fewer instructions to
  write, and all of it carries forward.
- ESP32 classic has an **on-chip Ethernet MAC**. The S3 dropped it — S3 Ethernet is an
  external W5500/DM9051 over SPI, i.e. a whole extra device model.
- Espressif's QEMU fork supports both, so the differential-testing oracle works either way.

The SoC is a **profile** (memory map + peripheral set + CPU config). Adding the S3 later
means writing a new profile plus the LX7-only instructions — not a rewrite.

---

## 2. Hard constraints (know these now)

**Zig cannot compile for Xtensa.** LLVM's Xtensa backend is not exposed by Zig. We write
the emulator in Zig; test firmware is built with Espressif's GCC toolchain. This is not a
problem, but it means the ESP toolchain is a Phase-1 dependency.

**Wi-Fi is out of scope, permanently.** The ESP32 Wi-Fi stack is a closed binary blob that
talks to an undocumented radio block. There is no clean seam. Do not plan around it.

**BLE is in scope, via HCI.** ESP-IDF's Bluetooth host (NimBLE/Bluedroid) talks to the
controller through **VHCI** — standard, documented HCI packets. We implement a *virtual BLE
controller* that answers HCI commands and speaks to a virtual air medium. The real host
stack runs unmodified on our emulated CPU. This is the seam that makes BLE tractable.

**Timing is approximate, not cycle-accurate.** We model instruction *counts* and peripheral
*deadlines*, not pipeline stalls or cache misses. Good enough for protocol and logic bugs;
useless for tight bit-banging timing. State this in the README so nobody is surprised.

---

## 3. Architecture

```
                      ┌──────────────────────────────────────┐
                      │  CLI  (phase 1)   MCP server (ph. 2) │
                      └───────────────────┬──────────────────┘
                                          │
                      ┌───────────────────▼──────────────────┐
                      │   Orchestrator / virtual clock       │
                      │   deterministic lockstep scheduler   │
                      └───┬───────────────┬──────────────┬───┘
                          │               │              │
                    ┌─────▼────┐    ┌─────▼────┐   ┌─────▼────┐
                    │  Node A  │    │  Node B  │   │  Node C  │
                    │ ESP32    │    │ ESP32    │   │  ...     │
                    └─────┬────┘    └─────┬────┘   └─────┬────┘
                          │               │              │
                      ┌───▼───────────────▼──────────────▼───┐
                      │  Fabric: CAN bus │ Ethernet │ BLE air │
                      └──────────────────────────────────────┘
```

A **Node** is: one CPU model + one memory bus + one SoC profile's peripherals.
The orchestrator advances all nodes in lockstep on a shared virtual clock, so a run is
byte-for-byte reproducible given the same seed and inputs. Determinism is a *feature*, not
a nicety — it's what makes an agent's iterate-and-fix loop actually converge.

### Module layout

| Module | Responsibility |
|---|---|
| `cpu/` | Xtensa decoder, executor, register windows, special registers, exceptions, interrupts |
| `mem/` | Address decode, RAM/ROM regions, MMIO dispatch table, flash + cache MMU |
| `soc/` | Per-chip profile: memory map, peripheral instantiation, interrupt matrix |
| `periph/` | UART, GPIO, TIMG, SYSTIMER, SPI, I2C, TWAI(CAN), EMAC, GDMA, eFuse, RTC |
| `dev/` | Virtual off-chip devices: sensors, EEPROMs, W5500, BLE peer models |
| `fabric/` | CAN bus arbitration, Ethernet switch, BLE air medium + collision model |
| `load/` | ELF32 loader, ESP image format, symbol table (for tracing + assertions) |
| `sched/` | Virtual clock, event queue, node lockstep |
| `trace/` | Structured event log, JSON output, waveform export |
| `dbg/` | GDB remote-serial-protocol stub |
| `cli/` | Command surface |
| `mcp/` | Phase 2 |

---

## 4. Phase 1 — POC (minimal vertical slice)

**Goal: `simulatr run hello.elf` prints `HELLO` to your terminal, by actually decoding and
executing Xtensa instructions.**

Nothing more. No FreeRTOS, no interrupts, no second node, no CAN. One CPU, one peripheral,
one command. This proves the whole vertical slice is real and gives us something to iterate
on within weeks rather than months.

**Scope:**

- [ ] Zig 0.16 installed; `zig build` skeleton; first `zig build test` passing
- [ ] Espressif GCC toolchain installed (firmware side only)
- [ ] A ~30-line hand-written Xtensa assembly firmware that writes bytes to the UART0 TX
      FIFO register in a loop, then spins
- [ ] ELF32 loader: parse headers, load PT_LOAD segments into simulated memory, find entry
- [ ] Flat memory model: IRAM + DRAM regions, byte/half/word access, alignment checks
- [ ] Instruction decoder for the ~25–30 instruction subset that firmware actually uses
      (`l32i`, `l32r`, `s32i`, `movi`, `add`, `addi`, `sub`, `beq`/`bne`/`bltu`, `j`,
      `call0`/`ret`, `memw`, `nop`, plus the narrow 16-bit forms)
- [ ] Execute loop with a PC, 16 address registers, and a step budget
- [ ] MMIO decode: writes to the UART0 TX FIFO address emit a byte to stdout
- [ ] `simulatr run <elf>` and `simulatr run <elf> --trace` (JSON instruction trace)

**Explicit non-goals for Phase 1:** register windows, interrupts, exceptions, cache/MMU,
the second CPU core, any real ESP-IDF binary, any peripheral except UART TX.

**Definition of done:** running the POC prints `HELLO`, and `--trace` emits a JSON line per
instruction that you can read and understand.

---

## 5. Phases 2+ (sketch — refined as we learn)

| Phase | Milestone | Unlocks |
|---|---|---|
| 2 | Register windows, exceptions, interrupt matrix, TIMG + SYSTIMER, full core ISA | Real compiled C runs; the windowed ABI is *the* hard Xtensa concept |
| 3 | Flash + cache MMU, ESP image format, ROM stub | A real `hello_world` ESP-IDF binary boots FreeRTOS and prints |
| 4 | GPIO, SPI, I2C + virtual sensor devices; **sensor injection API** | The "inject a reading, watch it react" half of the pitch |
| 5 | Multi-node orchestrator + **TWAI/CAN fabric** | The "multi-MCU" half of the pitch |
| 6 | EMAC + Ethernet switch; virtual BLE controller over VHCI | Full three-bus story |
| 7 | Agent surface: deterministic replay, assertions, snapshot/restore, GDB stub, JSON everywhere | Agents can iterate |
| 8 | **MCP server binary** | Claude Code / Codex / amp drive it natively |
| 9 | ESP32-S3 profile (LX7 + PIE), then a RISC-V node (ESP32-C3) | Heterogeneous |

---

## 6. Testing strategy

Three layers, introduced as soon as each becomes possible:

1. **Zig unit tests** — decoder round-trips, memory access edge cases. From day one.
2. **Firmware fixtures** — small `.elf` files with known-correct output, run in CI.
3. **Differential testing against Espressif QEMU** — this is the big one. Run the same ELF
   in QEMU and in simulatr, both under GDB, and compare register state instruction by
   instruction. First divergence = our bug, with an exact address. This turns "why is my
   emulator wrong" from days of guessing into minutes. Build it around Phase 2.

---

## 7. Zig learning track

Each phase is chosen partly for what it teaches. Rough mapping:

| Phase | Zig concepts |
|---|---|
| 1 | build.zig, slices vs arrays, `comptime`, packed structs, error unions, `defer`, testing, allocators |
| 2 | tagged unions, `switch` exhaustiveness, bit manipulation, `inline` loops for decode tables |
| 3 | reader/writer interfaces, `std.Io` (new in 0.16), file + binary parsing |
| 4–5 | interfaces via vtables/`anyopaque`, generic containers, arena allocators |
| 6–7 | serialization, snapshotting, JSON, process/socket I/O |
| 8 | building a protocol server, async patterns |

---

## 8. Open questions

- Interpreter design: naive switch dispatch first, then measure. Threaded dispatch or a
  decode cache only if the profiler says so. **Do not optimise in Phase 1.**
- Dual-core ESP32: model both PRO and APP cores, or single-core first? Leaning single-core
  through Phase 3, since ESP-IDF can be configured single-core.
- Sensor injection format: scripted timeline file, or live commands over a control socket?
  Probably both, timeline first.

---

## 9. References

- [Xtensa ISA Reference Manual](https://0x04.net/~mwk/doc/xtensa.pdf) — the primary source for the decoder
- [ESP32 Technical Reference Manual](https://www.espressif.com/sites/default/files/documentation/esp32_technical_reference_manual_en.pdf)
- [ESP32-S3 Technical Reference Manual](https://www.espressif.com/sites/default/files/documentation/esp32-s3_technical_reference_manual_en.pdf)
- [Espressif QEMU fork](https://github.com/espressif/qemu) — differential-testing oracle
- [ESP-IDF QEMU guide](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/tools/qemu.html)
- [Ebiroll/qemu_esp32](https://github.com/Ebiroll/qemu_esp32) — prior art, notes on ROM behaviour
- [Zig 0.16 release notes](https://ziglang.org/devlog/2026/) — `std.Io` changes
