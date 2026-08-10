//! ESP32 "classic" (Xtensa LX6) SoC profile.
//!
//! Every chip-specific constant lives here. Nothing in `cpu/`, `mem/` or `periph/` may
//! hard-code an address; they go through [`decode`]. Adding an ESP32-S3 profile means a
//! sibling module with its own `decode`, not edits to the CPU.
//!
//! Sources: ESP32 Technical Reference Manual, "System and Memory" (address map) and
//! "UART Controller" (register offsets).

/// Name reported in trace output and the run summary.
pub const NAME: &str = "esp32";

// The ESP32 has separate instruction and data buses onto the same internal SRAM, so the
// same physical bytes appear at more than one address. Phase 1 does not model that
// aliasing: two independent flat regions, placed at the origins ESP-IDF's own linker
// script uses for `iram0_0_seg` and `dram0_0_seg`.

/// Instruction RAM: where PT_LOAD segments holding code land.
pub const IRAM_BASE: u32 = 0x4008_0000;
pub const IRAM_SIZE: u32 = 0x0002_0000; // 128 KiB

/// Data RAM: where `.data`, `.bss` and the stack land.
pub const DRAM_BASE: u32 = 0x3FFB_0000;
pub const DRAM_SIZE: u32 = 0x0003_0000; // 192 KiB

/// The whole peripheral window. Phase 1 decodes exactly one peripheral inside it.
pub const PERIPHERAL_BASE: u32 = 0x3FF0_0000;
pub const PERIPHERAL_SIZE: u32 = 0x0008_0000;

/// UART0 register block. Each ESP32 UART gets 0x80 bytes of register space.
pub const UART0_BASE: u32 = 0x3FF4_0000;
pub const UART_REGS_SIZE: u32 = 0x80;

/// Byte offsets within a UART register block that Phase 1 knows about.
pub mod uart_reg {
    /// `UART_FIFO_REG`. Writing the low 8 bits pushes a byte into the TX FIFO; reading
    /// pops one from the RX FIFO. This is the register the POC firmware pokes.
    pub const FIFO: u32 = 0x00;
    /// `UART_STATUS_REG`. Bits 23:16 are TXFIFO_CNT, bits 7:0 are RXFIFO_CNT. Firmware
    /// polls this to wait for room in the TX FIFO.
    pub const STATUS: u32 = 0x1C;
}

/// Where an address lands, with the offset within whatever it landed in.
///
/// Address decoding is a pure function of the address, deliberately: it keeps the bus
/// free of chip knowledge and lets the whole map be unit-tested without allocating any
/// memory.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mapping {
    Iram { offset: u32 },
    Dram { offset: u32 },
    Uart0 { offset: u32 },
    /// Inside the peripheral window, but not a peripheral we model. Distinct from
    /// `Unmapped` so a run that dies tells you "not written yet" rather than
    /// "nothing there".
    UnmappedPeripheral,
    Unmapped,
}

pub const fn decode(addr: u32) -> Mapping {
    // `wrapping_sub` so a region at the very top of the address space still decodes.
    if addr.wrapping_sub(IRAM_BASE) < IRAM_SIZE {
        return Mapping::Iram { offset: addr - IRAM_BASE };
    }
    if addr.wrapping_sub(DRAM_BASE) < DRAM_SIZE {
        return Mapping::Dram { offset: addr - DRAM_BASE };
    }
    if addr.wrapping_sub(UART0_BASE) < UART_REGS_SIZE {
        return Mapping::Uart0 { offset: addr - UART0_BASE };
    }
    if addr.wrapping_sub(PERIPHERAL_BASE) < PERIPHERAL_SIZE {
        return Mapping::UnmappedPeripheral;
    }
    Mapping::Unmapped
}

/// Initial stack pointer: near the top of DRAM, growing down. Hand-written assembly
/// generally does not set up its own stack, and the call0 ABI requires `a1` to stay
/// 16-byte aligned.
pub const fn initial_stack_pointer() -> u32 {
    (DRAM_BASE + DRAM_SIZE - 16) & !15
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ram_region_boundaries() {
        assert_eq!(decode(IRAM_BASE), Mapping::Iram { offset: 0 });
        assert_eq!(
            decode(IRAM_BASE + IRAM_SIZE - 1),
            Mapping::Iram { offset: IRAM_SIZE - 1 }
        );
        assert_eq!(decode(IRAM_BASE + IRAM_SIZE), Mapping::Unmapped);
        assert_eq!(decode(IRAM_BASE - 1), Mapping::Unmapped);

        assert_eq!(decode(DRAM_BASE), Mapping::Dram { offset: 0 });
        // DRAM ends exactly where IRAM's window does not begin; nothing follows it.
        assert_eq!(decode(DRAM_BASE + DRAM_SIZE), Mapping::Unmapped);
    }

    #[test]
    fn uart0_decodes_ahead_of_the_generic_peripheral_window() {
        assert_eq!(decode(UART0_BASE), Mapping::Uart0 { offset: 0 });
        assert_eq!(
            decode(UART0_BASE + uart_reg::STATUS),
            Mapping::Uart0 { offset: uart_reg::STATUS }
        );
        assert_eq!(decode(UART0_BASE + UART_REGS_SIZE), Mapping::UnmappedPeripheral);
        // GPIO base: a real peripheral with no model in Phase 1.
        assert_eq!(decode(0x3FF4_4004), Mapping::UnmappedPeripheral);
    }

    #[test]
    fn regions_do_not_overlap() {
        assert_eq!(decode(0x0000_0000), Mapping::Unmapped);
        assert_eq!(decode(0x5000_0000), Mapping::Unmapped);
        assert_eq!(decode(0xFFFF_FFFF), Mapping::Unmapped);
    }

    #[test]
    fn stack_pointer_is_inside_dram_and_aligned() {
        let sp = initial_stack_pointer();
        assert_eq!(sp % 16, 0);
        assert!(matches!(decode(sp), Mapping::Dram { .. }));
    }
}
