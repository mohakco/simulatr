//! The Xtensa LX6 execution core: fetch, decode, execute.
//!
//! Phase 1 models the **call0 ABI** only: 16 flat address registers, none hardwired to
//! zero, `a0` holding the return address and `a1` the stack pointer by software
//! convention. No register windows — real Xtensa has a rotating 64-entry physical
//! register file that CALL4/8/12 rotate through, and the decoder refuses those rather
//! than pretending. No special registers, exceptions or interrupts.
//!
//! The CPU does not own the bus: [`Cpu::step`] takes `&mut Bus` as a parameter, so
//! `Machine` can hold both and hand out two disjoint borrows. That is what keeps the
//! emulator free of `Rc<RefCell<_>>`.

use crate::cpu::decode::{
    self, AluOp, Cond, DecodeError, Decoded, Inst, InstSize, LoadKind, Reg, StoreKind, ZeroCond,
};
use crate::mem::bus::{Bus, BusError};
use core::fmt;

/// The sentinel return address planted in `a0` before the first instruction.
///
/// There is no operating system to return to, so the entry function's `ret` has to land
/// somewhere recognisable. This address is outside every mapped region, and its low bits
/// are zero so it cannot be confused with a real PC.
pub const HALT_ADDRESS: u32 = 0xDEAD_BEE0;

/// Anything that stops a run mid-instruction.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fault {
    Decode(DecodeError),
    Bus(BusError),
}

impl From<DecodeError> for Fault {
    fn from(err: DecodeError) -> Self {
        Fault::Decode(err)
    }
}

impl From<BusError> for Fault {
    fn from(err: BusError) -> Self {
        Fault::Bus(err)
    }
}

impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Fault::Decode(err) => write!(f, "{err}"),
            Fault::Bus(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for Fault {}

/// Why a run stopped. `None` on the CPU means it is still running.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HaltReason {
    /// `ret` landed on [`HALT_ADDRESS`]: the entry function finished.
    Returned,
    /// A jump or taken branch whose destination is itself. Firmware spins when it is
    /// done, so a fixed point in the control flow is the natural "finished" signal, and
    /// `j .` is exactly how `examples/hello.S` ends.
    SpinLoop,
    /// The instruction budget ran out.
    StepBudgetExhausted,
    Fault(Fault),
}

impl fmt::Display for HaltReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HaltReason::Returned => write!(f, "returned"),
            HaltReason::SpinLoop => write!(f, "spin_loop"),
            HaltReason::StepBudgetExhausted => write!(f, "step_budget_exhausted"),
            HaltReason::Fault(fault) => write!(f, "fault: {fault}"),
        }
    }
}

/// One retired instruction, as reported to observers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Executed {
    /// Address the instruction was fetched from.
    pub pc: u32,
    /// Raw bytes, assembled little-endian.
    pub word: u32,
    pub decoded: Decoded,
}

#[derive(Debug)]
pub struct Cpu {
    /// The 16 visible address registers.
    regs: [u32; 16],
    pc: u32,
    steps: u64,
    halt: Option<HaltReason>,
}

impl Default for Cpu {
    fn default() -> Self {
        Self::new()
    }
}

impl Cpu {
    pub fn new() -> Self {
        Cpu { regs: [0; 16], pc: 0, steps: 0, halt: None }
    }

    /// Prepare to execute from `entry` with `a1` as the stack pointer.
    ///
    /// The call0 ABI expects a valid downward-growing stack even in a program that never
    /// calls anything, and hand-written assembly generally does not set one up.
    pub fn reset(&mut self, entry: u32, stack_pointer: u32) {
        self.regs = [0; 16];
        self.pc = entry;
        self.steps = 0;
        self.halt = None;
        self.set(Reg::A0, HALT_ADDRESS);
        self.set(Reg::A1, stack_pointer);
    }

    pub fn pc(&self) -> u32 {
        self.pc
    }

    pub fn steps(&self) -> u64 {
        self.steps
    }

    pub fn halt(&self) -> Option<HaltReason> {
        self.halt
    }

    pub fn is_halted(&self) -> bool {
        self.halt.is_some()
    }

    pub fn regs(&self) -> &[u32; 16] {
        &self.regs
    }

    #[inline]
    fn get(&self, reg: Reg) -> u32 {
        self.regs[reg.index()]
    }

    #[inline]
    fn set(&mut self, reg: Reg, value: u32) {
        self.regs[reg.index()] = value;
    }

    /// Stop the run for a reason the caller determined, e.g. an exhausted budget.
    pub fn halt_with(&mut self, reason: HaltReason) {
        self.halt = Some(reason);
    }

    /// Fetch, decode and execute one instruction.
    ///
    /// Returns `Ok(None)` when the CPU is already halted or halts before executing
    /// anything. A fault halts the CPU *and* is returned, so the caller can report it
    /// without reaching into `halt`.
    pub fn step(&mut self, bus: &mut Bus) -> Result<Option<Executed>, Fault> {
        if self.halt.is_some() {
            return Ok(None);
        }
        if self.pc == HALT_ADDRESS {
            self.halt = Some(HaltReason::Returned);
            return Ok(None);
        }

        let pc = self.pc;
        match self.execute_at(pc, bus) {
            Ok(executed) => Ok(Some(executed)),
            Err(fault) => {
                self.halt = Some(HaltReason::Fault(fault));
                Err(fault)
            }
        }
    }

    fn execute_at(&mut self, pc: u32, bus: &mut Bus) -> Result<Executed, Fault> {
        let (word, size) = fetch(bus, pc)?;
        let decoded = decode::decode(pc, word, size)?;

        let next_pc = self.execute(pc, decoded, bus)?;
        self.steps += 1;

        // Only control flow can land on its own address; straight-line instructions are
        // at least two bytes long.
        if next_pc == pc {
            self.halt = Some(HaltReason::SpinLoop);
        } else if next_pc == HALT_ADDRESS {
            self.halt = Some(HaltReason::Returned);
        }
        self.pc = next_pc;

        Ok(Executed { pc, word, decoded })
    }

    /// Perform `decoded` and return the address of the next instruction.
    ///
    /// Which field is the destination varies by format and is the easiest place to
    /// introduce a silent bug — the [`Inst`] variants name their operands so that the
    /// mapping lives in the decoder, not here.
    fn execute(&mut self, pc: u32, decoded: Decoded, bus: &mut Bus) -> Result<u32, Fault> {
        let sequential = pc.wrapping_add(decoded.size.bytes());

        let next = match decoded.inst {
            Inst::Load { kind, dst, base, offset } => {
                let addr = self.get(base).wrapping_add(offset);
                let value = match kind {
                    LoadKind::U8 => u32::from(bus.read8(addr)?),
                    LoadKind::U16 => u32::from(bus.read16(addr)?),
                    LoadKind::I16 => i32::from(bus.read16(addr)? as i16) as u32,
                    LoadKind::U32 => bus.read32(addr)?,
                };
                self.set(dst, value);
                sequential
            }

            Inst::Store { kind, src, base, offset } => {
                let addr = self.get(base).wrapping_add(offset);
                let value = self.get(src);
                match kind {
                    StoreKind::U8 => bus.write8(addr, value as u8)?,
                    StoreKind::U16 => bus.write16(addr, value as u16)?,
                    StoreKind::U32 => bus.write32(addr, value)?,
                }
                sequential
            }

            // The only load with no base register: the address came from the literal
            // pool and was resolved at decode time.
            Inst::L32r { dst, literal } => {
                let value = bus.read32(literal)?;
                self.set(dst, value);
                sequential
            }

            Inst::Movi { dst, imm } => {
                self.set(dst, imm as u32);
                sequential
            }

            Inst::Addi { dst, src, imm } => {
                self.set(dst, self.get(src).wrapping_add(imm as u32));
                sequential
            }

            Inst::Alu { op, dst, lhs, rhs } => {
                let (a, b) = (self.get(lhs), self.get(rhs));
                self.set(
                    dst,
                    match op {
                        AluOp::Add => a.wrapping_add(b),
                        AluOp::Sub => a.wrapping_sub(b),
                        AluOp::And => a & b,
                        AluOp::Or => a | b,
                        AluOp::Xor => a ^ b,
                    },
                );
                sequential
            }

            Inst::Mov { dst, src } => {
                self.set(dst, self.get(src));
                sequential
            }

            // MEMW orders memory accesses around it. An in-order interpreter that
            // completes each access before starting the next already satisfies that.
            Inst::Memw | Inst::Nop => sequential,

            Inst::Jump { target } => target,
            Inst::JumpReg { target } => self.get(target),
            Inst::Ret => self.get(Reg::A0),

            // CALL0 clobbers a0, which is why a function that both calls and returns has
            // to spill a0 to the stack first. Register windows exist to avoid exactly
            // that, and they are Phase 2's first job.
            Inst::Call { target } => {
                self.set(Reg::A0, sequential);
                target
            }
            // Read the destination before writing a0, in case the target register is a0.
            Inst::CallReg { target } => {
                let destination = self.get(target);
                self.set(Reg::A0, sequential);
                destination
            }

            Inst::Branch { cond, lhs, rhs, target } => {
                let (a, b) = (self.get(lhs), self.get(rhs));
                let taken = match cond {
                    Cond::Eq => a == b,
                    Cond::Ne => a != b,
                    Cond::Lt => (a as i32) < (b as i32),
                    Cond::Ge => (a as i32) >= (b as i32),
                    Cond::Ltu => a < b,
                    Cond::Geu => a >= b,
                };
                if taken { target } else { sequential }
            }

            Inst::BranchZero { cond, src, target } => {
                let value = self.get(src);
                let taken = match cond {
                    ZeroCond::Eq => value == 0,
                    ZeroCond::Ne => value != 0,
                    ZeroCond::Lt => (value as i32) < 0,
                    ZeroCond::Ge => (value as i32) >= 0,
                };
                if taken { target } else { sequential }
            }
        };

        Ok(next)
    }
}

/// Read one instruction's bytes.
///
/// The length is only known after reading the first byte, so this is a two-stage read —
/// which is exactly what the hardware does.
fn fetch(bus: &Bus, pc: u32) -> Result<(u32, InstSize), BusError> {
    let first = bus.read8(pc)?;
    let size = decode::instruction_size(first);

    let mut word = u32::from(first);
    for i in 1..size.bytes() {
        let byte = bus.read8(pc.wrapping_add(i))?;
        word |= u32::from(byte) << (i * 8);
    }
    Ok((word, size))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::soc::esp32::{self, IRAM_BASE, UART0_BASE};

    struct Harness {
        cpu: Cpu,
        bus: Bus,
    }

    impl Harness {
        /// Place `program` at the start of IRAM and reset the CPU to run it.
        fn new(program: &[u8]) -> Self {
            let mut bus = Bus::new();
            bus.write_block(IRAM_BASE, program).unwrap();
            let mut cpu = Cpu::new();
            cpu.reset(IRAM_BASE, esp32::initial_stack_pointer());
            Harness { cpu, bus }
        }

        fn run(&mut self, budget: u64) -> HaltReason {
            while !self.cpu.is_halted() {
                if self.cpu.steps() >= budget {
                    self.cpu.halt_with(HaltReason::StepBudgetExhausted);
                    break;
                }
                let _ = self.cpu.step(&mut self.bus);
            }
            self.cpu.halt().unwrap()
        }

        fn reg(&self, n: u8) -> u32 {
            self.cpu.regs()[usize::from(n)]
        }
    }

    #[test]
    fn movi_then_add_then_ret() {
        let mut h = Harness::new(&[
            0x22, 0xA0, 0x0A, // movi a2, 10
            0x32, 0xA0, 0x20, // movi a3, 32
            0x30, 0x42, 0x80, // add  a4, a2, a3   (r = dst)
            0x80, 0x00, 0x00, // ret
        ]);
        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!((h.reg(2), h.reg(3), h.reg(4)), (10, 32, 42));
        assert_eq!(h.cpu.steps(), 4);
    }

    #[test]
    fn arithmetic_wraps_instead_of_trapping() {
        let mut h = Harness::new(&[
            0x22, 0xAF, 0xFF, // movi a2, -1
            0x32, 0xA0, 0x01, // movi a3, 1
            0x30, 0x42, 0x80, // add  a4, a2, a3
            0x80, 0x00, 0x00, // ret
        ]);
        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!(h.reg(2), 0xFFFF_FFFF);
        assert_eq!(h.reg(4), 0);
    }

    #[test]
    fn store_then_load_through_the_stack_pointer() {
        let mut h = Harness::new(&[
            0x22, 0xA1, 0x23, // movi a2, 0x123
            0x22, 0x61, 0x02, // s32i a2, a1, 8
            0x32, 0x21, 0x02, // l32i a3, a1, 8
            0x80, 0x00, 0x00, // ret
        ]);
        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!(h.reg(3), 0x123);
        assert_eq!(h.bus.read32(h.reg(1) + 8).unwrap(), 0x123);
    }

    #[test]
    fn narrow_forms_execute_like_their_wide_counterparts() {
        let mut h = Harness::new(&[
            0x0C, 0x22, // movi.n a2, 2   (destination is the s field)
            0x0C, 0x53, // movi.n a3, 5
            0x4A, 0x23, // add.n  a2, a3, a4
            0x0D, 0xF0, // ret.n
        ]);
        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!(h.reg(3), 5);
        // a4 is still 0, so a2 ends up 5, overwriting the 2.
        assert_eq!(h.reg(2), 5);
        assert_eq!(h.cpu.steps(), 4);
    }

    #[test]
    fn a_backwards_branch_makes_a_counting_loop() {
        let mut h = Harness::new(&[
            0x22, 0xA0, 0x03, // 0x00 movi a2, 3
            0x32, 0xA0, 0x00, // 0x03 movi a3, 0
            0x32, 0xC3, 0x01, // 0x06 addi a3, a3, 1
            0x22, 0xC2, 0xFF, // 0x09 addi a2, a2, -1
            0x56, 0x62, 0xFF, // 0x0C bnez a2, 0x06
            0x80, 0x00, 0x00, // 0x0F ret
        ]);
        assert_eq!(h.run(1000), HaltReason::Returned);
        assert_eq!((h.reg(2), h.reg(3)), (0, 3));
    }

    #[test]
    fn call0_clobbers_a0_so_the_caller_must_spill_it() {
        // 0x00 s32i a0, a1, 0   ; save the incoming return address
        // 0x03 call0 0x14       ; a0 <- 0x06, jump to the callee
        // 0x06 l32i a0, a1, 0   ; restore it
        // 0x09 movi a4, 1       ; proof that we came back
        // 0x0C ret              ; -> HALT_ADDRESS
        // 0x0F nop.n / nop      ; padding: call0 targets are 4-byte aligned
        // 0x14 movi a5, 7       ; the callee
        // 0x17 ret              ; -> 0x06
        let mut h = Harness::new(&[
            0x02, 0x61, 0x00, //
            0x05, 0x01, 0x00, //
            0x02, 0x21, 0x00, //
            0x42, 0xA0, 0x01, //
            0x80, 0x00, 0x00, //
            0x3D, 0xF0, //
            0xF0, 0x20, 0x00, //
            0x52, 0xA0, 0x07, //
            0x80, 0x00, 0x00, //
        ]);
        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!(h.reg(5), 7); // the callee ran
        assert_eq!(h.reg(4), 1); // and we came back
    }

    #[test]
    fn l32r_loads_a_literal_placed_before_the_code() {
        let mut h = Harness::new(&[]);
        h.bus.write32(IRAM_BASE, 0x3FF4_0000).unwrap();
        h.bus
            .write_block(
                IRAM_BASE + 4,
                &[
                    0x21, 0xFF, 0xFF, // l32r a2, -4
                    0x80, 0x00, 0x00, // ret
                ],
            )
            .unwrap();
        h.cpu.reset(IRAM_BASE + 4, esp32::initial_stack_pointer());

        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!(h.reg(2), 0x3FF4_0000);
    }

    #[test]
    fn a_jump_to_itself_halts_as_a_spin_loop() {
        let mut h = Harness::new(&[0x06, 0xFF, 0xFF]); // j .
        assert_eq!(h.run(100), HaltReason::SpinLoop);
        assert_eq!(h.cpu.steps(), 1);
    }

    #[test]
    fn the_step_budget_stops_a_runaway_program() {
        // An infinite loop that is not a fixed point, so only the budget can stop it.
        let mut h = Harness::new(&[
            0xF0, 0x20, 0x00, // 0x00 nop
            0x46, 0xFE, 0xFF, // 0x03 j -7 -> 0x00
        ]);
        assert_eq!(h.run(50), HaltReason::StepBudgetExhausted);
        assert_eq!(h.cpu.steps(), 50);
    }

    #[test]
    fn an_illegal_instruction_halts_with_a_fault() {
        let mut h = Harness::new(&[0x00, 0x00, 0x00]); // ILL
        assert!(matches!(
            h.run(100),
            HaltReason::Fault(Fault::Decode(DecodeError::Illegal { .. }))
        ));
    }

    #[test]
    fn an_unsupported_instruction_is_reported_separately() {
        let mut h = Harness::new(&[0x15, 0x00, 0x00]); // call4: needs register windows
        assert!(matches!(
            h.run(100),
            HaltReason::Fault(Fault::Decode(DecodeError::Unsupported { .. }))
        ));
    }

    #[test]
    fn a_store_to_an_unmapped_address_halts_with_a_bus_error() {
        let mut h = Harness::new(&[
            0x22, 0xA0, 0x00, // movi a2, 0
            0x22, 0x62, 0x00, // s32i a2, a2, 0
            0x80, 0x00, 0x00, // ret
        ]);
        assert_eq!(
            h.run(100),
            HaltReason::Fault(Fault::Bus(BusError::Unmapped { addr: 0 }))
        );
    }

    #[test]
    fn storing_to_the_uart_fifo_emits_a_byte() {
        let mut h = Harness::new(&[]);
        h.bus.write32(IRAM_BASE, UART0_BASE).unwrap();
        h.bus
            .write_block(
                IRAM_BASE + 4,
                &[
                    0x31, 0xFF, 0xFF, // l32r a3, -4   -> a3 = UART0 FIFO
                    0x22, 0xA0, 0x48, // movi a2, 'H'
                    0x22, 0x63, 0x00, // s32i a2, a3, 0
                    0x80, 0x00, 0x00, // ret
                ],
            )
            .unwrap();
        h.cpu.reset(IRAM_BASE + 4, esp32::initial_stack_pointer());

        assert_eq!(h.run(100), HaltReason::Returned);
        assert_eq!(h.bus.uart().pending(), b"H");
    }

    #[test]
    fn a_step_on_a_halted_cpu_is_a_no_op() {
        let mut h = Harness::new(&[0x80, 0x00, 0x00]); // ret
        assert_eq!(h.run(100), HaltReason::Returned);
        let steps = h.cpu.steps();
        assert_eq!(h.cpu.step(&mut h.bus), Ok(None));
        assert_eq!(h.cpu.steps(), steps);
    }
}
