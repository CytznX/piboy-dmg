#!/bin/bash
# Instrument server control panel, launched from EmulationStation via runcommand
# (which hands over the display and starts joy2key, so the gamepad drives dialog).
export TERM=linux
BACKTITLE="PiBoy DMG - Instrument Servers"
DATA=$HOME/instruments/data
TMP=/tmp/inst.out                       # one screen is shown at a time

# Every instrument is described once, here. Adding a fourth means adding a row,
# not renumbering a menu and a case arm in lockstep. Discovery by unit-name
# convention would not work: soapyremote-server ships from the distro package
# and matches no naming scheme this repo controls.
UNITS=(
    "soapyremote-server.service|SDR streaming server (SoapyRemote)"
    "piboy-smartscope.service|Scope server (SmartScope)"
    "piboy-rtl433.service|Decoder logger (rtl_433 -> JSON)"
)

dlg() { dialog --backtitle "$BACKTITLE" "$@"; }

# One systemctl call for every unit rather than two per unit. LoadState
# distinguishes "not installed" from "installed but stopped", which the marker
# below actually renders - on a fresh machine the units may genuinely be absent,
# and showing that as an ordinary stopped service sends you debugging the wrong
# thing.
declare -A LOAD ACTIVE
read_states() {
    local u n l a
    for u in "${UNITS[@]}"; do
        n=${u%%|*}
        # One call per unit, two lines read by position within that call. Asking
        # for several units at once returns them separated by a blank line, so a
        # flat index over the whole output silently shears the values across
        # unit boundaries - it reported one unit's ActiveState as another's
        # LoadState, and only looked right because the absent case happened to
        # fall through to the same marker.
        { read -r l; read -r a; } < <(systemctl show -p LoadState -p ActiveState --value "$n" 2>/dev/null)
        LOAD[$n]=$l; ACTIVE[$n]=$a
    done
}
marker() {
    case "${LOAD[$1]:-}" in
        not-found|"") printf '[ -- ]' ;;                      # unit file missing
        *) [ "${ACTIVE[$1]:-}" = active ] && printf '[ ON ]' || printf '[    ]' ;;
    esac
}

addrs() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]' ; }

show_file() { dlg --title "$1" --textbox "$TMP" 22 74; }

info_screen() {
    local ip; ip=$(addrs | head -1)
    dlg --title "Connecting a client" --msgbox "\
This device: $(hostname)   $(addrs | tr '\n' ' ')

SDR streaming (SoapyRemote)
  Listens on tcp 55132, announced over mDNS as _soapy._tcp.
  Anything speaking SoapySDR uses it directly:

    SoapySDRUtil --find=\"driver=remote\"
    gqrx / SDR++ / GNU Radio: pick the Remote or Soapy source
    and enter    $ip    (or $(hostname).local)

Decoder logging (rtl_433)
  Newline-delimited JSON at
    $DATA/rtl433.jsonl
  Collect it from a client with:
    ssh $(whoami)@$ip tail -f $DATA/rtl433.jsonl

Scope server (SmartScope)
  LabNation's own server, announced as _sss._tcp. Start it here,
  then plug the scope in - it waits for the device. Their app
  finds it by itself; if not, point it at    $ip

  Scope missing? Check Attached hardware for usb 04d8:0052
  (or 04d8:f4b5 while it loads firmware). Ids come from
  99-labnation-smartscope.rules, which is authoritative.
" 24 74
}

logs_menu() {
    local items=() u n l
    for u in "${UNITS[@]}"; do n=${u%%|*}; l=${u##*|}; items+=("$n" "$l"); done
    local pick
    pick=$(dlg --title "Logs" --cancel-label "Back" --menu "" 14 66 6 "${items[@]}" 3>&1 1>&2 2>&3) || return
    journalctl -u "$pick" -n 200 --no-pager > "$TMP" 2>&1
    show_file "$pick (last 200 lines)"
}

data_screen() {
    if [ -s "$DATA/rtl433.jsonl" ]; then
        # Size, not a line count: this file grows without bound while the logger
        # runs, and counting lines means reading all of it off the SD card just
        # to title a window.
        local sz; sz=$(du -h "$DATA/rtl433.jsonl" | cut -f1)
        tail -200 "$DATA/rtl433.jsonl" > "$TMP"
        show_file "rtl433.jsonl - $sz, last 200 records"
    else
        dlg --msgbox "No decoder data yet.\n\nStart the rtl_433 logger and leave it running with a receiver attached." 10 60
    fi
}

hw_screen() {
    dlg --infobox "Scanning hardware..." 3 40      # the Soapy probe takes seconds
    { echo "== USB =="; lsusb
      echo; echo "== SoapySDR sees =="; SoapySDRUtil --find 2>&1 | sed -n '1,25p;25q'
      echo; echo "== HackRF =="; hackrf_info 2>&1 | head -12
      echo; echo "== SmartScope =="
      lsusb -d 04d8: 2>/dev/null || echo "no LabNation device (04d8:0052 / 04d8:f4b5)"
    } > "$TMP" 2>&1
    show_file "Attached hardware"
}

toggle() {
    local unit=$1 name=$2
    if [ "${LOAD[$unit]:-}" = not-found ]; then
        dlg --msgbox "$name is not installed on this system.\n\nRun instruments/install.sh from the repo." 9 60
        return
    fi
    if systemctl is-active --quiet "$unit"; then
        sudo systemctl stop "$unit"
        dlg --msgbox "$name stopped." 7 44
        return
    fi
    # A unit that failed earlier stays failed and drags that into this attempt's
    # status; clear it so each start is judged on its own outcome.
    sudo systemctl reset-failed "$unit" 2>/dev/null
    sudo systemctl start "$unit" > "$TMP" 2>&1
    # Type=simple units are active the moment the fork succeeds, so a doomed
    # process still reports success here. The pause is what lets it fail.
    sleep 1
    if systemctl is-active --quiet "$unit"; then
        dlg --msgbox "$name started." 7 44
    else
        # Append rather than overwrite: systemctl's own stderr is often the only
        # place a permission problem is explained, and the journal alone would
        # not mention it.
        { echo "--- journal ---"; journalctl -u "$unit" -n 15 --no-pager; } >> "$TMP" 2>&1
        show_file "$name did not start"
    fi
}

while true; do
    read_states
    items=(); i=1
    for u in "${UNITS[@]}"; do
        items+=("$i" "$(marker "${u%%|*}") ${u##*|}"); i=$((i+1))
    done
    items+=(h "Attached hardware" c "How to connect a client" d "Collected data" l "Logs")
    CHOICE=$(dlg --title "Instrument Servers" --cancel-label "Exit" \
        --menu "\nD-pad to move, A to select, B to go back\n" 18 68 8 "${items[@]}" 3>&1 1>&2 2>&3) || break
    case "$CHOICE" in
        [0-9]*) sel=${UNITS[$((CHOICE-1))]}; toggle "${sel%%|*}" "${sel##*|}" ;;
        h) hw_screen ;;
        c) info_screen ;;
        d) data_screen ;;
        l) logs_menu ;;
        # Without this an unmatched tag silently repaints the menu, and an
        # operator with no keyboard cannot tell that from a toggle that did
        # nothing.
        *) dlg --msgbox "Unhandled menu tag: $CHOICE\n\nThis is a bug in menu.sh." 8 50 ;;
    esac
done
clear
