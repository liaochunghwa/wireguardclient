#!/usr/bin/env bash
# doctor.sh — quick self-check of the WireGuard client stack. Run it whenever
# "the container is running but the VPN subnet is unreachable".
#
#   sudo ./doctor.sh [TARGET_IP]      # TARGET_IP defaults to the first host in
#                                     # WG_VPN_SUBNET (e.g. the Qdrant server)
set -e

TARGET="${1:-192.168.50.148}"
CLIENT=wireguard-client

pass() { echo "  [ OK ] $*"; }
fail() { echo "  [FAIL] $*"; }
warn() { echo "  [warn] $*"; }

echo "=== 1. containers ==="
docker ps -a --format 'table {{.Name}}\t{{.State}}\t{{.Image}}' | grep -E 'wireguard|NAME'

for c in "$CLIENT" wireguard-ui; do
    state=$(docker inspect -f '{{ .State }}' "$c" 2>/dev/null || echo missing)
    [ "$state" = "running" ] && pass "$c is running" || fail "$c state = $state"
    if [ "$state" = "created" ]; then
        fail "$c is stuck in 'created' -> usually the compose file still has a 'sysctls:' block"
    fi
done

echo "=== 2. host sysctls ==="
[ "$(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null)" = "1" ] && pass "src_valid_mark=1" || fail "src_valid_mark != 1 (sudo ./deploy.sh writes /etc/sysctl.d/99-wireguard.conf)"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && pass "ip_forward=1" || warn "ip_forward=0"

echo "=== 3. compose file ==="
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}"
if grep -q '^[[:space:]]*sysctls:' "$COMPOSE_FILE" 2>/dev/null; then
    fail "$COMPOSE_FILE contains 'sysctls:' -> runc rejects it with network_mode: host"
else
    pass "no sysctls in compose (correct)"
fi
if grep -q 'network_mode: host' "$COMPOSE_FILE" 2>/dev/null; then
    pass "network_mode: host"
else
    warn "no network_mode: host -> wg0 will not belong to the host"
fi

echo "=== 4. interface / tunnel ==="
if ip link show wg0 >/dev/null 2>&1; then
    pass "wg0 exists on the host"
    ip -o link show wg0 | sed -n '1p' | sed 's/^/       /'
else
    fail "wg0 does not exist -> conf not applied (check ${DATA_DIR:-./data}/wg_confs/)"
fi

docker exec "$CLIENT" wg show 2>/dev/null | sed -n '1,10p' | sed 's/^/       /' || warn "wg show failed"

echo "=== 5. route to the VPN subnet ==="
if ip route show | grep -q 'dev wg0'; then
    ip route show | grep 'dev wg0' | sed 's/^/       /'
else
    fail "no route via wg0 -> the watcher did not apply the conf (or AllowedIPs is empty)"
fi

echo "=== 6. reachability ==="
if ping -c 2 -W 4 "$TARGET" >/dev/null 2>&1; then
    pass "ping $TARGET through the tunnel works"
else
    fail "cannot reach $TARGET"
fi

echo "=== 7. last watcher log ==="
docker logs --tail 20 "$CLIENT" 2>&1 | sed 's/^/       /'
