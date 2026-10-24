#!/usr/bin/env bash
# R2 のバックアップから Gitea / 設定一式を復元して起動する。bootstrap.sh の後に実行する。
# 使い方: restore.sh [--force] [バックアップ名]
#   --force      : 既存の Gitea のデータを削除してやり直す (リハーサル後の本番用)
#   バックアップ名: 省略すると latest
# act_runner は、DNS 切り替え前に旧サーバーのジョブを奪わないよう、ここでは起動しない (go-live.sh が起動する)。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_docker

# cd の前に、このスクリプトがあるリポジトリ内の dev-env を求める (相対パスで実行された場合に備える)
REPO_DEV_ENV="$(cd "$(dirname "$0")/.." && pwd)"

FORCE=false
if [ "${1:-}" = "--force" ]; then FORCE=true; shift; fi
TS="${1:-$(rclone cat "R2:$R2_BACKUP_BUCKET/latest" | tr -d '[:space:]')}"
SRC="R2:$R2_BACKUP_BUCKET/$TS"
echo "復元するバックアップ: $TS"

cd "$DEV_ENV_DIR"

# pages が R2 でないと、ローカルディスクに成果物が溜まるため中止する
if ! findmnt -n -T "$DEV_ENV_DIR/pages" -o FSTYPE | grep -q 'fuse.s3fs'; then
  echo "pages が R2 にマウントされていません。先に bootstrap.sh を実行してください" >&2
  exit 1
fi

# 既存データがある場合は、--force のときだけ削除する (誤って上書きしない)
if [ -d gitea ] && [ -n "$(sudo ls -A gitea)" ]; then
  if ! $FORCE; then
    echo "既存のデータがあります。削除してやり直す場合は --force を付けてください" >&2
    exit 1
  fi
  if [ -f docker-compose.yml ]; then docker compose down -v; fi
  sudo rm -rf gitea gitea-config act_runner/data postgres_data
fi

# ファイル一式を展開する
rclone cat "$SRC/files.tgz" | sudo tar -xzf - -C "$DEV_ENV_DIR"

# docker-compose.yml は、バックアップのものではなくリポジトリの最新版に差し替える
# (バックアップのものは docker-compose.yml.from-backup に残す)。運用ディレクトリ内のスクリプトから実行した場合は差し替えない
if [ "$REPO_DEV_ENV" != "$DEV_ENV_DIR" ] && [ -f "$REPO_DEV_ENV/docker-compose.yml" ]; then
  if ! sudo cmp -s "$REPO_DEV_ENV/docker-compose.yml" docker-compose.yml; then
    [ -e docker-compose.yml ] && sudo mv docker-compose.yml docker-compose.yml.from-backup
    sudo cp "$REPO_DEV_ENV/docker-compose.yml" docker-compose.yml
    echo "docker-compose.yml をリポジトリの最新版に差し替えました (バックアップ版: docker-compose.yml.from-backup)"
  fi
fi

# 復元元と UID / パスが違っても動くように所有者と .env を整える
sudo chown -R 1000:1000 gitea gitea-config
for p in docker-compose.yml .env caddy ide flash act_runner; do
  if [ -e "$p" ]; then sudo chown -R "$(id -u):$(id -g)" "$p"; fi
done
chmod 600 .env
sed -i '/^DEV_ENV_DIR=/d' .env
echo "DEV_ENV_DIR=$DEV_ENV_DIR" >> .env
# runner の設定はリポジトリの最新版を使う。登録情報は復元せず、go-live.sh で登録し直す
mkdir -p act_runner/data
if [ "$REPO_DEV_ENV" != "$DEV_ENV_DIR" ] && [ -f "$REPO_DEV_ENV/act_runner/config.yaml" ]; then
  cp "$REPO_DEV_ENV/act_runner/config.yaml" act_runner/config.yaml
fi

# DB だけ起動し、接続できるまで待ってからダンプを復元する
docker compose up -d db
# 初期化中の一時サーバーは TCP で待ち受けないため、TCP で接続確認する
until docker compose exec -T db pg_isready -h 127.0.0.1 -U gitea -d gitea >/dev/null 2>&1; do sleep 2; done
rclone cat "$SRC/gitea.pgdump" | docker compose exec -T db pg_restore -U gitea -d gitea --no-owner --exit-on-error

# Caddy の証明書ボリュームを復元する (ボリュームを作るため、先に起動せず作成だけ行う)
docker compose up --no-start caddy
CADDY_VOL="$(docker volume ls -q | grep -m1 'caddy_data$' || true)"
if [ -n "$CADDY_VOL" ] && rclone lsf "$SRC/caddy_data.tgz" >/dev/null 2>&1; then
  rclone cat "$SRC/caddy_data.tgz" | docker run --rm -i -v "$CADDY_VOL:/data" alpine tar -xzf - -C /data
fi

# act_runner 以外を起動し、Gitea が応答して管理者が見えることを確認する (最大5分)
docker compose up -d gitea caddy

echo "Gitea の起動を待っています"
for _ in $(seq 1 60); do
  if docker compose exec -T gitea wget -qO- http://localhost:3000/api/healthz >/dev/null 2>&1; then
    echo "Gitea 起動 OK"
    docker compose exec -T gitea gitea admin user list --admin
    echo "復元完了。DNS 切り替えまで act_runner は起動していません"
    exit 0
  fi
  sleep 5
done
echo "Gitea が起動しません。docker compose logs gitea を確認してください" >&2
exit 1
