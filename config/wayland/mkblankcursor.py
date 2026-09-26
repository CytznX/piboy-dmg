#!/usr/bin/env python3
"""Write a 1x1 fully transparent XCursor.

labwc has no hide-cursor option (its config knows only the workspace OSD and
menu hideDelay), so the portable way to hide the pointer is to give it a cursor
that is transparent. Writing the Xcursor binary directly avoids depending on
xcursorgen, which is not installed and lives in an X11 package this device has
no other use for.

Format, from libXcursor:
  file header : "Xcur", uint32 headerlen(16), uint32 version, uint32 ntoc
  toc entry   : uint32 type(0xfffd0002 = image), uint32 subtype(nominal size),
                uint32 byte offset of the chunk
  image chunk : uint32 headerlen(36), uint32 type, uint32 subtype, uint32 ver,
                uint32 width, height, xhot, yhot, delay, then w*h ARGB pixels
"""
import os, struct

IMAGE_TYPE = 0xFFFD0002
SIZES = (16, 24, 32, 48)          # one image per nominal size a theme may ask for


def build() -> bytes:
    ntoc = len(SIZES)
    header = struct.pack("<4sIII", b"Xcur", 16, 0x00010000, ntoc)
    toc_len = 12 * ntoc
    chunk_len = 36 + 4            # 1x1 pixel
    out_toc, out_chunks, pos = b"", b"", 16 + toc_len
    for size in SIZES:
        out_toc += struct.pack("<III", IMAGE_TYPE, size, pos)
        out_chunks += struct.pack(
            "<IIIIIIIII", 36, IMAGE_TYPE, size, 1, 1, 1, 0, 0, 0
        ) + struct.pack("<I", 0x00000000)   # one fully transparent ARGB pixel
        pos += chunk_len
    return header + out_toc + out_chunks


def main():
    theme = os.path.expanduser("~/.icons/blank/cursors")
    os.makedirs(theme, exist_ok=True)
    data = build()

    primary = "default"
    with open(os.path.join(theme, primary), "wb") as f:
        f.write(data)

    # Every name a client might request. left_ptr is what labwc/wlroots asks for
    # by default; the rest cover anything a toolkit sets on hover.
    for name in ("left_ptr", "arrow", "top_left_arrow", "pointer", "text",
                 "xterm", "hand1", "hand2", "watch", "crosshair"):
        link = os.path.join(theme, name)
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(primary, link)

    index = os.path.expanduser("~/.icons/blank/index.theme")
    with open(index, "w") as f:
        f.write("[Icon Theme]\nName=blank\nComment=Fully transparent cursor\n")

    print(f"wrote {len(data)} bytes to {theme}/{primary}")
    print(f"sizes: {', '.join(map(str, SIZES))}")
    print(f"aliases: {len(os.listdir(theme)) - 1}")


if __name__ == "__main__":
    main()
