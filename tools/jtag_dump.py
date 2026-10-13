# Dump a flash/RAM range over JTAG/SAB to a file (bootloader lives at 0x80000000..0x80010000).
# Usage: python.exe tools/jtag_dump.py START LEN OUTFILE   (START/LEN accept 0x..)
import os, sys, pathlib, struct, time
import libusb_package
_dll = next(pathlib.Path(libusb_package.__file__).parent.rglob("libusb-1.0.dll"), None)
if _dll:
    os.add_dll_directory(str(_dll.parent))
    os.environ["PATH"] = str(_dll.parent) + os.pathsep + os.environ.get("PATH", "")
import usb.core, usb.backend.libusb1 as _lb
_backend = libusb_package.get_libusb1_backend()
_lb._lib = _backend.lib; _lb._backend = _backend; _lb.get_backend = lambda *a, **k: _backend
_of = usb.core.find
usb.core.find = lambda *a, **k: _of(*a, **{**k, "backend": k.get("backend") or _backend})
import pyftdi.usbtools as _ut
_gs = _ut.UsbTools.get_string.__func__
def _safe(cls, d, s):
    try: return _gs(cls, d, s)
    except Exception: return ""
_ut.UsbTools.get_string = classmethod(_safe)
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import jtag_flash

start, length, out = int(sys.argv[1], 0), int(sys.argv[2], 0), sys.argv[3]
jt = jtag_flash.jtag_open()
try:
    jtag_flash.enter_mwa(jt)
    buf = bytearray()
    t0 = time.time()
    for a in range(start, start + length, 4):
        buf += struct.pack(">I", jtag_flash.read_word(jt, a))
        if (a - start) % 0x1000 == 0:
            print(f"\r  {a-start:#x}/{length:#x}", end="", flush=True)
    open(out, "wb").write(buf)
    print(f"\n  wrote {len(buf)} bytes to {out} in {time.time()-t0:.0f}s")
finally:
    jt.close()
