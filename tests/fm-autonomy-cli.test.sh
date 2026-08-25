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

jq '.cases[0].inputs[0].payload.title = "tampered classifier input"' "$ROOT/tests/fixtures/fm-autonomy-heldout.json" > "$TMP_ROOT/tampered-corpus.json"
if out=$(FM_HOME="$home" FM_AUTONOMY_EVAL_CORPUS="$TMP_ROOT/tampered-corpus.json" "$ROOT/bin/fm-autonomy.sh" eval); then
  fail "held-out eval accepted a corpus whose classifier inputs changed: $out"
fi
printf '%s' "$out" | jq -e '.accepted == false and .corpusSha256 != ""' >/dev/null \
  || fail "held-out eval did not expose corpus-binding refusal: $out"

jq '.provenance.captureMode = "self-declared"' "$ROOT/tests/fixtures/fm-autonomy-recorded-outputs.json" > "$TMP_ROOT/tampered-recording.json"
if out=$(FM_HOME="$home" FM_AUTONOMY_EVAL_RECORDED="$TMP_ROOT/tampered-recording.json" "$ROOT/bin/fm-autonomy.sh" eval); then
  fail "held-out eval accepted unaudited classifier provenance: $out"
fi
printf '%s' "$out" | jq -e '.accepted == false' >/dev/null \
  || fail "held-out eval did not refuse unaudited classifier provenance: $out"

jq '.captureProvenance.provider = "different-provider"' "$ROOT/tests/fixtures/fm-autonomy-baseline.json" > "$TMP_ROOT/tampered-baseline.json"
if out=$(FM_HOME="$home" FM_AUTONOMY_EVAL_BASELINE="$TMP_ROOT/tampered-baseline.json" "$ROOT/bin/fm-autonomy.sh" eval); then
  fail "held-out eval accepted a classifier capture outside its provenance baseline: $out"
fi
printf '%s' "$out" | jq -e '.accepted == false' >/dev/null \
  || fail "held-out eval did not refuse classifier provenance drift: $out"

pass "Pi autonomy CLI is inert by default, reports exact config failures, preserves work under kill, and enforces the held-out baseline"
