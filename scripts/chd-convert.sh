#!/bin/bash
# Convert every Dreamcast GDI to CHD, verify, then remove the source.
#
# Order matters: convert -> verify -> only then delete. A CHD that fails
# verification leaves the original untouched, so a bad conversion can never
# cost a game. Multi-disc titles get an .m3u so ES lists one entry.
D=$HOME/RetroPie/roms/dreamcast
LOG=$HOME/chd-convert.log
ok=0; failed=0; freed=0

shopt -s nullglob
for gamedir in "$D"/*/; do
    [ -d "$gamedir" ] || continue
    title=$(basename "$gamedir")
    mapfile -t gdis < <(find "$gamedir" -name '*.gdi' | sort)
    [ "${#gdis[@]}" -gt 0 ] || { echo "  SKIP $title (no .gdi)"; continue; }

    before=$(du -sb "$gamedir" | cut -f1)
    outs=()
    bad=0
    for g in "${gdis[@]}"; do
        # Name each output after its own .gdi so multi-disc sets stay distinct.
        base=$(basename "$g" .gdi)
        out="$D/$base.chd"
        if ! chdman createcd -i "$g" -o "$out" -f >/dev/null 2>&1; then
            echo "  FAIL convert: $base"; rm -f "$out"; bad=1; break
        fi
        if ! chdman verify -i "$out" >/dev/null 2>&1; then
            echo "  FAIL verify:  $base"; rm -f "$out"; bad=1; break
        fi
        outs+=("$out")
    done

    if [ "$bad" = 1 ]; then
        for o in "${outs[@]}"; do rm -f "$o"; done
        failed=$((failed+1))
        echo "  KEPT SOURCE: $title"
        continue
    fi

    # Multi-disc -> one .m3u so EmulationStation shows a single entry.
    if [ "${#outs[@]}" -gt 1 ]; then
        m3u="$D/$title.m3u"; : > "$m3u"
        for o in "${outs[@]}"; do echo "$(basename "$o")" >> "$m3u"; done
        echo "  m3u: $title (${#outs[@]} discs)"
    fi

    after=0
    for o in "${outs[@]}"; do after=$((after + $(stat -c%s "$o"))); done
    rm -rf "$gamedir"
    freed=$((freed + before - after))
    ok=$((ok+1))
    echo "  [$ok] $title  $(numfmt --to=iec $before) -> $(numfmt --to=iec $after)  (freed $(numfmt --to=iec $((freed))) total)"
done

echo "=== DONE $(date +%H:%M:%S) ==="
echo "  converted: $ok    failed (source kept): $failed"
echo "  space freed: $(numfmt --to=iec $freed)"
df -h / | tail -1
