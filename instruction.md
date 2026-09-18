Support needs the count each recent release will finish with, not what it holds today. `/app/data` holds the tracker export and a README covering each file.

We write Ada here; the stub is `/app/forecast/src/forecast.adb`. More .adb/.ads files may sit beside it under src/; anything else there, and anything in `/app/out`, is removed before we build. `/app/forecast/build.sh` is yours to use; we compile `src/forecast.adb` and whatever it pulls in from src/, with gnatmake -I src, and run the binary from `/app/forecast`. The GNAT hierarchy is removed from the image. No network.

`/app/forecast/forecast <data-dir> <output-json>` writes one JSON object with two keys and keeps to the rules below.

- `reports_by_day_365`: keys exactly the versions under `forecast_releases` in that directory's policy.json, each a non-negative integer, the count you forecast it reaches by day 365, made the way the method section of the README says. Each must land within `tolerance_per_release` of the count actually reached, as a fraction of it, and the total within `tolerance_total` of the summed counts. A release that has reached day 365 has its count in the file and must match it exactly.
- `arrival_share`: the curve those forecasts rest on. Keys `ticket` and `crash`; under each, the ages 30, 60 and so on to 360 as strings, each the share of the finished releases' day-365 reports, taken together as one pile, opened by that age, the day itself included. The crash curve is the reporter's, from the finished releases that ship it. Every point must be within 0.05 of what those releases give, and each forecast for a release under a year old must be its counts over the shares you print, each read to its last printed digit.

- Handed anything but two arguments, it prints a line on standard error, leaves standard output empty, exits 2 and writes nothing.
- `horizon_days` is the bare token 365 in both exports; 365.0 or 365e0 is another spelling and so another horizon. Handed any other horizon, whatever JSON value, it prints a line on standard error, writes nothing and exits 3. We try wrong argument counts and horizons of each kind.
- While it runs, nothing under `/app/forecast` but the binary itself is readable. When it exits, the output file holds the JSON and nothing else has been written; there is nowhere else to write. The output path may already exist, empty; write over it.
- It runs again on another product's export: the same four files, different releases and policy, a crash reporter that went in at another release.
- Everything in `/app/data` stays exactly as it arrived; we check the whole directory against our copy.
