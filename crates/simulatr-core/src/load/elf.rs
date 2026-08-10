//! ELF32 loader.
//!
//! An ELF is a header, a program header table describing how to lay the file out in
//! memory, and the segment bytes. A loader only needs the program headers; sections
//! (`.text`, `.rodata`, ...) are a link-time view. The symbol table becomes interesting
//! in Phase 2, when traces want function names.
//!
//! Layout, all little-endian on Xtensa:
//!
//! ```text
//! ELF header, 52 bytes
//!   0x00  e_ident[16]   magic 0x7F 'E' 'L' 'F', class, data encoding, version
//!   0x10  e_type        u16, 2 = ET_EXEC
//!   0x12  e_machine     u16, 94 = EM_XTENSA
//!   0x18  e_entry       u32, virtual address of the first instruction
//!   0x1C  e_phoff       u32, file offset of the program header table
//!   0x2A  e_phentsize   u16, bytes per program header (32 for ELF32)
//!   0x2C  e_phnum       u16, number of program headers
//!
//! Program header, 32 bytes
//!   0x00  p_type        u32, 1 = PT_LOAD
//!   0x04  p_offset      u32, where the bytes live in the file
//!   0x08  p_vaddr       u32, where they must be placed in memory
//!   0x10  p_filesz      u32, how many bytes are in the file
//!   0x14  p_memsz       u32, how much memory the segment occupies
//! ```
//!
//! `p_memsz > p_filesz` means the tail is `.bss`: memory that must exist and be zero but
//! is not stored in the file.

use crate::mem::bus::{Bus, BusError};
use core::fmt;

const ELF_MAGIC: [u8; 4] = [0x7F, b'E', b'L', b'F'];
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const ET_EXEC: u16 = 2;
const EM_XTENSA: u16 = 94;
const PT_LOAD: u32 = 1;

const EHDR_SIZE: usize = 52;
const PHDR_SIZE: usize = 32;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LoadError {
    NotAnElfFile,
    NotElf32,
    /// The Espressif toolchain's *default* core is generic big-endian; you need
    /// `-mdynconfig=.../xtensa_esp32.so` to get a little-endian ESP32 image.
    /// See `examples/build.sh`.
    NotLittleEndian,
    NotAnExecutable {
        e_type: u16,
    },
    NotXtensa {
        e_machine: u16,
    },
    Truncated,
    BadProgramHeaderSize {
        size: u16,
    },
    NoLoadableSegments,
    SegmentFileRangeOutOfBounds {
        index: u16,
    },
    SegmentMemorySizeTooSmall {
        index: u16,
    },
    Bus(BusError),
}

impl From<BusError> for LoadError {
    fn from(err: BusError) -> Self {
        LoadError::Bus(err)
    }
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            LoadError::NotAnElfFile => write!(f, "not an ELF file"),
            LoadError::NotElf32 => write!(f, "not a 32-bit ELF"),
            LoadError::NotLittleEndian => {
                write!(f, "not a little-endian ELF (rebuild with -mdynconfig=.../xtensa_esp32.so)")
            }
            LoadError::NotAnExecutable { e_type } => {
                write!(f, "not an executable (e_type = {e_type})")
            }
            LoadError::NotXtensa { e_machine } => {
                write!(f, "not an Xtensa image (e_machine = {e_machine})")
            }
            LoadError::Truncated => write!(f, "file is truncated"),
            LoadError::BadProgramHeaderSize { size } => {
                write!(f, "unexpected program header size {size}, want {PHDR_SIZE}")
            }
            LoadError::NoLoadableSegments => write!(f, "no PT_LOAD segments"),
            LoadError::SegmentFileRangeOutOfBounds { index } => {
                write!(f, "segment {index} extends past the end of the file")
            }
            LoadError::SegmentMemorySizeTooSmall { index } => {
                write!(f, "segment {index} has p_memsz < p_filesz")
            }
            LoadError::Bus(err) => write!(f, "loading segment: {err}"),
        }
    }
}

impl std::error::Error for LoadError {}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct LoadResult {
    /// Virtual address of the first instruction to execute.
    pub entry: u32,
    pub segments_loaded: usize,
    /// Bytes copied from the file, not counting zero-filled `.bss`.
    pub bytes_loaded: usize,
}

/// Parse `image` and copy every PT_LOAD segment into `bus`.
///
/// The whole file is expected to be in memory already: Phase 1 images are kilobytes, and
/// streaming would drag host I/O into a crate that deliberately has none.
pub fn load(bus: &mut Bus, image: &[u8]) -> Result<LoadResult, LoadError> {
    let header = image.get(..EHDR_SIZE).ok_or(LoadError::Truncated)?;

    if header[..4] != ELF_MAGIC {
        return Err(LoadError::NotAnElfFile);
    }
    if header[4] != ELFCLASS32 {
        return Err(LoadError::NotElf32);
    }
    if header[5] != ELFDATA2LSB {
        return Err(LoadError::NotLittleEndian);
    }

    let e_type = u16_at(header, 0x10);
    if e_type != ET_EXEC {
        return Err(LoadError::NotAnExecutable { e_type });
    }
    let e_machine = u16_at(header, 0x12);
    if e_machine != EM_XTENSA {
        return Err(LoadError::NotXtensa { e_machine });
    }

    let entry = u32_at(header, 0x18);
    let e_phoff = u32_at(header, 0x1C) as usize;
    let e_phentsize = u16_at(header, 0x2A);
    let e_phnum = u16_at(header, 0x2C);

    if usize::from(e_phentsize) != PHDR_SIZE {
        return Err(LoadError::BadProgramHeaderSize { size: e_phentsize });
    }

    let mut result = LoadResult { entry, segments_loaded: 0, bytes_loaded: 0 };

    for index in 0..e_phnum {
        let start = e_phoff + PHDR_SIZE * usize::from(index);
        let phdr = image.get(start..start + PHDR_SIZE).ok_or(LoadError::Truncated)?;

        if u32_at(phdr, 0x00) != PT_LOAD {
            continue;
        }

        let p_offset = u32_at(phdr, 0x04) as usize;
        let p_vaddr = u32_at(phdr, 0x08);
        let p_filesz = u32_at(phdr, 0x10);
        let p_memsz = u32_at(phdr, 0x14);

        // A zero-size PT_LOAD is legal and means nothing to do.
        if p_memsz == 0 {
            continue;
        }
        if p_memsz < p_filesz {
            return Err(LoadError::SegmentMemorySizeTooSmall { index });
        }

        if p_filesz > 0 {
            let bytes = image
                .get(p_offset..p_offset + p_filesz as usize)
                .ok_or(LoadError::SegmentFileRangeOutOfBounds { index })?;
            bus.write_block(p_vaddr, bytes)?;
            result.bytes_loaded += bytes.len();
        }

        // The `.bss` tail. `Bus::new` already zeroed RAM, but a second load into the same
        // machine must not see the previous image's data.
        if p_memsz > p_filesz {
            bus.zero_block(p_vaddr.wrapping_add(p_filesz), p_memsz - p_filesz)?;
        }

        result.segments_loaded += 1;
    }

    if result.segments_loaded == 0 {
        return Err(LoadError::NoLoadableSegments);
    }
    Ok(result)
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::soc::esp32::{DRAM_BASE, IRAM_BASE};

    /// Hand-builds a minimal but genuine ELF32 executable with one PT_LOAD segment, so
    /// the loader's tests never need the Xtensa toolchain.
    struct TestElf {
        bytes: Vec<u8>,
    }

    impl TestElf {
        const PAYLOAD_OFFSET: usize = EHDR_SIZE + PHDR_SIZE;

        fn new(payload: &[u8], vaddr: u32, entry: u32, memsz: u32) -> Self {
            let mut bytes = vec![0u8; Self::PAYLOAD_OFFSET + payload.len()];

            bytes[..4].copy_from_slice(&ELF_MAGIC);
            bytes[4] = ELFCLASS32;
            bytes[5] = ELFDATA2LSB;
            bytes[6] = 1; // EV_CURRENT
            put_u16(&mut bytes, 0x10, ET_EXEC);
            put_u16(&mut bytes, 0x12, EM_XTENSA);
            put_u32(&mut bytes, 0x14, 1); // e_version
            put_u32(&mut bytes, 0x18, entry);
            put_u32(&mut bytes, 0x1C, EHDR_SIZE as u32); // e_phoff
            put_u32(&mut bytes, 0x24, 0x0000_0300); // e_flags, Xtensa ABI bits
            put_u16(&mut bytes, 0x28, EHDR_SIZE as u16);
            put_u16(&mut bytes, 0x2A, PHDR_SIZE as u16);
            put_u16(&mut bytes, 0x2C, 1); // e_phnum

            let ph = EHDR_SIZE;
            put_u32(&mut bytes, ph, PT_LOAD);
            put_u32(&mut bytes, ph + 0x04, Self::PAYLOAD_OFFSET as u32);
            put_u32(&mut bytes, ph + 0x08, vaddr);
            put_u32(&mut bytes, ph + 0x0C, vaddr);
            put_u32(&mut bytes, ph + 0x10, payload.len() as u32);
            put_u32(&mut bytes, ph + 0x14, memsz);
            put_u32(&mut bytes, ph + 0x18, 5); // PF_R | PF_X
            put_u32(&mut bytes, ph + 0x1C, 4); // p_align

            bytes[Self::PAYLOAD_OFFSET..].copy_from_slice(payload);
            Self { bytes }
        }

        fn simple(payload: &[u8]) -> Self {
            Self::new(payload, IRAM_BASE, IRAM_BASE, payload.len() as u32)
        }
    }

    fn put_u16(bytes: &mut [u8], offset: usize, value: u16) {
        bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    fn put_u32(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    #[test]
    fn loads_a_single_segment_and_reports_the_entry_point() {
        let mut bus = Bus::new();
        let elf = TestElf::simple(&[0xDE, 0xC0, 0xAD, 0x0B]);

        let result = load(&mut bus, &elf.bytes).unwrap();
        assert_eq!(result, LoadResult { entry: IRAM_BASE, segments_loaded: 1, bytes_loaded: 4 });
        assert_eq!(bus.read32(IRAM_BASE).unwrap(), 0x0BAD_C0DE);
    }

    #[test]
    fn entry_point_may_differ_from_the_segment_base() {
        let mut bus = Bus::new();
        let payload = [1, 2, 3, 4, 5, 6, 7, 8];
        let elf = TestElf::new(&payload, IRAM_BASE, IRAM_BASE + 4, payload.len() as u32);
        assert_eq!(load(&mut bus, &elf.bytes).unwrap().entry, IRAM_BASE + 4);
    }

    #[test]
    fn memsz_larger_than_filesz_zero_fills_the_bss_tail() {
        let mut bus = Bus::new();
        // Dirty the memory first, so we can prove the loader zeroed it.
        bus.write32(DRAM_BASE + 4, 0xFFFF_FFFF).unwrap();

        let elf = TestElf::new(&[0xAA, 0xBB, 0xCC, 0xDD], DRAM_BASE, DRAM_BASE, 8);
        load(&mut bus, &elf.bytes).unwrap();

        assert_eq!(bus.read32(DRAM_BASE).unwrap(), 0xDDCC_BBAA);
        assert_eq!(bus.read32(DRAM_BASE + 4).unwrap(), 0);
    }

    #[test]
    fn rejects_files_that_are_not_xtensa_elf32_executables() {
        let mut bus = Bus::new();

        let mut bad = TestElf::simple(&[0; 4]);
        bad.bytes[1] = b'X';
        assert_eq!(load(&mut bus, &bad.bytes), Err(LoadError::NotAnElfFile));

        let mut bad = TestElf::simple(&[0; 4]);
        bad.bytes[4] = 2; // ELFCLASS64
        assert_eq!(load(&mut bus, &bad.bytes), Err(LoadError::NotElf32));

        let mut bad = TestElf::simple(&[0; 4]);
        bad.bytes[5] = 2; // ELFDATA2MSB — what the toolchain produces by default
        assert_eq!(load(&mut bus, &bad.bytes), Err(LoadError::NotLittleEndian));

        let mut bad = TestElf::simple(&[0; 4]);
        put_u16(&mut bad.bytes, 0x12, 40); // EM_ARM
        assert_eq!(load(&mut bus, &bad.bytes), Err(LoadError::NotXtensa { e_machine: 40 }));

        let mut bad = TestElf::simple(&[0; 4]);
        put_u16(&mut bad.bytes, 0x10, 1); // ET_REL, an object file
        assert_eq!(load(&mut bus, &bad.bytes), Err(LoadError::NotAnExecutable { e_type: 1 }));

        assert_eq!(load(&mut bus, b"short"), Err(LoadError::Truncated));
    }

    #[test]
    fn rejects_a_segment_whose_bytes_are_not_in_the_file() {
        let mut bus = Bus::new();
        let mut bad = TestElf::simple(&[1, 2, 3, 4]);
        put_u32(&mut bad.bytes, EHDR_SIZE + 0x10, 4096); // p_filesz past the end
        put_u32(&mut bad.bytes, EHDR_SIZE + 0x14, 4096);
        assert_eq!(
            load(&mut bus, &bad.bytes),
            Err(LoadError::SegmentFileRangeOutOfBounds { index: 0 })
        );
    }

    #[test]
    fn rejects_a_segment_aimed_at_an_address_with_no_ram_behind_it() {
        let mut bus = Bus::new();
        let payload = [1, 2, 3, 4];
        let elf = TestElf::new(&payload, 0x1234_0000, 0x1234_0000, payload.len() as u32);
        assert!(matches!(load(&mut bus, &elf.bytes), Err(LoadError::Bus(_))));
    }

    #[test]
    fn a_file_with_no_loadable_segments_is_rejected() {
        let mut bus = Bus::new();
        let mut bad = TestElf::simple(&[1, 2, 3, 4]);
        put_u32(&mut bad.bytes, EHDR_SIZE, 4); // PT_NOTE
        assert_eq!(load(&mut bus, &bad.bytes), Err(LoadError::NoLoadableSegments));
    }
}
