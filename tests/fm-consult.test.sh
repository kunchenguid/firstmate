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
mkdir -p "$FAKE_BIN" "$FAKE_STATE"
export FAKE_STATE WAIT_STARTED WAIT_RELEASE

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

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

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

handle_status=0
handle_out=$(pa "$H1" handle "$id_one" 1 "$capture_one") || handle_status=$?
[ "$handle_status" -eq 0 ] || fail "completion handling failed: $handle_out argv=$(<"$FAKE_STATE/argv.log")"
assert_contains "$handle_out" "handled: $source_one 1" "receipt completion acknowledges exactly the captured generation"
assert_grep "$answer_secret" "$record_one/advisory.md" "matching job result is written once to advisory"
[ "$(mode_of "$record_one/advisory.md")" = 600 ] || fail "advisory is not 0600"
assert_not_contains "$(<"$record_one/receipt.json")" "$answer_secret" "receipt contains answer hash rather than answer bytes"
assert_grep '"result_terminal":"ADVISORY_RECORDED"' "$record_one/receipt.json" "receipt records a durable advisory terminal"
replay_out=$(pa "$H1" handle "$id_one" 1 "$capture_one") || fail "completion replay failed: $replay_out"
assert_contains "$replay_out" "already-handled: $source_one 1" "replay does not authorize a second handling effect"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = 1 ] || fail "completion replay created another pro-cli job"
pass "a known job completes through the process-event runner without blocking submission"

if rg -F -- "$question_secret" "$ROOT" >/dev/null || rg -F -- "$answer_secret" "$ROOT" >/dev/null; then
  fail "private consultation content reached tracked repository files"
fi
if rg -F -- "$answer_secret" "$H1/state" >/dev/null || rg -F -- "$credential_secret" "$H1/data" >/dev/null; then
  fail "answer or credentials escaped their private boundary"
fi
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
fc "$H2" reconcile-ambiguous "$id_two" --human-record captain-record-42 >/dev/null || fail "explicit reconciliation was rejected"
[ "$(mode_of "$H2/data/consults/$id_two/reconciliation.json")" = 600 ] || fail "reconciliation record is not 0600"
export PRO_CLI_CREATE_JSON='{"ok":true,"data":{"job":{"id":"job_fixture","status":"queued"}}}'
fc "$H2" submit "$id_two_next" >/dev/null || fail "reconciled different consult did not submit"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = $((before_ambiguous + 1)) ] || fail "reconciled submit count is wrong"
pass "delivery ambiguity forbids automatic retries and blocks a different consult until explicit reconciliation"

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

# A transport failure from `job wait` is evidence to inspect, not proof that a
# known job is terminal. The source must remain armed; a later event may safely
# reconcile status/result but must never create a second consultation job.
H_WAIT_FAILURE="$TMP_ROOT/home-wait-failure"
consult_home "$H_WAIT_FAILURE"
id_wait_failure=$(prepare_id "$H_WAIT_FAILURE" "$QUESTION_TWO")
rm -f -- "$WAIT_STARTED" "$WAIT_RELEASE"
export PRO_CLI_WAIT_JSON='{"ok":false,"error":{"code":"STREAM_INTERRUPTED"}}'
export PRO_CLI_WAIT_EXIT=75
before_wait_failure=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_WAIT_FAILURE" submit "$id_wait_failure" >/dev/null || fail "wait-failure fixture submit failed"
pe "$H_WAIT_FAILURE" reconcile >/dev/null || fail "wait-failure fixture reconcile failed"
wait_for_file "$WAIT_STARTED" || fail "wait-failure fixture wait did not start"
: > "$WAIT_RELEASE"
source_wait_failure="consult-$id_wait_failure"
capture_wait_failure="$H_WAIT_FAILURE/state/procevent-inbox/$source_wait_failure.1.result"
wait_for_file "$capture_wait_failure" || fail "nonzero wait outcome was not captured"
terminal_status=0
pa "$H_WAIT_FAILURE" terminal "$capture_wait_failure" >/dev/null 2>&1 || terminal_status=$?
[ "$terminal_status" -ne 0 ] || fail "nonzero wait outcome was misclassified as terminal"
assert_present "$H_WAIT_FAILURE/state/procevent/$source_wait_failure.source" "nonzero wait outcome must leave its source armed"
[ "$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')" = $((before_wait_failure + 1)) ] \
  || fail "nonzero wait outcome submitted another consultation job"
unset PRO_CLI_WAIT_JSON PRO_CLI_WAIT_EXIT
pass "a nonzero job wait result never retires or resubmits a consultation"

# The first durable request is a pre-delivery checkpoint. Its presence without
# the intent marker means the external call provably has not begun, so resume it
# rather than converting a harmless pre-call crash into delivery ambiguity.
H_RESUME="$TMP_ROOT/home-request-resume"
consult_home "$H_RESUME"
id_resume=$(prepare_id "$H_RESUME" "$QUESTION_TWO")
record_resume="$H_RESUME/data/consults/$id_resume"
prepared_model=$(perl -MJSON::PP -e 'my $v = decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }); print $v->{model}' "$record_resume/prepared.json")
observed_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"schema_version":1,"preflight":{"doctor":{"available":true,"ready":true}},"limits_observed":{"available":true,"account":{"planType":"pro"},"observedLimits":[{"featureName":"%s","remaining":1,"observedAt":"%s"}]}}\n' \
  "$prepared_model" "$observed_now" > "$record_resume/request.json"
chmod 0600 "$record_resume/request.json"
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

# A captured terminal belongs to its registration bytes, not a boot-volatile
# device/inode. Reconcile must retire that exact source before it can start a
# second wait after a runner crash between capture and retirement.
H_CAPTURE_RECOVERY="$TMP_ROOT/home-capture-recovery"
consult_home "$H_CAPTURE_RECOVERY"
id_capture_recovery=$(prepare_id "$H_CAPTURE_RECOVERY" "$QUESTION_TWO")
before_capture_recovery=$(wc -l < "$FAKE_STATE/create-count" | tr -d ' ')
fc "$H_CAPTURE_RECOVERY" submit "$id_capture_recovery" >/dev/null || fail "capture-recovery fixture submit failed"
source_capture_recovery="consult-$id_capture_recovery"
registration_capture_recovery="$H_CAPTURE_RECOVERY/state/procevent/$source_capture_recovery.source"
generation_capture_recovery="sha256:$(shasum -a 256 "$registration_capture_recovery" | awk '{print $1}')"
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

PE_HOME="$H2"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H3"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H_WAIT_FAILURE"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
PE_HOME="$H_RESUME"
FM_HOME="$PE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
