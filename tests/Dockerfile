# Verifier image. Runs in its own container: it sees only the paths declared in `artifacts`.
# It recompiles the agent's Ada and runs it, so it needs gnat; it scores the result with the
# standard library, so it needs nothing else. There is no dependency tree to pre-build here, the
# tool is written against the Ada runtime, which is why this image has no skeleton stage and no
# stale-binary problem.
FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm@sha256:01f42367a0a94ad4bc17111776fd66e3500c1d87c15bbd6055b7371d39c124fb

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends gnat \
    && rm -rf /var/lib/apt/lists/*

# The instruction says the tool is built against the Ada standard library and nothing else. GNAT
# ships its own convenience packages, the GNAT.* hierarchy, in the same source path as Ada.*, so a
# submission could `with GNAT.Regpat;` and still compile. Removing those sources makes the
# constraint real: Ada.* still resolves, GNAT.* no longer does, and the compile fails rather than
# the rule being taken on trust. The oracle_gnat_unit arm is that submission and it scores 0.
RUN find / -name 'adainclude' -type d -prune -exec sh -c 'rm -f "$1"/g-*.ads "$1"/g-*.adb' _ {} \; \
    && find / -name 'adalib' -type d -prune -exec sh -c 'rm -f "$1"/g-*.ali' _ {} \;

# Verifier tooling, pinned. Nothing is installed at trial time.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --require-hashes --no-deps -r /tmp/requirements.txt && rm -f /tmp/requirements.txt

# test.sh recompiles and runs the agent's program, so agent-authored code executes in this image,
# and this image holds the answer keys. That code runs as `runner`, never root.
RUN useradd --create-home --uid 10001 --shell /bin/bash runner

# Artifact landing directories must exist before Harbor uploads the declared artifacts.
RUN mkdir -p /app/forecast/src /app/data /app/out

# /app itself stays root-owned and not writable by runner: the exec/content sweeps in test.sh
# walk fixed directories, and a runner-writable /app would let a payload sit directly under it,
# a sibling of forecast/, out/ and data/, outside every one of those three. Only the three
# subdirectories the build actually needs are runner-owned, forecast/ and out/ so the build can
# write its objects, its binary and its output, data/ so the export lands and gets stripped of
# its write bits by test.sh before anything untrusted runs.
RUN chown -R runner:runner /app/forecast /app/data /app/out \
    && chmod 755 /app

# The key for the shipped export, at a path Harbor does not reserve, readable only by root. /tests
# is a runtime mount, permissions set on it here are ineffective and a documented cause of
# verifier failure, so the answer key cannot be protected there.
COPY golden /opt/golden
RUN chmod 700 /opt/golden && chmod 600 /opt/golden/*

# The other product's export and key. test.sh stages the export after the build and runs the
# agent's binary a second time, which is what proves the tool works from what it is handed
# rather than carrying the shipped answers.
COPY hidden /opt/hidden
RUN chmod -R go-rwx /opt/hidden

COPY . /tests/

WORKDIR /app
