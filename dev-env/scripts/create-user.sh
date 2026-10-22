#!/usr/bin/env bash
# root で1回だけ実行する。一般ユーザーを作成し、sudo / docker 権限と root の SSH 公開鍵を引き継ぐ。
# 使い方: create-user.sh [ユーザー名]   (既定: kithub)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "root で実行してください" >&2; exit 1; }
U="${1:-kithub}"

# ユーザーを作成し (パスワードなし)、sudo / docker グループに追加する
id "$U" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$U"
usermod -aG sudo "$U"
getent group docker >/dev/null && usermod -aG docker "$U"

# docker グループは事実上 root 権限のため、スクリプトが使う sudo はパスワード不要にする
echo "$U ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$U"
chmod 440 "/etc/sudoers.d/90-$U"
visudo -cf "/etc/sudoers.d/90-$U" >/dev/null

# root の SSH 公開鍵を引き継ぎ、すぐに公開鍵でログインできるようにする
if [ -s /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
  install -m 600 -o "$U" -g "$U" /root/.ssh/authorized_keys "/home/$U/.ssh/authorized_keys"
else
  echo "root の authorized_keys がありません。/home/$U/.ssh/authorized_keys に公開鍵を設定してください" >&2
fi

echo "作成完了。別のターミナルから ssh $U@<VPSのIP> でログインできることを確認してください"
