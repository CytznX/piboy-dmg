#!/bin/bash
# Install the udev rules in this directory. Without this the Bluetooth pad
# silently stops working after a reimage, with nothing pointing at the cause.
set -euo pipefail
cd "$(dirname "$0")"
for r in *.rules; do
  sudo install -m 644 "$r" /etc/udev/rules.d/"$r"
  echo "  installed /etc/udev/rules.d/$r"
done
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input --action=change
echo "  rules reloaded and re-triggered"
