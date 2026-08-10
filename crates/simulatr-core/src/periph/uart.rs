//! UART0 transmit — the only peripheral in Phase 1.
//!
//! Real hardware: firmware writes a byte to `UART_FIFO_REG`, it enters a 128-byte FIFO,
//! and the transmitter shifts it out a pin at the configured baud rate. Firmware polls
//! `UART_STATUS_REG`'s TXFIFO_CNT to avoid overflowing the FIFO.
//!
//! Our model: a write to `UART_FIFO_REG` appends to `tx`, and TXFIFO_CNT always reads 0
//! ("the FIFO is empty, go ahead"). Transmission is instantaneous, so we can neither
//! overflow nor stall, and there is no baud rate because there is no clock model yet.
//! Configuration registers (baud divider, line control, interrupt enables) accept writes
//! and discard them — firmware configures the UART before using it and must not fault
//! while doing so.
//!
//! The peripheral never writes to a host stream and never calls back into the CPU: it
//! accumulates bytes, and the run loop drains them into an [`Observer`](crate::Observer)
//! after each instruction. That is the "peripherals return events" rule from
//! `docs/PLAN.md` — it is what keeps the emulator a tree of owned values instead of a
//! cyclic graph needing `Rc<RefCell<_>>`.

use crate::soc::esp32::uart_reg;

#[derive(Default, Debug)]
pub struct Uart {
    /// Bytes transmitted since the last drain. Never more than one instruction's worth.
    tx: Vec<u8>,
    transmitted: u64,
}

impl Uart {
    pub fn new() -> Self {
        Self::default()
    }

    /// Handle a write inside the UART0 register block. `offset` is relative to
    /// `soc::esp32::UART0_BASE`.
    pub fn write_reg(&mut self, offset: u32, value: u32) {
        match offset {
            // Only the low 8 bits reach the shift register.
            uart_reg::FIFO => {
                self.tx.push(value as u8);
                self.transmitted += 1;
            }
            // Baud rate, line control, interrupt masks, ...: accepted and discarded.
            _ => {}
        }
    }

    /// Handle a read inside the UART0 register block.
    pub fn read_reg(&self, offset: u32) -> u32 {
        match offset {
            // TXFIFO_CNT (23:16) = 0 and RXFIFO_CNT (7:0) = 0, so a firmware loop that
            // spins until there is room in the TX FIFO exits immediately.
            uart_reg::STATUS => 0,
            // Phase 1 has no RX path, so the FIFO always reads empty.
            uart_reg::FIFO => 0,
            _ => 0,
        }
    }

    /// Bytes transmitted but not yet drained.
    pub fn pending(&self) -> &[u8] {
        &self.tx
    }

    /// Take everything transmitted since the last call.
    pub fn take_pending(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.tx)
    }

    pub fn clear_pending(&mut self) {
        self.tx.clear();
    }

    /// Total bytes ever transmitted, across drains.
    pub fn transmitted(&self) -> u64 {
        self.transmitted
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writing_the_fifo_register_transmits_the_low_byte() {
        let mut uart = Uart::new();
        uart.write_reg(uart_reg::FIFO, u32::from(b'H'));
        uart.write_reg(uart_reg::FIFO, u32::from(b'I'));
        // Only 0x21 ('!') is transmitted; the high bits are ignored by hardware.
        uart.write_reg(uart_reg::FIFO, 0x0000_FF21);

        assert_eq!(uart.pending(), b"HI!");
        assert_eq!(uart.transmitted(), 3);
    }

    #[test]
    fn configuration_registers_are_accepted_and_ignored() {
        let mut uart = Uart::new();
        uart.write_reg(0x14, 0x0000_02B6); // UART_CLKDIV_REG, 115200 baud @ 80 MHz
        uart.write_reg(0x20, 0x0000_001C); // UART_CONF0_REG
        assert!(uart.pending().is_empty());
    }

    #[test]
    fn status_register_reports_an_empty_tx_fifo() {
        let uart = Uart::new();
        let txfifo_cnt = (uart.read_reg(uart_reg::STATUS) >> 16) & 0xFF;
        assert_eq!(txfifo_cnt, 0);
    }

    #[test]
    fn draining_clears_the_buffer_but_not_the_running_total() {
        let mut uart = Uart::new();
        uart.write_reg(uart_reg::FIFO, u32::from(b'A'));
        assert_eq!(uart.take_pending(), b"A");
        assert!(uart.pending().is_empty());
        assert_eq!(uart.transmitted(), 1);
    }
}
