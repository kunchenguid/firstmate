#!/usr/bin/env bash
# Behavior tests for bin/fm-landing-claim.sh and the done: landing-proof field
# grammar it reads through bin/fm-classify-lib.sh (docs/landing-proof.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-landing-claim)
CLAIM="$ROOT/bin/fm-landing-claim.sh"

field() {  # <parse-output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

test_parse_extracts_all_four_fields() {
  local out status
  out=$("$CLAIM" parse "done: approvals written to core kind: data proof: ssh -o BatchMode=yes root@h \"sqlite3 /db 'select  count(*) from applied'\" expect: ^[1-9] told: grep -c 1794867516.095079 /l/ledger.log told-expect: ^[1-9][0-9]* lesson: drains write core") ; status=$?
  expect_code 0 "$status" "parse of a complete customer-facing claim should succeed ($out)"
  [ "$(field "$out" claim)" = "approvals written to core" ] || fail "claim text wrong: $out"
  [ "$(field "$out" kind)" = data ] || fail "kind wrong: $out"
  [ "$(field "$out" proof)" = "ssh -o BatchMode=yes root@h \"sqlite3 /db 'select  count(*) from applied'\"" ] \
    || fail "proof command lost its inner quoting or spacing: $out"
  [ "$(field "$out" expect)" = '^[1-9]' ] || fail "expect regex wrong: $out"
  [ "$(field "$out" told)" = "grep -c 1794867516.095079 /l/ledger.log" ] || fail "told command wrong: $out"
  [ "$(field "$out" told_expect)" = '^[1-9][0-9]*' ] || fail "told-expect regex wrong: $out"
  [ "$(field "$out" customer_facing)" = y ] || fail "a told: clause must mark the claim customer-facing: $out"
  [ "$(field "$out" lesson)" = "drains write core" ] || fail "lesson clause must be split off, not swallowed: $out"
  pass "fm-landing-claim.sh parse: claim, proof, expect, told, told-expect, and lesson are extracted"
}

test_parse_order_keys_and_inference() {
  local out
  out=$("$CLAIM" parse '2026-11-17T02:09Z done [key=ship]: PR https://github.com/o/r/pull/12 checks green expect: ^MERGED$ proof: gh pr view https://github.com/o/r/pull/12 --json state --jq .state') \
    || fail "timestamped, keyed, reordered claim should parse: $out"
  [ "$(field "$out" claim)" = "PR https://github.com/o/r/pull/12 checks green" ] || fail "claim wrong: $out"
  [ "$(field "$out" kind)" = pr ] || fail "a PR-URL claim without kind: must infer pr: $out"
  [ "$(field "$out" proof)" = "gh pr view https://github.com/o/r/pull/12 --json state --jq .state" ] || fail "proof wrong: $out"
  [ "$(field "$out" expect)" = '^MERGED$' ] || fail "expect wrong: $out"
  [ "$(field "$out" customer_facing)" = n ] || fail "no told: means not customer-facing: $out"
  out=$("$CLAIM" parse 'done: ready in branch fm/x proof: git --git-dir=/r/.git cat-file -t abc expect: ^commit$') \
    || fail "ready-in-branch claim should parse: $out"
  [ "$(field "$out" kind)" = branch ] || fail "ready in branch must infer kind branch: $out"
  # told-expect is its own label, never read as a second expect: clause.
  out=$("$CLAIM" parse 'done: x proof: a expect: b told: c told-expect: d') || fail "told-expect must not collide with expect: $out"
  [ "$(field "$out" expect)" = b ] && [ "$(field "$out" told_expect)" = d ] || fail "expect/told-expect mixed up: $out"
  pass "fm-landing-claim.sh parse: any clause order, keyed/timestamped lines, and kind inference"
}

test_unproven_and_malformed_are_refused() {
  local out status
  out=$("$CLAIM" parse 'done: shipped it, trust me'); status=$?
  expect_code 3 "$status" "a done: without proof: must be unproven"
  case "$out" in UNPROVEN:*"back to in progress"*) ;; *) fail "unproven output wrong: $out" ;; esac
  for line in 'done: x proof: echo a' 'done: x expect: ^a' 'done: x proof: a expect: b told: c' \
    'done: x proof: a expect: b told-expect: c' 'done: x proof: a expect: b proof: c' 'done: x proof:  expect: b' \
    'done: x kind: vibes proof: a expect: b' 'done: x told: c told-expect: d'; do
    out=$("$CLAIM" parse "$line"); status=$?
    expect_code 4 "$status" "malformed claim must be refused: $line ($out)"
    case "$out" in MALFORMED:*) ;; *) fail "malformed output wrong for '$line': $out" ;; esac
  done
  pass "fm-landing-claim.sh parse: unproven and malformed claims are refused with distinct codes"
}

test_append_writes_one_police_row() {
  local claims out status rows
  claims="$TMP_ROOT/claims.tsv"
  out=$(FM_LANDING_CLAIMS="$claims" "$CLAIM" append --epoch 1794867120 asset-fix-a1 \
    'done: hero copy live kind: asset proof: curl -fsS https://example.test/ expect: New hero told: grep -c msg-1 /l/ledger.log told-expect: ^[1-9]'); status=$?
  expect_code 0 "$status" "append of a well-formed claim should succeed ($out)"
  [ "$(head -n 1 "$claims")" = $'# task\tclaimed_epoch\tkind\tcustomer_facing\tclaim\tproof_cmd\texpect_regex\ttold_cmd\ttold_regex' ] \
    || fail "a new claims file must start with the column header"
  rows=$(grep -vc '^#' "$claims")
  [ "$rows" -eq 1 ] || fail "expected one claims row, got $rows"
  # Read it back the way the landing checker reads it.
  IFS=$'\t' read -r task epoch kind cf claim proof expect told toldre < <(grep -v '^#' "$claims")
  [ "$task|$epoch|$kind|$cf|$claim" = "asset-fix-a1|1794867120|asset|y|hero copy live" ] || fail "row identity wrong: $task|$epoch|$kind|$cf|$claim"
  [ "$proof|$expect|$told|$toldre" = "curl -fsS https://example.test/|New hero|grep -c msg-1 /l/ledger.log|^[1-9]" ] \
    || fail "row proof fields wrong: $proof|$expect|$told|$toldre"
  out=$(FM_LANDING_CLAIMS="$claims" "$CLAIM" append --epoch 1794869999 asset-fix-a1 \
    'done: hero copy live kind: asset proof: curl -fsS https://example.test/ expect: New hero told: grep -c msg-1 /l/ledger.log told-expect: ^[1-9]'); status=$?
  expect_code 0 "$status" "a replayed claim is not an error"
  case "$out" in unchanged:*) ;; *) fail "replayed claim should report unchanged: $out" ;; esac
  [ "$(grep -vc '^#' "$claims")" -eq 1 ] || fail "a replayed claim must not append a second row"
  out=$(FM_LANDING_CLAIMS="$claims" "$CLAIM" append no-proof-a2 'done: all good'); status=$?
  expect_code 3 "$status" "append of an unproven claim must refuse"
  [ "$(grep -vc '^#' "$claims")" -eq 1 ] || fail "an unproven claim must not be recorded"
  out=$(FM_LANDING_CLAIMS="$claims" "$CLAIM" append wrong-verb-a3 'working: proof: a expect: b' 2>/dev/null); status=$?
  expect_code 2 "$status" "append of a non-done: line must refuse"
  out=$(FM_LANDING_CLAIMS="$claims" "$CLAIM" append '../evil' 'done: x proof: a expect: b' 2>/dev/null); status=$?
  expect_code 2 "$status" "append must refuse a task id that is not a plain slug"
  pass "fm-landing-claim.sh append: one checker-readable row, replay-safe, unproven and non-done refused"
}

test_from_status_uses_newest_done_line() {
  local home out status
  home="$TMP_ROOT/home"
  mkdir -p "$home/state" "$home/data"
  {
    echo 'done: first cut kind: branch proof: echo old expect: ^old$'
    echo 'working: validating'
    echo 'done: PR https://github.com/o/r/pull/7 proof: gh pr view 7 --json state --jq .state expect: ^MERGED$ lesson: x'
    echo 'note: unrelated'
  } > "$home/state/task-b1.status"
  out=$(FM_HOME="$home" "$CLAIM" from-status --epoch 1794870000 task-b1); status=$?
  expect_code 0 "$status" "from-status should record the newest done: claim ($out)"
  assert_present "$home/data/landing-police/claims.tsv" "from-status must default to the home's landing-police claims file"
  grep -qxF $'task-b1\t1794870000\tpr\tn\tPR https://github.com/o/r/pull/7\tgh pr view 7 --json state --jq .state\t^MERGED$\t\t' \
    "$home/data/landing-police/claims.tsv" || fail "from-status recorded the wrong done: line"
  echo 'done: follow-up with no proof' >> "$home/state/task-b1.status"
  out=$(FM_HOME="$home" "$CLAIM" from-status task-b1); status=$?
  expect_code 3 "$status" "a newest done: without proof must be reported unproven"
  out=$(FM_HOME="$home" "$CLAIM" from-status missing-c1 2>/dev/null); status=$?
  expect_code 2 "$status" "from-status on a task with no status log must refuse"
  pass "fm-landing-claim.sh from-status: the newest done: line is the claim recorded"
}

test_parse_extracts_all_four_fields
test_parse_order_keys_and_inference
test_unproven_and_malformed_are_refused
test_append_writes_one_police_row
test_from_status_uses_newest_done_line
