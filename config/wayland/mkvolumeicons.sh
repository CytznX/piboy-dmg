#!/bin/bash
# Derive the volume OSD's icons from Adwaita, recoloured for a dark panel.
#
# Two reasons this exists rather than pointing mako straight at the theme:
#
# 1. COLOUR. Adwaita's symbolic icons are fill="#2e3436" - near black, drawn for
#    a light theme. On the OSD's black panel that is invisible, which on screen
#    is indistinguishable from a missing icon. Adwaita ships no light variant:
#    /usr/share/icons/Adwaita has only 16x16, scalable and symbolic, and only
#    symbolic carries audio-volume-*.
#
# 2. LOOKUP. mako's icon-path "approximates the XDG Icon Theme Specification but
#    does not support any of the theme metadata", so pointing it at a theme is
#    guesswork. An absolute path to a file is not.
#
# A script rather than four committed blobs, so the provenance stays obvious and
# they can be regenerated when Adwaita changes. Same idea as mkblankcursor.py.
set -eu

SRC=/usr/share/icons/Adwaita/symbolic/status
DST=${1:-/opt/retropie/configs/all/wayland/icons}

[ -d "$SRC" ] || { echo "$SRC missing - is adwaita-icon-theme installed?" >&2; exit 1; }

mkdir -p "$DST"
for i in muted low medium high; do
    src="$SRC/audio-volume-$i-symbolic.svg"
    [ -r "$src" ] || { echo "missing $src" >&2; exit 1; }
    # Only the fill changes. Everything else is Adwaita's, including the 16px
    # viewBox - mako scales it to max-icon-size, and SVG scales cleanly.
    sed 's/fill="#2e3436"/fill="#FFFFFF"/g' "$src" > "$DST/volume-$i.svg"
done

echo "wrote volume-{muted,low,medium,high}.svg to $DST"
