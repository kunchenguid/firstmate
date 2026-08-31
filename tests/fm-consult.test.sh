#!/usr/bin/env bash
# Behavior tests for the private pro-cli consultation state machine and its
# process-event adapter. The fake pro-cli records argv, never reads credentials,
# and delays job wait until a fixture trigger arrives, so the test proves that
# submission returns while completion waits in the generic background runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-consult-tests)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
FAKE_BIN="$TMP_ROOT/fakebin"
FAKE_STATE="$TMP_ROOT/pro-cli-state"
WAIT_STARTED="$TMP_ROOT/wait-started"
WAIT_RELEASE="$TMP_ROOT/wait-release"
RESULT_STARTED="$TMP_ROOT/result-started"
RESULT_RELEASE="$TMP_ROOT/result-release"
REAL_SHASUM=$(command -v shasum 2>/dev/null || true)
REAL_SHA256SUM=$(command -v sha256sum 2>/dev/null || true)
mkdir -p "$FAKE_BIN" "$FAKE_STATE"
export FAKE_STATE WAIT_STARTED WAIT_RELEASE RESULT_STARTED RESULT_RELEASE REAL_SHASUM REAL_SHA256SUM

cat > "$FAKE_BIN/shasum" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "$REAL_SHASUM" ] || exit 127
"$REAL_SHASUM" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FM_CONSULT_MUTATE_INPUT_ONE:-}" ] && [ ! -e "${FM_CONSULT_MUTATE_MARK_ONE:-}" ]; then
  printf '%s' "${FM_CONSULT_MUTATE_REPLACEMENT_ONE:-}" > "$FM_CONSULT_MUTATE_INPUT_ONE"
  : > "$FM_CONSULT_MUTATE_MARK_ONE"
elif [ "$rc" -eq 0 ] && [ -n "${FM_CONSULT_MUTATE_INPUT_TWO:-}" ] && [ ! -e "${FM_CONSULT_MUTATE_MARK_TWO:-}" ]; then
  printf '%s' "${FM_CONSULT_MUTATE_REPLACEMENT_TWO:-}" > "$FM_CONSULT_MUTATE_INPUT_TWO"
  : > "$FM_CONSULT_MUTATE_MARK_TWO"
fi
exit "$rc"
SH
chmod +x "$FAKE_BIN/shasum"

cat > "$FAKE_BIN/sha256sum" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "$REAL_SHA256SUM" ] || exit 127
"$REAL_SHA256SUM" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FM_CONSULT_MUTATE_INPUT_ONE:-}" ] && [ ! -e "${FM_CONSULT_MUTATE_MARK_ONE:-}" ]; then
  printf '%s' "${FM_CONSULT_MUTATE_REPLACEMENT_ONE:-}" > "$FM_CONSULT_MUTATE_INPUT_ONE"
  : > "$FM_CONSULT_MUTATE_MARK_ONE"
elif [ "$rc" -eq 0 ] && [ -n "${FM_CONSULT_MUTATE_INPUT_TWO:-}" ] && [ ! -e "${FM_CONSULT_MUTATE_MARK_TWO:-}" ]; then
  printf '%s' "${FM_CONSULT_MUTATE_REPLACEMENT_TWO:-}" > "$FM_CONSULT_MUTATE_INPUT_TWO"
  : > "$FM_CONSULT_MUTATE_MARK_TWO"
fi
exit "$rc"
SH
chmod +x "$FAKE_BIN/sha256sum"

cat > "$FAKE_BIN/pro-cli" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_STATE/argv.log"
case "${1-}:${2-}" in
  doctor:--json)
    value=${PRO_CLI_DOCTOR_JSON-}
    [ -n "$value" ] || value='{"ok":true,"data":{"ready":true}}'
    printf '%s\n' "$value"
    ;;
  limits:--json)
    value=${PRO_CLI_LIMITS_JSON-}
    [ -n "$value" ] || value=$(printf '{"ok":true,"data":{"account":{"planType":"pro"},"observedLimits":[{"featureName":"gpt-5-6-pro","remaining":1,"resetAfter":null,"observedAt":"%s","jobId":null}]}}' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
    printf '%s\n' "$value"
    ;;
  job:create)
    printf '%s\n' create >> "$FAKE_STATE/create-count"
    value=${PRO_CLI_CREATE_JSON-}
    [ -n "$value" ] || value='{"ok":true,"data":{"job":{"id":"job_fixture","status":"queued"}}}'
    printf '%s\n' "$value"
    ;;
  job:wait)
    : > "$WAIT_STARTED"
    while [ ! -e "$WAIT_RELEASE" ]; do sleep 0.05; done
    value=${PRO_CLI_WAIT_JSON-}
    [ -n "$value" ] || value='{"ok":true,"data":{"job":{"id":"job_fixture","status":"succeeded"}}}'
    printf '%s\n' "$value"
    exit "${PRO_CLI_WAIT_EXIT:-0}"
    ;;
  job:status)
    value=${PRO_CLI_STATUS_JSON-}
    [ -n "$value" ] || value='{"ok":true,"data":{"job":{"id":"job_fixture","status":"succeeded"}}}'
    printf '%s\n' "$value"
    ;;
  job:result)
    [ -n "${PRO_CLI_RESULT_JSON+x}" ] || exit 99
    printf '%s\n' "$PRO_CLI_RESULT_JSON"
    if [ "${PRO_CLI_RESULT_HOLD:-0}" = 1 ]; then
      : > "$RESULT_STARTED"
      while [ ! -e "$RESULT_RELEASE" ]; do sleep 0.05; done
    fi
    ;;
  --version:*)
    printf 'pro-cli fixture\n'
    ;;
  *)
    printf '{"ok":false,"error":{"code":"INVALID_ARGS"}}\n' >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKE_BIN/pro-cli"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.pro-cli"
credential_secret="credential-$(date +%s)-$$"
printf '%s\n' "$credential_secret" > "$HOME/.pro-cli/cookies"
chmod 000 "$HOME/.pro-cli/cookies"

fc() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-consult.sh" "${@:2}"; }
pa() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent-consult.sh" "${@:2}"; }
pe() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

wait_for_file() {
  local file=$1 tries=${2:-100}
  for _ in $(seq 1 "$tries"); do
    [ -e "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

mode_of() { perl -e 'my @s = stat($ARGV[0]) or exit 1; printf "%o", $s[2] & 07777' "$1"; }

consult_home() {
  mkdir -p "$1/state"
  chmod 0700 "$1" "$1/state"
}

prepare_id() {  # <home> <question file>
  local output
  output=$(fc "$1" prepare --question "$2" --privacy internal-research) || fail "prepare failed: $output"
  printf '%s\n' "$output" | awk '/^prepared: / { print $2; exit }'
}

json_result_for() {  # <answer>
  perl -MJSON::PP -e 'print encode_json({ok => JSON::PP::true, data => {jobId => "job_fixture", result => $ARGV[0]}})' "$1"
}

raw_sha256() {
  if [ -n "$REAL_SHASUM" ]; then
    "$REAL_SHASUM" -a 256 "$1" | awk '{print $1}'
  else
    "$REAL_SHA256SUM" "$1" | awk '{print $1}'
  fi
}

assert_tracked_secret_absent() {  # <secret> <diagnostic>
  local rc=0
  git -C "$ROOT" grep -F -l -- "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) fail "$2" ;;
    1) ;;
    *) fail "tracked-file privacy scan could not complete" ;;
  esac
}

assert_tree_secret_absent() {  # <secret> <directory> <diagnostic>
  local rc=0
  grep -r -F -l -- "$1" "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) fail "$3" ;;
    1) ;;
    *) fail "private-boundary scan could not complete" ;;
  esac
}

write_ready_request() {  # <consult directory> <consult id>
  local dir=$1 id=$2 model reasoning privacy question_hash contract_hash source_hash observed
  model=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{model}' "$dir/prepared.json")
  reasoning=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{reasoning}' "$dir/prepared.json")
  privacy=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{privacy_classification}' "$dir/prepared.json")
  source_hash=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{source_packet_sha256} // ""' "$dir/prepared.json")
  question_hash=$(raw_sha256 "$dir/question.md")
  contract_hash=$(raw_sha256 "$dir/contract.md")
  observed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  perl -MJSON::PP -e '
    my ($id, $model, $reasoning, $privacy, $question, $contract, $source, $observed) = @ARGV;
    print JSON::PP->new->canonical->encode({
      schema_version => 1, consult_id => $id, created_at => $observed,
      question_sha256 => $question, contract_sha256 => $contract,
      source_packet_sha256 => length($source) ? $source : undef,
      model => $model, reasoning => $reasoning, privacy_classification => $privacy,
      retries => 0, conversation_retention => "temporary",
      preflight => { recorded_at => $observed, doctor => { available => JSON::PP::true, kind => "doctor", ready => JSON::PP::true } },
      limits_observed_at => $observed,
      limits_observed => { available => JSON::PP::true, kind => "limits", account => { planType => "pro" },
        observedLimits => [{ featureName => $model, remaining => 1, observedAt => $observed }] },
      redaction_declaration => "fixture"
    }), "\n";
  ' "$id" "$model" "$reasoning" "$privacy" "$question_hash" "$contract_hash" "$source_hash" "$observed" \
    > "$dir/request.json"
  chmod 0600 "$dir/request.json"
}

# Run one command under a real deadline. A credential FIFO has no writer, so a
# direct cookie read would block and make this guard fail rather than merely
# relying on a content scan after the fact.
deadline_exec() {
  perl -e '
    my $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid == 0) { exec @ARGV; exit 127; }
    $SIG{ALRM} = sub { kill "TERM", $pid; waitpid $pid, 0; exit 124; };
    alarm 2;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$@"
}

H1="$TMP_ROOT/home-one"
consult_home "$H1"
question_secret="question-$(date +%s)-$$"
answer_secret="answer-$(date +%s)-$$"
QUESTION_ONE="$TMP_ROOT/question-one.md"
printf '%s\n' "$question_secret" > "$QUESTION_ONE"
id_one=$(prepare_id "$H1" "$QUESTION_ONE")
case "$id_one" in ????????-????-????-????-????????????) ;; *) fail "prepare returned no UUID-shaped consult id: $id_one" ;; esac
record_one="$H1/data/consults/$id_one"
[ "$(mode_of "$record_one")" = 700 ] || fail "consult directory is not 0700"
for leaf in question.md contract.md prepared.json; do
  [ "$(mode_of "$record_one/$leaf")" = 600 ] || fail "$leaf is not 0600"
done
assert_grep '"source_packet_sha256":null' "$record_one/prepared.json" "an absent source packet is explicit in the prepared record"
assert_grep 'ADVISORY_ONLY' "$record_one/contract.md" "contract declares advisory-only authority"
assert_grep "FIRSTMATE_CONSULT_ID: $id_one" "$record_one/question.md" "private question carries its unique forensic marker"
assert_grep 'Conversation retention: temporary' "$record_one/contract.md" "ordinary consult declares temporary retention"
assert_grep 'Deep Research is not enabled' "$record_one/contract.md" "saved-chat disclosure remains explicit"

PRO_CLI_RESULT_JSON=$(json_result_for "$answer_secret")
export PRO_CLI_RESULT_JSON
submit_out=$(fc "$H1" submit "$id_one") || fail "submit failed: $submit_out"
assert_contains "$submit_out" "submitted: $id_one" "non-waiting submit returns the consult id"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = 1 ] || fail "submit did not issue exactly one create"
assert_grep '"retries":0' "$record_one/request.json" "request records zero retries"
assert_grep '"source_packet_sha256":null' "$record_one/request.json" "an absent source packet remains explicit in the request record"
assert_grep '"terminal":"SUBMITTED"' "$record_one/submission.json" "submission has one submitted terminal"
assert_grep '"pro_cli_version":"pro-cli fixture"' "$record_one/submission.json" "submission records the local pro-cli identity"
assert_absent "$WAIT_STARTED" "submit did not call job wait in the foreground"

source_one="consult-$id_one"
reconcile_out=$(pe "$H1" reconcile 2>&1) || fail "process-event reconcile failed: $reconcile_out"
if ! wait_for_file "$WAIT_STARTED"; then
  fail "background runner never started the known-job wait: $reconcile_out"
fi
assert_absent "$H1/state/.wake-queue" "wait did not block reconcile or publish before completion"
: > "$WAIT_RELEASE"
wait_for_file "$H1/state/.wake-queue" || fail "completion did not publish a process-event wake"
assert_contains "$(awk -F '\t' '{print $5}' "$H1/state/.wake-queue")" "procevent consult $source_one 1" "completion publishes the normal wake shape"
assert_not_contains "$(awk -F '\t' '{print $5}' "$H1/state/.wake-queue")" "$answer_secret" "answer never reaches the wake line"
capture_one="$H1/state/procevent-inbox/$source_one.1.result"
wait_for_file "$capture_one" || fail "completion envelope was not durably captured"
assert_not_contains "$(<"$capture_one")" "$answer_secret" "adapter completion envelope omits full advisory text"
[ "$(mode_of "$capture_one")" = 600 ] || fail "completion envelope is not 0600"

bad_capture="$TMP_ROOT/mismatched-completion.json"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_other","wait_exit":0,"wait_timed_out":false,"error_code":null}\n' "$id_one" > "$bad_capture"
chmod 0600 "$bad_capture"
mismatch_status=0
pa "$H1" handle "$id_one" 1 "$bad_capture" >/dev/null 2>&1 || mismatch_status=$?
[ "$mismatch_status" -ne 0 ] || fail "mismatched result job id was accepted"
assert_absent "$record_one/advisory.md" "mismatched job id cannot create an advisory"

detached_capture="$TMP_ROOT/detached-matching-completion.json"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_fixture","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' "$id_one" > "$detached_capture"
chmod 0600 "$detached_capture"
detached_status=0
pa "$H1" handle "$id_one" 1 "$detached_capture" >/dev/null 2>&1 || detached_status=$?
[ "$detached_status" -ne 0 ] || fail "a detached matching envelope acknowledged another captured generation"
assert_absent "$record_one/advisory.md" "a detached envelope cannot create an advisory"
assert_absent "${capture_one%.result}.handled" "a detached envelope acknowledged the durable capture"

handle_status=0
handle_out=$(pa "$H1" handle "$id_one" 1 "$capture_one") || handle_status=$?
[ "$handle_status" -eq 0 ] || fail "completion handling failed: $handle_out argv=$(<"$FAKE_STATE/argv.log")"
assert_contains "$handle_out" "handled: $source_one 1" "receipt completion acknowledges exactly the captured generation"
assert_grep "$answer_secret" "$record_one/advisory.md" "matching job result is written once to advisory"
[ "$(mode_of "$record_one/advisory.md")" = 600 ] || fail "advisory is not 0600"
assert_not_contains "$(<"$record_one/receipt.json")" "$answer_secret" "receipt contains answer hash rather than answer bytes"
assert_grep '"result_terminal":"ADVISORY_RECORDED"' "$record_one/receipt.json" "receipt records a durable advisory terminal"
rm -f -- "$record_one/receipt.json"
recovery_out=$(pa "$H1" handle "$id_one" 1 "$capture_one") || fail "advisory-without-receipt recovery failed: $recovery_out"
assert_contains "$recovery_out" "already-handled: $source_one 1" "advisory recovery reuses the captured generation"
assert_grep '"result_terminal":"ADVISORY_RECORDED"' "$record_one/receipt.json" "byte-identical advisory recovery completes its receipt"
replay_out=$(pa "$H1" handle "$id_one" 1 "$capture_one") || fail "completion replay failed: $replay_out"
assert_contains "$replay_out" "already-handled: $source_one 1" "replay does not authorize a second handling effect"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = 1 ] || fail "completion replay created another pro-cli job"
pass "a known job completes through the process-event runner without blocking submission"

H_INPUT_SNAPSHOT="$TMP_ROOT/home-input-snapshot"
consult_home "$H_INPUT_SNAPSHOT"
SNAPSHOT_QUESTION="$TMP_ROOT/snapshot-question.md"
SNAPSHOT_SOURCE="$TMP_ROOT/snapshot-source.md"
printf 'original question bytes\n' > "$SNAPSHOT_QUESTION"
printf 'original source bytes\n' > "$SNAPSHOT_SOURCE"
snapshot_question_hash=$(raw_sha256 "$SNAPSHOT_QUESTION")
snapshot_source_hash=$(raw_sha256 "$SNAPSHOT_SOURCE")
export FM_CONSULT_MUTATE_INPUT_ONE="$SNAPSHOT_QUESTION"
export FM_CONSULT_MUTATE_REPLACEMENT_ONE='replacement question bytes'
export FM_CONSULT_MUTATE_MARK_ONE="$TMP_ROOT/mutated-question"
export FM_CONSULT_MUTATE_INPUT_TWO="$SNAPSHOT_SOURCE"
export FM_CONSULT_MUTATE_REPLACEMENT_TWO='replacement source bytes'
export FM_CONSULT_MUTATE_MARK_TWO="$TMP_ROOT/mutated-source"
snapshot_out=$(fc "$H_INPUT_SNAPSHOT" prepare --question "$SNAPSHOT_QUESTION" --source-packet "$SNAPSHOT_SOURCE" --privacy internal-research) \
  || fail "input snapshot preparation failed: $snapshot_out"
unset FM_CONSULT_MUTATE_INPUT_ONE FM_CONSULT_MUTATE_REPLACEMENT_ONE FM_CONSULT_MUTATE_MARK_ONE
unset FM_CONSULT_MUTATE_INPUT_TWO FM_CONSULT_MUTATE_REPLACEMENT_TWO FM_CONSULT_MUTATE_MARK_TWO
snapshot_id=$(printf '%s\n' "$snapshot_out" | awk '/^prepared: / { print $2; exit }')
snapshot_record="$H_INPUT_SNAPSHOT/data/consults/$snapshot_id"
snapshot_record_question_hash=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{question_input_sha256}' "$snapshot_record/prepared.json")
snapshot_record_source_hash=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{source_packet_sha256}' "$snapshot_record/prepared.json")
[ "$snapshot_record_question_hash" = "$snapshot_question_hash" ] || fail "prepared question hash did not bind the staged question bytes"
[ "$snapshot_record_source_hash" = "$snapshot_source_hash" ] || fail "prepared source hash did not bind the staged source bytes"
assert_grep 'original question bytes' "$snapshot_record/question.md" "question publication uses the verified staged snapshot"
assert_grep 'original source bytes' "$snapshot_record/question.md" "source publication uses the verified staged snapshot"
assert_not_contains "$(<"$snapshot_record/question.md")" 'replacement question bytes' "question publication reread mutable caller input"
assert_not_contains "$(<"$snapshot_record/question.md")" 'replacement source bytes' "source publication reread mutable caller input"
pass "question and source hashes bind the exact published snapshots"

assert_tracked_secret_absent "$question_secret" "private question content reached tracked repository files"
assert_tracked_secret_absent "$answer_secret" "private advisory content reached tracked repository files"
assert_tree_secret_absent "$answer_secret" "$H1/state" "advisory content escaped into runtime state"
assert_tree_secret_absent "$credential_secret" "$H1/data" "credential content escaped into consultation data"
assert_not_contains "$(<"$FAKE_STATE/argv.log")" " ask " "consult capability never falls back to pro-cli ask"
assert_grep 'job create @question.md --json --retries 0 --temporary' "$FAKE_STATE/argv.log" "submission uses the required non-waiting durable invocation with retries disabled"
pass "questions answers and credentials stay out of tracked files events and command output"

# The script must delegate browser-session access to pro-cli, never inspect its
# cookies itself. A direct read here would block on the unwritable FIFO and the
# deadline would return 124; both the ordinary preparation and submit paths
# must finish normally without copying or printing the credential sentinel.
H_CREDENTIAL="$TMP_ROOT/home-credential-boundary"
consult_home "$H_CREDENTIAL"
CREDENTIAL_HOME="$TMP_ROOT/credential-home"
mkdir -p "$CREDENTIAL_HOME/.pro-cli"
mkfifo "$CREDENTIAL_HOME/.pro-cli/cookies"
chmod 000 "$CREDENTIAL_HOME/.pro-cli/cookies"
credential_prepare=$(HOME="$CREDENTIAL_HOME" FM_HOME="$H_CREDENTIAL" FM_ROOT_OVERRIDE="$ROOT" \
  deadline_exec "$ROOT/bin/fm-consult.sh" prepare --question "$QUESTION_ONE" --privacy internal-research) \
  || fail "preparation attempted to read the credential FIFO"
id_credential=$(printf '%s\n' "$credential_prepare" | awk '/^prepared: / { print $2; exit }')
case "$id_credential" in ????????-????-????-????-????????????) ;; *) fail "credential guard did not prepare a consult" ;; esac
credential_submit=$(HOME="$CREDENTIAL_HOME" FM_HOME="$H_CREDENTIAL" FM_ROOT_OVERRIDE="$ROOT" \
  deadline_exec "$ROOT/bin/fm-consult.sh" submit "$id_credential") \
  || fail "submission attempted to read the credential FIFO"
assert_contains "$credential_submit" "submitted: $id_credential" "submission completes without opening session credentials"
assert_not_contains "$credential_prepare$credential_submit" "$credential_secret" "credential sentinel is never printed"
pass "consult machinery never directly reads, copies, or prints session credentials"

H2="$TMP_ROOT/home-ambiguous"
consult_home "$H2"
QUESTION_TWO="$TMP_ROOT/question-two.md"
printf 'ambiguous question\n' > "$QUESTION_TWO"
id_two=$(prepare_id "$H2" "$QUESTION_TWO")
export PRO_CLI_CREATE_JSON='{"ok":true,"data":{"job":{}}}'
ambiguous_out=$(fc "$H2" submit "$id_two") || fail "ambiguous submit did not record a terminal: $ambiguous_out"
assert_contains "$ambiguous_out" "DELIVERY_AMBIGUOUS" "malformed create response reaches DELIVERY_AMBIGUOUS"
assert_grep '"terminal":"DELIVERY_AMBIGUOUS"' "$H2/data/consults/$id_two/submission.json" "ambiguous terminal is durable"
before_ambiguous=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
replay_submit=$(fc "$H2" submit "$id_two") || fail "ambiguous replay did not safely return: $replay_submit"
assert_contains "$replay_submit" "already-terminal" "same consult replay has no second effect"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_ambiguous" ] || fail "ambiguous replay resubmitted"

id_two_next=$(prepare_id "$H2" "$QUESTION_TWO")
blocked_submit=0
blocked_out=$(fc "$H2" submit "$id_two_next" 2>&1) || blocked_submit=$?
[ "$blocked_submit" -ne 0 ] || fail "a different consult submitted before human ambiguity reconciliation"
assert_contains "$blocked_out" "reconciles DELIVERY_AMBIGUOUS" "different consult is blocked at submission boundary"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_ambiguous" ] || fail "ambiguity blocker still created a job"
printf '{"schema_version":1,"consult_id":"%s","reconciled_at":"2026-01-01T00:00:00Z","human_record":"captain-record-42","state":"HUMAN_RECONCILED"}\n' \
  "$id_two" > "$H2/data/consults/$id_two/reconciliation.json"
chmod 0644 "$H2/data/consults/$id_two/reconciliation.json"
invalid_reconciliation_status=0
invalid_reconciliation_out=$(fc "$H2" submit "$id_two_next" 2>&1) || invalid_reconciliation_status=$?
[ "$invalid_reconciliation_status" -ne 0 ] || fail "an unsafe reconciliation mode unblocked a different consult"
assert_contains "$invalid_reconciliation_out" "reconciles DELIVERY_AMBIGUOUS" "reconciliation mode is validated at the shared blocker"
chmod 0600 "$H2/data/consults/$id_two/reconciliation.json"
printf '{"schema_version":1,"consult_id":"%s","reconciled_at":"2026-01-01T00:00:00Z","human_record":"captain-record-42","state":"NOT_RECONCILED"}\n' \
  "$id_two" > "$H2/data/consults/$id_two/reconciliation.json"
invalid_reconciliation_status=0
invalid_reconciliation_out=$(fc "$H2" submit "$id_two_next" 2>&1) || invalid_reconciliation_status=$?
[ "$invalid_reconciliation_status" -ne 0 ] || fail "an invalid reconciliation record unblocked a different consult"
assert_contains "$invalid_reconciliation_out" "reconciles DELIVERY_AMBIGUOUS" "only a complete HUMAN_RECONCILED record lifts the blocker"
rm -f -- "$H2/data/consults/$id_two/reconciliation.json"
fc "$H2" reconcile-ambiguous "$id_two" --human-record captain-record-42 >/dev/null || fail "explicit reconciliation was rejected"
[ "$(mode_of "$H2/data/consults/$id_two/reconciliation.json")" = 600 ] || fail "reconciliation record is not 0600"
export PRO_CLI_CREATE_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"queued"}}}'
fc "$H2" submit "$id_two_next" >/dev/null || fail "reconciled different consult did not submit"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = $((before_ambiguous + 1)) ] || fail "reconciled submit count is wrong"
pass "delivery ambiguity forbids automatic retries and blocks a different consult until explicit reconciliation"

H_ATTEMPT_ONLY="$TMP_ROOT/home-attempt-only"
consult_home "$H_ATTEMPT_ONLY"
id_attempt_only=$(prepare_id "$H_ATTEMPT_ONLY" "$QUESTION_TWO")
id_after_attempt=$(prepare_id "$H_ATTEMPT_ONLY" "$QUESTION_TWO")
attempt_only_record="$H_ATTEMPT_ONLY/data/consults/$id_attempt_only"
printf '{"schema_version":1,"consult_id":"%s","attempted_at":"%s","state":"SUBMISSION_ATTEMPTED","retries":0}\n' \
  "$id_attempt_only" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$attempt_only_record/submission-attempt.json"
chmod 0600 "$attempt_only_record/submission-attempt.json"
before_attempt_only=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
attempt_only_status=0
attempt_only_out=$(fc "$H_ATTEMPT_ONLY" submit "$id_after_attempt" 2>&1) || attempt_only_status=$?
[ "$attempt_only_status" -ne 0 ] || fail "an attempt without a conclusive terminal did not block a different consult"
assert_contains "$attempt_only_out" "reconciles DELIVERY_AMBIGUOUS" "the unresolved attempt reports the human reconciliation boundary"
assert_grep '"terminal":"DELIVERY_AMBIGUOUS"' "$attempt_only_record/submission.json" "an unresolved attempt becomes DELIVERY_AMBIGUOUS"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_attempt_only" ] || fail "attempt-only recovery created another job"
fc "$H_ATTEMPT_ONLY" reconcile-ambiguous "$id_attempt_only" --human-record captain-record-43 >/dev/null \
  || fail "attempt-only ambiguity reconciliation was rejected"
fc "$H_ATTEMPT_ONLY" submit "$id_after_attempt" >/dev/null || fail "attempt-only reconciliation did not unblock the next consult"
pass "an unresolved submission attempt blocks every consult until validated human reconciliation"

H3="$TMP_ROOT/home-stalled"
consult_home "$H3"
id_three=$(prepare_id "$H3" "$QUESTION_TWO")
rm -f -- "$WAIT_STARTED" "$WAIT_RELEASE"
export PRO_CLI_WAIT_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"running"},"wait":{"timedOut":true}}}'
export PRO_CLI_STATUS_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"running"}}}'
fc "$H3" submit "$id_three" >/dev/null || fail "stalled fixture submit failed"
stalled_reconcile=$(pe "$H3" reconcile 2>&1) || fail "stalled fixture reconcile failed: $stalled_reconcile"
wait_for_file "$WAIT_STARTED" || fail "stalled fixture wait did not start: $stalled_reconcile"
: > "$WAIT_RELEASE"
source_three="consult-$id_three"
capture_three="$H3/state/procevent-inbox/$source_three.1.result"
wait_for_file "$capture_three" || fail "stalled completion was not captured"
assert_grep 'job wait job_fixture --soft-timeout 1800000 --json' "$FAKE_STATE/argv.log" "bounded wait uses pro-cli soft timeout so the terminal status remains inspectable"
pa "$H3" handle "$id_three" 1 "$capture_three" >/dev/null || fail "stalled completion did not handle"
assert_grep '"result_terminal":"STALLED"' "$H3/data/consults/$id_three/receipt.json" "bounded normal-job timeout records STALLED"
assert_absent "$H3/data/consults/$id_three/advisory.md" "stalled job cannot manufacture an advisory"
pass "a normal known job that remains running after bounded waiting records STALLED"

# A validated completed job remains terminal even when the local wait process
# reports a transport exit after receiving that completion.
H_WAIT_COMPLETED="$TMP_ROOT/home-wait-completed"
consult_home "$H_WAIT_COMPLETED"
id_wait_completed=$(prepare_id "$H_WAIT_COMPLETED" "$QUESTION_TWO")
rm -f -- "$WAIT_STARTED" "$WAIT_RELEASE"
export PRO_CLI_WAIT_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"succeeded"}}}'
export PRO_CLI_WAIT_EXIT=75
before_wait_completed=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_WAIT_COMPLETED" submit "$id_wait_completed" >/dev/null || fail "completed-wait fixture submit failed"
pe "$H_WAIT_COMPLETED" reconcile >/dev/null || fail "completed-wait fixture reconcile failed"
wait_for_file "$WAIT_STARTED" || fail "completed-wait fixture wait did not start"
: > "$WAIT_RELEASE"
source_wait_completed="consult-$id_wait_completed"
capture_wait_completed="$H_WAIT_COMPLETED/state/procevent-inbox/$source_wait_completed.1.result"
wait_for_file "$capture_wait_completed" || fail "nonzero completed wait outcome was not captured"
terminal_status=0
pa "$H_WAIT_COMPLETED" terminal "$capture_wait_completed" >/dev/null 2>&1 || terminal_status=$?
[ "$terminal_status" -eq 0 ] || fail "validated completion was not terminal when job wait exited nonzero"
for _ in $(seq 1 100); do
  [ ! -e "$H_WAIT_COMPLETED/state/procevent/$source_wait_completed.source" ] && break
  sleep 0.05
done
assert_absent "$H_WAIT_COMPLETED/state/procevent/$source_wait_completed.source" "validated completion retires its source despite nonzero wait exit"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = $((before_wait_completed + 1)) ] \
  || fail "nonzero completed wait submitted another consultation job"
unset PRO_CLI_WAIT_JSON PRO_CLI_WAIT_EXIT
pass "a validated completed job retires even when the wait process exits nonzero"

H_WAIT_MISMATCH="$TMP_ROOT/home-wait-mismatch"
consult_home "$H_WAIT_MISMATCH"
id_wait_mismatch=$(prepare_id "$H_WAIT_MISMATCH" "$QUESTION_TWO")
rm -f -- "$WAIT_STARTED" "$WAIT_RELEASE"
export PRO_CLI_WAIT_JSON='{"ok":true,"data":{"job":{"id":"job_other","status":"succeeded"}}}'
fc "$H_WAIT_MISMATCH" submit "$id_wait_mismatch" >/dev/null || fail "mismatched-wait fixture submit failed"
pe "$H_WAIT_MISMATCH" reconcile >/dev/null || fail "mismatched-wait fixture reconcile failed"
wait_for_file "$WAIT_STARTED" || fail "mismatched-wait fixture wait did not start"
: > "$WAIT_RELEASE"
source_wait_mismatch="consult-$id_wait_mismatch"
capture_wait_mismatch="$H_WAIT_MISMATCH/state/procevent-inbox/$source_wait_mismatch.1.result"
wait_for_file "$capture_wait_mismatch" || fail "mismatched wait outcome was not captured"
mismatched_terminal_status=0
pa "$H_WAIT_MISMATCH" terminal "$capture_wait_mismatch" >/dev/null 2>&1 || mismatched_terminal_status=$?
[ "$mismatched_terminal_status" -ne 0 ] || fail "a different returned job id was trusted as terminal"
assert_present "$H_WAIT_MISMATCH/state/procevent/$source_wait_mismatch.source" "a mismatched returned job id cannot retire the known job wait"
unset PRO_CLI_WAIT_JSON
pass "job wait status is trusted only for the exact submitted job id"

H_ARM_IDENTITY="$TMP_ROOT/home-arm-identity"
consult_home "$H_ARM_IDENTITY"
id_arm_identity=$(prepare_id "$H_ARM_IDENTITY" "$QUESTION_TWO")
before_arm_identity=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_ARM_IDENTITY" submit "$id_arm_identity" >/dev/null || fail "arm-identity fixture submit failed"
source_arm_identity="consult-$id_arm_identity"
pe "$H_ARM_IDENTITY" retire "$source_arm_identity" >/dev/null || fail "arm-identity fixture registration could not be retired"
mkdir -p "$H_ARM_IDENTITY/state/procevent-inbox"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_other","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' \
  "$id_arm_identity" > "$H_ARM_IDENTITY/state/procevent-inbox/$source_arm_identity.1.result"
printf '{"schema":"fm-consult-wait/1","consult_id":"11111111-1111-1111-1111-111111111111","job_id":"job_fixture","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' \
  > "$H_ARM_IDENTITY/state/procevent-inbox/$source_arm_identity.2.result"
chmod 0600 "$H_ARM_IDENTITY/state/procevent-inbox/$source_arm_identity.1.result" \
  "$H_ARM_IDENTITY/state/procevent-inbox/$source_arm_identity.2.result"
arm_identity_out=$(pa "$H_ARM_IDENTITY" arm "$id_arm_identity") || fail "mismatched captures blocked the exact known-job waiter: $arm_identity_out"
assert_contains "$arm_identity_out" "armed: $id_arm_identity" "arm ignores terminal captures for another consult or job"
assert_present "$H_ARM_IDENTITY/state/procevent/$source_arm_identity.source" "mismatched terminal capture suppressed the exact known-job waiter"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = $((before_arm_identity + 1)) ] || fail "arm identity recovery submitted another job"
pass "arm suppresses waiting only for an exact consult and job capture"

H_ARM_REGISTRATION="$TMP_ROOT/home-arm-registration"
consult_home "$H_ARM_REGISTRATION"
id_arm_registration=$(prepare_id "$H_ARM_REGISTRATION" "$QUESTION_TWO")
fc "$H_ARM_REGISTRATION" submit "$id_arm_registration" >/dev/null || fail "registration-identity fixture submit failed"
source_arm_registration="consult-$id_arm_registration"
pe "$H_ARM_REGISTRATION" retire "$source_arm_registration" >/dev/null || fail "registration-identity fixture could not retire its waiter"
pe "$H_ARM_REGISTRATION" register consult "$source_arm_registration" -- \
  "$ROOT/bin/fm-procevent-consult.sh" wait 11111111-1111-1111-1111-111111111111 >/dev/null \
  || fail "registration-identity fixture could not install the conflicting registration"
registration_before=$(raw_sha256 "$H_ARM_REGISTRATION/state/procevent/$source_arm_registration.source")
arm_registration_status=0
arm_registration_out=$(pa "$H_ARM_REGISTRATION" arm "$id_arm_registration" 2>&1) || arm_registration_status=$?
[ "$arm_registration_status" -ne 0 ] || fail "an unrelated existing registration was mistaken for the consult waiter"
assert_contains "$arm_registration_out" "does not match the requested adapter and argv" "arm rejects a same-name registration with different ownership"
[ "$(raw_sha256 "$H_ARM_REGISTRATION/state/procevent/$source_arm_registration.source")" = "$registration_before" ] \
  || fail "failed arm replaced the unrelated existing registration"
pass "arm accepts only the exact known-job wait registration"

# The first durable request is a pre-delivery checkpoint. Its presence without
# the intent marker means the external call provably has not begun, so resume it
# rather than converting a harmless pre-call crash into delivery ambiguity.
H_RESUME="$TMP_ROOT/home-request-resume"
consult_home "$H_RESUME"
id_resume=$(prepare_id "$H_RESUME" "$QUESTION_TWO")
record_resume="$H_RESUME/data/consults/$id_resume"
write_ready_request "$record_resume" "$id_resume"
request_hash_before=$(shasum -a 256 "$record_resume/request.json" | awk '{print $1}')
before_resume=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
resume_out=$(fc "$H_RESUME" submit "$id_resume") || fail "pre-attempt request checkpoint did not resume submission: $resume_out"
after_resume=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
[ "$after_resume" = $((before_resume + 1)) ] \
  || fail "resumed request checkpoint create count changed from $before_resume to $after_resume: $resume_out"
[ "$request_hash_before" = "$(shasum -a 256 "$record_resume/request.json" | awk '{print $1}')" ] \
  || fail "resumed request checkpoint overwrote immutable request evidence"
assert_grep '"terminal":"SUBMITTED"' "$record_resume/submission.json" "request checkpoint resume records the known submitted job"
pass "a request checkpoint before the attempt marker resumes without ambiguity"

# A recovered request is also the immutable source for the final receipt.
# Missing receipt bindings must therefore stop before the one-shot create call,
# rather than strand a submitted consultation that can never be collected.
for missing_binding in reasoning created_at limits_observed_at; do
  H_REQUEST_BINDING="$TMP_ROOT/home-request-binding-$missing_binding"
  consult_home "$H_REQUEST_BINDING"
  id_request_binding=$(prepare_id "$H_REQUEST_BINDING" "$QUESTION_TWO")
  record_request_binding="$H_REQUEST_BINDING/data/consults/$id_request_binding"
  write_ready_request "$record_request_binding" "$id_request_binding"
  perl -MJSON::PP -e '
    my ($file, $field) = @ARGV;
    my $v = decode_json(do { local $/; open my $fh, "<", $file or die; <$fh> });
    delete $v->{$field};
    open my $out, ">", $file or die;
    print {$out} JSON::PP->new->canonical->encode($v), "\n";
  ' "$record_request_binding/request.json" "$missing_binding"
  before_request_binding=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
  request_binding_status=0
  request_binding_out=$(fc "$H_REQUEST_BINDING" submit "$id_request_binding" 2>&1) || request_binding_status=$?
  [ "$request_binding_status" -ne 0 ] || fail "a recovered request without $missing_binding reached submission"
  assert_contains "$request_binding_out" "durable preflight record could not be classified" \
    "a recovered request without $missing_binding did not fail at its durable boundary"
  [ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_request_binding" ] \
    || fail "a recovered request without $missing_binding created a consultation job"
  assert_absent "$record_request_binding/submission-attempt.json" \
    "a recovered request without $missing_binding crossed the submission marker"
done
pass "recovered requests require every immutable receipt binding before submission"

H_SUBMISSION_INVALID="$TMP_ROOT/home-submission-invalid"
consult_home "$H_SUBMISSION_INVALID"
id_submission_invalid=$(prepare_id "$H_SUBMISSION_INVALID" "$QUESTION_TWO")
record_submission_invalid="$H_SUBMISSION_INVALID/data/consults/$id_submission_invalid"
: > "$record_submission_invalid/submission.json"
chmod 0600 "$record_submission_invalid/submission.json"
before_submission_invalid=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
submission_invalid_status=0
submission_invalid_out=$(fc "$H_SUBMISSION_INVALID" submit "$id_submission_invalid" 2>&1) || submission_invalid_status=$?
[ "$submission_invalid_status" -ne 0 ] || fail "a malformed submission record was trusted or replaced"
assert_contains "$submission_invalid_out" "submission terminal is invalid" "present malformed submission state fails closed"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_submission_invalid" ] || fail "malformed submission state created another job"

H_SUBMISSION_UNMARKED="$TMP_ROOT/home-submission-unmarked"
consult_home "$H_SUBMISSION_UNMARKED"
id_submission_unmarked=$(prepare_id "$H_SUBMISSION_UNMARKED" "$QUESTION_TWO")
record_submission_unmarked="$H_SUBMISSION_UNMARKED/data/consults/$id_submission_unmarked"
printf '{"schema_version":1,"consult_id":"%s","attempted_at":"2026-01-01T00:00:00Z","pro_cli_version":"pro-cli fixture","pro_cli_source_revision":"UNAVAILABLE","job_id":"job_fixture","terminal":"SUBMITTED","error_code":null}\n' \
  "$id_submission_unmarked" > "$record_submission_unmarked/submission.json"
chmod 0600 "$record_submission_unmarked/submission.json"
before_submission_unmarked=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
submission_unmarked_status=0
submission_unmarked_out=$(fc "$H_SUBMISSION_UNMARKED" submit "$id_submission_unmarked" 2>&1) || submission_unmarked_status=$?
[ "$submission_unmarked_status" -ne 0 ] || fail "SUBMITTED without its durable attempt marker was trusted"
assert_contains "$submission_unmarked_out" "submission terminal is invalid" "post-attempt terminal requires its exact marker"
assert_absent "$H_SUBMISSION_UNMARKED/state/procevent/consult-$id_submission_unmarked.source" "unmarked SUBMITTED state armed a waiter"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_submission_unmarked" ] || fail "unmarked SUBMITTED state created another job"
pass "submission recovery rejects malformed and unmarked terminal state"

H_PREFLIGHT_MISMATCH="$TMP_ROOT/home-preflight-mismatch"
consult_home "$H_PREFLIGHT_MISMATCH"
id_preflight_mismatch=$(prepare_id "$H_PREFLIGHT_MISMATCH" "$QUESTION_TWO")
record_preflight_mismatch="$H_PREFLIGHT_MISMATCH/data/consults/$id_preflight_mismatch"
observed_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"schema_version":1,"consult_id":"%s","model":"gpt-5-6-pro","preflight":{"doctor":{"available":true,"ready":true}},"limits_observed":{"available":true,"account":{"planType":"pro"},"observedLimits":[{"featureName":"gpt-5-6-pro","remaining":1,"observedAt":"%s"}]}}\n' \
  "$id_preflight_mismatch" "$observed_now" > "$record_preflight_mismatch/request.json"
printf '{"schema_version":1,"consult_id":"%s","attempted_at":"2026-01-01T00:00:00Z","pro_cli_version":"pro-cli fixture","pro_cli_source_revision":"UNAVAILABLE","job_id":null,"terminal":"AUTH_UNAVAILABLE","error_code":"SESSION_EXPIRED"}\n' \
  "$id_preflight_mismatch" > "$record_preflight_mismatch/submission.json"
chmod 0600 "$record_preflight_mismatch/request.json" "$record_preflight_mismatch/submission.json"
before_preflight_mismatch=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
preflight_mismatch_status=0
preflight_mismatch_out=$(fc "$H_PREFLIGHT_MISMATCH" submit "$id_preflight_mismatch" 2>&1) || preflight_mismatch_status=$?
[ "$preflight_mismatch_status" -ne 0 ] || fail "an unmarked failure terminal overrode a ready preflight"
assert_contains "$preflight_mismatch_out" "submission terminal is invalid" "an unmarked failure terminal must match its preflight evidence"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_preflight_mismatch" ] || fail "invalid preflight terminal created another job"
pass "unmarked failure terminals cannot suppress a ready preflight"

H_POST_AUTH="$TMP_ROOT/home-post-auth"
consult_home "$H_POST_AUTH"
id_post_auth=$(prepare_id "$H_POST_AUTH" "$QUESTION_TWO")
export PRO_CLI_CREATE_JSON='{"ok":false,"error":{"code":"SESSION_EXPIRED"}}'
post_auth_out=$(fc "$H_POST_AUTH" submit "$id_post_auth") || fail "post-attempt auth terminal was not recorded: $post_auth_out"
assert_contains "$post_auth_out" "AUTH_UNAVAILABLE" "structured post-attempt auth failure records its terminal"
post_auth_replay=$(fc "$H_POST_AUTH" submit "$id_post_auth") || fail "marked auth terminal was rejected on replay: $post_auth_replay"
assert_contains "$post_auth_replay" "already-terminal: $id_post_auth AUTH_UNAVAILABLE" "marked auth terminal remains replayable"
id_after_post_auth=$(prepare_id "$H_POST_AUTH" "$QUESTION_TWO")
export PRO_CLI_CREATE_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"queued"}}}'
fc "$H_POST_AUTH" submit "$id_after_post_auth" >/dev/null || fail "valid marked auth terminal wedged the global submission boundary"

H_POST_LIMIT="$TMP_ROOT/home-post-limit"
consult_home "$H_POST_LIMIT"
id_post_limit=$(prepare_id "$H_POST_LIMIT" "$QUESTION_TWO")
export PRO_CLI_CREATE_JSON='{"ok":false,"error":{"code":"RATE_LIMITED"}}'
post_limit_out=$(fc "$H_POST_LIMIT" submit "$id_post_limit") || fail "post-attempt limit terminal was not recorded: $post_limit_out"
assert_contains "$post_limit_out" "LIMIT_REACHED" "structured post-attempt limit failure records its terminal"
post_limit_replay=$(fc "$H_POST_LIMIT" submit "$id_post_limit") || fail "marked limit terminal was rejected on replay: $post_limit_replay"
assert_contains "$post_limit_replay" "already-terminal: $id_post_limit LIMIT_REACHED" "marked limit terminal remains replayable"
id_after_post_limit=$(prepare_id "$H_POST_LIMIT" "$QUESTION_TWO")
export PRO_CLI_CREATE_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"queued"}}}'
fc "$H_POST_LIMIT" submit "$id_after_post_limit" >/dev/null || fail "valid marked limit terminal wedged the global submission boundary"

H_MARKER_MISMATCH="$TMP_ROOT/home-marker-mismatch"
consult_home "$H_MARKER_MISMATCH"
id_marker_mismatch=$(prepare_id "$H_MARKER_MISMATCH" "$QUESTION_TWO")
record_marker_mismatch="$H_MARKER_MISMATCH/data/consults/$id_marker_mismatch"
printf '{"schema_version":1,"consult_id":"%s","attempted_at":"2026-01-01T00:00:00Z","state":"SUBMISSION_ATTEMPTED","retries":0}\n' \
  "$id_marker_mismatch" > "$record_marker_mismatch/submission-attempt.json"
printf '{"schema_version":1,"consult_id":"%s","attempted_at":"2026-01-01T00:00:01Z","pro_cli_version":"pro-cli fixture","pro_cli_source_revision":"UNAVAILABLE","job_id":null,"terminal":"AUTH_UNAVAILABLE","error_code":"SESSION_EXPIRED"}\n' \
  "$id_marker_mismatch" > "$record_marker_mismatch/submission.json"
chmod 0600 "$record_marker_mismatch/submission-attempt.json" "$record_marker_mismatch/submission.json"
before_marker_mismatch=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
marker_mismatch_status=0
marker_mismatch_out=$(fc "$H_MARKER_MISMATCH" submit "$id_marker_mismatch" 2>&1) || marker_mismatch_status=$?
[ "$marker_mismatch_status" -ne 0 ] || fail "post-attempt terminal with a mismatched marker timestamp was trusted"
assert_contains "$marker_mismatch_out" "submission terminal is invalid" "post-attempt terminal remains bound to its exact marker timestamp"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_marker_mismatch" ] || fail "mismatched marker state created another job"
pass "auth and limit terminals validate their preflight or marked origin"

H_RECEIPT_INVALID="$TMP_ROOT/home-receipt-invalid"
consult_home "$H_RECEIPT_INVALID"
id_receipt_invalid=$(prepare_id "$H_RECEIPT_INVALID" "$QUESTION_TWO")
fc "$H_RECEIPT_INVALID" submit "$id_receipt_invalid" >/dev/null || fail "invalid-receipt fixture submit failed"
source_receipt_invalid="consult-$id_receipt_invalid"
record_receipt_invalid="$H_RECEIPT_INVALID/data/consults/$id_receipt_invalid"
registration_receipt_invalid="$H_RECEIPT_INVALID/state/procevent/$source_receipt_invalid.source"
generation_receipt_invalid=$(sed -n 's/^registration_generation=//p' "$registration_receipt_invalid")
mkdir -p "$H_RECEIPT_INVALID/state/procevent-inbox"
capture_receipt_invalid="$H_RECEIPT_INVALID/state/procevent-inbox/$source_receipt_invalid.1.result"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_fixture","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' \
  "$id_receipt_invalid" > "$capture_receipt_invalid"
printf 'consult\n' > "${capture_receipt_invalid%.result}.adapter"
printf 'schema=fm-procevent-capture-generation.v1\nregistration_generation=%s\n' "$generation_receipt_invalid" \
  > "${capture_receipt_invalid%.result}.generation"
chmod 0600 "$capture_receipt_invalid" "${capture_receipt_invalid%.result}.adapter" "${capture_receipt_invalid%.result}.generation"
: > "$record_receipt_invalid/receipt.json"
chmod 0600 "$record_receipt_invalid/receipt.json"
receipt_invalid_status=0
receipt_invalid_out=$(pa "$H_RECEIPT_INVALID" handle "$id_receipt_invalid" 1 "$capture_receipt_invalid" 2>&1) || receipt_invalid_status=$?
[ "$receipt_invalid_status" -ne 0 ] || fail "an invalid receipt acknowledged the captured generation"
assert_contains "$receipt_invalid_out" "receipt is invalid" "invalid receipt state fails closed during collection"
assert_absent "${capture_receipt_invalid%.result}.handled" "invalid receipt state permanently acknowledged the completion"
assert_present "$registration_receipt_invalid" "invalid receipt state retired the known-job registration"
pass "receipt replay validates identity hashes terminal and advisory presence"

H_RESULT_BOUNDARY="$TMP_ROOT/home-result-boundary"
consult_home "$H_RESULT_BOUNDARY"
id_result_boundary=$(prepare_id "$H_RESULT_BOUNDARY" "$QUESTION_TWO")
fc "$H_RESULT_BOUNDARY" submit "$id_result_boundary" >/dev/null || fail "result-boundary fixture submit failed"
record_result_boundary="$H_RESULT_BOUNDARY/data/consults/$id_result_boundary"
capture_result_boundary="$TMP_ROOT/result-boundary-event.json"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_fixture","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' \
  "$id_result_boundary" > "$capture_result_boundary"
chmod 0600 "$capture_result_boundary"
result_boundary_secret="unvalidated-result-$(date +%s)-$$"
PRO_CLI_RESULT_JSON=$(json_result_for "$result_boundary_secret")
export PRO_CLI_STATUS_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"succeeded"}}}'
export PRO_CLI_RESULT_JSON PRO_CLI_RESULT_HOLD=1
rm -f -- "$RESULT_STARTED" "$RESULT_RELEASE"
fc "$H_RESULT_BOUNDARY" collect "$id_result_boundary" "$capture_result_boundary" > "$TMP_ROOT/result-boundary.out" 2>&1 &
result_boundary_pid=$!
wait_for_file "$RESULT_STARTED" || fail "result-boundary collection did not reach raw result capture"
kill -KILL "$result_boundary_pid" 2>/dev/null || fail "result-boundary collection could not be interrupted"
wait "$result_boundary_pid" 2>/dev/null || true
: > "$RESULT_RELEASE"
unset PRO_CLI_RESULT_HOLD PRO_CLI_STATUS_JSON
for stranded_result in "$record_result_boundary"/.result.*; do
  [ ! -e "$stranded_result" ] || fail "unvalidated raw result was stranded inside the immutable consult record"
done
assert_tree_secret_absent "$result_boundary_secret" "$record_result_boundary" \
  "unvalidated advisory bytes entered the immutable consult record"
pass "raw job results remain outside the immutable record until validation"

# A matching registration generation alone cannot make a foreign payload
# terminal. Recovery must bind the envelope to the submitted consult and job
# before it retires the waiter.
H_CAPTURE_MISMATCH="$TMP_ROOT/home-capture-mismatch"
consult_home "$H_CAPTURE_MISMATCH"
id_capture_mismatch=$(prepare_id "$H_CAPTURE_MISMATCH" "$QUESTION_TWO")
fc "$H_CAPTURE_MISMATCH" submit "$id_capture_mismatch" >/dev/null || fail "capture-mismatch fixture submit failed"
source_capture_mismatch="consult-$id_capture_mismatch"
registration_capture_mismatch="$H_CAPTURE_MISMATCH/state/procevent/$source_capture_mismatch.source"
generation_capture_mismatch=$(sed -n 's/^registration_generation=//p' "$registration_capture_mismatch")
mkdir -p "$H_CAPTURE_MISMATCH/state/procevent-inbox"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_other","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' \
  "$id_capture_mismatch" > "$H_CAPTURE_MISMATCH/state/procevent-inbox/$source_capture_mismatch.1.result"
printf 'consult\n' > "$H_CAPTURE_MISMATCH/state/procevent-inbox/$source_capture_mismatch.1.adapter"
printf 'schema=fm-procevent-capture-generation.v1\nregistration_generation=%s\n' \
  "$generation_capture_mismatch" > "$H_CAPTURE_MISMATCH/state/procevent-inbox/$source_capture_mismatch.1.generation"
chmod 0600 "$H_CAPTURE_MISMATCH/state/procevent-inbox/$source_capture_mismatch.1.result" \
  "$H_CAPTURE_MISMATCH/state/procevent-inbox/$source_capture_mismatch.1.adapter" \
  "$H_CAPTURE_MISMATCH/state/procevent-inbox/$source_capture_mismatch.1.generation"
rm -f -- "$WAIT_STARTED" "$WAIT_RELEASE"
capture_mismatch_out=$(pe "$H_CAPTURE_MISMATCH" reconcile) || fail "capture-mismatch reconcile failed: $capture_mismatch_out"
assert_contains "$capture_mismatch_out" "terminal-recovered=0" "foreign payload is not recovered as the known job terminal"
assert_present "$registration_capture_mismatch" "foreign payload retired the matching registration generation"
wait_for_file "$WAIT_STARTED" || fail "foreign payload prevented the known-job waiter from resuming"
pe "$H_CAPTURE_MISMATCH" sweep-home >/dev/null 2>&1 || fail "capture-mismatch fixture cleanup failed"
pass "terminal recovery binds generation and exact consult job identity"

# A captured terminal belongs to its publication generation, not a boot-volatile
# device/inode. Reconcile must retire that exact source before it can start a
# second wait after a runner crash between capture and retirement.
H_CAPTURE_RECOVERY="$TMP_ROOT/home-capture-recovery"
consult_home "$H_CAPTURE_RECOVERY"
id_capture_recovery=$(prepare_id "$H_CAPTURE_RECOVERY" "$QUESTION_TWO")
before_capture_recovery=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_CAPTURE_RECOVERY" submit "$id_capture_recovery" >/dev/null || fail "capture-recovery fixture submit failed"
source_capture_recovery="consult-$id_capture_recovery"
registration_capture_recovery="$H_CAPTURE_RECOVERY/state/procevent/$source_capture_recovery.source"
generation_capture_recovery=$(sed -n 's/^registration_generation=//p' "$registration_capture_recovery")
[ -n "$generation_capture_recovery" ] || fail "capture-recovery registration has no publication generation"
mkdir -p "$H_CAPTURE_RECOVERY/state/procevent-inbox"
printf '{"schema":"fm-consult-wait/1","consult_id":"%s","job_id":"job_fixture","wait_exit":0,"wait_timed_out":false,"job_status":"succeeded","error_code":null}\n' \
  "$id_capture_recovery" > "$H_CAPTURE_RECOVERY/state/procevent-inbox/$source_capture_recovery.1.result"
printf 'consult\n' > "$H_CAPTURE_RECOVERY/state/procevent-inbox/$source_capture_recovery.1.adapter"
printf 'schema=fm-procevent-capture-generation.v1\nregistration_generation=%s\n' \
  "$generation_capture_recovery" > "$H_CAPTURE_RECOVERY/state/procevent-inbox/$source_capture_recovery.1.generation"
chmod 0600 "$H_CAPTURE_RECOVERY/state/procevent-inbox/$source_capture_recovery.1.result" \
  "$H_CAPTURE_RECOVERY/state/procevent-inbox/$source_capture_recovery.1.adapter" \
  "$H_CAPTURE_RECOVERY/state/procevent-inbox/$source_capture_recovery.1.generation"
rm -f -- "$WAIT_STARTED" "$WAIT_RELEASE"
capture_recovery_out=$(pe "$H_CAPTURE_RECOVERY" reconcile) || fail "capture recovery reconcile failed: $capture_recovery_out"
assert_contains "$capture_recovery_out" "terminal-recovered=1" "captured terminal is recovered before new work starts"
assert_absent "$registration_capture_recovery" "captured terminal retirement removes its exact registration"
assert_absent "$WAIT_STARTED" "captured terminal recovery started a second wait"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = $((before_capture_recovery + 1)) ] \
  || fail "captured terminal recovery submitted another consultation job"
pass "captured terminal recovery prevents a second known-job wait after a crash"

H_LIMIT_STALE="$TMP_ROOT/home-limit-stale"
consult_home "$H_LIMIT_STALE"
id_limit_stale=$(prepare_id "$H_LIMIT_STALE" "$QUESTION_TWO")
export PRO_CLI_LIMITS_JSON='{"ok":true,"data":{"account":{"planType":"pro"},"observedLimits":[{"featureName":"gpt-5-6-pro","remaining":1,"resetAfter":null,"observedAt":"2000-01-01T00:00:00Z"}]}}'
before_limit_stale=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_LIMIT_STALE" submit "$id_limit_stale" >/dev/null || fail "stale limits terminal was not recorded"
assert_grep '"terminal":"LIMITS_INDETERMINATE"' "$H_LIMIT_STALE/data/consults/$id_limit_stale/submission.json" "stale selected-model limit observation stops before submission"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_limit_stale" ] \
  || fail "stale selected-model limit observation still created a job"
unset PRO_CLI_LIMITS_JSON
pass "a stale selected-model limit observation is never treated as unlimited"

H_LIMIT="$TMP_ROOT/home-limit"
consult_home "$H_LIMIT"
id_limit=$(prepare_id "$H_LIMIT" "$QUESTION_TWO")
limit_observation=$(printf '{"ok":true,"data":{"account":{"planType":"pro"},"observedLimits":[{"featureName":"gpt-5-6-pro","remaining":0,"resetAfter":null,"observedAt":"%s","jobId":null}]}}' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
export PRO_CLI_LIMITS_JSON="$limit_observation"
before_limit=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_LIMIT" submit "$id_limit" >/dev/null || fail "limit terminal was not recorded"
assert_grep '"terminal":"LIMIT_REACHED"' "$H_LIMIT/data/consults/$id_limit/submission.json" "explicit limits observation stops before submission"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_limit" ] || fail "explicit limits exhaustion still created a job"
limit_replay=$(fc "$H_LIMIT" submit "$id_limit") || fail "unmarked preflight limit terminal was rejected on replay: $limit_replay"
assert_contains "$limit_replay" "already-terminal: $id_limit LIMIT_REACHED" "preflight limit terminal remains valid without an attempt marker"
unset PRO_CLI_LIMITS_JSON
pass "an explicit observed exhaustion fails closed without inferring absent limits"

H4="$TMP_ROOT/home-auth"
consult_home "$H4"
id_four=$(prepare_id "$H4" "$QUESTION_TWO")
export PRO_CLI_DOCTOR_JSON='{"ok":false,"error":{"code":"SESSION_TOKEN_MISSING"}}'
before_auth=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H4" submit "$id_four" >/dev/null || fail "auth-unavailable terminal was not recorded"
assert_grep '"terminal":"AUTH_UNAVAILABLE"' "$H4/data/consults/$id_four/submission.json" "doctor failure stops before submission"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = "$before_auth" ] || fail "auth failure still created a job"
auth_replay=$(fc "$H4" submit "$id_four") || fail "unmarked preflight auth terminal was rejected on replay: $auth_replay"
assert_contains "$auth_replay" "already-terminal: $id_four AUTH_UNAVAILABLE" "preflight auth terminal remains valid without an attempt marker"
pass "auth preflight fails closed before the submission boundary"

H_DEEP="$TMP_ROOT/home-deep-research"
consult_home "$H_DEEP"
deep_status=0
deep_out=$(fc "$H_DEEP" prepare --question "$QUESTION_TWO" --privacy internal-research --model research 2>&1) || deep_status=$?
[ "$deep_status" -ne 0 ] || fail "Deep Research was accepted without its saved-chat authorization path"
assert_contains "$deep_out" "Deep Research is not enabled" "Deep Research is refused at the preparation boundary"
assert_absent "$H_DEEP/data/consults" "refused Deep Research creates no private consultation record"
pass "Deep Research remains explicitly disabled pending saved-chat authorization"

H_MODEL="$TMP_ROOT/home-model-deny"
consult_home "$H_MODEL"
model_status=0
model_out=$(fc "$H_MODEL" prepare --question "$QUESTION_TWO" --privacy internal-research --model gpt-5-5 2>&1) || model_status=$?
[ "$model_status" -ne 0 ] || fail "an unapproved temporary-chat model was accepted"
assert_contains "$model_out" "model is not approved" "model default-deny is enforced at preparation"
assert_absent "$H_MODEL/data/consults" "unapproved model creates no consultation record"
pass "only the explicitly approved temporary-chat model may be prepared"

H_REASONING="$TMP_ROOT/home-reasoning-deny"
consult_home "$H_REASONING"
reasoning_status=0
reasoning_out=$(fc "$H_REASONING" prepare --question "$QUESTION_TWO" --privacy internal-research --reasoning definitely-invalid 2>&1) || reasoning_status=$?
[ "$reasoning_status" -ne 0 ] || fail "an unsupported reasoning level was accepted"
assert_contains "$reasoning_out" "reasoning is not approved" "reasoning default-deny is enforced at preparation"
assert_absent "$H_REASONING/data/consults" "unsupported reasoning creates no consultation record"
pass "unsupported reasoning fails before any consultation side effect"

PE_HOME="$H2"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H3"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H_WAIT_COMPLETED"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H_WAIT_MISMATCH"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H_RESUME"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
