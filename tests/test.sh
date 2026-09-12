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
# straight after. Root is unaffected. A GNAT binary needs no launcher: it links the Ada runtime
# as a shared library, which lives outside the executable paths and stays readable.
TOOLS="$( { find /usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin -xdev -type f -perm /111 2>/dev/null;
             for l in $(find /usr/local/bin /usr/bin /bin -xdev -type l 2>/dev/null); do t="$(readlink -f "$l")"; [ -f "$t" ] && echo "$t"; done; } \
  | sort -u | grep -v -E 'ld-linux|/ld\.so$' | grep -v -x -F -e "$(readlink -f /usr/bin/env)")"
# /usr/bin/env is what setpriv starts each run through, so it stays open; it is not a route to
# anything, since whatever it executes is checked on its own. Only regular files are listed: the
# merged /bin is itself a symlink to /usr/bin, and closing that directory would shut the whole
# tree, launcher included. The dynamic loader is not in this list; it is handled on its own below,
# only for the graded runs, because closing it needs the launch arranged around it.
close_tools() { for f in $TOOLS; do chmod 750 "$f" 2>/dev/null || true; done; }
open_tools()  { for f in $TOOLS; do chmod 755 "$f" 2>/dev/null || true; done; }

# The dynamic loader. A native helper the program drops in scratch and marks executable needs the
# loader to run, and closing every interpreter does not touch it, so for the two graded runs the
# loader is closed to the build user too. It cannot simply go in TOOLS: a dynamically linked program
# whose loader is unreadable does not start at all, the built binary included. The graded runs get
# around that by launching the binary as setpriv's very first exec, which the kernel maps before the
# credential change fully takes effect, so the binary itself loads while every later exec it makes,
# an interpreter or a native helper alike, is held to the closed loader and cannot run. Root keeps
# access throughout (750 is root-readable), so the launch's own shell and setpriv are unaffected.
LOADER="$(readlink -f "$(ldd /bin/ls 2>/dev/null | grep -o '/[^ ]*ld-linux[^ ]*' | head -1)" 2>/dev/null)"
[ -e "$LOADER" ] || LOADER=/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
close_loader() { chmod 750 "$LOADER" 2>/dev/null || true; }
open_loader()  { chmod 755 "$LOADER" 2>/dev/null || true; }
trap 'open_tools; open_loader' EXIT

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

# run_once <data-dir> <output-path> <capture-path>: run the built binary on an export, as the
# build user, with every tool closed, from /app/forecast, and move what it wrote to a root-only
# path. The output path is the second argument the instruction documents, and the two runs ask for
# different names, so a program that ignores the argument and writes a fixed file is caught rather
# than graded. Only a regular file is ever staged: the binary cannot read the keys, but it can drop
# a symlink at the output path pointing into /opt, and pytest, running as root, would then read the
# verifier's own truth back as the agent's figures.
run_once() {
  local data="$1" asked="$2" out="$3" pid
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
  # Closing the project and the system paths still leaves scratch space the build user can write
  # to and then execute from. Ada reaches libc through Interfaces.C, which is part of the standard
  # library, so a program could carry a helper as bytes, drop it in /tmp, mark it executable and
  # run it. The task says the numbers come out of the Ada, so the run is scanned on both sides,
  # scratch space and the collected directories alike (/app itself included, not only its known
  # subdirectories, so nothing dropped as a sibling of forecast/, out/ or data/ escapes the sweep
  # by sitting outside all three), and anything newly executable throws the output away.
  # (The whole of /app is also listed in full, below, since the contract allows a run one new
  # file there and no other.)
  scratch_list() {
    find /tmp /var/tmp /dev/shm /home/runner /app "$data" -xdev -type f -perm /111 2>/dev/null | sort -u
  }
  # Under /app the sweep is not limited to executables: the instruction says the only new file
  # a run may leave there is the JSON it was asked for, so the whole tree is listed on either
  # side of the run, every path of every kind, and any new path other than that file discards
  # the run's output. Scratch space and the runner's home are the program's own and stay held
  # only to the executable rule above.
  app_list() {
    find /app -xdev -mindepth 1 2>/dev/null | sort -u
  }
  scratch_list > /opt/scratch_before.txt
  app_list > /opt/app_before.txt
  close_tools
  close_loader
  # A root shell sets the working directory the instruction documents and the runner's HOME, then
  # hands off with exec to setpriv, whose first exec is the binary itself: the binary loads through
  # the first-exec window while anything it spawns afterwards, with the loader closed, cannot. The
  # shell and setpriv run as root, so the closed loader does not touch them.
  setsid bash -c 'cd /app/forecast && export HOME=/home/runner && exec setpriv --clear-groups --no-new-privs --reuid runner --regid runner /app/forecast/forecast "$1" "$2"' _ "$data" "$asked" &
  pid=$!
  wait "$pid"
  echo "run exit status: $? ($data -> $asked)"
  open_loader
  open_tools
  kill -TERM -- -"$pid" 2>/dev/null || true
  kill -KILL -- -"$pid" 2>/dev/null || true
  as_runner bash -c 'kill -9 -1' 2>/dev/null || true
  scratch_list > /opt/scratch_after.txt
  app_list > /opt/app_after.txt
  if ! left="$(comm -13 /opt/scratch_before.txt /opt/scratch_after.txt)"; then left=""; fi
  if [ -n "$left" ]; then
    echo "the run left something executable in scratch space, so its output is discarded:"
    echo "$left"
    rm -f "$asked"
  fi
  if ! added="$(comm -13 /opt/app_before.txt /opt/app_after.txt | grep -v -x -F -- "$asked")"; then added=""; fi
  if [ -n "$added" ]; then
    echo "the run left a new path under /app other than the file it was asked for, so its output is discarded:"
    echo "$added"
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
# arguments: a usage line on standard error, nothing on standard output, exit 2, no file written.
# It promises that for any count other than two, not only one or two of them, so a spread from
# 0 up through 40, including a run of consecutive small counts and a couple of large ones, is
# probed below, not a handful clustered near two. "No file written" is read from a snapshot of
# every writable location the process can reach, before and after the call, not only /app/out, so
# a file dropped in the project directory, scratch space or the runner's home during an invalid
# invocation is still caught.
snapshot_writable() {
  find /app /tmp /var/tmp /dev/shm /home/runner -xdev -mindepth 1 -type f 2>/dev/null | sort -u
}
probe_args() {
  local tag="$1"; shift
  rm -f /app/out/argprobe.json
  snapshot_writable > "/opt/argprobe_${tag}_before.txt"
  close_tools
  setsid \
    setpriv --clear-groups --no-new-privs --reuid runner --regid runner \
    env -C /app/forecast HOME=/home/runner /app/forecast/forecast "$@" \
    > "/opt/argprobe_${tag}_out.txt" 2> "/opt/argprobe_${tag}_err.txt" &
  local ppid=$!
  wait "$ppid"
  local pstatus=$?
  open_tools
  kill -TERM -- -"$ppid" 2>/dev/null || true
  kill -KILL -- -"$ppid" 2>/dev/null || true
  as_runner bash -c 'kill -9 -1' 2>/dev/null || true
  echo "$pstatus" > "/opt/argprobe_${tag}_status.txt"
  snapshot_writable > "/opt/argprobe_${tag}_after.txt"
  if cmp -s "/opt/argprobe_${tag}_before.txt" "/opt/argprobe_${tag}_after.txt"; then
    echo nothing > "/opt/argprobe_${tag}_wrote.txt"
  else
    echo wrote > "/opt/argprobe_${tag}_wrote.txt"
  fi
  rm -f /app/out/argprobe.json
  echo "  $tag: exit $pstatus, $(cat "/opt/argprobe_${tag}_wrote.txt") written"
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
      probe_args "argc_${n}" /app/data /app/out/argprobe.json "${extras[@]}"
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
  probe_args "horizon_${value}" "$dir" /app/out/argprobe.json
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
run_once /app/data /app/out/forecast.json /opt/run_shipped.json

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
run_once "$staged" /app/out/forecast_second.json /opt/run_hidden.json
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
