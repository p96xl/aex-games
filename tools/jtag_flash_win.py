# Windows-native runner for jtag_flash.py — bypasses the usbipd/WSL bridge (~16.6 ms/JTAG
# transaction) by talking to the Tigard through native libusb. Same pyftdi code, ~10-30x
# faster because each USB round-trip is sub-ms instead of a usbip network hop.
#
# One-time Windows setup (see FLASHING-FAST.md):
#   1. usbipd detach --busid 1-4   &&   usbipd unbind --busid 1-4   (admin PowerShell)
#   2. Zadig -> Options -> List All Devices -> "Tigard V1.1 (Interface 1)" -> WinUSB -> Replace Driver
#   3. pip already done: pyftdi + libusb-package on the Windows Python.
#
# Run (from WSL or a Windows shell), same args as jtag_flash.py:
#   python.exe tools/jtag_flash_win.py probe
#   python.exe tools/jtag_flash_win.py write --i-have-a-backup app.img
import os, sys, pathlib

# Pin the libusb-package DLL so pyusb's backend discovery can't miss it (it's unreliable on
# Windows otherwise). Belt (add_dll_directory) + suspenders (force it as pyusb's default backend).
import libusb_package
_dll = next(pathlib.Path(libusb_package.__file__).parent.rglob("libusb-1.0.dll"), None)
if _dll:
    os.add_dll_directory(str(_dll.parent))
    os.environ["PATH"] = str(_dll.parent) + os.pathsep + os.environ.get("PATH", "")

import usb.core, usb.backend.libusb1 as _lb
_backend = libusb_package.get_libusb1_backend()
# pyusb's default libusb DLL on this system raises LIBUSB_ERROR_NOT_SUPPORTED on libusb_open.
# The bundled (libusb-package) DLL opens the device fine. The catch: pyusb's _DeviceHandle calls
# the MODULE-GLOBAL `_lib.libusb_open`, not the backend instance's lib — so enumerating with the
# good backend but opening with the stale global still fails. Pin BOTH: the global lib, the
# cached backend, and get_backend(). (_backend.lib is the bundled ctypes DLL.)
_lb._lib = _backend.lib
_lb._backend = _backend
_lb.get_backend = lambda *a, **k: _backend
_orig_find = usb.core.find
usb.core.find = lambda *a, **k: _orig_find(*a, **{**k, "backend": k.get("backend") or _backend})

# pyftdi enumerates EVERY VID=0x0403 device and reads its string descriptor. A sibling FTDI on
# the stock driver (here 0403:6015) can't be libusb_open'd -> NOT_SUPPORTED, which aborts the
# whole scan before reaching the Tigard. Make the string read skip un-openable devices.
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
jtag_flash.main()   # reads sys.argv[1:] exactly like the native tool
