#!/usr/bin/env python3
"""Assemble an injected app image: drop a code blob into free flash, redirect main()'s final call
to it, and fix the boot CRC. Output boots the stock firmware normally, then runs our code.

  python inject_patch.py --blob game/inject.bin         # -> firmware/app_game.img
Defaults match the reversed layout:
  --at   0x8002C000  (blob load address, inside the 336 KB blank region at 0x8002BEDC+)
  --hook 0x80014AE4  (pointer word main() calls last; stock value 0x800136EC = main loop)
  --entry defaults to --at
"""
import sys, struct, zlib, argparse

APP_CRC_LEN = 0x6FFFC
BASE = 0x80010000

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blob", required=True)
    ap.add_argument("--at", default="0x8002C000")
    ap.add_argument("--hook", default="0x80014AE4")
    ap.add_argument("--entry")
    ap.add_argument("--in", dest="inp", default="app.img")
    ap.add_argument("--out", default="firmware/app_game.img")
    a = ap.parse_args()
    at, hook = int(a.at, 0), int(a.hook, 0)
    entry = int(a.entry, 0) if a.entry else at
    d = bytearray(open(a.inp, "rb").read())
    blob = open(a.blob, "rb").read()
    boff = at - BASE
    if boff + len(blob) > len(d):
        sys.exit("blob overruns image")
    if any(b != 0xFF for b in d[boff:boff + len(blob)]):
        sys.exit(f"refusing: target 0x{at:08X}+{len(blob)} is not blank 0xFF")
    d[boff:boff + len(blob)] = blob
    hoff = hook - BASE
    old = struct.unpack(">I", d[hoff:hoff + 4])[0]
    d[hoff:hoff + 4] = struct.pack(">I", entry)
    d[0:4] = struct.pack(">I", zlib.crc32(bytes(d[4:4 + APP_CRC_LEN])) & 0xFFFFFFFF)
    open(a.out, "wb").write(d)
    dd = open(a.out, "rb").read()
    ok = struct.unpack(">I", dd[:4])[0] == zlib.crc32(dd[4:4 + APP_CRC_LEN]) & 0xFFFFFFFF
    print(f"blob {len(blob)}B @0x{at:08X}; hook 0x{hook:08X}: 0x{old:08X} -> 0x{entry:08X}; "
          f"CRC {'OK' if ok else 'MISMATCH'}")
    print(f"wrote {a.out}. flash it, then POWER-CYCLE. Restore = flash app.img.")

if __name__ == "__main__":
    main()
