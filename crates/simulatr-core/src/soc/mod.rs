//! Per-chip profiles: memory map, peripheral placement, CPU configuration.
//!
//! Phase 1 ships one. An ESP32-S3 profile becomes a sibling module exposing the same
//! `decode` function and constants.

pub mod esp32;
