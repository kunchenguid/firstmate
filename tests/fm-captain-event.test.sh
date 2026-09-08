#!/usr/bin/env bash
# Behavioral contract for the optional fm-captain-event.v1 semantic outbox and
# its trusted Pi primary/worker producers.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

OUTBOX="$ROOT/bin/fm-captain-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-event)

new_home() {
  local name=$1 home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

enable_home() {
  printf 'enabled\n' > "$1/config/captain-event-outbox"
}

primary_args() {
  local event_id=$1 summary=$2
  PRIMARY_ARGS=(
    --source main
    --source-role primary
    --incarnation pi-session:test-primary
    --producer pi
    --harness-event-id "$event_id"
    --audience captain
    --kind primary.final
    --summary "$summary"
    --occurred-at-ms 1000
  )
}

worker_args() {
  local event_id=$1 summary=$2
  WORKER_ARGS=(
    --source secondmate:ios
    --source-role worker
    --task soak-worker
    --incarnation s100.2.3
    --producer pi
    --harness-event-id "$event_id"
    --audience captain
    --kind worker.final
    --summary "$summary"
    --occurred-at-ms 1001
  )
}

# An unconfigured home is byte-and-artifact inert, including a home with no
# config directory at all. A malformed opt-in is a loud configuration error.
home=$(new_home disabled)
primary_args pi:disabled ignored
out=$(FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" 2>&1)
status=$?
expect_code 0 "$status" "disabled append"
[ -z "$out" ] || fail "disabled append printed output: $out"
assert_absent "$home/state/captain-events" "disabled append created outbox state"
rm -rf "$home/config"
out=$(FM_HOME="$home" "$OUTBOX" read --after 0 2>&1)
status=$?
expect_code 0 "$status" "missing-config read"
[ -z "$out" ] || fail "missing-config read printed output: $out"
mkdir "$home/config"
printf 'on\n' > "$home/config/captain-event-outbox"
out=$(FM_HOME="$home" "$OUTBOX" validate 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "malformed activation file was accepted"
assert_contains "$out" 'must contain exactly' "malformed activation diagnostic lost its exact contract"
assert_absent "$home/state/captain-events" "malformed activation created outbox state"
rm "$home/config/captain-event-outbox"
printf 'enabled\n' > "$home/config/flag-target"
ln -s flag-target "$home/config/captain-event-outbox"
FM_HOME="$home" "$OUTBOX" validate >/dev/null 2>&1 \
  && fail "symlinked activation file was accepted"
rm "$home/config/captain-event-outbox"
ln "$home/config/flag-target" "$home/config/captain-event-outbox"
FM_HOME="$home" "$OUTBOX" validate >/dev/null 2>&1 \
  && fail "hard-linked activation file was accepted"
assert_absent "$home/state/captain-events" "unsafe activation created outbox state"
pass "unconfigured homes are artifact-free and malformed activation fails closed"

# Sequence allocation, independent reads, exact retry idempotency, conflict
# refusal, private modes, and source/incarnation identity all share one fixture.
home=$(new_home ordered)
enable_home "$home"
primary_args pi:one 'Primary final one'
seq1=$(FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}") || fail "first append failed"
worker_args pi:two 'Worker final two'
seq2=$(FM_HOME="$home" "$OUTBOX" append "${WORKER_ARGS[@]}") || fail "second append failed"
[ "$seq1:$seq2" = "1:2" ] || fail "sequence allocation was not monotonic: $seq1:$seq2"
journal="$home/state/captain-events/events.jsonl"
cp "$journal" "$home/before-retry"
seq2_retry=$(FM_HOME="$home" "$OUTBOX" append "${WORKER_ARGS[@]}") || fail "same-payload retry failed"
[ "$seq2_retry" = 2 ] || fail "same-payload retry did not return original sequence"
cmp -s "$journal" "$home/before-retry" || fail "same-payload retry changed journal bytes"
worker_args pi:two 'Conflicting rewording'
out=$(FM_HOME="$home" "$OUTBOX" append "${WORKER_ARGS[@]}" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "same-identity conflicting payload was accepted"
assert_contains "$out" 'conflicts with its published payload' "payload conflict lacked a precise refusal"
cmp -s "$journal" "$home/before-retry" || fail "payload conflict changed journal bytes"
read_all_1=$(FM_HOME="$home" "$OUTBOX" read --after 0 --limit 10) || fail "first independent read failed"
read_all_2=$(FM_HOME="$home" "$OUTBOX" read --after 0 --limit 10) || fail "second independent read failed"
[ "$read_all_1" = "$read_all_2" ] || fail "independent readers changed source position"
[ "$(printf '%s\n' "$read_all_1" | wc -l | tr -d ' ')" = 2 ] || fail "read --after 0 did not return both rows"
[ "$(FM_HOME="$home" "$OUTBOX" read --after 1 --limit 10 | jq -r .seq)" = 2 ] \
  || fail "read --after 1 did not return only the suffix"
[ "$(FM_HOME="$home" "$OUTBOX" validate)" = 2 ] || fail "validate did not report the exact tail"
mode_root=$(stat -c %a "$home/state/captain-events" 2>/dev/null || stat -f %Lp "$home/state/captain-events")
mode_pending=$(stat -c %a "$home/state/captain-events/pending" 2>/dev/null || stat -f %Lp "$home/state/captain-events/pending")
mode_acks=$(stat -c %a "$home/state/captain-events/acks" 2>/dev/null || stat -f %Lp "$home/state/captain-events/acks")
mode_journal=$(stat -c %a "$journal" 2>/dev/null || stat -f %Lp "$journal")
mode_lock=$(stat -c %a "$home/state/captain-events/.lock" 2>/dev/null || stat -f %Lp "$home/state/captain-events/.lock")
[ "$mode_root:$mode_pending:$mode_acks:$mode_journal:$mode_lock" = "700:700:700:600:600" ] \
  || fail "private outbox paths do not have exact 0700/0600 modes"
jq -e -s '
  length == 2
  and .[0].schema == "fm-captain-event.v1"
  and .[0].source_home == "main"
  and .[0].source_role == "primary"
  and .[0].task_id == null
  and .[0].kind == "primary.final"
  and .[1].source_home == "secondmate:ios"
  and .[1].source_role == "worker"
  and .[1].task_id == "soak-worker"
  and .[1].incarnation == "s100.2.3"
  and .[1].kind == "worker.final"
  and (map(.event_id) | unique | length) == 2
' "$journal" >/dev/null || fail "published source, incarnation, audience, or kind fields are wrong"
[ ! -e "$home/state/captain-events/cursor" ] || fail "source created a consumer cursor"
pass "ordering, immutable retry identity, conflicts, privacy, and independent after reads are strict"

# Bounds and sanitization happen before persistence; only explicitly allowlisted
# structured references survive as active reference fields.
home=$(new_home bounded)
enable_home "$home"
long=$(python3 - <<'PY'
print("🧭" * 700)
PY
)
primary_args pi:bounded "ordinary prose $long"
PRIMARY_ARGS+=(--summary-truncated true --ref pr_url=https://github.com/example/repo/pull/7 --ref report_id=soak-report --ref report_path=data/soak-report/report.md --ref branch_outcome_seq=9)
# Replace the summary argument with a value that exercises normalization and
# the Unicode cap without risking shell byte slicing.
PRIMARY_ARGS[15]=$'\033[31mLine one\033[0m\nLine two \u202e'"ordinary prose $long"
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "bounded append failed"
row=$(FM_HOME="$home" "$OUTBOX" read --after 0)
printf '%s\n' "$row" | jq -e '
  .audience == "captain"
  and .summary_truncated == true
  and (.summary | contains("ordinary prose"))
  and (.refs | keys) == ["branch_outcome_seq","pr_url","report_id","report_path"]
  and .refs.branch_outcome_seq == 9
' >/dev/null || fail "summary sanitization or allowlisted references are wrong"
codepoints=$(printf '%s\n' "$row" | jq -r .summary | python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))')
[ "$codepoints" = 600 ] || fail "bounded summary has $codepoints codepoints, expected 600"
printf '%s\n' "$row" | jq -r .summary | python3 -c '
import sys, unicodedata
summary = sys.stdin.read().rstrip("\n")
assert not any(unicodedata.category(ch).startswith("C") for ch in summary)
' || fail "bounded summary retained a Unicode control or format character"
bytes=$(wc -c < "$home/state/captain-events/events.jsonl" | tr -d ' ')
[ "$bytes" -le 8192 ] || fail "serialized event exceeds 8192 bytes ($bytes)"
# shellcheck disable=SC2016 # Dollar and command-substitution syntax is intentional inert test data and must not expand.
assignment_cases=(
  'token=supersecretvalue visible suffix'
  'escaped_name=private\ escapedvalue visible suffix'
  'quoted_name="private \"quotedvalue\" tail" visible suffix'
  'command_name=$(printf substitutionsecret) visible suffix'
  'nested_name=$(outer $(inner nestedsecret)) visible suffix'
  'SAFE=$( (printf alpha); printf swordfish) visible suffix'
  'unproven_name=$(printf unresolvedsecret trailing suffix'
  'SAFE+=privateappend visible suffix'
  'MiXeD + = privateappend visible suffix'
)
after=1
for assignment_case in "${assignment_cases[@]}"; do
  primary_args "pi:assignment-$after" "Prefix $assignment_case"
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "assignment case $after append failed"
  assignment_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
  printf '%s\n' "$assignment_row" | jq -e '.summary == "Prefix [REDACTED]"' >/dev/null \
    || fail "assignment case $after retained text after its marker"
  after=$((after + 1))
done
authorization_cases=(
  'AuThOrIzAtIoN: Basic dXNlcjpwYXNz visible suffix'
  'pRoXy-AuThOrIzAtIoN: Bearer ordinarybearertoken visible suffix'
  'AUTHORIZATION: Digest username="captain", response="private" visible suffix'
)
for authorization_case in "${authorization_cases[@]}"; do
  primary_args "pi:authorization-$after" "Prefix $authorization_case"
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "authorization case $after append failed"
  authorization_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
  printf '%s\n' "$authorization_row" | jq -e '.summary == "Prefix [REDACTED]"' >/dev/null \
    || fail "authorization case $after retained its credential value"
  after=$((after + 1))
done
credential_label_cases=(
  'AWS Secret Access Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY visible suffix'
  'client_secret: privatevalue visible suffix'
  'deployment-private-key: privatevalue visible suffix'
  'MiXeD-aUtH_ToKeN: privatevalue visible suffix'
  'azure_ad_client_secret: privatevalue visible suffix'
  'platform-prod_service_AcCeSs-kEy: privatevalue visible suffix'
  'one_two-THREE_PaSsPhRaSe: privatevalue visible suffix'
)
for credential_label_case in "${credential_label_cases[@]}"; do
  primary_args "pi:credential-label-$after" "Prefix; $credential_label_case"
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "credential label case $after append failed"
  credential_label_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
  printf '%s\n' "$credential_label_row" | jq -e '.summary == "Prefix; [REDACTED]"' >/dev/null \
    || fail "credential label case $after retained its value or tail"
  after=$((after + 1))
done
quoted_credential_label_cases=(
  '{"client_secret":"privatevalue"} visible suffix'
  '{"MiXeD-aPi-Key":"privatevalue"} visible suffix'
  '{"clientSecret":"privatevalue"} visible suffix'
  '{"clientToken":"privatevalue"} visible suffix'
  '{"accessToken":"privatevalue"} visible suffix'
  '{"accessKey":"privatevalue"} visible suffix'
  '{"secretKey":"privatevalue"} visible suffix'
  '{"apiKey":"privatevalue"} visible suffix'
  '{"privateKey":"privatevalue"} visible suffix'
  '{"authToken":"privatevalue"} visible suffix'
  '{"refreshToken":"privatevalue"} visible suffix'
  '{"AzUrEAdClIeNtSeCrEt":"privatevalue"} visible suffix'
)
for quoted_credential_label_case in "${quoted_credential_label_cases[@]}"; do
  primary_args "pi:quoted-credential-label-$after" "Prefix $quoted_credential_label_case"
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "quoted credential label case $after append failed"
  quoted_credential_label_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
  printf '%s\n' "$quoted_credential_label_row" | jq -e '.summary == "Prefix {[REDACTED]"' >/dev/null \
    || fail "quoted credential label case $after retained its value or tail"
  after=$((after + 1))
done
compact_jwt='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sgnVsbG9uZ3NpZ25hdHVyZQ'
primary_args "pi:compact-jwt-$after" "Prefix $compact_jwt remains"
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "compact JWT append failed"
compact_jwt_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
printf '%s\n' "$compact_jwt_row" | jq -e '.summary == "Prefix [REDACTED] remains"' >/dev/null \
  || fail "compact JWT was not redacted as one token"
after=$((after + 1))
for non_jwt in 'abcdefgh.ijklmnop' 'abcdefgh.ijklmnop.qrstuvwx.yzABCDEF'; do
  primary_args "pi:non-jwt-$after" "Prefix $non_jwt remains"
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "non-JWT dotted text append failed"
  non_jwt_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
  printf '%s\n' "$non_jwt_row" | jq -e --arg summary "Prefix $non_jwt remains" '.summary == $summary' >/dev/null \
    || fail "non-JWT dotted text was treated as a compact JWT"
  after=$((after + 1))
done
primary_args pi:bare-uri 'Prefix postgres://bareuser:barepass@db.example/prod remains'
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "bare URI append failed"
bare_uri_row=$(FM_HOME="$home" "$OUTBOX" read --after "$after" --limit 1)
printf '%s\n' "$bare_uri_row" | jq -e '.summary == "Prefix [REDACTED] remains"' >/dev/null \
  || fail "bare credential-bearing URI was not redacted"
primary_args pi:bad-ref bad
PRIMARY_ARGS+=(--ref terminal=/tmp/raw)
out=$(FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "non-allowlisted reference was accepted"
assert_contains "$out" 'not allowlisted' "reference refusal did not name the allowlist"
primary_args pi:bad-url bad
PRIMARY_ARGS+=(--ref pr_url=http://example.test/7)
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1 \
  && fail "non-https PR reference was accepted"
primary_args pi:gitlab-url safe
PRIMARY_ARGS+=(--ref pr_url=https://gitlab.example.test/team/repo/-/merge_requests/8)
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null \
  || fail "canonical GitLab MR reference was rejected"
for unsafe_url in \
  'https://example.test/pull/7' \
  'https://user:password@example.test/pull/7' \
  'https://github.com/example/repo/pull/7?access_token=supersecretvalue' \
  'https://github.com/example/repo/pull/7#access_token=supersecretvalue' \
  'https://github.com/example/repo/pull/7/access_token/supersecretvalue' \
  'https://github.com/example/repo/pull/7/access_token=supersecretvalue' \
  'https://github.com/example/repo/pull/7/access_token%3Dsupersecretvalue' \
  'https://github.com/example/repo/pull/7?' \
  'https://github.com/example/repo/pull/7#'; do
  primary_args "pi:unsafe-url-$RANDOM" bad
  PRIMARY_ARGS+=(--ref "pr_url=$unsafe_url")
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1 \
    && fail "credential-bearing PR reference was accepted: $unsafe_url"
done
primary_args pi:wrong-kind bad
PRIMARY_ARGS[13]=worker.final
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1 \
  && fail "kind/source-role mismatch was accepted"
primary_args pi:wrong-audience bad
PRIMARY_ARGS[11]=user
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1 \
  && fail "unknown audience was accepted or defaulted to captain"
pass "summaries are inert, Unicode-bounded, redacted, size-capped, and references are allowlisted"

# The P0 spool ceiling is a hard refusal, not an implicit prune. Build the
# bounded fixture directly so testing the limit does not require quadratic
# journal replacement through ten thousand individual appends.
home=$(new_home hard-cap)
enable_home "$home"
FM_HOME="$home" "$OUTBOX" validate >/dev/null
python3 - "$home/state/captain-events/events.jsonl" <<'PY'
import hashlib
import json
import os
import sys

canonical = lambda value: json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as stream:
    for seq in range(1, 10001):
        identity = {
            "schema": "fm-captain-event.v1", "source_home": "main", "source_role": "primary",
            "task_id": None, "incarnation": "cap", "producer": "test", "harness_event_id": f"cap:{seq}",
        }
        event = {
            **identity, "seq": seq, "event_id": "sha256:" + hashlib.sha256(canonical(identity).encode()).hexdigest(),
            "published_at_ms": 1, "occurred_at_ms": None, "audience": "captain", "kind": "primary.final",
            "summary": "bounded", "summary_truncated": False, "refs": {},
        }
        stream.write(canonical(event) + "\n")
os.chmod(sys.argv[1], 0o600)
PY
[ "$(FM_HOME="$home" "$OUTBOX" validate)" = 10000 ] || fail "hard-cap fixture did not validate at exactly 10000 events"
primary_args pi:cap-overflow overflow
out=$(FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "an append beyond the hard event cap succeeded"
assert_contains "$out" 'hard 10000-event P0 bound' "hard-cap refusal was not explicit"
pass "the 10000-event P0 ceiling refuses without pruning source bytes"

# The consumer receipt is an ingestion acknowledgement, not a read cursor: it
# binds the exact sequence/id, advances monotonically, and leaves source bytes.
home=$(new_home acknowledgements)
enable_home "$home"
primary_args pi:ack-1 one
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null
primary_args pi:ack-2 two
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null
id1=$(sed -n '1p' "$home/state/captain-events/events.jsonl" | jq -r .event_id)
id2=$(sed -n '2p' "$home/state/captain-events/events.jsonl" | jq -r .event_id)
cp "$home/state/captain-events/events.jsonl" "$home/before-ack"
[ "$(FM_HOME="$home" "$OUTBOX" ack --consumer magistrate --through 1 --event-id "$id1")" = 1 ] \
  || fail "first consumer acknowledgement failed"
[ "$(FM_HOME="$home" "$OUTBOX" ack --consumer magistrate --through 2 --event-id "$id2")" = 2 ] \
  || fail "consumer acknowledgement did not advance"
FM_HOME="$home" "$OUTBOX" ack --consumer magistrate --through 1 --event-id "$id1" >/dev/null 2>&1 \
  && fail "consumer acknowledgement moved backwards"
FM_HOME="$home" "$OUTBOX" ack --consumer other --through 2 --event-id "$id1" >/dev/null 2>&1 \
  && fail "consumer acknowledgement accepted the wrong event id"
cmp -s "$home/before-ack" "$home/state/captain-events/events.jsonl" \
  || fail "consumer acknowledgement rewrote source events"
[ "$(FM_HOME="$home" "$OUTBOX" read --after 0 | wc -l | tr -d ' ')" = 2 ] \
  || fail "consumer acknowledgement advanced the independent read source"
[ "$(stat -c %a "$home/state/captain-events/acks/magistrate.json" 2>/dev/null || stat -f %Lp "$home/state/captain-events/acks/magistrate.json")" = 600 ] \
  || fail "consumer acknowledgement is not private"
pass "durable ingestion acknowledgements are exact, monotonic, private, and independent of reads"

# Interrupted publication is recoverable on both sides of the journal rename.
# Non-destructive readers refuse rather than skipping a pending final result.
home=$(new_home crash-before)
enable_home "$home"
primary_args pi:crash-before pending
FM_CAPTAIN_EVENT_TEST_CRASH=after-pending FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1
status=$?
expect_code 97 "$status" "after-pending crash injection"
assert_absent "$home/state/captain-events/events.jsonl" "pre-rename crash published a journal"
FM_HOME="$home" "$OUTBOX" read --after 0 >/dev/null 2>&1 \
  && fail "reader skipped an owed pending publication"
[ "$(FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}")" = 1 ] \
  || fail "same-event retry did not recover pending publication"
[ "$(FM_HOME="$home" "$OUTBOX" validate)" = 1 ] || fail "recovered pre-rename journal is invalid"
[ -z "$(find "$home/state/captain-events/pending" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || fail "pre-rename recovery left a pending record"

home=$(new_home crash-after)
enable_home "$home"
primary_args pi:crash-after committed
FM_CAPTAIN_EVENT_TEST_CRASH=after-replace FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1
status=$?
expect_code 98 "$status" "after-replace crash injection"
[ "$(wc -l < "$home/state/captain-events/events.jsonl" | tr -d ' ')" = 1 ] \
  || fail "post-rename crash did not leave the committed journal"
[ "$(FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}")" = 1 ] \
  || fail "post-rename retry did not reconcile idempotently"
[ "$(wc -l < "$home/state/captain-events/events.jsonl" | tr -d ' ')" = 1 ] \
  || fail "post-rename retry duplicated the event"
pass "pending publication recovers across both atomic-rename crash windows"

# Each corruption shape blocks validation, reads, and appends without salvage.
make_corrupt_case() {
  local name=$1 home
  home=$(new_home "$name")
  enable_home "$home"
  primary_args "pi:$name-1" one
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "$name seed 1 failed"
  primary_args "pi:$name-2" two
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null || fail "$name seed 2 failed"
  printf '%s\n' "$home"
}

for shape in empty gap duplicate reorder torn unterminated crlf bare-cr vertical-tab form-feed unicode-line unicode-paragraph; do
  home=$(make_corrupt_case "corrupt-$shape")
  journal="$home/state/captain-events/events.jsonl"
  case "$shape" in
    empty) : > "$journal" ;;
    gap) jq -c 'if .seq == 2 then .seq = 3 else . end' "$journal" > "$home/bad" && mv "$home/bad" "$journal" ;;
    duplicate) sed -n '1p' "$journal" > "$home/duplicate-row" && cat "$home/duplicate-row" >> "$journal" ;;
    reorder) { sed -n '2p' "$journal"; sed -n '1p' "$journal"; } > "$home/bad" && mv "$home/bad" "$journal" ;;
    torn) printf '{"schema":"fm-captain-event.v1"' >> "$journal" ;;
    unterminated) python3 - "$journal" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes()[:-1])
PY
      ;;
    crlf|bare-cr|vertical-tab|form-feed|unicode-line|unicode-paragraph)
      python3 - "$journal" "$shape" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
first, second, empty = path.read_bytes().split(b"\n")
assert empty == b""
separators = {
    "crlf": b"\r\n",
    "bare-cr": b"\r",
    "vertical-tab": b"\v",
    "form-feed": b"\f",
    "unicode-line": "\u2028".encode(),
    "unicode-paragraph": "\u2029".encode(),
}
path.write_bytes(first + separators[sys.argv[2]] + second + b"\n")
PY
      ;;
  esac
  chmod 0600 "$journal"
  cp "$journal" "$home/corrupt-bytes"
  FM_HOME="$home" "$OUTBOX" validate >/dev/null 2>&1 && fail "$shape corruption passed validate"
  FM_HOME="$home" "$OUTBOX" read --after 0 >/dev/null 2>&1 && fail "$shape corruption passed read"
  primary_args "pi:$shape-new" new
  FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null 2>&1 && fail "$shape corruption passed append"
  cmp -s "$journal" "$home/corrupt-bytes" || fail "$shape refusal changed corrupt journal bytes"
done
home=$(new_home ahead)
enable_home "$home"
primary_args pi:ahead one
FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null
FM_HOME="$home" "$OUTBOX" read --after 2 >/dev/null 2>&1 \
  && fail "reader cursor ahead of tail was accepted"
pass "gaps, duplicates, reorder, torn tails, and cursor-ahead reads all fail closed"

# Multiple independent producer processes serialize through the same lock and
# leave exactly one gap-free sequence regardless of scheduler order.
home=$(new_home concurrent)
enable_home "$home"
pids=()
i=1
while [ "$i" -le 12 ]; do
  (
    primary_args "pi:concurrent-$i" "event $i"
    FM_HOME="$home" "$OUTBOX" append "${PRIMARY_ARGS[@]}" >/dev/null
  ) &
  pids+=("$!")
  i=$((i + 1))
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "concurrent producer $pid failed"
done
[ "$(FM_HOME="$home" "$OUTBOX" validate)" = 12 ] || fail "concurrent tail is not 12"
jq -e -s 'length == 12 and ([.[].seq] == [range(1; 13)]) and (map(.event_id) | unique | length) == 12' \
  "$home/state/captain-events/events.jsonl" >/dev/null \
  || fail "concurrent publication left a gap, duplicate, or reorder"
pass "concurrent primary/worker producers retain one monotonic gap-free order"

# Exercise the actual shared Pi producer against a fake semantic turn boundary.
# It must select visible text blocks only, classify stop vs toolUse explicitly,
# use persisted entry identity, and remain inert without the activation file.
if command -v node >/dev/null 2>&1 && node --experimental-strip-types -e '' >/dev/null 2>&1; then
  home=$(new_home pi-presanitizer)
  enable_home "$home"
  fake_root="$TMP_ROOT/pi-presanitizer-root"
  capture="$TMP_ROOT/pi-presanitizer.args"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-captain-event.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1-}" = append ] || exit 0
shift
while [ "$#" -gt 0 ]; do
  if [ "$1" = --summary ]; then
    printf '%s\n' "$2" >> "$FM_CAPTURE"
    exit 0
  fi
  shift
done
exit 1
SH
  chmod +x "$fake_root/bin/fm-captain-event.sh"
  REPO_ROOT="$ROOT" FIXTURE_HOME="$home" FIXTURE_ROOT="$fake_root" FM_CAPTURE="$capture" \
    NODE_NO_WARNINGS=1 node --experimental-strip-types --input-type=module <<'JS' \
    || fail "Pi producer pre-sanitizer fixture failed"
import { pathToFileURL } from "node:url";
const { installCaptainEventPublisher } = await import(pathToFileURL(`${process.env.REPO_ROOT}/.pi/extensions/lib/fm-captain-event.ts`).href);
const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); } };
installCaptainEventPublisher(pi, {
  fmHome: process.env.FIXTURE_HOME,
  fmRoot: process.env.FIXTURE_ROOT,
  state: `${process.env.FIXTURE_HOME}/state`,
  config: `${process.env.FIXTURE_HOME}/config`,
  sourceRole: "primary",
});
async function emit(text, id) {
  const message = { role: "assistant", content: [{ type: "text", text }], stopReason: "stop", timestamp: 1 };
  const context = { sessionManager: { getSessionId: () => "pre", getEntries: () => [{ id, type: "message", message }] } };
  for (const handler of handlers.get("turn_end") ?? []) await handler({ message }, context);
}
await emit("Ordinary prose postgres://bareuser:barepass@db.example/prod remains SaFe += privateappend visible suffix", "environment");
await emit("Prefix AuThOrIzAtIoN: Basic dXNlcjpwYXNz visible suffix", "basic");
await emit("Prefix pRoXy-AuThOrIzAtIoN: Bearer ordinarybearertoken visible suffix", "bearer");
await emit('Prefix AUTHORIZATION: Digest username="captain", response="private" visible suffix', "digest");
await emit("Prefix; AWS Secret Access Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY visible suffix", "aws-secret-access-key");
await emit("Prefix; client_secret: privatevalue visible suffix", "client-secret");
await emit("Prefix; deployment-private-key: privatevalue visible suffix", "private-key");
await emit("Prefix; MiXeD-aUtH_ToKeN: privatevalue visible suffix", "mixed-auth-token");
await emit("Prefix; azure_ad_client_secret: privatevalue visible suffix", "azure-client-secret");
await emit("Prefix; platform-prod_service_AcCeSs-kEy: privatevalue visible suffix", "mixed-access-key");
await emit("Prefix; one_two-THREE_PaSsPhRaSe: privatevalue visible suffix", "mixed-passphrase");
await emit('Prefix {"client_secret":"privatevalue"} visible suffix', "quoted-client-secret");
await emit('Prefix {"MiXeD-aPi-Key":"privatevalue"} visible suffix', "quoted-api-key");
for (const label of [
  "clientSecret", "clientToken", "accessToken", "accessKey", "secretKey",
  "apiKey", "privateKey", "authToken", "refreshToken", "AzUrEAdClIeNtSeCrEt",
]) await emit(`Prefix {"${label}":"privatevalue"} visible suffix`, `quoted-${label}`);
await emit("Prefix eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sgnVsbG9uZ3NpZ25hdHVyZQ remains", "compact-jwt");
await emit("Prefix abcdefgh.ijklmnop remains", "two-segment-dotted-text");
await emit("Prefix abcdefgh.ijklmnop.qrstuvwx.yzABCDEF remains", "four-segment-dotted-text");
JS
  python3 - "$capture" <<'PY' || fail "Pi producer pre-sanitizer retained credential material"
import sys

summaries = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert summaries == [
    "Ordinary prose [REDACTED] remains [REDACTED]",
    "Prefix [REDACTED]",
    "Prefix [REDACTED]",
    "Prefix [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix; [REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix {[REDACTED]",
    "Prefix [REDACTED] remains",
    "Prefix abcdefgh.ijklmnop remains",
    "Prefix abcdefgh.ijklmnop.qrstuvwx.yzABCDEF remains",
], summaries
PY

  home=$(new_home pi-producer-disabled)
  REPO_ROOT="$ROOT" FIXTURE_HOME="$home" NODE_NO_WARNINGS=1 node --experimental-strip-types --input-type=module <<'JS' \
    || fail "disabled Pi producer fixture failed"
import { pathToFileURL } from "node:url";
const { installCaptainEventPublisher } = await import(pathToFileURL(`${process.env.REPO_ROOT}/.pi/extensions/lib/fm-captain-event.ts`).href);
const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); } };
installCaptainEventPublisher(pi, {
  fmHome: process.env.FIXTURE_HOME,
  fmRoot: process.env.REPO_ROOT,
  state: `${process.env.FIXTURE_HOME}/state`,
  config: `${process.env.FIXTURE_HOME}/config`,
  sourceRole: "primary",
});
const message = { role: "assistant", content: [{ type: "text", text: "not published" }], stopReason: "stop", timestamp: 1 };
const context = { sessionManager: { getSessionId: () => "disabled", getEntries: () => [{ id: "e", type: "message", message }] } };
for (const handler of handlers.get("session_start") ?? []) await handler({}, context);
for (const handler of handlers.get("turn_end") ?? []) await handler({ message }, context);
JS
  assert_absent "$home/state/captain-events" "disabled Pi producer created outbox state"

  home=$(new_home pi-producer)
  enable_home "$home"
  printf 'ios\n' > "$home/.fm-secondmate-home"
  REPO_ROOT="$ROOT" FIXTURE_HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" NODE_NO_WARNINGS=1 \
    node --experimental-strip-types --input-type=module <<'JS' \
    || fail "enabled Pi producer fixture failed"
import { pathToFileURL } from "node:url";
const { installCaptainEventPublisher } = await import(pathToFileURL(`${process.env.REPO_ROOT}/.pi/extensions/lib/fm-captain-event.ts`).href);
const primaryExtension = await import(`${pathToFileURL(`${process.env.REPO_ROOT}/.pi/extensions/fm-captain-event.ts`).href}?fixture=${Date.now()}`);
const makePi = () => {
  const handlers = new Map();
  return {
    handlers,
    pi: { on(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); } },
  };
};
const primaryPi = makePi();
const workerPi = makePi();
primaryExtension.default(primaryPi.pi);
installCaptainEventPublisher(workerPi.pi, {
  fmHome: process.env.FIXTURE_HOME,
  fmRoot: process.env.REPO_ROOT,
  state: `${process.env.FIXTURE_HOME}/state`,
  config: `${process.env.FIXTURE_HOME}/config`,
  sourceRole: "worker",
  taskId: "worker-one",
  incarnation: "s1.2.3",
});
const entries = [];
const context = { sessionManager: { getSessionId: () => "session-secret-id", getEntries: () => entries } };
for (const target of [primaryPi, workerPi]) {
  for (const handler of target.handlers.get("session_start") ?? []) await handler({}, context);
}
const primary = {
  role: "assistant",
  content: [
    { type: "thinking", thinking: "PRIVATE_REASONING" },
    { type: "text", text: "Captain result token=verysecretvalue" },
    { type: "toolCall", name: "bash", arguments: { value: "PRIVATE_TOOL_ARG" } },
  ],
  stopReason: "stop",
  timestamp: 101,
  responseId: "provider-secret-id",
};
entries.push({ id: "persisted-primary-entry", type: "message", message: primary });
for (const handler of primaryPi.handlers.get("turn_end") ?? []) await handler({ message: primary }, context);
// Re-delivering the same semantic boundary must be an immutable no-op.
for (const handler of primaryPi.handlers.get("turn_end") ?? []) await handler({ message: primary }, context);
const worker = {
  role: "assistant",
  content: [{ type: "text", text: "Worker progress" }, { type: "toolCall", name: "read", arguments: { path: "/private" } }],
  stopReason: "toolUse",
  timestamp: 102,
};
entries.push({ id: "persisted-worker-entry", type: "message", message: worker });
for (const handler of workerPi.handlers.get("turn_end") ?? []) await handler({ message: worker }, context);
JS
  journal="$home/state/captain-events/events.jsonl"
  jq -e -s '
    length == 2
    and .[0].kind == "primary.final"
    and .[0].source_home == "secondmate:ios"
    and .[0].source_role == "primary"
    and .[0].summary == "Captain result [REDACTED]"
    and .[1].kind == "worker.message"
    and .[1].source_home == "secondmate:ios"
    and .[1].source_role == "worker"
    and .[1].task_id == "worker-one"
    and .[1].incarnation == "s1.2.3"
    and (tostring | contains("PRIVATE_REASONING") | not)
    and (tostring | contains("PRIVATE_TOOL_ARG") | not)
    and (tostring | contains("provider-secret-id") | not)
    and (tostring | contains("session-secret-id") | not)
  ' "$journal" >/dev/null || fail "Pi semantic producer leaked private blocks/ids or misclassified its turns"
  pass "the tracked Pi primary call site publishes typed turns without exposing trusted ids to the model"
else
  echo "skip: node with TypeScript stripping unavailable for Pi producer behavior"
fi

# Drive the extension generated by the real spawn path rather than inspecting
# its source. The resulting row must bind to the exact spawn_gen in task
# metadata while preserving the pre-existing turn-end notification behavior.
if command -v node >/dev/null 2>&1 && node --experimental-strip-types -e '' >/dev/null 2>&1; then
  case_dir="$TMP_ROOT/generated-worker"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  task=event-worker
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" pi
  enable_home "$home"
  fm_git_worktree "$project" "$worktree" generated-worker
  fm_test_spawn_brief "$home" "$task"
  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" "$task" "$project" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "Pi worker spawn should succeed: $out"
  extension="$home/state/$task.pi-ext.ts"
  mkdir -p "$worktree/.pi/extensions/lib"
  cp "$ROOT/.pi/extensions/fm-captain-event.ts" "$worktree/.pi/extensions/fm-captain-event.ts"
  cp "$ROOT/.pi/extensions/lib/fm-captain-event.ts" "$worktree/.pi/extensions/lib/fm-captain-event.ts"
  spawn_gen=$(awk -F= '$1 == "spawn_gen" { print $2 }' "$home/state/$task.meta")
  rm -f "$home/state/$task.turn-ended"
  EXTENSION="$extension" TRACKED_EXTENSION="$worktree/.pi/extensions/fm-captain-event.ts" \
    FM_HOME="$home" FM_TASK_ID="$task" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    NODE_NO_WARNINGS=1 node --experimental-strip-types --input-type=module <<'JS' \
    || fail "generated Pi worker extension did not execute"
import { pathToFileURL } from "node:url";
const primaryHandlers = new Map();
const workerHandlers = new Map();
const primaryPi = { on(name, handler) { primaryHandlers.set(name, [...(primaryHandlers.get(name) ?? []), handler]); } };
const workerPi = { on(name, handler) { workerHandlers.set(name, [...(workerHandlers.get(name) ?? []), handler]); } };
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?fixture=${Date.now()}`);
const primaryExtension = await import(`${pathToFileURL(process.env.TRACKED_EXTENSION).href}?fixture=${Date.now()}`);
primaryExtension.default(primaryPi);
extension.default(workerPi);
const message = { role: "assistant", content: [{ type: "text", text: "Generated worker final" }], stopReason: "stop", timestamp: 303 };
const context = {
  isIdle: () => true,
  sessionManager: {
    getSessionId: () => "generated-worker-session",
    getEntries: () => [{ id: "generated-worker-entry", type: "message", message }],
  },
};
for (const handlers of [primaryHandlers, workerHandlers]) {
  for (const handler of handlers.get("turn_end") ?? []) await handler({ message }, context);
}
await new Promise((resolve) => setTimeout(resolve, 200));
JS
  assert_present "$home/state/$task.turn-ended" "semantic producer displaced the worker turn-end notification"
  jq -e -s --arg task "$task" --arg spawn_gen "$spawn_gen" '
    length == 1
    and .[0].source_home == "main"
    and .[0].source_role == "worker"
    and .[0].task_id == $task
    and .[0].incarnation == $spawn_gen
    and .[0].kind == "worker.final"
    and .[0].summary == "Generated worker final"
  ' "$home/state/captain-events/events.jsonl" >/dev/null \
    || fail "spawn-generated Pi producer duplicated primary typing or lost task spawn_gen"
  pass "the real spawn path generates a Pi producer bound to worker spawn_gen"
else
  echo "skip: node with TypeScript stripping unavailable for generated Pi worker behavior"
fi

printf '# fm-captain-event.test.sh: all assertions passed\n'
