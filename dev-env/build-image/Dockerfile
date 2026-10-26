# ESP32 (Arduino) ビルド専用イメージ。ツール・ボードコア・ライブラリを焼き込み、ジョブでのダウンロードをなくす。
# ベースは Node.js・Git・curl・Python を含み、actions/checkout がそのまま動く。
FROM catthehacker/ubuntu:act-22.04

ARG ESP32_CORE_VERSION=2.0.14
ENV ARDUINO_DIRECTORIES_DATA=/opt/arduino/data \
    ARDUINO_DIRECTORIES_USER=/opt/arduino/user \
    ARDUINO_DIRECTORIES_DOWNLOADS=/opt/arduino/staging \
    ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS=https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json \
    ARDUINO_UPDATER_ENABLE_NOTIFICATION=false

# flock と、arduino-cli・ESP32 ツールが使う pyserial
RUN apt-get update \
 && apt-get install -y --no-install-recommends util-linux \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_64bit.tar.gz \
      | tar -xz -C /usr/local/bin arduino-cli \
 && python3 -m pip install --no-cache-dir pyserial

# ESP32 ボードコアとライブラリ
RUN arduino-cli core update-index \
 && arduino-cli core install esp32:esp32@${ESP32_CORE_VERSION} \
 && arduino-cli lib install "U8g2" "Adafruit AHTX0" "BH1750" "Adafruit NeoPixel" \
 && git clone --depth 1 https://github.com/pschatzmann/ESP32-A2DP.git /opt/arduino/user/libraries/ESP32-A2DP \
 && rm -rf /opt/arduino/staging
