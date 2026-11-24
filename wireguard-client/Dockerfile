FROM linuxserver/wireguard:latest

# 1) Replace the stock svc-wireguard (one-shot: exits after the first attempt,
#    and runs `ip route del default` when no conf is found -> kills the HOST's
#    default route with network_mode: host) with a persistent watcher that
#    (re)deploys every tunnel in /config/wg_confs.
COPY svc-wireguard/run /etc/s6-overlay/s6-rc.d/svc-wireguard/run
COPY svc-wireguard/down /etc/s6-overlay/s6-rc.d/svc-wireguard/down
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-wireguard/run \
            /etc/s6-overlay/s6-rc.d/svc-wireguard/down

# 2) Remove interfaces left behind by a previous container. With
#    network_mode: host, wg0 belongs to the HOST, so `docker stop` that fails
#    its down hook (or a container that crashed) leaves an orphan wg0 built
#    from OLD keys/ListenPort. A new container then sees "wg0 already up" and
#    never re-applies the new conf -> restarts appear to do nothing.
COPY custom-cont-init.d/ /custom-cont-init.d/

# 3) Long-running helper services (DDNS endpoint refresh, route watchdog).
COPY custom-services.d/ /custom-services.d/
