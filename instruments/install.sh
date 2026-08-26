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

say() { printf '  %s\n' "$*"; }

say "installing for $USER_NAME ($HOME_DIR)"

install -d -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/instruments" "$HOME_DIR/instruments/data"
install -m 755 -o "$USER_NAME" -g "$USER_NAME" menu.sh "$HOME_DIR/instruments/menu.sh"
say "menu       -> $HOME_DIR/instruments/menu.sh"

sudo install -m 644 piboy-smartscope.service piboy-rtl433.service /etc/systemd/system/
say "units      -> /etc/systemd/system/"

sudo install -m 644 99-labnation-smartscope.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
say "udev rule  -> /etc/udev/rules.d/  (reloaded)"

# visudo -cf first: a malformed sudoers file can lock the account out of sudo
# entirely, and this one is generated from a template with a substituted name.
tmp=$(mktemp)
sed "s/^cytzenx /$USER_NAME /" 010-instruments-sudoers > "$tmp"
if sudo visudo -cf "$tmp" >/dev/null 2>&1; then
    sudo install -m 440 "$tmp" /etc/sudoers.d/010-instruments
    say "sudoers    -> /etc/sudoers.d/010-instruments  (validated)"
else
    say "sudoers    -> REFUSED: visudo rejected the generated file, leaving sudo untouched"
    sudo visudo -cf "$tmp" 2>&1 | sed 's/^/               /'
fi
rm -f "$tmp"

sudo install -d /opt/retropie/configs/ports/instruments
sudo install -m 644 -o "$USER_NAME" -g "$USER_NAME" \
     ports-instruments-emulators.cfg /opt/retropie/configs/ports/instruments/emulators.cfg
say "runcommand -> /opt/retropie/configs/ports/instruments/emulators.cfg"

install -m 755 -o "$USER_NAME" -g "$USER_NAME" \
     "Instrument Servers.sh" "$HOME_DIR/RetroPie/roms/ports/Instrument Servers.sh"
say "ES port    -> $HOME_DIR/RetroPie/roms/ports/Instrument Servers.sh"

id -nG "$USER_NAME" | grep -qw plugdev || {
    sudo usermod -aG plugdev "$USER_NAME"
    say "added $USER_NAME to plugdev (takes effect on next login)"
}

sudo systemctl daemon-reload
say "done - the units are installed but NOT enabled; start them from"
say "EmulationStation: Ports -> Instrument Servers"
