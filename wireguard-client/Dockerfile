FROM linuxserver/wireguard:latest

# 1) Replace the stock svc-wireguard (one-shot: exits after the first attempt,
#    and runs `ip route del default` when no conf is found -> kills the HOST's
#    default route with network_mode: host) with a persistent watcher that
#    (re)deploys every tunnel in /config/wg_confs.
COPY svc-wireguard/run /etc/s6-overlay/s6-rc.d/svc-wireguard/run
# s6-rc calls `finish` (not `down`) when the service stops; the stock finish
# script tears down the tunnels listed in /run/activeconfs.
COPY svc-wireguard/finish /etc/s6-overlay/s6-rc.d/svc-wireguard/finish
# The stock service is type `oneshot`, so s6 never supervises the run script and
# `docker stop` kills it with SIGKILL: the teardown (finish / the TERM trap in
# run) never runs and wg0 stays on the host. Declaring it `longrun` makes s6
# stop it gracefully, run finish, and let the TERM trap in run tear the tunnel
# down.
COPY svc-wireguard/type /etc/s6-overlay/s6-rc.d/svc-wireguard/type
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-wireguard/run \
             /etc/s6-overlay/s6-rc.d/svc-wireguard/finish

# 2) Remove interfaces left behind by a previous container. With
#    network_mode: host, wg0 belongs to the HOST, so `docker stop` that fails
#    its down hook (or a container that crashed) leaves an orphan wg0 built
#    from OLD keys/ListenPort. A new container then sees "wg0 already up" and
#    never re-applies the new conf -> restarts appear to do nothing.
COPY custom-cont-init.d/ /custom-cont-init.d/

# 3) Long-running helper services (DDNS endpoint refresh, route watchdog).
COPY custom-services.d/ /custom-services.d/

# custom-cont-init.d / custom-services.d scripts are only executed when they are
# executable; git does not always carry the exec bit, so make sure of it here.
RUN chmod +x /custom-cont-init.d/* /custom-services.d/* 2>/dev/null || true
