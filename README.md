# PiBoy DMG on 64-bit Raspberry Pi OS

Porting a [PiBoy DMG](https://experimentalpi.com/) handheld — Raspberry Pi 4B, 3.5" 640×480 DPI
panel, XPi controller board — from Experimental Pi's 32-bit RetroPie/Buster image onto
**64-bit Raspberry Pi OS Trixie**, after Experimental Pi shut down and support ended.

Everything here was worked out against real hardware. The [build document](docs/piboy-build-doc.html)
is the main artefact: it records the traps in the order they bite, including the
ones that cost hours and the theories that turned out to be wrong.

## Why this exists

Experimental Pi is gone. The 32-bit image still works but nothing will ever update it,
and the controller driver is an out-of-tree module written against kernel 5.10 that
does not build on 6.x. Anyone who wants to keep one of these running has to do this
work; this is one worked example.

## What's here

| Path | What it is |
|---|---|
| `driver/` | `xpi_gamecon` ported 5.10 → 6.18, plus Experimental Pi original and a diff |
| `daemons/` | Fan curve, volume wheel, and a Start+Select escape hatch for console emulators |
| `instruments/` | SDR and oscilloscope servers, and the EmulationStation menu that drives them |
| `migration/` | Image the original card, repartition, copy, rewrite PARTUUIDs, restore ROMs |
| `scripts/` | ROM library tools: NeoGeo DAT rebuild, PS1 reorganisation, CHD conversion, scraping |
| `roms/` | Library audit and deduplication |
| `patches/` | Third-party build fixes needed on a modern toolchain |
| `config/` | Known-good `config.txt` / `cmdline.txt`, and a provisioning template |

## The driver

`driver/xpi_gamecon.c` is a derivative of **Nathan Scherdin's GPL-licensed
`xpi_gamecon`** shipped with the PiBoy DMG. It remains GPL-2.0 — see `LICENSE`.
`xpi_gamecon.c.orig` is the unmodified Experimental Pi's source; `xpi_gamecon.diff` is the
delta, so you can see exactly what changed.

The port adds, beyond making it compile:

- **`KEY_POWER`** on the power switch, so shutdown is clean. Nothing answered the
  switch before; the XPi asserts a bit, waits ~31 s, and cuts the rail.
- **`power_supply`** for the battery, plus a second supply for wall power, so the
  OS can tell mains from battery.
- **`hwmon`** `pwm1` for the fan, with a kernel-side safety floor if userspace dies.
- **`leds`** classdev for the green status LED, so the kernel animates it.
- **`input`** `ABS_VOLUME` for the volume wheel.

Everything else in this repo is MIT-licensed; see `LICENSE-MIT`.

## Hardware notes worth knowing before you start

- **`config.txt` silently truncates lines at 98 characters.** A long `dtoverlay=`
  line loses its tail with no error — the panel then runs at the wrong resolution
  or not at all. Split into `dtparam=` lines.
- **The board runs permanently under-voltage** and Experimental Pi hid it with
  `avoid_warnings=2`. Without that line the CPU is pinned at 600 MHz. With it you
  get full speed and the dips are simply not reported.
- **Soft reboot does not come back.** The XPi cuts power on halt and does not
  re-assert it; the physical switch has to be flipped.
- **The red half of the status LED is firmware-owned** — it is the battery gauge,
  not something software can drive. Green is yours.

## Running the scripts

They take configuration from the environment rather than hardcoded values:

```sh
export PI_USER=pi
export PI_HOST=piboy.local
export SSH_KEY=~/.ssh/id_ed25519
export EXPECT_SERIAL=0x...        # your SD card's serial - a destructive-op guard
```

Read a script before running it. Several repartition disks or delete files, and
they identify the target card by name and serial precisely so they cannot run
against the wrong one. `EXPECT_SERIAL` is not optional decoration.

## Status

Working: DPI panel under full KMS, PWM audio, controller driver with clean
shutdown, fan control, battery and mains reporting, 2000 MHz overclock, RetroPie
with 19 cores, 17 ports.

Not solved: positive charge current has never been observed (the pack has been
full every time it was measured); two unexplained early shutdowns with a strong
but unproven candidate. Both are documented in the build document rather than
quietly omitted.
