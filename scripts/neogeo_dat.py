#!/usr/bin/env python3
"""Shared NeoGeo DAT parsing and archive indexing.

Both the audit and the rebuild need exactly this, and having it twice is how
they came to disagree: the first parser required name/size/crc in that order,
so every inherited <rom merge="..."> entry was silently skipped and games looked
complete on a subset of their files. Fixing that in one place is the point.
"""
import collections, os, re, zipfile

DAT_DEFAULT = "/opt/retropie/libretrocores/lr-fbneo/dats/FinalBurn Neo (ClrMame Pro XML, Arcade only).dat"

# BIOS roms live in neogeo.zip and FBNeo loads them from there, so they are not
# part of a game's completeness test.
BIOS_HINT = re.compile(
    r'^(sp[-0-9]|uni-bios|sm1\.sm1|sfix\.sfix|000-lo\.lo|neo-|vs-bios|japan-j3|neopen|neodebug)',
    re.I)


def _attr(line, key):
    m = re.search(rf'{key}="([^"]*)"', line)
    return m.group(1) if m else None


def parse_dat(path=DAT_DEFAULT):
    """{game: [(filename, crc), ...]} for game roms only, BIOS entries excluded.

    A LIST of pairs, not a {crc: name} dict. Keying by CRC silently collapses two
    roms with identical content but different names - common in NeoGeo sets, and
    universal for zero-length roms, which all carry crc 00000000. That made a set
    look complete when a file was genuinely missing, and made the rebuild write
    one name where the DAT wants two.

    Attributes are read order-independently: inherited entries carry merge="..."
    between name and size, and a positional regex drops every one of them.
    """
    games, cur = {}, None
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            if '<game name=' in line:
                cur = _attr(line, 'name')
                games[cur] = []
            elif '<rom ' in line and cur:
                name, crc = _attr(line, 'name'), _attr(line, 'crc')
                if name and crc and not BIOS_HINT.match(name):
                    games[cur].append((name, crc.lower().zfill(8)))
    return games


def index_archives(src):
    """{crc: [(zipname, member), ...]} for every file in every zip under src."""
    have = collections.defaultdict(list)
    for z in sorted(f for f in os.listdir(src) if f.lower().endswith('.zip')):
        try:
            with zipfile.ZipFile(os.path.join(src, z)) as zf:
                for i in zf.infolist():
                    have[f"{i.CRC:08x}"].append((z, i.filename))
        except (zipfile.BadZipFile, OSError):
            pass
    return have


def complete_games(games, have):
    """Games whose every rom CRC is present somewhere in the collection."""
    return sorted(g for g, roms in games.items()
                  if roms and all(crc in have for _, crc in roms))
