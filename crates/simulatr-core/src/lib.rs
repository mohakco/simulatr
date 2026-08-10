//! Deterministic ESP32 (Xtensa LX6) emulation core.
//!
//! A [`Machine`] is one node: a CPU, a memory bus, and the SoC profile's peripherals.
//! Load an ELF, run it, observe what it did:
//!
//! ```no_run
//! use simulatr_core::{DEFAULT_STEP_BUDGET, Machine, Observer};
//!
//! #[derive(Default)]
//! struct Collect(Vec<u8>);
//! impl Observer for Collect {
//!     fn on_uart_tx(&mut self, bytes: &[u8]) { self.0.extend_from_slice(bytes); }
//! }
//!
//! let image: &[u8] = &[]; // an ELF read by the caller; this crate does no I/O
//! let mut machine = Machine::new();
//! let mut out = Collect::default();
//! machine.load_elf(image)?;
//! let summary = machine.run(DEFAULT_STEP_BUDGET, &mut out);
//! # Ok::<(), simulatr_core::LoadError>(())
//! ```
//!
//! # Invariants
//!
//! This crate has **no dependencies**, contains **no `unsafe`**, and touches neither the
//! filesystem, the clock, threads nor randomness. Given the same image and the same
//! inputs, a run is byte-for-byte reproducible — determinism is the product, not a
//! nicety, because it is what makes an agent's iterate-and-fix loop converge instead of
//! chasing ghosts. It is also what keeps a WASM build small and snapshot/restore
//! tractable later. All host I/O belongs in `simulatr-cli`.

#![forbid(unsafe_code)]
#![warn(missing_debug_implementations)]

pub mod cpu;
pub mod load;
pub mod machine;
pub mod mem;
pub mod periph;
pub mod soc;
pub mod trace;

pub use cpu::core::{Cpu, Executed, Fault, HALT_ADDRESS, HaltReason};
pub use cpu::decode::{Decoded, DecodeError, Inst, InstSize, Reg};
pub use load::elf::{LoadError, LoadResult};
pub use machine::{DEFAULT_STEP_BUDGET, Machine, Observer, RunSummary};
pub use mem::bus::{Bus, BusError};
