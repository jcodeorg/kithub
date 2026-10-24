#!/usr/bin/env bash
# ESP32 ビルド専用イメージ (kithub/esp32-arduino:latest) を、このサーバーの Docker にビルドする。
# 使い方: build-image.sh
# ライブラリやボードコアを更新したいときも、このスクリプトを再実行する (ワークフローは次のジョブから新しいイメージを使う)。
set -euo pipefail

REPO_DEV_ENV="$(cd "$(dirname "$0")/.." && pwd)"
docker build -t kithub/esp32-arduino:latest "$REPO_DEV_ENV/build-image"
docker image ls kithub/esp32-arduino
