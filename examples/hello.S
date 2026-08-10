/*
 * hello.S - the Phase 1 POC firmware, in real Xtensa assembly.
 *
 * Writes "HELLO" one byte at a time into the ESP32's UART0 TX FIFO, then spins.
 * Nothing else: no ESP-IDF, no FreeRTOS, no C runtime, no stack usage.
 *
 * Build it with ../examples/build.sh (or `zig build firmware`), which explains the two
 * non-obvious GCC flags. Then:
 *
 *     simulatr run hello.elf
 *     xtensa-esp-elf-objdump -d hello.elf
 *
 * Note that GCC compiles most of the loop body into 16-bit narrow forms - movi.n,
 * s32i.n, addi.n - even though this source spells the wide mnemonics. That is the Code
 * Density option doing its job, and it is why the decoder has to handle both widths.
 */

	.section .text.start, "ax"

	/* Tell the assembler to park L32R literals here, immediately before the code.
	 * L32R's offset field is always negative, so its literal pool must precede it. */
	.literal_position
	.literal .Luart_fifo, 0x3FF40000   /* UART_FIFO_REG for UART0 */
	.literal .Lmessage,   .Lmsg

	.global _start
	.type   _start, @function
	.align  4
_start:
	l32r    a3, .Luart_fifo     /* a3 = address of the TX FIFO register */
	l32r    a4, .Lmessage       /* a4 = address of the message */
	movi    a5, 5               /* a5 = bytes remaining */

.Lloop:
	l8ui    a2, a4, 0           /* a2 = *a4 */
	s32i    a2, a3, 0           /* push the byte into the TX FIFO */
	addi    a4, a4, 1
	addi    a5, a5, -1
	bnez    a5, .Lloop

	/* Firmware never returns to anything, so spin. simulatr treats a jump to itself
	 * as "the program is finished" and stops. */
.Lspin:
	j       .Lspin

	.size   _start, . - _start

	.section .rodata
	.align  4
.Lmsg:
	.ascii  "HELLO"
	.byte   0, 0, 0
