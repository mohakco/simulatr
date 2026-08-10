//! The `simulatr` binary: everything `simulatr-core` deliberately refuses to do —
//! reading files, writing streams, and exiting with a status code.
//!
//! # Which stream gets what
//!
//! **stdout is the emulated UART, and nothing else.** `simulatr run hello.elf > out.txt`
//! produces exactly the bytes the firmware transmitted, which is what makes the output
//! testable and diffable.
//!
//! Everything simulatr says about itself, including the `--trace` JSON, goes to stderr:
//!
//! ```text
//! simulatr run examples/hello.elf --trace 2> trace.jsonl
//! ```

use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use simulatr_core::machine::Observer;
use simulatr_core::soc::esp32;
use simulatr_core::{DEFAULT_STEP_BUDGET, Executed, HaltReason, Machine, RunSummary, trace};

/// Sanity bound on the image size. Phase 1 firmware is a few kilobytes.
const MAX_ELF_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Parser)]
#[command(
    name = "simulatr",
    about = "A deterministic ESP32 simulator",
    version,
    // The UART owns stdout, so clap's own output must not compete for it on error paths.
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Load an ELF and execute it.
    Run {
        /// Firmware image, an unmodified xtensa-esp-elf ELF32 executable.
        elf: PathBuf,

        /// Emit one JSON object per executed instruction on stderr.
        #[arg(long)]
        trace: bool,

        /// Instruction budget for the run.
        #[arg(long, value_name = "N", default_value_t = DEFAULT_STEP_BUDGET)]
        max_steps: u64,
    },
}

/// Exit codes, so scripts can tell the outcomes apart.
mod exit {
    pub const OK: u8 = 0;
    /// Bad arguments, or an image that could not be read or loaded.
    pub const USAGE: u8 = 1;
    /// The step budget ran out: the firmware was still going.
    pub const BUDGET: u8 = 2;
    /// The firmware faulted.
    pub const FAULT: u8 = 3;
}

fn main() -> ExitCode {
    let Cli { command } = Cli::parse();
    let Command::Run { elf, trace, max_steps } = command;

    match run(&elf, trace, max_steps) {
        Ok(code) => ExitCode::from(code),
        Err(err) => {
            eprintln!("simulatr: {err}");
            ExitCode::from(exit::USAGE)
        }
    }
}

fn run(path: &Path, tracing: bool, max_steps: u64) -> Result<u8, Box<dyn std::error::Error>> {
    let image = read_image(path)?;

    let mut machine = Machine::new();
    let loaded =
        machine.load_elf(&image).map_err(|err| format!("cannot load {}: {err}", path.display()))?;

    let stdout = io::stdout();
    let stderr = io::stderr();
    let mut sink = Streams {
        uart: BufWriter::new(stdout.lock()),
        trace: BufWriter::new(stderr.lock()),
        tracing,
        line: String::new(),
    };

    let summary = machine.run(max_steps, &mut sink);

    // The UART's bytes must reach the terminal before the summary appears on stderr, or
    // the two interleave confusingly.
    sink.uart.flush()?;
    sink.trace.flush()?;
    drop(sink);

    report(loaded.entry, &summary);
    Ok(exit_code(&summary))
}

fn read_image(path: &Path) -> Result<Vec<u8>, String> {
    let metadata =
        std::fs::metadata(path).map_err(|err| format!("cannot read {}: {err}", path.display()))?;
    if metadata.len() > MAX_ELF_BYTES {
        return Err(format!(
            "{} is {} bytes, larger than the {MAX_ELF_BYTES}-byte limit",
            path.display(),
            metadata.len()
        ));
    }
    std::fs::read(path).map_err(|err| format!("cannot read {}: {err}", path.display()))
}

/// Routes what the emulator produces to the host's two output streams.
struct Streams<U: Write, T: Write> {
    uart: U,
    trace: T,
    tracing: bool,
    /// Reused across instructions so tracing does not allocate per line.
    line: String,
}

impl<U: Write, T: Write> Observer for Streams<U, T> {
    fn on_step(&mut self, step: u64, executed: &Executed, regs: &[u32; 16]) {
        if !self.tracing {
            return;
        }
        self.line.clear();
        trace::write_json_line(&mut self.line, step, executed, regs);
        // A closed pipe must not change the emulated CPU's behaviour: determinism beats
        // error reporting here, and the run's exit code still reflects the firmware.
        let _ = self.trace.write_all(self.line.as_bytes());
    }

    fn on_uart_tx(&mut self, bytes: &[u8]) {
        let _ = self.uart.write_all(bytes);
    }
}

fn report(entry: u32, summary: &RunSummary) {
    eprintln!(
        "simulatr: {name}, entry {entry:#010x}, {steps} instructions, \
         {bytes} bytes transmitted, halt: {halt}",
        name = esp32::NAME,
        steps = summary.steps,
        bytes = summary.bytes_transmitted,
        halt = summary.halt_reason,
    );
    if let Some(fault) = summary.fault() {
        eprintln!("simulatr: fault at pc {:#010x}: {fault}", summary.final_pc);
    }
}

fn exit_code(summary: &RunSummary) -> u8 {
    match summary.halt_reason {
        // Both mean "the firmware finished the way firmware finishes".
        HaltReason::Returned | HaltReason::SpinLoop => exit::OK,
        HaltReason::StepBudgetExhausted => exit::BUDGET,
        HaltReason::Fault(_) => exit::FAULT,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;
    use simulatr_core::Fault;
    use simulatr_core::cpu::decode::DecodeError;

    /// The same fixture the core tests use: a real xtensa-esp-elf-gcc build of
    /// examples/hello.S.
    const HELLO_ELF: &[u8] = include_bytes!("../../../examples/hello.elf");

    #[test]
    fn cli_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn parses_the_run_command() {
        let cli = Cli::parse_from(["simulatr", "run", "hello.elf"]);
        let Command::Run { elf, trace, max_steps } = cli.command;
        assert_eq!(elf, Path::new("hello.elf"));
        assert!(!trace);
        assert_eq!(max_steps, DEFAULT_STEP_BUDGET);
    }

    #[test]
    fn parses_flags_in_any_order() {
        for args in [
            ["simulatr", "run", "a.elf", "--trace", "--max-steps", "500"],
            ["simulatr", "run", "a.elf", "--max-steps", "500", "--trace"],
        ] {
            let Command::Run { trace, max_steps, .. } = Cli::parse_from(args).command;
            assert!(trace);
            assert_eq!(max_steps, 500);
        }
    }

    #[test]
    fn rejects_malformed_command_lines() {
        for args in [
            vec!["simulatr"],
            vec!["simulatr", "walk", "a.elf"],
            vec!["simulatr", "run"],
            vec!["simulatr", "run", "a.elf", "--fast"],
            vec!["simulatr", "run", "a.elf", "--max-steps"],
            vec!["simulatr", "run", "a.elf", "--max-steps", "lots"],
        ] {
            assert!(Cli::try_parse_from(&args).is_err(), "should have rejected {args:?}");
        }
    }

    /// Drives the same Observer the binary uses, but into byte buffers, so the stream
    /// routing itself is under test rather than just the core.
    fn capture(tracing: bool, budget: u64) -> (Vec<u8>, Vec<u8>, RunSummary) {
        let mut machine = Machine::new();
        machine.load_elf(HELLO_ELF).unwrap();

        let mut sink =
            Streams { uart: Vec::new(), trace: Vec::new(), tracing, line: String::new() };
        let summary = machine.run(budget, &mut sink);
        (sink.uart, sink.trace, summary)
    }

    #[test]
    fn uart_output_reaches_stdout_and_nothing_else_does() {
        let (uart, trace, summary) = capture(false, DEFAULT_STEP_BUDGET);
        assert_eq!(uart, b"HELLO");
        assert!(trace.is_empty());
        assert_eq!(exit_code(&summary), exit::OK);
    }

    #[test]
    fn trace_goes_to_stderr_one_json_object_per_instruction() {
        let (uart, trace, summary) = capture(true, DEFAULT_STEP_BUDGET);
        assert_eq!(uart, b"HELLO");

        let text = String::from_utf8(trace).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len() as u64, summary.steps);
        assert!(lines.iter().all(|l| l.starts_with('{') && l.ends_with('}')));
        assert!(lines[0].contains(r#""pc":"0x40080008""#));
        assert!(lines[0].contains(r#""op":"l32r""#));
    }

    #[test]
    fn an_exhausted_budget_exits_two() {
        let (uart, _, summary) = capture(false, 5);
        assert_eq!(summary.halt_reason, HaltReason::StepBudgetExhausted);
        assert_eq!(exit_code(&summary), exit::BUDGET);
        // Whatever was transmitted before the budget ran out still reaches stdout.
        assert_eq!(uart, b"H");
    }

    #[test]
    fn a_faulting_program_exits_three() {
        let mut machine = Machine::new();
        machine.load_elf(HELLO_ELF).unwrap();
        // Overwrite the entry point with the canonical illegal instruction.
        machine.bus_mut().write_block(0x4008_0008, &[0, 0, 0]).unwrap();

        let summary = machine.run(DEFAULT_STEP_BUDGET, &mut ());
        assert!(matches!(summary.fault(), Some(Fault::Decode(DecodeError::Illegal { .. }))));
        assert_eq!(exit_code(&summary), exit::FAULT);
    }
}
