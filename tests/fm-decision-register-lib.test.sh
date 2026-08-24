#!/usr/bin/env bash
# Behavior tests for bin/fm-decision-register-lib.sh - the firstmate-private
# per-home storage for captain-held decisions no work item gates.
# Exercises the shape the register file writes, `show` rendering that stays
# byte-compatible with `tasks-axi show --full` reads, idempotent open, close,
# and enumeration.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-register)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

# Source the lib under a fixture STATE dir so writes stay in the temp root.
FM_HOME="$HOME_DIR"
STATE="$HOME_DIR/state"
FM_STATE_OVERRIDE="$STATE"
FM_DECISION_REGISTER_NOW=2026-08-24T15:30:00Z
export FM_HOME STATE FM_STATE_OVERRIDE FM_DECISION_REGISTER_NOW
# shellcheck source=bin/fm-decision-register-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-decision-register-lib.sh"

# --- open + exists + field + show ------------------------------------------

test_open_writes_atomic_file() {
  fm_decision_register_open aim-42-decision-scope \
    "captain must pick scope A or B" aim-42 '' \
    "[aim] pick scope" firstmate "Origin: aim-42" || fail "open failed"
  local path
  path=$(fm_decision_register_path aim-42-decision-scope)
  [ -f "$path" ] || fail "register file missing"
  fm_decision_register_exists aim-42-decision-scope || fail "exists failed to see it"
  [ "$(stat -f %p "$path" 2>/dev/null || stat -c %a "$path")" != "" ] || fail "mode unreadable"
  pass "open writes an atomic register file"
}

test_field_reads() {
  local id=aim-42-decision-scope
  [ "$(fm_decision_register_field "$id" state)" = queued ] || fail "state field"
  [ "$(fm_decision_register_field "$id" hold_kind)" = captain ] || fail "hold_kind field"
  [ "$(fm_decision_register_field "$id" hold_reason)" = "captain must pick scope A or B" ] || fail "hold_reason field"
  [ "$(fm_decision_register_field "$id" title)" = "[aim] pick scope" ] || fail "title field"
  [ "$(fm_decision_register_field "$id" origin)" = aim-42 ] || fail "origin field"
  [ "$(fm_decision_register_field "$id" created)" = "$FM_DECISION_REGISTER_NOW" ] || fail "created field"
  [ "$(fm_decision_register_body "$id")" = "Origin: aim-42" ] || fail "body reader"
  pass "field readers return exact stored values"
}

test_show_matches_tasks_axi_shape() {
  local id=aim-42-decision-scope out
  out=$(fm_decision_register_show "$id") || fail "show failed"
  case "$out" in
    *'  id: '"$id"*) : ;;
    *) fail "show missing id line" ;;
  esac
  case "$out" in
    *'  state: queued'*) : ;;
    *) fail "show missing state line" ;;
  esac
  case "$out" in
    *'  hold_kind: captain'*) : ;;
    *) fail "show missing hold_kind line" ;;
  esac
  case "$out" in
    *'  body: Origin: aim-42'*) : ;;
    *) fail "show missing body line" ;;
  esac
  pass "show renders the tasks-axi show --full shape"
}

test_multi_line_body_json_encoded() {
  local id=aim-42-decision-multi out body
  body=$(printf 'line 1\nline 2\nline 3')
  fm_decision_register_open "$id" "picks something" aim-42 '' "[aim] multi" firstmate "$body" \
    || fail "multi-line open failed"
  out=$(fm_decision_register_show "$id") || fail "show failed"
  # Multi-line body must render as a single quoted line, matching tasks-axi.
  case "$out" in
    *'  body: "line 1\nline 2\nline 3"'*) : ;;
    *) fail "multi-line body not JSON-encoded: $out" ;;
  esac
  pass "multi-line body renders as one JSON-quoted line"
}

# --- idempotent open --------------------------------------------------------

test_open_is_idempotent_on_identical_input() {
  local id=aim-42-decision-scope path before after
  path=$(fm_decision_register_path "$id")
  before=$(cat "$path")
  fm_decision_register_open "$id" \
    "captain must pick scope A or B" aim-42 '' \
    "[aim] pick scope" firstmate "Origin: aim-42" || fail "idempotent open failed"
  after=$(cat "$path")
  [ "$before" = "$after" ] || fail "identical open changed the file"
  pass "identical open is a no-op"
}

test_open_updates_changed_reason() {
  local id=aim-42-decision-scope
  fm_decision_register_open "$id" \
    "captain must pick scope A or B or C" aim-42 '' \
    "[aim] pick scope" firstmate "Origin: aim-42" || fail "update open failed"
  [ "$(fm_decision_register_field "$id" hold_reason)" = "captain must pick scope A or B or C" ] \
    || fail "reason not updated"
  [ "$(fm_decision_register_field "$id" state)" = queued ] \
    || fail "update flipped state"
  pass "open with a new reason rewrites reason and preserves state"
}

# --- answer flips state, prepends resolution block --------------------------

test_answer_prepends_resolution_block() {
  local id=aim-42-decision-scope digest body
  digest=$(printf 'answer text' | shasum -a 256 | awk '{print $1}')
  fm_decision_register_answer "$id" answered "captain: pick A" "$digest" \
    || fail "answer failed"
  [ "$(fm_decision_register_field "$id" state)" = "done" ] || fail "state not flipped to done"
  body=$(fm_decision_register_body "$id")
  case "$body" in
    "Resolution recorded by fm-captain-hold."*"Decision digest: $digest"*"Resolution mode: answered"*"Captain decision:"*"captain: pick A"*"Origin: aim-42")
      : ;;
    *) fail "resolution block not prepended: $body" ;;
  esac
  pass "answer prepends resolution block and flips state to done"
}

# --- refusal to reopen a done register entry -------------------------------

test_open_refuses_reopen_of_done() {
  local id=aim-42-decision-scope rc=0
  fm_decision_register_open "$id" \
    "new reason" aim-42 '' \
    "[aim] pick scope" firstmate "Origin: aim-42" || rc=$?
  [ "$rc" = 2 ] || fail "expected exit 2 when re-holding a done entry, got $rc"
  pass "open refuses to reopen a done register entry"
}

# --- list filters -----------------------------------------------------------

test_list_filters() {
  local all queued done_
  all=$(fm_decision_register_list all | LC_ALL=C sort)
  queued=$(fm_decision_register_list queued | LC_ALL=C sort)
  done_=$(fm_decision_register_list "done" | LC_ALL=C sort)
  # aim-42-decision-scope is done; aim-42-decision-multi is queued.
  [ "$all" = "$(printf 'aim-42-decision-multi\naim-42-decision-scope')" ] || fail "list all mismatch: $all"
  [ "$queued" = "aim-42-decision-multi" ] || fail "list queued mismatch: $queued"
  [ "$done_" = "aim-42-decision-scope" ] || fail "list done mismatch: $done_"
  pass "list filters by state"
}

# --- retire removes the file, non-existent id is a silent no-op ------------

test_retire_removes_file() {
  local id=aim-42-decision-multi
  fm_decision_register_retire "$id" || fail "retire failed"
  fm_decision_register_exists "$id" && fail "retired id still exists"
  fm_decision_register_retire never-existed || fail "retire on absent id must be a no-op"
  pass "retire removes the file and is safe on absent ids"
}

# --- test hostile input: newlines in reason are stripped -------------------

test_sanitize_strips_newlines_from_fields() {
  local id=aim-99-decision-inject
  fm_decision_register_open "$id" \
    "$(printf 'line1\nline2 - a smuggled\nkey: bad')" aim-99 '' \
    "$(printf 't\nx')" firstmate "body ok" || fail "hostile open failed"
  local reason title
  reason=$(fm_decision_register_field "$id" hold_reason)
  title=$(fm_decision_register_field "$id" title)
  case "$reason" in *$'\n'*) fail "reason retained a newline" ;; esac
  case "$title" in *$'\n'*) fail "title retained a newline" ;; esac
  # And no key line got smuggled: state must still be readable and correct.
  [ "$(fm_decision_register_field "$id" state)" = queued ] || fail "state broken by injection"
  pass "hostile newlines are stripped from single-line fields"
}

# --- run --------------------------------------------------------------------

test_open_writes_atomic_file
test_field_reads
test_show_matches_tasks_axi_shape
test_multi_line_body_json_encoded
test_open_is_idempotent_on_identical_input
test_open_updates_changed_reason
test_answer_prepends_resolution_block
test_open_refuses_reopen_of_done
test_list_filters
test_retire_removes_file
test_sanitize_strips_newlines_from_fields
