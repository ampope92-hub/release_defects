# The release team writes its tooling in Ada, so the agent's project is compiled with GNAT.
# Canonical Python base: the harness runs on it, and nothing here needs a numerics stack.
FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm@sha256:01f42367a0a94ad4bc17111776fd66e3500c1d87c15bbd6055b7371d39c124fb

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# gnat is the whole toolchain: gnatmake, the Ada front end and the runtime. The tool is written
# against the Ada standard library, so nothing has to be fetched at solve time on an offline box.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gnat \
        tmux \
        asciinema \
    && rm -rf /var/lib/apt/lists/*

# The instruction says the GNAT hierarchy is removed from the image, and it is: Ada.* resolves as
# usual, GNAT.* does not, here and in the image that recompiles the work, so a submission that
# reaches for a convenience package finds out at its own first build rather than at grading time.
RUN find / -name 'adainclude' -type d -prune -exec sh -c 'rm -f "$1"/g-*.ads "$1"/g-*.adb' _ {} \; \
    && find / -name 'adalib' -type d -prune -exec sh -c 'rm -f "$1"/g-*.ali' _ {} \;

# The project the agent completes, and the export from the tracker.
COPY forecast /app/forecast
COPY data /app/data
RUN chmod +x /app/forecast/build.sh && mkdir -p /app/out

WORKDIR /app
