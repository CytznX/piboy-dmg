#!/bin/bash
# Convert every Dreamcast GDI to CHD, verify, then remove only what was consumed.
#
# Order matters: convert -> verify -> only then delete. A CHD that fails
# verification leaves the original untouched, so a bad conversion can never
# cost a game. Multi-disc titles get an .m3u so ES lists one entry.
#
# Pass --dry-run to see what would happen without converting or deleting.
set -euo pipefail
shopt -s nullglob

D=$HOME/RetroPie/roms/dreamcast
DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; fi

ok=0; failed=0; skipped=0; freed=0

if ! command -v chdman >/dev/null; then echo "chdman not found" >&2; exit 1; fi
if [ ! -d "$D" ]; then echo "no dreamcast directory: $D" >&2; exit 1; fi

# The track files a .gdi names, resolved against its own directory. Lines after
# the count are "idx lba type sectorsize FILE offset"; FILE may be quoted, and
# unquoted names can contain spaces, so take everything between field 4 and the
# last field rather than a single whitespace-delimited token.
gdi_tracks() {
    local gdi=$1 dir
    dir=$(dirname "$gdi")
    awk 'NR>1 && NF>=6 {
            name=""
            for (i=5; i<NF; i++) name = name (i>5 ? " " : "") $i
            gsub(/^"|"$/, "", name)
            if (name != "") print name
         }' "$gdi" | while IFS= read -r n; do printf '%s\n' "$dir/$n"; done
}

for gamedir in "$D"/*/; do
    title=$(basename "$gamedir")
    # Recursive on purpose: some titles nest one subdirectory per disc
    # (Sakura Taisen 3 ships five that way), and -maxdepth 1 would silently
    # convert none of them while still counting the title as handled.
    mapfile -t gdis < <(find "$gamedir" -name '*.gdi' | sort)
    if [ "${#gdis[@]}" -eq 0 ]; then
        echo "  SKIP $title (no .gdi)"; skipped=$((skipped+1)); continue
    fi

    # Collision check BEFORE converting anything. Every output lands in the
    # shared $D root, so two titles whose .gdi happen to share a basename would
    # overwrite each other - and with the original -f flag that was silent, with
    # the first title's source directory already deleted by then. Refuse instead.
    collision=""
    for g in "${gdis[@]}"; do
        out="$D/$(basename "$g" .gdi).chd"
        if [ -e "$out" ]; then collision=$(basename "$out"); break; fi
    done
    if [ -n "$collision" ]; then
        echo "  SKIP $title: output already exists, refusing to overwrite: $collision"
        skipped=$((skipped+1)); continue
    fi

    # Per-disc, not all-or-nothing. One unconvertible disc used to abandon the
    # whole title: Sakura Taisen 3 ships a bonus disc whose download is missing
    # two track files, and that left its four intact discs as raw GDI forever,
    # with every re-run failing the same way. Each disc now stands alone - the
    # good ones convert and their sources go, the bad one is kept for repair.
    outs=(); consumed=(); failed_discs=()
    for g in "${gdis[@]}"; do
        base=$(basename "$g" .gdi)
        out="$D/$base.chd"
        if [ "$DRY" = 1 ]; then
            echo "  would convert: $base"
            outs+=("$out")
            consumed+=("$g")
            while IFS= read -r t; do
                if [ -e "$t" ]; then consumed+=("$t"); fi
            done < <(gdi_tracks "$g")
            continue
        fi
        # No -f. The collision check above is the only sanctioned overwrite path.
        if ! chdman createcd -i "$g" -o "$out" >/dev/null 2>&1; then
            echo "  FAIL convert: $base"; rm -f "$out"; failed_discs+=("$base"); continue
        fi
        if ! chdman verify -i "$out" >/dev/null 2>&1; then
            echo "  FAIL verify:  $base"; rm -f "$out"; failed_discs+=("$base"); continue
        fi
        outs+=("$out")
        consumed+=("$g")
        while IFS= read -r t; do
            if [ -e "$t" ]; then consumed+=("$t"); fi
        done < <(gdi_tracks "$g")
    done

    if [ "${#outs[@]}" -eq 0 ]; then
        failed=$((failed+1)); echo "  KEPT SOURCE: $title (no disc converted)"; continue
    fi

    # One .gdi can name a track another already claimed; counting it twice would
    # inflate the freed total and stat a file that rm already removed.
    mapfile -t consumed < <(printf '%s\n' "${consumed[@]}" | sort -u)

    if [ "${#failed_discs[@]}" -gt 0 ]; then
        echo "  PARTIAL $title: ${#failed_discs[@]} disc(s) failed, sources kept:"
        for b in "${failed_discs[@]}"; do echo "      $b"; done
        failed=$((failed+1))
    fi

    if [ "${#outs[@]}" -gt 1 ] && [ "$DRY" = 0 ]; then
        m3u="$D/$title.m3u"; : > "$m3u"
        for o in "${outs[@]}"; do basename "$o" >> "$m3u"; done
        echo "  m3u: $title (${#outs[@]} discs)"
    fi

    bytes=0
    for f in "${consumed[@]}"; do bytes=$((bytes + $(stat -c%s "$f"))); done

    if [ "$DRY" = 1 ]; then
        extra=$(find "$gamedir" -mindepth 1 -type f | wc -l)  # includes nested discs
        echo "  would delete ${#consumed[@]} of $extra file(s) in $title"
        continue
    fi

    after=0
    for o in "${outs[@]}"; do after=$((after + $(stat -c%s "$o"))); done

    # Delete ONLY what these conversions consumed, then remove the directory if
    # that emptied it. The original rm -rf took the whole folder, so cover art,
    # save files, notes, and any disc this loop did not convert went with it.
    for f in "${consumed[@]}"; do rm -f "$f"; done
    # Prune directories the deletion emptied, deepest first, repeating until it
    # stops making progress - a per-disc subdirectory only becomes empty once
    # its own tracks are gone. A plain rm -rf would be one line, and would take
    # everything that was NOT consumed along with it.
    while [ -d "$gamedir" ]; do
        pruned=$(find "$gamedir" -depth -type d -empty -print -exec rmdir {} + 2>/dev/null | wc -l)
        if [ "$pruned" -eq 0 ]; then break; fi
    done
    if [ -d "$gamedir" ]; then
        left=$(find "$gamedir" -mindepth 1 | wc -l)
        echo "  KEPT DIR $title: $left file(s) were not part of the conversion"
    fi

    freed=$((freed + bytes - after))
    ok=$((ok+1))
    echo "  [$ok] $title  $(numfmt --to=iec "$bytes") -> $(numfmt --to=iec "$after")  (freed $(numfmt --to=iec "$freed") total)"
done

echo "=== DONE $(date +%H:%M:%S) ==="
echo "  converted: $ok    failed (source kept): $failed    skipped: $skipped"
echo "  space freed: $(numfmt --to=iec "$freed")"
df -h / | tail -1
