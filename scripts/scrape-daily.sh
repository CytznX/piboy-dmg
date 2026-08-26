#!/bin/bash
# Daily scrape attempt. ScreenScraper's anonymous quota allows only a slice of
# the library per day, and Skyscraper caches everything it fetches, so repeated
# runs resume rather than restart. Stops scheduling itself once nothing is left.
set -uo pipefail
PLATFORMS=(nes megadrive)

remaining() {
    local s=$1 tot got
    tot=$(find "$HOME/RetroPie/roms/$s" -type f \
          \( -name '*.nes' -o -name '*.zip' -o -name '*.md' -o -name '*.bin' \
             -o -name '*.gen' -o -name '*.smd' \) 2>/dev/null | wc -l)
    got=$(grep -c '<game' "$HOME/RetroPie/roms/$s/gamelist.xml" 2>/dev/null || echo 0)
    echo $(( tot - got ))
}

# Never compete with a game for the CPU - try again tomorrow instead.
if pgrep -f 'retroarch|redream|/opt/retropie/emulators' >/dev/null; then
    echo "an emulator is running; skipping this run"
    exit 0
fi

left=0
for s in "${PLATFORMS[@]}"; do
    n=$(remaining "$s"); left=$((left + n))
    echo "before: $s has $n unscraped"
done
if [ "$left" -le 0 ]; then
    echo "nothing left to scrape - disabling the timer"
    systemctl --user disable --now piboy-scrape.timer 2>/dev/null || \
        sudo systemctl disable --now piboy-scrape.timer
    exit 0
fi

"$HOME/scrape.sh" "${PLATFORMS[@]}"
rc=$?

after=0
for s in "${PLATFORMS[@]}"; do
    n=$(remaining "$s"); after=$((after + n))
    echo "after:  $s has $n unscraped"
done
echo "this run scraped $((left - after)) game(s); $after remaining; scrape.sh exit $rc"
[ "$after" -le 0 ] && { echo "complete - disabling the timer"; sudo systemctl disable --now piboy-scrape.timer; }
exit 0
