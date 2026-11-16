// SPDX-License-Identifier: Apache-2.0
// Dump BTF struct layouts from an Android boot image / arm64 Image.
use std::path::Path;

use timer_extract::boot::BootImage;
use timer_extract::btf::Btf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: dumpbtf <boot.img|Image> <StructName> [StructName...]");
        std::process::exit(2);
    }
    let boot = BootImage::load(Path::new(&args[1]))?;
    let btf_ref = boot.embedded_btf_at();
    let (_, blob) = btf_ref
        .as_ref()
        .ok_or("kernel carries no embedded BTF")?;
    let btf = Btf::new(blob)?;

    for name in &args[2..] {
        println!("=== {} ===", name);
        let Some(t) = btf.named_struct(name) else {
            println!("  (not found)");
            continue;
        };
        if let Some(sz) = btf.size(name) {
            println!("  size = {} (0x{:x})", sz, sz);
        }
        for m in &t.members {
            let off = m.bit_offset / 8;
            let bit = m.bit_offset % 8;
            let tsz = btf.type_size(m.type_id).unwrap_or(0);
            println!(
                "  +0x{:03x} ({:>4})  {:<26} type_id={:<6} size={}{}",
                off,
                off,
                m.name,
                m.type_id,
                tsz,
                if bit != 0 {
                    format!("  bitoff={}", bit)
                } else {
                    String::new()
                }
            );
        }
        println!();
    }
    Ok(())
}
