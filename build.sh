#!/usr/bin/env bash
# C60 slim Debian bookworm arm64 rootfs builder.
#
# Modeled directly on tc8-firmware-build/rootfs/build.sh. The output tarball
# is consumed by images/rootfs.sh which packs it into rootfs.img.
#
# Produces:
#   out/rootfs.tar.gz
#
# Usage:
#   sudo ./build.sh             # full build
#   sudo ./build.sh --keep      # don't remove work/rootfs after tarballing
#
# Requires (host): debootstrap, qemu-user-static, binfmt-support active,
#                  rsync, tar, gzip.
#
# Re-runs idempotently: if work/rootfs already exists with /etc/debian_version,
# skips debootstrap and re-applies the chroot-setup + etc/ overlay.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${ROOT_DIR}/work"
ROOTFS="${WORK}/rootfs"
OUT="${ROOT_DIR}/out"
SUITE="bookworm"
ARCH="arm64"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "build.sh must run as root (chroot needs it)" >&2
    exit 1
fi

# Host-side dep check.
need() { command -v "$1" >/dev/null || { echo "missing host tool: $1" >&2; exit 1; }; }
need debootstrap
need rsync
need tar
need gzip
[ -x /usr/bin/qemu-aarch64-static ] || {
    echo "missing /usr/bin/qemu-aarch64-static (apt install qemu-user-static)" >&2
    exit 1
}

mkdir -p "$WORK" "$OUT"

# 1. debootstrap.
if [ ! -f "$ROOTFS/etc/debian_version" ]; then
    echo "==> debootstrap stage 1 ($SUITE/$ARCH)"
    debootstrap --arch="$ARCH" --variant=minbase --foreign \
        "$SUITE" "$ROOTFS" "$MIRROR"

    install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"

    echo "==> debootstrap stage 2 (in chroot)"
    chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
else
    echo "==> rootfs exists, skipping debootstrap"
    install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
fi

# 2. Stage package list + chroot setup script.
echo "==> staging package-list.txt and chroot-setup.sh"
install -m 0644 "$ROOT_DIR/package-list.txt" "$ROOTFS/tmp/package-list.txt"
install -m 0755 "$ROOT_DIR/chroot-setup.sh"  "$ROOTFS/tmp/chroot-setup.sh"

# 3a. SSH pubkey injection (optional).
# Source order: C60_SSH_PUBKEY env wins, else ./authorized_keys at this
# rootfs dir if it exists (gitignored — drop your pubkey there).
SSH_PUBKEY_SRC="${C60_SSH_PUBKEY:-}"
[ -z "$SSH_PUBKEY_SRC" ] && [ -f "$ROOT_DIR/authorized_keys" ] && SSH_PUBKEY_SRC="$ROOT_DIR/authorized_keys"
if [ -n "$SSH_PUBKEY_SRC" ]; then
    if [ -f "$SSH_PUBKEY_SRC" ]; then
        echo "==> baking SSH pubkey from $SSH_PUBKEY_SRC"
        install -d -m 0700 "$ROOTFS/root/.ssh"
        cat "$SSH_PUBKEY_SRC" >> "$ROOTFS/root/.ssh/authorized_keys"
        chmod 0600 "$ROOTFS/root/.ssh/authorized_keys"
    else
        echo "warning: pubkey source $SSH_PUBKEY_SRC not found, skipping" >&2
    fi
fi

# 3b. Root password — works on tty + ssh.
# Default is "root"; override with C60_ROOT_PASSWORD env or ./root_password
# file (gitignored). sshd accepts both pubkey + password — pubkey wins when
# both are present. SECURITY: change before plugging the panel into anything
# you care about.
ROOT_PW="root"
if [ -n "${C60_ROOT_PASSWORD:-}" ]; then
    ROOT_PW="$C60_ROOT_PASSWORD"
elif [ -f "$ROOT_DIR/root_password" ]; then
    ROOT_PW="$(head -n1 "$ROOT_DIR/root_password")"
fi
echo "==> baking root password (tty + ssh)"
install -d -m 1777 "$ROOTFS/tmp"
printf '%s' "$ROOT_PW" > "$ROOTFS/tmp/.c60_root_pw"
chmod 0600 "$ROOTFS/tmp/.c60_root_pw"
install -d -m 0755 "$ROOTFS/etc/ssh/sshd_config.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/99-c60-rootpw.conf" <<EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF

# 4. etc/ overlay (network config, fstab, etc).
echo "==> applying etc/ overlay"
rsync -a "$ROOT_DIR/etc/" "$ROOTFS/etc/"

# 4b. WiFi firmware (BCM4356 + companion blobs) into /lib/firmware/brcm/.
# Mirrors what kernel-side CONFIG_EXTRA_FIRMWARE already embeds — having
# them in the rootfs too means udev paths + post-boot module reloads work,
# and the board-specific brcmfmac4356-pcie.poly,kepler-proto1.txt (staged below)
# is the name the driver actually requests. NXP SDMA blob also staged here
# so audio doesn't dmesg-warn "Direct firmware load ... -2".
FW_SRC="$ROOT_DIR/../firmware-blobs"
if [[ -d "$FW_SRC" ]]; then
    echo "==> staging WiFi + SDMA firmware blobs into /lib/firmware"
    install -d -m 0755 "$ROOTFS/lib/firmware/brcm" "$ROOTFS/lib/firmware/imx/sdma"
    for blob in brcmfmac4356-pcie.bin brcmfmac4356-pcie.clm_blob brcmfmac4356-pcie.txt; do
        [[ -f "$FW_SRC/brcm/$blob" ]] && install -m 0644 "$FW_SRC/brcm/$blob" "$ROOTFS/lib/firmware/brcm/$blob"
    done
    # brcmfmac derives the NVRAM name from the root compatible ("poly,kepler-proto1")
    # and requests brcmfmac4356-pcie.poly,kepler-proto1.txt first; without that exact
    # name the chip comes up without board cal and an iw scan hard-hangs the SoC.
    # Same content as the generic .txt, staged under the board-specific name.
    [[ -f "$FW_SRC/brcm/brcmfmac4356-pcie.txt" ]] && install -m 0644 "$FW_SRC/brcm/brcmfmac4356-pcie.txt" "$ROOTFS/lib/firmware/brcm/brcmfmac4356-pcie.poly,kepler-proto1.txt"
    [[ -f "$FW_SRC/sdma-imx7d.bin" ]] && install -m 0644 "$FW_SRC/sdma-imx7d.bin" "$ROOTFS/lib/firmware/imx/sdma/sdma-imx7d.bin"
    # Bluetooth patchram for the BCM4356 / CYW4354A2 combo. Unlike the WiFi
    # blobs this is not embedded via CONFIG_EXTRA_FIRMWARE, so hci_bcm loads it
    # from the rootfs at runtime. The driver derives the request name from the
    # chip's LMP subver and asks for brcm/<name>.hcd (BCM4356A2.hcd for subver
    # 0x230f, BCM4354.hcd for 0x610c); the recovered patch is staged under each
    # candidate name so the load matches whichever the silicon reports.
    for hcd in BCM4356A2.hcd BCM4354.hcd BCM4354A2.hcd; do
        [[ -f "$FW_SRC/brcm/$hcd" ]] && install -m 0644 "$FW_SRC/brcm/$hcd" "$ROOTFS/lib/firmware/brcm/$hcd"
    done
fi

# 5. Version stamp.
cat > "$ROOTFS/etc/c60-version" <<VER
# c60-firmware version metadata. Sourceable as shell.
C60_FW_VERSION="${C60_FW_VERSION:-standalone}"
C60_BUILD_DATE="${C60_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
C60_BUILD_HOST="${C60_BUILD_HOST:-$(hostname)}"
VER
chmod 0644 "$ROOTFS/etc/c60-version"

# 6. Bind /proc /sys /dev for chroot-setup's apt + ssh-keygen.
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys  "$ROOTFS/sys"
mount --bind /dev  "$ROOTFS/dev"
mount -t devpts devpts "$ROOTFS/dev/pts" || true
trap 'umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true; \
      umount -lf "$ROOTFS/dev"     2>/dev/null || true; \
      umount -lf "$ROOTFS/sys"     2>/dev/null || true; \
      umount -lf "$ROOTFS/proc"    2>/dev/null || true' EXIT

echo "==> running chroot-setup.sh"
chroot "$ROOTFS" /tmp/chroot-setup.sh

rm -f "$ROOTFS/tmp/chroot-setup.sh" "$ROOTFS/tmp/package-list.txt"
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
umount -lf "$ROOTFS/dev"     2>/dev/null || true
umount -lf "$ROOTFS/sys"     2>/dev/null || true
umount -lf "$ROOTFS/proc"    2>/dev/null || true
trap - EXIT

# 7. Tar.
echo "==> tarring rootfs -> $OUT/rootfs.tar.gz"
tar --numeric-owner --one-file-system \
    --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
    -C "$ROOTFS" -czf "$OUT/rootfs.tar.gz" .

if [ "$KEEP" -eq 0 ]; then
    echo "==> removing work/rootfs (use --keep to retain)"
    # Non-fatal: in unprivileged LXCs lazy /proc umount can leave residue
    # we can't unlink. Tarball is already built.
    rm -rf "$ROOTFS" 2>/dev/null || echo "warning: leftover work/rootfs files (harmless in unpriv LXC)" >&2
fi

echo "==> done"
ls -lh "$OUT"/rootfs.tar.gz
