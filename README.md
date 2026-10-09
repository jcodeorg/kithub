# kithub
北区用GitHub学習サイト



1. サーバー契約
XServer VPSクラウド
サーバー名:vps-2026-10-09-kithub
プラン:VPS 4GB(NVMe 50GB)
グローバルIPv4アドレス:153.115.45.237
OS:Ubuntu 24.04
セットアップスクリプト:Docker

2. パケットフィルター
80/443/22 を許可する
そのためには、2段階の設定が必要
・パケットフィルターを作成する
・パケットフィルターを適用する

3. IPアドレス
DNS で以下を設定する
* `gitea.j-code.org`（Gitea リポジトリ管理）
* `ide.j-code.org`（WebAssembly/クライアント動作型 Web IDE）
* `drone.j-code.org`（Drone CI サーバー）
* `flash.j-code.org`（ESP32 Web Serial 書き込み用ツール）

