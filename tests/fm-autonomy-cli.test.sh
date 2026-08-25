#!/usr/bin/env bash
# Executable regression for bin/fm-autonomy.sh's inert-default doctor/status,
# held-out baseline, and durable-work-preserving kill switch.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-autonomy-cli)
home="$TMP_ROOT/home"
mkdir -p "$home/config"

out=$(FM_HOME="$home" "$ROOT/bin/fm-autonomy.sh" status) || fail "absent-config status failed"
printf '%s' "$out" | jq -e '.configured == false and .active == false and (.diagnostics[0] | contains("config/pi-autonomy.json is absent"))' >/dev/null \
  || fail "absent-config status was not exact: $out"
[ ! -e "$home/state" ] || fail "absent-config status created autonomy state"

printf '{not json}\n' > "$home/config/pi-autonomy.json"
out=$(FM_HOME="$home" "$ROOT/bin/fm-autonomy.sh" status) || fail "malformed-config status failed"
printf '%s' "$out" | jq -e '.configured == true and .active == false and (.diagnostics[0] | contains("not valid JSON"))' >/dev/null \
  || fail "malformed-config status lost its exact requirement: $out"
[ ! -e "$home/state" ] || fail "malformed-config status created autonomy state"

ln -s "$home" "$TMP_ROOT/home-alias"
out=$(FM_HOME="$TMP_ROOT/home-alias" "$ROOT/bin/fm-autonomy.sh" status) || fail "symlink-parent config status failed"
printf '%s' "$out" | jq -e '.configured == true and .active == false and (.diagnostics[0] | contains("must not traverse a symlink"))' >/dev/null \
  || fail "symlink-parent config was not refused: $out"
if FM_HOME="$TMP_ROOT/home-alias" "$ROOT/bin/fm-autonomy.sh" kill-on >/dev/null 2>&1; then
  fail "kill-on accepted a symlink-backed state path"
fi
[ ! -e "$home/state" ] || fail "refused symlink-backed kill-on mutated the real state path"
rm "$TMP_ROOT/home-alias"

printf '{}\n' > "$home/config/pi-autonomy.json"
mkdir -p "$home/state/autonomy"
printf 'durable-existing-work\n' > "$home/state/autonomy/journal.jsonl"
FM_HOME="$home" "$ROOT/bin/fm-autonomy.sh" kill-on >/dev/null || fail "kill-on failed"
[ -f "$home/state/autonomy/KILL" ] || fail "kill-on did not create the marker"
[ "$(cat "$home/state/autonomy/journal.jsonl")" = "durable-existing-work" ] || fail "kill-on changed existing durable work"
FM_HOME="$home" "$ROOT/bin/fm-autonomy.sh" kill-off >/dev/null || fail "kill-off failed"
[ ! -e "$home/state/autonomy/KILL" ] || fail "kill-off left the marker"
[ "$(cat "$home/state/autonomy/journal.jsonl")" = "durable-existing-work" ] || fail "kill-off changed existing durable work"

out=$(FM_HOME="$home" "$ROOT/bin/fm-autonomy.sh" eval) || fail "held-out eval refused the accepted baseline: $out"
printf '%s' "$out" | jq -e '.accepted == true and .failed == 0 and .passed == 11' >/dev/null \
  || fail "held-out eval did not report the accepted baseline: $out"

pass "Pi autonomy CLI is inert by default, reports exact config failures, preserves work under kill, and enforces the held-out baseline"
