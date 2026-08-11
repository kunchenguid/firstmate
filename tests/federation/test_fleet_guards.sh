#!/usr/bin/env bash
# Guards around fleet-dir RESOLUTION — the first-run experience for someone who just
# cloned the repo and configured nothing.
#
# Two failure modes are covered, both found by actually running a fresh clone:
#   1. dir is not a fleet   -> used to surface as `awk: fatal: cannot open ...` with
#                              exit 0: a raw internal error that also looked like success.
#   2. dir IS a fleet, but someone else's -> the built-in default is a conventional
#      shared path; a bare clone silently listed another team's operators and dumped
#      their whole event log. Membership is the opt-in signal.
#
# Hermetic: every fleet lives in a temp dir and FM_FLEET_DEFAULT_DIR is overridden, so
# the real /opt/agents/fleet is never consulted.
set -uo pipefail
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

ME=$(id -un)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A fleet that belongs to somebody else entirely.
THEIRS="$TMP/theirs"
mkdir -p "$THEIRS"
FM_FLEET_DIR="$THEIRS" "$REAL/bin/fm-fleet.sh" init >/dev/null 2>&1
printf '| alice | web | /home/alice/firstmate | claude-default | online | 2026-07-28T06:00:00Z | 80 |\n' \
  >> "$THEIRS/operators.md"

# Run fm-fleet.sh with a controlled environment. FM_HOME points at a config-less dir so
# `config/fleet-dir` can never be picked up from the real repo.
#
# `env -u FM_FLEET_DIR` is load-bearing, not tidiness: these cases must resolve the dir
# through the built-in DEFAULT so the ownership guard applies. An operator who exports
# FM_FLEET_DIR (every real fleet operator does) would otherwise flip the resolution
# source to `env`, which correctly skips the ownership check — and the suite would report
# failures that say nothing about the code. Scrub it so the run is identical everywhere.
mkdir -p "$TMP/fmhome/config"
fleet() { # var-assignments... -- verb args
  env -u FM_FLEET_DIR FM_HOME="$TMP/fmhome" FM_FLEET_DEFAULT_DIR="$THEIRS" "$@" 2>&1
}

# --- 1. not a fleet at all ----------------------------------------------------------
out=$(env FM_HOME="$TMP/fmhome" FM_FLEET_DIR="$TMP/nope" "$REAL/bin/fm-fleet.sh" status 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "uninitialized fleet exits non-zero (was 0)" || no "uninitialized fleet exited $rc"
printf '%s' "$out" | grep -q 'no initialized fleet' \
  && ok "uninitialized fleet names the problem" || no "no diagnostic: $out"
printf '%s' "$out" | grep -qi 'awk' && no "raw awk error leaked to the user" || ok "no raw awk error"
printf '%s' "$out" | grep -q 'chosen by FM_FLEET_DIR' \
  && ok "diagnostic says HOW the dir was chosen" || no "missing provenance"

# --- 2. an existing fleet that is not yours, reached via the DEFAULT ----------------
for verb in status view; do
  out=$(fleet "$REAL/bin/fm-fleet.sh" "$verb"); rc=$?
  [ "$rc" -ne 0 ] \
    && ok "default -> foreign fleet: '$verb' refuses" \
    || no "'$verb' returned $rc on a foreign fleet"
  printf '%s' "$out" | grep -q 'alice' \
    && no "'$verb' leaked the other team's data" \
    || ok "default -> foreign fleet: '$verb' leaks nothing"
done

# route must not disclose the foreign operator either
out=$(fleet "$REAL/bin/fm-fleet.sh" route web)
printf '%s' "$out" | grep -q '^alice$' && no "route disclosed a foreign operator" \
                                       || ok "route discloses no foreign operator"

# --- 3. explicit choice is always honoured ------------------------------------------
out=$(env FM_HOME="$TMP/fmhome" FM_FLEET_DIR="$THEIRS" "$REAL/bin/fm-fleet.sh" status 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q alice \
  && ok "explicit FM_FLEET_DIR is honoured (no ownership check)" \
  || no "explicit FM_FLEET_DIR blocked (rc=$rc): $out"

out=$(env -u FM_FLEET_DIR FM_HOME="$TMP/fmhome" FM_FLEET_DEFAULT_DIR="$THEIRS" FM_FLEET_ACCEPT_DEFAULT=1 \
      "$REAL/bin/fm-fleet.sh" status 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "FM_FLEET_ACCEPT_DEFAULT=1 acknowledges the default" \
                || no "acknowledged default still blocked (rc=$rc)"

# --- 4. being an operator IS the opt-in ---------------------------------------------
MINE="$TMP/mine"; mkdir -p "$MINE"
FM_FLEET_DIR="$MINE" "$REAL/bin/fm-fleet.sh" init >/dev/null 2>&1
printf '| %s | backend | %s | - | online | 2026-07-28T06:00:00Z | 90 |\n' "$ME" "$TMP/fmhome" \
  >> "$MINE/operators.md"
out=$(env -u FM_FLEET_DIR FM_HOME="$TMP/fmhome" FM_FLEET_DEFAULT_DIR="$MINE" "$REAL/bin/fm-fleet.sh" status 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "default is allowed when you ARE an operator in it" \
                || no "own fleet via default was blocked (rc=$rc): $out"

# --- 5. surface-local verbs need no fleet at all ------------------------------------
# FM_HOME must be the real repo here: `models` reads the shipped model map
# (docs/examples/model-surfaces.json, or a local config/model-surfaces.json) from it.
# The point under test is only that a bogus FM_FLEET_DIR does not block it.
out=$(env FM_HOME="$REAL" FM_FLEET_DIR="$TMP/nope" "$REAL/bin/fm-fleet.sh" models 2>&1)
printf '%s' "$out" | grep -q 'no initialized fleet' \
  && no "models was blocked by the fleet guard" \
  || ok "models is not blocked by a missing fleet"

out=$(env FM_HOME="$REAL" FM_FLEET_DIR="$TMP/nope" "$REAL/bin/fm-fleet.sh" budget 2>&1)
printf '%s' "$out" | grep -q 'no initialized fleet' \
  && no "budget was blocked by the fleet guard" \
  || ok "budget is not blocked by a missing fleet"

# --- 6. fm-fleet-wait.sh honours the same guards ------------------------------------
out=$(env FM_HOME="$TMP/fmhome" FM_FLEET_DIR="$TMP/nope" "$REAL/bin/fm-fleet-wait.sh" "$ME" --once 2>&1); rc=$?
[ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'no initialized fleet' \
  && ok "wait refuses an uninitialized fleet loudly" \
  || no "wait on uninitialized fleet: rc=$rc: $out"

out=$(fleet "$REAL/bin/fm-fleet-wait.sh" "$ME" --once); rc=$?
[ "$rc" -eq 3 ] && ok "default -> foreign fleet: wait refuses" \
                || no "wait on foreign default fleet: rc=$rc: $out"
printf '%s' "$out" | grep -q 'alice' \
  && no "wait leaked the other team's data" \
  || ok "default -> foreign fleet: wait leaks nothing"

echo "-----"
[ "$fail" -eq 0 ] && echo "ALL PASS ($pass)" || { echo "$fail FAILED"; exit 1; }
