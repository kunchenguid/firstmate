#!/usr/bin/env bash
# The single-machine guarantee, as a test rather than a promise.
#
# The helm gate went into fm-spawn, fm-send, fm-teardown, fm-pr-merge, and
# fm-merge-local - five commands people run every day, on machines that have
# never heard of a fleet and never will. This repo is a shared template, so a
# gate that refused work without a lease would break every one of those users on
# the day they pulled.
#
# tests/fixtures/fm-helm-fleetless-baseline.txt was captured by running
# tests/fm-helm-fleetless-probe.sh on the tree BEFORE the gate existed. This
# test re-runs the same probe and requires the output to match byte for byte:
# same wording, same exit codes, same files written, no network call, and a real
# merge that still lands.
#
# If a future change to any of those five commands makes this fail, the fix is
# to look at what changed for a fleetless home - not to re-capture the baseline.
# Re-capturing is only correct when the difference is intended AND the commit
# says why.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASELINE="$ROOT/tests/fixtures/fm-helm-fleetless-baseline.txt"
PROBE="$ROOT/tests/fm-helm-fleetless-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-single)

test_fleetless_transcript_is_unchanged() {
  local out
  [ -f "$BASELINE" ] || fail "the pre-change baseline transcript is missing: $BASELINE"
  mkdir -p "$TMP_ROOT"
  out="$TMP_ROOT/now.txt"
  bash "$PROBE" > "$out" 2>&1 || fail "the fleetless probe itself failed to run"
  if ! diff -u "$BASELINE" "$out" > "$TMP_ROOT/diff.txt"; then
    printf -- '--- what changed for a machine with no fleet ---\n' >&2
    cat "$TMP_ROOT/diff.txt" >&2
    fail "a fleetless home must behave exactly as it did before the helm gate existed"
  fi
  pass "fleetless home: spawn/send/teardown/pr-merge/merge-local byte-identical to the pre-helm tree"
}

# The probe covers the commands. This covers the digest: a single-machine
# session start must not gain a helm section, a helm heading, or a helm word.
test_session_start_says_nothing_about_the_helm() {
  local home="$TMP_ROOT/home" out
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  out=$(FM_HOME="$home" FM_BACKEND=tmux "$ROOT/bin/fm-session-start.sh" 2>&1) || true
  assert_not_contains "$out" "HELM" "a fleetless session start must not mention the helm"
  assert_not_contains "$out" "control plane" "a fleetless session start must not mention a control plane"
  pass "fleetless home: the session-start digest carries no helm section at all"
}

# The same digest on a home that DID join a fleet has to say who is steering,
# because that is the one thing a session cannot work out for itself.
test_session_start_reports_the_helm_when_there_is_one() {
  local home="$TMP_ROOT/fleethome" out
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/cr/verbs"
  cp "$ROOT/control-root/verbs/fmr-verb.sh" "$home/cr/verbs/fmr-verb.sh"
  chmod 755 "$home/cr/verbs/fmr-verb.sh"
  cat > "$home/cr/config" <<EOF
FM_ROOT=$ROOT
FM_HOME=$home
HOME_DIR=$home
PATH=$PATH
FLEET_ROOT=$home/fr
EOF
  cat > "$home/config/fleet.json" <<EOF
{ "fleet": "solo", "machine": "here", "control_root": "$home/cr", "anchor": "here" }
EOF
  out=$(FM_HOME="$home" FM_BACKEND=tmux "$ROOT/bin/fm-session-start.sh" 2>&1) || true
  assert_contains "$out" "HELM" "a fleet session start must carry a helm section"
  assert_contains "$out" "no machine holds the helm" \
    "an unclaimed fleet must be reported as unclaimed, not assumed"
  assert_contains "$out" "may READ fleet state and may not change it" \
    "a session that may not act must be told so plainly"
  pass "fleet home: the session-start digest reports who is steering"
}

test_fleetless_transcript_is_unchanged
test_session_start_says_nothing_about_the_helm
test_session_start_reports_the_helm_when_there_is_one
