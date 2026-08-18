#!/usr/bin/env bash
#
# lrzip/mayhem/build.sh -- build the fuzz-decompression target over lrzip's OWN, unmodified CLI
# (mayhem-build-fuzz/lrzip -> /mayhem/fuzz_decompress), AND a separate, clean/normal-flags build
# of the same CLI (mayhem-build-oracle/lrzip) for mayhem/test.sh's oracle.
#
# ── Why the fuzz target wraps the REAL CLI instead of a hand-written in-process harness ──────
# lrzip decompresses via `decompress_file(rzip_control *control)` (lrzip.c), which is heavily
# file/fd-oriented (real open()/mkstemp() fds, not a buffer API -- the `Lrzip`/`lrzip_new()`
# object API referenced by decompress_demo.c does not exist in this version: that file is dead,
# unbuilt code, not listed in Makefile.am). Worse for an in-process libFuzzer harness: virtually
# EVERY validation failure (bad magic, bad encryption mode, corrupt streaming flags, a libzpaq
# decode error, ...) goes through failure_return()/fatal_return() -> fatal_exit() (util.c) ->
# the real libc exit(1) -- confirmed by grep across lrzip.c/rzip.c/util.c/libzpaq/zpaq_lrzip.cpp.
# A persistent in-process harness would therefore either (a) die on the very first malformed
# archive (exit() ends the whole libFuzzer process), or (b) if exit() is intercepted via
# --wrap=exit + longjmp, leak every heap buffer decompress_file() allocated before the jump --
# AND leak on the NORMAL success path too, since lrzip never frees control->outfile /
# control->tmpdir / internal rzip_state buffers, relying on process exit to reclaim them (a
# completely normal, correct design for a run-ONCE-per-process CLI tool, not for a loop that
# calls it a million times in one process). Neither is acceptable for a real campaign.
#
# So: build the real, unmodified lrzip binary TWICE with different compilers/flags (per SPEC
# SS6.2 item 11's "libFuzzer, or AFL via afl: true"):
#   1) afl-clang-fast(++) + $SANITIZER_FLAGS (+ -fsanitize=fuzzer-no-link is NOT needed here --
#      afl-clang-fast's own LLVM pass provides SanitizerCoverage-equivalent edge instrumentation
#      and the AFL fork-server runtime; ASan/UBSan still halt on real defects). Mayhem's `afl: true`
#      cmd runs this under its fork server: every test case gets a FRESH forked child (copy-on-write
#      from a clean, already-initialised parent), so lrzip's own exit(1)-per-rejected-archive design
#      and its per-call heap leaks are both exactly as harmless as in normal CLI use -- the child
#      just exits and is discarded. This is the one target (fuzz_decompress); its fuzzer-controlled
#      archive HEADER selects which back end (lzma/bzip2/gzip/lzo/zpaq) actually runs, so all five
#      are real attack surface from this single entry point (see the seed set below).
#   2) plain clang/clang++, NORMAL flags, no sanitizer, no afl -- the oracle build for
#      mayhem/test.sh (kept completely separate so the functional suite never sees sanitizer/UB
#      noise or AFL fork-server behaviour).
#
# Sources compiled: lrzip's own autotools project (configure.ac / Makefile.am) -- unmodified,
# built out-of-tree (VPATH) in two separate directories so the two builds never collide and a
# re-run on an already-built tree is a fast, idempotent no-op (SPEC SS6.5).
#
# Back ends kept: ALL FIVE upstream ships (lzma default, lzo -l, bzip2 -b, gzip -g, zpaq -z) --
# each is real, reachable attack surface from the single fuzzer-controlled header/back-end byte,
# so none are configured out. zpaq is bundled C++ (libzpaq/) built by the same autotools project
# with clang++ (afl-clang-fast++ for the fuzz build) -- no extra apt package needed for it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DWARF <= 3 (SPEC 6.2 item 10): clang-19's plain -g emits DWARF-5; be explicit.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS
: "${SRC:=/mayhem}"
cd "$SRC"

# ── 0) Generate configure/Makefile.in ONCE (idempotent: guarded on ./configure's presence, so a
#    re-run on an already-generated tree doesn't re-run autoreconf) ─────────────────────────────
[ -x "$SRC/configure" ] || autoreconf -fi

# ── ASan/UBSan RUNTIME options are Mayhem's to own, NOT ours to bake in (PE-7391) ──────────────
# We deliberately do NOT compile in any sanitizer-default-options override function, and do NOT set
# an ASAN_OPTIONS anywhere (Dockerfile ENV, Mayhemfile, or a baked constructor): adding any of those
# is a hard gate FAIL, because Mayhem controls the sanitizer runtime set for
# every run of the target and layers its own options on top. For this AFL-mode (`afl: true`) target
# that is exactly what handles the two concerns a baked constructor would otherwise cover:
#   * crash-as-signal: Mayhem's AFL fork server sets its own ASAN_OPTIONS (abort_on_error=1 etc.) so
#     a real ASan/UBSan defect raises SIGABRT and is caught as a crash rather than a silent exit(1).
#   * leaks: lrzip is a run-once CLI that never frees several control-struct buffers (see the header
#     comment) — but under the fork server each input is a fresh child, LeakSanitizer only runs at
#     that child's exit, and a leak report exits non-zero WITHOUT raising a signal, so AFL
#     classifies it as an ordinary non-crash, not a finding. No detect_leaks=0 needed, and real
#     overflow/UAF/UB detection stays fully on.

# ── 1) FUZZ build: afl-clang-fast(++) + $SANITIZER_FLAGS + $DEBUG_FLAGS, out-of-tree ───────────
FUZZ_BUILD="$SRC/mayhem-build-fuzz"
mkdir -p "$FUZZ_BUILD"
if [ ! -f "$FUZZ_BUILD/Makefile" ]; then
  ( cd "$FUZZ_BUILD" && "$SRC/configure" \
      CC=afl-clang-fast CXX=afl-clang-fast++ \
      CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      LDFLAGS="$SANITIZER_FLAGS" )
fi
make -C "$FUZZ_BUILD" -j"$MAYHEM_JOBS"

install -m0755 "$FUZZ_BUILD/lrzip" /mayhem/fuzz_decompress
# afl-clang-fast's instrumentation is fully passive when the binary is invoked directly (no
# AFL_FORKSRV parent) -- confirmed by running it standalone during porting -- so the exact same
# binary IS its own non-fuzzer, run-once reproducer; ship it under the fleet's `-standalone`
# convention too rather than a redundant third build.
install -m0755 "$FUZZ_BUILD/lrzip" /mayhem/fuzz_decompress-standalone
echo "built /mayhem/fuzz_decompress (+ -standalone) -- afl-clang-fast, $SANITIZER_FLAGS"

# Mayhemfile_fuzz_decompress references this flat /mayhem/fuzz_decompress.dict path (dict: key) --
# copy it into place so a referenced-but-absent dict can't make the run fail to start.
install -m0644 "$SRC/mayhem/fuzz_decompress/fuzz_decompress.dict" /mayhem/fuzz_decompress.dict

# ── 2) ORACLE build: plain $CC/$CXX, NORMAL flags, no sanitizer, no afl, out-of-tree ───────────
ORACLE_BUILD="$SRC/mayhem-build-oracle"
mkdir -p "$ORACLE_BUILD"
if [ ! -f "$ORACLE_BUILD/Makefile" ]; then
  ( cd "$ORACLE_BUILD" && "$SRC/configure" CC="$CC" CXX="$CXX" )
fi
make -C "$ORACLE_BUILD" -j"$MAYHEM_JOBS"

ORACLE_BIN="$ORACLE_BUILD/lrzip"
[ -x "$ORACLE_BIN" ] || { echo "FATAL: $ORACLE_BIN was not produced by the oracle build" >&2; exit 1; }
# Must be dynamically linked so verify-repo's LD_PRELOAD sabotage shim can neuter it (SPEC SS6.3) --
# plain clang links dynamically by default; assert it so a toolchain change can't silently weaken
# the oracle into an unsabotageable static binary.
if ! file "$ORACLE_BIN" | grep -q 'dynamically linked'; then
  echo "FATAL: $ORACLE_BIN is not dynamically linked -- the sabotage check could not neuter it" >&2
  file "$ORACLE_BIN" >&2
  exit 1
fi
echo "built $ORACLE_BIN (dynamically linked CLI, oracle build for mayhem/test.sh)"

echo "build.sh complete:"
ls -la /mayhem/fuzz_decompress /mayhem/fuzz_decompress-standalone "$ORACLE_BIN" 2>&1 || true
