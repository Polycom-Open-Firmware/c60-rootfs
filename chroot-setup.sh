#!/bin/bash
# Runs INSIDE the qemu-binfmt arm64 chroot. Called by build.sh after the
# second-stage debootstrap finishes. Reads /tmp/package-list.txt (staged
# in by build.sh), installs the configured Debian packages, creates the
# kiosk user, and enables the Wayland/Cage kiosk stack alongside the
# C60-specific boot-control units.
set -e

# APT / dpkg config — drop docs, suggests, recommends.
echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99-no-recommends
echo 'APT::Install-Suggests   "false";' > /etc/apt/apt.conf.d/99-no-suggests
cat > /etc/dpkg/dpkg.cfg.d/01-no-docs <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/locale.alias
path-include /usr/share/locale/en/*
path-include /usr/share/locale/en_US/*
path-include /usr/share/locale/C/*
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update

# Install packages.
PKG_LIST="/tmp/package-list.txt"
[ -f "$PKG_LIST" ] || { echo "missing $PKG_LIST" >&2; exit 1; }
PKGS=$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$PKG_LIST" | tr '\n' ' ')

# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS

# systemd-resolved postinst symlinks /etc/resolv.conf into /run/. Populate
# the stub before the symlink so we have DNS during the build phase too.
mkdir -p /run/systemd/resolve
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /run/systemd/resolve/stub-resolv.conf
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

# Cache + locale + static archive cleanup.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 \
    -not -name 'en*' -not -name 'C.*' -not -name locale.alias \
    -exec rm -rf {} + 2>/dev/null || true
find /usr -name '*.a' -delete 2>/dev/null || true

# kiosk user (uid 1000, no password — login disabled, kiosk service runs via PAM).
if ! id -u kiosk >/dev/null 2>&1; then
    # Ensure groups exist (some not created by our package set).
    for g in render input seat; do
        getent group "$g" >/dev/null || groupadd --system "$g"
    done
    useradd -u 1000 -m -s /bin/bash -G audio,video,render,input kiosk
    passwd -d kiosk
fi

echo 'c60' > /etc/hostname

# Locale: pre-generate en_US.UTF-8.
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Final resolv stub link.
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# u-boot environment editor config for fw_setenv/fw_printenv. The u-boot
# environment lives on eMMC at /dev/mmcblk2 byte offset 0x400000, size
# 4 KiB, stored as a 4-byte CRC32 followed by NUL-separated key=value
# pairs.
cat > /etc/fw_env.config <<'EOF'
# device      offset      env_size
/dev/mmcblk2  0x400000    0x1000
EOF
chmod 0644 /etc/fw_env.config

# Volatile journal — no eMMC writes for logs.
sed -i 's/^#\?Storage=.*/Storage=volatile/' /etc/systemd/journald.conf

# Force a fresh DHCPDISCOVER on every cold boot (avoid 5-min stale-lease
# fallback when the panel moves between LANs).
cat > /etc/systemd/system/wipe-networkd-leases.service <<'UNIT'
[Unit]
Description=Wipe systemd-networkd lease/state cache before networkd starts
DefaultDependencies=no
Before=systemd-networkd.service
ConditionPathExists=/var/lib/systemd/network

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rm -rf /var/lib/systemd/network/*'
RemainAfterExit=no

[Install]
WantedBy=systemd-networkd.service
UNIT
systemctl enable wipe-networkd-leases.service

# Enable core services.
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
chmod 0755 /etc/c60-config/apply-config.sh 2>/dev/null || true
systemctl enable c60-config.service

# Wayland/Cage kiosk (verified v0.1.8 bring-up): seatd provides the seat --
# it opens the DRM/input devices as root (started with `-g video`, so the
# kiosk user in the video group can drive the /run/seatd.sock) -- and
# c60kiosk.service runs cage + cog fullscreen on the DSI panel (WLR_DRM_DEVICES
# =card1 scanout, WLR_RENDER_DRM_DEVICE=renderD128 etnaviv GC520 GL) showing
# ${KIOSK_URL:-file:///etc/kiosk/splash.html}. The ft5x06 touch X+Y flip ships as the
# 99-c60-touch-calib.rules udev calibration matrix (rootfs-only; no DT invert).
# The older TC8-style kiosk.service / kiosk-vt / kiosk-config units were retired
# in favor of this seatd-only, VT-less unit.
systemctl enable seatd.service
systemctl enable c60kiosk.service
systemctl set-default multi-user.target

# C60-specific oneshots (overlaid from rootfs/etc/systemd/system/):
#   c60-mark-slot-success.service: marks A/B slot A successful_boot=1 so
#     u-boot stops decrementing tries_remaining and we don't fall back
#     to stock slot B. Runs after multi-user.target reached.
#   c60-wired-mac.service: provisions a stable, universally-administered
#     Polycom-OUI (00:04:f2) wired MAC on end0/lan/pc. Prefers
#     androidboot.ethmacaddr= from /proc/cmdline (emitted by polycom-uboot's
#     preboot); otherwise derives it per-unit from the immutable i.MX8MM OCOTP
#     SoC unique-id. Runs Before=network-pre.target so DHCP uses it. (The proto
#     has no factory FEC MAC fuse -> the kernel would otherwise pick a fresh
#     random MAC every boot.)
#   c60-bt-addr.service: same idea for the Bluetooth controller public BD_ADDR
#     (applied via btmgmt). Prefers androidboot.btmacaddr= else derived
#     (wired MAC + 1 in the last octet). Without it hci0 keeps the shared
#     CYW4354A2.1CX.hcd firmware default 43:54:A2:00:1F:AC.
systemctl enable c60-mark-slot-success.service
systemctl enable c60-wired-mac.service
systemctl enable c60-bt-addr.service
systemctl disable wpa_supplicant.service 2>/dev/null || true

# SSH host keys.
ssh-keygen -A
mkdir -p /root/.ssh
chmod 700 /root/.ssh
[ -f /root/.ssh/authorized_keys ] || : > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Optional: root password.
if [ -f /tmp/.c60_root_pw ]; then
    echo "root:$(cat /tmp/.c60_root_pw)" | chpasswd
    rm -f /tmp/.c60_root_pw
fi

echo "chroot-setup.sh: DONE"
