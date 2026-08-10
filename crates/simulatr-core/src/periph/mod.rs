//! On-chip peripherals.
//!
//! Peripherals never call back into the CPU: they accumulate state and the run loop
//! collects it. See `docs/PLAN.md`, "The one real Rust design risk".

pub mod uart;
