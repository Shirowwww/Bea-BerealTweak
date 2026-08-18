"""Minimal Mach-O surgery: insert LC_LOAD_DYLIB, rewrite LC_ID_DYLIB, inspect."""
import struct

MH_MAGIC_64 = 0xfeedfacf
FAT_MAGIC = 0xcafebabe
FAT_MAGIC_64 = 0xcafebabf
LC_REQ_DYLD = 0x80000000
LC_ID_DYLIB = 0xd
LC_LOAD_DYLIB = 0xc
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1f | LC_REQ_DYLD
LC_RPATH = 0x1c | LC_REQ_DYLD
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1d
LC_ENCRYPTION_INFO_64 = 0x2c
CPU_TYPES = {0x100000c: "arm64", 0xc: "armv7", 0x1000007: "x86_64"}


def slices(data):
    """Yield (offset, size) of each Mach-O slice (thin file -> one slice)."""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack_from(">I", data, 4)[0]
        for i in range(n):
            if magic == FAT_MAGIC:
                _, _, off, size, _ = struct.unpack_from(">iiIII", data, 8 + 20 * i)
            else:
                _, _, off, size, _, _ = struct.unpack_from(">iiQQII", data, 8 + 32 * i)
            yield off, size
    else:
        yield 0, len(data)


def commands(data, off):
    """Yield (cmd, cmdsize, pos) for each load command of the slice at off."""
    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, off)
    assert magic == MH_MAGIC_64, "only 64-bit Mach-O supported (got %x)" % magic
    p = off + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        yield cmd, cmdsize, p
        p += cmdsize


def lcstr(data, pos, cmdsize):
    off = struct.unpack_from("<I", data, pos + 8)[0]
    return data[pos + off:pos + cmdsize].split(b"\0")[0].decode()


def describe(data, off=0):
    """Return a dict summarising one slice."""
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = \
        struct.unpack_from("<IiiIIIII", data, off)
    info = {"arch": CPU_TYPES.get(cputype, hex(cputype)), "filetype": filetype,
            "ncmds": ncmds, "sizeofcmds": sizeofcmds, "dylibs": [], "weak": [],
            "rpaths": [], "id": None, "cryptid": None, "codesig": None,
            "min_section_offset": None}
    for cmd, cmdsize, p in commands(data, off):
        if cmd == LC_LOAD_DYLIB:
            info["dylibs"].append(lcstr(data, p, cmdsize))
        elif cmd == LC_LOAD_WEAK_DYLIB:
            info["weak"].append(lcstr(data, p, cmdsize))
        elif cmd == LC_ID_DYLIB:
            info["id"] = lcstr(data, p, cmdsize)
        elif cmd == LC_RPATH:
            info["rpaths"].append(lcstr(data, p, cmdsize))
        elif cmd == LC_ENCRYPTION_INFO_64:
            info["cryptid"] = struct.unpack_from("<I", data, p + 16)[0]
        elif cmd == LC_CODE_SIGNATURE:
            info["codesig"] = struct.unpack_from("<II", data, p + 8)
        elif cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            sp = p + 72
            for _ in range(nsects):
                so = struct.unpack_from("<I", data, sp + 48)[0]
                if so and (info["min_section_offset"] is None or so < info["min_section_offset"]):
                    info["min_section_offset"] = so
                sp += 80
    info["header_end"] = off + 32 + sizeofcmds
    return info


def _dylib_command(cmd, path, timestamp=2, cur=0x10000, compat=0x10000, cmdsize=None):
    raw = path.encode() + b"\0"
    need = (24 + len(raw) + 7) & ~7
    if cmdsize is None or cmdsize < need:
        cmdsize = need                       # otherwise keep the caller's size
    return struct.pack("<IIIIII", cmd, cmdsize, 24, timestamp, cur, compat) +         raw.ljust(cmdsize - 24, b"\0")


def _slack(data, off):
    info = describe(data, off)
    limit = info["min_section_offset"]
    if limit is None:                       # no sections: use the first segment's data
        limit = min((struct.unpack_from("<Q", data, p + 40)[0]
                     for cmd, _, p in commands(data, off)
                     if cmd == LC_SEGMENT_64 and struct.unpack_from("<Q", data, p + 40)[0]),
                    default=len(data) - off)
    return info["header_end"], off + limit


def insert_load_dylib(data, path, weak=False):
    """Append an LC_LOAD_DYLIB to every slice, using the header's zero padding."""
    data = bytearray(data)
    for off, _ in slices(bytes(data)):
        cmd = _dylib_command(LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB, path)
        end, limit = _slack(bytes(data), off)
        if end + len(cmd) > limit:
            raise RuntimeError("not enough header padding: need %d, have %d"
                               % (len(cmd), limit - end))
        if any(data[end:end + len(cmd)]):
            raise RuntimeError("header padding is not zero-filled; refusing to overwrite")
        data[end:end + len(cmd)] = cmd
        ncmds, sizeofcmds = struct.unpack_from("<II", data, off + 16)
        struct.pack_into("<II", data, off + 16, ncmds + 1, sizeofcmds + len(cmd))
    return bytes(data)


def set_dylib_id(data, path):
    """Rewrite LC_ID_DYLIB in place.

    A shorter name keeps the original cmdsize (zero-padded, the way
    install_name_tool does it) so no other load command has to move; only a
    longer one grows the command and shifts the rest into header padding.
    """
    data = bytearray(data)
    for off, _ in slices(bytes(data)):
        for cmd, cmdsize, p in list(commands(bytes(data), off)):
            if cmd != LC_ID_DYLIB:
                continue
            new = _dylib_command(LC_ID_DYLIB, path,
                                 *struct.unpack_from("<III", data, p + 12),
                                 cmdsize=cmdsize)
            if len(new) == cmdsize:
                data[p:p + cmdsize] = new
            else:
                end, limit = _slack(bytes(data), off)
                grow = len(new) - cmdsize
                if end + grow > limit:
                    raise RuntimeError("not enough header padding to grow LC_ID_DYLIB")
                tail = bytes(data[p + cmdsize:end])
                data[p:p + len(new)] = new
                data[p + len(new):p + len(new) + len(tail)] = tail
                _, sizeofcmds = struct.unpack_from("<II", data, off + 16)
                struct.pack_into("<I", data, off + 20, sizeofcmds + grow)
            break
    return bytes(data)
