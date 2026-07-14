# WireGuard Client (141 TrueNAS)

WireGuard VPN client running on TrueNAS (192.168.50.141) via Portainer.

## Stack

- **Image**: `linuxserver/wireguard:latest`
- **Network**: host mode
- **Container**: `wireguard-client`
- **Compose project**: `wireguardclient` (Portainer `/data/compose/22/`)

## Setup

1. Copy `wg_confs/wg0.conf.sample` to `wg_confs/wg0.conf`
2. Fill in your actual keys and endpoint
3. Deploy via Portainer or `docker compose up -d`

## Files

```
├── docker-compose.yml          # Portainer compose config
├── coredns/
│   └── Corefile                # CoreDNS config for WG DNS
├── templates/
│   ├── server.conf             # Server config template
│   └── peer.conf               # Peer config template
└── wg_confs/
    └── wg0.conf.sample         # Sample client config (DO NOT commit real wg0.conf)
```

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Subnet | 10.8.0.0/24 |
| MTU | 1420 |
| DNS | 1.1.1.1 |
| Listen Port | 51820/udp |
| TZ | Asia/Taipei |
| PUID/PGID | 0/0 (root) |
