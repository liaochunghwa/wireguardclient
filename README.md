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
2. 寫 `/etc/sysctl.d/99-wireguard.conf`（`src_valid_mark` / `ip_forward`，重開機仍生效）
3. 檢查 host 是否有 default route（沒有 → 提示 netplan 檔案）
4. 移除「不是這個 compose 專案建立的」同名 container（避免 `docker run` 殘留造成 `docker compose up` 失敗）
5. 從 `.env.example` 建立 `.env`（請修改 `ADMIN_PASS`、`SECRET_KEY`、`WG_LISTEN_PORT`）
6. `docker compose up -d --build`，然後 tunnel 狀態檢查

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

# 永久生效：用 drop-in 檔案（/etc/sysctl.conf 的預設內容全部被註解，
# 直接 tee -a 到 /etc/sysctl.conf 容易被後面的註解行干擾，且有些系統不讀它）
sudo tee /etc/sysctl.d/99-wireguard.conf >/dev/null <<'EOF'
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-wireguard.conf
```

> 這一步**不能**由 container 做：`network_mode: host` 下 kernel 拒絕容器改 `net.*` sysctl，runc 也禁止對 host namespace 傳 `--sysctl`。所以只能設定在 host 層。

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
2. ⚠️ **`docker-compose.yml` 不能寫 `sysctls:`**。`network_mode: host` 時網路 namespace 就是 host 的，runc 1.2+（實測 1.3.6）直接拒絕：
   ```
   failed to create shim task: OCI runtime create failed: runc create failed:
   sysctl "net.ipv4.conf.all.src_valid_mark" not allowed in host network namespace
   ```
   結果是容器停在 `Created` 狀態、整個 stack 起不來，`docker restart` 也救不回來。sysctl 必須設定在 **host 層**（`sudo ./deploy.sh` 寫 `/etc/sysctl.d/99-wireguard.conf`；`/etc/sysctl.conf` 裡被註解的 lines 不會生效）。container 內也無法設定（kernel 拒絕），watcher 僅會 Warning。
3. `wireguard-client/svc-wireguard/finish`（s6-rc 停止服務時執行）+ `custom-cont-init.d/00-clean-orphan-ifaces.sh`：見下方「重啟後不套用」。
4. Web UI 匯入時**驗證** conf（PrivateKey/PublicKey/Endpoint 是否真實）並**自動修正**：補 `ListenPort`、`PersistentKeepalive`，可選「只路由 VPN 子網」將 `AllowedIPs` 改為 `WG_VPN_SUBNET`。
5. 套用設定時用 `docker exec` 執行 `wg-quick down/up`，不需要重啟整個 container。

### 重啟後不套用：孤兒 `wg0` 介面（最常見）

`network_mode: host` 表示 **wg0 屬於 host，不屬於 container**。container 停止時若 down hook 沒成功（conf 解析失敗、`docker kill`、OOM），host 上的 wg0 還在，用的是**舊的私鑰與舊 ListenPort**。下一個 container 啟動時看到「wg0 已經 up」，就不重新套用 conf → 你改的設定永遠不會生效，看起來就是「重啟 docker 都失敗」。

修法（repo 已實作）：
- 啟動時 `00-clean-orphan-ifaces.sh` 先把 host 上所有 `type wireguard` 的介面移除（同 host 有其他 WireGuard stack 時設 `WG_CLEAN_ORPHANS=0`）。
- conf 的 hash 存在 **持久 volume** `${DATA_DIR}/.wg-state/`，所以重啟後能判斷「現有介面是不是由目前 conf 建立」。hash 不符或 state 空 → 強制 `wg-quick down` + `ip link del` + 重新 `up`。
- 每 cycle 檢查 `AllowedIPs` 的 route 是否存在，缺了就補（例如 `192.168.50.0/24` 到 Qdrant）。
- tunnel up 但沒有 handshake，連續 `WG_MAX_FAIL_CYCLES`（預設 4）次後自動重建介面。

判斷方式：
```bash
docker stop wireguard-client
ip link show wg0          # 如果仍存在 → 就是孤兒介面問題
```

### 快速排查（一鍵）

```bash
sudo ./doctor.sh 192.168.50.148   # 檢查 container 狀態、sysctl、compose 是否有 sysctls、
                                  # wg0、route、ping 到 Qdrant、watcher 最後 20 行 log
```

驗證「重啟後隧道會自愈」（stop → start 後自動重建 wg0 並 ping Qdrant）：

```bash
sudo ./restart-test.sh 192.168.50.148
```

手動檢查：

```bash
docker logs wireguard-client              # 看 [wg-auto-up] 是否 bringing up / failed
docker exec wireguard-client wg show      # 是否有 wg0 與 handshake
docker exec wireguard-client cat /config/wg_confs/wg0.conf
sysctl net.ipv4.conf.all.src_valid_mark   # 應為 1
ip route show | grep default              # host 仍有 default route
ip route show | grep 'dev wg0'           # 應有 10.8.0.0/24（及 192.168.50.0/24）
```

## 每台主機的固定 ListenPort

`WG_LISTEN_PORT` 是 UI 匯入 conf 時寫進 `ListenPort` 的值，**必須與 WireGuard server 已學到的 listen port 一致**，否則重啟後 server 端的 endpoint 停在舊 port，handshake 不會完成。

| 主機 | `WG_LISTEN_PORT` | VPN IP |
|------|-----------------|--------|
| 192.168.2.2（amhs-web01） | 52066 | 10.8.0.27 |
| 192.168.2.102（amhs-web02） | 52067 | 10.8.0.28 |

查目前值：`docker exec wireguard-client wg show` → `listening port`。

## 自動更新（image 與 watcher 保持最新）

```bash
sudo ./update.sh            # git pull + docker compose build --pull + up -d + tunnel 檢查
sudo ./update.sh --restart  # 只重啟 container，不重建 image
```

想用 systemd timer 每天自動重建（含 linuxserver 基礎 image 更新）：

```bash
sudo cp systemd/wireguard-update.service systemd/wireguard-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wireguard-update.timer
systemctl list-timers | grep wireguard
```

開機自動啟動整個 stack：

```bash
sudo cp systemd/wireguard-client-stack.service /etc/systemd/system/   # 改掉 WorkingDirectory 路徑
sudo systemctl daemon-reload
sudo systemctl enable --now wireguard-client-stack.service
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
├── deploy.sh                       # 一鍵部署：host 前置檢查 + sysctl + 清理殘留 container + compose up
├── update.sh                       # git pull + rebuild image + 重啟（可挂 systemd timer 每日執行）
├── doctor.sh                       # 一鍵自檢：container/sysctl/wg0/route/ping/log
├── restart-test.sh                   # docker stop/start 後驗證隧道自動重建
├── docker-compose.yml              # 兩個 service 的 compose 設定（⚠️ 沒有 sysctls）
├── .env.example                    # 環境變數範本（複製為 .env）
├── systemd/
│   ├── wireguard-client-stack.service   # 開機自動 docker compose up -d
│   ├── wireguard-update.service
│   └── wireguard-update.timer           # 每日 04:30 自動 rebuild
├── wireguard-client/
│   ├── Dockerfile                  # 基於 linuxserver/wireguard，覆寫 svc-wireguard run/finish
│   ├── svc-wireguard/
│   │   ├── type                    # longrun（內建是 oneshot → docker stop 會 SIGKILL，finish 不執行）
│   │   ├── run                     # 常駐 watcher：conf 出現/改變 → 自動 wg-quick down/up
│   │   └── finish                  # 容器停止時乾淨地拆除 wg0（避免孤兒介面）
│   ├── custom-cont-init.d/
│   │   └── 00-clean-orphan-ifaces.sh  # 啟動時移除 host 上殘留的 wg 介面
│   └── custom-services.d/
│       └── 10-wg-dns-update.sh     # DDNS endpoint 輪轉時自動 `wg set peer endpoint`
├── wireguard-ui/
│   ├── app.py                      # Flask 主程式（匯入驗證 + 自動補 ListenPort/AllowedIPs）
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
