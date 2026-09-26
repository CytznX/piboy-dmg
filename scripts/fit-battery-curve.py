#!/usr/bin/env python3
"""Fit R_PACK_MOHM, OCV_TABLE and CAPACITY_MAH from a piboy-batd --log capture.

Feed it one full discharge, logged from a full charge down to the automatic
shutdown:

    piboy-batd --log /var/log/piboy-batt.csv

The trick is that we never see a resting pack, so OCV cannot be measured
directly. But a handheld's load swings hard on its own - idle in the menu is
~450 mA, a game is well over a watt more - and within a narrow slice of charge
the SoC barely moves while the current does. So inside each slice:

    V = OCV + I * R          (I signed, negative discharging, so V < OCV)

is a straight line through the samples. Least-squares per slice gives the
intercept, which is the OCV at that charge, and the slope, which is the pack
resistance. No instrumentation, no rest periods, no reference load - just an
evening of normal play.

Capacity comes free: integrate the current over the whole log.

The result is written as JSON for piboy-batd to load, not pasted into its
source - so the daemon you then check with --replay is running the same numbers
it will run for real.

Usage:  sudo fit-battery-curve.py CAPTURE.CSV [--bin PERCENT] [--out JSON]
"""
import argparse, csv, json, os, statistics, sys

MIN_POINTS = 30     # per slice
MIN_SPREAD = 250.0  # mA of load variation needed before a slice can be fitted
CAL = '/var/lib/piboy/battery-cal.json'


def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                rows.append((float(r['mono']), float(r['mv']), float(r['ma']),
                             r['status']))
            except (KeyError, ValueError):
                continue

    # The capture ends when the pack empties and the daemon powers the device
    # off - so the documented procedure has the user charge up and boot again
    # with --log still set, and piboy-batd appends to the same file with its
    # monotonic clock restarted near zero. Integrating straight through that
    # step subtracts hours of charge and corrupts both the capacity and the SoC
    # axis, silently. There is no honest way to integrate across an off period
    # anyway - the board draws while it is down - so split on the step and keep
    # the longest run, which is the discharge that was actually asked for.
    sessions, cur = [], [rows[0]] if rows else []
    for prev, row in zip(rows, rows[1:]):
        if row[0] < prev[0]:            # monotonic went backwards: a reboot
            sessions.append(cur)
            cur = []
        cur.append(row)
    if cur:
        sessions.append(cur)
    if len(sessions) > 1:
        best = max(sessions, key=len)
        print(f'{path}: {len(sessions)} sessions (the daemon kept logging across '
              f'a reboot).\nUsing the longest: {len(best)} of {len(rows)} rows, '
              f'{(best[-1][0] - best[0][0]) / 3600:.2f} h.\n', file=sys.stderr)
        rows = best

    if len(rows) < 100:
        sys.exit(f'{path}: only {len(rows)} usable rows')
    return rows


def integrate(rows):
    """Cumulative mAh drawn at each sample, and the total."""
    cum, total = [0.0], 0.0
    for a, b in zip(rows, rows[1:]):
        total += -(a[2] + b[2]) / 2.0 * (b[0] - a[0]) / 3600.0
        cum.append(total)
    return cum, total


def isotonic(points):
    """Weighted pool-adjacent-violators: the least change to the fitted OCVs that
    makes them non-decreasing with SoC.

    Per-slice fits are independent, so noise alone puts a few of them out of
    order - and near empty the curve is steep enough that charge moves inside a
    slice, which breaks the constant-SoC assumption and tilts those fits. A table
    that dips is not invertible, so the daemon rejects it outright. Pooling the
    offending runs into their weighted mean is the standard repair, and it leaves
    every already-ordered slice untouched.

    Takes (soc, ocv, weight) sorted by soc; returns ((soc, ocv), pooled).
    """
    blocks = []                      # [sum of w*y, sum of w, how many points]
    for _, ocv, w in points:
        blocks.append([ocv * w, w, 1])
        while len(blocks) >= 2 and \
                blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]:
            b, a = blocks.pop(), blocks.pop()
            blocks.append([a[0] + b[0], a[1] + b[1], a[2] + b[2]])

    out, i, pooled = [], 0, 0
    for sy, sw, count in blocks:
        for _ in range(count):
            out.append((points[i][0], sy / sw))
            i += 1
        if count > 1:
            pooled += count
    return out, pooled


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('capture')
    ap.add_argument('--bin', type=float, default=2.5,
                    help='slice width in %% SoC (default 2.5)')
    ap.add_argument('--out', default=CAL, help=f'where to write it (default {CAL})')
    a = ap.parse_args()

    rows = load(a.capture)
    if rows[0][3] != 'Full':
        print(f"warning: log starts at status={rows[0][3]!r}, not 'Full'. "
              f"Capacity and the SoC axis will both be short.\n", file=sys.stderr)

    cum, total = integrate(rows)
    print(f'{len(rows)} samples over {(rows[-1][0] - rows[0][0]) / 3600:.2f} h')
    print(f'measured usable capacity: {total:.0f} mAh\n')

    # Slice by SoC and fit V against I inside each. Discharge samples only:
    # a charging pack sits on a different OCV curve and would bias the line.
    slices = {}
    for (t, mv, ma, st), drawn in zip(rows, cum):
        if ma >= 0:
            continue
        soc = min(100.0, max(0.0, (1.0 - drawn / total) * 100.0))
        slices.setdefault(int(soc / a.bin), []).append((ma, mv))

    print(f'{"SoC%":>6} {"n":>5} {"Ispread":>8} {"OCV mV":>7} {"R mohm":>7}')
    table, resistances = [], []
    for key in sorted(slices, reverse=True):
        pts = slices[key]
        soc = (key + 0.5) * a.bin
        currents = [p[0] for p in pts]
        spread = max(currents) - min(currents)
        if len(pts) < MIN_POINTS or spread < MIN_SPREAD:
            print(f'{soc:6.1f} {len(pts):5d} {spread:8.0f}       -       -   '
                  f'(too little load variation)')
            continue
        slope, ocv = statistics.linear_regression(currents, [p[1] for p in pts])
        r_mohm = slope * 1000.0     # mV/mA is ohms
        print(f'{soc:6.1f} {len(pts):5d} {spread:8.0f} {ocv:7.0f} {r_mohm:7.1f}')
        if 10.0 < r_mohm < 500.0:   # implausible values are a bad slice, not a pack
            resistances.append(r_mohm)
        table.append((soc, ocv, len(pts)))

    # Two points minimum: one is not a curve, and a single-point table would be
    # accepted by the daemon's monotonicity check (nothing to compare) and then
    # clamp every reading to that one SoC.
    if len(table) < 2:
        sys.exit(f'\nonly {len(table)} slice(s) had enough load variation to fit. '
                 'Capture a session that mixes menu idling with actual play.')

    table.sort()
    curve, pooled = isotonic(table)
    if pooled:
        print(f'\n{pooled} of {len(curve)} slices were out of order and have been '
              f'pooled to keep the curve invertible')

    if not resistances:
        sys.exit('\nno slice produced a plausible pack resistance, so there is no '
                 'calibration to write.\nCapture a session that mixes menu idling '
                 'with actual play.')
    # The median shrugs off the steep-curve slices near empty, where SoC moves
    # inside a slice and the fitted slope tilts.
    r = statistics.median(resistances)
    print(f'\nr_pack_mohm  {r:.0f}   (median of {len(resistances)} slices, '
          f'spread {min(resistances, default=0):.0f}-{max(resistances, default=0):.0f})')
    print(f'capacity_mah {total:.0f}')
    print(f'ocv_table    {len(curve)} points, '
          f'{curve[0][1]:.0f}-{curve[-1][1]:.0f} mV over '
          f'{curve[0][0]:.1f}-{curve[-1][0]:.1f}%')

    cal = {'capacity_mah': round(total, 1),
           'r_pack_mohm': round(r, 1),
           'ocv_table': [[round(soc, 2), round(ocv, 1)] for soc, ocv in curve],
           'source': os.path.abspath(a.capture)}
    # Rename-over-fsync, the same way piboy-batd persists its state file. A
    # half-written battery-cal.json is not a cosmetic problem: the daemon treats
    # malformed JSON as a stop-and-shout condition, so under Restart=always it
    # burns its start limit in under a minute and stays down - leaving the
    # device with no fuel gauge AND no empty-pack shutdown. This fit is run on a
    # handheld that has just powered itself off flat, which is exactly when a
    # truncating write is most likely to be interrupted.
    try:
        os.makedirs(os.path.dirname(a.out) or '.', exist_ok=True)
        tmp = f'{a.out}.tmp'
        with open(tmp, 'w') as f:
            json.dump(cal, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, a.out)
    except OSError as e:
        sys.exit(f'\ncould not write {a.out}: {e}\n'
                 f'run with sudo, or pass --out somewhere writable')

    print(f'\nwrote {a.out}')
    print(f'check it before trusting it:  piboy-batd --replay {a.capture}')
    print('then restart piboy-batd to adopt it')


if __name__ == '__main__':
    main()
