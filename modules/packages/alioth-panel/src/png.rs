//! A minimal PNG writer, kept in-tree because the panel's build must not depend
//! on anything that can break on a foreign machine.
//!
//! Only the parts a screenshot needs: RGBA8, one IHDR, one IDAT made of stored
//! (uncompressed) deflate blocks, and IEND. These images exist to be looked at,
//! not to be small.

use std::fs::File;
use std::io::{BufWriter, Write};

fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (index, entry) in table.iter_mut().enumerate() {
        let mut value = index as u32;
        for _ in 0..8 {
            value = if value & 1 != 0 {
                0xEDB8_8320 ^ (value >> 1)
            } else {
                value >> 1
            };
        }
        *entry = value;
    }
    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc = table[((crc ^ *byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

fn adler32(data: &[u8]) -> u32 {
    let (mut low, mut high) = (1u32, 0u32);
    for byte in data {
        low = (low + *byte as u32) % 65521;
        high = (high + low) % 65521;
    }
    (high << 16) | low
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], body: &[u8]) {
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    let mut signed = kind.to_vec();
    signed.extend_from_slice(body);
    out.extend_from_slice(&signed);
    out.extend_from_slice(&crc32(&signed).to_be_bytes());
}

/// Write `rgba` — `width * height * 4` bytes, top row first — as a PNG.
pub fn write(path: &str, width: u32, height: u32, rgba: &[u8]) -> Result<(), String> {
    let stride = width as usize * 4;
    if rgba.len() < stride * height as usize {
        return Err(format!("short canvas: {} bytes", rgba.len()));
    }

    // Raw scanlines, each prefixed with filter type 0.
    let mut raw = Vec::with_capacity((stride + 1) * height as usize);
    for row in 0..height as usize {
        raw.push(0);
        raw.extend_from_slice(&rgba[row * stride..(row + 1) * stride]);
    }

    // A zlib stream around stored deflate blocks.
    let mut zlib = vec![0x78, 0x01];
    let mut offset = 0;
    while offset < raw.len() {
        let take = (raw.len() - offset).min(u16::MAX as usize);
        let last = offset + take >= raw.len();
        zlib.push(if last { 1 } else { 0 });
        zlib.extend_from_slice(&(take as u16).to_le_bytes());
        zlib.extend_from_slice(&(!(take as u16)).to_le_bytes());
        zlib.extend_from_slice(&raw[offset..offset + take]);
        offset += take;
    }
    zlib.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut header = Vec::new();
    header.extend_from_slice(&width.to_be_bytes());
    header.extend_from_slice(&height.to_be_bytes());
    header.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit depth, RGBA
    chunk(&mut png, b"IHDR", &header);
    chunk(&mut png, b"IDAT", &zlib);
    chunk(&mut png, b"IEND", &[]);

    let mut file = BufWriter::new(File::create(path).map_err(|error| error.to_string())?);
    file.write_all(&png).map_err(|error| error.to_string())?;
    file.flush().map_err(|error| error.to_string())
}
