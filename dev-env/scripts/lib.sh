#!/usr/bin/env bash
# backup.sh / restore.sh / bootstrap.sh 共通の設定。直接は実行しない。
DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/dev-env}"
# 公開成果物 (R2 の s3fs マウント先) と s3fs のローカルキャッシュ。Caddy と Actions のジョブが共有する
PAGES_DIR="${PAGES_DIR:-/var/lib/kithub/pages}"
S3FS_CACHE_DIR="${S3FS_CACHE_DIR:-/var/cache/kithub/s3fs}"
BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-/var/lib/kithub/build-cache}"

if [ ! -f "$DEV_ENV_DIR/.r2.env" ]; then
  echo "$DEV_ENV_DIR/.r2.env がありません。doc/install.md の手順で作成してください" >&2
  exit 1
fi

set -a
. "$DEV_ENV_DIR/.r2.env"
set +a

# 設定ファイルを作らず、環境変数だけで rclone の R2 接続を定義する
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_BACKUP_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_BACKUP_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
# バケット単位のトークンではバケット作成の確認ができないため無効化する
export RCLONE_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_CHUNK_SIZE=16M
# 設定ファイルが無い旨などの通知で出力が読みにくくならないよう、エラーだけ表示する
export RCLONE_LOG_LEVEL=ERROR

# Docker を sudo なしで使えないと、処理の途中で止まるため、最初に確認する
require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker を使えません。次を実行し、一度ログアウトして入り直してから、もう一度実行してください:" >&2
    echo "  sudo usermod -aG docker $USER" >&2
    exit 1
  fi
}
