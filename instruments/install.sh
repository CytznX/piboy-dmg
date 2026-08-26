#!/usr/bin/env bash
# Install the instrument-server control panel and its units.
#
# Seven files go to six different places and nothing else states where; without
# this, reproducing the setup means reverse-engineering paths out of menu.sh and
# a flattened config filename. Mirrors config/udev/install.sh.
set -euo pipefail
cd "$(dirname "$0")"

USER_NAME=${PI_USER:-cytzenx}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[ -n "$HOME_DIR" ] || { echo "no such user: $USER_NAME" >&2; exit 1; }

say()  { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }

# Every shipped file names cytzenx, so a different PI_USER has to be substituted
# through ALL of them. Doing it only in the sudoers file - as an earlier version
# did - produced an install that reported success while the ES port pointed at
# /home/cytzenx/instruments/menu.sh and the services ran as a user whose data
# directory was never created.
sub() { sed "s|cytzenx|$USER_NAME|g; s|/home/$USER_NAME|$HOME_DIR|g" "$1"; }

say "installing for $USER_NAME ($HOME_DIR)"
[ "$USER_NAME" = cytzenx ] || say "substituting cytzenx -> $USER_NAME throughout"

# ---- directories first: every later step assumes these exist ----------------
install -d -o "$USER_NAME" -g "$USER_NAME" \
        "$HOME_DIR/instruments" "$HOME_DIR/instruments/data" \
        "$HOME_DIR/RetroPie/roms/ports"

install -m 755 -o "$USER_NAME" -g "$USER_NAME" menu.sh "$HOME_DIR/instruments/menu.sh"
say "menu       -> $HOME_DIR/instruments/menu.sh"

tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
for u in piboy-smartscope.service piboy-rtl433.service; do sub "$u" > "$tmpd/$u"; done
sudo install -m 644 "$tmpd/piboy-smartscope.service" "$tmpd/piboy-rtl433.service" /etc/systemd/system/
say "units      -> /etc/systemd/system/"

sudo install -m 644 99-labnation-smartscope.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
# Reloading rules does not re-apply them to a device already plugged in, so a
# scope attached right now would keep root:root ownership and the non-root
# service could not claim it - which looks like a broken server.
sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=04d8 2>/dev/null || true
say "udev rule  -> /etc/udev/rules.d/  (reloaded and re-triggered)"

# ---- sudoers: validate before installing, and never abort the run ----------
# A malformed sudoers file can lock the account out of sudo entirely. The
# reporting pipeline needs `|| true`: under `set -euo pipefail` a failing
# visudo in the error path killed the script, so the branch that existed to
# degrade gracefully instead left the machine half-configured.
sudoers_ok=1
sub 010-instruments-sudoers > "$tmpd/sudoers"
if sudo visudo -cf "$tmpd/sudoers" >/dev/null 2>&1; then
    sudo install -m 440 "$tmpd/sudoers" /etc/sudoers.d/010-instruments
    say "sudoers    -> /etc/sudoers.d/010-instruments  (validated)"
else
    sudoers_ok=0
    warn "sudoers REFUSED: visudo rejected the generated file. Nothing was written"
    warn "to /etc/sudoers.d, so sudo is untouched. The menu will not be able to"
    warn "start or stop services until this is resolved:"
    { sudo visudo -cf "$tmpd/sudoers" 2>&1 || true; } | sed 's/^/       /'
fi

sudo install -d /opt/retropie/configs/ports/instruments
sub ports-instruments-emulators.cfg > "$tmpd/emulators.cfg"
sudo install -m 644 -o "$USER_NAME" -g "$USER_NAME" \
     "$tmpd/emulators.cfg" /opt/retropie/configs/ports/instruments/emulators.cfg
say "runcommand -> /opt/retropie/configs/ports/instruments/emulators.cfg"

install -m 755 -o "$USER_NAME" -g "$USER_NAME" \
     "Instrument Servers.sh" "$HOME_DIR/RetroPie/roms/ports/Instrument Servers.sh"
say "ES port    -> $HOME_DIR/RetroPie/roms/ports/Instrument Servers.sh"

# plugdev so the non-root scope server can claim the device; systemd-journal so
# the menu's Logs screen shows unit output instead of "-- No entries --".
for g in plugdev systemd-journal; do
    id -nG "$USER_NAME" | grep -qw "$g" || {
        sudo usermod -aG "$g" "$USER_NAME"
        say "added $USER_NAME to $g (takes effect on next login)"
    }
done

# An earlier unit documented this file as the way to pin an SDR. The current one
# does not read it, so anyone who followed that advice would silently lose the
# setting rather than be told.
if [ -e /etc/default/piboy-rtl433 ]; then
    warn "/etc/default/piboy-rtl433 exists but is no longer read."
    warn "To pin a device now:  sudo systemctl edit piboy-rtl433"
fi

sudo systemctl daemon-reload
say "done - units installed but NOT enabled; start them from"
say "EmulationStation: Ports -> Instrument Servers"
[ "$sudoers_ok" = 1 ] || exit 1
