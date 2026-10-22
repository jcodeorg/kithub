#!/usr/bin/env bash
# 新しい VPS (Ubuntu) に、サービスを動かすための前提設定をすべて行う。何度実行しても安全。
# 使い方: bootstrap.sh [--harden-ssh]
#   --harden-ssh : root ログインとパスワード認証を無効にする (公開鍵でログインできていることが前提)
# 行うこと: Docker の導入確認 / MTU / スワップ / IP フォワーディング / R2 の pages マウント /
#           Docker の起動条件 / 設定ファイルの配置 (既存のものは上書きしない)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# このスクリプトがあるリポジトリ内の dev-env と、運用ディレクトリ (既定 ~/dev-env)
REPO_DEV_ENV="$(cd "$(dirname "$0")/.." && pwd)"
PAGES="$DEV_ENV_DIR/pages"

# 必要なパッケージを入れる (s3fs: R2 のマウント / rclone: バックアップ)
sudo apt-get update -qq
sudo apt-get install -y -qq s3fs rclone rsync curl git openssl python3
# Docker が無い場合だけ導入する (XServer の Docker テンプレートなら導入済み)
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  sudo apt-get install -y -qq docker.io docker-compose-v2
fi

# スワップが無ければ 2GB 作る (メモリ不足でのビルド失敗を防ぐ)
if ! swapon --show | grep -q .; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

# コンテナから外部への通信を転送できるよう、IP フォワーディングを永続的に有効にする
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-kithub.conf >/dev/null
sudo sysctl --system >/dev/null

# VPS の NIC (MTU 1442) より小さくする。既存の設定があれば変更しない
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{ "mtu": 1400 }' | sudo tee /etc/docker/daemon.json >/dev/null
fi

# pages (公開成果物) を R2 に接続する。VPS のディスクは使わない
(umask 077; echo "$R2_PAGES_ACCESS_KEY_ID:$R2_PAGES_SECRET_ACCESS_KEY" | sudo tee /etc/passwd-s3fs >/dev/null)
mkdir -p "$PAGES"
# fstab に書いて、再起動後も自動でマウントされるようにする (同じパスの古い行は先に削除)
sudo sed -i "\|[[:space:]]$PAGES[[:space:]]|d" /etc/fstab
echo "$R2_PAGES_BUCKET $PAGES fuse.s3fs _netdev,allow_other,use_path_request_style,url=https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com,endpoint=auto,passwd_file=/etc/passwd-s3fs,umask=0022,mp_umask=0022,stat_cache_expire=1,retries=5 0 0" | sudo tee -a /etc/fstab >/dev/null

# pages がマウントできないときは Docker を起動させない (ローカルディスクへの誤書き込み防止)
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$PAGES" | sudo tee /etc/systemd/system/docker.service.d/require-pages-mount.conf >/dev/null
sudo systemctl daemon-reload

# 実際にマウントし、R2 (fuse.s3fs) に接続できたことを確認する。失敗するとここで中止する
findmnt -n -T "$PAGES" -o FSTYPE | grep -q 'fuse.s3fs' || sudo mount "$PAGES"
findmnt -T "$PAGES" -o SOURCE,FSTYPE,TARGET
findmnt -n -T "$PAGES" -o FSTYPE | grep -q 'fuse.s3fs'

# 設定ファイルの配置。運用中のものを壊さないよう、無いときだけコピーする
mkdir -p "$DEV_ENV_DIR/caddy" "$DEV_ENV_DIR/cache"
[ -e "$DEV_ENV_DIR/docker-compose.yml" ] || cp "$REPO_DEV_ENV/docker-compose.yml" "$DEV_ENV_DIR/"
[ -e "$DEV_ENV_DIR/caddy/Caddyfile" ] || cp "$REPO_DEV_ENV/caddy/Caddyfile" "$DEV_ENV_DIR/caddy/"
[ -e "$PAGES/index.html" ] || cp "$REPO_DEV_ENV/pages/index.html" "$PAGES/"
# スクリプト自体も運用ディレクトリにコピーする (cron やバックアップから使うため)
if [ "$REPO_DEV_ENV" != "$DEV_ENV_DIR" ]; then
  rsync -a "$REPO_DEV_ENV/scripts/" "$DEV_ENV_DIR/scripts/"
fi

# MTU と起動条件を反映するため Docker を再起動し、自動起動を有効にする
sudo systemctl enable docker
sudo systemctl restart docker

# 指定時のみ: root ログインとパスワード認証を無効にする (鍵が無いと締め出されるため事前確認する)
if [ "${1:-}" = "--harden-ssh" ]; then
  if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
    echo "公開鍵が未設定のため SSH の設定は変更しません" >&2
    exit 1
  fi
  # 00- で始めて、cloud-init などの既存設定より優先させる
  printf 'PermitRootLogin no\nPasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-kithub.conf >/dev/null
  sudo sshd -t
  sudo systemctl reload ssh
  echo "SSH: root ログインとパスワード認証を無効にしました"
fi

echo "bootstrap 完了"
