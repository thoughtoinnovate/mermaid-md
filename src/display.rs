use std::fs;
use std::io::{self, Write};
use std::path::Path;

use anyhow::{Context, Result};
use base64::Engine;

const CHUNK_SIZE: usize = 4096;

fn write_apc(prefix: &str, payload: &str) -> io::Result<()> {
    let mut out = io::stdout().lock();
    write!(out, "\x1b_G{};{}\x1b\\", prefix, payload)?;
    out.flush()
}

pub fn clear_inline() -> Result<()> {
    // Delete all visible image placements in terminals that support Kitty graphics protocol.
    write_apc("a=d,d=A", "").context("send kitty protocol clear")
}

pub fn show_inline(path: &Path) -> Result<()> {
    let bytes = fs::read(path).with_context(|| format!("read image {}", path.display()))?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);

    for (idx, chunk) in encoded.as_bytes().chunks(CHUNK_SIZE).enumerate() {
        let chunk = std::str::from_utf8(chunk).context("base64 chunk utf8")?;
        let is_last = (idx + 1) * CHUNK_SIZE >= encoded.len();
        let more = if is_last { 0 } else { 1 };

        if idx == 0 {
            write_apc(&format!("a=T,f=100,t=d,m={}", more), chunk)
                .context("send kitty image payload")?;
        } else {
            write_apc(&format!("m={}", more), chunk).context("send kitty continuation payload")?;
        }
    }

    // Keep output readable after image render in regular shells.
    println!();
    Ok(())
}
