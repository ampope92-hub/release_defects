"""Verifier for the release forecast.

test.sh compiles the agent's Ada itself, runs the binary once on the export that shipped and
once on another product's export it has never seen, asking each run for a different output path,
and captures what each wrote root-only.
This module only reads those captures and the keys under /opt: the number of reports each
release had actually collected by day 365. It never runs agent code.

Every bar here is stated in instruction.md, and the same bars apply to both runs.
"""
import csv
import datetime
import hashlib
import json
import os
import pathlib

import pytest

SHIPPED_RUN = pathlib.Path("/opt/run_shipped.json")
HIDDEN_RUN = pathlib.Path("/opt/run_hidden.json")
SHIPPED_KEY = pathlib.Path("/opt/golden/key.json")
HIDDEN_KEY = pathlib.Path("/opt/hidden/key.json")
SHIPPED_DATA = pathlib.Path("/app/data")
HIDDEN_DATA = pathlib.Path("/opt/hidden/data")

SHIPPED_SHA = {
    "releases.csv": "1b498bfb45113b5a8fe684b7d9401b2f6bc6c8f7be536666c83cbe9a6c5c63df",
    "reports.csv": "09dd9079c2d47da8d99bc23d2506f77915b78f04e78dd3baa3cca9fcda10e2f7",
    "policy.json": "7910b56b680dd8c47e3430fd27c6cc7278f4c72b558f66bba07372d3b13dd177",
}

RUNS = [
    pytest.param(SHIPPED_RUN, SHIPPED_KEY, SHIPPED_DATA, id="shipped"),
    pytest.param(HIDDEN_RUN, HIDDEN_KEY, HIDDEN_DATA, id="hidden"),
]


def _open(path, mode="r"):
    """Open without following a final symlink, so a read can never be redirected into /opt."""
    return os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), mode)


def _sha(path):
    with _open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _load(path):
    assert path.exists() and path.stat().st_size > 0, (
        f"{path.name}: the run wrote nothing to the output path it was given"
    )
    with _open(path) as fh:
        text = fh.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        pytest.fail(f"{path.name}: not valid JSON ({e}): {text[:200]!r}")


def _key(path):
    with open(path) as fh:
        return json.load(fh)


def _policy(data_dir):
    with open(data_dir / "policy.json") as fh:
        return json.load(fh)


def _versions(data_dir):
    with open(data_dir / "releases.csv", newline="") as fh:
        return {row["version"] for row in csv.DictReader(fh)}


STEP, HORIZON = 30, 365
AGES = [str(a) for a in range(STEP, 13 * STEP, STEP)]    # 30, 60 ... 360
SHARE_BAR = 0.05


def _forecast(run_path, data_dir):
    """The forecast object, after the shape has been checked."""
    r = _load(run_path)
    assert isinstance(r, dict) and set(r) == {"reports_by_day_365", "arrival_share"}, (
        f"{run_path.name}: expected exactly the keys reports_by_day_365 and arrival_share"
    )
    return r["reports_by_day_365"]


def _rows(data_dir):
    with open(data_dir / "releases.csv", newline="") as fh:
        rel = {r["version"]: r for r in csv.DictReader(fh)}
    with open(data_dir / "reports.csv", newline="") as fh:
        reps = list(csv.DictReader(fh))
    return rel, reps


def _true_share(data_dir, source):
    """The arrival curve the export itself carries: for each column boundary, the share of a
    finished release's eventual day-365 total that had arrived by then, pooled over the releases
    that have finished collecting. Crash reports are pooled over the finished releases that
    shipped the reporter. Computed here from the same files the run was given, so this compares
    the run against its own input rather than against anything held back.

    A duplicate or invalid report was never a defect and is dropped before it reaches the curve.
    The column a report falls into is read off opened_date, the day the user actually hit the
    bug, not reported_date, which for a ticket is only the day the tracker logged it."""
    rel, reps = _rows(data_dir)
    export = datetime.date.fromisoformat(_policy(data_dir)["export_date"])
    cohort = {
        v for v, r in rel.items()
        if (export - datetime.date.fromisoformat(r["release_date"])).days >= HORIZON
        and (source != "crash" or r["crash_reporter"] == "yes")
    }
    lags = []
    for r in reps:
        if r["version"] in cohort and r["source"] == source and r["status"] == "open":
            rd = datetime.date.fromisoformat(rel[r["version"]]["release_date"])
            lag = (datetime.date.fromisoformat(r["opened_date"]) - rd).days
            if lag <= HORIZON:
                lags.append(lag)
    if not lags:
        return None
    return {a: sum(1 for L in lags if L < int(a)) / len(lags) for a in AGES}


def test_shipped_export_unmodified():
    """The three files in /app/data are byte-identical to what shipped."""
    for name, sha in SHIPPED_SHA.items():
        assert _sha(SHIPPED_DATA / name) == sha, f"{name} was altered"


def test_nothing_was_added_to_the_export():
    """/app/data holds the three files and the README and nothing else. The instruction says to
    leave the directory alone, and a file dropped in beside them would otherwise go unnoticed."""
    want = set(SHIPPED_SHA) | {"README.md"}
    got = {p.name for p in SHIPPED_DATA.iterdir()}
    assert got == want, f"/app/data holds {sorted(got)}, not {sorted(want)}"


def _probe(tag):
    """What one probe run in test.sh did: exit status, whether anything appeared in /app/out,
    and the two output streams."""
    read = lambda part: pathlib.Path(f"/opt/argprobe_{tag}_{part}.txt").read_text()
    return (int(read("status").strip()), read("wrote").strip(), read("out"), read("err"))


@pytest.mark.parametrize("arity", [0, 1, 3, 4, 5, 6, 7, 8, 16, 40])
def test_wrong_argument_count_is_refused(arity):
    """Every wrong argument count, not just a couple of them, gets something on stderr, an empty
    stdout, exit 2 and no file. test.sh runs a spread from 0 up through 40, small counts and a
    couple of large ones, before the graded runs. The instruction promises this for any count
    other than two, so a program that special-cases a handful of small counts near two, and
    answers differently once the count grows, is still caught.

    The instruction only says a usage line is printed; it does not fix the wording, so the check
    here is the part that is actually stated: something reaches stderr. A program that prints an
    unrelated but non-empty message would still be gaming the letter of the contract, but the
    contract has no fixed text to hold it to, so nothing narrower than non-empty is enforceable."""
    status, wrote, out, err = _probe(f"argc_{arity}")
    assert status == 2, f"{arity} arguments gave exit status {status}, not 2"
    assert wrote == "nothing", f"{arity} arguments still left something in a writable location"
    assert out.strip() == "", f"{arity} arguments put this on stdout: {out[:200]!r}"
    assert err.strip() != "", f"{arity} arguments: nothing reached stderr, though the contract requires a usage line there"


@pytest.mark.parametrize("horizon", [30, 90, 364, 366, 400, 1000])
def test_another_horizon_is_refused(horizon):
    """Handed a policy asking for a horizon other than 365 the program says so on stderr, writes
    nothing and exits 3. Both graded exports say 365, so without this the key could go unread.
    Several values are tried, not only one, so a program that special-cases a single sampled
    number cannot pass by accident. Only what the instruction states is checked: stdout is not,
    since the contract says nothing about it on this path."""
    status, wrote, _out, err = _probe(f"horizon_{horizon}")
    assert status == 3, f"a {horizon} day horizon gave exit status {status}, not 3"
    assert wrote == "nothing", f"a {horizon} day horizon it cannot answer still left something in a writable location"
    assert err.strip() != "", f"a {horizon} day horizon it cannot answer passed without a word on stderr"


def _reports_by(data_dir, version, source, days):
    """Open (not duplicate or invalid) reports filed against one release from one source whose
    opened_date, the day the user actually hit the bug, falls within its first `days`."""
    rel, reps = _rows(data_dir)
    rd = datetime.date.fromisoformat(rel[version]["release_date"])
    return sum(
        1 for r in reps
        if r["version"] == version and r["source"] == source and r["status"] == "open"
        and (datetime.date.fromisoformat(r["opened_date"]) - rd).days < days
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_forecast_is_the_count_over_the_reported_share(run_path, key_path, data_dir):
    """Each forecast is the release's reports so far, one source at a time, divided by the curve
    the report itself carries at that release's last whole thirty-day column, the two sources
    added. The instruction states that step, and this holds the printed curve to being the one the
    forecast was actually divided by, rather than a rounded copy of something else."""
    r = _load(run_path)
    a, fc = r["arrival_share"], r["reports_by_day_365"]
    rel, _ = _rows(data_dir)
    export = datetime.date.fromisoformat(_policy(data_dir)["export_date"])
    for v in _policy(data_dir)["forecast_releases"]:
        age = (export - datetime.date.fromisoformat(rel[v]["release_date"])).days
        k = min((age + 1) // STEP, len(AGES))
        assert k >= 1, f"{v} has no complete thirty-day column at {age} days, which the contract rules out"
        age_key = str(STEP * k)
        want = 0.0
        for src in ("ticket", "crash"):
            n = _reports_by(data_dir, v, src, STEP * k)
            if n == 0:
                continue
            share = float(a[src][age_key])
            assert share > 0, f"{run_path.name}: {v} has {src} reports but the curve is 0 at {age_key} days"
            want += n / share
        assert abs(fc[v] - want) <= 1.0, (
            f"{run_path.name}: {v} forecasts {fc[v]}, but its reports over the first {age_key} days divided by "
            f"the report's own curve at {age_key} days come to {want:.1f}; the printed curve is not the one the "
            f"forecast used"
        )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_report_shape(run_path, key_path, data_dir):
    """One object with exactly the key reports_by_day_365, mapping exactly the versions in
    that export's policy forecast_releases to non-negative integers."""
    f = _forecast(run_path, data_dir)
    wanted = set(_policy(data_dir)["forecast_releases"])
    assert isinstance(f, dict), f"{run_path.name}: reports_by_day_365 is not an object"
    assert set(f) == wanted, (
        f"{run_path.name}: forecast versions {sorted(f)} are not the policy's {sorted(wanted)}"
    )
    assert wanted <= _versions(data_dir), f"{run_path.name}: the policy names a version not in releases.csv"
    for v, n in f.items():
        assert isinstance(n, int) and not isinstance(n, bool) and n >= 0, (
            f"{run_path.name}: {v}: {n!r} is not a non-negative integer"
        )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_each_release_within_tolerance(run_path, key_path, data_dir):
    """Every forecast is within the policy's tolerance_per_release of the count the release
    actually reached by day 365."""
    f = _forecast(run_path, data_dir)
    real = _key(key_path)["reports_within_365_days"]
    tol = _policy(data_dir)["tolerance_per_release"]
    misses = []
    for v in sorted(real):
        err = abs(f[v] - real[v]) / real[v]
        if err > tol:
            misses.append(f"{v}: forecast {f[v]}, reached {real[v]} ({err:.1%} off)")
    assert not misses, (
        f"{run_path.name}: {len(misses)} of {len(real)} releases are more than {tol:.0%} off: "
        + "; ".join(misses) + ". Reports keep arriving long after a release ships"
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_total_within_tolerance(run_path, key_path, data_dir):
    """The forecasts summed over the forecast releases are within the policy's tolerance_total
    of the summed counts those releases actually reached."""
    f = _forecast(run_path, data_dir)
    real = _key(key_path)["reports_within_365_days"]
    tol = _policy(data_dir)["tolerance_total"]
    got, want = sum(f[v] for v in real), sum(real.values())
    err = abs(got - want) / want
    assert err <= tol, (
        f"{run_path.name}: forecasts total {got} against {want} reached, {err:.1%} off, more than the {tol:.0%} allowed"
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_arrival_share_shape(run_path, key_path, data_dir):
    """arrival_share carries a ticket and a crash curve, each giving a share between 0 and 1 at
    every thirty-day boundary from 30 to 360."""
    a = _load(run_path)["arrival_share"]
    assert isinstance(a, dict) and set(a) == {"ticket", "crash"}, (
        f"{run_path.name}: arrival_share needs exactly the keys ticket and crash, got {sorted(a) if isinstance(a, dict) else type(a).__name__}"
    )
    for src in ("ticket", "crash"):
        c = a[src]
        assert isinstance(c, dict) and set(c) == set(AGES), (
            f"{run_path.name}: arrival_share.{src} needs exactly the ages {AGES}, got {sorted(c) if isinstance(c, dict) else type(c).__name__}"
        )
        for age, v in c.items():
            assert isinstance(v, (int, float)) and not isinstance(v, bool) and 0.0 <= v <= 1.0, (
                f"{run_path.name}: arrival_share.{src}[{age}] is {v!r}, not a share between 0 and 1"
            )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_arrival_share_matches_the_finished_releases(run_path, key_path, data_dir):
    """Each reported curve is within 0.05 of the one the export's own finished releases carry.
    The two sources fill in at very different speeds, so a curve built without separating them
    misses on at least one of them by far more than the bar."""
    a = _load(run_path)["arrival_share"]
    misses = []
    for src in ("ticket", "crash"):
        want = _true_share(data_dir, src)
        assert want is not None, f"{data_dir}: no finished {src} history to check against"
        for age in AGES:
            got = float(a[src][age])
            if abs(got - want[age]) > SHARE_BAR:
                misses.append(f"{src} at {age} days: reported {got:.3f}, the finished releases show {want[age]:.3f}")
    assert not misses, (
        f"{run_path.name}: {len(misses)} points are more than {SHARE_BAR} out: " + "; ".join(misses[:6])
    )
