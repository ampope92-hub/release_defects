#!/usr/bin/env python3
"""Generate a product's release list, its defect-report log up to the export date, the policy,
and the key.

Each release has its own underlying defect intensity per install. Reports arrive with a delay
after the release: tickets filed by users take weeks to months, and from the release that shipped
the crash reporter onwards, crash reports arrive within days as well. The export holds every
report received up to the export date. The key is the number of reports each release has received
by 365 days after it shipped.

Two more things a reader has to get right, both stated in the README:

  status       a report can be marked duplicate or invalid by the tracker. Those are not
               defects and do not count, in the key or in the curve. A handful turn up in
               every product; one release's early days carries far more of them.
  opened_date  reported_date is the day the ticket was logged in the tracker, which lags the
               day the user actually hit the bug (opened_date) by a triage queue. Crash reports
               have no queue, so their two dates match. The gap is small here and large on the
               other product.

    gen_reports.py <out-dir> <key-dir> [--seed N] [--hidden]

Standard library only.
"""
import argparse
import csv
import datetime as dt
import json
import math
import pathlib
import random


def poisson(rng, mean):
    if mean > 500:
        return max(0, round(rng.gauss(mean, math.sqrt(mean))))
    L, k, p = math.exp(-mean), 0, 1.0
    while True:
        p *= rng.random()
        if p <= L:
            return k
        k += 1


def gen_one_release(rng, rng_status, rng_triage, i, d, installs, has_reporter, export, *,
                     base_rate, trend, rate_sd, reporter_lift, crash_share,
                     crash_med, crash_sig, ticket_med, ticket_sig,
                     ambient_bad_p, triage_med, triage_sig):
    """One release's underlying rate, its reports up to the export date, and its true day-365
    total: the same draws in the same order whether the release comes from the normal
    chronological schedule or from a date chosen explicitly to land on a boundary the schedule
    would not otherwise reach."""
    mu = base_rate * (trend ** i) * rng.lognormvariate(0, rate_sd)
    if has_reporter:
        mu *= reporter_lift
    n = poisson(rng, mu * installs / 10000)
    within = 0
    reports = []
    for _ in range(n):
        crash = has_reporter and rng.random() < crash_share
        if crash:
            delay = rng.lognormvariate(math.log(crash_med), crash_sig)
        else:
            delay = rng.lognormvariate(math.log(ticket_med), ticket_sig)
        open_delay = int(delay) + 1

        # reported_date lags opened_date by a triage queue for tickets; crash reports have
        # no queue, so the two dates are the same day. Whether a report exists in the export
        # at all is decided by open_delay alone, exactly as before these two facts existed:
        # a report the tracker has not even logged yet clearly is not in the export either,
        # so the triage queue can only push reported_date later within the export window,
        # never pull a report into or out of it.
        if crash:
            triage_gap = 0
        else:
            triage_gap = int(rng_triage.lognormvariate(math.log(triage_med), triage_sig))

        # status: duplicate/invalid reports are not defects and never count, in the key or
        # in the curve. A handful of ordinary reports turn out to be duplicates or invalid
        # everywhere; the concentrated storm below is separate and additional.
        if rng_status.random() < ambient_bad_p:
            status = "duplicate" if rng_status.random() < 0.5 else "invalid"
        else:
            status = "open"

        if status == "open" and open_delay <= 365:
            within += 1
        opened = d + dt.timedelta(days=open_delay)
        if opened <= export:
            reported = min(d + dt.timedelta(days=open_delay + triage_gap), export)
            reports.append((reported, "crash" if crash else "ticket", status, opened))
    return reports, within, mu


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("key_dir")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--hidden", action="store_true")
    a = ap.parse_args()
    if a.seed is None:
        a.seed = 23 if a.hidden else 16
    rng = random.Random(a.seed)
    # Two independent streams so the status and triage draws never touch the sequence that
    # decides who reports, when, or through which source; every existing column is exactly what
    # it was before these two facts existed.
    rng_status = random.Random(a.seed * 1_000_003 + 11)
    rng_triage = random.Random(a.seed * 1_000_003 + 13)
    rng_pilot = random.Random(a.seed * 1_000_003 + 17)

    if a.hidden:
        product, major, n_rel = "fieldbook-mobile", 7, 40
        first_release, export = dt.date(2022, 1, 12), dt.date(2025, 8, 4)
        gap_days = (28, 40)
        base_rate, rate_sd, trend = 7.5, 0.22, 1.025      # per 10k installs; the product IS getting worse
        ticket_med, ticket_sig = 150.0, 1.2
        crash_med, crash_sig = 3.0, 0.7
        # The reporter went in partway through this product's life, and well before the horizon,
        # so the releases that have already finished collecting split into a long ticket-only
        # stretch and a shorter stretch that carries both sources. A curve pooled over all of them
        # is dominated by the ticket-only half and is far too slow for the releases being forecast,
        # which all carry the reporter. The cutover sits at a different release from the other
        # product's, so a split index carried across cannot work either.
        reporter_from = 16                                # index of the first release with the crash reporter
        crash_share, reporter_lift = 0.45, 1.35
        tol_release, tol_total = 0.17, 0.07
        installs_mu = math.log(300000)
        ambient_bad_p = 0.012
        storm_extra_mean = 8000.0
        triage_med, triage_sig = 65.0, 0.6
    else:
        product, major, n_rel = "ledgerdesk", 4, 32
        first_release, export = dt.date(2022, 9, 6), dt.date(2025, 9, 1)
        gap_days = (30, 42)
        base_rate, rate_sd, trend = 5.2, 0.25, 0.995
        ticket_med, ticket_sig = 100.0, 1.3
        crash_med, crash_sig = 4.0, 0.9
        reporter_from = 14
        crash_share, reporter_lift = 0.35, 1.25
        tol_release, tol_total = 0.20, 0.10
        installs_mu = math.log(400000)
        ambient_bad_p = 0.010
        storm_extra_mean = 14.0
        triage_med, triage_sig = 4.0, 0.5

    # A finished (>=365 day old), early, ticket-only release whose first three columns carry a
    # duplicate-ticket storm: everyone who hit the same known bug filed near-identical tickets
    # in the weeks right after the release, before support caught up and marked the repeats
    # duplicate or invalid. Well inside the cohort of finished releases on both products, so it
    # feeds the pooled ticket curve rather than a forecast release. It sits on tickets and not
    # crash reports on purpose: the crash curve is nearly flat by day 30 already, so a storm on
    # that side would barely move a share that sits close to 1 either way.
    storm_idx = 3

    releases, reports = [], []
    truth = {}
    d = first_release
    gen_kwargs = {
        "base_rate": base_rate, "trend": trend, "rate_sd": rate_sd, "reporter_lift": reporter_lift,
        "crash_share": crash_share, "crash_med": crash_med, "crash_sig": crash_sig,
        "ticket_med": ticket_med, "ticket_sig": ticket_sig, "ambient_bad_p": ambient_bad_p,
        "triage_med": triage_med, "triage_sig": triage_sig,
    }
    for i in range(n_rel):
        version = f"{major}.{i}"
        installs = int(rng.lognormvariate(installs_mu, 0.35))
        has_reporter = i >= reporter_from
        rel_reports, within, mu = gen_one_release(
            rng, rng_status, rng_triage, i, d, installs, has_reporter, export, **gen_kwargs)
        for reported, source, status, opened in rel_reports:
            reports.append((version, reported, source, status, opened))

        if i == storm_idx and storm_extra_mean > 0:
            # The duplicate-ticket storm: never counted in `within`, since none of them was
            # ever a defect. A curve that pools raw counts without the status filter treats
            # this release as having arrived far faster than it really did, which pulls the
            # whole pooled early-column share up and every young release's forecast down.
            n_storm = poisson(rng_status, storm_extra_mean)
            for _ in range(n_storm):
                sd = int(rng_status.uniform(0, 89))
                opened = d + dt.timedelta(days=sd)
                if opened <= export:
                    status = "duplicate" if rng_status.random() < 0.5 else "invalid"
                    reports.append((version, opened, "ticket", status, opened))

        releases.append((version, d, installs, has_reporter))
        truth[version] = {"reports_within_365_days": within, "true_rate_per_10k": round(mu, 3), "release_date": d.isoformat()}
        d = d + dt.timedelta(days=rng.randint(*gap_days))
        if d > export:
            break

    special_versions = {}
    if a.hidden:
        # Releases the natural schedule never lands on exactly, pinned to dates chosen instead of
        # accumulated from a random gap, so a specific boundary always has a release sitting on it:
        #   age 209  residue 29 mod 30, a forecast release, so floor(age/30) and the contract's
        #            floor((age+1)/30) disagree on how many columns it holds;
        #   age  59  a forecast release one day past a thirty-day column edge, so the same off-by-one
        #            picks the day-30 column instead of the day-60 one, a much steeper part of the
        #            curve where the two divisors are far apart;
        #   age 365  the finished-release cohort's own inclusive edge, so an off-by-one ">" instead
        #            of ">=" drops a release the contract keeps in the crash curve;
        #   age 400  kept on the forecast list though it is long past the horizon, so the twelve
        #            column cap has to fire, since floor((400+1)/30) is thirteen.
        # Each is drawn from its own independent stream keyed by its age, so tuning one never shifts
        # another's reports, and all go through gen_one_release exactly like any other release.
        #
        # The age-365 release has to be big enough, and its crash reports slow enough to arrive, that
        # dropping it from the crash pool moves an early share well past the 0.05 bar. Tickets pool
        # over every finished release, so one more barely moves that curve; crash reports pool only
        # over the reporter releases, so one heavy release carries real weight. This is a major push,
        # installed far more widely, that shipped with an early crash-reporter build phoning reports
        # home in slow batches, so its crash arrival is much slower than the pool's while its tickets
        # behave normally; it is fully caught up by day 60, so only the day-30 share moves and no
        # forecast release, which all sit at day-60 or later, is grossed up by it. The age-400
        # release's users were a little slower to file tickets, enough that its own last complete
        # column reads below its finished total, which is what a forecast that never caps its column
        # count at twelve gets wrong. The age-59 release is an ordinary reporter release.
        for age_days in (209, 365, 400, 59):
            i = len(releases)
            version = f"{major}.{i}"
            rd = export - dt.timedelta(days=age_days)
            release_kwargs = {**gen_kwargs}
            rs = random.Random(a.seed * 2_000_003 + age_days * 3 + 0)
            rst = random.Random(a.seed * 2_000_003 + age_days * 3 + 1)
            rtr = random.Random(a.seed * 2_000_003 + age_days * 3 + 2)
            mu_installs = installs_mu
            if age_days == 365:
                mu_installs = installs_mu + math.log(18.0)
                release_kwargs["crash_med"] = gen_kwargs["crash_med"] * 10.0
                release_kwargs["crash_sig"] = 0.30
            if age_days == 400:
                release_kwargs["ticket_med"] = gen_kwargs["ticket_med"] * 1.3
            installs = int(rs.lognormvariate(mu_installs, 0.35))
            has_reporter = True
            rel_reports, within, mu = gen_one_release(
                rs, rst, rtr, i, rd, installs, has_reporter, export, **release_kwargs)
            for reported, source, status, opened in rel_reports:
                reports.append((version, reported, source, status, opened))
            releases.append((version, rd, installs, has_reporter))
            truth[version] = {"reports_within_365_days": within, "true_rate_per_10k": round(mu, 3),
                               "release_date": rd.isoformat()}
            special_versions[age_days] = version

        # A crash-reporting pilot run on the release right before the official rollout: a batch
        # of its users carried an early build that phoned crash logs home in slow weekly syncs
        # rather than within days, so it genuinely carries crash-source rows in the export, even
        # though its own crash_reporter column reads "no" because the release never shipped the
        # reporter fleet-wide. The arrival curve's cohort is read off that column, not off which
        # releases happen to hold crash rows, so pooling these in without checking it visibly
        # slows the pooled curve rather than leaving it untouched. Drawn from its own stream so
        # it never shifts any other release's reports.
        pilot_i = reporter_from - 1
        pilot_version, pilot_date, _pilot_installs, _ = releases[pilot_i]
        n_pilot = poisson(rng_pilot, 9000.0)
        for _ in range(n_pilot):
            delay = rng_pilot.lognormvariate(math.log(crash_med * 10.0), crash_sig)
            opened = pilot_date + dt.timedelta(days=int(delay) + 1)
            if opened <= export:
                reports.append((pilot_version, opened, "crash", "open", opened))

    out = pathlib.Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "releases.csv", "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["version", "release_date", "installs_first_90_days", "crash_reporter"])
        for version, rd, installs, has in releases:
            w.writerow([version, rd.isoformat(), installs, "yes" if has else "no"])
    reports.sort(key=lambda r: (r[1], r[0]))
    with open(out / "reports.csv", "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["report_id", "version", "reported_date", "source", "status", "opened_date"])
        for k, (version, when, source, status, opened) in enumerate(reports, 1):
            w.writerow([f"R{k:06d}", version, when.isoformat(), source, status, opened.isoformat()])

    to_forecast = [v for v, rd, _, _ in releases if 60 <= (export - rd).days < 210]
    if a.hidden:
        # The age-59 release is younger than the 60-day floor above but is still asked for, so a
        # forecast release always sits one day past a column edge; the age-400 release is kept on
        # the list though it is long past the horizon, so the twelve-column cap has something to
        # bind on (see the special releases above).
        to_forecast.append(special_versions[59])
        to_forecast.append(special_versions[400])
    received = {}
    for version, when, source, status, opened in reports:
        received[version] = received.get(version, 0) + 1
    inst = {v: n for v, _, n, _ in releases}
    per10k = {v: round(10000 * received.get(v, 0) / inst[v], 2) for v, _, _, _ in releases}
    policy = {
        "product": product,
        "export_date": export.isoformat(),
        "horizon_days": 365,
        "forecast_releases": to_forecast,
        "tolerance_per_release": tol_release,
        "tolerance_total": tol_total,
        "reports_per_10k_installs_to_date": per10k,
    }
    with open(out / "policy.json", "w") as fh:
        json.dump(policy, fh, indent=2)
        fh.write("\n")
    kd = pathlib.Path(a.key_dir)
    kd.mkdir(parents=True, exist_ok=True)
    with open(kd / "key.json", "w") as fh:
        json.dump({"forecast_releases": to_forecast,
                   "reports_within_365_days": {v: truth[v]["reports_within_365_days"] for v in to_forecast},
                   "tolerance_per_release": tol_release, "tolerance_total": tol_total,
                   "truth": truth}, fh, indent=2)
        fh.write("\n")
    print(f"{product}: {len(releases)} releases, {len(reports)} reports to date; forecast {len(to_forecast)}: "
          + ", ".join(f"{v} {received.get(v,0)}->{truth[v]['reports_within_365_days']}" for v in to_forecast))


if __name__ == "__main__":
    main()
