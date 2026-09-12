#!/usr/bin/env bash
# Build the forecast tool. Run it as: /app/forecast/forecast <data-dir> <output-json>
set -euo pipefail
cd /app/forecast
mkdir -p obj
gnatmake -O2 -D obj -Isrc -o forecast src/forecast.adb
