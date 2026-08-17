#!/usr/bin/env python3
"""Strip non-arm64(e) slices from a Mach-O fat binary, no lipo/llvm-lipo needed."""
import struct
import sys

FAT_MAGIC = 0xcafebabe
FAT_MAGIC_64 = 0xcafebabf
CPU_TYPE_ARM64 = 0x0100000c


def thin(in_path, out_path):
    with open(in_path, "rb") as f:
        data = f.read()

    magic = struct.unpack(">I", data[0:4])[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        raise SystemExit(f"Not a fat Mach-O (magic={magic:#x})")

    is64 = magic == FAT_MAGIC_64
    nfat = struct.unpack(">I", data[4:8])[0]

    entry_size = 32 if is64 else 20
    slices = []
    off = 8
    for _ in range(nfat):
        chunk = data[off:off + entry_size]
        if is64:
            cputype, cpusubtype, offset, size, align, _reserved = struct.unpack(">iiQQII", chunk)
        else:
            cputype, cpusubtype, offset, size, align = struct.unpack(">iiIII", chunk)
        slices.append({
            "cputype": cputype, "cpusubtype": cpusubtype,
            "offset": offset, "size": size, "align": align,
        })
        off += entry_size

    kept = [s for s in slices if s["cputype"] == CPU_TYPE_ARM64]
    dropped = [s for s in slices if s["cputype"] != CPU_TYPE_ARM64]
    if not kept:
        raise SystemExit("No arm64/arm64e slices found - refusing to produce an empty binary")

    print(f"Kept {len(kept)} slice(s), dropped {len(dropped)}:")
    for s in dropped:
        print(f"  dropped cputype={s['cputype']:#x} cpusubtype={s['cpusubtype']:#x}")
    for s in kept:
        print(f"  kept   cputype={s['cputype']:#x} cpusubtype={s['cpusubtype']:#x}")

    header_size = 8 + entry_size * len(kept)
    new_offset = header_size
    layout = []
    for s in kept:
        align_bytes = 1 << s["align"]
        new_offset = (new_offset + align_bytes - 1) // align_bytes * align_bytes
        layout.append((s, new_offset))
        new_offset += s["size"]

    out = bytearray()
    out += struct.pack(">I", magic)
    out += struct.pack(">I", len(kept))
    for s, new_off in layout:
        if is64:
            out += struct.pack(">iiQQII", s["cputype"], s["cpusubtype"], new_off, s["size"], s["align"], 0)
        else:
            out += struct.pack(">iiIII", s["cputype"], s["cpusubtype"], new_off, s["size"], s["align"])

    for s, new_off in layout:
        if len(out) < new_off:
            out += b"\x00" * (new_off - len(out))
        out += data[s["offset"]:s["offset"] + s["size"]]

    with open(out_path, "wb") as f:
        f.write(out)
    print(f"Wrote {out_path} ({len(out)} bytes, was {len(data)} bytes)")


if __name__ == "__main__":
    thin(sys.argv[1], sys.argv[2])
