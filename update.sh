#!/usr/bin/env bash
# update.sh — pull the repo, rebuild the images (pulling the latest
# linuxserver/wireguard base image) and restart the stack without touching the
# tunnel configs in DATA_DIR. Run manually, from cron, or from the systemd
# timer in systemd/ (see README).
#
#   sudo ./update.sh            # git pull + build + up
#   sudo ./update.sh --no-git   # skip git pull
#   sudo ./update.sh --restart  # only restart the containers (no rebuild)
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./update.sh"
    exit 1
fi

if [ "${1:-}" != "--no-git" ] && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "==> Updating repo"
    git pull --ff-only
fi

# Keep the host sysctls in place (they are what makes wg-quick routing work;
# they cannot be set from the container because of network_mode: host).
if [ ! -f /etc/sysctl.d/99-wireguard.conf ]; then
    cat > /etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.ip_forward = 1
SYSCTL
fi
sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null

if [ "${1:-}" = "--restart" ]; then
    echo "==> Restarting containers"
    docker compose up -d
else
    echo "==> Rebuilding images (pulls the newest linuxserver/wireguard)"
    docker compose build --pull
    docker compose up -d
fi

echo "==> Checking the tunnel"
sleep 15
docker exec wireguard-client wg show 2>/dev/null | head -12 || echo "wireguard-client is not running"
ip route show | grep 'dev wg0' || echo "no wg0 route yet"
