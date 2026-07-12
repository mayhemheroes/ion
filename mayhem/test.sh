#!/usr/bin/env bash
#
# ion/mayhem/test.sh — RUN redox-os/ion's own test suite and emit a CTRF summary.
# exit 0 iff no test failed.
#
# Upstream's suite is `make tests`, three parts (all pre-built by mayhem/build.sh):
#   1. cargo test           — lib/unit/doc tests of the ion-shell crate (assert concrete
#                             parser/expansion results — known-answer assertions);
#   2. tests/run_examples.sh — golden-output tests: runs target/debug/ion on every
#                             tests/*.ion (+ *.params) script and diffs stdout against
#                             the committed tests/*.out file;
#   3. cargo test in each members/* crate (ranges, types-rs, scopes-rs, builtins-proc).
# These assert exact values / golden output, so a no-op or exit(0) patch cannot pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi
if [ ! -x target/debug/ion ]; then
  echo "target/debug/ion missing — build.sh did not pre-build the debug binary" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

PASSED=0; FAILED=0; IGNORED=0

# Sum libtest "test result:" lines from one cargo test invocation's output.
count_libtest() {
  local out="$1"
  while read -r p f i; do
    PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
  done < <(printf '%s\n' "$out" \
    | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')
}

echo "=== [1/3] cargo test (ion-shell unit + doc tests) ==="
out="$(RUSTFLAGS="" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc1=$?
echo "$out"
count_libtest "$out"
if [ "$rc1" -ne 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "cargo test exited $rc1 without parseable failures (compile error?)" >&2
  FAILED=$(( FAILED + 1 ))
fi

echo "=== [2/3] tests/run_examples.sh (golden-output .ion/.out diffs) ==="
# RUSTUP=0 → the script's internal `cargo build` uses the image's default toolchain
# (a cached no-op; build.sh already built target/debug/ion).
ex_out="$(RUSTUP=0 RUSTFLAGS="" bash tests/run_examples.sh 2>&1)"; rc2=$?
echo "$ex_out"
EX_PASS=$(printf '%s\n' "$ex_out" | grep -c '\[PASS\]')
EX_FAIL=$(printf '%s\n' "$ex_out" | grep -c '\[FAIL\]')
# run_examples.sh runs under `set -e`, so it stops at the first failing batch — a
# nonzero exit with no counted [FAIL] still counts as a failure.
if [ "$rc2" -ne 0 ] && [ "$EX_FAIL" -eq 0 ]; then EX_FAIL=1; fi
PASSED=$(( PASSED + EX_PASS )); FAILED=$(( FAILED + EX_FAIL ))

echo "=== [3/3] cargo test in members/* crates ==="
for crate in members/*; do
  out="$(RUSTFLAGS="" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" --manifest-path "$crate/Cargo.toml" 2>&1)"; rc3=$?
  echo "$out"
  before_failed=$FAILED
  count_libtest "$out"
  if [ "$rc3" -ne 0 ] && [ "$FAILED" -eq "$before_failed" ]; then
    echo "cargo test in $crate exited $rc3 without parseable failures" >&2
    FAILED=$(( FAILED + 1 ))
  fi
done

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
