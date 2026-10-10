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
* `gitea.j-code.org`（Gitea リポジトリ管理）
* `ide.j-code.org`（WebAssembly/クライアント動作型 Web IDE）
* `drone.j-code.org`（Drone CI サーバー）
* `flash.j-code.org`（ESP32 Web Serial 書き込み用ツール）
* **VPS事業者側のファイアウォール:** TCP **80 / 443 / 22**（Giteaの SSH を使う場合は 2222 も）の受信を許可しておくこと（Xserver VPS では「パケットフィルター設定」で「Web」と「SSH」を追加）。80番が塞がっていると、Caddy が Let's Encrypt の証明書を取得できません。



---

## 2. インストール手順（作業時間：約35分）

1. **OS初期セットアップ & Dockerの導入:** 所要時間: 約5分.
SSHでVPSにログインし、システムの更新および Docker / Docker Compose プラグインをインストールします。

```bash
# パッケージの更新
sudo apt update && sudo apt upgrade -y

# Dockerおよび必要な標準ツールのインストール
# Xserver VPS では、管理画面で提供されている Docker 導入スクリプトで Docker を導入済みのため、以下はコメントアウトしている。
# 手動で導入する場合は、Docker 公式リポジトリの手順に従うか、次のコマンドを使用する。
# sudo apt install -y curl git docker.io docker-compose-v2

# Dockerサービスの起動と自動起動有効化
sudo systemctl enable --now docker

```

   **Docker の MTU 設定（必須）:** VPS の NIC の MTU（Xserver VPS では 1442）より Docker ブリッジの既定 MTU（1500）が大きいと、大きなダウンロードがタイムアウトや `connection reset by peer` で失敗します。`/etc/docker/daemon.json` で既定ブリッジの MTU を下げます。Drone のパイプライン用ネットワークと `dev-net` には、`docker-compose.yml` 側で別途 MTU を指定します（`daemon.json` の `mtu` は既定の `bridge` にしか効きません）。

```bash
echo '{ "mtu": 1400 }' | sudo tee /etc/docker/daemon.json
sudo dockerd --validate --config-file=/etc/docker/daemon.json
sudo systemctl restart docker   # 実行中のコンテナとDroneのビルドは止まります

```

   **一般ユーザーの作成と root ログインの無効化（推奨）:** root のまま運用すると、SSH への総当たり攻撃や操作ミスの被害が大きくなります。以降の作業は一般ユーザーで行います。

```bash
# 一般ユーザーを作成し、sudo / docker 権限を付与（ユーザー名は任意）
adduser kithub
usermod -aG sudo,docker kithub

# SSH公開鍵をコピー
rsync --archive --chown=kithub:kithub ~/.ssh /home/kithub

```

   **別のターミナルから** `ssh kithub@<VPSのIP>` でログインでき、`sudo` が使えることを確認してから、`/etc/ssh/sshd_config` を次のとおり変更します。

```
PermitRootLogin no
PasswordAuthentication no
```

```bash
sudo systemctl reload ssh

```

   ※ 公開鍵でのログイン確認前に設定すると、ログインできなくなります。以降の `~/dev-env` は、この一般ユーザーのホームディレクトリ配下に作成します。


2. **ディレクトリ構造作成と SSL (Caddy) の設定:** 所要時間: 約5分.
全サービスをまとめて管理するためのディレクトリを作成し、 Let's Encrypt 自動SSLに対応した **Caddy** の設定ファイルを用意します。

```bash
mkdir -p ~/dev-env/caddy ~/dev-env/gitea ~/dev-env/gitea-config ~/dev-env/drone ~/dev-env/ide ~/dev-env/flash
cd ~/dev-env

```

`caddy/Caddyfile` を作成します（`j-code.org` はお使いのドメインに書き換えてください）。`ide` と `flash` の静的ファイルは、Caddy が `/srv/ide`、`/srv/flash`（次の手順で `./ide`、`./flash` をマウント）から直接配信します。

```caddy
# Gitea (リポジトリ管理)
gitea.j-code.org {
    reverse_proxy gitea:3000
}

# Web IDE (クライアント型IDEの静的アセット配信)
ide.j-code.org {
    root * /srv/ide
    file_server
}

# Drone CI (自動ビルド)
drone.j-code.org {
    reverse_proxy drone:80
}

# ESP Web Tools (Web Serial 書き込みUI)
flash.j-code.org {
    root * /srv/flash
    file_server
}

```


3. **Docker Compose 設定ファイルの作成:** 所要時間: 約10分.
`~/dev-env/docker-compose.yml` を作成し、サーバーのリソース（メモリ）を消費しない構成を定義します。

```yaml
networks:
  dev-net:
    driver: bridge
    driver_opts:
      com.docker.network.driver.mtu: "1400"

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
      - ./ide:/srv/ide:ro
      - ./flash:/srv/flash:ro
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
      - GITEA__server__ROOT_URL=https://gitea.j-code.org/
      - GITEA__server__SSH_PORT=2222
    volumes:
      - ./gitea:/var/lib/gitea
      - ./gitea-config:/etc/gitea
    ports:
      - "2222:2222"
    networks:
      - dev-net

  # --- 自動ビルド (Drone CI) ---
  drone:
    image: drone/drone:2
    restart: always
    environment:
      - DRONE_GITEA_SERVER=https://gitea.j-code.org
      - DRONE_GITEA_CLIENT_ID=${GITEA_CLIENT_ID}
      - DRONE_GITEA_CLIENT_SECRET=${GITEA_CLIENT_SECRET}
      - DRONE_RPC_SECRET=${DRONE_RPC_SECRET}
      - DRONE_SERVER_HOST=drone.j-code.org
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
      - DRONE_RPC_HOST=drone.j-code.org
      - DRONE_RPC_SECRET=${DRONE_RPC_SECRET}
      - DRONE_RUNNER_CAPACITY=2  # 同時ビルド並列数を2件に絞りハングアップを防止
      - DRONE_RUNNER_NAME=vps-runner
      # パイプラインごとに作られるネットワークのMTUをホストNIC(1442)より小さくする
      - DRONE_RUNNER_NETWORK_OPTS=com.docker.network.driver.mtu:1400
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - dev-net

volumes:
  caddy_data:
  caddy_config:

```


4. **Gitea連携 & Drone OAuth設定:** 所要時間: 約10分.
1. 最初に Gitea と リバースプロキシを起動します。
Gitea (rootless イメージ) はUID 1000で動作するため、事前にデータディレクトリの所有者を変更しておかないと `/var/lib/gitea/git is not writable` で起動に失敗します。
Gitea の設定ファイルは `/etc/gitea/app.ini` に保存されるため、データとは別に `./gitea-config` へ永続化します。既存環境でこの設定を追加する場合は、Compose ファイルを更新してコンテナを再作成する前に、現在のコンテナから設定ファイルをコピーしてください。

```bash
cd ~/dev-env
sudo chown -R 1000:1000 ./gitea ./gitea-config
docker compose up -d gitea caddy

```

既存環境で `./gitea-config:/etc/gitea` のマウントを追加する場合は、上記の起動前に次を実行して、現在使われている設定をホストへ退避します（初回構築では不要です）。

```bash
docker cp "$(docker compose ps -q gitea)":/etc/gitea/app.ini ./gitea-config/app.ini
sudo chown 1000:1000 ./gitea-config/app.ini
```

2. ブラウザで `https://gitea.j-code.org` にアクセスし、初期管理者を作成します。
3. Gitea画面の右上アイコン > **[設定]** > **[アプリケーション]** > **[OAuth2アプリケーションの作成]** から以下を入力します。
* **アプリケーション名:** `Drone CI`
* **リダイレクトURI:** `https://drone.j-code.org/login`


4. 発行された **Client ID** と **Client Secret** を確認します。
5. `~/dev-env/.env` ファイルを作成して記載します。

```env
GITEA_CLIENT_ID=発行されたClient_ID
GITEA_CLIENT_SECRET=発行されたClient_Secret
DRONE_RPC_SECRET=任意で生成した文字列(openssl rand -hex 16 等)

```

6. 全サービスを一括起動します。`.env` が未作成のまま起動すると `drone` が起動せず、Caddy に `lookup drone ... server misbehaving`（502）のエラーが出ます。`.env` は Git にコミットしないでください。

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

* **検証:** Chromebookから `https://flash.j-code.org` にアクセスし、「Connect」ボタンからUSBシリアルポートが検出されることを確認します。


---

## 3. 本手順書に含まれない補足作業（簡易チェックリスト）

本インストールガイドの範囲外となる、事前・事後で必要となる周辺作業です。

* **1. ドメイン・DNSの設定**
* 外部DNS管理画面でサブドメイン4種（`gitea`, `ide`, `drone`, `flash`）の A レコードをVPSのパブリックIPへ紐付ける作業。


* **2. サーバー基本セキュリティ設定**
* ファイアウォール（`ufw`）による不要ポートの閉鎖（80, 443, 22番のみ許可）。
* Giteaの一般ユーザー自由登録（Sign-up）の無効化設定。初期構築中は許可したままでも構いませんが、管理者アカウントには強いパスワードを設定し、ユーザー登録が済んだら無効化してください。`docker-compose.yml` の `gitea` の `environment` に `GITEA__service__DISABLE_REGISTRATION=true` を追加し、`docker compose up -d gitea` を実行します。


* **3. リポジトリ用ビルド定義とマニフェスト作成**
* 生徒が利用する `.drone.yml`（C++コンパイル定義）の配備。
* ESP Web Tools書き込み用の `manifest.json`（バイナリ配置URL等の定義）の用意。


* **4. Google SSO連携設定（オプション）**
* Google Cloud Console上でのOAuth同意画面・クライアントIDの作成とGitea側への登録。


* **5. バックアップ・保守管理**
* Giteaデータディレクトリ（`~/dev-env/gitea`）の定時バックアップCron作成。



---