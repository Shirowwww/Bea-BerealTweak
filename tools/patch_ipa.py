"""Inject the jailed MiniBea.dylib into a decrypted BeReal IPA (no macOS needed).

Rewrites the zip entry-by-entry so every other file keeps its original
permissions/attributes: only the main executable is replaced, the tweak dylib
added, and the app's now-stale _CodeSignature dropped (the sideload signer
regenerates it).
"""
import argparse, os, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import macho

DYLIB_REL = "Frameworks/MiniBea.dylib"
INSTALL_NAME = "@executable_path/" + DYLIB_REL


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("dylib")
    ap.add_argument("out")
    a = ap.parse_args()

    zin = zipfile.ZipFile(a.ipa)
    app = sorted({n.split("/")[1] for n in zin.namelist()
                  if n.startswith("Payload/") and n.count("/") >= 2})
    assert len(app) == 1, "expected exactly one .app in Payload: %s" % app
    app = app[0]
    exe_name = _executable_name(zin, app)
    exe_path = "Payload/%s/%s" % (app, exe_name)
    print("app bundle:", app, "| executable:", exe_name)

    exe = zin.read(exe_path)
    for off, _ in macho.slices(exe):
        i = macho.describe(exe, off)
        if i["cryptid"]:
            sys.exit("ERROR: %s slice is still encrypted (cryptid=1) - "
                     "a decrypted IPA is required." % i["arch"])
        if INSTALL_NAME in i["dylibs"]:
            sys.exit("ERROR: this IPA is already patched (%s)." % INSTALL_NAME)
    patched = macho.insert_load_dylib(exe, INSTALL_NAME)
    assert len(patched) == len(exe)

    dylib = macho.set_dylib_id(open(a.dylib, "rb").read(), INSTALL_NAME)

    dropped = 0
    with zipfile.ZipFile(a.out, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if item.filename.startswith("Payload/%s/_CodeSignature/" % app):
                dropped += 1
                continue
            data = patched if item.filename == exe_path else zin.read(item)
            new = zipfile.ZipInfo(item.filename, date_time=item.date_time)
            new.external_attr = item.external_attr
            new.internal_attr = item.internal_attr
            new.create_system = item.create_system
            new.compress_type = item.compress_type
            zout.writestr(new, data)
        info = zipfile.ZipInfo("Payload/%s/%s" % (app, DYLIB_REL))
        info.external_attr = (0o100755 << 16)      # -rwxr-xr-x, needed to load
        info.create_system = 3                     # unix
        info.compress_type = zipfile.ZIP_DEFLATED
        zout.writestr(info, dylib)

    print("dropped stale app signature entries:", dropped)
    print("wrote", a.out, "(%.1f MB)" % (os.path.getsize(a.out) / 1e6))


def _executable_name(zin, app):
    import plistlib
    p = plistlib.loads(zin.read("Payload/%s/Info.plist" % app))
    return p["CFBundleExecutable"]


if __name__ == "__main__":
    main()
