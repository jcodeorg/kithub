# kithub
北区用GitHub学習サイト



1. サーバー契約
XServer VPSクラウド
サーバー名:vps-2026-10-09-kithub
プラン:VPS 4GB(NVMe 50GB)
グローバルIPv4アドレス:153.115.45.237
OS:Ubuntu 24.04
セットアップスクリプト:Docker

1-1. 通常ユーザー作成

1-2. スワップ領域作成
===
# 2GBのSWAPファイルを作成
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 再起動後もSWAPを有効化
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
===

2. パケットフィルター
80/443/22 を許可する
そのためには、2段階の設定が必要
・パケットフィルターを作成する
・パケットフィルターを適用する

3. IPアドレス
DNS で以下を設定する
* `gitea.j-code.org`（Gitea リポジトリ管理）
* `ide.j-code.org`（WebAssembly/クライアント動作型 Web IDE）
* `users.j-code.org`（Gitea Actions で生成したビルド成果物の配信）

ESP32のビルド成果物は `https://users.j-code.org/<オーナー名>/<リポジトリ名>/latest/`（ブランチPush時）または `https://users.j-code.org/<オーナー名>/<リポジトリ名>/<タグ>/`（タグ時）から取得できます。

4. Gitea を起動

5. Actions runner（act_runner）を登録して起動

6. VPS（Ubuntu）の IP フォワーディングを有効化する
Docker コンテナからの通信を外のインターネットに転送するための設定を有効にします。
===
次のコマンドで設定ファイルを編集します。

Bash
sudo sysctl -w net.ipv4.ip_forward=1
再起動後も維持されるよう /etc/sysctl.conf に書き込みます。

Bash
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
確認方法: cat /proc/sys/net/ipv4/ip_forward を実行し、1 が返れば成功です。

# 1. IP Forwarding を即時強制有効化
sudo sysctl -w net.ipv4.ip_forward=1
# 2. 変更をシステム全体に反映　！重要
sudo sysctl -p


ステップ 2: UFW（ファイアウォール）
Ubuntu デフォルトのファイアウォール（UFW）が Docker からの外行きパケットを破棄（DROP）しているケースです。

以下なら問題ありません：
sudo ufw status verbose
状態: 非アクティブ

多分不要：
MASQUERADE ルールを手動で適用する

# Docker の POSTROUTING チェーンに MASQUERADE ルールを追加
sudo iptables -t nat -A POSTROUTING -s 172.16.0.0/12 ! -o docker0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 ! -o br-+ -j MASQUERADE


ステップ 3: Docker サービスと iptables の再読み込み
転送ルールを Docker に再適用させるため、Docker サービスを再起動します。

Bash
sudo systemctl restart docker
ステップ 4: 再度、疎通テストを実施する
設定が完了したら、もう一度同じコマンドを実行します。

Bash
docker exec -it dev-env-act_runner-1 wget --spider --timeout=5 https://github.com
成功時の表示: Connecting to github.com ... connected. および 200 OK や 301 Moved Permanently などの応答が返ります。

接続が確認できたら、Gitea の Actions 画面からワークフローを再実行してください。
===