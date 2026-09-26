#!/bin/bash
# Put xpi_gamecon under DKMS, so a kernel upgrade rebuilds it instead of leaving
# a handheld with no buttons, no gauge, no fan and no clean way to power off.
# Runs ON the handheld, once per card:
#
#     sudo ~/piboy-src/dkms-setup.sh
#
# After this, editing ~/piboy-src/xpi_gamecon.c is not enough - DKMS builds from
# its own copy under /usr/src. Re-run this to publish a source change; it is
# idempotent and will remove and re-add the same version.
#
# What DKMS does and does not buy: it guarantees a module is BUILT and installed
# for each new kernel, before you reboot into it. It does not check that the
# module works - so this reloads from the installed path afterwards and proves
# the device comes back. test-reload.sh is the heavier harness, for stressing a
# candidate build before it is published here.
set -u

SRC=$(cd "$(dirname "$0")" && pwd)
NAME=xpi_gamecon
VER=1.0
USRC=/usr/src/$NAME-$VER
# Must match test-reload.sh - both encode "how to safely take the driver away".
CONSUMERS="piboy-fand piboy-escaped piboy-vold piboy-display piboy-batd"
LOG=/var/log/xpi-dkms.log

exec > >(tee -a "$LOG") 2>&1
fail() { echo "FAILED: $*" >&2; exit 1; }

echo "=== $(date -Is)  $(uname -r) ==="
[ "$(id -u)" = 0 ] || fail "must be root"
[ -f "$SRC/$NAME.c" ] || fail "no $SRC/$NAME.c"
command -v dkms >/dev/null || fail "dkms not installed (apt-get install dkms)"

# Drop any previous registration of this exact version, so this is re-runnable.
if dkms status -m $NAME -v $VER 2>/dev/null | grep -q .; then
    echo "--- removing previous DKMS registration ---"
    dkms remove -m $NAME -v $VER --all || true
fi

echo "--- staging source in $USRC ---"
mkdir -p "$USRC"
install -m 0644 "$SRC/$NAME.c" "$USRC/$NAME.c"

# The vendor's own Makefile had KVERSION := 'uname -r' - single quotes, so it
# expands to the literal string "uname -r". It never bit them because DKMS
# always passes KVERSION= on the command line, which overrides the assignment.
# It only breaks when someone runs `make all` by hand, so fix it here.
cat > "$USRC/Makefile" <<'EOF'
obj-m := xpi_gamecon.o

KVERSION ?= $(shell uname -r)

all:
	$(MAKE) -C /lib/modules/$(KVERSION)/build M=$(CURDIR) modules

clean:
	$(MAKE) -C /lib/modules/$(KVERSION)/build M=$(CURDIR) clean
EOF

# Experimental Pi's own dkms.conf, kept as-is apart from the comment. The
# load-bearing line is AUTOINSTALL - that is what makes the kernel package's
# postinst rebuild this before you boot the new kernel. $kernelver is DKMS's
# variable, expanded by DKMS, not by this shell - hence the quoted heredoc.
cat > "$USRC/dkms.conf" <<'EOF'
PACKAGE_NAME="xpi_gamecon"
PACKAGE_VERSION="1.0"
CLEAN="make clean"
MAKE[0]="make all KVERSION=$kernelver"
BUILT_MODULE_NAME[0]="$PACKAGE_NAME"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
EOF

echo "--- dkms add / build / install ---"
dkms add     -m $NAME -v $VER || fail "dkms add"
dkms build   -m $NAME -v $VER || fail "dkms build"
dkms install -m $NAME -v $VER --force || fail "dkms install"

# A hand-installed copy in extra/ would sit in the same modules tree as the DKMS
# one in updates/dkms/ and silently compete for the name. Retire it by changing
# the suffix - depmod only indexes files ending in .ko, so this takes it out of
# the running without throwing it away.
OLD=/lib/modules/$(uname -r)/extra/$NAME.ko
if [ -f "$OLD" ]; then
    mv "$OLD" "$OLD.pre-dkms"
    echo "retired hand-installed $OLD -> $OLD.pre-dkms"
fi
depmod -a

echo "--- verify the file ---"
dkms status -m $NAME
echo "resolves to: $(modinfo -n $NAME)"
case "$(modinfo -n $NAME)" in
    *dkms*) ;;
    *) fail "still resolving to $(modinfo -n $NAME) - the DKMS copy is not winning" ;;
esac

# Reloading via modprobe is the point: insmod would test the file just built,
# not the path a boot actually resolves.
echo "--- reload from the installed path ---"
systemctl stop emulationstation 2>/dev/null || true
pkill -x emulationstation 2>/dev/null && sleep 2
systemctl stop $CONSUMERS 2>/dev/null
rmmod $NAME 2>/dev/null
if ! modprobe $NAME; then
    systemctl start $CONSUMERS 2>/dev/null
    systemctl start emulationstation 2>/dev/null || true
    fail "modprobe failed - 'dkms remove -m $NAME -v $VER --all' restores the previous module"
fi
sleep 3
systemctl start $CONSUMERS 2>/dev/null
systemctl start emulationstation 2>/dev/null || true

pad=$(grep -c 'PiBoy DMG Controller' /proc/bus/input/devices)
echo "pad=$pad fw=$(cat /sys/kernel/xpi_gamecon/version) batt=$(cat /sys/class/power_supply/xpi-battery/capacity)%"
echo "backlight: $(ls /sys/class/backlight/ 2>/dev/null | tr '\n' ' ')"
for u in $CONSUMERS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u")"; done; echo
[ "$pad" -ge 1 ] || fail "pad missing after reload"
echo "RESULT: DKMS owns the module, it loads, and kernel upgrades will rebuild it"
