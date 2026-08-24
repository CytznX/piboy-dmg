#!/bin/bash
# Scrape artwork and metadata with Skyscraper.
#
#   scrape.sh [--flags F] platform:count ...
#   scrape.sh                     # all platforms, ascending by rom count
#
# Smallest first, so whole systems finish early rather than stalling for hours
# on the 2204-rom NES set. Skyscraper caches everything it fetches, so stopping
# and re-running resumes rather than starting over.
#
# Do NOT add 'nosubdirs' by default: megadrive and nes keep most of their games
# in Alternate_roms/ subfolders, and that flag made Skyscraper see 98 games
# where there are 1400+.
FLAGS="unattend"
[ "${1:-}" = "--flags" ] && { FLAGS="$2"; shift 2; }

PLATFORMS=("$@")
if [ "${#PLATFORMS[@]}" -eq 0 ]; then
    PLATFORMS=(psx:101 gb:83 nds:103 snes:104 gba:158 n64:419 gbc:480
               atari2600:735 megadrive:1413 nes:2205)
fi

mkdir -p ~/scrape-logs
for entry in "${PLATFORMS[@]}"; do
    p=${entry%%:*}; n=${entry##*:}
    [ -d "$HOME/RetroPie/roms/$p" ] || continue
    echo "=== $p ($n roms)  start $(date +%H:%M:%S)"
    Skyscraper -p "$p" -s screenscraper --flags "$FLAGS" > ~/scrape-logs/"$p".gather.log 2>&1
    Skyscraper -p "$p"                  --flags "$FLAGS" > ~/scrape-logs/"$p".build.log  2>&1
    got=$(grep -oE "Successfully processed games: [0-9]+" ~/scrape-logs/"$p".build.log | tail -1)
    echo "    $p done $(date +%H:%M:%S)  ${got:-see log}"
done
echo "=== SCRAPE COMPLETE $(date +%H:%M:%S) ==="
