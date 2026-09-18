"""Verifier for the release forecast.

test.sh compiles the agent's Ada itself, runs the binary once on the export that shipped and
once on another product's export it has never seen, asking each run for a different output
path, and captures what each wrote root-only.
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
    "releases.csv": "e45226fc2ad46aeb1be626637ffa752bafa573279acd5b39d9ea8049cf03e8f2",
    "reports.csv": "9e13926a0a037a96587bad18de24302144d4daa7478797402bd90fa63b7e36ad",
    "policy.json": "839c27cfc21e2e071d5713d5c0f30ba31150894f1137d31e2e34e1a29be3d6bb",
    "README.md": "8d95887488b8708c19e1b816d59148b4add98399e8243052eef4cef9b90908a5",
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
    """The arrival curve the export itself carries, as the instruction defines it: at each
    thirty-day age, the share of the finished releases' day-365 reports, taken together as one
    pile, that had been opened by then. Finished means the release has its whole day-365 record
    in the file, which the README puts at 365 days old or more on the export date. One pile, not
    the mean of the releases' own shares: both exports carry one very large, slow release (4.32,
    7.39) that holds a large part of the pile, and the equal-weight mean reads up to 0.2 higher
    at the thirty-day crash point, so the contract says which it is. The crash curve is the
    reporter's, so its pile is the finished releases whose crash_reporter column says yes; the
    README says which release carries crash rows that did not come through it. Computed here
    from the same files the run was given, so this compares the run against its own input
    rather than against anything held back.

    The README defines the day-365 count as open reports opened within 365 days of the release,
    so a duplicate or invalid report never reaches the curve and a report's age is read off
    opened_date, not reported_date. "Opened by that age" is inclusive, lag 0 to N for the N-day
    point, the same way the day-365 count is lag 0 to 365, and that reading is graded: each
    export's age-365 release got its crash reports through a reporter build that uploaded on a
    monthly sync, so they are opened on day 30, 60 or 90 exactly, and a curve that reads "by day
    30" as "before day 30" leaves that whole batch out, 0.25 low at thirty days on the shipped
    export and 0.29 on the other."""
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
    return {a: sum(1 for L in lags if L <= int(a)) / len(lags) for a in AGES}


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
    """What one probe run in test.sh did: exit status, whether the output file it was handed (if
    any) was written, the two output streams, and any leftover-file violation test.sh's
    check_after found for this call specifically. test.sh hands every invocation its output
    path as an empty file it owns inside a root-owned directory, the one thing on the box it
    can write, and "wrote" means that file's size or timestamps moved; a call of zero or one
    arguments names no output path, so test.sh records "nothing" for those and there is nothing
    else to check there. The build user has nowhere else to create anything, so the
    before/after listing is a belt, and "violation" should always be empty.

    Every capture and every record of what test.sh drew for this run is created root-only
    (umask 077, and /opt/draws is a closed directory), so the binary, running as the build user
    between two probes, can never read what has been drawn or recorded so far."""
    read = lambda part: pathlib.Path(f"/opt/argprobe_{tag}_{part}.txt").read_text()
    return (
        int(read("status").strip()), read("wrote").strip(), read("out"), read("err"),
        read("violation").strip(),
    )


DRAWN_ARITY_FILE = pathlib.Path("/opt/draws/arity.txt")
DRAWN_ARITY = DRAWN_ARITY_FILE.read_text().strip() if DRAWN_ARITY_FILE.exists() else ""


def test_an_argument_count_was_drawn():
    """test.sh draws one more argument count, from 41 to 5000, on every run and records it; the
    drawn case below is only as good as that record, so its absence fails here rather than
    passing by having nothing to check."""
    assert DRAWN_ARITY.isdigit() and 41 <= int(DRAWN_ARITY) <= 5000, (
        f"expected a drawn argument count in {DRAWN_ARITY_FILE}, found {DRAWN_ARITY!r}"
    )


@pytest.mark.parametrize("arity", [n for n in range(41) if n != 2] + ["drawn"])
def test_wrong_argument_count_is_refused(arity):
    """Every wrong argument count gets something on stderr, an empty stdout, exit 2 and nothing
    written. The instruction promises this for any count other than two; test.sh probes
    every count from zero through forty before the graded runs, forty cases rather than a
    handful, and one more drawn from 41..5000 on every run, so a program that answers one of
    them normally, or that stops refusing past a cutoff, is caught.

    The instruction only says a line is printed on stderr; it does not fix the wording, so the
    check here is the part that is actually stated: something reaches stderr and it is a line,
    newline-terminated. A program that prints an unrelated but non-empty line would still be
    gaming the letter of the contract, but the contract has no fixed text to hold it to, so
    nothing narrower is enforceable.

    Standard output is the other way round: the contract says it stays empty, and test.sh captures
    it straight from the file descriptor, so the capture is compared as the exact bytes it holds.
    A lone newline is not empty; a program whose usage path also prints a blank line to stdout
    fails here."""
    status, wrote, out, err, violation = _probe(f"argc_{arity}")
    assert status == 2, f"{arity} arguments gave exit status {status}, not 2"
    assert wrote == "nothing", f"{arity} arguments still wrote the output file it was handed"
    assert out == "", f"{arity} arguments put this on stdout, which the contract says stays empty: {out[:200]!r}"
    assert err.strip() != "" and err.endswith("\n"), (
        f"{arity} arguments: the contract requires a line on stderr, got {err[:200]!r}"
    )
    assert violation == "", f"{arity} arguments {violation}"


# (tag, the JSON text test.sh wrote after the colon); the tag names the capture files.
FIXED_HORIZONS = [(str(v), str(v)) for v in (0, 30, 90, 364, 366, 400, 1000, 99999999999999999999)]
FIXED_HORIZONS += [(v, v) for v in ("365.0", "365e0", "3.65e2", "3650e-1")]
FIXED_HORIZONS += [("str365", '"365"'), ("true", "true"), ("null", "null"), ("list365", "[365]"), ("obj365", '{"v":365}')]
DRAWN_HORIZONS_FILE = pathlib.Path("/opt/draws/horizons.txt")
DRAWN_HORIZONS = (
    [ln.strip() for ln in DRAWN_HORIZONS_FILE.read_text().splitlines() if ln.strip()]
    if DRAWN_HORIZONS_FILE.exists() else []
)


def _horizon_refused(tag, value):
    status, wrote, _out, err, violation = _probe(f"horizon_{tag}")
    assert status == 3, f"horizon_days {value} gave exit status {status}, not 3"
    assert wrote == "nothing", f"horizon_days {value}, which it cannot answer, still wrote the output file it was handed"
    assert err.strip() != "" and err.endswith("\n"), (
        f"horizon_days {value}, which it cannot answer, needs a line on stderr, got {err[:200]!r}"
    )
    assert violation == "", f"horizon_days {value}: {violation}"


@pytest.mark.parametrize("tag,value", FIXED_HORIZONS, ids=[t for t, _ in FIXED_HORIZONS])
def test_another_horizon_is_refused(tag, value):
    """Handed a policy whose horizon_days is anything but the bare token 365 the program says so
    on stderr, writes nothing and exits 3. Both graded exports say 365, so without this the key
    could go unread. The rule is universal and cannot be run to exhaustion, so it is sampled,
    and the instruction says so. Seventeen fixed values: zero, which a parser that reads it as
    "not set" and falls back to 365 answers instead of refusing; two close to 365, two far from
    it, two round figures, a twenty-digit numeral no 32-bit integer holds (a program that
    converts first and compares after has to refuse it rather than die on the conversion), four
    JSON numbers that begin with the digits 365 and are not the bare token 365 (365.0, 365e0,
    3.65e2 and 3650e-1, which a parser that stops at the first non-digit reads as 365, and which
    the instruction names as another spelling and so another horizon), and five values of
    another JSON type: the string "365", true, null, [365] and {"v":365}, which a parser that
    coerces a quoted number, or skips ahead to the first digits it finds, reads as 365. Only
    what the instruction states is checked: stdout is not, since the contract says nothing
    about it on this path."""
    _horizon_refused(tag, value)


def test_eight_horizons_were_drawn():
    """test.sh draws eight more horizons from /dev/urandom on every run and records them; the
    drawn cases below are only as good as that record, so its absence or a short list fails
    here rather than passing by having nothing to check."""
    assert len(DRAWN_HORIZONS) == 8, (
        f"expected eight drawn horizons in {DRAWN_HORIZONS_FILE}, found {DRAWN_HORIZONS}"
    )


@pytest.mark.parametrize("horizon", DRAWN_HORIZONS)
def test_a_drawn_horizon_is_refused(horizon):
    """The same promise at values nobody could have listed: four integers drawn across 1..10000
    other than 365, a negative, a fraction, an exponent form and a numeral of twenty to forty
    digits, all drawn fresh by test.sh for this run and printed in its log. A program that
    refuses the fixed values by name and answers the rest is caught here."""
    _horizon_refused(horizon, horizon)


def _reports_by(data_dir, version, source, days):
    """Open (not duplicate or invalid) reports filed against one release from one source whose
    opened_date, the day the user actually hit the bug, is by day `days` after the release."""
    rel, reps = _rows(data_dir)
    rd = datetime.date.fromisoformat(rel[version]["release_date"])
    return sum(
        1 for r in reps
        if r["version"] == version and r["source"] == source and r["status"] == "open"
        and (datetime.date.fromisoformat(r["opened_date"]) - rd).days <= days
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_a_release_sits_on_a_column_edge(run_path, key_path, data_dir):
    """A check on the fixture, not on the run. The README states that a release A days old has
    A+1 days of history in the file, the export date included, so a release exactly 60 days old
    has its whole sixty-day column (opened by day 60) and holds two complete columns, not one.
    A program that gives it only sixty days of history takes the column below on any release
    whose age is a multiple of thirty, and on an ordinary such release the two columns estimate
    the same total to within a report, so its mere presence proves nothing. Each export must
    carry a forecast release exactly on a column edge whose reports are placed so that the
    figure read off the lower column misses the count it reached by more than that policy's
    tolerance_per_release. It fails loudly if a regeneration ever drops the case.

    In the shipped export that release is 4.31, 60 days old, whose month-end close crashed for
    everyone on day 59: a hundred and fifty-odd crash reports inside its sixty-day column and
    none inside its thirty-day one, so the lower column reads about 155 against a count reached
    of 288. In the other export it is 7.41, also 60 days old, where the slow-reporter release
    pulls the pooled thirty-day crash share down to 0.72 and the lower column grosses an
    ordinary release's crash reports up by a third, 1548 against 1190."""
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
        right, lower = min(age // STEP, len(AGES)), min((age - 1) // STEP, len(AGES))
        if lower < 1 or lower == right:
            continue
        cases[f"{v} at {age} days"] = abs(figure(v, lower) - real[v]) / real[v]
    assert cases, (
        f"{data_dir}: no forecast release sits on a column edge, so floor(A/30) and "
        f"floor((A-1)/30) pick the same column for every graded release"
    )
    best = max(cases, key=cases.get)
    assert cases[best] > tol, (
        f"{data_dir}: the lower column is not separated from the right one on any forecast release; "
        f"the widest case is {best}, where reading floor((A-1)/30) lands {cases[best]:.1%} from the "
        f"count reached, inside the {tol:.0%} tolerance"
    )


@pytest.mark.parametrize("run_path,key_path,data_dir", RUNS)
def test_report_shape(run_path, key_path, data_dir):
    """One object with exactly the keys reports_by_day_365 and arrival_share; under the first,
    exactly the versions in that export's policy forecast_releases, each a non-negative
    integer."""
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
    actually reached by day 365, as a fraction of that count. The method section of the README says
    how the forecast is made; this holds what it produces to the record."""
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
    misses on at least one of them by far more than the bar. Each fact the README states, and
    the instruction's "opened by that age", moves a point of the shipped curve by more than the
    bar on its own: a release exactly 365 days old left out of the crash curve, 0.25 at 30 days;
    the pilot release's crash rows pooled in, 0.16 at 30 days; duplicate and invalid reports
    pooled in, 0.14 at 90 days on the ticket curve; ages read off reported_date, 0.10 at 30
    days; "by day 30" read as "before day 30", 0.25 at 30 days."""
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
