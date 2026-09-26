# PiBoy DMG — 64-bit port

Porting a PiBoy DMG (Raspberry Pi 4B 8GB handheld) off Experimental Pi's 32-bit
RetroPie/Buster image onto 64-bit Raspberry Pi OS Trixie, after Experimental Pi
shut down. Built 2026-08-22 → 2026-08-23.

Full write-up, including the traps that cost real time:
`docs/piboy-build-doc.html`

## Current state

The 1 TB card is the live system; the 32 GB card is a working rollback.
Both share a machine-id — never boot them onto the network at the same time.

    /            938 G on PARTUUID=e22bcd10-02   (ext4 reserve lowered to 1%)
    CPU          2000 MHz, throttled=0x0
    roms         26 G restored, checksums verified
    driver       xpi_gamecon, ported 5.10 -> 6.18, kept rebuilt by DKMS
    session      Wayland: labwc + waybar + EmulationStation.
                 `sudo switch.sh kms` rolls back to plain KMS on the next boot

## Layout

    driver/      xpi_gamecon.c    the port (KEY_POWER, power_supply, hwmon, leds,
                                  ABS_VOLUME, settable bitrate)
                 .orig / .diff    an older vendor GPL revision, and the patch
                                  against it. The 1.0.6 installer carries a newer
                                  one - see docs/experimentalpi-mirror/downloads/
                 xpi_gamecon.c.*  intermediate revisions, oldest to newest
                 dkms-setup.sh    put the driver under DKMS, then reload from the
                                  installed path and prove the device comes back.
                                  Run once per card, and again to publish a
                                  source change. Kernel upgrades rebuild it.
                 test-reload.sh   build and cycle rmmod/insmod N times, checking
                                  for oops and for a teardown that hangs
    daemons/     piboy-fand       fan curve, LED trigger, low-battery OSD
                 piboy-batd       fuel gauge: integrates current, anchors on an
                                  IR-compensated OCV curve, publishes through the
                                  driver's capacity_override so ES/RetroArch/
                                  upower all see it. Also owns the clean shutdown
                                  on an empty pack. Runs uncalibrated on generic
                                  constants; to calibrate this pack, capture with
                                  --log (see daemons/piboy-batd.default) and fit
                                  with scripts/fit-battery-curve.py, which writes
                                  /var/lib/piboy/battery-cal.json
                 piboy-vold.c     volume wheel -> ALSA, blocks on evdev
                 piboy-escaped    Start+Select escape hatch; idle screen blanking
                 piboy-display    follows the HDMI cable: panel, audio, ES restart
                 *.service        systemd units as installed
    migration/   capture.sh       image the original card (partclone + zstd)
                 01..03           partition, rsync, rewrite PARTUUIDs
                 02b              verify the copy with rsync -n
                 04-restore-roms  runs ON the Pi, from USB, never over network
                 piboy-cleanup.sh removes build artifacts (dry run by default)
                 MANIFEST.txt     sha256 of the captured image
    config/      working-*.txt    known-good config.txt / cmdline.txt
                 custom.toml      Bookworm-era provisioning; Trixie ignores it
                                  and uses cloud-init instead — kept as a warning
                 wayland/         THE CURRENT BOOT PATH: labwc + waybar +
                                  EmulationStation, mirroring /opt/retropie/
                                  configs/all/wayland/. Status bar over every
                                  emulator, and the terminal wrapper the RetroPie
                                  config menu needs under a compositor.
                                  switch.sh flips boot between this and plain
                                  KMS. See its README.md
                                  Volume OSD: piboy-vold publishes the wheel to
                                  /run/piboy-volume (created by tmpfiles, since
                                  /run is root-owned), piboy-volume-osd.sh
                                  watches it and notifies mako, which draws the
                                  icon + percentage + level bar (mako.ini).
                                  Icons come from mkvolumeicons.sh - Adwaita's
                                  are black-on-black here.
    patches/     *-enable-wayland RetroArch and SDL2 rebuilt with the Wayland
                                  backend — the work that made the above possible
                 runcommand-*     gives runcommand a pty under the compositor,
                                  without which nothing launches at all
                 es_systems-*     points the RetroPie menu at the wrapper
                 retroarch-*      showmsg-flush (kept, drives low-battery alerts)
                                  and status-bar (RETIRED, waybar replaced it)
                                  Reapply by hand after a RetroPie-Setup update.

## Not here

The 24 GB captured Experimental Pi's image is in `~/.local/share/piboy-backup-image/`,
deliberately outside Dropbox so it does not sync. See
`migration/WHERE-IS-THE-IMAGE.txt`. It is currently the only copy of *this card*,
on one laptop disk — that is not a backup. Copy it to external media.

Alongside it, `exppi-archive/` holds the four stock OS images from Experimental
Pi's download server, recovered 2026-09-25 from
<https://archive.org/details/EXPPI>. The rest of that archive — Windows utility,
MCU firmware 1.0.6/1.0.7, STLs — is small enough to sync and is in the repo at
`docs/experimentalpi-mirror/downloads/`.

Credentials (Pi password, Wi-Fi PSK) were deliberately NOT saved here.

## Sources of record on the Pi itself

`~/piboy-src/` on the handheld carries the same driver and daemon sources, so
the device can rebuild its own module after a kernel update without this laptop.
