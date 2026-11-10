#!/usr/bin/env bash
# shellcheck disable=SC2016 # The fixture heredocs are literal Python and JavaScript.
# tests/ak47-guards.test.sh - the guard that stops the source fix rotting.
#
# Without this, the per-task TMPDIR and the per-file cleanup both quietly
# disappear and the sweeper becomes load-bearing again. Each check below is
# exercised in both directions: it must pass on a clean tree and fail on a
# broken one.
set -u


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/ak47/guards/guard-producers.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-guards-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state"

# A fake projects tree. `clean` writes only files that create and remove;
# `leaky` writes the same tree with the cleanup removed from every file.
make_projects() {
  local mode=${1:-leaky} p=$SANDBOX/projects
  rm -rf "$p"
  mkdir -p "$p/hydra/scripts/tests" "$p/core-backend/src/commands" \
           "$p/core-backend/scripts" "$p/H-DevOps/scripts/devops-agent/tests"
  if [ "$mode" = clean ]; then
    cat >"$p/hydra/scripts/tests/test_uvn_status.py" <<'PY'
import tempfile, shutil
class T:
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="uvn-")
        self.ledger = tempfile.mkdtemp(prefix="wc-")
    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.rmtree(self.ledger, ignore_errors=True)
PY
    cat >"$p/hydra/scripts/tests/test_fraud_lens.py" <<'PY'
import tempfile, shutil
class T:
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="uvn-lens-")
    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
PY
    printf '%s\n' 'const f = fs.mkdtempSync(path.join(os.tmpdir(), "rmtc-"));' \
      'afterAll(() => fs.rmSync(f, { recursive: true, force: true }));' \
      >"$p/core-backend/src/commands/repairMissingTrackCredits.test.js"
    printf '%s\n' 'const f = path.join(os.tmpdir(), `csv-${Math.random()}.json`);' \
      'afterAll(() => fs.rmSync(f, { force: true }));' \
      >"$p/core-backend/scripts/claim-surface-verify.test.js"
    printf '%s\n' 'WORK="$(mktemp -d)"' 'trap "rm -rf $WORK" EXIT' \
      >"$p/H-DevOps/scripts/devops-agent/tests/test-rebalance-wedge-scaleup-gate.sh"
  else
    cat >"$p/hydra/scripts/tests/test_uvn_status.py" <<'PY'
import tempfile
class T:
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="uvn-")
        self.ledger = tempfile.mkdtemp(prefix="wc-")
PY
    cat >"$p/hydra/scripts/tests/test_fraud_lens.py" <<'PY'
import tempfile
class T:
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="uvn-lens-")
PY
    printf '%s\n' 'const f = fs.mkdtempSync(path.join(os.tmpdir(), "rmtc-"));' \
      >"$p/core-backend/src/commands/repairMissingTrackCredits.test.js"
    printf '%s\n' 'const f = path.join(os.tmpdir(), `csv-${Math.random()}.json`);' \
      >"$p/core-backend/scripts/claim-surface-verify.test.js"
    printf '%s\n' 'WORK="$(mktemp -d)"' \
      >"$p/H-DevOps/scripts/devops-agent/tests/test-rebalance-wedge-scaleup-gate.sh"
  fi
  printf '%s' "$p"
}

# --- the systemic check ---------------------------------------------------------

test_systemic_passes_on_this_checkout() {
  "$GUARD" --systemic >/dev/null 2>&1 \
    || fail "the systemic check fails on this checkout; bin/fm-spawn.sh no longer exports a per-task TMPDIR"
  pass "the systemic check passes: bin/fm-spawn.sh exports a per-task TMPDIR"
}

test_systemic_fails_when_the_export_is_removed() {
  # A fake repo whose bin/fm-spawn.sh has lost the export. The guard checks the
  # checkout it lives in, so the fake needs its own ak47/ tree.
  local fake=$SANDBOX/fake-repo
  mkdir -p "$fake/bin" "$fake/ak47/guards"
  cp "$GUARD" "$fake/ak47/guards/guard-producers.sh"
  cp -r "$ROOT/ak47/lib" "$fake/ak47/lib"
  cp "$ROOT/ak47/census-producers.conf" "$fake/ak47/census-producers.conf"
  cp "$ROOT/ak47/budget.conf" "$fake/ak47/budget.conf"
  printf '%s\n' '#!/usr/bin/env bash' 'export GOTMPDIR=/tmp/fm-x/gotmp' \
    >"$fake/bin/fm-spawn.sh"
  if "$fake/ak47/guards/guard-producers.sh" --systemic >/dev/null 2>&1; then
    fail "the systemic check passed after the TMPDIR export was removed"
  fi
  pass "the systemic check fails when bin/fm-spawn.sh loses the TMPDIR export"
}

# --- the static check -----------------------------------------------------------

test_static_passes_on_a_clean_tree() {
  local p
  p=$(make_projects clean)
  "$GUARD" --static --projects "$p" >/dev/null 2>&1 \
    || fail "the static check failed on files that create and remove"
  pass "the static check passes on files that create and remove"
}

test_static_fails_on_a_leaking_tree() {
  local p
  p=$(make_projects leaky)
  if "$GUARD" --static --projects "$p" >/dev/null 2>&1; then
    fail "the static check passed on files that create a temp dir and never remove it"
  fi
  pass "the static check fails on files that create a temp dir and never remove it"
}

test_static_skips_a_file_absent_from_the_checkout() {
  local p
  p=$(make_projects leaky)
  # Remove every file the table names: nothing to check, nothing to fail.
  rm -rf "$p"
  mkdir -p "$p"
  "$GUARD" --static --projects "$p" >/dev/null 2>&1 \
    || fail "the static check failed on a checkout with none of the named files; an absent file is a skip, not a failure"
  pass "the static check skips a file that is absent from the checkout"
}

# --- the dynamic check ----------------------------------------------------------

test_dynamic_skips_without_a_baseline() {
  rm -f "$AK47_STATE/census.baseline"
  "$GUARD" --dynamic >/dev/null 2>&1 \
    || fail "the dynamic check failed with no baseline; it must skip, not fail"
  pass "the dynamic check skips when there is no baseline"
}

test_dynamic_fails_when_a_producer_grows() {
  rm -rf "$AK47_TMP_ROOT"; mkdir -p "$AK47_TMP_ROOT"
  mkdir -p "$AK47_TMP_ROOT/uvn-abc123"
  "$ROOT/ak47/census.sh" --write-baseline >/dev/null 2>&1 || fail "could not write a baseline"
  mkdir -p "$AK47_TMP_ROOT/uvn-def456" "$AK47_TMP_ROOT/uvn-ghi789"
  if "$GUARD" --dynamic >/dev/null 2>&1; then
    fail "the dynamic check passed after a producer grew"
  fi
  pass "the dynamic check fails when a producer grows"
}

# --- the report -----------------------------------------------------------------

test_the_report_names_every_check() {
  local p out
  p=$(make_projects leaky)
  out=$("$GUARD" --projects "$p" 2>&1) || true
  case "$out" in
    *pass*|*fail*) : ;;
    *) fail "the guard printed no pass/fail lines: $out" ;;
  esac
  case "$out" in
    *"passed,"*) : ;;
    *) fail "the guard printed no summary line: $out" ;;
  esac
  pass "the guard reports one line per check and a summary"
}

test_systemic_passes_on_this_checkout
test_systemic_fails_when_the_export_is_removed
test_static_passes_on_a_clean_tree
test_static_fails_on_a_leaking_tree
test_static_skips_a_file_absent_from_the_checkout
test_dynamic_skips_without_a_baseline
test_dynamic_fails_when_a_producer_grows
test_the_report_names_every_check
