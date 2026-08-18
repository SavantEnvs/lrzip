# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) -- builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). lrzip needs a handful of pinned apt -dev packages beyond the base
# (liblzo2, liblz4, libbz2, zlib -- LZMA and zpaq are both bundled/vendored under lzma/ and
# libzpaq/, no external dependency) plus libtool for its autotools build.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t lrzip-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); an empty value breaks clang, so it is
# never baked as ENV -- build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declared WITHOUT a default so an unset arg lets the base ENV flow through to build.sh, while an
# explicit --build-arg (including an EMPTY one, for a no-sanitizer build) overrides it.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# lrzip's own build-dependency closure: liblzo2/liblz4/libbz2/zlib -dev headers (LZMA and zpaq are
# vendored, no apt package needed for either) + libtool (missing from the base) for the autotools
# build. Re-pin to SOURCE_DATE_EPOCH first for reproducibility when it's set (repro-sources-list.sh
# ships in the base).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libtool liblzo2-dev liblz4-dev libbz2-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

# The ONLY writable location under Mayhem's read-only image mount during coverage collection
# (SPEC SS6.2 item 13). lrzip's `-t` test/verify mode still needs a scratch temp file (mkstemp())
# for the decoded-but-discarded output -- initialise_control() (lrzip.c) reads $TMPDIR, so this
# ENV (not a Mayhemfile-level `env:`, which a plain local `docker run`/fuzz-smoke wouldn't see and
# would then silently fall back to the read-only cwd) makes every invocation -- Mayhem's, a local
# smoke test's, or a human's -- resolve the same writable path.
ENV TMPDIR=/dev/shm

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# lrzip's own built-in regression suite (tests/regression.sh + tests/regression.good, built above
# with NORMAL flags) -- a failing suite fails the image.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
