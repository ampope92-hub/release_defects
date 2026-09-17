#!/usr/bin/env python3
"""The same export, cut off at an earlier date.

    truncate.py <export-dir> <out-dir> <days-back>

Writes <out-dir>/data, the export as the tracker would have taken it <days-back> days before
the real export date, and <out-dir>/key.json, the count each release on its forecast list went
on to reach, read off the full export. The forecast list is the releases that were between 60
and 210 days old on the earlier date and have since finished collecting (at least 365 days old
on the real export date), so every count on the key is in the export the program was handed
and nothing is held back. That is the back-test the instruction names: a forecast is what a
release's reports so far imply, and the same reading on a release that has since finished has
to land on what it reached.

The cut follows the tracker's own rule for what an export holds: a report is in the file when
its opened_date is on or before the export date, and a ticket still in the triage queue on that
date carries the export date as its reported_date. Releases that had not shipped are not in the
release list, and the review table is recomputed from what the earlier export holds.
"""
import csv
import datetime as dt
import json
import pathlib
import sys

HORIZON = 365


def main():
    src, out, back = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
    with open(src / "policy.json") as fh:
        policy = json.load(fh)
    with open(src / "releases.csv", newline="") as fh:
        releases = list(csv.DictReader(fh))
    with open(src / "reports.csv", newline="") as fh:
        reports = list(csv.DictReader(fh))
    export = dt.date.fromisoformat(policy["export_date"])
    cut = export - dt.timedelta(days=back)

    kept_releases = [r for r in releases if dt.date.fromisoformat(r["release_date"]) <= cut]
    kept_versions = {r["version"] for r in kept_releases}
    kept = []
    for r in reports:
        if r["version"] not in kept_versions or dt.date.fromisoformat(r["opened_date"]) > cut:
            continue
        r = dict(r)
        if dt.date.fromisoformat(r["reported_date"]) > cut:
            r["reported_date"] = cut.isoformat()
        kept.append(r)
    kept.sort(key=lambda r: (r["reported_date"], r["version"]))

    rel_date = {r["version"]: dt.date.fromisoformat(r["release_date"]) for r in releases}
    young = [r["version"] for r in kept_releases
             if 60 <= (cut - rel_date[r["version"]]).days <= 210
             and (export - rel_date[r["version"]]).days >= HORIZON]
    reached = {}
    for v in young:
        reached[v] = sum(1 for r in reports
                         if r["version"] == v and r["status"] == "open"
                         and (dt.date.fromisoformat(r["opened_date"]) - rel_date[v]).days <= HORIZON)
    finished_with_reporter = [r["version"] for r in kept_releases
                              if (cut - rel_date[r["version"]]).days >= HORIZON and r["crash_reporter"] == "yes"]
    if not young or not finished_with_reporter:
        sys.exit(f"{src}: cut off {back} days early the export has {len(young)} releases to forecast "
                 f"and {len(finished_with_reporter)} finished releases with the crash reporter; the "
                 f"back-test needs at least one of each")

    data = out / "data"
    data.mkdir(parents=True, exist_ok=True)
    with open(data / "releases.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["version", "release_date", "installs_first_90_days", "crash_reporter"],
                           lineterminator="\n")
        w.writeheader()
        w.writerows(kept_releases)
    with open(data / "reports.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["report_id", "version", "reported_date", "source", "status", "opened_date"],
                           lineterminator="\n")
        w.writeheader()
        for k, r in enumerate(kept, 1):
            r["report_id"] = f"R{k:06d}"
            w.writerow(r)
    received = {}
    for r in kept:
        received[r["version"]] = received.get(r["version"], 0) + 1
    policy["export_date"] = cut.isoformat()
    policy["forecast_releases"] = young
    policy["reports_per_10k_installs_to_date"] = {
        r["version"]: round(10000 * received.get(r["version"], 0) / int(r["installs_first_90_days"]), 2)
        for r in kept_releases
    }
    with open(src / "policy.json") as fh:
        tabs = "\t" in fh.read()
    with open(data / "policy.json", "w") as fh:
        if tabs:
            json.dump(policy, fh, indent="\t", separators=(",", ":\t"))
        else:
            json.dump(policy, fh, indent=2)
        fh.write("\n")
    readme = src / "README.md"
    if readme.exists():
        (data / "README.md").write_text(readme.read_text().replace(export.isoformat(), cut.isoformat()))
    with open(out / "key.json", "w") as fh:
        json.dump({"export_date": cut.isoformat(), "forecast_releases": young,
                   "reports_within_365_days": reached,
                   "tolerance_per_release": policy["tolerance_per_release"],
                   "tolerance_total": policy["tolerance_total"]}, fh, indent=2)
        fh.write("\n")
    print(f"{src} cut off at {cut} ({back} days early): {len(kept_releases)} releases, {len(kept)} reports; "
          f"forecast {', '.join(f'{v} ({(cut - rel_date[v]).days} days, reached {reached[v]})' for v in young)}; "
          f"finished with the reporter: {', '.join(finished_with_reporter)}")


if __name__ == "__main__":
    main()
