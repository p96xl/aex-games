# Read memory words over JTAG/SAB after an nSRST reset-boot. Same Windows libusb backend setup as
# jtag_flash_win.py. Usage:  python.exe tools/jtag_peek.py [--boot SECS] ADDR [ADDR...]
# jtag_open() pulses nSRST, so the chip reboots into whatever is in flash; after --boot seconds
# (default 2.5) the words are read. This is the "force the chip to output over JTAG" channel: run
# firmware that writes a marker to RAM, then read that RAM address here. No serial needed.
import os, sys, pathlib, time

import libusb_package
_dll = next(pathlib.Path(libusb_package.__file__).parent.rglob("libusb-1.0.dll"), None)
if _dll:
    os.add_dll_directory(str(_dll.parent))
    os.environ["PATH"] = str(_dll.parent) + os.pathsep + os.environ.get("PATH", "")
import usb.core, usb.backend.libusb1 as _lb
_backend = libusb_package.get_libusb1_backend()
_lb._lib = _backend.lib
_lb._backend = _backend
_lb.get_backend = lambda *a, **k: _backend
_orig_find = usb.core.find
usb.core.find = lambda *a, **k: _orig_find(*a, **{**k, "backend": k.get("backend") or _backend})
import pyftdi.usbtools as _ut
_gs = _ut.UsbTools.get_string.__func__
def _safe_get_string(cls, device, stridx):
    try:
        return _gs(cls, device, stridx)
    except Exception:
        return ""
_ut.UsbTools.get_string = classmethod(_safe_get_string)

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import jtag_flash

args = sys.argv[1:]
boot = 2.5
poll = 0
poke = None
run = False
if args and args[0] == "--run":
    run = True; args = args[1:]          # resume core from reset-halt, let it run, then halt+read
if args and args[0] == "--boot":
    boot = float(args[1]); args = args[2:]
if args and args[0] == "--write":
    poke = (int(args[1], 0), int(args[2], 0)); args = args[3:]
if args and args[0] == "--poll":
    poll = int(args[1]); args = args[2:]
addrs = [int(a, 0) for a in args] or [0x0000F000, 0x80010000]

jt = jtag_flash.jtag_open()
try:
    idc = jtag_flash.enter_mwa(jt)
    if run:
        print(f"IDCODE 0x{idc:08X}; RESUMING core, running {boot}s, then halt+read...")
        jtag_flash.halt(jt, stop=False)   # resume from reset-halt -> core executes bootloader+app
        time.sleep(boot)
        jtag_flash.halt(jt, stop=True)    # halt the running core so SAB reads are coherent
    else:
        print(f"IDCODE 0x{idc:08X}; booting {boot}s then reading...")
        time.sleep(boot)
    if poke is not None:
        a, v = poke
        before = jtag_flash.read_word(jt, a)
        jtag_flash.write_word(jt, a, v)
        after = jtag_flash.read_word(jt, a)
        print(f"  SAB write test 0x{a:08X}: before=0x{before:08X} wrote=0x{v:08X} after=0x{after:08X} "
              f"-> {'WRITE OK' if after == v else 'WRITE FAILED'}")
    elif poll:
        # Read the first address repeatedly (no re-reset) to see if the free-running system changes
        # it over time: oscillation => reboot loop / our code flickering in; stable => static.
        a = addrs[0]
        for i in range(poll):
            v = jtag_flash.read_word(jt, a)
            print(f"  [{i:2d}] 0x{a:08X} = 0x{v:08X}")
            time.sleep(0.3)
    else:
        for a in addrs:
            v = jtag_flash.read_word(jt, a)
            print(f"  0x{a:08X} = 0x{v:08X}")
finally:
    jt.close()
