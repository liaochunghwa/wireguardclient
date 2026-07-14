# WireGuard Client (141 TrueNAS)

WireGuard VPN client + Web UI 管理面板，運行在 TrueNAS (192.168.50.141)。

## 架構

```
wireguard-client (linuxserver/wireguard)  ←  VPN tunnel UDP 51820
        ↕ shared volume /config
wireguard-ui (Flask)                      ←  Web UI Port 5000
```

- **wireguard-client**: WireGuard VPN 連線（host 網路，linuxserver/wireguard）
- **wireguard-ui**: 視覺管理面板（Flask/Python，可匯入 .conf、重啟、監控）

## 功能

- 匯入 WireGuard Server 傳來的 `.conf` 檔案（上傳或貼上）
- 即時顯示 WireGuard 連線狀態（peer、handshake、流量）
- 重啟 / 停止 WireGuard 介面
- 下載目前設定檔
- 密碼保護登入頁面

## 預設帳密

| 項目 | 值 |
|------|-----|
| 帳號 | `admin` |
| 密碼 | `wireguard` |

可在 `docker-compose.yml` 的 `environment` 中修改 `ADMIN_USER` / `ADMIN_PASS`。

## 部署

```bash
# 在 141 上
cd /mnt/hivet/docker/wireguard-client
sudo docker compose up -d --build
```

Web UI: `http://192.168.50.141:5000`

## Files

```
├── docker-compose.yml              # 兩個 service 的 compose 設定
├── wireguard-ui/
│   ├── app.py                      # Flask 主程式
│   ├── Dockerfile
│   ├── requirements.txt
│   └── templates/
│       ├── index.html              # 管理面板
│       └── login.html              # 登入頁
├── coredns/
│   └── Corefile
├── templates/
│   ├── server.conf
│   └── peer.conf
└── wg_confs/
    └── wg0.conf.sample
```

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Subnet | 10.8.0.0/24 |
| MTU | 1420 |
| DNS | 1.1.1.1 |
| WireGuard Port | 51820/udp |
| Web UI Port | 5000 |
| TZ | Asia/Taipei |
