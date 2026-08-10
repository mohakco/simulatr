//! The memory bus: turns a 32-bit address into RAM bytes or a peripheral access.
//!
//! Phase 1 is a flat model — two RAM regions plus one MMIO decode, no cache, no MMU, no
//! flash, no aliasing between the instruction and data buses. All address decoding is
//! delegated to the SoC profile; this module only routes.
//!
//! The ESP32's Xtensa core is little-endian, and every multi-byte access here goes
//! through `from_le_bytes`/`to_le_bytes` so the emulator behaves identically on a
//! big-endian host.

use crate::periph::uart::Uart;
use crate::soc::esp32::{self, Mapping};
use core::fmt;

/// Access width. The discriminants are the byte counts, which is also the alignment
/// requirement — Xtensa has no unaligned 16- or 32-bit access.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Width {
    Byte = 1,
    Half = 2,
    Word = 4,
}

impl Width {
    pub const fn bytes(self) -> u32 {
        self as u32
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BusError {
    /// No RAM region and no known peripheral covers this address.
    Unmapped { addr: u32 },
    /// A real peripheral register block with no model in this phase.
    UnimplementedPeripheral { addr: u32 },
    /// A 16- or 32-bit access whose address is not a multiple of the access size. Real
    /// Xtensa raises `LoadStoreAlignmentCause`; Phase 1 has no exception machinery, so
    /// this halts the run instead.
    Unaligned { addr: u32, width: Width },
    /// The access started inside a region but ran off its end. Single loads and stores
    /// cannot trigger this (alignment is enforced and region sizes are multiples of 4),
    /// so in practice it only comes from a bulk segment load.
    RegionOverrun { addr: u32, len: u32 },
}

impl fmt::Display for BusError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            BusError::Unmapped { addr } => write!(f, "unmapped address {addr:#010x}"),
            BusError::UnimplementedPeripheral { addr } => {
                write!(f, "unimplemented peripheral at {addr:#010x}")
            }
            BusError::Unaligned { addr, width } => {
                write!(f, "unaligned {}-byte access at {addr:#010x}", width.bytes())
            }
            BusError::RegionOverrun { addr, len } => {
                write!(f, "{len}-byte access at {addr:#010x} runs off the end of its region")
            }
        }
    }
}

impl std::error::Error for BusError {}

pub struct Bus {
    iram: Box<[u8]>,
    dram: Box<[u8]>,
    uart: Uart,
}

/// Deliberately not derived: the RAM regions are half a megabyte and dumping them helps
/// nobody.
impl fmt::Debug for Bus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Bus")
            .field(
                "iram",
                &format_args!("{} bytes @ {:#010x}", self.iram.len(), esp32::IRAM_BASE),
            )
            .field(
                "dram",
                &format_args!("{} bytes @ {:#010x}", self.dram.len(), esp32::DRAM_BASE),
            )
            .field("uart", &self.uart)
            .finish()
    }
}

impl Default for Bus {
    fn default() -> Self {
        Self::new()
    }
}

impl Bus {
    pub fn new() -> Self {
        // Real SRAM powers up with garbage, but a simulator that starts from garbage is
        // not reproducible, and determinism is the product.
        Self {
            iram: vec![0; esp32::IRAM_SIZE as usize].into_boxed_slice(),
            dram: vec![0; esp32::DRAM_SIZE as usize].into_boxed_slice(),
            uart: Uart::new(),
        }
    }

    pub fn uart(&self) -> &Uart {
        &self.uart
    }

    pub fn uart_mut(&mut self) -> &mut Uart {
        &mut self.uart
    }

    // --- loads ---------------------------------------------------------------------

    pub fn read8(&self, addr: u32) -> Result<u8, BusError> {
        Ok(self.load(addr, Width::Byte)? as u8)
    }

    pub fn read16(&self, addr: u32) -> Result<u16, BusError> {
        Ok(self.load(addr, Width::Half)? as u16)
    }

    pub fn read32(&self, addr: u32) -> Result<u32, BusError> {
        self.load(addr, Width::Word)
    }

    /// One implementation for all three widths; the result is zero-extended into a u32.
    fn load(&self, addr: u32, width: Width) -> Result<u32, BusError> {
        let size = width.bytes();
        if addr % size != 0 {
            return Err(BusError::Unaligned { addr, width });
        }

        match esp32::decode(addr) {
            Mapping::Iram { offset } => read_le(&self.iram, offset, size, addr),
            Mapping::Dram { offset } => read_le(&self.dram, offset, size, addr),
            // Peripheral registers are word-oriented; a sub-word read returns the
            // corresponding slice of the 32-bit register value.
            Mapping::Uart0 { offset } => {
                let word = self.uart.read_reg(offset & !3);
                Ok(sub_word(word, addr, size))
            }
            Mapping::UnmappedPeripheral => Err(BusError::UnimplementedPeripheral { addr }),
            Mapping::Unmapped => Err(BusError::Unmapped { addr }),
        }
    }

    // --- stores --------------------------------------------------------------------

    pub fn write8(&mut self, addr: u32, value: u8) -> Result<(), BusError> {
        self.store(addr, Width::Byte, u32::from(value))
    }

    pub fn write16(&mut self, addr: u32, value: u16) -> Result<(), BusError> {
        self.store(addr, Width::Half, u32::from(value))
    }

    pub fn write32(&mut self, addr: u32, value: u32) -> Result<(), BusError> {
        self.store(addr, Width::Word, value)
    }

    fn store(&mut self, addr: u32, width: Width, value: u32) -> Result<(), BusError> {
        let size = width.bytes();
        if addr % size != 0 {
            return Err(BusError::Unaligned { addr, width });
        }

        match esp32::decode(addr) {
            Mapping::Iram { offset } => write_le(&mut self.iram, offset, size, addr, value),
            Mapping::Dram { offset } => write_le(&mut self.dram, offset, size, addr, value),
            // A sub-word store to a peripheral is modelled as a word store of the value.
            // Only UART_FIFO_REG cares, and it only looks at the low 8 bits.
            Mapping::Uart0 { offset } => {
                self.uart.write_reg(offset & !3, value);
                Ok(())
            }
            Mapping::UnmappedPeripheral => Err(BusError::UnimplementedPeripheral { addr }),
            Mapping::Unmapped => Err(BusError::Unmapped { addr }),
        }
    }

    // --- bulk access, used by the ELF loader ----------------------------------------

    /// Copy `bytes` into RAM at `addr`. Peripherals are not loadable.
    pub fn write_block(&mut self, addr: u32, bytes: &[u8]) -> Result<(), BusError> {
        let len = bytes.len() as u32;
        let dest = self.ram_block_mut(addr, len)?;
        dest.copy_from_slice(bytes);
        Ok(())
    }

    /// Zero `len` bytes of RAM at `addr` — the `.bss` tail of a segment, where the ELF
    /// says `p_memsz > p_filesz`.
    pub fn zero_block(&mut self, addr: u32, len: u32) -> Result<(), BusError> {
        self.ram_block_mut(addr, len)?.fill(0);
        Ok(())
    }

    fn ram_block_mut(&mut self, addr: u32, len: u32) -> Result<&mut [u8], BusError> {
        let (region, offset) = match esp32::decode(addr) {
            Mapping::Iram { offset } => (&mut self.iram, offset),
            Mapping::Dram { offset } => (&mut self.dram, offset),
            _ => return Err(BusError::Unmapped { addr }),
        };
        let end = offset as usize + len as usize;
        region
            .get_mut(offset as usize..end)
            .ok_or(BusError::RegionOverrun { addr, len })
    }
}

fn read_le(mem: &[u8], offset: u32, size: u32, addr: u32) -> Result<u32, BusError> {
    let start = offset as usize;
    let bytes = mem
        .get(start..start + size as usize)
        .ok_or(BusError::RegionOverrun { addr, len: size })?;

    let mut word = [0u8; 4];
    word[..bytes.len()].copy_from_slice(bytes);
    Ok(u32::from_le_bytes(word))
}

fn write_le(
    mem: &mut [u8],
    offset: u32,
    size: u32,
    addr: u32,
    value: u32,
) -> Result<(), BusError> {
    let start = offset as usize;
    let bytes = mem
        .get_mut(start..start + size as usize)
        .ok_or(BusError::RegionOverrun { addr, len: size })?;
    bytes.copy_from_slice(&value.to_le_bytes()[..size as usize]);
    Ok(())
}

/// Extract the `size` bytes at `addr`'s offset within a 32-bit register value.
fn sub_word(word: u32, addr: u32, size: u32) -> u32 {
    if size == 4 {
        return word;
    }
    let shift = (addr & 3) * 8;
    let mask = (1u64 << (size * 8)) - 1;
    ((word >> shift) as u64 & mask) as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::soc::esp32::{DRAM_BASE, DRAM_SIZE, IRAM_BASE, UART0_BASE, uart_reg};

    #[test]
    fn word_round_trip_in_dram() {
        let mut bus = Bus::new();
        bus.write32(DRAM_BASE + 16, 0xDEAD_BEEF).unwrap();
        assert_eq!(bus.read32(DRAM_BASE + 16).unwrap(), 0xDEAD_BEEF);
    }

    #[test]
    fn little_endian_byte_order() {
        let mut bus = Bus::new();
        bus.write32(DRAM_BASE, 0x1122_3344).unwrap();

        assert_eq!(bus.read8(DRAM_BASE).unwrap(), 0x44);
        assert_eq!(bus.read8(DRAM_BASE + 1).unwrap(), 0x33);
        assert_eq!(bus.read8(DRAM_BASE + 2).unwrap(), 0x22);
        assert_eq!(bus.read8(DRAM_BASE + 3).unwrap(), 0x11);
        assert_eq!(bus.read16(DRAM_BASE).unwrap(), 0x3344);
        assert_eq!(bus.read16(DRAM_BASE + 2).unwrap(), 0x1122);
    }

    #[test]
    fn iram_and_dram_are_independent() {
        let mut bus = Bus::new();
        bus.write32(IRAM_BASE, 0xAAAA_AAAA).unwrap();
        bus.write32(DRAM_BASE, 0xBBBB_BBBB).unwrap();
        assert_eq!(bus.read32(IRAM_BASE).unwrap(), 0xAAAA_AAAA);
        assert_eq!(bus.read32(DRAM_BASE).unwrap(), 0xBBBB_BBBB);
    }

    #[test]
    fn alignment_is_enforced_for_halfword_and_word_access() {
        let mut bus = Bus::new();
        assert_eq!(
            bus.read32(DRAM_BASE + 1),
            Err(BusError::Unaligned { addr: DRAM_BASE + 1, width: Width::Word })
        );
        assert_eq!(
            bus.read32(DRAM_BASE + 2),
            Err(BusError::Unaligned { addr: DRAM_BASE + 2, width: Width::Word })
        );
        assert_eq!(
            bus.read16(DRAM_BASE + 1),
            Err(BusError::Unaligned { addr: DRAM_BASE + 1, width: Width::Half })
        );
        assert!(bus.write32(DRAM_BASE + 3, 0).is_err());

        // Byte access is never misaligned.
        bus.write8(DRAM_BASE + 1, 0x5A).unwrap();
        assert_eq!(bus.read8(DRAM_BASE + 1).unwrap(), 0x5A);
    }

    #[test]
    fn unmapped_addresses_are_errors_not_silent_zeroes() {
        let mut bus = Bus::new();
        assert_eq!(bus.read32(0), Err(BusError::Unmapped { addr: 0 }));
        assert_eq!(bus.read32(0x5000_0000), Err(BusError::Unmapped { addr: 0x5000_0000 }));
        assert!(bus.write32(IRAM_BASE - 4, 1).is_err());
    }

    #[test]
    fn unimplemented_peripherals_are_reported_not_ignored() {
        let mut bus = Bus::new();
        // GPIO base on the ESP32; no model in Phase 1.
        assert_eq!(
            bus.write32(0x3FF4_4004, 1),
            Err(BusError::UnimplementedPeripheral { addr: 0x3FF4_4004 })
        );
    }

    #[test]
    fn a_word_store_to_the_uart_fifo_emits_a_byte() {
        let mut bus = Bus::new();
        bus.write32(UART0_BASE + uart_reg::FIFO, u32::from(b'Z')).unwrap();
        assert_eq!(bus.uart().pending(), b"Z");
    }

    #[test]
    fn bulk_access_covers_a_segment_load() {
        let mut bus = Bus::new();
        bus.write_block(IRAM_BASE, &[1, 2, 3, 4]).unwrap();
        assert_eq!(bus.read32(IRAM_BASE).unwrap(), 0x0403_0201);

        bus.zero_block(IRAM_BASE, 4).unwrap();
        assert_eq!(bus.read32(IRAM_BASE).unwrap(), 0);

        // A segment aimed at an address with no RAM behind it must fail loudly.
        assert!(bus.write_block(0x1000, &[0]).is_err());
    }

    #[test]
    fn a_bulk_write_that_overruns_its_region_is_caught() {
        let mut bus = Bus::new();
        let last_word = DRAM_BASE + DRAM_SIZE - 4;
        bus.write32(last_word, 0x1234_5678).unwrap();
        assert_eq!(bus.read32(last_word).unwrap(), 0x1234_5678);
        assert_eq!(bus.read32(last_word + 4), Err(BusError::Unmapped { addr: last_word + 4 }));

        assert_eq!(
            bus.write_block(last_word, &[0; 8]),
            Err(BusError::RegionOverrun { addr: last_word, len: 8 })
        );
    }
}
