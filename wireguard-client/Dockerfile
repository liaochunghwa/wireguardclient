FROM linuxserver/wireguard:latest

# Replace the stock svc-wireguard (one-shot: exits after the first attempt)
# with a persistent watcher that always (re)deploys wg0 when a conf appears
# or changes. This is the "machine-level wg0 deployment" the client needs.
COPY svc-wireguard/run /etc/s6-overlay/s6-rc.d/svc-wireguard/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-wireguard/run

COPY custom-services.d/ /custom-services.d/
