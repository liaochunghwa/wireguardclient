#!/usr/bin/env bash
# deploy.sh — one-command deployment of this WireGuard client on a new machine
# (Ubuntu / TrueNAS Scale). Prepares the host, then starts the containers.
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./deploy.sh"
    exit 1
fi

echo "==> Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not installed. Install it first (e.g. on Ubuntu: curl -sSL https://get.docker.com | sh)"
    exit 1
fi

echo "==> Checking WireGuard kernel module"
if ! ip link add dev wg-test type wireguard 2>/dev/null; then
    echo "WARNING: the kernel does not support WireGuard (modprobe wireguard)."
    echo "         The container will not be able to create the wg0 interface."
else
    ip link del dev wg-test 2>/dev/null || true
    echo "WireGuard kernel module OK"
fi

echo "==> Setting required sysctls (persisted)"
sysctl -w net.ipv4.conf.all.src_valid_mark=1
sysctl -w net.ipv4.ip_forward=1
grep -q 'src_valid_mark' /etc/sysctl.conf 2>/dev/null || \
    echo "net.ipv4.conf.all.src_valid_mark=1" >> /etc/sysctl.conf
grep -q 'ip_forward' /etc/sysctl.conf 2>/dev/null || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

echo "==> Preparing .env"
if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from .env.example (edit ADMIN_PASS / SECRET_KEY before exposing the UI!)"
fi

echo "==> Starting containers"
docker compose up -d --build

echo "==> Done."
echo "    Web UI:  http://<this-machine-ip>:5080"
echo "    Import the .conf exported by the wg-easy server (192.168.50.148:51820) in the UI,"
echo "    and the wg0 tunnel will be created automatically within ~15s."
echo "    Check tunnel status:  docker exec wireguard-client wg show"
