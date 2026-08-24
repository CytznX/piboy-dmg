#!/usr/bin/env python3
"""Rebuild the romsets the audit found complete, naming files as the DAT wants.

Reads the audit's output rather than recomputing it, so the two can never
disagree about which games are buildable.
"""
import json, os, sys, zipfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from neogeo_dat import parse_dat, index_archives, complete_games

SRC = os.path.expanduser("~/neogeo-orig")
OUT = os.path.expanduser("~/RetroPie/roms/neogeo")
LIST = os.path.expanduser("~/neogeo-complete.json")

games = parse_dat()
have = index_archives(SRC)
try:
    complete = json.load(open(LIST))
except (OSError, ValueError):
    print("  no audit output - computing")
    complete = complete_games(games, have)

print(f"  rebuilding {len(complete)} games")
built = 0
for g in complete:
    if g not in games:
        print(f"    SKIP {g}: not in the current DAT")
        continue
    # Group members by source archive so each zip is opened once per game, not
    # once per member - a NeoGeo set is 10-40 files mostly from one parent.
    by_src = {}
    missing = [n for n, c in games[g] if not have.get(c)]
    if missing:
        # A stale ~/neogeo-complete.json (written against a different DAT, or
        # before the source collection changed) would otherwise raise IndexError
        # partway through, after zips have already been written.
        print(f"    SKIP {g}: {len(missing)} rom(s) no longer available")
        continue
    for name, crc in games[g]:
        srcz, member = have[crc][0]
        by_src.setdefault(srcz, []).append((member, name))
    dest = os.path.join(OUT, g + ".zip")
    try:
        with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as out:
            for srcz, members in by_src.items():
                with zipfile.ZipFile(os.path.join(SRC, srcz)) as zf:
                    for member, name in members:
                        out.writestr(name, zf.read(member))
        built += 1
        if built % 15 == 0:
            print(f"    {built}/{len(complete)}...", flush=True)
    except (OSError, zipfile.BadZipFile) as e:
        print(f"    FAILED {g}: {e}")
        try: os.remove(dest)
        except OSError: pass
print(f"  built {built}")
