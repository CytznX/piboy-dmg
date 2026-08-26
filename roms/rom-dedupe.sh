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
# An unquoted FILE line may contain spaces ("FILE Game Track 01.bin BINARY"),
# so the bare-name branch must be non-greedy up to the optional mode keyword
# rather than \S+, which would capture only "Game".
FILE_RE = re.compile(
    r'^\s*(?:FILE|DATAFILE)\s+(?:"([^"]+)"|(.+?))'
    r'(?:\s+(?:BINARY|MOTOROLA|AIFF|WAVE|MP3|AUDIO))?\s*$', re.I)
# The unquoted branch must reach to the trailing offset field, not stop at the
# first whitespace: a .gdi naming `1 0 4 2352 Game Track 04.bin 0` would
# otherwise yield "Game", a path that does not exist, so the real track goes
# unprotected and is eligible for deletion. Same class of bug FILE_RE above was
# already fixed for; it was never applied here.
GDI_RE  = re.compile(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+(?:"([^"]+)"(?:\s+\d+)?|(.+?)\s+\d+)\s*$')

def references(sheet, ext):
    """Bare filenames this sheet names, or None if they could not be determined.

    None is deliberately not []. An unreadable sheet means the references are
    UNKNOWN, and the caller must then protect the whole directory. Returning an
    empty list would quietly mean "this sheet protects nothing", which is the
    fail-OPEN direction in front of an irreversible delete.
    """
    out = []
    try:
        lines = open(sheet, encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return None
    for line in lines:
        if ext == '.m3u':
            s = line.strip()
            if s and not s.startswith('#'):
                out.append(s)
        else:
            m = (GDI_RE if ext == '.gdi' else FILE_RE).match(line)
            if m:
                out.append(m.group(1) or m.group(2))
    return out or None          # a sheet naming nothing is malformed, not empty

# Only directories holding a file the delete loop could actually pick are worth
# scanning: a sheet protects nothing outside its own directory, so a directory
# with no deletion candidate cannot spare anything.
candidates = [files for files in groups.values()
              if len(files) >= 2 and not any(s in f for f in files for s in SKIP)]

# Which content each path holds, so the stem rule below can tell a SET apart
# from a pair of COPIES.
path_hash = {}
for h, files in groups.items():
    for f in files:
        path_hash[os.path.realpath(f)] = h

protected = set()
protected_ci = set()          # sheets may disagree with the filesystem on case

def protect(path):
    rp = os.path.realpath(path)
    protected.add(rp)
    protected_ci.add(rp.casefold())

def is_protected(path):
    rp = os.path.realpath(path)
    return rp in protected or rp.casefold() in protected_ci

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
        protect(sheet)
        refs = references(sheet, ext.lower())
        if refs is None:                  # unknown contents -> protect the lot
            for other in entries:
                protect(os.path.join(d, other))
            continue
        for ref in refs:
            protect(os.path.join(d, ref))

    for names in stems.values():
        if len(names) < 2:
            continue
        # Byte-identical stem-mates are COPIES of one another, not parts of a
        # set - n64's .v64/.z64 pairs are exactly that, and collapsing them is
        # this script's whole purpose. Only differing content means genuinely
        # complementary parts (.cue/.bin, .mds/.mdf, .cue/.sbi). A file absent
        # from the hash snapshot counts as distinct, which errs toward keeping.
        paths = [os.path.realpath(os.path.join(d, n)) for n in names]
        if len({path_hash.get(x, x) for x in paths}) < 2:
            continue
        for x in paths:
            protect(x)

def rank(f):
    alt  = 'lternate' in f
    z64  = 0 if f.lower().endswith('.z64') else 1
    return (alt, z64, -len(f))

deleted = freed = spared = stale = 0
for files in candidates:
    # The hash file is a SNAPSHOT and its paths go stale. Re-pick the keeper
    # among members that still exist: choosing a keeper that has since been
    # moved or removed, then deleting the others, erases the game outright and
    # reports it as an ordinary successful deletion.
    live = [f for f in files if os.path.exists(f)]
    if len(live) < len(files):
        stale += len(files) - len(live)
    if len(live) < 2:
        continue                          # nothing left to collapse
    keeper = sorted(live, key=rank)[0]
    for f in live:
        if f == keeper: continue
        if is_protected(f):
            spared += 1                       # named by a sheet, or half of a stem pair
            continue
        try: sz = os.path.getsize(f)
        except OSError: continue
        if GO:
            try: os.remove(f)
            except OSError as e: print(f"  FAILED {f}: {e}"); continue
        deleted += 1; freed += sz
print(f"  protected: {len(protected)} paths; spared {spared}; stale snapshot entries {stale}")
print(f"  {'deleted' if GO else 'would delete'}: {deleted} files, {freed/1024**3:.2f} GiB")
PY
