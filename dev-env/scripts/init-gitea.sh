#!/usr/bin/env bash
# 新規構築用。Gitea を起動し、管理者アカウントを作成して、Actions runner を含む全サービスを起動する。
# 引っ越しのときは使わない (restore.sh を使う)。bootstrap.sh の後、DNS が新サーバーを向いた状態で実行する。
# 使い方: init-gitea.sh
# 環境変数: GITEA_ADMIN_USER (既定 gitea-admin) / GITEA_ADMIN_EMAIL (既定 <ユーザー名>@<ドメイン>)
set -euo pipefail

DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/dev-env}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
cd "$DEV_ENV_DIR"

# docker-compose.yml の Gitea のドメインから、ドメインを求める
GITEA_HOST="$(grep -oP 'GITEA__server__DOMAIN=\K\S+' docker-compose.yml)"
DOMAIN="${GITEA_HOST#*.}"
ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-$ADMIN_USER@$DOMAIN}"

# 構築済みのデータを誤って壊さないよう、既存の環境では中止する
if [ -e .env ] || [ -n "$(sudo ls -A gitea 2>/dev/null)" ]; then
  echo "すでに構築済みです。やり直す場合は docker compose down -v のあと gitea / gitea-config / postgres_data / .env を削除してください" >&2
  exit 1
fi

# データ用ディレクトリを作る (Gitea コンテナは UID 1000 で動くため所有者を合わせる)
mkdir -p gitea gitea-config act_runner/data
sudo chown -R 1000:1000 gitea gitea-config
# .env を作る。runner 登録トークンは Gitea 起動後に書き込む
(umask 077; cat > .env <<EOF
GITEA_RUNNER_REGISTRATION_TOKEN=
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
DEV_ENV_DIR=$DEV_ENV_DIR
EOF
)

# まず DB・Gitea・Caddy だけ起動し、Gitea が応答するまで待つ (最大5分)
docker compose up -d db gitea caddy
echo "Gitea の起動を待っています"
for _ in $(seq 1 60); do
  docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null 2>&1 && break
  sleep 5
done
docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null

# .r2.env に gitea-storage の設定があれば、Gitea の添付・アバター・LFS などの保存先を R2 にする
# (app.ini は初回起動で生成されるため、起動後に [storage] を追記して再起動する)
. "$(dirname "$0")/lib.sh"
if [ -n "${R2_STORAGE_BUCKET:-}" ]; then
  sudo tee -a gitea-config/app.ini >/dev/null <<EOF

[storage]
STORAGE_TYPE = minio
MINIO_ENDPOINT = $R2_ACCOUNT_ID.r2.cloudflarestorage.com
MINIO_ACCESS_KEY_ID = $R2_STORAGE_ACCESS_KEY_ID
MINIO_SECRET_ACCESS_KEY = $R2_STORAGE_SECRET_ACCESS_KEY
MINIO_BUCKET = $R2_STORAGE_BUCKET
MINIO_LOCATION = auto
MINIO_USE_SSL = true
EOF
  docker compose restart gitea
  for _ in $(seq 1 60); do
    docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null 2>&1 && break
    sleep 5
  done
fi

# ランダムなパスワードで管理者アカウントを作成する
PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
docker compose exec -T gitea gitea admin user create --admin \
  --username "$ADMIN_USER" --password "$PASS" --email "$ADMIN_EMAIL" --must-change-password=false

# act_runner の登録トークンを発行して .env に書き込む
TOKEN="$(docker compose exec -T gitea gitea actions generate-runner-token | tr -d '\r\n')"
sed -i "s|^GITEA_RUNNER_REGISTRATION_TOKEN=.*|GITEA_RUNNER_REGISTRATION_TOKEN=$TOKEN|" .env

# 残りのサービス (act_runner など) を .env の値で起動する
docker compose up -d
docker compose ps

# 管理者の情報を表示する (再表示はできない)
cat <<EOF

構築完了。管理者の情報は次のとおりです。この画面でしか表示されないため、パスワードマネージャーに保存してください。
  URL      : https://gitea.$DOMAIN
  ユーザー : $ADMIN_USER
  パスワード: $PASS
EOF
