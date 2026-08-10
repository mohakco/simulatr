//! Instruction trace: one JSON object per executed instruction.
//!
//! ```text
//! {"step":3,"pc":"0x40080006","raw":"0x0020c0","len":3,"op":"memw","a":["0x0", ...]}
//! ```
//!
//! JSON *Lines* — one self-contained object per line, no enclosing array — so it streams,
//! greps, and pipes into `jq` while the run is still going.
//!
//! Rendered by hand rather than with `serde`: `simulatr-core` has no dependencies by
//! design, and the shape is fixed enough that a serializer would add surface without
//! adding correctness. Formatting into a caller-supplied `String` keeps this pure, so the
//! crate still does no I/O.

use crate::cpu::core::Executed;
use core::fmt::Write as _;

/// Append one trace line, including its terminating newline.
pub fn write_json_line(out: &mut String, step: u64, executed: &Executed, regs: &[u32; 16]) {
    let Executed { pc, word, decoded } = executed;

    // Writing into a String is infallible; the only error `write!` can surface here comes
    // from a Display impl, and none of ours fail.
    let _ = write!(
        out,
        r#"{{"step":{step},"pc":"{pc:#010x}","raw":"0x{word:06x}","len":{len},"op":"{op}","a":["#,
        len = decoded.size.bytes(),
        op = decoded.mnemonic(),
    );

    for (i, value) in regs.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let _ = write!(out, r#""{value:#x}""#);
    }

    out.push_str("]}\n");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cpu::decode::{Decoded, Inst, InstSize, Reg};

    fn executed(inst: Inst, size: InstSize, pc: u32, word: u32) -> Executed {
        Executed { pc, word, decoded: Decoded { inst, size } }
    }

    #[test]
    fn line_shape() {
        let mut regs = [0u32; 16];
        regs[2] = 0x48;

        let mut out = String::new();
        write_json_line(
            &mut out,
            7,
            &executed(
                Inst::Movi { dst: Reg::new(2), imm: 0x48 },
                InstSize::Wide,
                0x4008_0000,
                0x4822_A0,
            ),
            &regs,
        );

        assert!(out.starts_with(r#"{"step":7,"pc":"0x40080000","#));
        assert!(out.contains(r#""raw":"0x4822a0""#));
        assert!(out.contains(r#""len":3"#));
        assert!(out.contains(r#""op":"movi""#));
        assert!(out.contains(r#""a":["0x0","0x0","0x48","#));
        assert!(out.ends_with("]}\n"));
    }

    #[test]
    fn narrow_instructions_report_their_narrow_mnemonic() {
        let mut out = String::new();
        write_json_line(
            &mut out,
            1,
            &executed(
                Inst::Movi { dst: Reg::new(5), imm: 5 },
                InstSize::Narrow,
                0x4008_000E,
                0x550C,
            ),
            &[0; 16],
        );
        assert!(out.contains(r#""op":"movi.n""#));
        assert!(out.contains(r#""len":2"#));
        assert!(out.contains(r#""raw":"0x00550c""#));
    }

    #[test]
    fn every_register_appears_exactly_once() {
        let mut regs = [0u32; 16];
        for (i, r) in regs.iter_mut().enumerate() {
            *r = i as u32;
        }

        let mut out = String::new();
        write_json_line(
            &mut out,
            0,
            &executed(Inst::Nop, InstSize::Wide, 0, 0x0020F0),
            &regs,
        );

        // Five commas separate the six scalar fields, plus fifteen between the registers.
        assert_eq!(out.matches(',').count(), 5 + 15);
        assert!(out.contains(r#""0xf"]"#));
    }

    #[test]
    fn lines_are_independent_and_appendable() {
        let mut out = String::new();
        let e = executed(Inst::Nop, InstSize::Wide, 0x4008_0000, 0x0020F0);
        write_json_line(&mut out, 1, &e, &[0; 16]);
        write_json_line(&mut out, 2, &e, &[0; 16]);
        assert_eq!(out.lines().count(), 2);
        assert!(out.lines().all(|line| line.starts_with('{') && line.ends_with('}')));
    }
}
