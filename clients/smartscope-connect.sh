#!/usr/bin/env bash
# Diagnose the link between LabNation's SmartScope app and the server running
# on the PiBoy.
#
# The app finds the server by itself: DeviceInterface's InterfaceManagerZeroConf
# browses for _sss._tcp and hands what it finds to SmartScopeInterfaceEthernet.
# The C++ server on the handheld publishes that same service type, so there is
# nothing to configure and nothing to patch.
#
# This exists because when it does NOT appear, the app cannot tell you which of
# three quite different things went wrong. This can.
set -uo pipefail

HOST=${1:-}
SERVICE=_sss._tcp
SCOPE_VID=04d8            # 0052 = running, f4b5 = loading firmware

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

head_ "1. is the server announcing itself?"
if command -v avahi-browse >/dev/null; then
    mapfile -t hits < <(avahi-browse -rtp "$SERVICE" 2>/dev/null | awk -F';' '$1=="=" {print $7" "$8" "$9}' | sort -u)
    if [ "${#hits[@]}" -gt 0 ]; then
        for h in "${hits[@]}"; do say "found: $h"; done
        [ -z "$HOST" ] && HOST=$(printf '%s\n' "${hits[0]}" | awk '{print $2}')
    else
        say "nothing published $SERVICE on this network."
        say "mDNS does not cross subnets and some access points drop it, so this"
        say "alone does not mean the server is down - step 2 settles that."
    fi
else
    say "avahi-browse not installed here (apt install avahi-utils) - skipping."
    say "This is a gap on THIS machine; the app has its own mDNS client and may"
    say "still find the scope even when this check cannot."
fi

if [ -z "$HOST" ]; then
    head_ "no address"
    say "Pass the PiBoy's address to continue:   smartscope-connect.sh 10.1.1.34"
    exit 1
fi

head_ "2. is the server process up?"
if ssh -o ConnectTimeout=5 -o BatchMode=yes "cytzenx@$HOST" \
      'systemctl is-active piboy-smartscope' 2>/dev/null | grep -q '^active'; then
    say "piboy-smartscope is running on $HOST"
else
    say "piboy-smartscope is NOT running (or ssh refused)."
    say "On the handheld: Ports -> Instrument Servers -> Scope server"
    exit 1
fi

head_ "3. is a scope actually plugged into it?"
usb=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "cytzenx@$HOST" "lsusb -d $SCOPE_VID: 2>/dev/null" 2>/dev/null)
if [ -n "$usb" ]; then
    printf '  %s\n' "$usb"
    case "$usb" in
        *f4b5*) say "NOTE: f4b5 is the firmware-loading state. Give it a moment;"
                say "it should reappear as 0052 once the server uploads firmware." ;;
    esac
else
    say "no LabNation device on the PiBoy's USB."
    say "The server runs happily with nothing attached - it waits - so this is"
    say "the usual reason the app sees a server but offers no scope."
fi

head_ "4. what the app should do now"
say "Start SmartScope on this machine. It browses $SERVICE itself and should"
say "list the handheld without being told anything."
say ""
say "If it does not, the app and this script disagree, which narrows it to the"
say "app's own mDNS stack rather than the server or the network."
