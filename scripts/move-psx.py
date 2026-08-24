#!/usr/bin/env python3
"""Move the PS Classic-packaged PS1 collection into RetroPie layout.

Source layout is AutoBleem/PlayStation Classic:  <Game>/{cue,bin,lic,png,ini,cfg}
with multi-disc titles nesting a subfolder per disc. RetroPie wants the disc
images flat and an .m3u per multi-disc title so discs can be swapped in-game and
ES lists ONE entry instead of three.

  single disc -> roms/psx/<Game>.cue + .bin
  multi disc  -> roms/psx/discs/<Game (Disc n)>.cue + .bin
                 roms/psx/<Game>.m3u  listing them in order

.lic/.png/Game.ini/pcsx.cfg are PS Classic metadata and are not copied.
"""
import os, re, sys, shutil

SRC = os.path.expanduser("~/Downloads/--- TOP 100 PLAYSTATION1 GAMES")
DST = os.path.expanduser("~/RetroPie/roms/psx")
DISCS = os.path.join(DST, "discs")
GO = "--yes" in sys.argv
KEEP_EXT = {".cue", ".bin", ".chd", ".img", ".iso"}
# Already present with a live .srm memory card - leave it alone rather than
# shadow a save the user made last night.
SKIP_GAMES = {"01. Final Fantasy VII (USA)"}

def act(msg): print(("  " if GO else "  would ") + msg)

if GO:
    os.makedirs(DISCS, exist_ok=True)
single = multi = skipped = files_moved = 0
collisions = []

for game in sorted(os.listdir(SRC)):
    gp = os.path.join(SRC, game)
    if not os.path.isdir(gp):
        continue
    if game in SKIP_GAMES:
        print(f"  SKIP {game}  (already in psx with a save file)")
        skipped += 1
        continue

    entries = os.listdir(gp)
    subdirs = sorted(d for d in entries if os.path.isdir(os.path.join(gp, d)))

    if subdirs:                                     # multi-disc
        # Strip the "01. " ordering prefix the pack added; keep the real title.
        title = re.sub(r'^\d+\.\s*', '', game)
        cues = []
        for d in subdirs:
            dp = os.path.join(gp, d)
            for f in sorted(os.listdir(dp)):
                if os.path.splitext(f)[1].lower() not in KEEP_EXT:
                    continue
                dest = os.path.join(DISCS, f)
                if os.path.exists(dest):
                    collisions.append(dest); continue
                if GO: shutil.move(os.path.join(dp, f), dest)
                files_moved += 1
                if f.lower().endswith(('.cue', '.chd')):
                    cues.append(f)
        cues.sort()
        m3u = os.path.join(DST, title + ".m3u")
        act(f"m3u {title}.m3u  ({len(cues)} discs)")
        if GO:
            with open(m3u, "w", encoding="utf-8") as fh:
                for c in cues: fh.write(f"discs/{c}\n")
        multi += 1
    else:                                           # single disc
        moved_any = False
        for f in sorted(entries):
            if os.path.splitext(f)[1].lower() not in KEEP_EXT:
                continue
            dest = os.path.join(DST, f)
            if os.path.exists(dest):
                collisions.append(dest); continue
            if GO: shutil.move(os.path.join(gp, f), dest)
            files_moved += 1; moved_any = True
        if moved_any: single += 1

print(f"\n  single-disc games : {single}")
print(f"  multi-disc games  : {multi}  (each gets one .m3u)")
print(f"  skipped           : {skipped}")
print(f"  files {'moved' if GO else 'to move'}      : {files_moved}")
if collisions:
    print(f"  COLLISIONS (left in place, not overwritten): {len(collisions)}")
    for c in collisions[:5]: print(f"    {os.path.basename(c)}")
