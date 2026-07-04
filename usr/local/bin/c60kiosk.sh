#!/bin/sh
# C60 cage+cog kiosk launcher. Arg1 = rotation count (0..3), each = 90 deg CW via cage -r.
# All env (XDG_RUNTIME_DIR, WLR_DRM_DEVICES, LIBSEAT_BACKEND, etc.) is provided by systemd-run --setenv.
ROT=""
i=0
while [ "$i" -lt "${1:-0}" ]; do ROT="$ROT -r"; i=$((i+1)); done
exec /usr/bin/cage $ROT -s -- /usr/bin/cog --enable-media=true http://127.0.0.1:8080/
