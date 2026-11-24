#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Remove WireGuard interfaces that a previous run of THIS container left on the
# host. network_mode: host means wg0 is a host interface: if the container is
# stopped/restarted and the down hook does not run (crash, OOM, `docker kill`,
# a conf that failed to parse), an orphan wg0 stays up with the OLD private key
# and OLD ListenPort. The next container then thinks "tunnel already active"
# and never applies the conf you just edited -> "restart docker, nothing works".
#
# Set WG_CLEAN_ORPHANS=0 in .env if another WireGuard stack on the same host
# must not be touched.

if [ "${WG_CLEAN_ORPHANS:-1}" = "0" ]; then
    echo "[clean-orphan] disabled (WG_CLEAN_ORPHANS=0)"
    exit 0
fi

# `ip -o link show type wireguard` prints "33: wg0: <POINTOPOINT,...>"
for iface in $(ip -o link show type wireguard 2>/dev/null | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p'); do
    conf="/config/wg_confs/${iface}.conf"
    echo "[clean-orphan] removing interface ${iface}"
    if [ -f "$conf" ]; then
        wg-quick down "$conf" 2>/dev/null || true
    fi
    ip link del dev "$iface" 2>/dev/null || true
done

echo "[clean-orphan] done"
