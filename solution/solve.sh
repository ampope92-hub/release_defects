#!/usr/bin/env bash
set -euo pipefail

# Reference day-365 forecast.
#
# The memo's table divides the reports a release has collected so far by its installs, and
# the young releases look clean because their tickets are still on their way: a ticket
# trails the release by weeks or months. The older releases show how a release's count grows
# column by 30-day column, and that growth is what a young release still has coming. From
# 4.20 the crash reporter adds a second stream that lands within days, so the two streams
# get separate growth patterns, tickets from every release and crash reports from the
# releases that have the reporter, and the two are added. See forecast.adb alongside.
install -m 644 "$(dirname "$0")/forecast.adb" /app/forecast/src/forecast.adb
bash /app/forecast/build.sh
# The build script has done its job; it is ours, not part of the binary's own project, so it
# does not stay executable for the run that follows.
chmod -x /app/forecast/build.sh
mkdir -p /app/out
/app/forecast/forecast /app/data /app/out/forecast.json
