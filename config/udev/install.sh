#!/bin/bash
# Install the udev rules in this directory. Without this the Bluetooth pad
# silently stops working after a reimage, with nothing pointing at the cause.
set -euo pipefail
shopt -s nullglob            # without this an empty dir runs the body once with
                             # r='*.rules', install fails, and set -e aborts
                             # BEFORE the reload - leaving rules copied but dead
cd "$(dirname "$0")"
rules=(*.rules)
if [ ${#rules[@]} -eq 0 ]; then
  echo "  no .rules files here - nothing to install" >&2
  exit 1
fi
for r in "${rules[@]}"; do
  sudo install -m 644 "$r" /etc/udev/rules.d/"$r"
  echo "  installed /etc/udev/rules.d/$r"
done
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input --action=change
echo "  rules reloaded and re-triggered"
