#!/bin/bash
# Scrape artwork and metadata with Skyscraper, anonymously.
#
# Smallest platforms first: without a ScreenScraper account the request rate is
# throttled hard, so this finishes whole systems early rather than stalling for
# hours on the 2204-rom NES set. Skyscraper caches everything it fetches, so
# stopping and re-running resumes rather than starting over.
mkdir -p ~/scrape-logs
while pgrep -f "build-cores.sh|build-extras.sh" >/dev/null; do sleep 30; done
command -v Skyscraper >/dev/null || { echo "Skyscraper never installed - aborting"; exit 1; }
echo "=== starting $(date +%H:%M:%S) ==="
Skyscraper --version 2>&1 | head -1

# platform:romcount, ascending.
# NOT nosubdirs: these libraries keep most of their content in subdirectories
# (megadrive/Alternate_roms, nes/"Alternate Roms" and nes/fbneo), so that flag
# scrapes 98 of 1410 and 98 of 2191 while reporting success.
# Platforms may be given as arguments to scrape a subset; the default is the
# full list, smallest first. Do not fork a second copy of this script for a
# subset - the guards above only exist in this one.
list=("$@")
if [ ${#list[@]} -eq 0 ]; then
    list=(psx gb nds snes gba n64 gbc atari2600 megadrive nes)
fi
# Platform names now come from argv, so a typo must not look like success:
# the old `|| continue` was written for a hardcoded list that could not be wrong.
for p in "${list[@]}"; do
    p=${p%/}                       # tab-completion appends a slash; it breaks the log path
    if [ ! -d ~/RetroPie/roms/"$p" ]; then
        echo "no such platform: $p" >&2; exit 2
    fi
    echo "=== $p  start $(date +%H:%M:%S)"
    # Pass 1 gathers into the cache; pass 2 writes gamelist.xml and media.
    Skyscraper -p "$p" -s screenscraper --flags unattend \
        > ~/scrape-logs/"$p".gather.log 2>&1
    Skyscraper -p "$p" --flags unattend \
        > ~/scrape-logs/"$p".build.log 2>&1
    got=$(grep -oE "Successfully processed games: [0-9]+" ~/scrape-logs/"$p".build.log | tail -1)
    echo "    $p done $(date +%H:%M:%S)  ${got:-see log}"
done
echo "=== SCRAPE COMPLETE $(date +%H:%M:%S) ==="
du -sh ~/.skyscraper 2>/dev/null
