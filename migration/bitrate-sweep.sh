#!/bin/bash
# Sweep the XPi bit-bang clock half-period against CRC error rate and CPU cost.
# Run as root on the PiBoy. Restores the starting value on exit.
P=/sys/module/xpi_gamecon/parameters
DWELL=${DWELL:-20}          # seconds per setting
ORIG=$(cat $P/bitrate)
trap 'echo "$ORIG" > $P/bitrate; echo "restored bitrate=$ORIG"' EXIT

softirq_us() {   # cumulative softirq jiffies -> us, field 7 of cpu line
    awk '/^cpu /{print ($8)*10000}' /proc/stat
}

printf "%-8s %-12s %-12s %-10s %-12s\n" BITRATE GOOD/s CRC/s ERR_RATE SOFTIRQ_%
for br in 7 6 5 4 3 2; do
    echo "$br" > $P/bitrate
    sleep 2                                    # let it settle
    g0=$(cat $P/pkt_good); c0=$(cat $P/pkt_crc); s0=$(softirq_us); t0=$(date +%s%N)
    sleep "$DWELL"
    g1=$(cat $P/pkt_good); c1=$(cat $P/pkt_crc); s1=$(softirq_us); t1=$(date +%s%N)

    el=$(( (t1-t0)/1000000 ))                  # ms
    dg=$((g1-g0)); dc=$((c1-c0))
    gps=$(( dg*1000/el )); cps=$(( dc*1000/el ))
    tot=$((dg+dc)); rate="0.000%"
    [ "$tot" -gt 0 ] && rate=$(awk -v c=$dc -v t=$tot 'BEGIN{printf "%.3f%%", 100*c/t}')
    sq=$(awk -v a=$s0 -v b=$s1 -v e=$el 'BEGIN{printf "%.1f", (b-a)/(e*10)}')
    printf "%-8s %-12s %-12s %-10s %-12s\n" "$br" "$gps" "$cps" "$rate" "$sq"
done
