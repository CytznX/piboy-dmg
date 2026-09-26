# PiBoy DMG - Wayland session (labwc + waybar + EmulationStation).
# Installed as /opt/retropie/configs/all/autostart.sh.
# Switch between this and the plain KMS boot with:
#     sudo /opt/retropie/configs/all/wayland/switch.sh kms
#     sudo /opt/retropie/configs/all/wayland/switch.sh wayland
W=/opt/retropie/configs/all/wayland
exec >> /var/log/piboy-wayland.log 2>&1
echo "=== session $(date -Is) on $(tty) ==="

# labwc has no hide-cursor option, so hide it with a transparent theme.
# See $W/mkblankcursor.py; the theme lives in ~/.icons/blank.
export XCURSOR_THEME=blank
export XCURSOR_SIZE=24

# /proc/uptime, not `date +%s`: this Pi has no RTC, so fake-hwclock restores a
# stale time at boot and chrony steps the clock - often seconds into the session,
# squarely inside the window below. A forward step would make a session that
# died instantly look long and suppress the fallback; a backward step would make
# a healthy one look short and start a second EmulationStation. Uptime cannot
# step.
uptime_s() { local u _; read -r u _ < /proc/uptime; echo "${u%.*}"; }

start=$(uptime_s)
labwc -s "$W/startup.sh"
rc=$?
elapsed=$(( $(uptime_s) - start ))
echo "=== labwc exited rc=$rc after ${elapsed}s ==="

# Escape hatch. A normal session lasts minutes to hours and ends because
# EmulationStation was quit, so labwc exiting almost immediately means the
# compositor never came up at all - a bad update, a missing library, a DRM it
# could not take. Falling through would leave a handheld sitting at a bare
# console with no frontend and no obvious way back. Boot the plain KMS
# EmulationStation instead: it does not need a compositor, and it is the
# configuration this device ran for a month.
if [ "$elapsed" -lt 10 ]; then
    echo "=== compositor did not start - falling back to KMS EmulationStation ==="
    exec emulationstation
fi
