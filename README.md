# WireGuard Client

WireGuard VPN client + Web UI 管理面板，部署在 TrueNAS / Ubuntu 主機上。

## 架構

```
wireguard-client (linuxserver/wireguard + 自訂 svc-wireguard watcher)  ←  在 host 網路建立 wg0，VPN tunnel UDP 51820
        ↕ shared volume /config
wireguard-ui (Flask/Python)              ←  Web UI Port 5080
```

- **wireguard-client**: WireGuard VPN 連線（host 網路）。自訂的 `svc-wireguard` 服務**常駐監看** `/config/wg_confs/`：conf 出現或改變時自動 `wg-quick up/down`，介面消失時自動重建 → 整台機器（host 網路層）的 wg0 佈署由 container 完成，host 本身不需要安裝 wireguard。
- **wireguard-ui**: 視覺管理面板（可匯入 .conf、編輯設定、套用重連、監控連線）。

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

# 2. 一鍵部署（自動設定 sysctl、建立 .env、啟動 container）
sudo ./deploy.sh
```

`deploy.sh` 會：
1. 檢查 Docker 與 WireGuard kernel module
2. 設定並持久化 `src_valid_mark` / `ip_forward` sysctl
3. 從 `.env.example` 建立 `.env`（請修改 `ADMIN_PASS`、`SECRET_KEY`）
4. `docker compose up -d --build`

Web UI: `http://<YOUR_IP>:5080`

> 啟動時**不需要**先有 `wg0.conf`。之後在 Web UI 匯入 wg-easy 的 `.conf`（或直接把檔案放到 `<DATA_DIR>/wg_confs/`），container 內的 watcher 會在約 15 秒內自動 `wg-quick up` 建立 wg0，不需要重啟 container。

> 手動部署（不用 deploy.sh）：`cp .env.example .env` 後 `sudo docker compose up -d --build`，但 host 的 sysctl 需自行設定（見下方「Host 環境需求」）。

## Endpoint 設定注意事項

WireGuard client 的 `Endpoint` 需要根據部署環境選擇：

| 場景 | Endpoint 設定 |
|------|--------------|
| Client 與 Server 在**同一個 LAN** | 用 Server 的**內網 IP**，例如 `192.168.50.148:51820` |
| Client 從**外網**連 Server | 用 Server 的**公網域名**，例如 `mushinah.ddns.net:51820` |

### 為什麼不能在 LAN 內用公網域名？

多數路由器不支援 **hairpin NAT**（從 LAN 連自己的 WAN IP 再轉回 LAN），會導致 WireGuard handshake 失敗。如果 Client 和 Server 在同一個網段，務必使用內網 IP。

## Host 環境需求

> `sudo ./deploy.sh` 會自動完成以下設定。若手動部署，需自行執行：

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
ListenPort = 52066            # ⚠️ 務必固定！見下方「重啟後連不回來」說明
                              # 透過 Web UI 匯入 wg-easy 的 .conf 時，程式會自動補 ListenPort（預設 51821）
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY>
AllowedIPs = 10.8.0.0/24       # 只路由 VPN 子網，不要用 0.0.0.0/0
PersistentKeepalive = 25
Endpoint = <SERVER_IP>:51820    # 同 LAN 用內網 IP，外網用域名
```

> ⚠️ `AllowedIPs` 建議設為 `10.8.0.0/24`（只路由 VPN 流量）。若設為 `0.0.0.0/0`（全部流量走 VPN），需要完整的路由配置，否則可能導致網路中斷。

### 重啟後連不回來（listen port 飄移）

若 `[Interface]` **沒有指定 `ListenPort`**，每次 `docker restart wireguard-client`（介面重建）都會換隨機 listener port；Server 端學到的 endpoint 停在舊 port，新介面的 handshake 完成不了。**務必固定 `ListenPort`**（沿用 Server 已學到的 port，例 `52066`），重啟後立刻能重連。判斷方式：重啟後 `docker exec wireguard-client wg show` 若 `listening port` 每次都變 → 就是這個問題。

## 匯入 .conf 後 wg0 沒建立（根因與修正）

**根因**：`linuxserver/wireguard` 的內建 `svc-wireguard` 只在 container 啟動時**一次性**嘗試 `wg-quick up`，之後服務就結束。如果那一刻 `/config/wg_confs/` 沒有有效 conf（例如之後才透過 Web UI 匯入），wg0 永遠不會建立；它甚至會執行 `ip route del default`，在 `network_mode: host` 下直接砍掉 **host 的 default route**。此外 wg-easy 匯出的 conf 沒有 `ListenPort`（重啟後 port 飄移）、`AllowedIPs = 0.0.0.0/0, ::/0`（全部流量走 tunnel，host 網路容易斷）。

**修正**：
1. 自訂 `wireguard-client/svc-wireguard/run` 取代內建服務：**常駐監看** `wg_confs/`，conf 出現或內容改變時自動 `wg-quick down/up`，介面消失時自動重建（間隔 `WG_AUTO_UP_INTERVAL`，預設 15 秒）。
2. `docker-compose.yml` 加入 `SYS_ADMIN` 能力與 `sysctls`（`src_valid_mark`、`ip_forward`），container 可自行設定 wg-quick 所需參數。
3. Web UI 匯入時**驗證** conf（PrivateKey/PublicKey/Endpoint 是否真實）並**自動修正**：補 `ListenPort`、`PersistentKeepalive`，可選「只路由 VPN 子網」將 `AllowedIPs` 改為 `WG_VPN_SUBNET`。
4. 套用設定時用 `docker exec` 執行 `wg-quick down/up`，不需要重啟整個 container。

### 快速排查

```bash
docker logs wireguard-client              # 看 [wg-auto-up] 是否 bringing up / failed
docker exec wireguard-client wg show      # 是否有 wg0 與 handshake
docker exec wireguard-client cat /config/wg_confs/wg0.conf
sysctl net.ipv4.conf.all.src_valid_mark   # 應為 1
ip route show | grep default              # host 仍有 default route
```

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
├── deploy.sh                       # 一鍵部署：host 前置檢查 + sysctl + compose up
├── docker-compose.yml              # 兩個 service 的 compose 設定
├── .env.example                    # 環境變數範本（複製為 .env）
├── wireguard-client/
│   ├── Dockerfile                  # 基於 linuxserver/wireguard，覆寫 svc-wireguard
│   └── svc-wireguard/
│       └── run                     # 常駐 watcher：conf 出現/改變 → 自動 wg-quick up/down
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
