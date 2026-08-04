#!/usr/bin/with-contenv bash
# DNS-based WireGuard endpoint updater.
# Every WG_DNS_INTERVAL seconds, resolve the Endpoint hostname of each
# /config/wg_confs/*.conf and call `wg set ... endpoint` whenever the
# resolved IP differs from the currently cached endpoint.
# This restores connectivity automatically after DDNS rotation without
# restarting the tunnel.

CONF_DIR="/config/wg_confs"
INTERVAL="${WG_DNS_INTERVAL:-60}"

log() {
    echo "[wg-dns-update] $*"
}

resolved_ip() {
    local host="$1" ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$ip" ] || ip=$(getent ahosts "$host" 2>/dev/null | awk '/^[0-9.]+ /{print $1; exit}')
    printf '%s' "$ip"
}

fix_tunnel() {
    local conf iface endpoint host port new_ip pk ep cur changed
    for conf in "${CONF_DIR}"/*.conf; do
        [ -f "$conf" ] || continue
        iface=$(basename "$conf" .conf)
        wg show "$iface" >/dev/null 2>&1 || continue
        endpoint=$(awk '/^[[:space:]]*Endpoint[[:space:]]*=/{print $NF}' "$conf" | tail -n1)
        [ -n "$endpoint" ] || continue
        port=${endpoint##*:}
        host=${endpoint%:*}
        new_ip=$(resolved_ip "$host")
        [ -n "$new_ip" ] || { log "$iface: cannot resolve $host"; continue; }
        changed=0
        while read -r pk ep; do
            [ -n "$ep" ] || continue
            case "$ep" in
                \[*\]:*) cur=${ep%%]:*}; cur=${cur#[} ;;
                *:*)     cur=${ep%:*} ;;
                *)       cur=$ep ;;
            esac
            if [ "$cur" != "$new_ip" ]; then
                log "$iface: endpoint ${cur} -> ${new_ip}:${port} ($host)"
                wg set "$iface" peer "$pk" endpoint "${new_ip}:${port}"
                changed=1
            fi
        done < <(wg show "$iface" endpoints)
        [ "$changed" -eq 1 ] && log "$iface: endpoint refreshed"
    done
}

log "starting (interval=${INTERVAL}s, conf_dir=${CONF_DIR})"
while true; do
    fix_tunnel
    sleep "$INTERVAL"
done
