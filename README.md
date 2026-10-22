# Release Defect Forecasting (Reporting-Delay Correction in Ada)

Support needs to know how many defect reports each recent software release will have collected by day 365, not how many it holds today. The agent gets a defect-tracker export (`releases.csv`, `reports.csv`, `policy.json`) plus a README that documents the data and the forecasting method, and must implement the forecast in Ada (`/app/forecast/src/forecast.adb`, built with `gnatmake`, GNAT convenience hierarchy removed, no network). The program takes `<data-dir> <output-json>` and writes a per-release day-365 forecast (`reports_by_day_365`) and the per-source arrival curve it rests on (`arrival_share`, ticket and crash shares at each 30-day age), while honouring strict exit-code and no-side-effect rules.

## What makes it hard

- **The obvious table is right and the conclusion is wrong.** Reports per install make the newest releases look cleanest, but the median ticket arrives about 100 days after release. Submitting counts as they stand misses the per-release bar by up to 34% (32% on the second product); a rate trend through mature releases misses by 85% (76%).
- **Two sources on different clocks.** Crash reports land within days; tickets trickle in for a year. A single pooled growth pattern overshoots a crash-heavy 60-day release by 48% and fails the arrival-curve bar on both products. The curves must be built per source - tickets from all finished releases, crashes only from finished releases that ship the reporter - and the two ultimates added. That route lands every release within 2.1% (5.6% on the second product).
- **Every data edge is load-bearing.** Each of these, missed, moves a point of the curve by more than the 0.05 bar: a release exactly 365 days old must be in the finished cohort; "opened by day 30" includes day 30 (one release syncs crashes on days 30/60/90 exactly); a pre-reporter pilot release carries crash rows but must not join the crash curve; duplicate/invalid reports (including a 2000-report storm) are not defects; `opened_date`, not `reported_date`, is the clock. A release A days old has A+1 days of history - a 60-day release whose crashes landed on day 59 is 46% off if read one column short.
- **A second, unseen product.** A mobile line with 42 releases, slower tickets, a rising defect rate and a different reporter rollout. Carrying the shipped numbers or curves fails it; only a program that reads the pattern off its input passes.

Across ten generated products, the per-source method passes the forecast bars 10/10 on both shapes; counts-as-they-stand and the rate trend pass none.

## How it's graded

The verifier runs in a separate, offline container. It strips `src/` to top-level `*.adb`/`*.ads` files, compiles them itself with `gnatmake` as an unprivileged user (the agent's `build.sh` is not run), and runs the binary on the shipped export and then on the hidden second product. Checks include:

- Each forecast within `tolerance_per_release` of the true day-365 count (0.20 shipped / 0.17 hidden) and the total within `tolerance_total` (0.10 / 0.07); finished releases must match their in-file count exactly.
- Every arrival-curve point within 0.05 of the curve recomputed from that run's own input; each young release's forecast must equal its count over the printed share.
- Wrong argument counts (every count 0-40, plus 2000) must print a stderr line, leave stdout empty, exit 2 and write nothing; 18 malformed `horizon_days` values (`365.0`, `365e0`, `"365"`, `-365`, `null`, a 20-digit numeral, ...) must exit 3.
- The shipped export is unmodified (sha256) with nothing added.

Anti-cheat: all system executables are closed to the build user while the binary runs; everything under the project except the binary is made unreadable; the file system is verified to have no location writable by the build user except a pre-created output file; output paths and capture names are randomized so probes cannot be told apart from graded runs; answer keys are root-only and `/tests` is closed (run scored 0 if reachable). The task.toml verification write-up documents the one-change variants of the reference used to confirm each check rejects what it targets without failing valid variants.

## Repository layout

- `instruction.md` - the task prompt given to the agent.
- `task.toml` - metadata, difficulty/solution/verification write-ups, timeouts and network policy.
- `environment/` - agent image: `Dockerfile`, the Ada stub and `build.sh` in `forecast/`, and the tracker export with its README in `data/`.
- `solution/` - reference `forecast.adb` and `solve.sh`, the generator `gen_reports.py` (rebuilds both products byte for byte; `--hidden` for the second), and `calibrate.py`, which reproduces the figures above.
- `tests/` - verifier image, `test.sh`, `test_outputs.py`, the shipped answer key (`golden/`) and the hidden product with its key (`hidden/`).

## Running it

Requires Docker and Harbor (`uv tool install harbor` or `pip install harbor`). From the repo root:

```
harbor run -p . -a oracle
```

runs the reference solution through the verifier (should score reward 1). To try an agent instead:

```
harbor run -p . -a <agent> -m <model>
```

for example `-a claude-code`.

---

Task design, data generators, reference solution and verifier by Audrey Pope.
