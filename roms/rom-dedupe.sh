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
import collections, os, re, sys
GO = sys.argv[1] == "1"
groups = collections.defaultdict(list)
for line in open(os.path.expanduser('~/rom-audit/hashes.sorted.tsv'), encoding='utf-8', errors='replace'):
    h, _, p = line.rstrip('\n').partition('\t')
    groups[h].append(p)
SKIP = ('/roms/mame-libretro/', '/roms/ports/')

# A disc image is not a standalone file, and deleting one member of a set breaks
# it silently - the survivor still exists and still points at something gone.
# Byte-identical members are routine rather than exotic: silent audio tracks,
# shared filler and near-identical libcrypt patches collide constantly, both
# between discs of one game and between unrelated games. Protection here is
# therefore deliberately fail-CLOSED, and covers two different families:
#
#   reference-by-name   .cue/.gdi/.m3u/.toc name their tracks explicitly, by
#                       bare filename resolved in the sheet's own directory.
#                       The names do not derive from the sheet's stem
#                       ("Game (Disc 1).cue" -> "Game (Disc 1) (Track 04).bin"),
#                       so reading the sheet is the only way to learn them.
#
#   pair-by-stem        .ccd/.img/.sub, .mds/.mdf, .cue/.sbi and their kin carry
#                       no reference at all; the partner is found by sharing the
#                       stem. Enumerating those formats would be a blocklist
#                       that fails OPEN - the first format missing from it gets
#                       its partner deleted, and nothing says so. The general
#                       property covers every such format, today's and the ones
#                       not met yet, and costs one comparison.
SHEETS  = ('.cue', '.gdi', '.m3u', '.toc')
FILE_RE = re.compile(r'^\s*(?:FILE|DATAFILE)\s+(?:"([^"]+)"|(\S+))', re.I)
GDI_RE  = re.compile(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+(?:"([^"]+)"|(\S+))')

def references(sheet, ext):
    """Bare filenames this sheet names, in its own directory."""
    out = []
    try:
        lines = open(sheet, encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return out
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

# Only directories holding a file the delete loop could actually pick are worth
# scanning: a sheet protects nothing outside its own directory, so a directory
# with no deletion candidate cannot spare anything.
candidates = [files for files in groups.values()
              if len(files) >= 2 and not any(s in f for f in files for s in SKIP)]

protected = set()
for d in {os.path.dirname(os.path.realpath(p)) for files in candidates for p in files}:
    try:
        entries = os.listdir(d)
    except OSError:
        continue
    stems = collections.defaultdict(list)
    for name in entries:
        stem, ext = os.path.splitext(name)
        stems[stem].append(name)
        if ext.lower() not in SHEETS:
            continue
        sheet = os.path.join(d, name)
        protected.add(os.path.realpath(sheet))
        for ref in references(sheet, ext.lower()):
            protected.add(os.path.realpath(os.path.join(d, ref)))
    for names in stems.values():
        if len(names) > 1:                # one stem, several extensions: a set
            for name in names:
                protected.add(os.path.realpath(os.path.join(d, name)))

def rank(f):
    alt  = 'lternate' in f
    z64  = 0 if f.lower().endswith('.z64') else 1
    return (alt, z64, -len(f))

deleted = freed = spared = 0
for files in candidates:
    keeper = sorted(files, key=rank)[0]
    for f in files:
        if f == keeper: continue
        if os.path.realpath(f) in protected:
            spared += 1                       # named by a sheet, or half of a stem pair
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
