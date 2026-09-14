#!/bin/bash

# Verifier entrypoint. Runs in the verifier container, not the agent's: it sees only the paths
# declared in `artifacts`. All tooling is baked into tests/Dockerfile; nothing is fetched here.

set -uo pipefail

mkdir -p /logs/verifier
echo 0 > /logs/verifier/reward.txt

# Fold stderr into stdout: only stdout survives into the feedback bundle.
exec 2>&1

as_runner() {
  setpriv --clear-groups --no-new-privs --reuid runner --regid runner "$@"
}

# A fresh, unpredictable basename for one run's output file, so the two graded runs and every
# argument-count and horizon probe ask for a name drawn from the very same generator. Nothing in
# the basename can tell a probe apart from a graded run any more (a fixed name like argprobe.json
# used to do exactly that; see the cheat_probe_basename arm).
rand_name() {
  local hex
  hex="$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ -n "$hex" ] || hex="$RANDOM$RANDOM$RANDOM$RANDOM"
  printf '%s.json' "$hex"
}

# The shipped tests/ directory lands here at runtime, so the verifier's own code sits under
# /tests just as agent-authored code is about to run. Close it to the build user first: root still
# reads it, `runner` cannot traverse it. If it is still reachable the run is abandoned with reward
# 0 rather than graded. `test -r` on a file is not enough on its own: access(2) answers true for a
# chmod 700 directory the user cannot actually read, so a listing of the key directory is tried too.
chmod 700 /tests 2>/dev/null || true
chmod 700 /logs/verifier 2>/dev/null || true
if as_runner bash -c 'test -r /tests/test_outputs.py || ls /opt/golden || ls /opt/hidden' >/dev/null 2>&1; then
  echo "FATAL: /tests or the answer keys are still reachable by the unprivileged build user;"
  echo "the verifier's code and keys are exposed to agent-authored code, so this run cannot be graded."
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi
echo "verifier files closed to the unprivileged build user"

# The shipped export is checked back against its hashes by pytest, so it stays where it landed,
# read-only. A root-owned pristine copy of the agent's project is kept so each build starts from
# exactly what was collected; cp -a keeps the agent's file modes, so write bits are stripped.
chmod -R a-w /app/data
# A root-owned copy of the export's regular files, taken before any agent code runs. The horizon
# probe is staged from this copy and never from /app/data itself, so a symlink planted in the
# export can never be dereferenced by root into a directory the build user then reads.
mkdir -p /opt/data_pristine
find /app/data -maxdepth 1 -type f -exec cp -- {} /opt/data_pristine/ \;
chmod -R go-w /opt/data_pristine
cp -a /app/forecast /opt/forecast_pristine
chmod -R go-w /opt/forecast_pristine

# The task states the tool lives in Ada and that the box carries nothing past the Ada runtime.
# This image ships a Python interpreter because pytest scores the result with it, and the
# compiler and shells are here because the tool has to be built. All of them, and every other
# executable on the system paths, are closed to the build user for the seconds the binary runs,
# so the forecast cannot come out of a python or awk the binary shells out to, and reopened
# straight after. Root is unaffected. This is a closure by construction, found by walking the
# system directories rather than by naming files, so it holds regardless of what this image
# happens to ship.
TOOLS="$( { find /usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin -xdev -type f -perm /111 2>/dev/null;
             for l in $(find /usr/local/bin /usr/bin /bin -xdev -type l 2>/dev/null); do t="$(readlink -f "$l")"; [ -f "$t" ] && echo "$t"; done; } \
  | sort -u | grep -v -E 'ld-linux|/ld\.so$' | grep -v -x -F -e "$(readlink -f /usr/bin/env)")"
# /usr/bin/env is what setpriv starts each run through, so it stays open; it is not a route to
# anything, since whatever it executes is checked on its own. Only regular files are listed: the
# merged /bin is itself a symlink to /usr/bin, and closing that directory would shut the whole
# tree, launcher included. The dynamic loader is deliberately excluded from this closure (see
# below): the panel has three times rejected making an ordinary dynamically linked binary
# unlaunchable as the price of this closure, so the loader itself is left alone and the value
# this closure gives up is only the one attack that needed a *second*, separately-launched
# dynamically linked binary. A helper compiled from the agent's own collected source is not a
# route around anything: only src/*.adb|ads is ever compiled, so the same standard-library-only
# code is all that could run either way.
close_tools() { for f in $TOOLS; do chmod 750 "$f" 2>/dev/null || true; done; }
open_tools()  { for f in $TOOLS; do chmod 755 "$f" 2>/dev/null || true; done; }
trap 'open_tools' EXIT

# Compile the collected sources ourselves, as the build user, from the directory the instruction
# documents. The agent's build.sh is not run: the instruction says the forecast comes out of the
# Ada, and a build script that did the work some other way would otherwise pass every check with
# the stub still in place. The binary that build produces is what is run.
#
# The build directory holds only Ada units copied out of src/: every *.adb and *.ads file the
# project shipped there, and nothing else. A submission split into forecast.adb plus ordinary
# helper packages builds exactly as it would from the project directory itself, with the same
# command build.sh documents. A helper written any other way (a native binary, a script, an
# object file) is simply never copied in, so it cannot be linked into the program or reached by
# its build: "the standard library and nothing else" is enforced by what the compiler is ever
# given, not by scanning what the project happens to contain.
rm -rf /app/forecast /app/build_iso
cp -a /opt/forecast_pristine /app/forecast
# Only Ada source ever survives under src/: an ordinary GNAT project built with the documented
# `gnatmake -I src` command needs nothing else there, and the instruction now says so. Anything
# else the agent left there is deleted now, before the run even starts, rather than merely
# losing its read and execute bits later -- so there is nothing left on disk for the later
# point-in-time checks to have to catch. /opt/forecast_pristine, the copy the build step below
# still reads from, keeps the original files; only the collected working copy is stripped.
find /app/forecast/src -mindepth 1 -maxdepth 1 -type f ! -name '*.adb' ! -name '*.ads' -delete 2>/dev/null || true
mkdir -p /app/build_iso/src
find /app/forecast/src -maxdepth 1 -type f \( -name '*.adb' -o -name '*.ads' \) \
     -exec cp -- {} /app/build_iso/src/ \;
chown -R runner:runner /app/forecast /app/build_iso /app/out
rm -rf /app/forecast/forecast /app/forecast/obj
setsid \
  setpriv --clear-groups --no-new-privs --reuid runner --regid runner \
  bash -c 'cd /app/build_iso && mkdir -p obj && gnatmake -O2 -D obj -Isrc -o forecast src/forecast.adb' &
bpid=$!
wait "$bpid"
bstatus=$?
echo "build exit status: $bstatus"
# setsid makes the child a session leader, so its group id is its own pid and can be addressed
# directly. Reading it out of /proc races setsid and has taken down the verifier on sibling tasks.
kill -TERM -- -"$bpid" 2>/dev/null || true
kill -KILL -- -"$bpid" 2>/dev/null || true
as_runner bash -c 'kill -9 -1' 2>/dev/null || true
if [ "$bstatus" -eq 0 ] && [ -x /app/build_iso/forecast ]; then
  mv /app/build_iso/forecast /app/forecast/forecast
  chown runner:runner /app/forecast/forecast
else
  echo "the collected sources did not build into /app/forecast/forecast"
fi
rm -rf /app/build_iso

# Closing the project and the system paths still leaves scratch space the build user can write
# to and then execute from. Ada reaches libc through Interfaces.C, which is part of the standard
# library, so a program could carry a helper as bytes, drop it in /tmp, mark it executable and
# run it. The task says the numbers come out of the Ada, so every single invocation below -- the
# two graded runs AND every argument-count and horizon probe, not only the two graded runs -- is
# bracketed by the same pair of checks, scratch space and the collected directories alike (/app
# itself included, not only its known subdirectories, so nothing dropped as a sibling of
# forecast/, out/ or data/ escapes the sweep by sitting outside all three), and anything newly
# executable throws that invocation's own output away. A probe used to be checked only for the
# output path it named, which let something planted during a probe sit unnoticed until a LATER
# snapshot's "before" picture, since that picture was only ever taken right before the two graded
# runs; every invocation now takes and checks its own before/after pair, so nothing has anywhere
# to hide between one call and the next.
scratch_list() {
  find /tmp /var/tmp /dev/shm /home/runner /app -xdev -type f -perm /111 2>/dev/null | sort -u
}
# Under /app the sweep is not limited to executables: the instruction says the only new file an
# invocation may leave there is the JSON it was asked for (or nothing at all, for a call that
# named no output path), so the whole tree is listed on either side of every call, and every new
# FILE of any kind (a regular file, a symlink, a fifo, a device) other than the one it was allowed
# discards its output. A plain directory is not a file and is not listed, matching the
# instruction's own wording; a probe's own staging directory is created before its bracket opens
# and removed only after it closes, so it never looks new to this. Scratch space and the runner's
# home are the program's own and stay held only to the executable rule above.
app_list() {
  find /app -xdev -mindepth 1 ! -type d 2>/dev/null | sort -u
}
snapshot_before() {
  scratch_list > /opt/scratch_before.txt
  app_list > /opt/app_before.txt
}
# check_after <keep-path>: call once tools are reopened. <keep-path> is the one path this
# invocation was allowed to write (empty when it named none). Prints a one-line description of
# any violation, empty when clean, and removes whatever it found immediately, so nothing an
# invocation leaves behind can ever look like it was "already there" to the NEXT invocation's own
# before picture.
check_after() {
  local keep="$1" left added desc=""
  scratch_list > /opt/scratch_after.txt
  app_list > /opt/app_after.txt
  if ! left="$(comm -13 /opt/scratch_before.txt /opt/scratch_after.txt)"; then left=""; fi
  if [ -n "$left" ]; then
    desc="left something executable in scratch space ($left)"
    printf '%s\n' "$left" | while IFS= read -r f; do [ -n "$f" ] && rm -f -- "$f"; done
  fi
  if ! added="$(comm -13 /opt/app_before.txt /opt/app_after.txt | grep -v -x -F -- "$keep")"; then added=""; fi
  if [ -n "$added" ]; then
    [ -n "$desc" ] && desc="$desc; "
    desc="${desc}left a new path under /app other than the file it was asked for ($added)"
    printf '%s\n' "$added" | while IFS= read -r f; do [ -n "$f" ] && rm -f -- "$f"; done
  fi
  printf '%s' "$desc"
}

# run_once <data-dir> <output-path> <capture-path>: run the built binary on an export, as the
# build user, with every tool closed, from /app/forecast, and move what it wrote to a root-only
# path. The output path is the second argument the instruction documents, and the two runs ask for
# a different, freshly randomized name each (rand_name, the same generator every probe below uses
# too), so a program that ignores the argument and writes a fixed file is caught rather than
# graded, and nothing about the name itself tells this run apart from a probe. Only a regular file
# is ever staged: the binary cannot read the keys, but it can drop a symlink at the output path
# pointing into /opt, and pytest, running as root, would then read the verifier's own truth back
# as the agent's figures.
run_once() {
  local data="$1" asked="$2" out="$3" pid violation
  rm -f "$asked"
  # Closing the system paths stops the binary shelling out to a python or an awk, but the project
  # directory is the agent's own and is collected as an artifact, so an executable helper shipped
  # inside it would still run. Everything under /app/forecast except the binary this verifier just
  # built loses its execute bits for the graded runs.
  # /app/out and the data directory are collected artifact paths the agent can populate too, so
  # they are swept on the same terms; only the binary this verifier built keeps its execute bit.
  find /app/forecast /app/out "$data" -type f -perm /111 \
       ! -samefile /app/forecast/forecast -exec chmod a-x {} + 2>/dev/null || true
  # An execute bit is not what a shared object needs. The loader only has to read one, so inside
  # the project and the output directory nothing but the built binary stays readable either. The
  # export directory keeps its read bits, since that is the input; a file planted there instead is
  # caught by the check that /app/data holds the shipped files and nothing else.
  find /app/forecast /app/out -type f \
       ! -samefile /app/forecast/forecast -exec chmod a-r {} + 2>/dev/null || true
  snapshot_before
  close_tools
  # A root shell sets the working directory the instruction documents and the runner's HOME, then
  # hands off with exec to setpriv, whose own exec is the binary itself. The dynamic loader is
  # not closed here (see the TOOLS comment above): the binary loads normally, and so would a
  # second dynamically linked binary the program went on to launch itself, since only the
  # standard library and the agent's own collected source are ever available to run either way.
  setsid bash -c 'cd /app/forecast && export HOME=/home/runner && exec setpriv --clear-groups --no-new-privs --reuid runner --regid runner /app/forecast/forecast "$1" "$2"' _ "$data" "$asked" &
  pid=$!
  wait "$pid"
  echo "run exit status: $? ($data -> $asked)"
  open_tools
  kill -TERM -- -"$pid" 2>/dev/null || true
  kill -KILL -- -"$pid" 2>/dev/null || true
  as_runner bash -c 'kill -9 -1' 2>/dev/null || true
  violation="$(check_after "$asked")"
  if [ -n "$violation" ]; then
    echo "the run $violation, so its output is discarded"
    rm -f "$asked"
  fi
  if [ -L "$asked" ] || [ ! -f "$asked" ]; then
    echo "no regular file was produced at $asked for $data (absent, or not a regular file)"
    rm -f "$asked"
  else
    mv "$asked" "$out"
    chown root:root "$out" 2>/dev/null || true
    chmod 600 "$out" 2>/dev/null || true
  fi
}

# The instruction says what the program does when it is handed anything other than two
# arguments: a usage line on standard error, nothing on standard output, exit 2, no output file
# created. It promises that for a spread of counts, from zero through forty, so a spread from 0
# up through 40, including a run of consecutive small counts and a couple of large ones, is
# probed below, not a handful clustered near two. The check is only of the output path the call
# actually names (the second argument, when there is one, exactly as the graded runs use it): a
# run of zero or one arguments names no output path at all, so there is nothing to check there
# beyond exit status and stderr -- and, as of this round, the same leftover-executable and
# new-app-file bracket every graded run gets (see check_after above).
probe_args() {
  local tag="$1"; shift
  # The second positional argument, when there is one, is the output path this call asked for
  # (a freshly randomized name from the caller, same generator the graded runs use); it is only
  # ever cleaned up here, never chosen here, so a probe's basename is decided the same way a
  # graded run's is and this function cannot itself reintroduce a fixed one.
  local outpath="${2:-}" violation
  [ -n "$outpath" ] && rm -f "$outpath"
  snapshot_before
  close_tools
  # Same launch chain as run_once: a root shell sets cwd and HOME, then execs setpriv, whose own
  # first exec is the forecast binary. Earlier this ran the binary through setpriv -> env instead,
  # so a graded run and a probe run reached the binary through different parent processes; now
  # both go through the identical chain and only the policy content (or the horizon value, for a
  # horizon probe) differs between them.
  setsid bash -c 'cd /app/forecast && export HOME=/home/runner && exec setpriv --clear-groups --no-new-privs --reuid runner --regid runner /app/forecast/forecast "$@"' _ "$@" \
    > "/opt/argprobe_${tag}_out.txt" 2> "/opt/argprobe_${tag}_err.txt" &
  local ppid=$!
  wait "$ppid"
  local pstatus=$?
  open_tools
  kill -TERM -- -"$ppid" 2>/dev/null || true
  kill -KILL -- -"$ppid" 2>/dev/null || true
  as_runner bash -c 'kill -9 -1' 2>/dev/null || true
  echo "$pstatus" > "/opt/argprobe_${tag}_status.txt"
  violation="$(check_after "$outpath")"
  printf '%s' "$violation" > "/opt/argprobe_${tag}_violation.txt"
  if [ -n "$outpath" ] && { [ -e "$outpath" ] || [ -L "$outpath" ]; }; then
    echo wrote > "/opt/argprobe_${tag}_wrote.txt"
  else
    echo nothing > "/opt/argprobe_${tag}_wrote.txt"
  fi
  [ -n "$outpath" ] && rm -f "$outpath"
  echo "  $tag: exit $pstatus, $(cat "/opt/argprobe_${tag}_wrote.txt") written${violation:+, VIOLATION: $violation}"
}

echo "=== what it does when the argument count is wrong ==="
for n in 0 1 3 4 5 6 7 8 16 40; do
  case "$n" in
    0) probe_args "argc_0" ;;
    1) probe_args "argc_1" /app/data ;;
    *)
      extras=()
      for ((e = 3; e <= n; e++)); do
        extras+=("extra$((e - 2))")
      done
      probe_args "argc_${n}" /app/data "/app/out/$(rand_name)" "${extras[@]}"
      ;;
  esac
done

# The horizon is the one policy figure the program is told to refuse. Both graded exports say 365,
# so without cases of its own nothing would stop a program that never reads the key. Several other
# values are tried, close to 365, far from it and one too long for any integer type, so a program
# that special-cases the one sampled number cannot pass by accident.
#
# Staged under a name drawn from the same bare mktemp template as the other product's export
# below, not a distinguishing prefix like "horizon_": a name that says what the directory is for
# would let a program single out the probe by argv and answer it differently from a graded run.
# The output path asked for is a fresh rand_name too, the same generator a graded run gets, not
# the fixed argprobe.json this used to be: nothing about either name says which kind of run it is.
echo "=== what it does when the policy asks for another horizon ==="
run_horizon_probe() {
  local value="$1" dir
  dir="$(mktemp -d /app/XXXXXXXXXX)"
  find /opt/data_pristine -maxdepth 1 -type f ! -name policy.json -exec cp -- {} "$dir"/ \;
  sed "s/\"horizon_days\"[[:space:]]*:[[:space:]]*365/\"horizon_days\": ${value}/" \
    /opt/data_pristine/policy.json > "$dir/policy.json"
  grep -q "\"horizon_days\": ${value}" "$dir/policy.json" \
    || echo "WARNING: the horizon probe for ${value} did not get a changed policy, so it proves nothing"
  # Root keeps ownership: the binary only has to read the export, and a directory it owned would
  # let it restore write bits and rewrite the policy from inside the run.
  chmod -R a-w,a+rX "$dir"
  probe_args "horizon_${value}" "$dir" "/app/out/$(rand_name)"
  rm -rf "$dir"
}
# The last value is a twenty-digit numeral: another horizon, and one no 32-bit integer holds, so
# a program that converts the figure before comparing it has to refuse it rather than die on it.
for h in 30 90 364 366 400 1000 99999999999999999999; do
  run_horizon_probe "$h"
done

chown root:root /opt/argprobe_*.txt 2>/dev/null || true
chmod 600 /opt/argprobe_*.txt 2>/dev/null || true

echo "=== the export that shipped in the agent's image ==="
run_once /app/data "/app/out/$(rand_name)" /opt/run_shipped.json

# Then the other product. Its export is staged only now, after the build has finished and every
# process it started is gone, into a fresh directory the binary has never seen, so nothing that
# ran during compilation could have had it on disk to read. Same bare template as the horizon
# probe above: this directory's name gives no more away than that one's does.
staged="$(mktemp -d /app/XXXXXXXXXX)"
cp /opt/hidden/data/*.csv /opt/hidden/data/policy.json /opt/hidden/data/README.md "$staged"/
# Root-owned and read-only to the build user, so nothing the binary does during its run can
# change the export it is being graded on.
chmod -R a-w,a+rX "$staged"
echo "=== the same binary on the other product's export ==="
run_once "$staged" "/app/out/$(rand_name)" /opt/run_hidden.json
rm -rf "$staged"

# Nothing the agent started may be alive while pytest runs or while the reward is written.
as_runner bash -c 'kill -9 -1' 2>/dev/null || true

# -P keeps the working directory off sys.path, so a pytest.py dropped into /app by the binary
# cannot shadow the suite. The interpreter is called by full path, not through PATH.
cd /tests
/usr/local/bin/python3 -P -m pytest -o cache_dir=/tmp/pytest_cache \
  --ctrf /logs/verifier/ctrf.json /tests/test_outputs.py -rA
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi

# Harbor grades from reward.txt, never from this script's exit status.
exit 0
