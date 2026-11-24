#!/usr/bin/env bash
# deploy.sh — one-command deployment of this WireGuard client stack on a new
# machine (Ubuntu / TrueNAS Scale). Prepares the host, then builds + starts the
# containers, and verifies the tunnel.
#
#   sudo ./deploy.sh              # first install (creates .env, builds, starts)
#   sudo ./deploy.sh --update     # git pull + rebuild + restart (see update.sh)
#
# Idempotent: on an existing install it reuses the DATA_DIR that the current
# wireguard-client container already mounts, so the tunnel configs in
# <DATA_DIR>/wg_confs are never lost.
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
CLIENT=wireguard-client
UI=wireguard-ui

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./deploy.sh"
    exit 1
fi

if [ "${1:-}" = "--update" ]; then
    exec "$REPO_DIR/update.sh"
fi

echo "==> Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not installed. Install it first (Ubuntu: curl -sSL https://get.docker.com | sh)"
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

echo "==> Persisting required sysctls on the HOST"
# sysctl CANNOT be set from the container: with network_mode: host the network
# namespace is the host's, and runc refuses `--sysctl net.*` for it
# ("sysctl ... not allowed in host network namespace"). It has to be a host
# setting that survives a reboot -> use a drop-in file, not the commented
# lines in /etc/sysctl.conf.
cat > /etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
# Required by wg-quick (source validation of packets routed through wg0)
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.ip_forward = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-wireguard.conf
echo "src_valid_mark = $(sysctl -n net.ipv4.conf.all.src_valid_mark)"

echo "==> Default route check (netplan)"
if ! ip route show | grep -q default; then
    echo "WARNING: the host has no default route. The DDNS endpoint of the"
    echo "         WireGuard server will not be reachable."
    echo "         Fix with netplan (see netplan/99-default-route.yaml)."
fi

# A container created by `docker run` (or by an old compose project) keeps the
# same name and blocks `docker compose up`. Remove anything that is not part of
# THIS compose project, and anything stuck in a "Created" state.
remove_stale_containers() {
    for name in "$CLIENT" "$UI"; do
        if ! docker ps -a -q -f name="^${name}$" | grep -q .; then
            continue
        fi
        cfg=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$name" 2>/dev/null || true)
        state=$(docker inspect -f '{{ .State }}' "$name" 2>/dev/null || true)
        if [ "$cfg" != "$COMPOSE_FILE" ] || [ "$state" = "created" ]; then
            echo "==> Removing stale container ${name} (compose file: ${cfg:-<none>}, state: ${state})"
            docker rm -f "$name" >/dev/null
        fi
    done
}

echo "==> Preparing .env"
# Keep the data directory the existing container uses, otherwise the confs in
# <DATA_DIR>/wg_confs would be "lost" (a new empty ./data would be created and
# the tunnel would never come up).
existing_data_dir=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/config" }}{{ .Source }}{{ end }}{{ end }}' "$CLIENT" 2>/dev/null || true)

if [ ! -f "$REPO_DIR/.env" ]; then
    cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
    echo "Created .env from .env.example (edit ADMIN_PASS / SECRET_KEY / WG_LISTEN_PORT!)"
    if [ -n "$existing_data_dir" ] && [ -d "$existing_data_dir" ]; then
        sed -i "s|^DATA_DIR=.*|DATA_DIR=$existing_data_dir|" "$REPO_DIR/.env"
        echo "    Reusing existing config volume: DATA_DIR=$existing_data_dir"
    fi
fi

# sanity: the wg_confs directory must exist (init-config of the image creates it)
grep -q '^DATA_DIR=' "$REPO_DIR/.env" || echo "DATA_DIR=./data" >> "$REPO_DIR/.env"

remove_stale_containers

echo "==> Building and starting containers"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "==> Waiting for the tunnel (conf changes are applied automatically every ${WG_AUTO_UP_INTERVAL:-15}s)"
sleep 20
docker exec "$CLIENT" wg show 2>/dev/null | head -12
if ip route show | grep -q 'dev wg0'; then
    echo "OK: wg0 is up, routes:"
    ip route show | grep 'dev wg0'
else
    echo "wg0 not up yet. Put your .conf into ${DATA_DIR:-./data}/wg_confs/ or import it in the Web UI,"
    echo "the watcher will bring it up within ${WG_AUTO_UP_INTERVAL:-15}s."
fi

echo "==> Done."
echo "    Web UI:  http://<this-machine-ip>:${WG_UI_PORT:-5080}"
echo "    Import the .conf exported by the wg-easy server in the UI."
echo "    Check tunnel status:  docker exec wireguard-client wg show"
echo "    Auto-update images:   sudo ./update.sh   (or install the systemd timer, see README)"
