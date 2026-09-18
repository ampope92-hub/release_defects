#!/bin/bash

# Verifier entrypoint. Runs in the verifier container, not the agent's: it sees only the paths
# declared in `artifacts`. All tooling is baked into tests/Dockerfile; nothing is fetched here.

set -uo pipefail

mkdir -p /logs/verifier
echo 0 > /logs/verifier/reward.txt

# Fold stderr into stdout: only stdout survives into the feedback bundle.
exec 2>&1

# Everything this script creates from here on is root-only from the moment it exists: the
# probe captures, the record of the horizons and the argument count drawn for this run, the
# staged copies of the exports. Nothing is written world-readable and closed afterwards, so
# there is never a window in which the binary, running as the build user between two probes,
# could read what the verifier has drawn or recorded so far. The few things the build user has
# to reach (the staged export directories, the binary itself) are opened by name below.
umask 077
chmod 700 /opt 2>/dev/null || true

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
# below): closing it makes an ordinary dynamically linked binary unlaunchable during the
# credential transition setpriv makes, so the loader itself is left alone and the value this
# closure gives up is only the one attack that needed a *second*, separately-launched
# dynamically linked binary. A helper compiled from the agent's own collected source is not a
# route around anything: only src/*.adb|ads is ever compiled, so the same standard-library-only
# code is all that could run either way.
# One chmod process rather than one per file: every invocation below is bracketed by this pair,
# and the argument-count probes alone now run it forty times.
close_tools() { printf '%s\n' "$TOOLS" | xargs -d '\n' -r chmod 750 2>/dev/null || true; }
open_tools()  { printf '%s\n' "$TOOLS" | xargs -d '\n' -r chmod 755 2>/dev/null || true; }
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
# `gnatmake -I src` command needs nothing else there, and the instruction says so. Every entry
# that is not a top-level *.adb or *.ads regular file is deleted now, before the run even starts,
# rather than merely losing its read and execute bits later. "Every entry" is meant literally and
# is not a question of file MODE: a directory and everything under it goes too, so a nested tree
# whose DIRECTORY NAMES carry a parser table or any other payload is gone rather than merely
# unreadable, and so does a symlink, a fifo or a device node, none of which the documented build
# reads. Nothing an ordinary GNAT project needs is lost: `gnatmake -I src` compiles from src/
# itself, so a sub-directory was never on its build path in the first place.
# /app/out is emptied on the same terms. It is a collected path too, so whatever the agent leaves
# there arrives with the project; nothing is meant to be in it before the run, and the instruction
# says so. /opt/forecast_pristine, the copy the build step below still reads from, keeps the
# original files; only the collected working copy is stripped.
find /app/forecast/src -mindepth 1 -maxdepth 1 \
     ! \( -type f \( -name '*.adb' -o -name '*.ads' \) \) -exec rm -rf -- {} + 2>/dev/null || true
find /app/out -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
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
  chmod 755 /app/forecast/forecast
else
  echo "the collected sources did not build into /app/forecast/forecast"
fi
rm -rf /app/build_iso

# Nowhere to write. The contract says a run writes nothing but the JSON it was asked for and has
# nowhere else to write, and that second half is what makes the first one checkable: a
# before/after listing (kept below, as a belt) only sees what is still there when the run ends,
# so a file created and deleted inside one invocation leaves it nothing to compare. Ada reaches
# libc through Interfaces.C, which is part of the standard library, so a program could carry a
# helper as bytes, drop it in scratch, mark it executable and run it, or spool through a
# temporary file and unlink it. So the build is over, and from here on the build user has no
# place to create anything: everything under /app is root-owned (the binary needs only its
# execute bit, and the export was never meant to be written), the runner's home and every
# scratch directory are root-only, and a walk of the whole file system AS THE BUILD USER has to
# come back empty before anything below runs. Whatever it lists is closed and the walk repeated;
# if something still answers writable the run is abandoned rather than graded on a promise the
# box cannot keep. The one path a run may write is its own output file, which each invocation
# pre-creates empty, owned by the build user, inside a root-owned directory: it can be written
# over, and nothing can be created beside it, in its place or anywhere else.
chown -R root:root /app /home/runner
for d in /tmp /var/tmp /dev/shm /dev/mqueue /home/runner /run/lock; do
  [ -d "$d" ] && chmod 700 "$d" 2>/dev/null
done
runner_writable() {
  as_runner find / \( -path /proc -o -path /sys \) -prune -o \( -type d -o -type f \) -writable -print 2>/dev/null | sort
}
open=""
for attempt in 1 2 3; do
  open="$(runner_writable)"
  [ -z "$open" ] && break
  printf '%s\n' "$open" | while IFS= read -r p; do
    [ -n "$p" ] && { chown root:root -- "$p"; chmod go-w -- "$p"; } 2>/dev/null
  done
done
if [ -n "$open" ]; then
  echo "FATAL: the build user can still write somewhere, so the run cannot be graded:"
  printf '%s\n' "$open"
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi
echo "nothing on the box is writable by the build user; each run gets its own output file and nothing else"

# Every invocation, graded run and probe alike, has its standard output and standard error
# captured into two files whose names are drawn fresh from /dev/urandom, and only after the
# process is gone are a probe's captures renamed to the tag pytest reads them under. The binary
# can read the path behind its own descriptor 1 (readlink on /proc/self/fd/1) even though it
# cannot list /opt, and a capture named after the probe would tell it which kind of run it is
# in; a bare hex name under a closed directory tells it nothing a graded run's does not.
cap_name() {
  printf '/opt/%s' "$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
}

# stage_output <path>: the one file an invocation may write, created empty for it and handed
# over; its size and both timestamps are recorded, so "wrote nothing" below means exactly that
# the file is as it was handed out, not merely that it is empty. output_touched <path> answers
# wrote / nothing against that record.
stage_output() {
  : > "$1"
  chown runner:runner "$1"
  chmod 600 "$1"
  stat -c '%s %y %z' "$1" > /opt/out_stat_before.txt
}
output_touched() {
  if [ -f "$1" ] && [ ! -L "$1" ] \
     && [ "$(stat -c '%s %y %z' "$1" 2>/dev/null)" = "$(cat /opt/out_stat_before.txt)" ]; then
    echo nothing
  else
    echo wrote
  fi
}

# The belt: every single invocation below -- the two graded runs AND every argument-count and
# horizon probe -- is still bracketed by a before/after listing of every non-directory entry in
# scratch space, the runner's home and the whole of /app (/app itself included, so nothing
# dropped as a sibling of forecast/, out/ or data/ escapes by sitting outside all three), and
# anything new other than the one output file the call was handed throws that invocation's own
# output away and is deleted on the spot. With nowhere to write, nothing should ever be listed;
# it stays because it costs nothing and reports loudly if the lockdown above ever regresses.
# The listing turns on presence, not mode: the dynamic loader is deliberately left executable
# (see the TOOLS comment above), and it maps and runs a helper the kernel would refuse to
# execve, so an execute bit says nothing about whether a leftover could have done work.
# A plain directory is not a file and is not listed; a probe's own staging directory is created
# before its bracket opens and removed only after it closes, so it never looks new to this.
all_list() {
  find /tmp /var/tmp /dev/shm /home/runner /app -xdev -mindepth 1 ! -type d 2>/dev/null | sort -u
}
snapshot_before() {
  all_list > /opt/all_before.txt
}
# check_after <keep-path>: call once tools are reopened. <keep-path> is the one path this
# invocation was allowed to write (empty when it named none). Prints a one-line description of
# any violation, empty when clean, and removes whatever it found immediately, so nothing an
# invocation leaves behind can ever look like it was "already there" to the NEXT invocation's own
# before picture.
check_after() {
  local keep="$1" added desc=""
  all_list > /opt/all_after.txt
  if ! added="$(comm -13 /opt/all_before.txt /opt/all_after.txt | grep -v -x -F -- "$keep")"; then added=""; fi
  if [ -n "$added" ]; then
    desc="left a new file behind other than the one it was asked for ($added)"
    printf '%s\n' "$added" | while IFS= read -r f; do [ -n "$f" ] && rm -f -- "$f"; done
  fi
  printf '%s' "$desc"
}

# lock_project [data-dir]: the state every invocation runs under, graded run and probe alike.
# Everything under /app/forecast except the binary this verifier built loses its read and execute
# bits -- the project's own sub-directories included, so a directory NAME cannot be read as data
# any more than a file's contents can -- and /app/forecast itself keeps only the execute bit the
# launch below needs to cd into it and start the binary. /app/out is a collected path the agent
# can populate too, so it is swept on the same terms; the export directory, when one is named,
# loses execute bits but keeps its read bits, since that is the input, and a file planted there
# instead is caught by the check that /app/data holds the shipped files and nothing else.
lock_project() {
  local data="${1:-}"
  find /app/forecast /app/out $data -type f -perm /111 \
       ! -samefile /app/forecast/forecast -exec chmod a-x {} + 2>/dev/null || true
  find /app/forecast /app/out -type f \
       ! -samefile /app/forecast/forecast -exec chmod a-r {} + 2>/dev/null || true
  find /app/forecast -mindepth 1 -depth -type d -exec chmod a-rx {} + 2>/dev/null || true
  chmod a-r /app/forecast 2>/dev/null || true
}

# run_once <data-dir> <output-path> <capture-path>: run the built binary on an export, as the
# build user, with every tool closed, from /app/forecast, and move what it wrote to a root-only
# path. The output path is the second argument the instruction documents, and the graded runs ask
# for a different, freshly randomized name each (rand_name, the same generator every probe below uses
# too), so a program that ignores the argument and writes a fixed file is caught rather than
# graded, and nothing about the name itself tells this run apart from a probe. Only a regular file
# is ever staged: the binary cannot read the keys, but it can drop a symlink at the output path
# pointing into /opt, and pytest, running as root, would then read the verifier's own truth back
# as the agent's figures.
run_once() {
  local data="$1" asked="$2" out="$3" pid violation cap
  # Closing the system paths stops the binary shelling out to a python or an awk, but the project
  # directory is the agent's own and is collected as an artifact, so a helper shipped inside it
  # would still be there to read. lock_project is what closes it, and the probes below run under
  # exactly the same call. The output file is handed out after it, so the lockdown's own chmod
  # never touches the record stage_output keeps.
  lock_project "$data"
  stage_output "$asked"
  snapshot_before
  close_tools
  # A root shell sets the working directory the instruction documents and the runner's HOME, then
  # hands off with exec to setpriv, whose own exec is the binary itself. The dynamic loader is
  # not closed here (see the TOOLS comment above): the binary loads normally, and so would a
  # second dynamically linked binary the program went on to launch itself, since only the
  # standard library and the agent's own collected source are ever available to run either way.
  cap="$(cap_name)"
  setsid bash -c 'cd /app/forecast && export HOME=/home/runner && exec setpriv --clear-groups --no-new-privs --reuid runner --regid runner /app/forecast/forecast "$1" "$2"' _ "$data" "$asked" \
    > "${cap}.o" 2> "${cap}.e" &
  pid=$!
  wait "$pid"
  echo "run exit status: $? ($data -> $asked)"
  open_tools
  # What the run said, for the log; nothing on either stream is graded on this path.
  head -c 4000 "${cap}.o" "${cap}.e" | sed 's/^/  | /'
  rm -f "${cap}.o" "${cap}.e"
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
  elif [ "$(output_touched "$asked")" = nothing ]; then
    echo "the output file handed to the run for $data was never written"
    rm -f "$asked"
  else
    mv "$asked" "$out"
    chown root:root "$out" 2>/dev/null || true
    chmod 600 "$out" 2>/dev/null || true
  fi
}

# The instruction says what the program does when it is handed anything other than two
# arguments: a line on standard error, nothing on standard output, exit 2, nothing written.
# Every count from zero through forty is probed below, forty cases rather than a handful, and
# one more drawn from 41..5000 on every run, so a program that refuses a few counts and answers
# another normally, or stops refusing past the fixed loop, is caught. The check is only of
# the output path the call actually names (the second argument, when there is one, handed over
# exactly as the graded runs get it): a run of zero or one arguments names no output path at
# all, so there is nothing to check there beyond exit status and stderr -- and the same
# leftover-file bracket every graded run gets (see check_after above).
probe_args() {
  local tag="$1"; shift
  # The second positional argument, when there is one, is the output path this call asked for
  # (a freshly randomized name from the caller, same generator the graded runs use); it is only
  # ever cleaned up here, never chosen here, so a probe's basename is decided the same way a
  # graded run's is and this function cannot itself reintroduce a fixed one.
  local outpath="${2:-}" violation datadir="${1:-}" cap
  # The project-tree lockdown is not a privilege of the graded runs. A probe is an invocation of
  # the same binary and runs under the same closed project: it used to be bracketed by the
  # before/after sweep but to reach an open /app/forecast, which made the first probe a window in
  # which the build script and everything else collected with it could still be read and its
  # contents staged somewhere for a later run to pick up.
  if [ -n "$datadir" ] && [ -d "$datadir" ]; then lock_project "$datadir"; else lock_project; fi
  [ -n "$outpath" ] && stage_output "$outpath"
  snapshot_before
  close_tools
  # Same launch chain as run_once: a root shell sets cwd and HOME, then execs setpriv, whose own
  # first exec is the forecast binary. Earlier this ran the binary through setpriv -> env instead,
  # so a graded run and a probe run reached the binary through different parent processes; now
  # both go through the identical chain and only the policy content (or the horizon value, for a
  # horizon probe) differs between them.
  cap="$(cap_name)"
  setsid bash -c 'cd /app/forecast && export HOME=/home/runner && exec setpriv --clear-groups --no-new-privs --reuid runner --regid runner /app/forecast/forecast "$@"' _ "$@" \
    > "${cap}.o" 2> "${cap}.e" &
  local ppid=$!
  wait "$ppid"
  local pstatus=$?
  open_tools
  mv -f "${cap}.o" "/opt/argprobe_${tag}_out.txt"
  mv -f "${cap}.e" "/opt/argprobe_${tag}_err.txt"
  kill -TERM -- -"$ppid" 2>/dev/null || true
  kill -KILL -- -"$ppid" 2>/dev/null || true
  as_runner bash -c 'kill -9 -1' 2>/dev/null || true
  echo "$pstatus" > "/opt/argprobe_${tag}_status.txt"
  violation="$(check_after "$outpath")"
  printf '%s' "$violation" > "/opt/argprobe_${tag}_violation.txt"
  if [ -n "$outpath" ]; then
    output_touched "$outpath" > "/opt/argprobe_${tag}_wrote.txt"
  else
    echo nothing > "/opt/argprobe_${tag}_wrote.txt"
  fi
  [ -n "$outpath" ] && rm -f "$outpath"
  echo "  $tag: exit $pstatus, $(cat "/opt/argprobe_${tag}_wrote.txt") written${violation:+, VIOLATION: $violation}"
}

# The records of what this run drew, root-only from the moment they exist (umask above, and a
# directory nobody else can enter); pytest reads them to know what to look for.
install -d -m 700 /opt/draws
rnd() { od -An -tu4 -N4 /dev/urandom | tr -d ' \n'; }

echo "=== what it does when the argument count is wrong ==="
# Every count from zero through forty, and then one more drawn from 41..5000 on every run and
# printed, so the promise is sampled well past any cutoff a program could have read off the
# fixed loop.
drawn_arity=$(( $(rnd) % 4960 + 41 ))
printf '%s\n' "$drawn_arity" > /opt/draws/arity.txt
echo "argument count drawn for this run: $drawn_arity"
for n in $(seq 0 40) "$drawn_arity"; do
  [ "$n" -eq 2 ] && continue
  tag="argc_${n}"; [ "$n" -eq "$drawn_arity" ] && tag="argc_drawn"
  case "$n" in
    0) probe_args "$tag" ;;
    1) probe_args "$tag" /app/data ;;
    *)
      extras=()
      for ((e = 3; e <= n; e++)); do
        extras+=("extra$((e - 2))")
      done
      probe_args "$tag" /app/data "/app/out/$(rand_name)" "${extras[@]}"
      ;;
  esac
done

# The horizon is the one policy figure the program is told to refuse. Both graded exports say 365,
# so without cases of its own nothing would stop a program that never reads the key. The rule is
# universal, anything but the integer 365, and a universal rule over every JSON value cannot be
# run to exhaustion, so it is sampled, and the instruction says so: fixed values and values drawn
# fresh on every run. Seventeen fixed: zero, which a parser that treats a missing or unset figure
# as "use the default" answers instead of refusing, close to 365, far from it, one numeral too
# long for any integer type, four JSON numbers that begin with the digits 365 and are not the
# bare token 365 (365.0, 365e0, 3.65e2, 3650e-1), which a parser that stops at the first
# non-digit reads as 365 and which the instruction names as another spelling and another horizon,
# and five values of another JSON type that carry the same digits or no number at all (the string
# "365", true, null, [365], {"v":365}), which a parser that coerces a string to an integer, or
# skips to the first digits it can find, reads as 365. Then eight more are drawn from /dev/urandom
# and printed below, so the set a program would have to know is not a set at all: integers across
# 1..10000 other than 365, a negative, a fraction, an exponent form and a numeral of twenty to
# forty digits. Staging a whole export for a horizon costs a copy of the report log, so this stays
# a sample rather than the exhaustive range the argument counts above get.
#
# Staged under a name drawn from the same bare mktemp template as the other product's export
# below, not a distinguishing prefix like "horizon_": a name that says what the directory is for
# would let a program single out the probe by argv and answer it differently from a graded run.
# The output path asked for is a fresh rand_name too, the same generator a graded run gets, not
# the fixed argprobe.json this used to be: nothing about either name says which kind of run it is.
echo "=== what it does when the policy asks for another horizon ==="
run_horizon_probe() {
  # <tag> names the capture files (a plain token, so a value with quotes or brackets never
  # becomes part of a path); <value> is the JSON text written after the colon.
  local tag="$1" value="$2" dir
  dir="$(mktemp -d /app/XXXXXXXXXX)"
  find /opt/data_pristine -maxdepth 1 -type f ! -name policy.json -exec cp -- {} "$dir"/ \;
  sed "s/\"horizon_days\"[[:space:]]*:[[:space:]]*365/\"horizon_days\": ${value}/" \
    /opt/data_pristine/policy.json > "$dir/policy.json"
  grep -qF -- "\"horizon_days\": ${value}" "$dir/policy.json" \
    || echo "WARNING: the horizon probe for ${value} did not get a changed policy, so it proves nothing"
  # Root keeps ownership: the binary only has to read the export, and a directory it owned would
  # let it restore write bits and rewrite the policy from inside the run.
  chmod -R a-w,a+rX "$dir"
  probe_args "horizon_${tag}" "$dir" "/app/out/$(rand_name)"
  rm -rf "$dir"
}
# The twenty-digit numeral is another horizon, and one no 32-bit integer holds, so a program that
# converts the figure before comparing it has to refuse it rather than die on it. The tag of each
# fixed value is the value itself where that is a plain token, and a word for the others. Every
# probe's captures are renamed to their tag only after the process is gone (probe_args above).
for h in 0 30 90 364 366 400 1000 99999999999999999999 365.0 365e0 3.65e2 3650e-1; do
  run_horizon_probe "$h" "$h"
done
run_horizon_probe str365 '"365"'
run_horizon_probe true true
run_horizon_probe null null
run_horizon_probe list365 '[365]'
run_horizon_probe obj365 '{"v":365}'
# The drawn set, recorded root-only as it is drawn (umask, and /opt/draws is closed). pytest reads
# the record to know what to look for and fails if it does not hold eight values, so a run that
# skipped these cannot pass by their absence.
drawn=()
for i in 1 2 3 4; do
  v=$(( $(rnd) % 10000 + 1 )); [ "$v" -eq 365 ] && v=$(( v + 1 + $(rnd) % 100 ))
  drawn+=("$v")
done
drawn+=("-$(( $(rnd) % 10000 + 1 ))")
drawn+=("$(( $(rnd) % 1000 )).$(( $(rnd) % 90 + 10 ))")
drawn+=("$(( $(rnd) % 999 + 1 ))e$(( $(rnd) % 4 ))")
big="$(( $(rnd) % 9 + 1 ))$(od -An -tu1 -N$(( 19 + $(rnd) % 20 )) /dev/urandom | tr -d ' \n' | tr -d -c '0-9' | cut -c1-39)"
drawn+=("$big")
: > /opt/draws/horizons.txt
echo "horizons drawn for this run: ${drawn[*]}"
for h in "${drawn[@]}"; do
  echo "$h" >> /opt/draws/horizons.txt
  run_horizon_probe "$h" "$h"
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
