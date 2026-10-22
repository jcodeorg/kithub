#!/usr/bin/env bash
# 引っ越しの仕上げ。DNS が このサーバーを向くまで待ち、drone-runner を起動して動作を確認する。
# restore.sh の後、DNS を変更してから実行する。
# 使い方: go-live.sh   (DOMAIN で既定の j-code.org を変更できる)
set -euo pipefail

DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/dev-env}"
DOMAIN="${DOMAIN:-j-code.org}"
cd "$DEV_ENV_DIR"

# このサーバーのグローバル IP を調べる
MYIP="$(curl -4 -fsS https://api.ipify.org)"
echo "このサーバーの IP: $MYIP。DNS の反映を待っています (最大1時間)"

# 3つのホスト名が、すべてこのサーバーの IP に解決されるまで待つ
for h in gitea drone users; do
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

# 旧サーバーの Drone に接続しないよう、DNS の反映後に起動する
docker compose up -d drone-runner

# HTTPS 経由で Gitea が応答することを確認する (証明書の取得待ちを含め最大5分)
for _ in $(seq 1 30); do
  curl -fsS "https://gitea.$DOMAIN/api/healthz" >/dev/null 2>&1 && break
  sleep 10
done
curl -fsS "https://gitea.$DOMAIN/api/healthz" >/dev/null
docker compose ps
echo "切り替え完了。https://drone.$DOMAIN で Sync を確認し、テスト用リポジトリで1回ビルドを通してください"
