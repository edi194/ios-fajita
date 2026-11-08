//! LZVN decoder (the raw opcode stream decmpfs stores; the opcode table is Apple's reference decoder's).

use crate::io::bad;
use std::io::Result;

enum Op {
    SmlD,
    MedD,
    LrgD,
    PreD,
    SmlM,
    LrgM,
    SmlL,
    LrgL,
    Nop,
    Eos,
    Undef,
}

fn classify(op: u8) -> Op {
    match op {
        0x06 => Op::Eos,
        0x0e | 0x16 => Op::Nop,
        0xe0 => Op::LrgL,
        0xe1..=0xef => Op::SmlL,
        0xf0 => Op::LrgM,
        0xf1..=0xff => Op::SmlM,
        0x70..=0x7f | 0xd0..=0xdf => Op::Undef,
        0xa0..=0xbf => Op::MedD,
        _ => match op & 7 {
            0..=5 => Op::SmlD,
            7 => Op::LrgD,
            // 'x110': the previous distance, except in the undefined opcodes below 0x40
            _ if op >= 0x40 => Op::PreD,
            _ => Op::Undef,
        },
    }
}

/// Decodes a raw LZVN stream into at most `out_len` bytes (the stream is cut off at that length, as
/// Apple's decoder does, and stops at its end-of-stream opcode or when the input ends).
pub(crate) fn decode(src: &[u8], out_len: usize) -> Result<Vec<u8>> {
    let mut dst: Vec<u8> = Vec::with_capacity(out_len);
    let mut i = 0usize;
    let mut dprev = 0usize;
    while dst.len() < out_len {
        let Some(&op) = src.get(i) else { break };
        let (l, m, d, oplen);
        match classify(op) {
            Op::SmlD => {
                let b = *src.get(i + 1).ok_or_else(|| bad("LZVN: truncated opcode"))? as usize;
                l = (op >> 6) as usize;
                m = ((op >> 3) & 7) as usize + 3;
                d = ((op & 7) as usize) << 8 | b;
                oplen = 2;
            }
            Op::MedD => {
                let b = src.get(i + 1..i + 3).ok_or_else(|| bad("LZVN: truncated opcode"))?;
                let w = u16::from_le_bytes([b[0], b[1]]) as usize;
                l = ((op >> 3) & 3) as usize;
                m = (((op & 7) as usize) << 2 | (w & 3)) + 3;
                d = w >> 2;
                oplen = 3;
            }
            Op::LrgD => {
                let b = src.get(i + 1..i + 3).ok_or_else(|| bad("LZVN: truncated opcode"))?;
                l = (op >> 6) as usize;
                m = ((op >> 3) & 7) as usize + 3;
                d = u16::from_le_bytes([b[0], b[1]]) as usize;
                oplen = 3;
            }
            Op::PreD => {
                l = (op >> 6) as usize;
                m = ((op >> 3) & 7) as usize + 3;
                d = dprev;
                oplen = 1;
            }
            Op::SmlM => {
                l = 0;
                m = (op & 15) as usize;
                d = dprev;
                oplen = 1;
            }
            Op::LrgM => {
                let b = *src.get(i + 1).ok_or_else(|| bad("LZVN: truncated opcode"))? as usize;
                l = 0;
                m = b + 16;
                d = dprev;
                oplen = 2;
            }
            Op::SmlL => {
                l = (op & 15) as usize;
                m = 0;
                d = dprev;
                oplen = 1;
            }
            Op::LrgL => {
                let b = *src.get(i + 1).ok_or_else(|| bad("LZVN: truncated opcode"))? as usize;
                l = b + 16;
                m = 0;
                d = dprev;
                oplen = 2;
            }
            Op::Nop => {
                i += 1;
                continue;
            }
            Op::Eos => break,
            Op::Undef => return Err(bad(format!("LZVN: undefined opcode {op:#x}"))),
        }
        i += oplen;
        let lit = src.get(i..i + l).ok_or_else(|| bad("LZVN: truncated literal"))?;
        i += l;
        let room = out_len - dst.len();
        dst.extend_from_slice(&lit[..l.min(room)]);
        if m > 0 {
            if d == 0 || d > dst.len() {
                return Err(bad("LZVN: match distance out of range"));
            }
            dprev = d;
            let m = m.min(out_len - dst.len());
            let start = dst.len() - d;
            for k in 0..m {
                let b = dst[start + k];
                dst.push(b);
            }
        }
    }
    Ok(dst)
}
