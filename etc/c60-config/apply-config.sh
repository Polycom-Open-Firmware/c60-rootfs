#!/bin/sh
# Apply a provisioning-wizard config blob from the stock Android `misc` partition.

log() { echo "c60-config: $*"; }

DEV=${C60_CFG_DEV:-/dev/disk/by-partlabel/misc}
[ -e "$DEV" ] || { log "no misc partition -- skipping"; exit 0; }

tmp_h=$(mktemp) || exit 0
tmp_p=$(mktemp) || exit 0
trap 'rm -f "$tmp_h" "$tmp_p"' EXIT

dd if="$DEV" of="$tmp_h" bs=64 count=1 2>/dev/null

magic=$(dd if="$tmp_h" bs=1 count=8 2>/dev/null)
[ "$magic" = "TC8CFGv1" ] || { log "no config blob (magic mismatch) -- skipping"; exit 0; }

set -- $(od -An -tu1 -j8 -N4 "$tmp_h")
len=$(( ${1:-0} + ${2:-0} * 256 + ${3:-0} * 65536 + ${4:-0} * 16777216 ))
if [ "$len" -le 0 ] || [ "$len" -gt 1048576 ]; then
	log "implausible payload length ($len) -- skipping"
	exit 0
fi

want=$(od -An -tx1 -j12 -N32 "$tmp_h" | tr -d ' \n')
dd if="$DEV" of="$tmp_p" bs=1 skip=64 count="$len" 2>/dev/null
got=$(sha256sum "$tmp_p" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
	log "sha256 mismatch -- refusing to apply (want $want got $got)"
	exit 0
fi
log "valid config blob: $len bytes"

KIOSK=${C60_CFG_KIOSK:-/etc/default/c60-kiosk}
WIFI_IFACE=${C60_CFG_WIFI_IFACE:-}
if [ -z "$WIFI_IFACE" ]; then
	for p in /sys/class/net/wl* /sys/class/net/wlan*; do
		[ -e "$p" ] || continue
		WIFI_IFACE=$(basename "$p")
		break
	done
fi
WPA_CONF=${C60_CFG_WPA_CONF:-/etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE:-wlp1s0}.conf}
WLAN_NET=${C60_CFG_WLAN_NET:-/etc/systemd/network/25-wifi.network}

set_kv() {
	_f=$1; _k=$2; _v=$3
	install -d -m 0755 "$(dirname "$_f")"
	if [ -f "$_f" ] && grep -q "^${_k}=" "$_f"; then
		awk -v k="$_k" -v v="$_v" '
			$0 ~ "^" k "=" { print k "=" v; seen=1; next }
			{ print }
			END { if (!seen) print k "=" v }
		' "$_f" > "$_f.tmp" && mv "$_f.tmp" "$_f"
	else
		printf '%s=%s\n' "$_k" "$_v" >> "$_f"
	fi
}

wifi_escape() {
	printf '%s' "$1" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "%s", $0 }'
}

apply_wifi() {
	[ -n "${wifi_ssid+x}" ] || return 0
	[ -n "$wifi_ssid" ] || { log "empty WIFI_SSID -- skipping wifi config"; return 0; }
	[ -n "$WIFI_IFACE" ] || { log "no wifi interface -- skipping wifi config"; return 0; }

	install -d -m 0755 "$(dirname "$WPA_CONF")" "$(dirname "$WLAN_NET")"
	{
		printf 'ctrl_interface=/run/wpa_supplicant\n'
		printf 'update_config=0\n'
		[ -n "${wifi_country:-}" ] && printf 'country=%s\n' "$(wifi_escape "$wifi_country")"
		printf '\nnetwork={\n'
		printf '\tssid="%s"\n' "$(wifi_escape "$wifi_ssid")"
		printf '\tscan_ssid=1\n'
		if [ -n "${wifi_password+x}" ] && [ -n "$wifi_password" ]; then
			printf '\tpsk="%s"\n' "$(wifi_escape "$wifi_password")"
		else
			printf '\tkey_mgmt=NONE\n'
		fi
		printf '}\n'
	} > "$WPA_CONF"
	chmod 0600 "$WPA_CONF"

	cat > "$WLAN_NET" <<'EOF'
[Match]
Name=wl* wlan*

[Network]
DHCP=yes
EOF

	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now wpa_supplicant.service >/dev/null 2>&1 || true
		systemctl enable "wpa_supplicant@${WIFI_IFACE}.service" >/dev/null 2>&1 || true
		systemctl restart "wpa_supplicant@${WIFI_IFACE}.service" systemd-networkd.service >/dev/null 2>&1 || true
	fi
	log "configured wifi on $WIFI_IFACE"
}

while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in ''|\#*) continue ;; esac
	key=${line%%=*}; val=${line#*=}
	case "$key" in
		KIOSK_URL|KIOSK_URL_FALLBACK|COG_OPTS)
			set_kv "$KIOSK" "$key" "$val"; log "set $key" ;;
		DEVICE_NAME)
			printf '%s\n' "$val" > /etc/hostname
			hostname "$val" 2>/dev/null || true
			log "set hostname" ;;
		ROOT_PASSWORD)
			printf 'root:%s\n' "$val" | chpasswd 2>/dev/null && log "set root password" ;;
		KIOSK_PASSWORD)
			printf 'kiosk:%s\n' "$val" | chpasswd 2>/dev/null && log "set kiosk password" ;;
		SSH_AUTHKEY)
			install -d -m 0700 /root/.ssh
			grep -qxF "$val" /root/.ssh/authorized_keys 2>/dev/null \
				|| printf '%s\n' "$val" >> /root/.ssh/authorized_keys
			chmod 0600 /root/.ssh/authorized_keys; log "added ssh authorized key" ;;
		TIMEZONE)
			if [ -e "/usr/share/zoneinfo/$val" ]; then
				ln -sf "/usr/share/zoneinfo/$val" /etc/localtime
				printf '%s\n' "$val" > /etc/timezone; log "set timezone=$val"
			else log "unknown timezone '$val'"; fi ;;
		NTP_SERVER)
			set_kv /etc/systemd/timesyncd.conf NTP "$val"; log "set NTP server" ;;
		WIFI_SSID) wifi_ssid=$val ;;
		WIFI_PASSWORD) wifi_password=$val ;;
		WIFI_COUNTRY) wifi_country=$val ;;
		*) log "ignoring unknown key '$key'" ;;
	esac
done < "$tmp_p"

apply_wifi
log "config applied"
exit 0
