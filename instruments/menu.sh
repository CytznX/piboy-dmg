#!/bin/bash
# Instrument server control panel, launched from EmulationStation via runcommand
# (which hands over the display and starts joy2key, so the gamepad drives dialog).
export TERM=linux
BACKTITLE="PiBoy DMG - Instrument Servers"
DATA=$HOME/instruments/data

svc_state() {   # -> "on" / "off" / "absent"
    systemctl list-unit-files "$1" >/dev/null 2>&1 || { echo absent; return; }
    systemctl is-active --quiet "$1" && echo on || echo off
}
dot() { [ "$1" = on ] && printf '[ON ]' || printf '[   ]'; }

addrs() { ip -4 addr show | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '^127'; }

info_screen() {
    local ip; ip=$(addrs | head -1)
    dialog --backtitle "$BACKTITLE" --title "Connecting a client" --msgbox "\
This device: $(hostname)   $(addrs | tr '\n' ' ')

SDR streaming (SoapyRemote)
  Server listens on tcp 55132 and announces itself over mDNS.
  Clients that speak SoapySDR can use it directly:

    SoapySDRUtil --find=\"driver=remote\"
    SDR++ / gqrx / GNU Radio: choose the Remote / Soapy source
    and enter    $ip    (or $(hostname).local)

  Anything SoapySDR supports works - HackRF, RTL-SDR, others.

Decoder logging (rtl_433)
  Writes newline-delimited JSON to
    $DATA/rtl433.jsonl
  Collect it from a client with:
    ssh $(whoami)@$ip tail -f $DATA/rtl433.jsonl

Scope server (SmartScope)
  LabNation's own C++ server, announced over mDNS the same way.
  Start it here, then plug the scope in - it waits for the device.
  On a client, LabNation's SmartScope app finds it automatically;
  if it does not, point it at    $ip

  Scope not detected? Check it appears under Attached hardware
  (USB 04d8:0052, or 04d8:f4b5 while loading firmware).
" 22 74
}

logs_screen() {
    local unit=$1
    journalctl -u "$unit" -n 200 --no-pager > /tmp/inst.log 2>&1
    dialog --backtitle "$BACKTITLE" --title "$unit (last 200 lines)" --textbox /tmp/inst.log 22 74
}

data_screen() {
    if [ -s "$DATA/rtl433.jsonl" ]; then
        local n; n=$(wc -l < "$DATA/rtl433.jsonl")
        tail -200 "$DATA/rtl433.jsonl" > /tmp/inst.data
        dialog --backtitle "$BACKTITLE" --title "rtl433.jsonl - $n records, last 200" \
               --textbox /tmp/inst.data 22 74
    else
        dialog --backtitle "$BACKTITLE" --msgbox "No decoder data yet.\n\nStart the rtl_433 logger and leave it running with a receiver attached." 10 60
    fi
}

toggle() {   # unit, friendly name
    local unit=$1 name=$2
    if systemctl is-active --quiet "$unit"; then
        sudo systemctl stop "$unit"
        dialog --backtitle "$BACKTITLE" --msgbox "$name stopped." 7 44
    else
        # A unit that failed earlier stays in the failed state and drags that
        # into the next attempt's status; clear it so each start is judged on
        # its own outcome.
        sudo systemctl reset-failed "$unit" 2>/dev/null
        if sudo systemctl start "$unit" 2>/tmp/inst.err; then
            sleep 1
            if systemctl is-active --quiet "$unit"; then
                dialog --backtitle "$BACKTITLE" --msgbox "$name started." 7 44
            else
                journalctl -u "$unit" -n 15 --no-pager > /tmp/inst.err
                dialog --backtitle "$BACKTITLE" --title "$name failed to stay up" --textbox /tmp/inst.err 18 70
            fi
        else
            dialog --backtitle "$BACKTITLE" --title "Could not start $name" --textbox /tmp/inst.err 12 60
        fi
    fi
}

hw_screen() {
    { echo "== USB devices =="; lsusb
      echo; echo "== SoapySDR sees =="; SoapySDRUtil --find 2>&1 | sed -n '1,25p'
      echo; echo "== HackRF =="; hackrf_info 2>&1 | head -12
      echo; echo "== SmartScope =="
      lsusb -d 04d8: 2>/dev/null || echo "no LabNation device on USB (04d8:0052 / 04d8:f4b5)"
    } > /tmp/inst.hw 2>&1
    dialog --backtitle "$BACKTITLE" --title "Attached hardware" --textbox /tmp/inst.hw 22 74
}

while true; do
    sdr=$(svc_state soapyremote-server.service)
    sco=$(svc_state piboy-smartscope.service)
    r43=$(svc_state piboy-rtl433.service)
    CHOICE=$(dialog --backtitle "$BACKTITLE" --title "Instrument Servers" \
        --cancel-label "Exit" --menu "\nGamepad: D-pad to move, A to select, B to go back\n" 20 68 10 \
        1 "$(dot "$sdr") SDR streaming server (SoapyRemote)" \
        2 "$(dot "$sco") Scope server (SmartScope)" \
        3 "$(dot "$r43") Decoder logger (rtl_433 -> JSON)" \
        4 "Attached hardware" \
        5 "How to connect a client" \
        6 "Collected data" \
        7 "Logs: SDR server" \
        8 "Logs: scope server" \
        9 "Logs: decoder" \
        3>&1 1>&2 2>&3) || break
    case "$CHOICE" in
        1) toggle soapyremote-server.service "SDR streaming server" ;;
        2) toggle piboy-smartscope.service   "Scope server" ;;
        3) toggle piboy-rtl433.service       "Decoder logger" ;;
        4) hw_screen ;;
        5) info_screen ;;
        6) data_screen ;;
        7) logs_screen soapyremote-server.service ;;
        8) logs_screen piboy-smartscope.service ;;
        9) logs_screen piboy-rtl433.service ;;
    esac
done
clear
