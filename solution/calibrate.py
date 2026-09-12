#!/usr/bin/env python3
"""Where the bars sit, measured rather than chosen.

Generates products with gen_reports.py across seeds and, on each, forecasts the young releases'
365-day counts by the routes a reader of the export is likely to take, then scores every route
against the counts those releases actually reached:

  reports_to_date        the memo's number: what each release has collected by the export date
  mature_rate_trend      a straight line through the reports-per-installs of the releases that are
                         a year old, read off at the young releases and scaled by their installs
  chain_ladder_pooled    one column-to-column growth pattern from every report of every release,
                         applied to each young release's count so far
  chain_ladder_by_source the reference: an arrival curve per source over the finished releases,
                         tickets from every one of them and crash reports from the ones that ship
                         the crash reporter, each share rounded to the four places the report
                         prints, and a young release's count divided by the share at its last
                         whole column. Duplicate and invalid reports are dropped first, and the
                         column a report falls into is read off opened_date, not reported_date.
  by_source_ignore_triage  the reference method with one fact missed: it reads reported_date, the
                         day the tracker logged a ticket, instead of opened_date, the day the user
                         actually hit it. Tickets sit in a triage queue between the two, short on
                         the shipped product and long on the other.
  by_source_ignore_status  the reference method with the other fact missed: it never drops the
                         reports one release's tracker marked duplicate or invalid, so a storm of
                         them in that release's first columns is pooled into the curve as if they
                         were real, growing releases.
  by_source_ignore_both    both facts missed at once.

Columns are 30 days wide and only complete columns are used, with a final column for everything
by day 365. Scores are the worst per-release error, the error on the total, and how many
releases land inside the policy's tolerance.

    calibrate.py [--seeds N]
"""
import argparse
import csv
import datetime as dt
import json
import pathlib
import statistics as st
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
STEP = 30
COLUMNS = 13


def load(d):
    with open(d / "releases.csv", newline="") as fh:
        rel = {r["version"]: r for r in csv.DictReader(fh)}
    with open(d / "reports.csv", newline="") as fh:
        reps = list(csv.DictReader(fh))
    with open(d / "policy.json") as fh:
        pol = json.load(fh)
    return rel, reps, pol


def complete_columns(age):
    if age >= 365:
        return COLUMNS
    return max(0, min(COLUMNS - 1, (age + 1) // STEP))


def column_limit(p):
    return 365 if p == COLUMNS - 1 else STEP * (p + 1) - 1


def triangle(rel, reps, export, source=None, versions=None, date_field="opened_date", filter_status=True):
    """Cumulative counts per release for the columns the export holds complete. date_field picks
    opened_date (the reference) or reported_date (a reader who missed the triage-queue fact);
    filter_status drops duplicate/invalid reports unless a reader missed that fact too."""
    lags = {}
    for r in reps:
        if filter_status and r.get("status", "open") != "open":
            continue
        if source and r["source"] != source:
            continue
        v = r["version"]
        if versions is not None and v not in versions:
            continue
        rd = dt.date.fromisoformat(rel[v]["release_date"])
        lags.setdefault(v, []).append((dt.date.fromisoformat(r[date_field]) - rd).days)
    tri = {}
    for v in (versions if versions is not None else rel):
        age = (export - dt.date.fromisoformat(rel[v]["release_date"])).days
        tri[v] = [sum(1 for L in lags.get(v, []) if L <= column_limit(p)) for p in range(complete_columns(age))]
    return tri


def chain_ladder(tri):
    factors = []
    for p in range(COLUMNS - 1):
        num = sum(row[p + 1] for row in tri.values() if len(row) > p + 1)
        den = sum(row[p] for row in tri.values() if len(row) > p + 1)
        factors.append(num / den if den > 0 else 1.0)
    ult = {}
    for v, row in tri.items():
        if not row:
            continue
        x = row[-1]
        for p in range(len(row) - 1, COLUMNS - 1):
            x *= factors[p]
        ult[v] = x
    return ult


def by_arrival_share(tri):
    """What forecast.adb does: pool the finished releases into one curve per column, round each
    share to four places, and divide a young release's last complete count by the share there.
    A release already past the horizon still forecasts off the twelfth (360-day) column, never
    off the reserved day-365 slot that only feeds the pool: the cap on how many columns a
    forecast may use and the cohort question of whether a release has finished collecting are
    two different rules, exactly as forecast.adb keeps Complete and Finished separate fields."""
    finished = [row for row in tri.values() if len(row) == COLUMNS]
    ult = sum(row[-1] for row in finished)
    share = [round(sum(row[p] for row in finished) / ult, 4) if ult else 1.0 for p in range(COLUMNS)]
    out = {}
    for v, row in tri.items():
        if not row:
            out[v] = 0.0
            continue
        k = min(len(row) - 1, COLUMNS - 2)
        out[v] = row[k] / share[k] if share[k] > 0 else 0.0
    return out


def routes(d):
    rel, reps, pol = load(d)
    export = dt.date.fromisoformat(pol["export_date"])
    fc = pol["forecast_releases"]
    got = {}
    for r in reps:
        got[r["version"]] = got.get(r["version"], 0) + 1
    out = {"reports_to_date": {v: got.get(v, 0) for v in fc}}

    idx = {v: i for i, v in enumerate(rel)}
    mature = [v for v in rel if (export - dt.date.fromisoformat(rel[v]["release_date"])).days >= 365]
    xs = [idx[v] for v in mature]
    ys = [10000 * got.get(v, 0) / int(rel[v]["installs_first_90_days"]) for v in mature]
    mx, my = st.mean(xs), st.mean(ys)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
    out["mature_rate_trend"] = {v: max(0.0, my + slope * (idx[v] - mx)) * int(rel[v]["installs_first_90_days"]) / 10000 for v in fc}

    pooled = chain_ladder(triangle(rel, reps, export))
    out["chain_ladder_pooled"] = {v: pooled[v] for v in fc}

    era = {v for v in rel if rel[v]["crash_reporter"] == "yes"}

    def by_source(date_field, filter_status):
        tickets = by_arrival_share(triangle(rel, reps, export, "ticket", date_field=date_field, filter_status=filter_status))
        crashes = by_arrival_share(triangle(rel, reps, export, "crash", era, date_field=date_field, filter_status=filter_status)) if era else {}
        return {v: tickets.get(v, 0) + (crashes.get(v, 0) if v in era else 0) for v in fc}

    out["chain_ladder_by_source"] = by_source("opened_date", True)
    out["by_source_ignore_triage"] = by_source("reported_date", True)
    out["by_source_ignore_status"] = by_source("opened_date", False)
    out["by_source_ignore_both"] = by_source("reported_date", False)
    return out, pol


def score(fcst, key, pol):
    real = key["reports_within_365_days"]
    per = {v: abs(round(fcst[v]) - real[v]) / real[v] for v in real}
    tot = abs(sum(round(fcst[v]) for v in real) - sum(real.values())) / sum(real.values())
    inside = sum(1 for e in per.values() if e <= pol["tolerance_per_release"])
    return max(per.values()), tot, inside, len(per), tot <= pol["tolerance_total"] and inside == len(per)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=10)
    a = ap.parse_args()
    fmt = lambda v: f"{st.mean(v):.3f} [{min(v):.3f},{max(v):.3f}]"
    for label, extra in [("ledgerdesk, the shipped export", []), ("fieldbook-mobile, the other product", ["--hidden"])]:
        res = {}
        with tempfile.TemporaryDirectory() as tmp:
            for seed in range(a.seeds):
                d = pathlib.Path(tmp) / f"s{seed}"
                subprocess.run([sys.executable, str(HERE / "gen_reports.py"), str(d / "data"), str(d), "--seed", str(seed)] + extra,
                               check=True, capture_output=True)
                with open(d / "key.json") as fh:
                    key = json.load(fh)
                out, pol = routes(d / "data")
                for name, f in out.items():
                    res.setdefault(name, []).append(score(f, key, pol))
        print(f"== {label}, {a.seeds} seeds")
        for name, v in res.items():
            c = list(zip(*v))
            print(f"   {name:24s} worst release {fmt(c[0])}   total {fmt(c[1])}   inside {' '.join(f'{i}/{n}' for i, n in zip(c[2], c[3]))}   passes {sum(c[4])}/{len(c[4])}")
    print("== the pinned exports")
    for label, d, k in [("shipped", HERE.parent / "environment" / "data", HERE.parent / "tests" / "golden" / "key.json"),
                        ("hidden", HERE.parent / "tests" / "hidden" / "data", HERE.parent / "tests" / "hidden" / "key.json")]:
        if not d.exists():
            continue
        with open(k) as fh:
            key = json.load(fh)
        out, pol = routes(d)
        for name, f in out.items():
            w, t, i, n, ok = score(f, key, pol)
            print(f"   {label:8s} {name:24s} worst {w:.3f} total {t:.3f} inside {i}/{n} {'PASS' if ok else 'fail'}  " + " ".join(f"{v}={round(f[v])}/{key['reports_within_365_days'][v]}" for v in f))


if __name__ == "__main__":
    main()
