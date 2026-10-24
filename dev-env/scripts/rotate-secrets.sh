#!/usr/bin/env bash
# 引っ越し後の新サーバーで、旧サーバーと共有していたパスワード・トークンをすべて新しいものに入れ替える。
# restore.sh の後、DNS 切り替え (go-live.sh) の前に1回実行する。新規構築では不要 (init-gitea.sh が新規に生成する)。
# 使い方: rotate-secrets.sh
# 事前に .r2.env の R2_STORAGE_* を、Cloudflare で新しく発行した gitea-storage 用トークンに書き換えておくこと。
# 環境変数: GITEA_ADMIN_USER (既定 gitea-admin)
# 入れ替えるもの: DB パスワード / gitea-admin のパスワード / gitea-storage の R2 トークン / Gitea の内部トークン類
# (act_runner の登録トークンは go-live.sh が新しく発行する)
# 入れ替えないもの: SECRET_KEY (暗号化済みのデータが読めなくなるため)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_docker

ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
cd "$DEV_ENV_DIR"
INI=gitea-config/app.ini

rand() { openssl rand -base64 "$1" | tr -d '/+=\n'; }
set_env() { # .env の値を書き換える (無ければ追加する)
  sed -i "/^$1=/d" .env
  echo "$1=$2" >> .env
}
set_ini() { # app.ini の既存キーの値を書き換える
  sudo sed -i "s|^$1 *=.*|$1 = $2|" "$INI"
}

DB_PASSWORD="$(rand 24 | cut -c1-24)"
ADMIN_PASS="$(rand 24 | cut -c1-20)"

# 1) DB パスワード。既存の DB は環境変数では変わらないため、SQL で変更してから設定ファイルを合わせる
docker compose up -d db
until docker compose exec -T db pg_isready -h 127.0.0.1 -U gitea -d gitea >/dev/null 2>&1; do sleep 2; done
docker compose exec -T db psql -U gitea -d gitea -c "ALTER USER gitea PASSWORD '$DB_PASSWORD'" >/dev/null
set_env DB_PASSWORD "$DB_PASSWORD"
# 旧い docker-compose.yml (パスワード直書き) でも、.env を参照する形に直す
sed -i -E 's|(POSTGRES_PASSWORD=)[^ ]+|\1${DB_PASSWORD}|; s|(GITEA__database__PASSWD=)[^ ]+|\1${DB_PASSWORD}|' docker-compose.yml
set_ini PASSWD "$DB_PASSWORD"

# 2) gitea-storage の R2 トークン (.r2.env に書いた新しい値を app.ini に反映する)
if grep -q '^\[storage\]' "$INI" && [ -n "${R2_STORAGE_ACCESS_KEY_ID:-}" ]; then
  set_ini MINIO_ACCESS_KEY_ID "$R2_STORAGE_ACCESS_KEY_ID"
  set_ini MINIO_SECRET_ACCESS_KEY "$R2_STORAGE_SECRET_ACCESS_KEY"
else
  echo "注意: gitea-storage のトークンは更新していません (.r2.env に R2_STORAGE_* が無いか、app.ini に [storage] がありません)" >&2
fi

# 3) Gitea の内部トークン類。Gitea が自動生成する形式で作り直す
INTERNAL_TOKEN="$(docker compose exec -T gitea gitea generate secret INTERNAL_TOKEN | tr -d '\r\n')"
set_ini INTERNAL_TOKEN "$INTERNAL_TOKEN"
set_ini JWT_SECRET "$(docker compose exec -T gitea gitea generate secret JWT_SECRET | tr -d '\r\n')"
set_ini LFS_JWT_SECRET "$(docker compose exec -T gitea gitea generate secret LFS_JWT_SECRET | tr -d '\r\n')"

# 4) 新しい設定で再作成する (act_runner は go-live.sh が起動する)
docker compose up -d db gitea caddy
docker compose restart gitea
echo "Gitea の起動を待っています"
for _ in $(seq 1 60); do
  docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null 2>&1 && break
  sleep 5
done
docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null

# 5) 管理者のパスワード
docker compose exec -T gitea gitea admin user change-password \
  --username "$ADMIN_USER" --password "$ADMIN_PASS"

cat <<EOF

入れ替え完了。次の情報は、この画面でしか表示されません。パスワードマネージャーに保存してください。
  Gitea 管理者 : $ADMIN_USER
  パスワード   : $ADMIN_PASS
(DB パスワードなどは $DEV_ENV_DIR/.env に保存されています。.env は backup.sh で R2 に保存されます)
旧サーバーで使っていた R2 トークンは、切り替えの確認が終わってから Cloudflare で無効化してください。
EOF
