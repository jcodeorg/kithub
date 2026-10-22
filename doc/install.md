# 🛠️ **【構築・引っ越し手順書】Chromebook向けブラウザ開発環境 VPSセットアップガイド**

新規構築も引っ越しも、人手が必要なのは **R2 のトークン作成・VPS の契約・DNS の変更・パスワードの保管** だけです。それ以外はスクリプト（[dev-env/scripts/](../dev-env/scripts)）が行います。

| 作業 | 担当 |
|---|---|
| R2 バケット・トークンの作成、VPS 契約、パケットフィルター、DNS 変更 | 人 |
| 一般ユーザー作成 | `create-user.sh` |
| Docker / MTU / スワップ / R2 マウント / 設定ファイル配置 / SSH 保護 | `bootstrap.sh` |
| Gitea 起動、管理者作成、Drone の OAuth 作成、全サービス起動（新規のみ） | `init-gitea.sh` |
| バックアップ / 復元（引っ越しのみ） | `backup.sh` / `restore.sh` |
| パスワード・トークンの入れ替え（引っ越しのみ） | `rotate-secrets.sh` |
| DNS 反映待ち、drone-runner 起動、疎通確認（引っ越しのみ） | `go-live.sh` |

**目安時間:** 新規構築 約30分 / 引っ越し 約40分（DNS の TTL を下げる待ち時間を除く）

---

## 1. 動作環境

* **VPS:** XServer VPS（4コア / 4GB RAM 以上、Ubuntu 24.04 LTS、「Docker」セットアップスクリプトを選択）
* **ユーザー名:** OS の一般ユーザーは `kithub`、Gitea の管理者アカウントは `gitea-admin`
* **ドメイン（A レコードを VPS の IP に向ける）:** `gitea.j-code.org`（Gitea）/ `drone.j-code.org`（Drone CI）/ `users.j-code.org`（CI成果物の配信）。`ide` / `flash` を使う場合はそれも。
* **構成:** 公開成果物（`pages`）は Cloudflare R2 を s3fs でマウントし、VPS の容量を使いません。Gitea の添付ファイル・アバター・LFS などは `gitea-storage` バケットに保存します。リポジトリ本体・Drone・DB は VPS に置き、`backup.sh` で R2（`gitea-backup`）に保存します。

---

## 2. 事前準備（人手。目安 約15分）

1. **R2 のバケットとトークンを作る（Cloudflare ダッシュボード）**
   * バケットは次の 3 つを使います（すべて非公開）。

     | バケット | 用途 |
     |---|---|
     | `gitea-pages` | 公開成果物（users.j-code.org）。s3fs で `~/dev-env/pages` にマウント |
     | `gitea-backup` | `backup.sh` の保存先 |
     | `gitea-storage` | Gitea の添付ファイル・アバター・LFS などの保存先（Gitea の `[storage]`、MinIO 互換。リポジトリ本体と DB は VPS に置く） |

   * **`gitea-pages`** 用に、そのバケットだけに限定した **Object Read & Write** トークン（既存なら不要）。
   * **`gitea-backup`** 用に、そのバケットだけに限定した **Object Read & Write** トークン。pages 用とは別のトークンにしてください。バックアップには `.env` や `app.ini` の秘密情報が含まれます。
   * **`gitea-storage`** 用に、そのバケットだけに限定した **Object Read & Write** トークン。**引っ越しでは、新サーバー専用に新しく発行してください**（旧サーバーのトークンは、切り替え確認後に無効化できるようにするため）。pages / backup も、引っ越しでは新サーバー用に新しいトークンを発行すると、旧サーバーと秘密情報を共有せずに済みます。
   * アカウント ID と、上の 3 組の Access Key ID / Secret Access Key を手元に控えます。
2. **VPS を契約し、パケットフィルターを設定する**（Xserver VPS では「パケットフィルター設定」でルールを作成し、**サーバーに適用**する。作成しただけでは有効になりません）。
   * **TCP 80 / 443 を全体に許可**: 80 番が塞がっていると、Caddy が Let's Encrypt の証明書を取得できません。
   * **TCP 22（SSH）は、管理者の IP アドレスだけに許可**（IP フィルタ）。Xserver VPS のパケットフィルターは、送信元 IP を指定できるルールで設定します。自宅・学校など固定の IP を控えておきます。
   * **TCP 2222 は許可しない（閉じる）**。Git の SSH は使わず、HTTPS のみで運用します（`docker-compose.yml` で Gitea の SSH を無効化し、ポートも公開していません）。
   * 自分の IP が変わると SSH できなくなります。その場合は、Xserver の管理画面のコンソール（VNC）からログインするか、パケットフィルターの IP を更新してください。
3. **SSH 公開鍵を VPS に登録する**（契約時の鍵設定、または root で `~/.ssh/authorized_keys`）。
4. **（引っ越しのみ）DNS の TTL を下げる:** 切り替えるレコードの TTL を 300 秒以下にし、元の TTL が経過するまで待ちます（目安: 半日〜1日前）。
5. **（新規構築のみ）DNS の A レコードを、新しい VPS の IP に向ける。** 引っ越しでは、この作業は 5-3 で行います。
6. このリポジトリの変更は、先に `git push` しておいてください（スクリプトは GitHub の `main` から取得します）。

---

## 3. サーバーのセットアップ（新規・引っ越し共通。新しい VPS で行う。目安 約10分）

1. **root でログインし、一般ユーザー `kithub` を作る**（sudo / docker 権限と SSH 公開鍵を引き継ぎます）。

```bash
curl -fsSL https://raw.githubusercontent.com/jcodeorg/kithub/main/dev-env/scripts/create-user.sh | bash
```

2. **別のターミナルから `ssh kithub@<VPSのIP>` でログイン**し、`.r2.env` を作ってセットアップを実行します。`--harden-ssh` が root ログインとパスワード認証を無効にします（`kithub` で公開鍵ログインできていることが前提です）。

```bash
sudo apt-get update && sudo apt-get install -y git
git clone --depth 1 https://github.com/jcodeorg/kithub.git ~/kithub-repo
mkdir -p ~/dev-env
cat > ~/dev-env/.r2.env <<'EOF'
R2_ACCOUNT_ID=<アカウントID>
R2_PAGES_BUCKET=gitea-pages
R2_PAGES_ACCESS_KEY_ID=<pages用トークンのAccess Key ID>
R2_PAGES_SECRET_ACCESS_KEY=<pages用トークンのSecret Access Key>
R2_BACKUP_BUCKET=gitea-backup
R2_BACKUP_ACCESS_KEY_ID=<バックアップ用トークンのAccess Key ID>
R2_BACKUP_SECRET_ACCESS_KEY=<バックアップ用トークンのSecret Access Key>
R2_STORAGE_BUCKET=gitea-storage
R2_STORAGE_ACCESS_KEY_ID=<storage用トークンのAccess Key ID>
R2_STORAGE_SECRET_ACCESS_KEY=<storage用トークンのSecret Access Key>
EOF
chmod 600 ~/dev-env/.r2.env
bash ~/kithub-repo/dev-env/scripts/bootstrap.sh --harden-ssh
```

`bootstrap.sh` は何度実行しても安全です。OS のパッケージも最新に更新します。終了時に「再起動してください」と表示されたら、`sudo reboot` で再起動し、再ログインしてから次へ進みます（R2 のマウントと Docker は自動で復帰します）。R2 が `fuse.s3fs` としてマウントできないときは、エラーで止まります（マウントできない状態では Docker を起動させない設定も入ります）。

3. **次へ進む:** 新規構築なら「4」、引っ越しなら「5」へ。

---

## 4. 新規構築（目安 約5分）

DNS が新しい VPS を向いたことを確認してから、次を実行します。

```bash
bash ~/dev-env/scripts/init-gitea.sh
```

Gitea を起動し、管理者 `gitea-admin` と Drone 用の OAuth アプリを作成して、全サービスを起動します。DB パスワードと Drone の RPC シークレットは、ここでランダムに生成されて `~/dev-env/.env` に保存されます（`docker-compose.yml` に直書きしません）。**最後に表示される管理者パスワードは、この画面でしか表示されません。** パスワードマネージャーに保存してください。

**動作確認**
* `https://gitea.j-code.org` に `gitea-admin` でログインできる。
* `https://drone.j-code.org` で「Gitea でログイン」でき、リポジトリの Sync が成功する。
* 管理者のメールアドレスを変える場合は、`GITEA_ADMIN_EMAIL=...` を付けて実行します。

続いて「6. 運用」へ。

---

## 5. 引っ越し（旧 VPS → 新 VPS、R2 経由。目安 約30分）

**前提**
* 旧・新どちらも Gitea の管理者は `gitea-admin` とします。名前は DB ごと引き継がれるため、旧サーバーの管理者名が違う場合は、バックアップ前に Gitea の「サイト管理 → ユーザーアカウント」で変更しておいてください。
* `pages`（公開成果物）と `gitea-storage`（添付・アバター・LFS など）は R2 にあるため、コピー不要です。新サーバーは同じバケットを使います。`gitea-storage` の接続情報は `app.ini` の `[storage]` に入っており、`backup.sh` / `restore.sh` で引き継がれます（旧サーバーの `.r2.env` に storage の項目は不要）。ただし旧サーバーと同じ秘密情報になるため、5-3 の `rotate-secrets.sh` で入れ替えます。
* 引き継がれないもの: Drone のビルドキャッシュ（初回ビルドだけ遅くなります）、Docker イメージ（自動で再取得されます）。

### 5-1. 旧サーバーの準備（サービスを止めずにできる）

旧サーバーにも、スクリプトと `.r2.env`（バックアップ用の 3 項目だけ）を用意します。

```bash
sudo apt-get update && sudo apt-get install -y git rclone
git clone --depth 1 https://github.com/jcodeorg/kithub.git ~/kithub-repo
mkdir -p ~/dev-env && cp -r ~/kithub-repo/dev-env/scripts ~/dev-env/
cat > ~/dev-env/.r2.env <<'EOF'
R2_ACCOUNT_ID=<アカウントID>
R2_BACKUP_BUCKET=gitea-backup
R2_BACKUP_ACCESS_KEY_ID=<バックアップ用トークンのAccess Key ID>
R2_BACKUP_SECRET_ACCESS_KEY=<バックアップ用トークンのSecret Access Key>
EOF
chmod 600 ~/dev-env/.r2.env
```

### 5-2. リハーサル（任意だが推奨。旧サーバーが数分止まり、終了後に自動で再開する）

```bash
# 旧サーバー
bash ~/dev-env/scripts/backup.sh

# 新サーバー (DNS はまだ変更しない)
bash ~/dev-env/scripts/restore.sh
curl -fsS --resolve gitea.j-code.org:443:<新サーバーのIP> https://gitea.j-code.org/api/healthz
```

確認できたら、本番で `restore.sh --force` を使い、新サーバーのデータを消してやり直します。リハーサルを省略する場合は、`--force` なしで 5-3 へ進みます。

### 5-3. 本番の切り替え（ここから旧サーバーが止まる）

1. **旧サーバー**: 最終バックアップを取ります。完了後も旧サーバーのサービスは停止したままになります（再開しないでください）。

```bash
bash ~/dev-env/scripts/backup.sh --final
```

2. **新サーバー**: 復元します。最後に管理者の一覧が表示されるので、`gitea-admin` があることを確認します（リハーサル済みなら `--force` を付けます）。

```bash
bash ~/dev-env/scripts/restore.sh
```

3. **新サーバー**: パスワード・トークンを新しいものに入れ替えます。DNS 変更の前に行うため、旧サーバーにも利用者にも影響しません。

```bash
bash ~/dev-env/scripts/rotate-secrets.sh
```

   入れ替わるもの: DB パスワード / Drone の RPC シークレットと OAuth シークレット / `gitea-admin` のパスワード / `gitea-storage` の R2 トークン（`~/dev-env/.r2.env` の `R2_STORAGE_*` の値を `app.ini` に反映）/ Gitea の `INTERNAL_TOKEN`・`JWT_SECRET`・`LFS_JWT_SECRET`。
   * **新しい `gitea-storage` のトークンを、先に `.r2.env` に書いておいてください**（3 章で記入済みなら不要）。
   * **最後に表示される新しい管理者パスワードは、この画面でしか表示されません。** パスワードマネージャーに保存してください。
   * `SECRET_KEY` は、暗号化済みのデータが読めなくなるため入れ替えません。
   * Drone は OAuth が作り直されるため、全員が一度ログインし直します。

4. **DNS を変更（人手）:** `gitea` / `drone` / `users` と、使っていれば `ide` / `flash` の A レコードを新サーバーの IP に変更します。
5. **新サーバー:** DNS の反映を待って、drone-runner の起動と疎通確認までを行います（旧 IP のまま起動すると、旧サーバーの Drone に接続してしまうため、スクリプトが反映を確認してから起動します）。

```bash
bash ~/dev-env/scripts/go-live.sh
```

6. **確認:** `https://drone.j-code.org` で Sync が成功し、テスト用リポジトリの push でビルドが通り、`https://users.j-code.org/<オーナー名>/<リポジトリ名>/latest/` が更新されること。
7. **後片付け:** DNS の TTL を元に戻します。旧サーバーは、問題がないと確認できてから 1 週間ほど停止したまま残し、その後に解約します。**Cloudflare で、旧サーバーが使っていた R2 のトークン（pages / backup / storage）を無効化します。** 旧サーバーを解約する前に、旧サーバーのディスクや `~/dev-env/.env`・`app.ini` に残る古い秘密情報も消去されることを確認してください（解約時にディスクは破棄されます）。
8. 続いて「6. 運用」の定時バックアップを、新サーバーで設定します。

### 5-4. 戻す場合

DNS を旧サーバーの IP に戻し、旧サーバーで `cd ~/dev-env && docker compose start gitea drone drone-runner` を実行します。新サーバーで書き込まれたデータは、旧サーバーには反映されません。

---

## 6. 運用

### 6-1. 定時バックアップ（推奨）

毎日 4:00 に R2 へバックアップします（新しい 7 世代を保持）。実行中は Gitea と Drone が数分止まります。`crontab -e` に次を追加します。

```cron
0 4 * * * $HOME/dev-env/scripts/backup.sh >> $HOME/backup.log 2>&1
```

### 6-2. 生徒向けの設定

* 生徒が使う `.drone.yml` は [templates/esp32-arduino/.drone.yml](../templates/esp32-arduino/.drone.yml) をリポジトリ直下にコピーします（変更不要）。`/publish` は R2 をマウントした `~/dev-env/pages`、`/ci-cache` は VPS の `~/dev-env/cache` に保存されます。
* CI成果物は `https://users.j-code.org/<オーナー名>/<リポジトリ名>/latest/`（ブランチ push 時）または `https://users.j-code.org/<オーナー名>/<リポジトリ名>/<タグ>/`（タグ時）で配信されます。
* R2 はオブジェクトストレージで、ローカルファイルシステムと同じ原子性・遅延特性ではありません。s3fs のアップロード中の一時ファイル、ビルドキャッシュ、Docker イメージやログは VPS の容量を使います。定期的に VPS の空き容量と R2 の利用状況を確認してください。

### 6-3. Gitea の一般ユーザー登録

`docker-compose.yml` の `gitea` の `environment` に `GITEA__service__DISABLE_REGISTRATION=true` を追加し、`docker compose up -d gitea` で無効化できます。Google SSO を使う場合は、下の「6-4」の設定を使い、この環境変数は設定しないでください（環境変数が `app.ini` より優先され、Google 経由の登録も止まります）。

### 6-4. Google SSO 連携（オプション）

Gitea のログイン／アカウント作成に Google アカウントを使えるようにします。コンテナの変更は不要です。

* **(1) Google Cloud Console**
  1. 「APIとサービス → OAuth 同意画面」を設定します。学校の Google Workspace に限定する場合はユーザーの種類を「内部」、一般の Gmail も許可する場合は「外部」にします。
  2. 「認証情報 → 認証情報を作成 → OAuth クライアント ID」で、種類を「ウェブ アプリケーション」にします。
  3. 「承認済みのリダイレクト URI」に `https://gitea.j-code.org/user/oauth2/google/callback` を登録します（`google` は (2) の認証名と一致させる）。
  4. 表示されたクライアント ID とクライアント シークレットを控えます。
* **(2) Gitea 管理画面**
  1. 管理者で「サイト管理 → 認証ソース → 認証ソースを追加」を開きます。
  2. 認証タイプ `OAuth2`、認証名 `google`、OAuth2 プロバイダー `Google` を選び、クライアント ID とシークレットを入力して保存します。
  3. ログイン画面に「Google でサインイン」が表示されることを確認します。
* **(3) `app.ini` の調整**
  `~/dev-env/gitea-config/app.ini` に追記し、`docker compose restart gitea` で反映します。初回ログイン時に、生徒が自分でユーザー名を入力する構成です（Gitea 1.21 では、Google 登録後のユーザー名は変更できないため）。

```ini
[oauth2_client]
; 自動登録を行わず、初回ログイン時に登録画面でユーザー名を入力させる
ENABLE_AUTO_REGISTRATION = false
; 既存アカウントにひも付ける場合はログインを要求する
ACCOUNT_LINKING = login
; Google のプロフィール画像を同期する（不要なら false）
UPDATE_AVATAR = true

[service]
; Google 経由の登録だけ許可する（DISABLE_REGISTRATION は true にしない）
DISABLE_REGISTRATION = false
ALLOW_ONLY_EXTERNAL_REGISTRATION = true
```

* **(4) ユーザー名を間違えた場合（生徒自身でやり直し）**
  Gitea 1.21 では、Google 登録（外部）ユーザーのユーザー名は、本人も管理者も変更できません。次の手順でアカウントを削除し、作り直します。
  1. 間違えたアカウントでログインし、「設定 → アカウント」でパスワードを設定します（Google 登録のアカウントはパスワードが未設定のため、設定しないと削除できません）。
  2. 同じ画面の「アカウントを削除」で、設定したパスワードを入力して削除します。
  3. もう一度「Google でサインイン」を押し、正しいユーザー名で登録します。
  * 削除できるのは、リポジトリ・組織・パッケージを持たない場合のみです。リポジトリがある場合は、先に削除または移管してください。管理者アカウントは自分では削除できません。
  * 授業の最初に、ログインとユーザー名の登録だけを済ませる時間を取り、命名規則（学籍番号など）を事前に周知すると、やり直しを減らせます。
* **注意:** 「外部」で公開すると、誰でもアカウントを作成できます。利用者を限定する場合は、Workspace の「内部」を使ってください。Drone は Gitea の OAuth2 でログインするため、この設定の影響を受けません。

### 6-5. ESP32 書き込みツール（ESP Web Tools。オプション）

Web Serial API で、Chromebook から USB 経由で ESP32 にワンクリック書き込みするための静的ページです。使う場合は、次を行います。

1. `~/dev-env/caddy/Caddyfile` に `flash.j-code.org { root * /srv/flash; file_server }`（`flash.j-code.org` の A レコードも追加）を追記し、`docker-compose.yml` の caddy の `volumes` に `./flash:/srv/flash:ro` を追加して、`docker compose up -d caddy` を実行します。
2. 次の内容を `~/dev-env/flash/index.html` として保存します。

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

3. **検証:** Chromebook から `https://flash.j-code.org` にアクセスし、「Connect」ボタンから USB シリアルポートが検出されることを確認します。`flash` は `backup.sh` の対象に含まれます。

### 6-6. トラブルシューティング: Drone のビルドが外部（GitHub など）に接続できない

コンテナから外へ通信できない場合の確認手順です（`bootstrap.sh` で設定済みのため、通常は不要です）。

1. **疎通テスト:** 成功すれば `connected` と `200 OK` / `301` が返ります。成功したら、Drone の画面から Re-run します。

```bash
docker exec -it dev-env-drone-runner-1 wget --spider --timeout=5 https://github.com
```

2. **IP フォワーディング:** `cat /proc/sys/net/ipv4/ip_forward` が `1` でなければ、次を実行します。

```bash
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-kithub.conf
sudo sysctl --system
```

3. **UFW:** `sudo ufw status verbose` が「非アクティブ」なら問題ありません。有効な場合は、Docker からの外向き通信を破棄していないか確認します。
4. **Docker の再起動:** 転送ルールを再適用させるため、`sudo systemctl restart docker` を実行します。その後、`cd ~/dev-env && docker compose up -d` で、コンテナを起動し直します。
5. 手動の `iptables -t nat ... MASQUERADE` 追加は、通常は不要です。Docker が自動で設定します。
6. それでも通信が不安定（大きなデータだけ失敗する）な場合は、MTU が原因の可能性があります。`daemon.json`、`dev-env` の `dev-net`、`DRONE_RUNNER_NETWORK_OPTS` の 3 か所を、同じ値（1400）にそろえてください。

### 6-7. アップグレード方針

* **OS:** `bootstrap.sh` を再実行すると、OS のパッケージを更新します（`sudo reboot` が必要な場合は表示されます）。月 1 回程度、授業のない時間帯に実施してください。
* **コンテナ:** 引っ越しと同時には行わず、移行が安定してから別の作業として行います。
  * 現在のバージョン: Gitea `1.21-rootless`（開発が終了した古い系列です。計画的に新しい版へ更新してください）、PostgreSQL `15`、Drone `2`、Caddy `2`。
  * 手順: ①`backup.sh` を実行 ② `docker-compose.yml` の `image:` を 1 つずつ変更（Gitea は 1 マイナー版ずつ、リリースノートの破壊的変更を確認）③`docker compose pull && docker compose up -d` ④動作確認（ログイン・push・ビルド）。問題があれば、バックアップから `restore.sh --force` で戻せます。
  * PostgreSQL のメジャー版（15 → 16 など）は、データの互換性がないため、`docker-compose.yml` のタグを変えるだけでは更新できません。`pg_dump` と `pg_restore` による移行が必要です。
