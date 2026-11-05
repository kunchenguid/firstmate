#!/usr/bin/env bash
# Behavioral contract for Droid's AFK AskUser deferral guard, the owner-bearing
# question binding it requires, and the existing decision and return owners it
# files through.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-droid-afk-askuser-check.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"
RETURN="$ROOT/bin/fm-afk-return.sh"
TMP_ROOT=$(fm_test_tmproot fm-droid-afk-approval)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A primary home with a real backlog, so questions reach the genuine captain-hold
# and status-decision owners rather than a test double of them.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/bin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '# fixture\n' > "$home/AGENTS.md"
  git -C "$home" init -q
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

seed_task() {  # <home> <id> [status-line...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=synthetic:$id" "kind=ship"
  : > "$home/state/$id.status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.status"; done
}

ask() {  # <home> <questionnaire>; stdout/stderr land in <home>/out and <home>/err
  local home=$1 questionnaire=$2 rc=0
  : > "$home/out"
  : > "$home/err"
  jq -n --arg q "$questionnaire" \
    '{hook_event_name:"PreToolUse",tool_name:"AskUser",tool_input:{questionnaire:$q}}' \
    | PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$CHECK" > "$home/out" 2> "$home/err" || rc=$?
  return "$rc"
}

holds() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$HOLD" "$@"
}

run_return() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$RETURN" 2>&1
}

deny_message() {  # <home>
  jq -r '.systemMessage' "$1/err"
}

assert_denied() {  # <rc> <home> <label>
  local rc=$1 home=$2 label=$3
  [ "$rc" -eq 2 ] || fail "$label must be denied with exit 2, got $rc"
  [ ! -s "$home/out" ] || fail "$label wrote stdout: $(cat "$home/out")"
  jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse" and
    .hookSpecificOutput.permissionDecision == "deny" and
    (.systemMessage | contains("denied, not answered")) and
    (.systemMessage | contains("continue every independently authorized action")) and
    (.systemMessage | contains("operationally prefixed input is not the captain returning")) and
    (.systemMessage | contains("grants no additional approval"))
  ' "$home/err" >/dev/null || fail "$label lost its timing or authority contract: $(cat "$home/err")"
}

# The reported defect: an approval question asked interactively during away mode.
# The question must instead be denied and filed with the owner its binding names,
# while unrelated authorized progress continues untouched.
test_existing_status_owner_receives_the_deferred_question() {
  local home rc=0 folded
  home=$(make_home status-owner)
  seed_task "$home" review \
    'needs-decision [key=helper-versions]: restrict helper equality to MAS or keep paused' \
    'working: independently authorized review evidence continues'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[topic] Descriptive helper topic that names no owner
[option] Approve
[option] Keep paused' || rc=$?
  assert_denied "$rc" "$home" "an away-mode approval question"
  assert_contains "$(deny_message "$home")" 'question 1 status review/helper-versions' \
    'the deferred question was not filed with its bound status owner'

  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  folded=$(status_open_decisions "$home/state/review.status")
  [ "$(printf '%s\n' "$folded" | grep -c '^helper-versions	')" -eq 1 ] \
    || fail "the bound decision must stay exactly one open identity: $folded"
  assert_contains "$(cat "$home/state/review.status")" 'working: independently authorized review evidence continues' \
    'deferral discarded unrelated authorized progress'
  assert_not_contains "$(cat "$home/state/review.status")" 'resolved [key=' \
    'deferral automatically approved a decision'
  pass "an away-mode approval question is denied and filed with the status owner its binding names"
}

# A descriptive topic must never become an owner, and independently authorized
# work after the denial must not evict the unanswered question.
test_repeat_notifications_and_authorized_progress_keep_one_identity() {
  local home rc=0 before after folded
  home=$(make_home repeat-durability)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  local q='1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve
[option] Keep paused'

  ask "$home" "$q" || rc=$?
  [ "$rc" -eq 2 ] || fail "the first away-mode attempt must be denied"
  before=$(cksum < "$home/state/review.status")

  # A fresh guard process with the same disk state is all a restarted or compacted
  # session can recover from, so an exact replay must change nothing.
  rc=0
  ask "$home" "$q" || rc=$?
  [ "$rc" -eq 2 ] || fail "a repeated away-mode notification must still deny AskUser"
  after=$(cksum < "$home/state/review.status")
  [ "$before" = "$after" ] || fail "an exact replay rewrote the durable decision owner"

  printf 'working: authorized follow-up landed while the captain was away\n' >> "$home/state/review.status"
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  folded=$(status_open_decisions "$home/state/review.status")
  assert_contains "$folded" 'helper-versions	needs-decision' \
    'authorized progress after the denial erased the unanswered question'
  pass "repeat notifications are idempotent and authorized progress never evicts the deferred question"
}

# One decision identity, several attempted wordings: every attempt survives.
test_reworded_attempt_is_kept_as_another_variant() {
  local home rc=0 variants
  home=$(make_home variants)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve' || rc=$?
  rc=0
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds only?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the reworded attempt must still be denied"

  variants=$(holds "$home" open-questions \
    | awk -F '\t' '$1 == "chunk" { print $2 "/" $3 }' | sort -u | wc -l | tr -d ' ')
  [ "$variants" -eq 2 ] || fail "both attempted wordings must survive as variants, saw $variants"
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  [ "$(status_open_decisions "$home/state/review.status" | grep -c '^helper-versions	')" -eq 1 ] \
    || fail "two variants must remain one unresolved decision identity"
  pass "a reworded attempt is retained as another variant of one decision identity"
}

test_identical_questions_are_preserved_for_each_status_key() {
  local home rc=0 listing
  home=$(make_home identical-status-evidence)
  seed_task "$home" review \
    'needs-decision [key=first-choice]: choose the first policy' \
    'needs-decision [key=second-choice]: choose the second policy'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Apply the shared policy?
[firstmate-decision origin=review key=first-choice state=existing]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the first identical question must be denied"
  rc=0
  ask "$home" '1. [question] Apply the shared policy?
[firstmate-decision origin=review key=second-choice state=existing]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the second identical question must be denied"

  listing=$(holds "$home" open-questions --render)
  assert_contains "$listing" '[key=first-choice] owner=status' \
    'the first key lost its identical deferred question'
  assert_contains "$listing" '[key=second-choice] owner=status' \
    'the second key lost its identical deferred question'
  [ "$(printf '%s\n' "$listing" | grep -Fxc '1. [question] Apply the shared policy?')" -eq 2 ] \
    || fail "identical question evidence was not preserved once for each decision key"
  pass "identical status-owned questions retain evidence under each decision key"
}

test_status_evidence_uses_the_authoritative_transition_key() {
  local home rc=0 records alpha_item beta_item actual
  home=$(make_home status-key-association)
  seed_task "$home" review \
    'needs-decision [key=alpha]: choose alpha' \
    'needs-decision [key=beta]: choose beta'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Should beta preserve literal [key=alpha]: text?
[firstmate-decision origin=review key=beta state=existing]
[option] Yes' || rc=$?
  [ "$rc" -eq 2 ] || fail "the key-association question must be denied"

  records=$(holds "$home" open-questions)
  alpha_item=$(printf '%s\n' "$records" | awk -F '\t' '$1 == "decision" && $4 == "alpha" { print $2 }')
  beta_item=$(printf '%s\n' "$records" | awk -F '\t' '$1 == "decision" && $4 == "beta" { print $2 }')
  [ -n "$alpha_item" ] && [ -n "$beta_item" ] || fail "both status decisions must remain projected"
  [ "$(printf '%s\n' "$records" | awk -F '\t' -v it="$alpha_item" '$1 == "chunk" && $2 == it { n++ } END { print n + 0 }')" -eq 0 ] \
    || fail "beta question evidence was incorrectly projected under alpha"
  actual=$(printf '%s\n' "$records" \
    | awk -F '\t' -v it="$beta_item" '$1 == "chunk" && $2 == it { printf "%s", $6 }' \
    | base64 --decode)
  assert_contains "$actual" 'literal [key=alpha]: text' \
    'beta lost its question text containing another key token'
  pass "status evidence is projected only under its authoritative transition key"
}

# An unseeded review or merge question has no prior record, so it becomes an
# ordinary captain hold under its real origin - never a synthetic ledger.
test_unseeded_binding_creates_an_ordinary_captain_hold() {
  local home rc=0 id show
  home=$(make_home unseeded)
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Merge PR 123 after its required checks are green?
[firstmate-decision origin=release key=merge-pr-123 state=unseeded]
[option] Approve merge
[option] Do not merge' || rc=$?
  assert_denied "$rc" "$home" "an unseeded merge approval question"

  id=release-decision-merge-pr-123
  show=$( (cd "$home" && tasks-axi show "$id" --full) ) || fail "no captain hold was created for the unseeded question"
  assert_contains "$show" 'kind: captain' "the unseeded question did not become a captain decision"
  assert_contains "$show" 'held: yes' "the created captain decision is not actively held"
  assert_absent "$home/state/droid-afk-approval.status" "a synthetic question ledger was created"
  assert_absent "$home/state/$id.meta" "a dummy task metadata surrogate was created"
  pass "an unseeded binding creates an ordinary captain hold under its real origin"
}

# The R4 defect: once `complete` transfers a key to its hold, the status fold no
# longer matches it. Reopening status there would let fm-send close a duplicate
# and leave the authoritative hold unanswered forever.
test_transferred_hold_wins_and_status_is_never_reopened() {
  local home rc=0 status_text
  home=$(make_home transferred)
  seed_task "$home" review 'needs-decision [key=route-choice]: north or south'
  holds "$home" hold review route-choice --title 'Choose the route' --reason 'captain decision pending' >/dev/null \
    || fail "could not seed the captain hold"
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Route north or south?
[firstmate-decision origin=review key=route-choice state=existing]
[option] North
[option] South' || rc=$?
  assert_denied "$rc" "$home" "a question whose decision already moved to a captain hold"
  assert_contains "$(deny_message "$home")" 'question 1 hold review-decision-route-choice' \
    'the transferred decision was not filed with its captain hold'

  status_text=$(cat "$home/state/review.status")
  assert_contains "$status_text" 'captain-held [key=route-choice]: tracked by review-decision-route-choice' \
    'the interrupted status-to-hold transfer was not finished'
  [ "$(printf '%s\n' "$status_text" | grep -c '^needs-decision \[key=route-choice\]')" -eq 1 ] \
    || fail "status was reopened for a key its captain hold already owns: $status_text"
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  [ -z "$(status_open_decisions "$home/state/review.status")" ] \
    || fail "a duplicate status decision survives beside the authoritative hold"
  pass "an active captain hold wins and the status ledger is never reopened behind it"
}

test_status_question_moves_to_hold_before_transfer_closes() {
  local home rc=0 listing
  home=$(make_home transfer-evidence)
  seed_task "$home" review 'needs-decision [key=route-choice]: north or south'
  date +%s > "$home/state/.afk"

  ask "$home" '1. [question] Route north or south?
[firstmate-decision origin=review key=route-choice state=existing]
[option] North
[option] South' || rc=$?
  [ "$rc" -eq 2 ] || fail "the status-owned question must be denied"
  holds "$home" hold review route-choice --title 'Choose the route' --reason 'captain decision pending' >/dev/null \
    || fail "could not seed the captain hold"
  holds "$home" complete review route-choice >/dev/null \
    || fail "could not transfer the status decision to its hold"

  listing=$(holds "$home" open-questions --render)
  assert_contains "$listing" '[key=route-choice] owner=hold' \
    'the transferred decision did not become hold-owned'
  assert_contains "$listing" '1. [question] Route north or south?' \
    'the status-owned question disappeared during transfer'
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-classify-lib.sh"
  [ -z "$(status_open_decisions "$home/state/review.status")" ] \
    || fail "the status decision stayed open after its evidence reached the hold"
  pass "status question evidence reaches the hold before transfer closes its key"
}

test_open_questions_reports_incomplete_hold_enumeration() {
  local home out rc=0
  home=$(make_home incomplete-hold-enumeration)

  out=$(PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=0 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$HOLD" open-questions --render 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "open-questions reported success without enumerating captain holds"
  assert_contains "$out" 'compatible tasks-axi is unavailable; captain-decision holds were not read' \
    'incomplete hold enumeration did not report its missing owner surface'
  pass "open-questions reports incomplete captain-hold enumeration"
}

test_open_questions_reports_unsafe_status_owners() {
  local home out rc=0
  home=$(make_home unsafe-status-enumeration)
  seed_task "$home" review 'needs-decision [key=choice]: choose safely'
  ln -s review.status "$home/state/unsafe.status"

  out=$(holds "$home" open-questions --render 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "open-questions reported success while a symlinked status owner was skipped"
  assert_contains "$out" 'status owner unsafe could not be read safely' \
    'the unsafe status owner was omitted without a limitation'

  rm -f "$home/state/unsafe.status"
  : > "$home/state/unreadable.status"
  chmod 000 "$home/state/unreadable.status"
  rc=0
  out=$(holds "$home" open-questions --render 2>&1) || rc=$?
  chmod 600 "$home/state/unreadable.status"
  [ "$rc" -ne 0 ] || fail "open-questions reported success while an unreadable status owner was skipped"
  assert_contains "$out" 'status owner unreadable could not be read safely' \
    'the unreadable status owner was omitted without a limitation'
  pass "unsafe and unreadable status owners make question projection incomplete"
}

# Ownership must come from the caller. Anything less is rejected loudly rather
# than guessed from a topic, the question text, or the session.
test_unbound_and_malformed_questions_are_rejected_without_mutation() {
  local home rc=0 before
  home=$(make_home rejection)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  before=$(cksum < "$home/state/review.status")

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[topic] Descriptive topic that is not an owner
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question with no owner binding"
  assert_contains "$(deny_message "$home")" 'CONTRACT VIOLATION, not filed' \
    'an unbound question was not rejected explicitly'
  assert_contains "$(deny_message "$home")" 'has no [firstmate-decision origin=' \
    'the rejection did not name the missing requirement'

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision key=malformed-route state=existing]
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question whose binding omits its origin"
  assert_contains "$(deny_message "$home")" 'has no valid origin=' \
    'the malformed binding rejection did not name the missing origin'

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision origin=review origin=release key=helper-versions state=existing]
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question whose binding repeats its origin"
  assert_contains "$(deny_message "$home")" 'require exactly one origin=' \
    'the repeated-field rejection did not name the strict binding requirement'
  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "a repeated binding field mutated the durable decision owner"

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision origin=review key=helper-versions state=existing extra=token]
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question whose binding carries an extra token"
  assert_contains "$(deny_message "$home")" 'with no extra tokens' \
    'the extra-token rejection did not name the strict binding requirement'
  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "an extra binding token mutated the durable decision owner"

  rc=0
  ask "$home" '1. [question] Keep the fixture parked?
[firstmate-decision origin=review key=helper-versions state=existing]
[firstmate-decision origin=review key=helper-versions state=existing] trailing
[option] Keep parked' || rc=$?
  assert_denied "$rc" "$home" "a question with one valid and one malformed binding candidate"
  assert_contains "$(deny_message "$home")" 'multiple [firstmate-decision] candidate lines' \
    'the malformed second binding candidate was not counted'
  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "a malformed second binding candidate mutated the durable decision owner"

  rc=0
  ask "$home" '1. [question] Stale binding?
[firstmate-decision origin=review key=never-seeded state=existing]
[option] Yes' || rc=$?
  assert_denied "$rc" "$home" "a binding claiming an owner that does not exist"
  assert_contains "$(deny_message "$home")" 'OWNER FAULT, not filed' \
    'a stale existing binding was not surfaced as an owner fault'

  [ "$before" = "$(cksum < "$home/state/review.status")" ] \
    || fail "a rejected question mutated the durable decision owner"
  [ "$( (cd "$home" && tasks-axi list --state held --kind captain) | grep -c '^  ' || true)" -eq 0 ] \
    || fail "a rejected question invented a captain hold"
  pass "unbound, malformed, and stale bindings are rejected loudly and mutate nothing"
}

# Framing text before the first numbered question is not itself a question, so it
# must not be rejected for carrying no binding or shift the question ordinals.
test_leading_preamble_is_not_mistaken_for_a_question() {
  local home rc=0
  home=$(make_home preamble)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  ask "$home" 'Here is some framing text before the questions.
1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve' || rc=$?
  assert_denied "$rc" "$home" "a questionnaire with leading preamble"
  assert_not_contains "$(deny_message "$home")" 'CONTRACT VIOLATION' \
    'leading preamble was mistaken for a question with no binding'
  assert_contains "$(deny_message "$home")" 'question 1 status review/helper-versions' \
    'preamble shifted the question ordinal away from its owner'
  pass "leading preamble is not mistaken for an unbound question"
}

# One questionnaire, two origins: the first block must not capture the second.
test_multi_origin_questionnaire_reaches_each_owner() {
  local home rc=0 message
  home=$(make_home multi-origin)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[topic] Descriptive helper topic
[option] Approve
2. [question] Merge PR 123 after its required checks are green?
[firstmate-decision origin=release key=derive state=unseeded]
[option] Approve merge
[option] Do not merge' || rc=$?
  assert_denied "$rc" "$home" "a two-origin questionnaire"
  message=$(deny_message "$home")
  assert_contains "$message" 'question 1 status review/helper-versions' \
    'the status-owned block did not reach its own owner'
  assert_contains "$message" 'question 2 hold release-decision-droid-askuser-' \
    'the unseeded block did not reach its own origin'
  pass "each block of a multi-origin questionnaire reaches its own bound owner"
}

# The captain must get every deferred question back, byte for byte, at return.
test_return_presents_every_question_losslessly() {
  local home rc=0 listing long expected actual item
  home=$(make_home return-listing)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  long=$(awk 'BEGIN { for (i = 0; i < 120; i++) printf "long café segment %d ", i }')
  ask "$home" "1. [question] Limit helper-version equality checks to MAS builds for café α → β 🚀?
[firstmate-decision origin=review key=helper-versions state=existing]
[topic] Descriptive café topic
[option] Approve
[option] Keep paused
2. [question] $long
[firstmate-decision origin=release key=long-question state=unseeded]
[option] Approve" || rc=$?
  [ "$rc" -eq 2 ] || fail "the away-mode attempt must be denied before the return case"

  # Every chunk of every variant reassembles to the exact stored question.
  item=$(holds "$home" open-questions | awk -F '\t' '$1 == "decision" && $4 == "long-question" { print $2 }')
  [ -n "$item" ] || fail "the long question is missing from the outstanding-question projection"
  actual=$(holds "$home" open-questions \
    | awk -F '\t' -v it="$item" '$1 == "chunk" && $2 == it { printf "%s", $6 }' \
    | base64 --decode)
  expected=$(printf '2. [question] %s\n[option] Approve' "$long")
  [ "$actual" = "$expected" ] || fail "a chunked question did not reassemble to its stored bytes"
  holds "$home" open-questions \
    | awk -F '\t' -v it="$item" '$1 == "chunk" && $2 == it { if (length($6) > 800) bad = 1 } END { exit bad ? 1 : 0 }' \
    || fail "a return chunk exceeded the 800-character bound"

  listing=$(run_return "$home") || fail "the away-mode return catch-up failed"
  assert_contains "$listing" 'outstanding decision' 'return catch-up presented no outstanding decision'
  assert_contains "$listing" 'café α → β 🚀' 'return catch-up lost the Unicode question text'
  assert_contains "$listing" '[key=helper-versions] owner=status' \
    'return catch-up omitted the status-owned question'
  assert_contains "$listing" '[key=long-question] owner=hold' \
    'return catch-up omitted the hold-owned question'
  assert_contains "$listing" 'long café segment 119' 'return catch-up truncated a long question'
  assert_not_contains "$listing" '[firstmate-decision origin=' \
    'return catch-up showed the transport binding line to the captain'
  pass "return catch-up presents every deferred question, including Unicode and over-long ones, without omission"
}

# Returning must restore native questioning without answering anything, and the
# guard must stay inert for linked workers throughout.
test_return_restores_askuser_without_approving_anything() {
  local home rc=0 child
  home=$(make_home return-restores)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve
[option] Keep paused' || rc=$?
  [ "$rc" -eq 2 ] || fail "the away-mode attempt must be denied"

  run_return "$home" >/dev/null || fail "the away-mode return catch-up failed"
  assert_absent "$home/state/.afk" "the return did not clear away mode"

  rc=0
  ask "$home" '1. [question] Anything at all?
[option] Yes' || rc=$?
  [ "$rc" -eq 0 ] || fail "AskUser must be available after the return, got exit $rc"
  [ ! -s "$home/out" ] && [ ! -s "$home/err" ] || fail "the post-return allow wrote output"

  assert_not_contains "$(cat "$home/state/review.status")" 'resolved [key=' \
    'the return automatically resolved a deferred decision'
  assert_contains "$( (cd "$home" && tasks-axi show review-decision-helper-versions --full) 2>&1 || true)" \
    'not found' 'the deferral closed or invented a hold for a status-owned decision'

  fm_git_identity "$home"
  git -C "$home" add AGENTS.md
  git -C "$home" commit -qm fixture
  child="$TMP_ROOT/linked-child"
  git -C "$home" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/state" "$child/fakebin"
  printf '# fixture\n' > "$child/AGENTS.md"
  date +%s > "$child/state/.afk"
  rc=0
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"AskUser","tool_input":{"questionnaire":"1. [question] anything?"}}' \
    | FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
      "$CHECK" > "$child/out" 2> "$child/err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the guard must stay inert in a linked task worktree, got exit $rc"
  [ ! -s "$child/out" ] && [ ! -s "$child/err" ] || fail "the linked-worktree no-op wrote output"
  pass "a real return restores AskUser, approves nothing, and leaves linked workers untouched"
}

test_oversized_question_is_parked_and_returned_losslessly() {
  local home rc=0 large expected records item actual line_max evidence_file
  home=$(make_home oversized-question)
  seed_task "$home" review 'needs-decision [key=oversized]: inspect the complete request'
  date +%s > "$home/state/.afk"
  large=$(awk 'BEGIN { for (i = 0; i < 900; i++) printf "oversized café segment %d ", i }')

  ask "$home" "1. [question] $large
[firstmate-decision origin=review key=oversized state=existing]
[option] Preserve every byte" || rc=$?
  [ "$rc" -eq 2 ] || fail "the oversized away-mode question must be denied and parked"
  assert_not_contains "$(deny_message "$home")" 'OWNER FAULT' \
    'the oversized owner-bound question was rejected instead of parked'

  line_max=$(LC_ALL=C awk '{ if (length > max) max = length } END { print max + 0 }' "$home/state/review.status")
  [ "$line_max" -le 512 ] || fail "the status owner stored an unbounded question line ($line_max bytes)"
  set -- "$home/data/review"/droid-afk-question-*
  [ "$#" -eq 1 ] && [ -f "$1" ] || fail "the oversized question was not parked in one durable per-origin file"
  evidence_file=$1
  [ "$(LC_ALL=C wc -c < "$evidence_file" | tr -d ' ')" -gt 8192 ] \
    || fail "the parked oversized evidence did not retain more than 8192 bytes"

  records=$(holds "$home" open-questions)
  item=$(printf '%s\n' "$records" | awk -F '\t' '$1 == "decision" && $4 == "oversized" { print $2 }')
  [ -n "$item" ] || fail "the oversized question is missing from the public projection"
  actual=$(printf '%s\n' "$records" \
    | awk -F '\t' -v it="$item" '$1 == "chunk" && $2 == it { printf "%s", $6 }' \
    | base64 --decode)
  expected=$(printf '1. [question] %s\n[option] Preserve every byte' "$large")
  [ "$actual" = "$expected" ] || fail "the parked oversized question did not round-trip losslessly"
  pass "oversized questions use bounded owner references and return losslessly"
}

test_non_droid_return_does_not_project_deferred_questions() {
  local home out
  home=$(make_home non-droid-return)
  seed_task "$home" review 'working: ordinary non-Droid work'
  holds "$home" hold review ordinary-choice --title 'Ordinary captain choice' \
    --reason 'captain decision pending' >/dev/null || fail "could not seed an ordinary captain hold"
  date +%s > "$home/state/.afk"

  out=$(FM_TASKS_AXI_COMPATIBLE=0 run_return "$home") \
    || fail "a non-Droid return was gated by the Droid question projection: $out"
  assert_not_contains "$out" 'outstanding decisions limitation' \
    'a non-Droid return received the Droid projection limitation'
  assert_not_contains "$out" 'Ordinary captain choice' \
    'a non-Droid return received the Droid deferred-question listing'
  [ ! -e "$home/state/.afk-return-catchup" ] \
    || fail "a non-Droid return stayed gated on Droid-only owner enumeration"
  pass "non-Droid return behavior is unchanged by Droid question deferral"
}

test_derived_keys_close_and_invalid_answer_records_fail_loudly() {
  local home rc=0 records key out show
  home=$(make_home derived-answer)
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Ship after checks pass?
[firstmate-decision origin=release key=derive state=unseeded]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the derived-key question must be denied and filed"

  records=$(holds "$home" open-questions)
  key=$(printf '%s\n' "$records" | awk -F '\t' '$1 == "decision" && $4 ~ /^droid-askuser-/ { print $4 }')
  [ "${#key}" -eq 78 ] || fail "the accepted derived key did not retain its 78-character identity"
  printf '%s\tapprove\tApprove\n' "$key" \
    | holds "$home" answers release --source return >/dev/null \
    || fail "the shared keyed-answer intake rejected a valid derived key"
  show=$( (cd "$home" && tasks-axi show "release-decision-$key" --full) )
  assert_contains "$show" 'state: done' 'the valid derived key did not close its hold'

  rc=0
  out=$(printf 'bad key\tapprove\tApprove\n' \
    | holds "$home" answers release --source return 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid keyed-answer record was silently reported as success"
  assert_contains "$out" 'skipped: invalid keyed-answer record' \
    'invalid keyed-answer input did not report a nonzero skip'
  assert_contains "$out" 'answers: closed=0 skipped=1 origin=release' \
    'invalid keyed-answer input reported the wrong closure totals'
  pass "derived keys close normally and invalid answer records fail loudly"
}

test_concurrent_preservation_cannot_erase_a_captain_answer() {
  local home rc=0 preserve_pid answer_pid answer_state='' show i
  home=$(make_home preserve-answer-race)
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Ship after checks pass?
[firstmate-decision origin=release key=ship state=unseeded]
[option] Approve' || rc=$?
  [ "$rc" -eq 2 ] || fail "the initial away-mode question must be denied and filed"
  printf '1. [question] Ship after checks pass with the final evidence?
[option] Approve\n' > "$home/reworded-question"
  printf 'ship\tapprove\tApprove\n' > "$home/answer.tsv"

  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${INTERLEAVE_PRESERVE:-0}" = 1 ] && [ "${1:-}" = update ] \
    && [ "${2:-}" = release-decision-ship ]; then
  : > "$FM_HOME/preserve-ready"
  while [ ! -f "$FM_HOME/release-preserve" ]; do /bin/sleep 0.02; done
fi
PATH=${PATH#*:}
export PATH
exec "$REAL_TASKS_AXI" "$@"
SH
  cat > "$home/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
[ "${INTERLEAVE_ANSWER:-0}" != 1 ] || : > "$FM_HOME/answer-waiting"
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/tasks-axi" "$home/fakebin/sleep"

  INTERLEAVE_PRESERVE=1 holds "$home" preserve-question release ship \
    --state existing --question-file "$home/reworded-question" > "$home/preserve.out" 2> "$home/preserve.err" &
  preserve_pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    [ -f "$home/preserve-ready" ] && break
    kill -0 "$preserve_pid" 2>/dev/null || break
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if [ ! -f "$home/preserve-ready" ]; then
    : > "$home/release-preserve"
    wait "$preserve_pid" || true
    fail "question preservation did not reach the forced interleaving point"
  fi

  (INTERLEAVE_ANSWER=1 holds "$home" answers release --source return \
    < "$home/answer.tsv" > "$home/answer.out" 2> "$home/answer.err"; printf '%s\n' "$?" > "$home/answer.rc") &
  answer_pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    if [ -f "$home/answer-waiting" ]; then answer_state=waiting; break; fi
    if [ -f "$home/answer.rc" ]; then answer_state=closed; break; fi
    /bin/sleep 0.01
    i=$((i + 1))
  done
  : > "$home/release-preserve"
  wait "$preserve_pid" || fail "concurrent question preservation failed: $(cat "$home/preserve.err")"
  wait "$answer_pid" || fail "concurrent captain answer failed: $(cat "$home/answer.err")"
  [ -n "$answer_state" ] || fail "concurrent answer neither waited nor completed"
  [ "$(cat "$home/answer.rc")" -eq 0 ] || fail "concurrent keyed-answer intake reported failure"
  [ "$answer_state" = waiting ] \
    || fail "captain answer did not serialize behind in-flight question preservation"

  show=$( (cd "$home" && tasks-axi show release-decision-ship --full) )
  assert_contains "$show" 'state: done' "concurrent preservation reopened the answered hold"
  assert_contains "$show" 'Resolution mode: answered' "concurrent preservation erased the durable captain answer"
  assert_contains "$show" 'Answer: approve' "concurrent preservation changed the captain answer"
  pass "concurrent preservation cannot erase a durable captain answer"
}

# Answering a returned question must close it through the owner's own existing
# close path, and only then may it leave the outstanding listing.
test_answers_close_through_the_existing_owner_paths() {
  local home rc=0 answer listing
  home=$(make_home answer-closure)
  seed_task "$home" review 'needs-decision [key=helper-versions]: restrict helper equality to MAS'
  seed_task "$home" release 'working: release prep'
  date +%s > "$home/state/.afk"
  ask "$home" '1. [question] Limit helper-version equality checks to MAS builds?
[firstmate-decision origin=review key=helper-versions state=existing]
[option] Approve
2. [question] Merge PR 123 after its required checks are green?
[firstmate-decision origin=release key=merge-pr-123 state=unseeded]
[option] Approve merge' || rc=$?
  [ "$rc" -eq 2 ] || fail "the away-mode attempt must be denied"

  # The status owner closes on its own exact resolved transition, the one
  # bin/fm-send.sh --resolve-key appends after it confirms delivery.
  printf 'resolved [key=helper-versions]: captain approved the MAS-only check\n' \
    >> "$home/state/review.status"

  # The hold owner closes through the existing keyed-answer intake.
  answer="$home/answer.tsv"
  printf 'merge-pr-123\tcaptain approved the merge once checks are green\treturn\n' > "$answer"
  holds "$home" answers release --source return < "$answer" >/dev/null \
    || fail "the existing keyed-answer intake could not close the returned hold"

  listing=$(holds "$home" open-questions --render)
  assert_not_contains "$listing" 'helper-versions' \
    'an answered status question stayed in the outstanding listing'
  assert_not_contains "$listing" 'merge-pr-123' \
    'an answered captain hold stayed in the outstanding listing'
  assert_contains "$( (cd "$home" && tasks-axi show release-decision-merge-pr-123 --full) )" 'state: done' \
    'the keyed answer did not durably close the captain hold'
  pass "answers close deferred questions through the existing status and captain-hold paths"
}

test_existing_status_owner_receives_the_deferred_question
test_repeat_notifications_and_authorized_progress_keep_one_identity
test_reworded_attempt_is_kept_as_another_variant
test_identical_questions_are_preserved_for_each_status_key
test_status_evidence_uses_the_authoritative_transition_key
test_unseeded_binding_creates_an_ordinary_captain_hold
test_transferred_hold_wins_and_status_is_never_reopened
test_status_question_moves_to_hold_before_transfer_closes
test_open_questions_reports_incomplete_hold_enumeration
test_open_questions_reports_unsafe_status_owners
test_unbound_and_malformed_questions_are_rejected_without_mutation
test_leading_preamble_is_not_mistaken_for_a_question
test_multi_origin_questionnaire_reaches_each_owner
test_return_presents_every_question_losslessly
test_return_restores_askuser_without_approving_anything
test_oversized_question_is_parked_and_returned_losslessly
test_non_droid_return_does_not_project_deferred_questions
test_derived_keys_close_and_invalid_answer_records_fail_loudly
test_concurrent_preservation_cannot_erase_a_captain_answer
test_answers_close_through_the_existing_owner_paths
