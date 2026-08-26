#!/usr/bin/env bash
# Behavior tests for bin/fm-freigabenotiz-lib.sh - the one owner of the
# 5-question Freigabenotiz, the approval class vocabulary, the acceptance-block
# fingerprint, and the destructive-marker tripwire.
#
# The point of the library is that a machine can check that a substantive review
# HAPPENED (all five questions answered, the class stated, the captain's wording
# named where the fleet requires one) without pretending it can grade the
# answers. These cases pin exactly that boundary: form is mechanical, content is
# never inspected.
#
# Standalone: `bash tests/fm-freigabenotiz-lib.test.sh`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-freigabenotiz-lib.sh
. "$ROOT/bin/fm-freigabenotiz-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-freigabenotiz-lib)

# A complete note. Callers drop one question by passing its number, so every
# "missing question" case differs from the green case in exactly one line.
write_notiz() {  # <file> [<omit-1..5>]
  local file=$1 omit=${2:-0}
  : > "$file"
  [ "$omit" = 1 ] || printf 'F1 Praemissen: the ledger is the only seating order.\n' >> "$file"
  [ "$omit" = 2 ] || printf 'F2 Abnahme: the suite is green on a clean checkout.\n' >> "$file"
  [ "$omit" = 3 ] || printf 'F3 Vision: serves the fleet-order rebuild, no product frame.\n' >> "$file"
  [ "$omit" = 4 ] || printf 'F4 Budget: one afternoon, no spend.\n' >> "$file"
  [ "$omit" = 5 ] || printf 'F5 Betroffene: the officers, nobody outside the fleet.\n' >> "$file"
}

write_brief() {  # <file> <body-line> [<abnahme-line>...]
  local file=$1 body=$2
  shift 2
  {
    printf '# Task\n%s\n\n' "$body"
    if [ "$#" -gt 0 ]; then
      printf '## Abnahme (maschinenlesbar)\n'
      printf '%s\n' "$@"
      printf '\n## Notes\ntrailing prose\n'
    fi
  } > "$file"
}

# The class vocabulary is closed, and exactly the two classes that may not rest
# on the fleet's own judgment demand a captain wording.
test_class_vocabulary_is_closed_and_names_who_needs_a_captain_word() {
  local k
  for k in routine destruktiv produkt; do
    fm_freigabe_klasse_valid "$k" || fail "'$k' must be part of the class vocabulary"
  done
  for k in "" ROUTINE routinemaessig destructive " routine "; do
    ! fm_freigabe_klasse_valid "$k" || fail "'$k' must not pass as a class"
  done
  fm_freigabe_klasse_braucht_vorlage destruktiv \
    || fail "destruktiv must require the captain's recorded wording"
  fm_freigabe_klasse_braucht_vorlage produkt \
    || fail "produkt must require the captain's recorded wording"
  ! fm_freigabe_klasse_braucht_vorlage routine \
    || fail "routine is the fleet's own call and must not demand a captain wording"
  ! fm_freigabe_klasse_braucht_vorlage "" \
    || fail "an empty class must not be treated as needing a wording"
  pass "the class vocabulary is closed and only destruktiv/produkt demand a captain wording"
}

# Order ids are minted as O-%04d, and a fleet that outgrows four digits must not
# need this validator changed.
test_order_ids_are_recognized_by_shape() {
  local ok bad
  for ok in O-0001 O-0083 O-12345; do
    fm_freigabe_order_valid "$ok" || fail "'$ok' should be a well-formed order id"
  done
  for bad in "" O- O-12 o-0001 O-0001x keine "O-0001 "; do
    ! fm_freigabe_order_valid "$bad" || fail "'$bad' must not pass as an order id"
  done
  pass "order ids are recognized by shape and tolerate more than four digits"
}

# All five markers present with a non-empty answer is the whole mechanical bar;
# what the answers SAY is never inspected.
test_a_complete_note_passes_whatever_it_says() {
  local notiz="$TMP_ROOT/complete.md"
  write_notiz "$notiz"
  fm_freigabe_notiz_check "$notiz" \
    || fail "a complete note should pass: $FM_FREIGABE_NOTIZ_ERROR"

  # Same five markers, deliberately unhelpful answers, plus surrounding prose
  # and indentation. The tool grades form, never judgment.
  {
    printf '# Freigabenotiz\n\n'
    printf '  F1 Praemissen: tbd\n'
    printf '  F2 Abnahme: tbd\n'
    printf '  F3 Vision: tbd\n'
    printf '  F4 Budget: tbd\n'
    printf '  F5 Betroffene: tbd\n\n'
    printf 'Signed, firstmate.\n'
  } > "$TMP_ROOT/thin.md"
  fm_freigabe_notiz_check "$TMP_ROOT/thin.md" \
    || fail "the library must not grade the content of an answer: $FM_FREIGABE_NOTIZ_ERROR"

  # The umlaut spelling is the one accepted synonym.
  write_notiz "$TMP_ROOT/umlaut.md" 1
  printf 'F1 Prämissen: the same premise, spelled with the umlaut.\n' >> "$TMP_ROOT/umlaut.md"
  fm_freigabe_notiz_check "$TMP_ROOT/umlaut.md" \
    || fail "'F1 Prämissen' must be accepted alongside 'F1 Praemissen': $FM_FREIGABE_NOTIZ_ERROR"
  pass "a note answering all five questions passes regardless of what it says"
}

# Every missing question is refused, and the refusal names exactly which one, so
# the firstmate is not sent hunting.
test_each_missing_question_is_named_in_the_refusal() {
  local n label notiz
  for n in 1 2 3 4 5; do
    case "$n" in
      1) label='F1 Praemissen' ;;
      2) label='F2 Abnahme' ;;
      3) label='F3 Vision' ;;
      4) label='F4 Budget' ;;
      5) label='F5 Betroffene' ;;
    esac
    notiz="$TMP_ROOT/missing-$n.md"
    write_notiz "$notiz" "$n"
    if fm_freigabe_notiz_check "$notiz"; then
      fail "a note without $label must not pass"
    fi
    assert_contains "$FM_FREIGABE_NOTIZ_ERROR" "$label" \
      "the refusal did not name the unanswered question $label"
  done

  # A marker with nothing behind the colon is an unanswered question, not an
  # answer: this is the exact shape a hurried note takes.
  write_notiz "$TMP_ROOT/empty-answer.md" 3
  printf 'F3 Vision:   \n' >> "$TMP_ROOT/empty-answer.md"
  if fm_freigabe_notiz_check "$TMP_ROOT/empty-answer.md"; then
    fail "a marker with an empty answer must not count as answered"
  fi
  assert_contains "$FM_FREIGABE_NOTIZ_ERROR" "F3 Vision" \
    "an empty answer was not reported as the unanswered question it is"

  if fm_freigabe_notiz_check "$TMP_ROOT/does-not-exist.md"; then
    fail "a missing note file must not pass"
  fi
  assert_contains "$FM_FREIGABE_NOTIZ_ERROR" "not an ordinary file" \
    "a missing note was not reported as a missing file"
  pass "every unanswered question is refused and named"
}

# The acceptance block is the one part of a brief that stays byte-bound, so the
# fingerprint must move when the block moves and stand still when prose moves.
test_the_acceptance_fingerprint_tracks_only_the_block() {
  local a b prose_edited gained
  write_brief "$TMP_ROOT/brief-a.md" 'ship the thing' '1. tests green' '2. rollout done'
  write_brief "$TMP_ROOT/brief-b.md" 'ship the thing' '1. tests green' '2. rollout done'
  a=$(fm_freigabe_abnahme_sha "$TMP_ROOT/brief-a.md")
  b=$(fm_freigabe_abnahme_sha "$TMP_ROOT/brief-b.md")
  [ "$a" = "$b" ] || fail "two identical acceptance blocks must fingerprint the same"
  case "$a" in
    [0-9a-f]*) [ "${#a}" -eq 64 ] || fail "the fingerprint should be 64 hex characters, got '$a'" ;;
    *) fail "the fingerprint should be lowercase hex, got '$a'" ;;
  esac

  # Prose outside the block is free to be sharpened after approval.
  printf 'one more clarifying sentence, outside the block\n' >> "$TMP_ROOT/brief-b.md"
  prose_edited=$(fm_freigabe_abnahme_sha "$TMP_ROOT/brief-b.md")
  [ "$prose_edited" = "$a" ] \
    || fail "editing prose outside the acceptance block must not move the fingerprint"

  # The bar itself is not.
  write_brief "$TMP_ROOT/brief-c.md" 'ship the thing' '1. tests green' '2. rollout optional'
  [ "$(fm_freigabe_abnahme_sha "$TMP_ROOT/brief-c.md")" != "$a" ] \
    || fail "changing an acceptance point must move the fingerprint"

  # Absence is its own distinguishable state, so a brief that GAINS a block
  # after approval reads as the change it is.
  write_brief "$TMP_ROOT/brief-none.md" 'ship the thing'
  [ "$(fm_freigabe_abnahme_sha "$TMP_ROOT/brief-none.md")" = '-' ] \
    || fail "a brief with no acceptance block must fingerprint as '-'"
  write_brief "$TMP_ROOT/brief-gained.md" 'ship the thing' '1. tests green'
  gained=$(fm_freigabe_abnahme_sha "$TMP_ROOT/brief-gained.md")
  [ "$gained" != '-' ] || fail "a brief that gained a block must not still read as blockless"
  pass "the acceptance fingerprint tracks the block alone, and absence is its own state"
}

# The tripwire never decides; it makes a contradiction impossible to pass over.
# TRIPPED is a return VALUE, so a caller under set -e must survive asking.
test_the_tripwire_reports_markers_without_deciding() {
  local out
  write_brief "$TMP_ROOT/trip-rm.md" 'clean the workspace with rm -rf build/' '1. build dir gone'
  if out=$(fm_freigabe_tripwire "$TMP_ROOT/trip-rm.md"); then
    assert_contains "$out" "rm -rf" "the tripwire did not report the irreversible command it found"
  else
    fail "a brief carrying 'rm -rf' must trip the tripwire"
  fi

  write_brief "$TMP_ROOT/trip-sql.md" 'migrate: DROP TABLE alt; DELETE FROM sitzungen;' '1. schema migrated'
  if out=$(fm_freigabe_tripwire "$TMP_ROOT/trip-sql.md"); then
    assert_contains "$out" "DROP" "the tripwire missed a DROP"
    assert_contains "$out" "DELETE FROM" "the tripwire missed a DELETE FROM"
  else
    fail "a brief carrying SQL destruction must trip the tripwire"
  fi

  # The German verbs are read only inside the acceptance block, where they
  # describe the delivered RESULT rather than incidental prose.
  write_brief "$TMP_ROOT/trip-block.md" 'tidy up' '1. Cache leeren' '2. tests green'
  if out=$(fm_freigabe_tripwire "$TMP_ROOT/trip-block.md"); then
    assert_contains "$out" "Abnahmeblock" \
      "a destructive verb in the acceptance block should be reported as such"
  else
    fail "'leeren' inside the acceptance block must trip the tripwire"
  fi
  write_brief "$TMP_ROOT/prose-verb.md" 'we discussed whether to leeren the cache and decided against it' '1. tests green'
  if fm_freigabe_tripwire "$TMP_ROOT/prose-verb.md" >/dev/null; then
    fail "a German verb in incidental prose must not trip the tripwire"
  fi

  write_brief "$TMP_ROOT/clean.md" 'add a column and a test' '1. tests green'
  if fm_freigabe_tripwire "$TMP_ROOT/clean.md" >/dev/null; then
    fail "an ordinary brief must not trip the tripwire"
  fi

  # Asking under `set -e` must not kill the asker: the verdict is a return
  # value, and both answers have to survive the question.
  ( set -e
    # shellcheck source=bin/fm-freigabenotiz-lib.sh
    . "$ROOT/bin/fm-freigabenotiz-lib.sh"
    if fm_freigabe_tripwire "$TMP_ROOT/clean.md" >/dev/null; then :; fi
    if fm_freigabe_tripwire "$TMP_ROOT/trip-rm.md" >/dev/null; then :; fi
    exit 0
  ) || fail "asking the tripwire under set -e must not abort the caller"
  pass "the tripwire reports markers, distinguishes prose from the acceptance block, and never decides"
}

# A missing mandate does not stop the plan; it stops the MERGE (HR2'). Saying so
# at approval time is strictly better than discovering it at landing time.
test_the_mandate_hint_warns_without_refusing() {
  local home out
  home="$TMP_ROOT/home"
  mkdir -p "$home/projects/lensclash" "$home/data/mandat"
  write_brief "$TMP_ROOT/brief-repo.md" 'repo: lensclash' '1. tests green'

  out=$(fm_freigabe_mandat_hinweis "$TMP_ROOT/brief-repo.md" "$home") \
    || fail "the mandate hint must never refuse"
  assert_contains "$out" "MANDAT.md is missing" "the hint did not name the missing mandate file"
  assert_contains "$out" "merge will hold everything" "the hint did not say what the consequence is"

  printf '# Mandat\n' > "$home/projects/lensclash/MANDAT.md"
  out=$(fm_freigabe_mandat_hinweis "$TMP_ROOT/brief-repo.md" "$home")
  [ -z "$out" ] || fail "a present project mandate must silence the hint, got: $out"

  # The transition fallback bin/fm-mandat-check.sh also reads counts as present.
  rm -f "$home/projects/lensclash/MANDAT.md"
  printf '# Mandat\n' > "$home/data/mandat/lensclash.md"
  out=$(fm_freigabe_mandat_hinweis "$TMP_ROOT/brief-repo.md" "$home")
  [ -z "$out" ] || fail "the data/mandat fallback must silence the hint too, got: $out"

  # A brief that names no repo has nothing to warn about.
  write_brief "$TMP_ROOT/brief-norepo.md" 'no repo field here' '1. tests green'
  out=$(fm_freigabe_mandat_hinweis "$TMP_ROOT/brief-norepo.md" "$home")
  [ -z "$out" ] || fail "a brief without a repo field must produce no hint, got: $out"
  pass "the mandate hint warns about a merge that will hold, and never refuses"
}

test_class_vocabulary_is_closed_and_names_who_needs_a_captain_word
test_order_ids_are_recognized_by_shape
test_a_complete_note_passes_whatever_it_says
test_each_missing_question_is_named_in_the_refusal
test_the_acceptance_fingerprint_tracks_only_the_block
test_the_tripwire_reports_markers_without_deciding
test_the_mandate_hint_warns_without_refusing
