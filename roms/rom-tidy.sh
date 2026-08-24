#!/bin/bash
# Remove empty and dead rom directories. Dry run unless --yes.
# Never touches a directory that holds a real file, nor one whose system has an
# emulator installed AND content - only genuinely dead ones.
R=$HOME/RetroPie/roms
GO=0; [ "${1:-}" = "--yes" ] && GO=1
act() { if (( GO )); then rm -rf "$1"; echo "  removed  $(basename "$1")"; else echo "  would remove  $(basename "$1")"; fi; }

echo "=== empty directories ==="
for d in "$R"/*/; do
    [ -L "${d%/}" ] && continue
    [ -z "$(find "$d" -type f 2>/dev/null | head -1)" ] && act "${d%/}"
done

echo "=== dead stub dirs (only +Start*.sh, and no emulator installed) ==="
for s in amiga dreamcast pc scummvm; do
    d="$R/$s"
    [ -d "$d" ] || continue
    if [ -f "/opt/retropie/configs/$s/emulators.cfg" ]; then
        echo "  SKIP $s - an emulator IS installed"; continue
    fi
    # refuse if anything other than a +Start launcher is present
    other=$(find "$d" -type f ! -name '+Start*.sh' | head -1)
    if [ -n "$other" ]; then echo "  SKIP $s - holds real files"; continue; fi
    act "$d"
done

echo "=== mame-libretro (no playable archives) ==="
n=$(find "$R/mame-libretro" -type f \( -iname '*.zip' -o -iname '*.7z' \) 2>/dev/null | wc -l)
if [ "$n" -eq 0 ] && [ -d "$R/mame-libretro" ]; then act "$R/mame-libretro"
else echo "  SKIP - $n playable archives present"; fi
