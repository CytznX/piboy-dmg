#!/bin/bash
# Delete redundant copies of byte-identical roms. Dry run unless --yes.
#
# Excluded on purpose:
#   mame-libretro  .CFG files are per-game configs; identical content is normal
#                  and deleting one destroys that game's configuration
#   ports          game data (each Marathon scenario ships its own Readme.md)
#
# Keeper preference, in order: not in an "Alternate Roms" folder; then .z64 for
# n64 (the conventional big-endian label - the bytes are identical either way);
# then the longest filename, which is the more descriptive No-Intro style name.
GO=0; [ "${1:-}" = "--yes" ] && GO=1
python3 - "$GO" <<'PY'
import collections, os, sys
GO = sys.argv[1] == "1"
groups = collections.defaultdict(list)
for line in open(os.path.expanduser('~/rom-audit/hashes.sorted.tsv'), encoding='utf-8', errors='replace'):
    h, _, p = line.rstrip('\n').partition('\t')
    groups[h].append(p)
SKIP = ('/roms/mame-libretro/', '/roms/ports/')

def rank(f):
    alt  = 'lternate' in f
    z64  = 0 if f.lower().endswith('.z64') else 1
    return (alt, z64, -len(f))

deleted = freed = 0
for h, files in groups.items():
    if len(files) < 2 or any(s in f for f in files for s in SKIP):
        continue
    keeper = sorted(files, key=rank)[0]
    for f in files:
        if f == keeper: continue
        try: sz = os.path.getsize(f)
        except OSError: continue
        if GO:
            try: os.remove(f)
            except OSError as e: print(f"  FAILED {f}: {e}"); continue
        deleted += 1; freed += sz
print(f"  {'deleted' if GO else 'would delete'}: {deleted} files, {freed/1024**3:.2f} GiB")
PY
