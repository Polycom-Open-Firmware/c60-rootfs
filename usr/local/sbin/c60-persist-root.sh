#!/bin/sh
# Keep root's home on the userdata partition when it is available.

set -eu

log() { echo "c60-persist-root: $*"; }

DEV=${C60_PERSIST_DEV:-/dev/disk/by-partlabel/userdata}
MNT=${C60_PERSIST_MNT:-/persist}
ROOT=${C60_PERSIST_ROOT:-$MNT/c60-root}

[ -e "$DEV" ] || { log "no userdata partition -- keeping /root on system_a"; exit 0; }

fstype=$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)
if [ "$fstype" != ext4 ]; then
	command -v mkfs.ext4 >/dev/null 2>&1 || { log "userdata is not ext4 and mkfs.ext4 is unavailable"; exit 0; }
	log "initializing userdata as ext4"
	mkfs.ext4 -F -L c60-persist "$DEV" >/dev/null || { log "failed to initialize userdata"; exit 0; }
fi

install -d -m 0755 "$MNT"
if ! mountpoint -q "$MNT"; then
	mount -o rw,noatime "$DEV" "$MNT" || { log "failed to mount userdata"; exit 0; }
fi

install -d -m 0700 "$ROOT"
if [ ! -e "$ROOT/.c60-root-initialized" ]; then
	if [ -d /root ]; then
		cp -a /root/. "$ROOT"/ 2>/dev/null || true
	fi
	touch "$ROOT/.c60-root-initialized"
	chmod 0700 "$ROOT"
	log "initialized $ROOT"
fi

if ! mountpoint -q /root; then
	mount --bind "$ROOT" /root || { log "failed to bind $ROOT to /root"; exit 0; }
fi
chmod 0700 /root
log "/root is persistent on userdata"
