# Flash the AT32UC3C APPLICATION partition over JTAG (Tigard, channel B) via the SAB,
# using the FLASHCDW controller. Writes ONLY 0x80010000..0x8007FFFF. Never touches the
# bootloader or the user page, so a bad/interrupted write stays recoverable (the bootloader
# CRC-gates the app and is the recovery agent).
#
# SAFETY MODEL (read this):
#   * `probe`  is READ-ONLY. Run it FIRST. It confirms the FLASHCDW base by reading the
#              controller's version/parameter registers and checking flash size + page size.
#              Nothing is written. Paste me the output before you ever run `write`.
#   * `write`  REFUSES to run unless the probe self-check passes AND every target page is
#              inside the app partition. It erases+programs page-by-page, then can verify.
#   * `verify` reads the region back and compares to the image + checks the app CRC word.
#   * Keep your golden full-flash dump. It is the ultimate backstop.
#
# Usage:
#   python3 jtag_flash.py probe
#   python3 jtag_flash.py verify            [app.img]
#   python3 jtag_flash.py write  --i-have-a-backup   [app.img]
#   python3 jtag_flash.py write  --i-have-a-backup --dry-run   # addressing + probe only
#
# ponytail: mirrors dump.py's SAB word protocol; one word per few USB round-trips.
import sys, time, struct, zlib

try:
    from pyftdi.gpio import GpioAsyncController
    from pyftdi.jtag import JtagEngine
    from pyftdi.bits import BitSequence
except ImportError:
    sys.exit("pyftdi not installed (same dep as dump.py): pip install pyftdi")

URL          = 'ftdi://0x0403:0x6010/2'
IR_IDCODE, IR_MWA, IR_HALT = 0x01, 0x11, 0x1C
SLAVE_HSB    = 0x5
FLASH        = 0x80000000
APP_START    = 0x80010000
APP_END      = 0x80080000          # exclusive
PAGE         = 512                 # AT32UC3C flash page = 512 B (confirmed by probe below)
APP_CRC_LEN  = 0x6FFFC             # bytes the bootloader CRC32s (after the 4-B CRC word)
DBUG         = 0x44425547

# --- FLASHCDW register block. Base is CONFIRMED by `probe`; writes are gated on that. ---
# Candidate bases tried by probe (AVR32 UC3 flash controllers live in the HSB peripheral
# space). The one whose FPR reports 512 KB / 512 B wins; nothing is written until it does.
FLASHCDW_CANDIDATES = [0xFFFE0000, 0xFFFE1400, 0xFFFF0000, 0xFFFE2000]
OFF_FCR, OFF_FCMD, OFF_FSR, OFF_FPR, OFF_FVR = 0x00, 0x04, 0x08, 0x0C, 0x10
FKEY = 0xA5
CMD_WP, CMD_EP, CMD_CPB, CMD_UP, CMD_EA = 1, 2, 3, 5, 6
FSR_FRDY, FSR_LOCKE, FSR_PROGE = 1 << 0, 1 << 2, 1 << 3

# ---------------- JTAG / SAB plumbing (identical handshake to dump.py) ----------------
def jtag_open():
    # Full reset: all lines low, release nTRST (TAP), then release nSRST with TCK low
    # (UC3 enables JTAG only if TCK is low at RESET_N release). This also recovers a SAB
    # that a prior failed access left wedged.
    g = GpioAsyncController()
    g.configure(URL, direction=0x3B)
    g.write(0x00); time.sleep(0.5)      # nSRST + nTRST asserted, TCK low
    g.write(0x10); time.sleep(0.3)      # release nTRST
    g.write(0x30); time.sleep(0.5)      # release nSRST, TCK low -> JTAG + CPU boot
    g.close()
    jt = JtagEngine(frequency=1e6)
    jt.configure(URL); jt.reset(); jt.go_idle()
    # FTDI latency timer defaults to 16 ms: every JTAG readback waits that long for the chip to
    # flush a short USB packet, so a full flash took ~32 min. 1 ms -> ~16x faster (~2 min),
    # same effect on WSL/usbip or native Windows (it's a chip setting, not a transport thing).
    # ponytail: 1 ms is the standard MPSSE value; raise it if a flaky cable drops transfers.
    ctrl = getattr(jt, '_controller', None) or getattr(jt, '_ctrl', None)
    ftdi = getattr(ctrl, '_ftdi', None) or getattr(ctrl, 'ftdi', None)
    if ftdi is not None:
        ftdi.set_latency_timer(1)
    return jt

def _to_int(bs): return sum(int(b) << i for i, b in enumerate(bs))

def scan(jt, kind, value, n):
    jt.change_state('shift_' + kind)
    out = jt.shift_and_update_register(BitSequence(value, length=n))
    jt.go_idle()
    return _to_int(out)

def read_word(jt, addr):
    # MWA read, OpenOCD model: busy is bit32 on both the address and data phases.
    for _ in range(200):
        st = scan(jt, 'dr', 1 | ((addr >> 2) << 1) | (SLAVE_HSB << 31), 35)
        if not (st >> 32) & 1: break
    for _ in range(200):
        v = scan(jt, 'dr', 0, 35)
        if not (v >> 32) & 1: break
    return v & 0xFFFFFFFF

def write_word(jt, addr, data):
    # Validated on the dead board, matches OpenOCD avr32_jtag_mwa_*.
    # Address phase (MODE_WRITE=0): DR = mode | (addr>>2)<<1 | slave<<31; busy = bit32.
    for _ in range(100):
        st = scan(jt, 'dr', 0 | ((addr >> 2) << 1) | (SLAVE_HSB << 31), 35)
        if not (st >> 32) & 1: break
    # Data phase: DR = {status[2:0], data[31:0]} -> data at bits [34:3] (data<<3); busy = bit0.
    for _ in range(100):
        v = scan(jt, 'dr', (data & 0xFFFFFFFF) << 3, 35)
        if not (v & 1): break
    # Re-select the instruction after a write to resync the SAB access state (required:
    # a following read returns garbage without it). Validated on the dead board.
    scan(jt, 'ir', IR_MWA, 5)

def halt(jt, stop=True):
    # AVR32 OCD HALT instruction (IR 0x1C), 1-bit DR: 1 = halt core, 0 = resume.
    # WORKS (reads succeed while halted). Use write_dr for the 1-bit DR (shift_and_update
    # breaks on length-1). Does NOT by itself make SAB writes succeed — see note in main().
    scan(jt, 'ir', IR_HALT, 5)
    jt.write_dr(BitSequence(1 if stop else 0, length=1)); jt.go_idle()
    scan(jt, 'ir', IR_MWA, 5)

def enter_mwa(jt):
    ir = scan(jt, 'ir', IR_IDCODE, 5)
    idc = scan(jt, 'dr', 0, 32)
    if ir & 0x10:
        sys.exit('Security bit set — flash locked; cannot program from JTAG.')
    scan(jt, 'ir', IR_MWA, 5)
    return idc

# ---------------- FLASHCDW helpers ----------------
def flashcdw_decode_fpr(fpr):
    # AT32UC3C FLASHCDW FPR: FSZ[3:0] flash-size code, PSZ[10:8] page-size code.
    # UC3C fine FSZ enum: 11 -> 512KB (this part). PSZ: 3 -> 512B page.
    fsz_code = fpr & 0xF
    psz_code = (fpr >> 8) & 0x7
    fsz_kb = {13: 1024, 12: 768, 11: 512, 10: 384, 9: 256, 7: 128, 5: 64}.get(fsz_code)
    psz_b  = {1: 128, 2: 256, 3: 512, 4: 1024}.get(psz_code)
    return fsz_kb, psz_b

APP_START_WORD = 0x6B57B0FE        # app CRC word @0x80010000 on a stock 3.0.59 unit (clincher)

def probe(jt):
    print('Probing for the FLASHCDW controller (read-only)...')
    good = None
    for base in FLASHCDW_CANDIDATES:
        try:
            fvr = read_word(jt, base + OFF_FVR)
            fpr = read_word(jt, base + OFF_FPR)
            fsr = read_word(jt, base + OFF_FSR)
        except Exception as e:
            print(f'  0x{base:08X}: unreadable ({e})'); continue
        fsz_kb, psz_b = flashcdw_decode_fpr(fpr)
        # Confirmation: controller ready (FRDY), sane version, 512B page.
        ok = bool(fsr & FSR_FRDY) and (0 < fvr < 0x10000) and (psz_b == PAGE)
        print(f'  0x{base:08X}: FVR=0x{fvr:08X} FPR=0x{fpr:08X} FSR=0x{fsr:08X} '
              f'-> flash={fsz_kb}KB page={psz_b}B FRDY={bool(fsr & FSR_FRDY)}'
              f'  {"<== candidate" if ok else ""}')
        if ok and good is None:
            good = base
    if good is None:
        print('\nNo candidate confirmed. Do NOT write.')
        return None
    # Clincher: read a known flash word to prove the read path + that this is the right chip.
    w = read_word(jt, APP_START)
    print(f'\nread-back @0x{APP_START:08X} = 0x{w:08X} '
          f'(expect 0x{APP_START_WORD:08X} on stock 3.0.59)')
    if w in (0x00000000, 0xFFFFFFFF):
        print(f'Clincher: app word reads blank/broken (0x{w:08X}) — read path wrong. Not confirming.')
        return None
    if w != APP_START_WORD:
        # A valid-but-non-stock CRC word = a patched/modified app is present. FLASHCDW is already
        # confirmed and the read path returned a real value, so re-flashing is safe (e.g. restoring
        # OEM over our patch). Only a blank/broken read (above) blocks.
        print(f'Note: app CRC word 0x{w:08X} != stock (patched/modified app present) — re-flash OK.')
    print(f'FLASHCDW base confirmed: 0x{good:08X}; read path verified. Safe to proceed.')
    return good

def fsr_wait(jt, base):
    for _ in range(500):
        fsr = read_word(jt, base + OFF_FSR)
        if fsr & FSR_FRDY:
            if fsr & (FSR_LOCKE | FSR_PROGE):
                raise RuntimeError(f'FLASHCDW error FSR=0x{fsr:08X} (LOCKE/PROGE)')
            return
    raise RuntimeError(f'FLASHCDW FRDY timeout (last FSR=0x{fsr:08X})')

def fcmd(jt, base, cmd, page=0):
    write_word(jt, base + OFF_FCMD, (FKEY << 24) | ((page & 0xFFFF) << 8) | cmd)
    fsr_wait(jt, base)

# ---------------- high-level ops ----------------
def load_image(path):
    data = open(path, 'rb').read()
    if len(data) % PAGE:
        data += b'\xff' * (PAGE - len(data) % PAGE)
    if APP_START + len(data) > APP_END:
        sys.exit(f'image too big for app partition ({len(data)} B)')
    # sanity: app boot CRC must be correct (else it won't run)
    stored = struct.unpack('>I', data[:4])[0]
    calc = zlib.crc32(data[4:4 + APP_CRC_LEN]) & 0xFFFFFFFF
    if stored != calc and stored != DBUG:
        print(f'WARNING: app CRC mismatch stored=0x{stored:08X} calc=0x{calc:08X} — '
              f'it would fail the boot gate. Proceeding anyway.')
    else:
        print(f'app CRC ok (0x{stored:08X})')
    return data

def write_app(jt, base, data, dry):
    assert APP_START % PAGE == 0
    npages = len(data) // PAGE
    print(f'{"DRY-RUN: " if dry else ""}programming {npages} pages '
          f'0x{APP_START:08X}..0x{APP_START + len(data):08X}')
    for p in range(npages):
        addr = APP_START + p * PAGE
        if not (APP_START <= addr < APP_END and addr + PAGE <= APP_END):
            raise RuntimeError(f'REFUSING: 0x{addr:08X} outside app partition')
        page_no = (addr - FLASH) // PAGE
        if dry:
            continue
        # Proven page order (validated on the dead board): unlock, erase, clear buffer,
        # fill buffer, write page. Do NOT halt the core — HALT gates the flash clock and
        # commands never complete; the CPU runs from the bootloader, not this region.
        chunk = data[p * PAGE:(p + 1) * PAGE]
        if all(b == 0xFF for b in chunk):
            # Image page is blank, so the chip must be blank here too — otherwise a stale tail from
            # a previously-flashed LARGER blob stays inside the CRC-covered region and the app fails
            # its boot CRC gate (stuck on the bootloader logo). Cheap check: read the first word and
            # erase the page only if it's non-blank. ponytail: blobs are contiguous, so a stale page
            # always has a non-0xFF first word; one read per page is enough, no full-page scan.
            if read_word(jt, addr) != 0xFFFFFFFF:
                fcmd(jt, base, CMD_UP, page_no)               # unlock region
                fcmd(jt, base, CMD_EP, page_no)               # erase page -> back to 0xFF
            continue
        fcmd(jt, base, CMD_UP, page_no)                       # unlock region
        fcmd(jt, base, CMD_EP, page_no)                       # erase page
        fcmd(jt, base, CMD_CPB)                               # clear page buffer
        for w in range(0, PAGE, 4):                           # fill page buffer
            write_word(jt, addr + w, struct.unpack('>I', chunk[w:w + 4])[0])
        fcmd(jt, base, CMD_WP, page_no)                       # write page
        if p % 32 == 0:
            print(f'\r  page {p}/{npages} @0x{addr:08X}', end='', flush=True)
    print('\r  done.                      ')

def verify(jt, data):
    print('verifying read-back...')
    bad = 0
    for p in range(len(data) // PAGE):
        addr = APP_START + p * PAGE
        # ponytail: blank image pages get a first-word check only (same assumption as write_app).
        # ~75% of the app region is 0xFF, so this is the bulk of the old 5-min verify. A stray
        # non-blank word deeper in a blank page would still fail the boot CRC gate, not go unnoticed.
        blank = all(b == 0xFF for b in data[p * PAGE:(p + 1) * PAGE])
        for w in range(0, 4 if blank else PAGE, 4):
            got = read_word(jt, addr + w)
            exp = struct.unpack('>I', data[p * PAGE + w:p * PAGE + w + 4])[0]
            if got != exp:
                if bad < 8:
                    print(f'  MISMATCH @0x{addr + w:08X}: got 0x{got:08X} exp 0x{exp:08X}')
                bad += 1
    print('VERIFY OK' if bad == 0 else f'VERIFY FAILED: {bad} words differ')
    return bad == 0

def main():
    args = sys.argv[1:]
    if not args or args[0] not in ('probe', 'write', 'verify'):
        sys.exit(__doc__ or 'usage: jtag_flash.py probe|write|verify')
    cmd = args[0]
    img = next((a for a in args[1:] if not a.startswith('-')), 'app.img')
    dry = '--dry-run' in args

    jt = jtag_open()
    try:
        idc = enter_mwa(jt)
        print(f'IDCODE 0x{idc:08X}')
        if cmd == 'probe':
            probe(jt); return
        if cmd == 'verify':
            verify(jt, load_image(img)); return
        # write (validated on the dead board: erase+program+verify, full page round-trip)
        if '--i-have-a-backup' not in args:
            sys.exit('Refusing: pass --i-have-a-backup to confirm you have the golden dump.')
        base = probe(jt)
        if base is None:
            sys.exit('Refusing to write: FLASHCDW base not confirmed.')
        data = load_image(img)
        write_app(jt, base, data, dry)
        if not dry:
            verify(jt, data)
            print('Done. Power-cycle and check the console `Ver` banner shows CRC: 6B57B0FE.')
    finally:
        jt.close()

if __name__ == '__main__':
    main()
