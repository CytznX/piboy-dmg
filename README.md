# PiBoy DMG — 64-bit port

Porting a PiBoy DMG (Raspberry Pi 4B 8GB handheld) off Experimental Pi's 32-bit
RetroPie/Buster image onto 64-bit Raspberry Pi OS Trixie, after Experimental Pi
shut down. Built 2026-08-22 → 2026-08-23.

Full write-up, including the traps that cost real time:
`docs/piboy-build-doc.html` — also published at
https://claude.ai/code/artifact/b0a8889b-bb44-452e-9d5e-c876599c4584

## Current state

The 1 TB card is the live system; the 32 GB card is a working rollback.
Both share a machine-id — never boot them onto the network at the same time.

    /            938 G on PARTUUID=e22bcd10-02   (ext4 reserve lowered to 1%)
    CPU          2000 MHz, throttled=0x0
    roms         26 G restored, checksums verified
    driver       xpi_gamecon, ported 5.10 -> 6.18

## Layout

    driver/      xpi_gamecon.c    the port (KEY_POWER, power_supply, hwmon, leds,
                                  ABS_VOLUME, settable bitrate)
                 .orig / .diff    vendor's GPL original, and the patch against it
                 xpi_gamecon.c.*  intermediate revisions, oldest to newest
    daemons/     piboy-fand       fan curve, LED trigger, low-battery OSD
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

## Not here

The 24 GB captured Experimental Pi's image is in `~/.local/share/piboy-backup-image/`,
deliberately outside Dropbox so it does not sync. See
`migration/WHERE-IS-THE-IMAGE.txt`. It is currently the only copy, on one
laptop disk — that is not a backup. Copy it to external media.

Credentials (Pi password, Wi-Fi PSK) were deliberately NOT saved here.

## Sources of record on the Pi itself

`~/piboy-src/` on the handheld carries the same driver and daemon sources, so
the device can rebuild its own module after a kernel update without this laptop.
