#!/bin/sh
# c60-usbnet-gadget.sh — bring up a USB CDC-ECM network gadget on the OTG port
# for headless access. The C60 side is 10.55.0.1/24; a host connected to the
# OTG cable configures 10.55.0.2/24 and reaches the box over that link. This is
# the same physical port used for SDP/fastboot flashing — the gadget only comes
# up once Linux owns the controller, so it does not interfere with recovery.
set -u

GADGET=/sys/kernel/config/usb_gadget/c60
log() { echo "c60-usbnet: $*" > /dev/console 2>/dev/null; echo "c60-usbnet: $*"; }

modprobe libcomposite 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null || true

UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
if [ -z "$UDC" ]; then
    log "no UDC available (OTG not in peripheral mode?) — skipping"
    exit 0
fi

if [ ! -d "$GADGET" ]; then
    mkdir -p "$GADGET" || { log "configfs gadget mkdir failed"; exit 0; }
    echo 0x1d6b > "$GADGET/idVendor"     # Linux Foundation
    echo 0x0104 > "$GADGET/idProduct"    # Multifunction Composite Gadget
    echo 0x0100 > "$GADGET/bcdDevice"
    echo 0x0200 > "$GADGET/bcdUSB"
    mkdir -p "$GADGET/strings/0x409"
    echo "kepler-proto1"       > "$GADGET/strings/0x409/serialnumber"
    echo "Poly"                > "$GADGET/strings/0x409/manufacturer"
    echo "C60 headless usbnet" > "$GADGET/strings/0x409/product"
    mkdir -p "$GADGET/configs/c.1/strings/0x409"
    echo "ecm" > "$GADGET/configs/c.1/strings/0x409/configuration"
    echo 250   > "$GADGET/configs/c.1/MaxPower"
    mkdir -p "$GADGET/functions/ecm.usb0"
    echo "02:c6:00:00:00:01" > "$GADGET/functions/ecm.usb0/dev_addr"   # C60 side
    echo "02:c6:00:00:00:02" > "$GADGET/functions/ecm.usb0/host_addr"  # cable host side
    ln -s "$GADGET/functions/ecm.usb0" "$GADGET/configs/c.1/" 2>/dev/null || true
fi

if [ -z "$(cat "$GADGET/UDC" 2>/dev/null)" ]; then
    echo "$UDC" > "$GADGET/UDC" 2>/dev/null || { log "bind to $UDC failed"; exit 0; }
fi

for _ in $(seq 1 20); do
    ip link show usb0 >/dev/null 2>&1 && break
    sleep 0.5
done
ip addr add 10.55.0.1/24 dev usb0 2>/dev/null || true
ip link set usb0 up 2>/dev/null || true
log "gadget bound to $UDC; usb0 = 10.55.0.1/24 (host side: 10.55.0.2)"
exit 0
