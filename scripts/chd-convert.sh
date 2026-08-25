#!/bin/bash
# Convert Dreamcast GDI sets to CHD, verify, then remove only what was consumed.
#
# Dry run by default, like every other destructive script here; pass --yes to
# act. This is the only one that deletes source media irreversibly, so it is the
# last place to invert that convention.
#
# Order matters: convert -> verify -> only then delete. A CHD that fails
# verification leaves its source untouched, so a bad conversion can never cost a
# game. `chdman verify` is the expensive part of the run and is the reason the
# delete is safe; do not drop it to save time.
set -euo pipefail
shopt -s nullglob

D=$HOME/RetroPie/roms/dreamcast
LOG=$HOME/chd-convert.log
GO=0
if [ "${1:-}" = "--yes" ]; then GO=1; fi

ok=0; failed=0; skipped=0; freed=0

if ! command -v chdman >/dev/null; then echo "chdman not found" >&2; exit 1; fi
if [ ! -d "$D" ]; then echo "no dreamcast directory: $D" >&2; exit 1; fi

# note() is progress a human watches; record() is the manifest. Both land in the
# log, only note() reaches the console - a hundred titles delete some six hundred
# files, and that would bury the progress it is printed alongside.
_log()   { [ "$GO" = 1 ] && printf '%s %s\n' "$(date +%F_%T)" "$*" >> "$LOG"; return 0; }
note()   { printf '%s\n' "$*"; _log "$*"; }
record() { _log "$*"; }

# The track files a .gdi names, resolved against its own directory. Lines after
# the count are "idx lba type sectorsize FILE offset"; FILE may be quoted, and
# unquoted names can contain spaces, so take everything between field 4 and the
# last field rather than one whitespace-delimited token.
gdi_tracks() {
    local gdi=$1 dir=${1%/*}
    awk -v d="$dir" 'NR>1 && NF>=6 {
            name=""
            for (i=5; i<NF; i++) name = name (i>5 ? " " : "") $i
            gsub(/^"|"$/, "", name)
            if (name != "") print d "/" name
         }' "$gdi"
}

for gamedir in "$D"/*/; do
    title=${gamedir%/}; title=${title##*/}
    [ "$title" = discs ] && continue
    # Recursive on purpose: some titles nest one subdirectory per disc (Sakura
    # Taisen 3 ships five that way), and -maxdepth 1 would convert none of them
    # while still counting the title as handled.
    mapfile -t gdis < <(find "$gamedir" -name '*.gdi' | sort)
    if [ "${#gdis[@]}" -eq 0 ]; then
        note "  SKIP $title (no .gdi)"; skipped=$((skipped+1)); continue
    fi

    # Multi-disc titles put their discs in discs/ and leave only the .m3u at the
    # top level, matching move-psx.py. A flat layout makes EmulationStation list
    # the playlist AND every disc, so a four-disc game appears five times - the
    # exact thing the .m3u exists to prevent.
    if [ "${#gdis[@]}" -gt 1 ]; then outdir="$D/discs"; ref="discs/"; else outdir="$D"; ref=""; fi

    # Collision check before converting anything: two titles whose .gdi share a
    # basename would otherwise overwrite each other, and with the original -f
    # flag that was silent, with the first title's source already deleted.
    collision=""
    for g in "${gdis[@]}"; do
        b=${g##*/}; b=${b%.gdi}
        if [ -e "$outdir/$b.chd" ]; then collision="$b.chd"; break; fi
    done
    if [ -n "$collision" ]; then
        note "  SKIP $title: output exists, refusing to overwrite: $collision"
        skipped=$((skipped+1)); continue
    fi

    outs=(); consumed=(); failed_discs=()
    [ "$GO" = 1 ] && mkdir -p "$outdir"
    for g in "${gdis[@]}"; do
        b=${g##*/}; b=${b%.gdi}
        out="$outdir/$b.chd"
        if [ "$GO" = 1 ]; then
            # No -f. The collision check above is the only sanctioned overwrite.
            if ! chdman createcd -i "$g" -o "$out" >/dev/null 2>&1; then
                note "  FAIL convert: $b"; rm -f "$out"; failed_discs+=("$b"); continue
            fi
            if ! chdman verify -i "$out" >/dev/null 2>&1; then
                note "  FAIL verify:  $b"; rm -f "$out"; failed_discs+=("$b"); continue
            fi
        else
            echo "  would convert: $b -> ${ref}$b.chd"
        fi
        # One copy of "what this disc consumed", shared by both paths: if the dry
        # run computed it separately it could drift and then lie about what a
        # real run would delete, which is the one thing it exists to show.
        outs+=("$out"); consumed+=("$g")
        while IFS= read -r t; do
            if [ -e "$t" ]; then consumed+=("$t"); fi
        done < <(gdi_tracks "$g")
    done

    if [ "${#outs[@]}" -eq 0 ]; then
        failed=$((failed+1)); note "  KEPT SOURCE: $title (no disc converted)"; continue
    fi

    # A track named by two .gdi must not be counted twice, nor stat'd after the
    # first rm removed it.
    mapfile -t consumed < <(printf '%s\n' "${consumed[@]}" | sort -u)
    bytes=$(stat -c%s -- "${consumed[@]}" | awk '{s+=$1} END{print s+0}')

    if [ "${#failed_discs[@]}" -gt 0 ]; then
        failed=$((failed+1))
        note "  PARTIAL $title: ${#failed_discs[@]} disc(s) failed, sources kept:"
        for b in "${failed_discs[@]}"; do note "      $b"; done
    fi

    if [ "$GO" = 0 ]; then
        echo "  would delete ${#consumed[@]} of $(find "$gamedir" -type f | wc -l) file(s) in $title"
        continue
    fi

    # Skip the playlist entirely while a disc is known-failed: one that is
    # missing a disc looks perfectly healthy in EmulationStation and strands the
    # player partway through the game. The consequence is that a title repaired
    # and re-converted later needs its .m3u written by hand, because by then its
    # other discs are already CHDs and this loop no longer sees them - reported
    # rather than guessed at.
    if [ "${#gdis[@]}" -gt 1 ]; then
        m3u="$D/$title.m3u"
        if [ "${#failed_discs[@]}" -gt 0 ]; then
            note "  no .m3u for $title while a disc is unconverted"
        else
            # From this title's own converted discs, never a name-prefix glob:
            # "Shenmue"* would also match "Shenmue II (Europe) (Disc 1).chd" and
            # silently put another game's discs in this playlist.
            : > "$m3u"
            for o in "${outs[@]}"; do printf 'discs/%s\n' "${o##*/}"; done >> "$m3u"
            note "  m3u: $title (${#outs[@]} discs)"
        fi
    fi

    after=0
    for o in "${outs[@]}"; do after=$((after + $(stat -c%s "$o"))); done

    # Delete only what these conversions consumed, then remove directories the
    # deletion emptied. -delete implies -depth, so children go before parents
    # and arbitrarily deep nesting collapses in a single pass. rm -rf would be
    # one line and would take cover art, saves and unconverted discs with it.
    for f in "${consumed[@]}"; do rm -f "$f"; record "deleted $f"; done
    find "$gamedir" -depth -type d -empty -delete 2>/dev/null || true
    if [ -d "$gamedir" ]; then
        note "  KEPT DIR $title: $(find "$gamedir" -mindepth 1 | wc -l) file(s) not part of the conversion"
    fi

    freed=$((freed + bytes - after))
    ok=$((ok+1))
    note "  [$ok] $title  $(numfmt --to=iec "$bytes") -> $(numfmt --to=iec "$after")  (freed $(numfmt --to=iec "$freed") total)"
done

echo "=== DONE $(date +%H:%M:%S) ==="
echo "  converted: $ok    failed (source kept): $failed    skipped: $skipped"
echo "  space freed: $(numfmt --to=iec "$freed")"
[ "$GO" = 0 ] && echo "  DRY RUN - nothing was changed. Pass --yes to act."
df -h / | tail -1
