# AEX Pong 🏓

Pong, hand-written in AVR32 assembly, running on the bare-metal CPU of a
**decommissioned Medtronic AEX electrosurgical generator** — rendered on the
unit's own touchscreen, controlled by its **PlasmaBlade surgical handpiece**,
with the **return-electrode (NEM) status LED** repurposed as a game indicator:
green while you play, red when the AI scores on you.

![demo](media/demo.gif) <!-- drop a phone screen-recording here (see media/) -->

> ⚠️ **Independent hobby / educational project. Not affiliated with, authorized
> by, or endorsed by Medtronic.** Everything here was done on a dead, out-of-service
> unit the author owns, on the bench, never connected to a patient. **No proprietary
> firmware, decompiled code, dumps, or manuals are included in this repo** — only
> original game code plus hardware-level addresses. Never run modified firmware on
> any device in clinical use.

## The gist

The generator runs an Atmel **AT32UC3C** (32-bit **big-endian** AVR32). Its
application firmware is gated at boot by a plain **CRC-32 — no secure boot, no
signature**. So you can:

1. Append a small code blob to unused application flash.
2. Repoint one function pointer the app calls at the end of init to your blob.
3. Recompute the boot CRC.

…and the device boots 100% normally, then hands control to your code. Ours is
~1.9 KB and it's a full game of Pong. Completely reversible — reflash the stock
image and it's a generator again.

## What it does

- **Display** — drives the panel's Reach **SLCD5** serial LCD directly over USART1
  (115200 8N1) with its ASCII command set (`z` clear, `r` rect, `t` text). Clears
  the panel's power-on splash with `xd 0 255`, and renders flicker-free with
  *differential drawing* (only redraw what actually moved).
- **Input** — the PlasmaBlade handpiece's CUT / COAG buttons are read from an
  **external SPI ADC**. The stock firmware only samples that bus from a timer ISR
  (which our takeover removes), so the buffer was frozen; we **re-trigger the SPI
  bus every frame**, classify the handpiece voltage into CUT / COAG bands, and
  debounce it. Hold CUT → paddle down, COAG → paddle up. The right paddle is AI.
- **LED** — the NEM port's bicolor status LED (two active-low GPIOs, **PC31 / PD10**)
  is driven green during play and flashed red on a lost point.

## Hardware map (AT32UC3C)

| What | Address / pin |
|---|---|
| App base / reset entry | `0x80010000` / `0x80010004` |
| Boot CRC word | `@0x80010000` = `crc32(app[4 : 4+0x6FFFC])`, big-endian |
| Injection hook (function pointer) | word `@0x80014AE4` → our entry |
| Blob load address (free app flash) | `0x8002C000` |
| Panel (SLCD5) USART1 | base `0xFFFF2C00` (THR `+0x1C`, CSR `+0x14`) |
| Handpiece SPI-ADC result buffer | RAM `0x29C4` (16 × 12-bit); re-sample routine `0x800146B8` |
| NEM LED green / red | GPIO PC31 (`0xFFFF2400` bit 31) + PD10 (`0xFFFF2600` bit 10), active-low |

CUT / COAG bands and a couple of call addresses are per-firmware-version; the ones
above are for the unit this was developed on.

## Build & run

You need the (end-of-life) Atmel **AVR32 GNU toolchain** — `avr32-as`, `avr32-ld`,
`avr32-objcopy`. No C compiler required; the game is hand-written assembly.

```sh
# 1) assemble the blob
AVR32_BIN=/path/to/avr32-gnu-toolchain/bin  ./game/build.sh game/pong.s

# 2) splice the blob into YOUR OWN device's firmware image and fix the boot CRC.
#    You supply app.img (a dump of your own unit). It is NOT included here.
python3 tools/inject_patch.py --blob game/blob.bin --in app.img --out patched.img

# 3) flash over JTAG (any SWD/JTAG adapter, e.g. a Tigard), then power-cycle.
python3 tools/jtag_flash.py write --i-have-a-backup patched.img
```

`tools/jtag_peek.py` and `tools/jtag_dump.py` read registers / RAM over JTAG —
the workhorses for the reverse-engineering.

## Files

- `game/pong.s` — the game: physics, AI, SLCD5 rendering, handpiece input, NEM LED.
- `game/nemsweep.s` — a safe GPIO sweep used to find the LED pins on the bench.
- `game/inject.ld` — links the blob at its load address.
- `tools/inject_patch.py` — drop blob into free flash + recompute the boot CRC.
- `tools/jtag_*.py` — flash / read the chip over JTAG (FTDI-based adapter).

## License

[MIT](LICENSE). Applies to the original code in this repository only.
