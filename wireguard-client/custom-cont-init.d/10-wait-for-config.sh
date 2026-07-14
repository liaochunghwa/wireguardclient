#!/usr/bin/with-contenv bash
# Wait for wg0.conf to exist before proceeding with WireGuard init
# This prevents the race condition when deploying via docker compose
# before the config file is placed

CONF_DIR="/config/wg_confs"
MAX_WAIT=60
INTERVAL=3
elapsed=0

echo "Checking for WireGuard config in ${CONF_DIR}/ ..."

# Loop until a .conf file exists or timeout
while [ $elapsed -lt $MAX_WAIT ]; do
    if ls "${CONF_DIR}"/*.conf 1>/dev/null 2>&1; then
        echo "Found config file(s) in ${CONF_DIR}/, proceeding..."
        exit 0
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
done

echo "WARNING: No .conf file found in ${CONF_DIR}/ after ${MAX_WAIT}s."
echo "WireGuard tunnel will NOT start until a valid config is added and the container is restarted."
exit 0
