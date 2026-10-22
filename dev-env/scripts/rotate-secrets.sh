#!/usr/bin/env bash
# 引っ越し後の新サーバーで、旧サーバーと共有していたパスワード・トークンをすべて新しいものに入れ替える。
# restore.sh の後、DNS 切り替え (go-live.sh) の前に1回実行する。新規構築では不要 (init-gitea.sh が新規に生成する)。
# 使い方: rotate-secrets.sh
# 事前に .r2.env の R2_STORAGE_* を、Cloudflare で新しく発行した gitea-storage 用トークンに書き換えておくこと。
# 環境変数: GITEA_ADMIN_USER (既定 gitea-admin)
# 入れ替えるもの: DB パスワード / Drone の RPC シークレット / Drone の OAuth シークレット /
#                 gitea-admin のパスワード / gitea-storage の R2 トークン / Gitea の内部トークン類
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
DRONE_RPC_SECRET="$(openssl rand -hex 16)"
ADMIN_PASS="$(rand 24 | cut -c1-20)"

# 1) DB パスワード。既存の DB は環境変数では変わらないため、SQL で変更してから設定ファイルを合わせる
docker compose up -d db
until docker compose exec -T db pg_isready -h 127.0.0.1 -U gitea -d gitea >/dev/null 2>&1; do sleep 2; done
docker compose exec -T db psql -U gitea -d gitea -c "ALTER USER gitea PASSWORD '$DB_PASSWORD'" >/dev/null
set_env DB_PASSWORD "$DB_PASSWORD"
# 旧い docker-compose.yml (パスワード直書き) でも、.env を参照する形に直す
sed -i -E 's|(POSTGRES_PASSWORD=)[^ ]+|\1${DB_PASSWORD}|; s|(GITEA__database__PASSWD=)[^ ]+|\1${DB_PASSWORD}|' docker-compose.yml
set_ini PASSWD "$DB_PASSWORD"

# 2) Drone と drone-runner が共有する RPC シークレット
set_env DRONE_RPC_SECRET "$DRONE_RPC_SECRET"

# 3) gitea-storage の R2 トークン (.r2.env に書いた新しい値を app.ini に反映する)
if grep -q '^\[storage\]' "$INI" && [ -n "${R2_STORAGE_ACCESS_KEY_ID:-}" ]; then
  set_ini MINIO_ACCESS_KEY_ID "$R2_STORAGE_ACCESS_KEY_ID"
  set_ini MINIO_SECRET_ACCESS_KEY "$R2_STORAGE_SECRET_ACCESS_KEY"
else
  echo "注意: gitea-storage のトークンは更新していません (.r2.env に R2_STORAGE_* が無いか、app.ini に [storage] がありません)" >&2
fi

# 4) Gitea の内部トークン類。Gitea が自動生成する形式で作り直す
INTERNAL_TOKEN="$(docker compose exec -T gitea gitea generate secret INTERNAL_TOKEN | tr -d '\r\n')"
set_ini INTERNAL_TOKEN "$INTERNAL_TOKEN"
set_ini JWT_SECRET "$(docker compose exec -T gitea gitea generate secret JWT_SECRET | tr -d '\r\n')"
set_ini LFS_JWT_SECRET "$(docker compose exec -T gitea gitea generate secret LFS_JWT_SECRET | tr -d '\r\n')"

# 5) 新しい設定で再作成する (drone-runner は go-live.sh が起動する)
docker compose up -d db gitea drone caddy
docker compose restart gitea
echo "Gitea の起動を待っています"
for _ in $(seq 1 60); do
  docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null 2>&1 && break
  sleep 5
done
docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null

# 6) 管理者のパスワード
docker compose exec -T gitea gitea admin user change-password \
  --username "$ADMIN_USER" --password "$ADMIN_PASS"

# 7) Drone の OAuth アプリを作り直し、新しい ID / シークレットを .env に書く
NET="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(docker compose ps -q gitea)")"
api() { docker run --rm --network "$NET" curlimages/curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" -H 'Content-Type: application/json' "$@"; }
DRONE_HOST="$(grep -oP 'DRONE_SERVER_HOST=\K\S+' docker-compose.yml)"
for id in $(api http://gitea:3000/api/v1/user/applications/oauth2 | python3 -c 'import sys,json; [print(a["id"]) for a in json.load(sys.stdin) if a["name"]=="Drone CI"]'); do
  api -X DELETE "http://gitea:3000/api/v1/user/applications/oauth2/$id"
done
RES="$(api -d "{\"name\":\"Drone CI\",\"redirect_uris\":[\"https://$DRONE_HOST/login\"],\"confidential_client\":true}" http://gitea:3000/api/v1/user/applications/oauth2)"
read -r CID CSECRET < <(echo "$RES" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["client_id"], d["client_secret"])')
set_env GITEA_CLIENT_ID "$CID"
set_env GITEA_CLIENT_SECRET "$CSECRET"
docker compose up -d drone

cat <<EOF

入れ替え完了。次の情報は、この画面でしか表示されません。パスワードマネージャーに保存してください。
  Gitea 管理者 : $ADMIN_USER
  パスワード   : $ADMIN_PASS
(DB パスワードなどは $DEV_ENV_DIR/.env に保存されています。.env は backup.sh で R2 に保存されます)
旧サーバーで使っていた R2 トークンは、切り替えの確認が終わってから Cloudflare で無効化してください。
EOF
