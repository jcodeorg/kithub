# ESP32 (Arduino) ビルド専用イメージ。ツール・ボードコア・ライブラリを焼き込み、ジョブでのダウンロードをなくす。
# ベースは Node.js・Git・curl・Python を含み、actions/checkout がそのまま動く。
FROM catthehacker/ubuntu:act-22.04

ARG ESP32_CORE_VERSION=2.0.14
ENV ARDUINO_DIRECTORIES_DATA=/opt/arduino/data \
    ARDUINO_DIRECTORIES_USER=/opt/arduino/user \
    ARDUINO_DIRECTORIES_DOWNLOADS=/opt/arduino/staging \
    ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS=https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json \
    ARDUINO_UPDATER_ENABLE_NOTIFICATION=false

# arduino-cli と、ESP32 ツールが使う pyserial
RUN curl -fsSL https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_64bit.tar.gz \
      | tar -xz -C /usr/local/bin arduino-cli \
 && python3 -m pip install --no-cache-dir pyserial

# ESP32 ボードコアとライブラリ
RUN arduino-cli core update-index \
 && arduino-cli core install esp32:esp32@${ESP32_CORE_VERSION} \
 && arduino-cli lib install "U8g2" "Adafruit AHTX0" "BH1750" "Adafruit NeoPixel" \
 && git clone --depth 1 https://github.com/pschatzmann/ESP32-A2DP.git /opt/arduino/user/libraries/ESP32-A2DP \
 && rm -rf /opt/arduino/staging

# 読み取り専用のベース。ESP32 コアとライブラリを事前コンパイルして焼き込む。
#   build-cache-base: コア (core.a) のキャッシュ
#   build-base      : ビルドディレクトリ一式 (ライブラリのオブジェクトを含む)
# ジョブは開始時にこれを自分用にコピーして使うため、同時実行でもキャッシュが競合・汚染されない。
# ワークフローと同じ FQBN でビルドすること (キャッシュはボード設定ごとに分かれる)。
COPY warmup /tmp/warmup
RUN arduino-cli config set build_cache.path /opt/arduino/build-cache-base \
 && arduino-cli compile \
      --fqbn "esp32:esp32:esp32:PartitionScheme=huge_app,FlashMode=dio,FlashSize=4M" \
      --build-path /opt/arduino/build-base \
      --output-dir /tmp/warmup-out \
      /tmp/warmup \
 && ls /opt/arduino/build-cache-base /opt/arduino/build-base >/dev/null \
 && rm -rf /tmp/warmup /tmp/warmup-out \
 && chmod -R a+rX /opt/arduino/build-cache-base /opt/arduino/build-base
