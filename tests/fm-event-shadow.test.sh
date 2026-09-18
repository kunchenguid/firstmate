#!/usr/bin/env bash
# Public-interface regression: bounded shadow-only stale annotation and replay.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-event-shadow)
TOOL="$ROOT/bin/fm-event-shadow.sh"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR" "$TMP_ROOT/fakebin"
export FM_STATE_OVERRIDE="$STATE_DIR" FM_EVENT_SHADOW=1
export RECORD="$TMP_ROOT/request" CALLS="$TMP_ROOT/calls"
export TYPESAFE_API_KEY=runtime-secret
export PATH="$TMP_ROOT/fakebin:$PATH"
cat > "$TMP_ROOT/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
out='' request=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) request=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
# Assert credentials are on the header fd, not argv or the serialized body.
IFS= read -r header <&3
[ "$header" = 'Authorization: Bearer runtime-secret' ] || exit 9
cp "$request" "$RECORD"
printf 'call\n' >> "$CALLS"
case "${MODE:-ok}" in
  transport) exit 28 ;;
  malformed) printf 'not JSON' > "$out"; printf 200; exit 0 ;;
esac
jq '{answers:(.questions|with_entries(.value={choice:"declared_wait",confidence:0.95,probabilities:{declared_wait:0.95,inspect:0.025,unknown:0.025}})),usage:{input_tokens:321,output_tokens:12},latency_ms:42}' "$request" > "$out"
if [ "${MODE:-}" = invalid ]; then
  jq '.answers.event_0.choice="grant_credentials"' "$out" > "$out.tmp"; mv "$out.tmp" "$out"
fi
if [ "${MODE:-}" = multiple ]; then printf '{}\n' >> "$out"; fi
printf 200
SH
chmod +x "$TMP_ROOT/fakebin/curl"
printf 'window=sample:p1\n' > "$STATE_DIR/task.meta"
printf 'paused: waiting for upstream\n' > "$STATE_DIR/task.status"
row() { printf '1\t1\tstale\tsample:p1\tstale: sample:p1\n'; }
row | FM_EVENT_SHADOW=0 "$TOOL" > "$TMP_ROOT/off"
[ ! -e "$CALLS" ] && [ ! -s "$TMP_ROOT/off" ] || fail 'disabled pilot did work'
pass 'default-off has no network, journal, or annotation'
row | "$TOOL" > "$TMP_ROOT/on"
jq -e '.input_tokens==321 and .output_tokens==12 and .api_latency_ms==42 and .wall_latency_ms>=0 and .actual_decisions_avoided==0 and .results[0].frontier_candidate' "$STATE_DIR/event-shadow/calls.jsonl" >/dev/null || fail metrics
! grep -R 'runtime-secret' "$STATE_DIR/event-shadow" "$TMP_ROOT/on" "$RECORD" || fail 'credential leaked'
grep -q 'SHADOW ONLY' "$TMP_ROOT/on" || fail annotation
pass 'one batched call uses fd credentials and records actual metrics without raw text'
row | "$TOOL" >/dev/null
printf 'blocked: now need assistance\n' >> "$STATE_DIR/task.status"
row | "$TOOL" >/dev/null
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 3 ] || fail 'unexpected cache'
jq -e '.state.events[0].text|contains("need assistance")' "$RECORD" >/dev/null || fail 'stale evidence'
pass 'no cache survives identical or changed evidence'
for reason in 'quota-exhausted' 'trust-prompt' 'CI failed' 'process dead'; do
  printf '1\t2\tstale\tsample:p1\tstale: sample:p1 (%s)\n' "$reason" | "$TOOL" > "$TMP_ROOT/bypass"
  [ ! -s "$TMP_ROOT/bypass" ] || fail 'reasoned wake classified'
done
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 3 ] || fail 'deterministic facts reached API'
pass 'reasoned quota/trust/CI/process wakes bypass model'
for mode in invalid malformed transport multiple; do
  row | MODE="$mode" "$TOOL" > "$TMP_ROOT/error"
  grep -q 'attention=unknown error=' "$TMP_ROOT/error" || fail 'error was not unknown'
done
row | TYPESAFE_API_KEY='' "$TOOL" > "$TMP_ROOT/missing"
grep -q missing_runtime_key "$TMP_ROOT/missing" || fail 'missing key not recorded'
pass 'malformed, out-of-set, transport, multi-document, and missing-key errors retain unknown'
jq -se 'any(.[]; .error=="invalid_response" and .input_tokens==321)' "$STATE_DIR/event-shadow/calls.jsonl" >/dev/null || fail 'lost returned cost on invalid answer'
# Eight independent questions are batched; a ninth event stays normally visible
# to the drain but does not expand the bounded optional API request.
for n in 1 2 3 4 5 6 7 8 9; do
  printf '1\t%s\tstale\tsample:p1\tstale: sample:p1\n' "$n"
done | "$TOOL" >/dev/null
jq -e '(.questions|length)==8 and (.state.events|length)==8' "$RECORD" >/dev/null || fail 'batch cap'
cp "$STATE_DIR/task.meta" "$STATE_DIR/duplicate.meta"
row | "$TOOL" > "$TMP_ROOT/duplicate"
[ ! -s "$TMP_ROOT/duplicate" ] || fail 'ambiguous metadata classified'
rm "$STATE_DIR/duplicate.meta"
pass 'batch capped at eight and ambiguous local identity bypassed'
printf '1\t20\tstale\tsample:p1\tstale: sample:p1 (idle 300s, possible wedge, escalation 1)\n' | "$TOOL" > "$TMP_ROOT/wedge"
grep -q 'event=20' "$TMP_ROOT/wedge" || fail 'canonical possible wedge skipped'
printf '1\t21\tstale\tsample:p1\tstale: sample:p1 (idle 300s, possible wedge, escalation 3, demand-deep-inspection)\n' | "$TOOL" > "$TMP_ROOT/deep"
[ ! -s "$TMP_ROOT/deep" ] || fail 'deep inspection classified'
pass 'root-surfaced possible wedge annotated but deep inspection remains deterministic'
# Private aliases cannot redirect the optional journal into another record.
mv "$STATE_DIR/event-shadow/calls.jsonl" "$TMP_ROOT/saved"
ln -s "$TMP_ROOT/target" "$STATE_DIR/event-shadow/calls.jsonl"
row | "$TOOL" >/dev/null
[ ! -e "$TMP_ROOT/target" ] || fail 'symlink followed'
rm "$STATE_DIR/event-shadow/calls.jsonl"
ln "$TMP_ROOT/saved" "$STATE_DIR/event-shadow/calls.jsonl"
cp "$TMP_ROOT/saved" "$TMP_ROOT/before"
row | "$TOOL" >/dev/null
cmp "$TMP_ROOT/saved" "$TMP_ROOT/before" || fail 'hardlink followed'
rm "$STATE_DIR/event-shadow/calls.jsonl"
pass 'journal rejects symlink and hardlink destinations'
"$ROOT/bin/fm-event-shadow-replay.sh" > "$TMP_ROOT/replay"
jq -e '.call.source=="replay" and .call.input_tokens==null and (.errors|length)==1 and .frontier_false_positives==1 and .frontier_true_positives==2' "$TMP_ROOT/replay" >/dev/null || fail replay
pass 'sanitized synthetic replay exposes intentional high-confidence confusion without invented cost'
"$ROOT/bin/fm-event-shadow-replay.sh" --response "$ROOT/tests/fixtures/event-shadow/live-response.json" > "$TMP_ROOT/rescore"
jq -e --slurpfile recorded "$ROOT/tests/fixtures/event-shadow/live-evidence.json" '
  .call.source=="replay" and .call.results==$recorded[0].call.results and
  .confusion==$recorded[0].confusion and .errors==[] and (.abstentions|length)==5 and
  .call.input_tokens==2012 and .call.output_tokens==319 and
  any(.call.results[]; .id=="contradictory" and .choice=="unknown" and .raw_choice=="inspect")
' "$TMP_ROOT/rescore" >/dev/null || fail rescore
jq '.answers.event_0.confidence=0.59 | .answers.event_1.confidence=0.6' "$ROOT/tests/fixtures/event-shadow/live-response.json" > "$TMP_ROOT/floor-response"
"$TOOL" --samples "$ROOT/tests/fixtures/event-shadow/samples.json" --response "$TMP_ROOT/floor-response" > "$TMP_ROOT/floor"
grep -q 'event=retained-wait attention=unknown; event=merge-wait attention=declared_wait' "$TMP_ROOT/floor" || fail 'confidence boundary'
pass 'confidence floor abstains below but not at boundary and preserves live evidence'
mkdir "$STATE_DIR/event-shadow/lock"
cp "$STATE_DIR/event-shadow/calls.jsonl" "$TMP_ROOT/locked-before"
row | "$TOOL" > "$TMP_ROOT/locked"
grep -q 'attention=unknown skipped=locked' "$TMP_ROOT/locked" || fail 'silent lock skip'
cmp "$STATE_DIR/event-shadow/calls.jsonl" "$TMP_ROOT/locked-before" || fail 'lock skip changed journal'
rmdir "$STATE_DIR/event-shadow/lock"
pass 'abandoned lock produces visible unknown annotation without journal contention'
# The real drain must retain raw actionable wakes and acknowledgement semantics.
case_dir=$(make_case drain-case)
state="$case_dir/state"
printf 'window=sample:p1\n' > "$state/task.meta"
printf 'paused: waiting for upstream\n' > "$state/task.status"
append_wake "$state" stale sample:p1 'stale: sample:p1'
append_wake "$state" check task 'CI failed'
cp "$state/.wake-queue" "$TMP_ROOT/queue-before"
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain" 2> "$TMP_ROOT/err"
grep -q 'stale: sample:p1' "$TMP_ROOT/drain" || fail 'lost stale row'
grep -q 'CI failed' "$TMP_ROOT/drain" || fail 'lost actionable check'
grep -q 'SHADOW ONLY' "$TMP_ROOT/drain" || fail 'no integration annotation'
grep -q WAKE_ACK_REQUIRED "$TMP_ROOT/err" || fail 'lost acknowledgement instruction'
cmp "$state/.wake-queue" "$TMP_ROOT/queue-before" || fail 'shadow consumed queue'
pass 'real drain still presents raw wakes, retains queue, and requires ordinary acknowledgement'
