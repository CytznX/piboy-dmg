# Wayland session — THE DEFAULT BOOT as of 2026-09-25

labwc + waybar + EmulationStation as a Wayland client, proven working 2026-09-25.
Prerequisites are already in place: SDL2 and RetroArch both rebuilt with their
Wayland backends (see ../../patches/*-enable-wayland.patch).

Lives on the device at /opt/retropie/configs/all/wayland/. Switch boot paths:

    sudo /opt/retropie/configs/all/wayland/switch.sh status | kms | wayland

    autostart-wayland.sh  installed as autostart.sh; starts labwc, and if the
                          compositor dies within 10s falls back to plain KMS
                          EmulationStation rather than leaving a bare console
    autostart-kms.sh      the stock one-liner, `emulationstation #auto`
    switch.sh             flips between them
    startup.sh            runs INSIDE labwc: waybar, then the ES wrapper
    waybar.json/.css      the bar
    mkblankcursor.py      builds the transparent cursor theme
    tmpfiles-piboy-wayland.conf  -> /etc/tmpfiles.d/, creates the session log
                          owned by cytzenx (autostart runs as the user and
                          cannot create a file in /var/log itself)

The fallback is tested, with stub labwc/emulationstation binaries placed ahead
on PATH so the real script runs unmodified: labwc exiting at 0s falls back,
exiting at 12s does not. Do NOT test it by sed-editing the script - an earlier
attempt missed an indented `exec emulationstation`, spawned a second frontend,
and the botched cleanup then killed the live session.

## The one non-obvious setting

`"layer": "overlay"` — NOT `"top"`. wlroots raises a fullscreen window above the
`top` layer, so a bar there is configured correctly, reports the right geometry,
and is completely invisible behind EmulationStation. `overlay` is above
fullscreen. This cost a round of "waybar says it worked but I see nothing".

## What works, and what does not

Works: ES renders at 640x480, all buttons navigate, the bar is visible over it.
labwc holds DRM master and ES is a client - which is the whole architecture.

Games DO launch, as of 2026-09-25 - see patches/runcommand-wayland.patch.
Under a compositor there is no controlling terminal, and runcommand launched the
emulator with `eval "$COMMAND" </dev/tty`, which fails with ENXIO. Five input
redirections now go through a $TTY_IN that falls back to /dev/null. Confirmed:
game renders, plays, and waybar draws over it.

The pre-launch configure menu works too, which it did not at first. It needs a
pty: with no controlling terminal the key read gets EOF and dialog would draw
onto the VT the compositor covers. runcommand now re-execs itself inside `foot`
(a native Wayland terminal) when WAYLAND_DISPLAY is set and there is no tty.
Verified visible, readable at monospace:size=10, and navigable with the d-pad -
joy2key works under the compositor. Force --term=xterm-256color: foot defaults
to TERM=foot, and a missing terminfo breaks tput and dialog the same way
TERM=unknown did.

EVERY emulator works as a native Wayland client: EmulationStation, RetroArch,
PPSSPP, Aleph One, OpenTyrian, and Dreamcast via lr-flycast-dev. That is Stage 1
paying off - SDL2 was the shared chokepoint, so rebuilding it with the wayland
backend gave all the SDL2-based emulators wayland for free.

THE ONE EXCEPTION: redream cannot work and cannot be fixed here. It statically
links its own SDL built with KMSDRM as the only video driver, so under a
compositor it dies with "No available video device". XWayland does not help - it
never starts, because there is no X11 backend to trigger it, so the usual
SDL_VIDEODRIVER=x11 advice does not apply. Batocera, who also use labwc, removed
redream from v36+ on Wayland devices for exactly this reason. Dreamcast now
defaults to lr-flycast-dev, which costs some performance on Pi-class hardware.

## Known artifact: faint flickering horizontal bands (UNRESOLVED, accepted)

Faint darker horizontal patches come and go on the ES background under the
compositor. Not present under direct KMS. Judged very subtle and not worth more
time (2026-09-25) - recorded so it is not re-investigated from scratch.

Ruled out, with evidence:
- NOT direct-scanout toggling. waybar on `overlay` means something is always on
  top, so scanout is already disabled and compositing is constant. No change.
- NOT damage tracking / buffer age. `WLR_SCENE_DEBUG_DAMAGE=rerender` forces a
  full re-render every frame; the flicker was unchanged. (Reverted - it costs
  damage tracking for nothing. It was cheap though: labwc 6.1% -> 7.2% CPU.)
- NOT bandwidth or thermal. ES 30% CPU, labwc 6%, v3d 750MHz, throttled=0x0.
- NOT a plane/format problem. One plane (plane-1 on pixelvalve-0), XR24,
  modifier=0x0 linear, no vc4/DRM errors in dmesg.
- NOT static RGB666 truncation - that would band consistently, not flicker.

Untested next suspect: the EGL config SDL2 picks on its wayland backend versus
kmsdrm. If wayland lands on a lower-precision visual, gradients would band and
shimmer. Would need to dump the chosen EGLConfig from inside ES.

## SOLVED: the sometimes-drawn mouse cursor

labwc has no hide-cursor option (labwc-config only matches "hide" for the
workspace OSD and menu hideDelay), so the pointer is hidden by giving it a
cursor that is transparent. `mkblankcursor.py` writes a 1x1 fully transparent
XCursor directly - the binary format is trivial and xcursorgen is not installed
- into ~/.icons/blank/cursors/, with aliases for every name a client might ask
for. autostart-wayland.sh exports XCURSOR_THEME=blank. Confirmed gone.
Only applies inside the wayland session; a normal KMS boot has no cursor anyway.

## SOLVED: two status bars in game

RetroArch's own bar and waybar were both drawing. Turned RetroArch's OFF via
CONFIG, not by retiring the patch: `status_bar_show = "false"` in
/opt/retropie/configs/all/retroarch.cfg. The feature is still compiled in, so it
is one word to restore if Stage 5 shows waybar cannot cover the standalone
emulators. Previous config saved at ~/retroarch.cfg.two-bars on the device.
Retiring patches/retroarch-status-bar.patch properly (drop the applyPatch line
in retroarch.sh and rebuild) is the LAST step, after Stage 5.


## The RetroPie configuration menu needs the same treatment, separately

The `retropie` system in es_systems.cfg calls retropie_packages.sh DIRECTLY and
never touches runcommand, so the foot re-exec that fixed the pre-launch menu does
not cover it. Every entry (splashscreen, wifi, bluetooth, audiosettings, rpsetup)
draws with dialog onto the VT the compositor covers, then blocks on input nobody
can give it - the handheld hangs on a black screen. Killing it also skips
joy2keyStop, leaving an orphan joy2key fighting ES for the gamepad.

Fixed with `retropiemenu-launch.sh`, pointed at from es_systems.cfg
(patches/es_systems-retropiemenu-wrapper.patch). A WRAPPER rather than a patch to
retropiemenu.sh, because sudo has env_reset with no env_keep for the session
variables: by the time retropie_packages.sh runs, WAYLAND_DISPLAY and
XDG_RUNTIME_DIR are already empty. The wrapper runs BEFORE sudo, as the user,
with the session env intact - it opens foot, and sudo happens inside it. Patching
retropiemenu.sh would have needed sudo -E or a sudoers rule as well, and would
have left a root process owning a GUI client.

Limitation: only the ES path is fixed. Running
`retropie_packages.sh retropiemenu launch ...` by hand over SSH still hangs.

Upstream RetroPie has NO Wayland support - grepping current master for
wayland/WAYLAND_DISPLAY/terminal across retropiemenu.sh and runcommand.sh finds
nothing relevant, and upstream runcommand has the same 5 input and 7 output
/dev/tty redirections ours did. There is no upstream fix to adopt or wait for,
and equally nothing that will conflict with these patches.

## Volume overlay (the bar the original PiBoy had)

Experimental Pi's `osd` binary drew a volume bar through dispmanx; full KMS
removed that, and the replacement was a text message pushed into RetroArch over
UDP (SHOW_MSG), which only appears in RetroArch. Under Wayland a real overlay is
possible again:

    wob                      layer-shell overlay bar, apt-installable
    wob.ini                  -> ~/.config/wob/wob.ini, sized for 640x480
    piboy-volume-osd.sh      feeds it, started from startup.sh

piboy-vold ALREADY publishes the wheel position to /run/piboy-volume on every
change, so nothing new reads the input device - the feeder just watches that
file. It uses `inotifywait -m` (monitor mode), NOT a loop respawning inotifywait
per event: the wheel emits ~25 events/second while turning and a process per
event is real battery drain on a handheld. piboy-vold rewrites the file in place
with O_TRUNC so close_write fires and the watch survives.

Confirmed working by eye. Tunables all live in wob.ini: width/height, anchor,
margin, timeout, colours.

NOT YET RETIRED: piboy-vold still also sends `SHOW_MSG Volume [...] NN%` to
RetroArch, so inside RetroArch you get both. Same situation the status bar was
in. Retire the SHOW_MSG volume path only after wob has been lived with - and
note that retroarch-showmsg-flush.patch exists to serve it, though that patch
should stay regardless for low-battery alerts.
