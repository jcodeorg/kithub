# 🛠️ **【構築手順書】Chromebook向けブラウザ開発環境 VPSセットアップガイド**

---

## ⏱️ 作業予定時間の目安

* **本手順の作業時間：** **合計 約35分**
* **事前・事後作業（本手順外）：** 約20〜30分（DNS設定・運用セキュリティ設定など）

---

## 1. 動作環境と事前準備

### 必要リソース

* **VPSスペック(Xserver 格安プラン ):** 4コア / 4GB RAM / 150GB SSD（Ubuntu 22.04 LTS / 24.04 LTS）
* **VPSスペック(Gemini推奨スペック):** 4コア / 8GB RAM / 100GB SSD（Ubuntu 22.04 LTS / 24.04 LTS）
* **ドメイン設定:** 以下のサブドメインの A レコードを VPS の IP アドレスに向けておくこと
* `gitea.example.com`（Gitea リポジトリ管理）
* `ide.example.com`（WebAssembly/クライアント動作型 Web IDE）
* `drone.example.com`（Drone CI サーバー）
* `flash.example.com`（ESP32 Web Serial 書き込み用ツール）



---

## 2. インストール手順（作業時間：約35分）

1. **OS初期セットアップ & Dockerの導入:** 所要時間: 約5分.
SSHでVPSにログインし、システムの更新および Docker / Docker Compose プラグインをインストールします。

```bash
# パッケージの更新
sudo apt update && sudo apt upgrade -y

# Dockerおよび必要な標準ツールのインストール
sudo apt install -y curl git docker.io docker-compose-plugin

# Dockerサービスの起動と自動起動有効化
sudo systemctl enable --now docker

```


2. **ディレクトリ構造作成と SSL (Caddy) の設定:** 所要時間: 約5分.
全サービスをまとめて管理するためのディレクトリを作成し、 Let's Encrypt 自動SSLに対応した **Caddy** の設定ファイルを用意します。

```bash
mkdir -p ~/dev-env/caddy ~/dev-env/gitea ~/dev-env/drone ~/dev-env/ide ~/dev-env/flash
cd ~/dev-env

```

`caddy/Caddyfile` を作成します（`example.com` はお使いのドメインに書き換えてください）。

```caddy
# Gitea (リポジトリ管理)
gitea.example.com {
    reverse_proxy gitea:3000
}

# Web IDE (クライアント型IDEの静的アセット配信)
ide.example.com {
    root * /usr/share/nginx/html
    file_server
}

# Drone CI (自動ビルド)
drone.example.com {
    reverse_proxy drone:80
}

# ESP Web Tools (Web Serial 書き込みUI)
flash.example.com {
    root * /usr/share/nginx/html
    file_server
}

```


3. **Docker Compose 設定ファイルの作成:** 所要時間: 約10分.
`~/dev-env/docker-compose.yml` を作成し、サーバーのリソース（メモリ）を消費しない構成を定義します。

```yaml
version: '3.8'

networks:
  dev-net:
    driver: bridge

services:
  # --- リバースプロキシ (HTTPS自動化) ---
  caddy:
    image: caddy:2-alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - dev-net

  # --- Gitリポジトリ管理 (Gitea) ---
  gitea:
    image: gitea/gitea:1.21-rootless
    restart: always
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__server__ROOT_URL=https://gitea.example.com/
      - GITEA__server__SSH_PORT=2222
    volumes:
      - ./gitea:/var/lib/gitea
    ports:
      - "2222:2222"
    networks:
      - dev-net

  # --- クライアント動作型 Web IDE 配信用 Nginx ---
  web-ide:
    image: nginx:alpine
    restart: always
    volumes:
      - ./ide:/usr/share/nginx/html
    networks:
      - dev-net

  # --- 自動ビルド (Drone CI) ---
  drone:
    image: drone/drone:2
    restart: always
    environment:
      - DRONE_GITEA_SERVER=https://gitea.example.com
      - DRONE_GITEA_CLIENT_ID=${GITEA_CLIENT_ID}
      - DRONE_GITEA_CLIENT_SECRET=${GITEA_CLIENT_SECRET}
      - DRONE_RPC_SECRET=${DRONE_RPC_SECRET}
      - DRONE_SERVER_HOST=drone.example.com
      - DRONE_SERVER_PROTO=https
    volumes:
      - ./drone:/data
    networks:
      - dev-net

  # --- Drone CI Runner (一斉ビルド負荷制御) ---
  drone-runner:
    image: drone/drone-runner-docker:1
    restart: always
    environment:
      - DRONE_RPC_PROTO=https
      - DRONE_RPC_HOST=drone.example.com
      - DRONE_RPC_SECRET=${DRONE_RPC_SECRET}
      - DRONE_RUNNER_CAPACITY=2  # 同時ビルド並列数を2件に絞りハングアップを防止
      - DRONE_RUNNER_NAME=vps-runner
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - dev-net

  # --- ESP Web Tools (ブラウザ書き込みUI配信) ---
  flash:
    image: nginx:alpine
    restart: always
    volumes:
      - ./flash:/usr/share/nginx/html
    networks:
      - dev-net

volumes:
  caddy_data:
  caddy_config:

```


4. **Gitea連携 & Drone OAuth設定:** 所要時間: 約10分.
1. 最初に Gitea と リバースプロキシを起動します。

```bash
cd ~/dev-env
docker compose up -d gitea caddy

```

2. ブラウザで `[https://gitea.example.com](https://gitea.example.com)` にアクセスし、初期管理者を作成します。
3. Gitea画面の右上アイコン > **[設定]** > **[アプリケーション]** > **[OAuth2アプリケーションの作成]** から以下を入力します。
* **アプリケーション名:** `Drone CI`
* **リダイレクトURI:** `[https://drone.example.com/login](https://drone.example.com/login)`


4. 発行された **Client ID** と **Client Secret** を確認します。
5. `~/dev-env/.env` ファイルを作成して記載します。

```env
GITEA_CLIENT_ID=発行されたClient_ID
GITEA_CLIENT_SECRET=発行されたClient_Secret
DRONE_RPC_SECRET=任意で生成した文字列(openssl rand -hex 16 等)

```

6. 全サービスを一括起動します。

```bash
docker compose up -d

```


5. **ESP32書き込みツール (ESP Web Tools) の配置:** 所要時間: 約5分.
Web Serial APIを利用してChromebookからUSB経由でESP32にワンクリック書き込みを行うための静的ファイルを `~/dev-env/flash/index.html` として設置します。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <title>ESP32 ブラウザ書き込みツール</title>
  <script type="module" src="https://unpkg.com/esp-web-tools@9/dist/web/install-button.js?module"></script>
  <style>
    body { font-family: sans-serif; text-align: center; padding: 2rem; background: #f4f6f8; }
    .card { background: white; max-width: 500px; margin: auto; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
  </style>
</head>
<body>
  <div class="card">
    <h2>ESP32 実機書き込み</h2>
    <p>ChromebookとESP32をUSBケーブルで接続し、下のボタンを押してください。</p>
    <esp-web-install-button manifest="manifest.json"></esp-web-install-button>
  </div>
</body>
</html>

```

* **検証:** Chromebookから `[https://flash.example.com](https://flash.example.com)` にアクセスし、「Connect」ボタンからUSBシリアルポートが検出されることを確認します。


---

## 3. 本手順書に含まれない補足作業（簡易チェックリスト）

本インストールガイドの範囲外となる、事前・事後で必要となる周辺作業です。

* **1. ドメイン・DNSの設定**
* 外部DNS管理画面でサブドメイン4種（`gitea`, `ide`, `drone`, `flash`）の A レコードをVPSのパブリックIPへ紐付ける作業。


* **2. サーバー基本セキュリティ設定**
* ファイアウォール（`ufw`）による不要ポートの閉鎖（80, 443, 22番のみ許可）。
* Giteaの一般ユーザー自由登録（Sign-up）の無効化設定。


* **3. リポジトリ用ビルド定義とマニフェスト作成**
* 生徒が利用する `.drone.yml`（C++コンパイル定義）の配備。
* ESP Web Tools書き込み用の `manifest.json`（バイナリ配置URL等の定義）の用意。


* **4. Google SSO連携設定（オプション）**
* Google Cloud Console上でのOAuth同意画面・クライアントIDの作成とGitea側への登録。


* **5. バックアップ・保守管理**
* Giteaデータディレクトリ（`~/dev-env/gitea`）の定時バックアップCron作成。



---