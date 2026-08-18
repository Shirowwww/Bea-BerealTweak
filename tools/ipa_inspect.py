#!/usr/bin/env python3
"""Read a decrypted BeReal IPA without unpacking it, a device, or a Mac.

Every non-obvious fact this tweak depends on - which classes exist, what the
ad SDK inventory is, the -primary/-secondary CDN convention, the localized
"Post to view" copy - came out of one of these four subcommands. Reach for
this *before* writing a hook, not after a round of on-device guessing.

    python tools/ipa_inspect.py frameworks BeReal.ipa
    python tools/ipa_inspect.py strings    BeReal.ipa 'Advert|SparkAds'
    python tools/ipa_inspect.py classes    BeReal.ipa 'HostingController'
    python tools/ipa_inspect.py loc        BeReal.ipa 'post to view' [--lang fr]

CAVEAT that has bitten this project: a *generic* Swift class's ObjC runtime
name (`_TtGC6BeReal25HomeViewHostingControllerVS_8HomeView_`) is assembled at
runtime and is not a static string anywhere in the binary. `strings` finding
nothing therefore proves nothing about a generic class. Search for the bare
type name instead, and match on substrings at runtime.
"""
import argparse
import plistlib
import re
import sys
import zipfile

APP_PREFIX = "Payload/"
STRING_RE = re.compile(rb"[ -~]{4,200}")
PAIR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)


def app_dir(z):
    names = {n.split("/")[1] for n in z.namelist()
             if n.startswith(APP_PREFIX) and n.count("/") >= 2}
    apps = sorted(n for n in names if n.endswith(".app"))
    if len(apps) != 1:
        sys.exit("expected exactly one .app in Payload/, found %s" % apps)
    return APP_PREFIX + apps[0]


def executable(z):
    app = app_dir(z)
    info = plistlib.loads(z.read("%s/Info.plist" % app))
    return z.read("%s/%s" % (app, info["CFBundleExecutable"]))


def cmd_frameworks(z, _args):
    """Every embedded framework. This is how BeaAdBlocker's SDK list was built."""
    app = app_dir(z)
    found = set()
    for n in z.namelist():
        marker = "%s/Frameworks/" % app
        if n.startswith(marker):
            rest = n[len(marker):].split("/")[0]
            if rest:
                found.add(rest)
    for name in sorted(found):
        print(name)


def cmd_strings(z, args):
    """Printable strings in the main binary matching a regex."""
    data = executable(z)
    pattern = re.compile(args.pattern, re.I)
    seen = set()
    for m in STRING_RE.finditer(data):
        s = m.group().decode("utf-8", "replace")
        if pattern.search(s) and s not in seen:
            seen.add(s)
            print(s)
    print("\n%d unique match(es)" % len(seen), file=sys.stderr)


def cmd_classes(z, args):
    """Swift/ObjC class symbols (_TtC...) matching a regex.

    Note this only sees non-generic classes; see the module docstring.
    """
    data = executable(z)
    pattern = re.compile(args.pattern, re.I)
    found = {m.group().decode() for m in re.finditer(rb"_TtC[0-9A-Za-z_]{4,180}", data)}
    for name in sorted(n for n in found if pattern.search(n)):
        print(name)


def _load_strings(z, lang):
    app = app_dir(z)
    path = "%s/Localisation_Localisation.bundle/%s.lproj/Localizable.strings" % (app, lang)
    raw = z.read(path)
    if raw[:6] == b"bplist":
        return plistlib.loads(raw)
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8")
    return dict(PAIR_RE.findall(text))


def _languages(z):
    app = app_dir(z)
    marker = "%s/Localisation_Localisation.bundle/" % app
    return sorted({n[len(marker):].split(".lproj")[0]
                   for n in z.namelist()
                   if n.startswith(marker) and n.endswith("Localizable.strings")})


def cmd_loc(z, args):
    """Find the localization KEY behind some English UI copy, then show it in
    every language.

    This is the fix for the single worst class of bug in this repo: matching
    BeReal's on-screen text against a hardcoded English literal, which does
    nothing on the ~14 other languages it ships. Find the key here, then read
    it at runtime from the app's own bundle (see +gatingCopyNeedles in
    BeaDownloader.m) rather than hardcoding any translation.
    """
    langs = _languages(z)
    english = _load_strings(z, "en")
    pattern = re.compile(args.pattern, re.I)

    keys = [k for k, v in english.items() if isinstance(v, str) and pattern.search(v)]
    if not keys:
        sys.exit("no English string matched %r (searched %d keys)" % (args.pattern, len(english)))

    wanted = [args.lang] if args.lang else langs
    tables = {}
    for lang in wanted:
        try:
            tables[lang] = _load_strings(z, lang)
        except KeyError:
            pass

    for key in sorted(keys):
        print("\n%s" % key)
        for lang in wanted:
            value = tables.get(lang, {}).get(key)
            if value is not None:
                print("    %-6s %s" % (lang, value))


def main():
    # BeReal ships Japanese, Korean, Hindi and Traditional Chinese, none of
    # which survive a Windows console's default cp1252 encoding - and this
    # repo is maintained from Windows.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("frameworks", help="list embedded frameworks")
    p.add_argument("ipa")
    p.set_defaults(func=cmd_frameworks)

    for name, fn, helptext in [("strings", cmd_strings, "grep the main binary's strings"),
                               ("classes", cmd_classes, "grep class symbols"),
                               ("loc", cmd_loc, "find localized UI copy by key")]:
        p = sub.add_parser(name, help=helptext)
        p.add_argument("ipa")
        p.add_argument("pattern")
        if name == "loc":
            p.add_argument("--lang", help="only this language (default: all)")
        p.set_defaults(func=fn)

    args = ap.parse_args()
    with zipfile.ZipFile(args.ipa) as z:
        args.func(z, args)


if __name__ == "__main__":
    main()
