# PiBoy DMG — 64-bit port

Experimental Pi shut down and left their PiBoy DMG handheld on a 32-bit
RetroPie/Buster image with no support behind it. This repo is the result of
moving one onto 64-bit Raspberry Pi OS Trixie and taking over the whole stack:
their GPL controller driver, the daemons around it, the emulation front end,
and the tooling to rebuild a card from scratch.

Hardware: Raspberry Pi 4B rev 1.4 (8 GB), XPi controller board, 3.5" 640×480
DPI panel. Ported from their 5.10 kernel to 6.18.

Full write-up, including the traps that cost real time: `docs/piboy-build-doc.html`

## What works

    frontend     EmulationStation under a Wayland compositor (labwc), with one
                 status bar drawn over EVERY emulator - clock, CPU, memory,
                 disk, temperature, battery, wired/wifi link. Themed to match
                 the gbz35 ES theme it sits on top of.
    emulators    Every SDL2-based emulator runs as a native Wayland client:
                 RetroArch and its cores, PPSSPP, Aleph One, OpenTyrian,
                 the ports. Dreamcast via lr-flycast-dev.
    controls     Full pad, analog volume wheel -> ALSA on Experimental Pi's own
                 curve, volume OSD with icon + percentage + level bar, power
                 button, Start+Select escape hatch out of any wedged emulator.
    battery      Coulomb-counting fuel gauge, not the MCU's voltage guess.
                 Powers the device off cleanly before the pack dies.
    thermals     Fan curve on the MCU's real units, LED trigger, throttled=0x0
                 at a 2000 MHz overclock.
    display      Experimental Pi's own 60 Hz DPI timing; follows the HDMI cable
                 for panel, audio sink and an in-place ES restart.
    driver       xpi_gamecon under DKMS, so a kernel upgrade rebuilds it rather
                 than orphaning it. Proven across 6.18.39 -> 6.18.50.

## Known limitations

These are decided, not open bugs:

  * **The status bar cannot be hidden during a game.** Changing a layer
    surface's state next to a fullscreen client intermittently wedges that
    client for good — it blocks waiting for a frame callback that never
    arrives, while the compositor itself stays healthy and keeps rendering.
    Unrecoverable short of SIGKILL. It reproduces during ordinary play and
    never once in ~30 scripted attempts, so `scripts/freeze-watch.sh` exists to
    capture it rather than guess. The auto-hide hooks in `config/wayland/
    runcommand/` are shipped but deliberately NOT installed. Costs ~7.7% of a
    core that hiding the bar would have saved.
  * **`layer: overlay` defeats direct scanout**, so the compositor composites
    every frame: ~11% of a core with the bar up against ~3% without. Required —
    wlroots raises a fullscreen window above the `top` layer, so a bar on `top`
    is configured correctly, logs the right geometry, and is invisible.
  * **redream cannot run under Wayland.** It statically links its own SDL built
    with KMSDRM as the only video driver. XWayland does not help: there is no
    X11 backend to trigger it. Batocera hit the same wall and dropped it.
    lr-flycast-dev is the default instead — slower, but it works.
  * **Faint horizontal banding** under the compositor. Ruled out direct scanout,
    damage tracking, bandwidth and plane/format. Subtle; accepted.
  * **The fuel gauge is uncalibrated**, running on generic 1S Li-ion constants
    and a capacity borrowed from another pack. It says so on every boot. See
    `daemons/piboy-batd.default` for the one-discharge procedure.

## Layout

    driver/      xpi_gamecon.c    the port: KEY_POWER, power_supply, hwmon fan,
                                  leds, backlight, ABS_VOLUME, settable bitrate,
                                  capacity_override
                 .orig / .diff    an older vendor GPL revision and the patch
                                  against it
                 dkms-setup.sh    put the driver under DKMS, reload from the
                                  installed path, prove the device comes back
                 test-reload.sh   cycle rmmod/insmod N times, watching for an
                                  oops or a teardown that hangs
    daemons/     piboy-fand       fan curve, LED trigger, low-battery alerts
                 piboy-batd       the fuel gauge, and the clean shutdown on an
                                  empty pack (it lives here, not in fand, which
                                  exits when the FAN is unwritable)
                 piboy-vold.c     volume wheel -> ALSA, blocks on evdev
                 piboy-escaped    Start+Select escape hatch; idle blanking
                 piboy-display    follows the HDMI cable
                 *.service        systemd units as installed
    config/      wayland/         THE BOOT PATH: labwc + waybar + ES, mirroring
                                  /opt/retropie/configs/all/wayland/. switch.sh
                                  flips to plain KMS. See its own README.md
                 working-*.txt    known-good config.txt / cmdline.txt
                 retroarch-joypads, udev
                 custom.toml.example
                                  the real custom.toml carries a PSK and a
                                  password hash and is gitignored
    patches/     *-enable-wayland RetroArch and SDL2 rebuilt with the Wayland
                                  backend — SDL2 was the chokepoint, and doing
                                  it there gave every SDL2 emulator Wayland free
                 runcommand-*     gives runcommand a pty under the compositor,
                                  without which nothing launches at all
                 es_systems-*     points the RetroPie config menu at the wrapper
                                  it needs to draw under a compositor
                 retroarch-*      showmsg-flush (kept — drives transient alerts)
                                  and status-bar (RETIRED, waybar replaced it)
                 others           joy2key, flycast, dxx-rebirth build fixes
                                  ALL of these are reapplied BY HAND after a
                                  RetroPie-Setup update. Nothing upstream
                                  supports Wayland; these are ours to carry.
    scripts/     fit-battery-curve.py
                                  recovers capacity, pack resistance and the OCV
                                  curve from one logged discharge
                 freeze-watch.sh  captures the in-game stall described above
                 scrape*, chd-convert, migrate-discs, neogeo-*, move-psx
    roms/        rom-audit / rom-dedupe / rom-tidy
    migration/   capture.sh       image the original card (partclone + zstd)
                 01..03           partition, rsync, rewrite PARTUUIDs
                 02b              verify the copy with rsync -n
                 04-restore-roms  runs ON the Pi, from USB, never over network
                 piboy-cleanup.sh removes build artifacts (dry run by default)
    instruments/ SDR (rtl_433) and SmartScope servers, launchable from ES
    systemd/     the scrape timer
