//! One emulated node: a CPU, a memory bus, and the SoC's peripherals.
//!
//! Phase 1 has exactly one, driven directly by the CLI. Phase 5's orchestrator will own
//! several and advance them in lockstep on a shared virtual clock, which is why the run
//! loop lives here rather than in the command-line code.
//!
//! `Machine` owns everything; nothing is shared, and there is no interior mutability.
//! `Cpu::step` borrows the bus as a parameter, so the two disjoint field borrows below
//! are all the aliasing the emulator ever needs.

use crate::cpu::core::{Cpu, Executed, Fault, HaltReason};
use crate::load::elf::{self, LoadError, LoadResult};
use crate::mem::bus::Bus;
use crate::soc::esp32;

/// Default instruction budget: generous enough for any Phase 1 firmware, small enough
/// that a mistake finishes in well under a second.
pub const DEFAULT_STEP_BUDGET: u64 = 10_000_000;

/// Callbacks the run loop makes as it goes.
///
/// This is the *only* direction data flows out of the core during a run, and it is
/// strictly outward: peripherals accumulate state, the run loop collects it and hands it
/// here. Nothing an observer does can reach back into the CPU, which is what keeps the
/// machine a tree of owned values.
pub trait Observer {
    /// Called once per retired instruction, after its effects are visible in `regs`.
    fn on_step(&mut self, _step: u64, _executed: &Executed, _regs: &[u32; 16]) {}

    /// Called with whatever the UART transmitted during the last instruction.
    fn on_uart_tx(&mut self, _bytes: &[u8]) {}
}

/// Discards everything, for runs that only care about the final state.
impl Observer for () {}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct RunSummary {
    /// Where the PC stopped. On a clean exit this is [`HALT_ADDRESS`](crate::cpu::core::HALT_ADDRESS).
    pub final_pc: u32,
    pub steps: u64,
    pub halt_reason: HaltReason,
    pub bytes_transmitted: u64,
}

impl RunSummary {
    /// True when the firmware finished the way firmware finishes.
    pub fn is_clean_exit(&self) -> bool {
        matches!(self.halt_reason, HaltReason::Returned | HaltReason::SpinLoop)
    }

    pub fn fault(&self) -> Option<Fault> {
        match self.halt_reason {
            HaltReason::Fault(fault) => Some(fault),
            _ => None,
        }
    }
}

#[derive(Debug, Default)]
pub struct Machine {
    cpu: Cpu,
    bus: Bus,
}

impl Machine {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cpu(&self) -> &Cpu {
        &self.cpu
    }

    pub fn bus(&self) -> &Bus {
        &self.bus
    }

    pub fn bus_mut(&mut self) -> &mut Bus {
        &mut self.bus
    }

    /// Load an ELF image and point the CPU at its entry symbol.
    pub fn load_elf(&mut self, image: &[u8]) -> Result<LoadResult, LoadError> {
        let result = elf::load(&mut self.bus, image)?;
        self.cpu.reset(result.entry, esp32::initial_stack_pointer());
        Ok(result)
    }

    /// Run until a halt condition fires or `budget` instructions have retired.
    pub fn run<O: Observer>(&mut self, budget: u64, observer: &mut O) -> RunSummary {
        while !self.cpu.is_halted() {
            if self.cpu.steps() >= budget {
                self.cpu.halt_with(HaltReason::StepBudgetExhausted);
                break;
            }

            // Two disjoint field borrows: this is the whole trick that keeps the
            // emulator free of `Rc<RefCell<_>>`.
            let executed = match self.cpu.step(&mut self.bus) {
                Ok(Some(executed)) => executed,
                // Either the CPU halted before executing anything, or it faulted; both
                // are already recorded in `cpu.halt`.
                Ok(None) | Err(_) => break,
            };

            observer.on_step(self.cpu.steps(), &executed, self.cpu.regs());

            // Peripherals return events rather than calling back; drain them here.
            let uart = self.bus.uart_mut();
            if !uart.pending().is_empty() {
                let bytes = uart.take_pending();
                observer.on_uart_tx(&bytes);
            }
        }

        // A fault or an early halt can leave bytes buffered from the last instruction.
        let uart = self.bus.uart_mut();
        if !uart.pending().is_empty() {
            let bytes = uart.take_pending();
            observer.on_uart_tx(&bytes);
        }

        RunSummary {
            final_pc: self.cpu.pc(),
            steps: self.cpu.steps(),
            halt_reason: self.cpu.halt().unwrap_or(HaltReason::StepBudgetExhausted),
            bytes_transmitted: self.bus.uart().transmitted(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Collects everything a run emits, so tests can assert on output without any host
    /// I/O.
    #[derive(Default)]
    struct Recorder {
        uart: Vec<u8>,
        mnemonics: Vec<&'static str>,
    }

    impl Observer for Recorder {
        fn on_step(&mut self, _step: u64, executed: &Executed, _regs: &[u32; 16]) {
            self.mnemonics.push(executed.decoded.mnemonic());
        }

        fn on_uart_tx(&mut self, bytes: &[u8]) {
            self.uart.extend_from_slice(bytes);
        }
    }

    /// The Phase 1 firmware fixture: a real `xtensa-esp-elf-gcc` build of
    /// `examples/hello.S`, embedded at compile time so `cargo test` needs no Xtensa
    /// toolchain. Regenerate it with `examples/build.sh`.
    const HELLO_ELF: &[u8] = include_bytes!("../../../examples/hello.elf");

    #[test]
    fn the_vertical_slice_a_real_gcc_elf_prints_hello() {
        let mut machine = Machine::new();
        let mut recorder = Recorder::default();

        let loaded = machine.load_elf(HELLO_ELF).unwrap();
        assert_eq!(loaded.entry, 0x4008_0008);
        assert_eq!(loaded.segments_loaded, 1);

        let summary = machine.run(DEFAULT_STEP_BUDGET, &mut recorder);

        // hello.S ends in `j .` rather than `ret`, which is how firmware actually
        // finishes.
        assert_eq!(summary.halt_reason, HaltReason::SpinLoop);
        assert_eq!(recorder.uart, b"HELLO");
        assert_eq!(summary.bytes_transmitted, 5);
        assert_eq!(summary.steps, 29);

        // GCC compiled the loop body into narrow forms unprompted, so this fixture also
        // exercises the 16-bit decode path against a real assembler.
        assert!(recorder.mnemonics.contains(&"movi.n"));
        assert!(recorder.mnemonics.contains(&"s32i.n"));
        assert!(recorder.mnemonics.contains(&"addi.n"));
        assert_eq!(recorder.mnemonics[0], "l32r");
    }

    #[test]
    fn uart_bytes_are_delivered_as_they_are_transmitted() {
        let mut machine = Machine::new();

        /// Records which step each byte arrived on, to prove output is not buffered to
        /// the end of the run.
        #[derive(Default)]
        struct Timeline {
            steps: Vec<u64>,
            step: u64,
        }

        impl Observer for Timeline {
            fn on_step(&mut self, step: u64, _e: &Executed, _r: &[u32; 16]) {
                self.step = step;
            }
            fn on_uart_tx(&mut self, bytes: &[u8]) {
                for _ in bytes {
                    self.steps.push(self.step);
                }
            }
        }

        let mut timeline = Timeline::default();
        machine.load_elf(HELLO_ELF).unwrap();
        machine.run(DEFAULT_STEP_BUDGET, &mut timeline);

        assert_eq!(timeline.steps.len(), 5);
        // Five distinct instructions, one per loop iteration.
        assert!(timeline.steps.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn a_machine_can_be_reused_for_a_second_image() {
        let mut machine = Machine::new();
        machine.load_elf(HELLO_ELF).unwrap();
        machine.run(DEFAULT_STEP_BUDGET, &mut ());

        machine.load_elf(HELLO_ELF).unwrap();
        let summary = machine.run(DEFAULT_STEP_BUDGET, &mut ());

        assert_eq!(summary.halt_reason, HaltReason::SpinLoop);
        assert_eq!(summary.steps, 29);
        // The counter is cumulative across loads: ten bytes over two runs.
        assert_eq!(summary.bytes_transmitted, 10);
    }

    #[test]
    fn a_budget_smaller_than_the_program_stops_it_mid_flight() {
        let mut machine = Machine::new();
        let mut recorder = Recorder::default();
        machine.load_elf(HELLO_ELF).unwrap();

        let summary = machine.run(5, &mut recorder);
        assert_eq!(summary.halt_reason, HaltReason::StepBudgetExhausted);
        assert_eq!(summary.steps, 5);
        assert_eq!(recorder.uart, b"H");
        assert!(!summary.is_clean_exit());
    }
}
