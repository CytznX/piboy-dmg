#!/usr/bin/env bash
# Connect a desktop SDR GUI to the PiBoy's SoapyRemote server.
#
# No patching of gqrx / SDR++ / GNU Radio is needed - they all speak SoapySDR,
# and soapysdr-module-remote is the client half of the server running on the
# handheld. What is actually missing is the plumbing: finding the box, checking
# it is serving something, and producing the device string these GUIs want.
# That is all this does.
set -uo pipefail

HOST=${1:-}
SERVICE=_soapy._tcp

need() { command -v "$1" >/dev/null || { echo "missing: $1  (apt install $2)" >&2; return 1; }; }

discover() {
    need avahi-browse avahi-utils || return 1
    # Resolve rather than just browse: we want the address and port, and a
    # browse-only result tells us a name exists without proving it answers.
    avahi-browse -rtp "$SERVICE" 2>/dev/null | awk -F';' '$1=="=" {print $7" "$8" "$9}' | sort -u
}

echo "== looking for a SoapyRemote server on the network =="
if [ -n "$HOST" ]; then
    echo "  using the host you gave: $HOST"
    FOUND="$HOST"
else
    if ! command -v avahi-browse >/dev/null; then
        cat >&2 <<'MSG'
  cannot search: avahi-browse is not installed here (apt install avahi-utils).
  This is a missing tool on THIS machine, not a missing server - pass the
  PiBoy's address directly and everything else still works:

      sdr-connect.sh 10.1.1.34
MSG
        exit 1
    fi
    mapfile -t hits < <(discover)
    if [ "${#hits[@]}" -eq 0 ]; then
        cat >&2 <<'MSG'
  no server announced itself.

  Either it is not running (on the PiBoy: Ports -> Instrument Servers ->
  SDR streaming server), or mDNS is not crossing your network - it does not
  route between subnets and some access points block it. Pass the address:

      sdr-connect.sh 10.1.1.34
MSG
        exit 1
    fi
    for h in "${hits[@]}"; do echo "  found: $h"; done
    FOUND=$(printf '%s\n' "${hits[0]}" | awk '{print $2}')
fi

PORT=55132
echo
echo "== is it answering? =="
if ! timeout 5 bash -c ": >/dev/tcp/$FOUND/$PORT" 2>/dev/null; then
    echo "  $FOUND:$PORT is not accepting connections" >&2
    exit 1
fi
echo "  $FOUND:$PORT open"

echo
echo "== what radios is it serving? =="
if need SoapySDRUtil soapysdr-tools 2>/dev/null; then
    SoapySDRUtil --find="driver=remote,remote=$FOUND" 2>&1 | sed -n '/Found device/,$p' | head -20 | sed 's/^/  /'
    echo "  (no devices listed = server is up but nothing is plugged into the PiBoy)"
else
    echo "  install soapysdr-tools to enumerate remotely"
fi

cat <<MSG

== device strings ==

  SoapySDRUtil --probe="driver=remote,remote=$FOUND"

  gqrx        Configure I/O devices -> Device string:
                driver=remote,remote=$FOUND

  SDR++       Source: SoapySDR -> Refresh, pick the remote entry
              (or set SOAPY_SDR_REMOTE=$FOUND before launching)

  GNU Radio   Soapy Custom Source, device args:
                driver=remote,remote=$FOUND

  rtl_433 against the same radio, from here:
                rtl_433 -d "driver=remote,remote=$FOUND"
MSG
