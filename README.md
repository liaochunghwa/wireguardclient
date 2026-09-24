# WireGuard Client

WireGuard VPN client + Web UI 管理面板，部署在 TrueNAS / Ubuntu 主機上。

## 架構

```
wireguard-client (linuxserver/wireguard)  ←  VPN tunnel UDP 51820
        ↕ shared volume /config
wireguard-ui (Flask/Python)              ←  Web UI Port 5080
```

- **wireguard-client**: WireGuard VPN 連線（host 網路，基於 linuxserver/wireguard，含自訂 init script 等待 config 就緒）
- **wireguard-ui**: 視覺管理面板（可匯入 .conf、編輯設定、重啟 WireGuard、監控連線）

## 功能

- **匯入設定**：上傳或貼上 WireGuard Server 傳來的 `.conf` 檔案
- **編輯設定**：直接在 Web UI 編輯 wg0.conf，儲存後自動重連
- **連線狀態**：即時顯示 peer、handshake 時間、上下行流量
- **重啟 / 停止**：一鍵重啟 WireGuard 介面
- **下載設定**：下載目前 wg0.conf
- **密碼登入**：保護管理介面

## 預設帳密

| 項目 | 值 |
|------|-----|
| 帳號 | `admin` |
| 密碼 | `wireguard` |

可在 `docker-compose.yml` 的 `environment` 中修改，或透過 `.env` 檔案設定。

## 部署（新機器）

```bash
# 1. Clone repo
git clone https://github.com/liaochunghwa/wireguardclient.git
cd wireguardclient

# 2. 建立 .env（複製範本並修改）
cp .env.example .env
# 修改 DATA_DIR、SECRET_KEY 等

# 3. 建立 wg0.conf（從 Server 取得金鑰後填入）
cp wg_confs/wg0.conf.sample wg_confs/wg0.conf
# 編輯 wg0.conf 填入 PrivateKey、Address、Endpoint 等

# 4. 啟動
sudo docker compose up -d --build
```

Web UI: `http://<YOUR_IP>:5080`

> **Init Script**: `wireguard-client` 的 container 啟動時會自動等待 `wg0.conf` 就緒（最多 60 秒）。若先 `docker compose up -d --build` 再透過 Web UI 建立 config，container 會自動等待。若超過 60 秒仍無 config，需手動重啟：`docker restart wireguard-client`。

## Endpoint 設定注意事項

WireGuard client 的 `Endpoint` 需要根據部署環境選擇：

| 場景 | Endpoint 設定 |
|------|--------------|
| Client 與 Server 在**同一個 LAN** | 用 Server 的**內網 IP**，例如 `192.168.50.148:51820` |
| Client 從**外網**連 Server | 用 Server 的**公網域名**，例如 `mushinah.ddns.net:51820` |

### 為什麼不能在 LAN 內用公網域名？

多數路由器不支援 **hairpin NAT**（從 LAN 連自己的 WAN IP 再轉回 LAN），會導致 WireGuard handshake 失敗。如果 Client 和 Server 在同一個網段，務必使用內網 IP。

## Host 環境需求

```bash
# 確保 sysctl 已設定（wg-quick 需要）
sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1
sudo sysctl -w net.ipv4.ip_forward=1

# 永久生效
echo "net.ipv4.conf.all.src_valid_mark=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
```

## wg0.conf 設定說明

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address = 10.8.0.x/24          # x 為 Server 分配的 IP（不能和別人重複）
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY>
AllowedIPs = 10.8.0.0/24       # 只路由 VPN 子網，不要用 0.0.0.0/0
PersistentKeepkeepalive = 25
Endpoint = <SERVER_IP>:51820    # 同 LAN 用內網 IP，外網用域名
```

> ⚠️ `AllowedIPs` 建議設為 `10.8.0.0/24`（只路由 VPN 流量）。若設為 `0.0.0.0/0`（全部流量走 VPN），需要完整的路由配置，否則可能導致網路中斷。

## 預設路由保險（netplan）

若主機的 DHCP 只發 DNS 主機路由（例如 `1.1.1.1 / 8.8.8.8 via 閘道`）卻**沒有給 default route**，重開機後 WireGuard client 會連不上（DDNS endpoint 不可達、出現 `cannot resolve <DDNS>`）。用 `netplan/99-default-route.yaml` 強制訂死 default route：

```bash
# 依主機修改網卡名稱（ens3/eno1/eth0）與閘道後：
sudo cp netplan/99-default-route.yaml /etc/netplan/
sudo netplan apply
ip route show | grep default   # 確認出現 default via <GATEWAY>
```

> 此檔設 `dhcp4-overrides.use-routes: false`，避免 DHCP 給的路由（沒有 default）蓋掉我們訂死的 default。

## Files

```
├── docker-compose.yml              # 兩個 service 的 compose 設定
├── .env.example                    # 環境變數範本（複製為 .env）
├── wireguard-client/
│   ├── Dockerfile                  # 基於 linuxserver/wireguard，含自訂 init script
│   └── custom-cont-init.d/
│       └── 10-wait-for-config.sh   # 啟動時等待 wg0.conf 就緒（最多 60s）
├── wireguard-ui/
│   ├── app.py                      # Flask 主程式
│   ├── Dockerfile
│   ├── requirements.txt
│   └── templates/
│       ├── index.html              # 管理面板
│       └── login.html              # 登入頁
├── coredns/
│   └── Corefile
├── netplan/
│   └── 99-default-route.yaml        # 訂死 default route（DHCP 沒給 default 時用）
├── templates/
│   ├── server.conf                 # Server 設定模板
│   └── peer.conf                   # Peer 設定模板
└── wg_confs/
    └── wg0.conf.sample             # Client 設定範本
```

## Key Parameters

| Parameter | Value |
|-----------|-------|
| VPN Subnet | 10.8.0.0/24 |
| MTU | 1420 |
| DNS | 1.1.1.1 |
| WireGuard Port | 51820/udp |
| Web UI Port | 5080 |
| TZ | Asia/Taipei |
