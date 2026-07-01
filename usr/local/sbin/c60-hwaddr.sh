#!/bin/sh
# c60-hwaddr — provision stable, universally-administered Polycom-OUI (00:04:f2)
# addresses for the wired Ethernet (FEC/DSA) and the Bluetooth controller.
#
# The i.MX8MM Trio C60 proto ships with NO factory FEC MAC (OCOTP MAC fuse @0x90
# is blank -> the kernel FEC driver assigns a fresh RANDOM MAC every boot) and
# NO factory BT BD_ADDR (plcm_cfg carries none -> the CYW4354A2.1CX.hcd firmware
# default 43:54:A2:00:1F:AC is kept). Stock provisions these at the factory
# (eth = OCOTP fuse, BT = plcm_cfg via androidboot.btmacaddr); a proto has
# neither.
#
# Address selection, first match wins:
#   1. kernel cmdline token (androidboot.ethmacaddr= / androidboot.btmacaddr=),
#      as emitted by polycom-uboot's preboot -- mirrors the stock mechanism and
#      lets the bootloader own the value.
#   2. else DERIVE deterministically from the immutable i.MX8MM OCOTP SoC
#      unique-id (/sys/devices/soc0/serial_number): Polycom OUI 00:04:f2 + the
#      low 3 bytes of uid_low. Universally administered, unique per die, stable
#      across reboot and reflash, no fuse burning, fully reversible.
# BT differs from the wired MAC by +1 in the last octet.
#
# Usage: c60-hwaddr.sh [net|bt|all|nettest]   (default: all)
set -u

OUI="00:04:f2"
MODE="${1:-all}"

# --- derivation from the SoC unique-id ------------------------------------
uid=$(cat /sys/devices/soc0/serial_number 2>/dev/null | tr 'A-F' 'a-f')
if [ -z "$uid" ]; then
    echo "c60-hwaddr: cannot read SoC unique-id; aborting" >&2
    exit 1
fi
low6=$(printf '%s' "$uid" | tail -c 6)       # low 3 bytes of uid_low
b4=$(printf '%s' "$low6" | cut -c1-2)
b5=$(printf '%s' "$low6" | cut -c3-4)
b6=$(printf '%s' "$low6" | cut -c5-6)
DERIVED_FEC="$OUI:$b4:$b5:$b6"
b6n=$(printf '%02x' $(( (0x$b6 + 1) & 0xff )))
DERIVED_BT="$OUI:$b4:$b5:$b6n"

# --- optional override from the kernel cmdline ----------------------------
cmdline_mac() {   # $1 = token name; echoes a validated lower-case MAC or nothing
    v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n "s/^$1=//p" | head -n1 | tr 'A-F' 'a-f')
    case "$v" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
            case "$v" in 00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) return 1 ;; esac
            printf '%s' "$v"; return 0 ;;
    esac
    return 1
}

FEC=$(cmdline_mac androidboot.ethmacaddr) && FEC_SRC=cmdline || { FEC="$DERIVED_FEC"; FEC_SRC=soc-uid; }
BT=$(cmdline_mac androidboot.btmacaddr)   && BT_SRC=cmdline  || { BT="$DERIVED_BT";  BT_SRC=soc-uid; }

set_dev() {   # $1 = ifname
    [ -e "/sys/class/net/$1" ] || return 0
    if ip link set dev "$1" address "$FEC" 2>/tmp/c60hw.err; then
        echo "c60-hwaddr: $1 -> $FEC"
    else
        echo "c60-hwaddr: WARN $1 set failed: $(cat /tmp/c60hw.err 2>/dev/null)"
    fi
}

do_net() {
    for dev in end0 lan pc; do set_dev "$dev"; done
    if command -v arping >/dev/null 2>&1; then
        arping -U -c2 -w2 -I lan 10.42.42.60 >/dev/null 2>&1 || true
    fi
}

do_bt() {
    command -v btmgmt >/dev/null 2>&1 || { echo "c60-hwaddr: no btmgmt"; return 0; }
    i=0
    while [ ! -e /sys/class/bluetooth/hci0 ] && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i+1)); done
    [ -e /sys/class/bluetooth/hci0 ] || { echo "c60-hwaddr: hci0 not present"; return 0; }
    # The mgmt "Set Public Address" op needs the controller powered down with no
    # other manager racing it, so cycle bluetoothd around it.
    was_active=0
    systemctl is-active --quiet bluetooth 2>/dev/null && was_active=1
    [ "$was_active" = 1 ] && systemctl stop bluetooth
    btmgmt --index 0 power off >/dev/null 2>&1 || true
    if btmgmt --index 0 public-addr "$BT" >/dev/null 2>&1; then
        echo "c60-hwaddr: hci0 -> $BT"
    else
        echo "c60-hwaddr: WARN btmgmt public-addr failed"
    fi
    btmgmt --index 0 power on >/dev/null 2>&1 || true
    [ "$was_active" = 1 ] && systemctl start bluetooth
}

echo "c60-hwaddr: soc_uid=$uid  FEC=$FEC ($FEC_SRC)  BT=$BT ($BT_SRC)  mode=$MODE"
case "$MODE" in
    net) do_net ;;
    bt)  do_bt ;;
    all) do_net; do_bt ;;
    nettest)
        sleep 3
        orig=$(cat /sys/class/net/lan/address)
        ( sleep 75; [ -f /tmp/c60keepmac ] || { ip link set dev lan address "$orig"; echo "c60-hwaddr: nettest reverted lan -> $orig"; } ) >/tmp/c60lantest.log 2>&1 &
        set_dev lan
        command -v arping >/dev/null 2>&1 && arping -U -c3 -w3 -I lan 10.42.42.60 >/dev/null 2>&1
        echo "c60-hwaddr: nettest lan set to $FEC; touch /tmp/c60keepmac within 75s to keep"
        ;;
    *) echo "c60-hwaddr: unknown mode $MODE" >&2; exit 2 ;;
esac
