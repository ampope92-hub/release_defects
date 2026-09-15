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
import decimal
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
    "releases.csv": "b905ef05b956bfc56a553c72d33b2414d403d0f0a4f465c014531f35655af986",
    "reports.csv": "dbc7afa5796c78fec19989afcb830600c89f1b783a5ad6c20225e86c0cb2f08a",
    "policy.json": "5f644618bcbcf6ac9bfc544bc99aab89f09d80141403eaacec37885b177c09aa",
    "README.md": "73d8a22b0ee7f6502811589477b8d5f0b5a444a7689891b2341dcbfbe52e751f",
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


def _load_as_printed(path):
    """The same document, with every number kept as the text the run printed (a Decimal), so a
    share's printed precision is known: 0.10 is exact to a hundredth, 0.1004 to a ten-thousandth."""
    with _open(path) as fh:
        text = fh.read()
    return json.loads(text, parse_float=decimal.Decimal, parse_int=decimal.Decimal)


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
    """Every file in /app/data, including the README, is byte-identical to what shipped."""
    for name, sha in SHIPPED_SHA.items():
        path = SHIPPED_DATA / name
        assert path.exists(), f"{name} is gone from /app/data"
        assert _sha(path) == sha, f"{name} was altered"


def test_nothing_was_added_to_the_export():
    """/app/data holds exactly the shipped files and nothing else. The instruction says the whole
    directory stays as it arrived, and a file dropped in beside them would otherwise go unnoticed."""
    want = set(SHIPPED_SHA)
    got = {p.name for p in SHIPPED_DATA.iterdir()}
    assert got == want, f"/app/data holds {sorted(got)}, not {sorted(want)}"


def _probe(tag):
    """What one probe run in test.sh did: exit status, whether the output path it was given (if
    any) exists afterward, the two output streams, and any leftover-file violation test.sh's
    check_after found for this call specifically. "wrote" answers only for
    the output path named in the call; a call of zero or one arguments names no output path, so
    test.sh always records "nothing" for those and there is nothing else to check there. Every
    probe is bracketed by the same before/after check a graded run gets, not only the two graded
    runs, so a probe can no longer plant something a later call's own baseline would treat as
    having always been there."""
    read = lambda part: pathlib.Path(f"/opt/argprobe_{tag}_{part}.txt").read_text()
    return (
        int(read("status").strip()), read("wrote").strip(), read("out"), read("err"),
        read("violation").strip(),
    )


@pytest.mark.parametrize("arity", [n for n in range(41) if n != 2])
def test_wrong_argument_count_is_refused(arity):
    """Every wrong argument count gets something on stderr, an empty stdout, exit 2 and no output
    file created. The instruction bounds the promise to the counts from zero through forty, and
    test.sh probes every one of them before the graded runs, so the promise and the grading are
    the same set: there is no count inside it a program could answer differently and still pass.

    The instruction only says a usage line is printed; it does not fix the wording, so the check
    here is the part that is actually stated: something reaches stderr. A program that prints an
    unrelated but non-empty message would still be gaming the letter of the contract, but the
    contract has no fixed text to hold it to, so nothing narrower than non-empty is enforceable.

    Standard output is the other way round: the contract says it stays empty, and test.sh captures
    it straight from the file descriptor, so the capture is compared as the exact bytes it holds.
    A lone newline is not empty; a program whose usage path also prints a blank line to stdout
    fails here, where a stripped comparison used to let it through."""
    status, wrote, out, err, violation = _probe(f"argc_{arity}")
    assert status == 2, f"{arity} arguments gave exit status {status}, not 2"
    assert wrote == "nothing", f"{arity} arguments still created the output file it was told to use"
    assert out == "", f"{arity} arguments put this on stdout, which the contract says stays empty: {out[:200]!r}"
    assert err.strip() != "", f"{arity} arguments: nothing reached stderr, though the contract requires a usage line there"
    assert violation == "", f"{arity} arguments {violation}"


@pytest.mark.parametrize("horizon", [30, 90, 364, 366, 400, 1000, 99999999999999999999])
def test_another_horizon_is_refused(horizon):
    """Handed a policy asking for one of the seven horizons the instruction names the program says
    so on stderr, creates no output file and exits 3. Both graded exports say 365, so without this
    the key could go unread. These seven are exactly the seven the contract states, so nothing is
    promised here that is not graded: staging a whole export per horizon costs a copy of the
    report log, which rules out the exhaustive range the argument counts above get. The last is a
    twenty-digit numeral, a horizon no 32-bit integer holds, so a program that converts first and
    compares after has to refuse it rather than die on the conversion. Only what the instruction
    states is checked: stdout is not, since the contract says nothing about it on this path."""
    status, wrote, _out, err, violation = _probe(f"horizon_{horizon}")
    assert status == 3, f"a {horizon} day horizon gave exit status {status}, not 3"
    assert wrote == "nothing", f"a {horizon} day horizon it cannot answer still created the output file it was told to use"
    assert err.strip() != "", f"a {horizon} day horizon it cannot answer passed without a word on stderr"
    assert violation == "", f"a {horizon} day horizon {violation}"


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


def _reports_on(data_dir, version, source, day):
    """Open reports filed against one release from one source whose opened_date falls exactly
    `day` days after it shipped: the reports that separate a lag under `day` from a lag of `day`
    or less."""
    rel, reps = _rows(data_dir)
    rd = datetime.date.fromisoformat(rel[version]["release_date"])
    return sum(
        1 for r in reps
        if r["version"] == version and r["source"] == source and r["status"] == "open"
        and (datetime.date.fromisoformat(r["opened_date"]) - rd).days == day
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_a_release_sits_on_its_column_edge(run_path, key_path, data_dir):
    """The export itself has to carry the case that separates the instruction's "opened lag under
    N days" from "N days or less", or the check below cannot tell the two readings apart. This is
    a check on the fixture, not on the run: at least one forecast release must carry a batch of
    open reports opened exactly on its last complete column edge, big enough that dividing them by
    the curve at that edge moves the release's figure by far more than the one report the
    consistency check allows. It fails loudly if a regeneration ever drops the case.

    In the shipped export that release is 4.28: fourteen tickets all opened sixty days after it
    shipped, against a ticket share of about 0.40 at the sixty-day column, which is thirty-four
    reports on a forecast of a hundred and ninety-four."""
    rel, _ = _rows(data_dir)
    export = datetime.date.fromisoformat(_policy(data_dir)["export_date"])
    effects = {}
    for v in _policy(data_dir)["forecast_releases"]:
        age = (export - datetime.date.fromisoformat(rel[v]["release_date"])).days
        edge = STEP * min((age + 1) // STEP, len(AGES))
        moved = 0.0
        for src in ("ticket", "crash"):
            want = _true_share(data_dir, src)
            share = want[str(edge)] if want else 0.0
            n = _reports_on(data_dir, v, src, edge)
            if n and share > 0:
                moved += n / share
        effects[f"{v} at {edge} days"] = moved
    best = max(effects, key=effects.get)
    assert effects[best] > 10.0, (
        f"{data_dir}: no forecast release carries a batch on its own column edge; the largest "
        f"move a lag<=N reading would make is {best} by {effects[best]:.1f} reports, which the "
        f"consistency check's one-report allowance can swallow"
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_a_release_sits_one_day_past_a_column_edge(run_path, key_path, data_dir):
    """The export has to carry the case that separates the instruction's floor((A+1)/30) complete
    columns from the ordinary off-by-one floor(A/30), or the column rule is stated and never
    exercised: a release whose age has remainder 29 is the only kind on which the two disagree,
    and on an ordinary such release the two columns estimate the same total to within a report,
    so its mere presence proves nothing. This is a check on the fixture, not on the run: at least
    one forecast release must be one day past a column edge AND carry reports placed so that the
    figure read off the lower column misses the count it reached by more than the policy's own
    tolerance_per_release, and differs from the right column's figure by far more than the one
    report the consistency check allows, whatever precision the curve is printed to. It fails
    loudly if a regeneration ever drops the case.

    In the shipped export that release is 4.31, 59 days old, whose month-end close crashed for
    everyone on day 58: a hundred and fifty-odd crash reports inside its sixty-day column and
    none inside its thirty-day one, so the lower column reads about 216 against a count reached
    of 360. In the other export it is 7.41, also 59 days old, where the slow-reporter release
    pulls the pooled thirty-day crash share down to 0.69 and the lower column grosses an
    ordinary release's crash reports up by a quarter."""
    rel, _ = _rows(data_dir)
    export = datetime.date.fromisoformat(_policy(data_dir)["export_date"])
    real = _key(key_path)["reports_within_365_days"]
    tol = _policy(data_dir)["tolerance_per_release"]
    want = {src: _true_share(data_dir, src) for src in ("ticket", "crash")}

    def figure(v, k):
        total = 0.0
        for src in ("ticket", "crash"):
            n = _reports_by(data_dir, v, src, STEP * k)
            share = want[src][str(STEP * k)] if want[src] else 0.0
            if n and share > 0:
                total += n / share
        return total

    cases = {}
    for v in _policy(data_dir)["forecast_releases"]:
        age = (export - datetime.date.fromisoformat(rel[v]["release_date"])).days
        right, lower = min((age + 1) // STEP, len(AGES)), min(age // STEP, len(AGES))
        if lower < 1 or lower == right:
            continue
        r, w = figure(v, right), figure(v, lower)
        cases[f"{v} at {age} days"] = (abs(r - w), abs(w - real[v]) / real[v])
    assert cases, (
        f"{data_dir}: no forecast release is one day past a column edge, so floor((A+1)/30) and "
        f"floor(A/30) pick the same column for every graded release"
    )
    best = max(cases, key=lambda c: cases[c][1])
    moved, off = cases[best]
    assert moved > 10.0 and off > tol, (
        f"{data_dir}: the lower column is not separated from the right one on any forecast release; "
        f"the widest case is {best}, where reading floor(A/30) moves the figure by {moved:.1f} reports "
        f"and lands {off:.1%} from the count reached, inside the {tol:.0%} tolerance"
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_forecast_is_the_count_over_the_reported_share(run_path, key_path, data_dir):
    """Each forecast is the release's reports so far, one source at a time, divided by the curve
    the report itself carries at that release's last whole thirty-day column, the two sources
    added. The instruction states that step and says the forecast is checked against the printed
    curve with each share taken as exact only to its last printed digit: a share printed as 0.10
    stands for any divisor from 0.095 to 0.105, so the recomputed forecast is a range, not a
    point, and the printed forecast has to fall inside it, within one report for the rounding to
    an integer. A curve printed to two decimals passes as readily as one printed to ten; what
    cannot pass is a forecast that was not divided by the curve beside it."""
    r = _load_as_printed(run_path)
    a, fc = r["arrival_share"], r["reports_by_day_365"]
    rel, _ = _rows(data_dir)
    export = datetime.date.fromisoformat(_policy(data_dir)["export_date"])
    for v in _policy(data_dir)["forecast_releases"]:
        age = (export - datetime.date.fromisoformat(rel[v]["release_date"])).days
        k = min((age + 1) // STEP, len(AGES))
        assert k >= 1, f"{v} has no complete thirty-day column at {age} days, which the contract rules out"
        age_key = str(STEP * k)
        low, high = 0.0, 0.0
        for src in ("ticket", "crash"):
            n = _reports_by(data_dir, v, src, STEP * k)
            if n == 0:
                continue
            share = a[src][age_key]
            assert isinstance(share, decimal.Decimal) and share > 0, (
                f"{run_path.name}: {v} has {src} reports but the curve is {share!r} at {age_key} days"
            )
            # Half a unit in the last printed place: the widest the divisor could have been and
            # still have printed as this figure.
            half = decimal.Decimal(1).scaleb(share.as_tuple().exponent) / 2
            lo, hi = float(share - half), float(share + half)
            low += n / hi
            high += n / lo if lo > 0 else float("inf")
        assert low - 1.0 <= float(fc[v]) <= high + 1.0, (
            f"{run_path.name}: {v} forecasts {fc[v]}, but its reports over the first {age_key} days divided by "
            f"the report's own curve at {age_key} days, each share read to its last printed digit, come to "
            f"between {low:.1f} and {high:.1f}; the printed curve is not the one the forecast used"
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
