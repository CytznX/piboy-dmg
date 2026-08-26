#!/bin/bash
# Move multi-disc Dreamcast CHDs into discs/ and re-point their playlists, so
# EmulationStation lists one entry per game instead of the playlist plus every
# disc. Matches the layout move-psx.py already produces for PlayStation.
#
# Dry run unless --yes.
set -euo pipefail
shopt -s nullglob

D=$HOME/RetroPie/roms/dreamcast
GO=0; [ "${1:-}" = "--yes" ] && GO=1 || true

[ -d "$D" ] || { echo "no dreamcast dir" >&2; exit 1; }

# --- Phase 1: validate everything before touching anything ---------------
declare -A plan=()      # source file -> owning playlist
problems=0
for m in "$D"/*.m3u; do
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in discs/*) continue ;; esac        # already migrated
        src="$D/$line"
        if [ ! -e "$src" ]; then
            echo "  MISSING  $(basename "$m") -> $line"; problems=$((problems+1)); continue
        fi
        if [ -e "$D/discs/$line" ]; then
            echo "  COLLIDES $line already exists in discs/"; problems=$((problems+1)); continue
        fi
        if [ -n "${plan[$src]:-}" ]; then
            echo "  SHARED   $line referenced by two playlists"; problems=$((problems+1)); continue
        fi
        plan[$src]=$m
    done < "$m"
done

if [ "$problems" -gt 0 ]; then
    echo "=== $problems problem(s); refusing to migrate ==="; exit 1
fi
echo "=== ${#plan[@]} disc(s) across $(printf '%s\n' "${plan[@]}" | sort -u | wc -l) playlist(s), all resolvable ==="

if [ "$GO" = 0 ]; then
    for src in "${!plan[@]}"; do echo "  would move: ${src##*/}"; done | sort
    flat=$(find "$D" -maxdepth 1 -name '*.chd' | wc -l)
    m3u=$(find "$D" -maxdepth 1 -name '*.m3u' | wc -l)
    echo "  ES entries: $((flat + m3u)) now -> $((flat - ${#plan[@]} + m3u)) after"
    echo "  DRY RUN - nothing changed. Pass --yes to act."
    exit 0
fi

# --- Phase 2: back up the playlists, then move ---------------------------
mkdir -p "$D/discs"
bk="$HOME/dreamcast-m3u-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$bk"; cp "$D"/*.m3u "$bk"/
echo "  playlists backed up to $bk"

for src in "${!plan[@]}"; do
    mv -n -- "$src" "$D/discs/"
    echo "  moved ${src##*/}"
done

# --- Phase 3: re-point the playlists -------------------------------------
for m in "$D"/*.m3u; do
    tmp=$(mktemp)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in discs/*) printf '%s\n' "$line" ;;
                        *)       printf 'discs/%s\n' "$line" ;;
        esac
    done < "$m" > "$tmp"
    mv -- "$tmp" "$m"
done

# --- Phase 4: verify every reference resolves ----------------------------
bad=0
for m in "$D"/*.m3u; do
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [ -e "$D/$line" ] || { echo "  BROKEN $(basename "$m") -> $line"; bad=$((bad+1)); }
    done < "$m"
done
flat=$(find "$D" -maxdepth 1 -name '*.chd' | wc -l)
m3u=$(find "$D" -maxdepth 1 -name '*.m3u' | wc -l)
echo "=== done: $bad broken reference(s) ==="
echo "  top-level .chd: $flat   discs/: $(find "$D/discs" -name '*.chd' | wc -l)   .m3u: $m3u"
echo "  ES entries now: $((flat + m3u))"
[ "$bad" -eq 0 ] || exit 1
