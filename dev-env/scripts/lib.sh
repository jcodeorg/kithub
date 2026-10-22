#!/usr/bin/env bash
# backup.sh / restore.sh / bootstrap.sh 共通の設定。直接は実行しない。
DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/dev-env}"

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
