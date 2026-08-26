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

HOST=${1:-${PI_HOST:-}}
PIBOY_USER=${PI_USER:-cytzenx}
SERVICE=_sss._tcp
SCOPE_VID=04d8                     # ids are authoritative in
                                   # instruments/99-labnation-smartscope.rules:
                                   # 0052 = running, f4b5 = loading firmware

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

head_ "1. is the server announcing itself?"
if command -v avahi-browse >/dev/null; then
    mapfile -t hits < <(avahi-browse -rtp "$SERVICE" 2>/dev/null | awk -F';' '$1=="=" {print $7" "$8" "$9}' | sort -u)
    if [ "${#hits[@]}" -gt 0 ]; then
        for h in "${hits[@]}"; do say "found: $h"; done
        [ -z "$HOST" ] && read -r _ HOST _ <<<"${hits[0]}"
    else
        say "nothing published $SERVICE on this network."
        say ""
        say "This is the EXPECTED state when no scope is plugged in. The server"
        say "creates its listener and its mDNS advertisement only after it finds"
        say "a scope on USB (main.cpp builds InterfaceServer with the device, not"
        say "before it), so silence here means 'server down' OR 'no scope' OR"
        say "'mDNS blocked' - steps 2 and 3 separate them."
    fi
else
    say "avahi-browse not installed here (apt install avahi-utils) - skipping."
    say "This is a gap on THIS machine; the app has its own mDNS client and may"
    say "still find the scope even when this check cannot."
fi

if [ -z "$HOST" ]; then
    # Step 1 can only succeed when a scope IS attached - the server publishes
    # nothing before that - so auto-discovery works precisely in the case where
    # nothing is wrong. Exiting here would abandon the user in the situation
    # they actually ran this for, right after promising a diagnosis.
    head_ "2-3. need an address to continue"
    say "Discovery found nothing, which is expected when no scope is attached,"
    say "so there is no address to check. Give one and the remaining steps run:"
    say ""
    say "    smartscope-connect.sh 10.1.1.34"
    say "    PI_HOST=piboy64.local smartscope-connect.sh"
    exit 1
fi

head_ "2. is the server process up?"
# This has to be ssh. A TCP probe - which is how the SDR helper answers the
# same question - cannot work here, because smartscopeserver opens no socket at
# all until a scope is attached, so "down" and "up but idle" are identical from
# the network. Separate ssh's own failure from the service's state rather than
# reporting one as the other.
state=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$PIBOY_USER@$HOST" \
          'systemctl is-active piboy-smartscope' 2>/dev/null)
ssh_rc=$?
if [ -z "$state" ] && [ "$ssh_rc" -ne 0 ] && [ "$ssh_rc" -ne 3 ]; then
    say "could not reach $PIBOY_USER@$HOST over ssh (exit $ssh_rc)."
    say "That is a login problem, not a verdict on the server: no key, sshd off,"
    say "or a different account - set PI_USER if yours is not $PIBOY_USER."
    say "Check on the handheld instead: Ports -> Instrument Servers."
    exit 1
fi
case "$state" in
    active)   say "piboy-smartscope is running on $HOST" ;;
    activating) say "piboy-smartscope is still starting - try again in a moment"; exit 1 ;;
    *)        say "piboy-smartscope is $state on $HOST."
              say "Start it: Ports -> Instrument Servers -> Scope server"
              exit 1 ;;
esac

head_ "3. is a scope actually plugged into it?"
# lsusb -d exits 1 when it matches nothing, so "no scope" and "ssh broke" both
# yield empty output - separate them by exit code rather than reporting one as
# the other, which is the whole point of this script.
usb=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$PIBOY_USER@$HOST" "lsusb -d $SCOPE_VID:" 2>/dev/null)
usb_rc=$?
if [ "$usb_rc" -gt 1 ]; then
    say "could not check: ssh or lsusb failed on the handheld (exit $usb_rc)."
    say "That is not a verdict on the scope - look at Attached hardware in the"
    say "menu on the device itself."
elif [ -n "$usb" ]; then
    printf '  %s\n' "$usb"
    case "$usb" in
        *f4b5*) say "NOTE: f4b5 is the firmware-loading state. Give it a moment;"
                say "it should reappear as 0052 once the server uploads firmware." ;;
    esac
else
    say "no LabNation device on the PiBoy's USB."
    say "The server waits rather than exiting, so this is the usual reason for"
    say "step 1 finding nothing while step 2 says the server is fine. Plug the"
    say "scope in and re-run; nothing needs restarting."
fi

head_ "4. what the app should do now"
say "Start SmartScope on this machine. It browses $SERVICE itself and should"
say "list the handheld without being told anything."
say ""
say "If it does not, the app and this script disagree, which narrows it to the"
say "app's own mDNS stack rather than the server or the network."
