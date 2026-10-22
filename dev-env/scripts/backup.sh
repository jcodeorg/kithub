#!/usr/bin/env bash
# Gitea / Drone / 設定一式を R2 のバックアップ用バケットへ保存する (VPS のディスクは使わない)。
# 使い方: backup.sh [--final]
#   --final : 引っ越し用。完了後も、このサーバーのサービスを停止したままにする
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_docker

FINAL=false
[ "${1:-}" = "--final" ] && FINAL=true

# 保存先は <バケット>/<UTC日時>/ 
cd "$DEV_ENV_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BUCKET="R2:$R2_BACKUP_BUCKET"
DEST="$BUCKET/$TS"

# 失敗したときは、通常・--final のどちらでもサービスを再開する。--final は成功したときだけ停止したままにする
DONE=false
trap '{ $DONE && $FINAL; } || docker compose start gitea drone drone-runner >/dev/null' EXIT

# 整合性のため、書き込みを行うサービスを止めてから保存する (DB は起動したまま)
docker compose stop gitea drone drone-runner

# 1) DB のダンプを、ディスクに書かず直接 R2 へ送る
docker compose exec -T db pg_dump -U gitea -Fc gitea | rclone rcat "$DEST/gitea.pgdump"

# 2) リポジトリ・設定・秘密情報 (.env) のファイル一式を tar にして R2 へ送る (存在するものだけ)
PATHS=()
for p in gitea gitea-config drone ide flash caddy .env docker-compose.yml; do
  if [ -e "$p" ]; then PATHS+=("$p"); fi
done
sudo tar -czf - "${PATHS[@]}" | rclone rcat "$DEST/files.tgz"

# 3) Caddy の証明書。引っ越し後に再取得を待たずに HTTPS を使うため
CADDY_VOL="$(docker volume ls -q | grep -m1 'caddy_data$' || true)"
if [ -n "$CADDY_VOL" ]; then
  docker run --rm -v "$CADDY_VOL:/data:ro" alpine tar -czf - -C /data . | rclone rcat "$DEST/caddy_data.tgz"
fi

# 保存内容を表示して確認する
rclone ls "$DEST"
# すべて保存できた後で、最新バックアップの印を更新する
echo "$TS" | rclone rcat "$BUCKET/latest"

# 新しい7世代だけ残す
rclone lsf --dirs-only "$BUCKET" | sort | head -n -7 | while read -r d; do
  rclone purge "$BUCKET/$d"
done

echo "バックアップ完了: $TS"
DONE=true
if $FINAL; then
  echo "旧サーバーのサービスは停止したままです。再開しないでください (新旧での二重運用を防ぐため)"
fi
