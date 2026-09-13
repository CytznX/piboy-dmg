#!/bin/bash
# Daily scrape attempt. ScreenScraper's anonymous quota allows only a slice of
# the library per day, and Skyscraper caches everything it fetches, so repeated
# runs resume rather than restart. Stops scheduling itself once nothing is left.
set -uo pipefail
PLATFORMS=(nes megadrive dreamcast)

remaining() {
    local s=$1 dir="$HOME/RetroPie/roms/$s" tot got skip n
    [ -d "$dir" ] || { echo 0; return; }
    # Recurse: nes and megadrive keep most of their library in an "Alternate Roms"
    # subfolder. But skip media/ (scraped artwork, thousands of files) and discs/,
    # where a multi-disc set keeps its images - the set is counted once via the
    # top-level .m3u that represents it.
    tot=$(find "$dir" -type f \
          -not -path "$dir/media/*" -not -path "$dir/discs/*" \
          \( -iname '*.nes' -o -iname '*.zip' -o -iname '*.md' -o -iname '*.bin' \
             -o -iname '*.gen' -o -iname '*.smd' -o -iname '*.chd' \
             -o -iname '*.m3u' \) 2>/dev/null | wc -l)
    got=$(grep -c '<game' "$dir/gamelist.xml" 2>/dev/null || echo 0)
    # ScreenScraper has no data at all for some titles. Skyscraper records them and
    # skips them on every subsequent run, so counting them as outstanding means the
    # total never reaches zero and the timer below can never retire itself.
    skip=0
    [ -f "$HOME/.skyscraper/skipped-$s-cache.txt" ] &&
        skip=$(wc -l < "$HOME/.skyscraper/skipped-$s-cache.txt")
    n=$(( tot - got - skip ))
    [ "$n" -lt 0 ] && n=0
    echo "$n"
}

# Never compete with a game for the CPU - try again tomorrow instead.
if pgrep -f 'retroarch|redream|/opt/retropie/emulators' >/dev/null; then
    echo "an emulator is running; skipping this run"
    exit 0
fi

left=0
todo=()
for s in "${PLATFORMS[@]}"; do
    n=$(remaining "$s"); left=$((left + n))
    echo "before: $s has $n unscraped"
    [ "$n" -gt 0 ] && todo+=("$s")
done
if [ "$left" -le 0 ]; then
    echo "nothing left to scrape - disabling the timer"
    systemctl --user disable --now piboy-scrape.timer 2>/dev/null || \
        sudo systemctl disable --now piboy-scrape.timer
    exit 0
fi

"$HOME/scrape.sh" "${todo[@]}"
rc=$?

after=0
for s in "${PLATFORMS[@]}"; do
    n=$(remaining "$s"); after=$((after + n))
    echo "after:  $s has $n unscraped"
done
echo "this run scraped $((left - after)) game(s); $after remaining; scrape.sh exit $rc"
[ "$after" -le 0 ] && { echo "complete - disabling the timer"; sudo systemctl disable --now piboy-scrape.timer; }
exit 0
