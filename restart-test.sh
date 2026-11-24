#!/usr/bin/env bash
# restart-test.sh — prove the tunnel self-heals after a container restart.
#   sudo ./restart-test.sh [TARGET_IP]
set -e
TARGET="${1:-192.168.50.148}"

echo "=== baseline ==="
docker exec wireguard-client wg show | sed -n '1,10p'
ip route show | grep 'dev wg0'
ping -c 2 -W 4 "$TARGET" >/dev/null && echo "baseline ping $TARGET OK"

echo "=== docker stop wireguard-client ==="
docker stop wireguard-client
sleep 3
if ip link show wg0 >/dev/null 2>&1; then
    echo "  wg0 still present after stop (down hook did not run cleanly)"
else
    echo "  wg0 removed cleanly by the down hook"
fi

echo "=== docker start wireguard-client ==="
docker start wireguard-client
for i in $(seq 1 12); do
    sleep 5
    if wg show wg0 >/dev/null 2>&1 && ip route show | grep -q 'dev wg0'; then
        break
    fi
    echo "  waiting... ($i)"
done

echo "=== after restart ==="
docker exec wireguard-client wg show | sed -n '1,10p'
ip route show | grep 'dev wg0'
if ping -c 3 -W 4 "$TARGET" >/dev/null; then
    echo "OK: $TARGET reachable again after restart"
else
    echo "FAIL: $TARGET not reachable"
    docker logs --tail 30 wireguard-client
    exit 1
fi

echo "=== from amhs-web container ==="
docker exec amhs-web sh -c "curl -s -m 8 http://${TARGET}:6333/collections" || echo "amhs-web could not reach Qdrant"
echo
