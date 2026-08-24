#!/usr/bin/env python3
"""Report which NeoGeo romsets can be rebuilt from what we own."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from neogeo_dat import parse_dat, index_archives, complete_games

SRC = os.path.expanduser("~/neogeo-orig")
OUT = os.path.expanduser("~/neogeo-complete.json")

games = parse_dat()
have = index_archives(SRC)
complete = complete_games(games, have)
partial = sum(1 for g, roms in games.items()
              if roms and 0 < sum(crc in have for _, crc in roms) < len(roms))

print(f"  DAT games         : {len(games)}")
print(f"  distinct CRCs held: {len(have)}")
print(f"  fully rebuildable : {len(complete)}")
print(f"  partial           : {partial}")
for g in complete[:20]:
    print(f"    {g}")
if len(complete) > 20:
    print(f"    ... and {len(complete)-20} more")
json.dump(complete, open(OUT, "w"))
print(f"  -> {OUT}")
