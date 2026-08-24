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
set -euo pipefail
GO=0
if [ "${1:-}" = "--yes" ]; then GO=1; fi
python3 - "$GO" <<'PY'
import collections, glob, os, re, sys
GO = sys.argv[1] == "1"
groups = collections.defaultdict(list)
for line in open(os.path.expanduser('~/rom-audit/hashes.sorted.tsv'), encoding='utf-8', errors='replace'):
    h, _, p = line.rstrip('\n').partition('\t')
    groups[h].append(p)
SKIP = ('/roms/mame-libretro/', '/roms/ports/')

# A disc image is not a standalone file. A .cue/.gdi/.ccd/.toc names its track
# files by BARE FILENAME, and a .m3u names its discs the same way, so those
# references resolve only inside the sheet's own directory. Deduplicating across
# directories - the entire point of this script - therefore breaks the surviving
# copy's siblings. And byte-identical tracks are routine rather than exotic:
# silent audio tracks and shared filler collide constantly between discs of one
# game and between different games. Anything a sheet names, and every sheet
# itself, is off limits no matter how many identical copies exist.
SHEETS  = ('.cue', '.gdi', '.m3u', '.ccd', '.toc')
FILE_RE = re.compile(r'^\s*(?:FILE|DATAFILE)\s+(?:"([^"]+)"|(\S+))', re.I)
GDI_RE  = re.compile(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+(?:"([^"]+)"|(\S+))')

def references(sheet, ext):
    """Bare filenames this sheet names, in its own directory."""
    out = []
    try:
        lines = open(sheet, encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return out
    if ext == '.ccd':
        # A .ccd names nothing; its siblings are found by sharing the stem.
        stem = os.path.basename(os.path.splitext(sheet)[0])
        return [stem + e for e in ('.img', '.sub')]
    for line in lines:
        if ext == '.m3u':
            s = line.strip()
            if s and not s.startswith('#'):
                out.append(s)
        else:
            m = (GDI_RE if ext == '.gdi' else FILE_RE).match(line)
            if m:
                out.append(m.group(1) or m.group(2))
    return out

protected = set()
for d in {os.path.dirname(p) for files in groups.values() for p in files}:
    for sheet in glob.glob(os.path.join(glob.escape(d), '*')):
        ext = os.path.splitext(sheet)[1].lower()
        if ext not in SHEETS:
            continue
        protected.add(os.path.realpath(sheet))
        for ref in references(sheet, ext):
            protected.add(os.path.realpath(os.path.join(d, ref)))

def rank(f):
    alt  = 'lternate' in f
    z64  = 0 if f.lower().endswith('.z64') else 1
    return (alt, z64, -len(f))

deleted = freed = spared = 0
for h, files in groups.items():
    if len(files) < 2 or any(s in f for f in files for s in SKIP):
        continue
    keeper = sorted(files, key=rank)[0]
    for f in files:
        if f == keeper: continue
        if os.path.realpath(f) in protected:
            spared += 1                       # named by a .cue/.gdi/.m3u/.ccd/.toc
            continue
        try: sz = os.path.getsize(f)
        except OSError: continue
        if GO:
            try: os.remove(f)
            except OSError as e: print(f"  FAILED {f}: {e}"); continue
        deleted += 1; freed += sz
print(f"  protected by sidecars: {len(protected)} paths; spared {spared} deletions")
print(f"  {'deleted' if GO else 'would delete'}: {deleted} files, {freed/1024**3:.2f} GiB")
PY
