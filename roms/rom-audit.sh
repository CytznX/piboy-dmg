#!/bin/bash
# Read-only audit of the rom library. Writes reports; deletes nothing.
#
# Duplicate detection hashes only files that share a size with another file -
# two files of different sizes cannot be identical, so hashing everything would
# read 26G to find the same answer.
R=$HOME/RetroPie/roms
OUT=$HOME/rom-audit
CFG=/etc/emulationstation/es_systems.cfg
mkdir -p "$OUT"

# Things that are not games: saves, states, scraped art, metadata, mame support files.
find "$R" -type f \
    ! -name '*.srm' ! -name '*.state*' ! -name '*.txt' ! -name '*.xml' \
    ! -name '*.cfg' ! -name '*.hi' ! -name '*.nv' ! -name '*.dat' \
    ! -name '*.png' ! -name '*.jpg' ! -name '*.bmp' ! -name '*.sh' \
    ! -path '*/images/*' ! -path '*/media/*' \
    -printf '%s\t%p\n' 2>/dev/null | sort -n > "$OUT/inventory.tsv"

total=$(wc -l < "$OUT/inventory.tsv")
echo "=== inventory: $total candidate rom files ==="

# --- duplicates -------------------------------------------------------------
# Sizes that occur more than once are the only possible duplicates.
awk -F'\t' 'NR==FNR{c[$1]++; next} c[$1]>1' "$OUT/inventory.tsv" "$OUT/inventory.tsv" \
    | cut -f2- > "$OUT/samesize.txt"
cand=$(wc -l < "$OUT/samesize.txt")
echo "=== $cand files share a size with another - hashing just those ==="

# md5sum already prints "hash  path" and accepts a whole file list, so one
# batched invocation replaces two forks per file plus a reopen of the output.
tr '\n' '\0' < "$OUT/samesize.txt" | xargs -0 -r md5sum 2>/dev/null \
    | sed 's/  /\t/' > "$OUT/hashes.tsv"

sort "$OUT/hashes.tsv" > "$OUT/hashes.sorted.tsv"
awk -F'\t' '{c[$1]++} END{for(h in c) if(c[h]>1) print h}' "$OUT/hashes.sorted.tsv" > "$OUT/duphashes.txt"
ndup=$(wc -l < "$OUT/duphashes.txt")
echo "=== $ndup distinct files exist in more than one copy ==="

# The hash file is already sorted, so groups are contiguous: one awk pass emits
# the report and totals the waste. The previous shape re-grepped the whole file
# three times per group and forked stat once more, which is thousands of full
# scans on a library this size. Sizes come from inventory.tsv, which already has
# every one of them.
waste=$(awk -F'\t' '
    NR==FNR { size[$2] = $1; next }                 # inventory.tsv: size<TAB>path
    { crc[$1] = crc[$1] "\n    " $2; n[$1]++; first[$1] = first[$1] ? first[$1] : $2 }
    END {
        total = 0
        for (h in n) {
            if (n[h] < 2) continue
            printf "--- %s%s\n", h, crc[h] > OUT
            total += size[first[h]] * (n[h] - 1)
        }
        print total
    }
' OUT="$OUT/duplicates.txt" "$OUT/inventory.tsv" "$OUT/hashes.sorted.tsv")
echo "$waste" > "$OUT/waste.txt"

echo "=== redundant copies occupy $(numfmt --to=iec $waste) ==="
echo "$waste" > "$OUT/waste.txt"

# --- system/extension sanity ------------------------------------------------
echo "=== systems whose files do not match the extensions ES accepts ==="
for d in "$R"/*/; do
    s=$(basename "$d")
    [ -L "${d%/}" ] && continue                     # skip the genesis symlink
    n=$(find "$d" -maxdepth 1 -type f ! -name '*.txt' ! -name '*.xml' 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || continue
    want=$(awk -v sys="$s" '$0 ~ "<name>"sys"</name>" {f=1} f && /<extension>/ {gsub(/.*<extension>|<\/extension>.*/,""); print; exit}' "$CFG" | tr 'A-Z' 'a-z')
    [ -n "$want" ] || { echo "  $s: not a system ES knows (no emulator installed)"; continue; }
    bad=$(find "$d" -maxdepth 1 -type f ! -name '*.txt' ! -name '*.xml' ! -name '*.srm' ! -name '*.state*' -printf '%f\n' 2>/dev/null \
          | sed -n 's/.*\(\.[A-Za-z0-9]\{1,5\}\)$/\1/p' | tr 'A-Z' 'a-z' | sort -u \
          | while read -r e; do case " $want " in *" $e "*) ;; *) echo "$e";; esac; done | tr '\n' ' ')
    [ -n "$bad" ] && echo "  $s: unplayable extensions present -> $bad"
done
echo "=== reports written to $OUT ==="
