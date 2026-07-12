#!/usr/bin/env bash
#
# ion/mayhem/build.sh — build redox-os/ion's cargo-fuzz target as a sanitized libFuzzer
# binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS — NOT clang's
# $SANITIZER_FLAGS / CFLAGS, which rustc ignores), plus the project's own
# test suite with NORMAL flags so mayhem/test.sh only RUNS it.
#
# Targets (mayhem/fuzz/fuzz_targets/*.rs):
#   parser — UTF-8-decodes the input and runs ion's statement parser
#            (ion_shell::parser::fuzzing::statement_parse), the same code path as
#            upstream's fuzz/ crate (which is not buildable as-is: it pins
#            libfuzzer-sys to a git URL; this additive copy pins 0.4).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# DWARF < 4 debug-info contract (§6.2 item 10): force DWARF 2 so Mayhem triage / gdb can
# resolve project source lines. The rlenv runtime may export RUST_DEBUG_FLAGS before
# re-running build.sh offline; the default only applies when unset/empty.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

cd "$SRC"

# Rust's ASan runtime (librustc-nightly_rt.asan.a) is compiled with the nightly's bundled
# LLVM (DWARF 5) and is linked before project code — strip its debug sections so it
# contributes no DWARF ≥ 4 CUs to the final binary.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 there too.
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# The cargo-fuzz crate is ADDITIVE under mayhem/fuzz/ (upstream's fuzz/ stays untouched).
FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=(parser)
TRIPLE="x86_64-unknown-linux-gnu"

# OSS-Fuzz Rust libFuzzer+ASan flags. NOTE: no `--cfg fuzzing` (and cargo-fuzz runs
# with --no-cfg-fuzzing below): ion_shell's #[cfg(fuzzing)] mod references the private
# `statement::parse` module and fails to compile (E0603) whenever cfg(fuzzing) is set —
# the harness uses the public StatementSplitter/parse_and_validate API instead.
export RUSTFLAGS="${RUSTFLAGS:-} -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" --no-cfg-fuzzing -O --debug-assertions "$t"
done

TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
echo "fuzz target_directory: $TARGET_DIR"

REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    ls -la "$REL" >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Test suite (NORMAL flags — no sanitizer RUSTFLAGS, default ./target dir) ──────────
# Upstream's suite is `make tests`: cargo test (lib/bin/doc), tests/run_examples.sh
# (golden-output .ion/.out diffs against target/debug/ion), and cargo test in each
# members/* crate. Pre-build everything here so mayhem/test.sh only RUNS it.
echo "=== pre-building the project + test suite (normal flags) ==="
RUSTFLAGS="" cargo build --jobs "$MAYHEM_JOBS"                 # target/debug/ion for run_examples.sh
RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS"
for crate in members/*; do
  RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS" --manifest-path "$crate/Cargo.toml"
done

echo "build.sh complete:"
ls -la /mayhem/parser
