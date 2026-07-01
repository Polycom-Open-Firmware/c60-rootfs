#!/bin/sh
# c60-fec-mac-from-cmdline.sh
#
# Mainline FEC driver picks a random MAC every boot because it doesn't
# parse the androidboot.ethmacaddr token in /proc/cmdline that Polycom's
# u-boot still appends. Result: the panel shows up with a different MAC
# (and probably DHCP IP) on every reboot.
#
# This script:
#   1. Greps the MAC out of /proc/cmdline.
#   2. Validates the format (XX:XX:XX:XX:XX:XX, hex, six octets).
#   3. Applies it to the DSA user port `lan` (and underlying conduit
#      `end0` so the FEC carrier itself isn't random — some L2 setups
#      care).
#
# Runs Before=network-pre.target so the MAC is in place before
# systemd-networkd-wait-online does anything useful.
#
# Idempotent: if the interface already has the desired MAC, no-op.
# Quiet-fail: if cmdline lacks the token, log a warning and exit 0 — we
# don't want a missing MAC to keep the box off the network entirely.

set -u

CMDLINE=$(cat /proc/cmdline 2>/dev/null || true)

# Extract MAC. androidboot.ethmacaddr=AA:BB:CC:DD:EE:FF
MAC=$(printf '%s\n' "$CMDLINE" \
    | tr ' ' '\n' \
    | sed -n 's/^androidboot\.ethmacaddr=//p' \
    | head -n1)

if [ -z "$MAC" ]; then
    echo "c60-fec-mac-from-cmdline: androidboot.ethmacaddr token absent from /proc/cmdline; leaving FEC MAC alone" >&2
    exit 0
fi

# Validate: six colon-separated hex octets.
case "$MAC" in
    [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])
        ;;
    *)
        echo "c60-fec-mac-from-cmdline: malformed androidboot.ethmacaddr '$MAC'; leaving FEC MAC alone" >&2
        exit 0
        ;;
esac

# Reject the all-zero and all-FF cases (almost certainly bogus).
case "$MAC" in
    00:00:00:00:00:00|ff:ff:ff:ff:ff:ff|FF:FF:FF:FF:FF:FF)
        echo "c60-fec-mac-from-cmdline: refusing to apply degenerate MAC '$MAC'" >&2
        exit 0
        ;;
esac

apply_mac() {
    iface="$1"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        return 1
    fi

    cur=$(ip -o link show "$iface" 2>/dev/null \
        | sed -n 's/.*link\/ether \([0-9a-f:]*\).*/\1/p' \
        | head -n1)
    want=$(printf '%s' "$MAC" | tr 'A-F' 'a-f')

    if [ "$cur" = "$want" ]; then
        echo "c60-fec-mac-from-cmdline: $iface already has MAC $want (no-op)"
        return 0
    fi

    # The interface must be DOWN to change the MAC.
    ip link set "$iface" down 2>/dev/null || true
    if ip link set "$iface" address "$MAC"; then
        echo "c60-fec-mac-from-cmdline: set $iface MAC to $MAC (was $cur)"
        return 0
    else
        echo "c60-fec-mac-from-cmdline: failed to set $iface MAC to $MAC" >&2
        return 1
    fi
}

# Apply to the FEC conduit first (end0), then the DSA user port (lan).
# Order matters: in a DSA setup, the user-port MAC tracks the conduit
# MAC at registration unless explicitly overridden. We set both so the
# carrier-side address is also deterministic.
apply_mac end0 || true
apply_mac lan  || true

exit 0
