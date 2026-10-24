#!/usr/bin/env bash
# 引っ越しの仕上げ。DNS が このサーバーを向くまで待ち、act_runner を登録・起動して動作を確認する。
# restore.sh の後、DNS を変更してから実行する。
# 使い方: go-live.sh   (DOMAIN で既定の j-code.org を変更できる)
set -euo pipefail

DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/dev-env}"
DOMAIN="${DOMAIN:-j-code.org}"
cd "$DEV_ENV_DIR"

# このサーバーのグローバル IP を調べる
MYIP="$(curl -4 -fsS https://api.ipify.org)"
echo "このサーバーの IP: $MYIP。DNS の反映を待っています (最大1時間)"

# 2つのホスト名が、どちらもこのサーバーの IP に解決されるまで待つ
for h in gitea users; do
  for _ in $(seq 1 360); do
    [ "$(getent ahostsv4 "$h.$DOMAIN" | awk 'NR==1{print $1}')" = "$MYIP" ] && break
    sleep 10
  done
  if [ "$(getent ahostsv4 "$h.$DOMAIN" | awk 'NR==1{print $1}')" != "$MYIP" ]; then
    echo "$h.$DOMAIN が $MYIP を向いていません。DNS の設定を確認してください" >&2
    exit 1
  fi
  echo "OK: $h.$DOMAIN -> $MYIP"
done

# 新しいトークンで runner を登録し直す。旧サーバーのジョブを奪わないよう、DNS の反映後に起動する
TOKEN="$(docker compose exec -T gitea gitea actions generate-runner-token | tr -d '\r\n')"
sed -i '/^GITEA_RUNNER_REGISTRATION_TOKEN=/d' .env
echo "GITEA_RUNNER_REGISTRATION_TOKEN=$TOKEN" >> .env
docker compose up -d act_runner

# HTTPS 経由で Gitea が応答することを確認する (証明書の取得待ちを含め最大5分)
for _ in $(seq 1 30); do
  curl -fsS "https://gitea.$DOMAIN/api/healthz" >/dev/null 2>&1 && break
  sleep 10
done
curl -fsS "https://gitea.$DOMAIN/api/healthz" >/dev/null
docker compose ps
echo "切り替え完了。https://gitea.$DOMAIN の 管理画面 > Actions > Runners で runner が「待機中」になっていることを確認し、テスト用リポジトリで1回ビルドを通してください"
