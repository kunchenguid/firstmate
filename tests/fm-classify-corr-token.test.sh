#!/usr/bin/env bash
# tests/fm-classify-corr-token.test.sh - a status line may carry the correlation
# token bin/fm-pending-reply-lib.sh embeds in a marked request and a secondmate
# echoes back (bin/fm-brief.sh), between the verb and the rest of the line. Every
# verb-driven classification must read straight through that token, in BOTH
# directions: a verb parse that keeps the token glued on matches no arm of the
# decision fold, so the opener never opens, the closer never closes, and a
# decision the captain is owed never reaches him.
#
# The parse is deliberately strict, and these tests defend that strictness as
# hard as they defend the fix: only the exact token a firstmate library writes is
# read through. Prose, a malformed or wrong-length token, and an arbitrary
# name=value word all keep their extra words and therefore stay non-transitions.
#
# Coverage is split by the interface each claim lives behind: the fold is driven
# through the REAL bin/fm-wake-drain.sh, the classifier predicates through the
# library's own sourced entry points (as tests/fm-watch-triage.test.sh does), and
# the token grammar itself is pinned against the REAL writers so this library's
# second statement of the shape cannot drift from the one that owns it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-corr-token-tests)

# A syntactically valid correlation token payload: 16 hex characters.
CORR=c44897ee2db4326b
CORR2=7ab3e5dd13c9a993

# Print the drain's OPEN DECISIONS view of <state>, or the empty string when the
# drain reports nothing open. Keeps each case's assertions about the CONTRACT
# (which decisions are open) rather than about the section's layout.
drain_open() {  # <state> <out>
  local state=$1 out=$2
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed over $state"
  grep -F 'OPEN DECISIONS' "$out" >/dev/null || return 0
  cat "$out"
}

# --- the fold, both directions ----------------------------------------------

test_tokened_opener_opens_and_tokened_closer_closes() {
  local dir state out view
  dir=$(make_case tokened-both-directions)
  state="$dir/state"
  out="$dir/drain.out"

  # OPENER. The half that loses a captain decision outright: it never appears in
  # any listing, so nobody knows it is owed.
  printf 'needs-decision corr=%s [key=texte-du-mur]: propose the wall text\n' "$CORR" \
    > "$state/task-open.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-open'*'[key=texte-du-mur]'*'propose the wall text'*) : ;;
    *) fail "a needs-decision carrying a correlation token did not open its key: $view" ;;
  esac

  # CLOSER. The half that leaves an answered decision on the captain's board.
  printf 'resolved corr=%s [key=texte-du-mur]: captain chose the third wording\n' "$CORR" \
    >> "$state/task-open.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'texte-du-mur'*) fail "a resolved carrying a correlation token did not close its key: $view" ;;
  esac

  # A blocked opener and a captain-held transfer close the same way.
  printf 'blocked corr=%s [key=sortie-plan]: the only lever exceeds the ruling\n' "$CORR2" \
    > "$state/task-blocked.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-blocked'*'[key=sortie-plan]'*) : ;;
    *) fail "a blocked carrying a correlation token did not open its key: $view" ;;
  esac
  printf 'captain-held corr=%s [key=sortie-plan]: tracked as a captain hold\n' "$CORR2" \
    >> "$state/task-blocked.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'sortie-plan'*) fail "a captain-held carrying a correlation token did not close its key: $view" ;;
  esac

  pass "a correlation token between the verb and the key breaks neither opening nor closing"
}

test_token_is_read_through_in_every_position_it_is_written_in() {
  local dir state out view
  dir=$(make_case token-positions)
  state="$dir/state"
  out="$dir/drain.out"

  # Before the key, after the key, with no key at all, twice on one line (a
  # recovery turn re-embedding), and in the bracketed shape the optional
  # bin/fm-secondmate-report.sh helper writes. Every one is a real observed shape.
  printf 'needs-decision corr=%s [key=before]: token ahead of the key\n' "$CORR" > "$state/t1.status"
  printf 'needs-decision [key=after] corr=%s: token behind the key\n' "$CORR" > "$state/t2.status"
  printf 'blocked corr=%s: token and no key at all\n' "$CORR" > "$state/t3.status"
  printf 'needs-decision corr=%s corr=%s [key=twice]: two tokens on one line\n' "$CORR" "$CORR2" \
    > "$state/t4.status"
  printf 'needs-decision [corr=%s]: the helper bracket shape\n' "$CORR" > "$state/t5.status"

  view=$(drain_open "$state" "$out")
  case "$view" in *'t1'*'[key=before]'*) ;; *) fail "token before the key did not open: $view" ;; esac
  case "$view" in *'t2'*'[key=after]'*) ;; *) fail "token after the key did not open: $view" ;; esac
  # The drain prints the default key as a bare verb, with no [key=...] segment.
  case "$view" in *'t3 blocked:'*) ;; *) fail "token with no key did not open the default key: $view" ;; esac
  case "$view" in *'t4'*'[key=twice]'*) ;; *) fail "two tokens on one line did not open: $view" ;; esac
  case "$view" in *'t5 needs-decision:'*) ;; *) fail "the bracketed helper token did not open: $view" ;; esac

  # ...and each closes from the same position.
  printf 'resolved corr=%s [key=before]: closed\n' "$CORR" >> "$state/t1.status"
  printf 'resolved [key=after] corr=%s: closed\n' "$CORR" >> "$state/t2.status"
  printf 'resolved corr=%s: closed\n' "$CORR" >> "$state/t3.status"
  printf 'resolved corr=%s corr=%s [key=twice]: closed\n' "$CORR" "$CORR2" >> "$state/t4.status"
  printf 'resolved [corr=%s]: closed\n' "$CORR" >> "$state/t5.status"

  view=$(drain_open "$state" "$out")
  [ -z "$view" ] || fail "a correlated closer failed to close from some position: $view"

  pass "the token is read through before the key, after it, doubled, bracketed, and unkeyed"
}

test_untokened_pair_is_unchanged() {
  local dir state out view
  dir=$(make_case untokened-pair)
  state="$dir/state"
  out="$dir/drain.out"

  # The same pair with no token at all, keyed and bare: the historical behavior
  # this change must leave exactly as it was.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/keyed.status"
  printf 'blocked: no key at all\n' > "$state/bare.status"
  view=$(drain_open "$state" "$out")
  case "$view" in *'keyed'*'[key=api-shape]'*) ;; *) fail "an untokened keyed opener regressed: $view" ;; esac
  case "$view" in *'bare blocked:'*) ;; *) fail "an untokened bare opener regressed: $view" ;; esac

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/keyed.status"
  printf 'resolved: cleared on its own\n' >> "$state/bare.status"
  view=$(drain_open "$state" "$out")
  [ -z "$view" ] || fail "an untokened closer regressed: $view"

  pass "the untokened opener/closer pair behaves exactly as before"
}

# --- the strictness the parse exists for ------------------------------------

test_prose_and_malformed_tokens_never_become_transitions() {
  local dir state out view line
  dir=$(make_case no-prose-takeover)
  state="$dir/state"
  out="$dir/drain.out"

  # Every one of these must stay a non-transition. If any became a verb, free
  # text would be able to open decisions nobody raised - or silently close one
  # the captain is owed, which is the takeover this strictness exists to stop.
  #
  # All of these are UNBRACKETED, which is the shape this parser owns. A
  # BRACKETED tag is deliberately NOT listed: verb parsing ends at the first
  # "[", so "resolved [corr=deadbeef] [key=victim]:" reads as the bare verb
  # "resolved" and does close the decision. That is the tag rule's own
  # contract, not a gap in this one, and tightening it here would silently
  # narrow a separately reviewed rule. The strictness below is what keeps an
  # unbracketed token honest, and a bracketed impostor still has to get a
  # well-formed key past _fm_decision_key_transition_allowed.
  local -a impostors=(
    'resolved the corr= issue yesterday [key=victim]'
    'resolved corr= [key=victim]'
    'resolved corr=deadbeef [key=victim]'
    'resolved corr=abcdef0123456789ab [key=victim]'
    'resolved corr=ZZZZbeefdeadbeef [key=victim]'
    'resolved xcorr=c44897ee2db4326b [key=victim]'
    'resolved corr=c44897ee2db4326 [key=victim]'
    'resolved anything=whatever [key=victim]'
    'resolved and then corr=c44897ee2db4326b happened [key=victim]'
  )

  # Each impostor gets its own task log, and every log is only ever appended to,
  # the way a real status file is written. All of them are then folded in ONE
  # drain, so a single pass proves every case at once.
  local i=0
  for line in "${impostors[@]}"; do
    printf 'needs-decision [key=victim]: a real captain decision\n' > "$state/close-$i.status"
    printf '%s: free text that must not close it\n' "$line" >> "$state/close-$i.status"
    # The same shape must not OPEN one either.
    printf '%s: free text that must not open anything\n' "${line/resolved/needs-decision}" \
      > "$state/open-$i.status"
    i=$((i + 1))
  done

  view=$(drain_open "$state" "$out")
  i=0
  for line in "${impostors[@]}"; do
    case "$view" in
      *"close-$i [key=victim] needs-decision: a real captain decision"*) : ;;
      *) fail "an impostor closed a real decision: '$line' -> $view" ;;
    esac
    case "$view" in
      *"open-$i "*) fail "an impostor opened a decision nobody raised: '$line' -> $view" ;;
    esac
    i=$((i + 1))
  done

  # A note mentioning the token AFTER the colon is ordinary prose and touches
  # nothing, whichever verb carries it.
  printf 'needs-decision [key=noted]: see corr=c44897ee2db4326b in the thread\n' > "$state/noted.status"
  printf 'working: chasing corr=c44897ee2db4326b through the log\n' >> "$state/noted.status"
  printf 'done: resolved corr=c44897ee2db4326b in passing\n' >> "$state/noted.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'noted'*'[key=noted]'*) : ;;
    *) fail "a token quoted inside notes disturbed the fold: $view" ;;
  esac

  pass "prose, malformed, wrong-length and unknown name=value tokens stay non-transitions"
}

test_token_first_word_never_impersonates_a_transition() {
  local dir state out view
  dir=$(make_case token-first)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'corr=%s needs-decision [key=token-first-needs]: prose\n' "$CORR" \
    > "$state/token-first-needs.status"
  printf 'corr=%s blocked [key=token-first-blocked]: prose\n' "$CORR" \
    > "$state/token-first-blocked.status"

  printf 'needs-decision [key=stays-open-resolved]: a real captain decision\n' \
    > "$state/token-first-resolved.status"
  printf 'corr=%s resolved [key=stays-open-resolved]: prose\n' "$CORR" \
    >> "$state/token-first-resolved.status"

  printf 'blocked [key=stays-open-held]: a real captain blocker\n' \
    > "$state/token-first-held.status"
  printf 'corr=%s captain-held [key=stays-open-held]: prose\n' "$CORR" \
    >> "$state/token-first-held.status"

  view=$(drain_open "$state" "$out")
  case "$view" in
    *'token-first-needs '*) fail "a token-first needs-decision opened a decision: $view" ;;
  esac
  case "$view" in
    *'token-first-blocked '*) fail "a token-first blocked opened a decision: $view" ;;
  esac
  case "$view" in
    *'token-first-resolved'*'[key=stays-open-resolved]'*'a real captain decision'*) : ;;
    *) fail "a token-first resolved closed a real decision: $view" ;;
  esac
  case "$view" in
    *'token-first-held'*'[key=stays-open-held]'*'a real captain blocker'*) : ;;
    *) fail "a token-first captain-held closed a real blocker: $view" ;;
  esac

  pass "a token-first line cannot impersonate any opening or closing verb"
}

# --- every other status_line_verb consumer ----------------------------------

test_captain_relevance_and_pause_are_unchanged_without_a_token() {
  # Pinned verdicts for the untokened shapes. These are the historical answers;
  # the fast path in status_line_verb returns such a prefix byte-for-byte, so
  # this is the regression wall for every consumer at once.
  status_is_captain_relevant 'done: shipped' || fail "done: regressed"
  status_is_captain_relevant 'needs-decision [key=q1]: pick one' || fail "keyed needs-decision regressed"
  status_is_captain_relevant 'blocked: stuck' || fail "blocked: regressed"
  status_is_captain_relevant 'failed: gave up' || fail "failed: regressed"
  status_is_captain_relevant 'working: still going' && fail "working: regressed to captain-relevant"
  status_is_captain_relevant 'working: rebased onto merged #76' \
    && fail "nonterminal free-text guard regressed"
  status_is_captain_relevant 'merged' || fail "legacy bare free-text regressed"
  status_is_captain_relevant 'resolved [key=q1]: answered' && fail "resolved regressed to captain-relevant"

  status_is_paused 'paused: waiting on the upstream release' || fail "paused: regressed"
  status_is_paused '  paused:   waiting on a reset' || fail "spaced paused: regressed"
  status_is_paused 'blocked: the build is paused upstream' && fail "paused-in-prose regressed"
  status_is_paused 'working: paused the animation loop' && fail "paused-in-prose regressed"
  status_is_paused '' && fail "empty line regressed"

  status_is_terminal_verb 'done: shipped' || fail "terminal verb regressed"
  status_is_terminal_verb 'working: rebased onto merged #76' && fail "nonterminal terminal-verb regressed"
  status_is_paused_or_captain_held 'captain-held [key=r]: tracked' || fail "captain-held regressed"
  status_is_paused_or_captain_held 'resolved [key=r]: answered' && fail "resolved regressed"

  pass "untokened captain-relevance, pause, terminal-verb and captain-held verdicts are unchanged"
}

test_consumer_verdicts_read_through_the_token() {
  # A token must not hide a captain-facing event from the supervisors, and must
  # not let a nonterminal line be escalated as one. Both were live: an untreated
  # token made "done corr=...: PR ready" invisible to the terminal-verb test,
  # while "working corr=...: rebased onto merged #76" leaked through the
  # free-text fallback the nonterminal guard was supposed to stop.
  status_is_captain_relevant "done corr=$CORR: shipped" \
    || fail "a correlated done is not captain-relevant"
  status_is_captain_relevant "needs-decision corr=$CORR [key=q]: pick one" \
    || fail "a correlated needs-decision is not captain-relevant"
  status_is_captain_relevant "blocked corr=$CORR: stuck" \
    || fail "a correlated blocked is not captain-relevant"
  status_is_captain_relevant "done [corr=$CORR]: shipped via the helper" \
    || fail "a helper-bracketed done is not captain-relevant"

  status_is_terminal_verb "done corr=$CORR: shipped" \
    || fail "a correlated done is not a terminal verb"
  status_is_terminal_verb "working corr=$CORR: still going" \
    && fail "a correlated working became a terminal verb"

  status_is_captain_relevant "working corr=$CORR: rebased onto merged #76" \
    && fail "a correlated working leaked through the free-text fallback"
  status_is_captain_relevant "resolved corr=$CORR [key=q]: answered" \
    && fail "a correlated resolved leaked through the free-text fallback"

  # The pause and captain-held declarations the watcher reads to leave a
  # deliberately idle endpoint alone instead of aging it as a possible wedge.
  status_is_paused "paused corr=$CORR: waiting on the upstream release" \
    || fail "a correlated pause was not recognised as a declared external wait"
  status_is_paused_or_captain_held "captain-held corr=$CORR [key=r]: tracked as a hold" \
    || fail "a correlated captain-held was not recognised"
  status_is_paused "blocked corr=$CORR: the build is paused upstream" \
    && fail "a correlated blocked mentioning paused false-matched"

  pass "captain-relevance, terminal-verb, pause and captain-held all read through the token"
}

test_daemon_and_crew_state_case_arms_read_through_the_token() {
  # Two consumers switch on the verb STRING rather than on a helper, so they
  # cannot be proven through status_is_*: bin/fm-supervise-daemon.sh matches
  # working|resolved|captain-held to take the transient-stale path instead of
  # the terminal one, and bin/fm-crew-state.sh's map_log_state maps each verb to
  # a run state, falling through to "unknown" on anything else.
  #
  # Before this fix a correlated line matched no arm of either: a correlated
  # working line was escalated as terminally stale, and every correlated line
  # read as run state "unknown". Pin the exact strings those arms compare
  # against, for both the tokened and untokened spellings.
  local verb
  for verb in working resolved captain-held; do
    [ "$(status_line_verb "$verb corr=$CORR [key=k]: note")" = "$verb" ] \
      || fail "the daemon transient-stale arm no longer matches a correlated $verb"
    [ "$(status_line_verb "$verb [key=k]: note")" = "$verb" ] \
      || fail "the daemon transient-stale arm regressed for an untokened $verb"
  done
  for verb in working needs-decision blocked 'done' failed; do
    [ "$(status_line_verb "$verb corr=$CORR: note")" = "$verb" ] \
      || fail "map_log_state would still read a correlated $verb as unknown"
    [ "$(status_line_verb "$verb: note")" = "$verb" ] \
      || fail "map_log_state regressed for an untokened $verb"
  done

  # The same arms must stay closed to prose and to a malformed token, or a
  # stuck worker could dodge a stale escalation by writing one.
  [ "$(status_line_verb "working the corr= thing [key=k]: prose")" = working ] \
    && fail "prose reduced to a bare working verb"
  [ "$(status_line_verb "working corr=deadbeef [key=k]: malformed")" = working ] \
    && fail "a malformed token reduced to a bare working verb"

  pass "the daemon and crew-state verb case arms read through the token"
}

test_pending_reply_escalation_matching_is_unaffected() {
  # bin/fm-pending-reply-lib.sh filters a status file by verb when looking for
  # the escalation IT published, then whole-line matches its own exact payload.
  # Reading through the token widens the verb filter, so this pins that the exact
  # match behind it still refuses everything that is not that library's own line.
  local dir state out view
  dir=$(make_case pending-reply-namespace)
  state="$dir/state"
  out="$dir/drain.out"

  # The reserved namespace may only be opened by a note speaking its vocabulary.
  # A correlated line must not become a way around that. Each claim gets its own
  # append-only log so one drain proves both.
  printf 'blocked corr=%s [key=pending-reply-%s]: unrelated note\n' "$CORR" "$CORR" \
    > "$state/task-takeover.status"
  printf 'blocked corr=%s [key=pending-reply-%s]: pending-reply-missed: task=t pending-reply-id=%s\n' \
    "$CORR" "$CORR" "$CORR" > "$state/task-owner.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-takeover'*) fail "a correlated line took over a reserved key: $view" ;;
  esac
  case "$view" in
    *"task-owner [key=pending-reply-$CORR]"*) : ;;
    *) fail "the reserved namespace owner could not open through a token: $view" ;;
  esac

  # ...and the owner closes it through a token just as completely.
  printf 'resolved corr=%s [key=pending-reply-%s]: pending-reply-missed: answered\n' \
    "$CORR" "$CORR" >> "$state/task-owner.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-owner'*) fail "the reserved namespace owner could not close through a token: $view" ;;
  esac

  pass "reading through the token does not weaken the reserved-key namespace rule"
}

# --- the two folds must agree ------------------------------------------------

test_incremental_and_whole_file_folds_agree_over_correlated_lines() {
  local dir state status whole inc round
  dir=$(make_case fold-agreement)
  state="$dir/state"
  status="$state/task-agree.status"

  # Grow the log the way a real one grows - correlated opens, unrelated routine
  # traffic, correlated closes - and after EVERY append assert that the bounded
  # cursor-backed fold and the whole-file fold report the identical open set.
  : > "$status"
  round=0
  while [ "$round" -lt 6 ]; do
    printf 'needs-decision corr=%s [key=k%s]: decision %s\n' "$CORR" "$round" "$round" >> "$status"
    printf 'working corr=%s: routine progress %s\n' "$CORR2" "$round" >> "$status"
    whole=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    inc=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions_incremental "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    [ "$whole" = "$inc" ] \
      || fail "folds disagreed after opening k$round: whole=[$whole] incremental=[$inc]"
    # Agreement alone would be satisfied by both folds being blind in the same
    # way, so pin the answer itself: every key opened so far, and only those.
    [ "$(printf '%s' "$whole" | grep -c .)" -eq "$((round + 1))" ] \
      || fail "after opening k$round the folds agreed on the wrong set: [$whole]"
    case "$whole" in
      *"k$round"*) : ;;
      *) fail "the folds agreed but never saw the correlated opener k$round: [$whole]" ;;
    esac
    round=$((round + 1))
  done

  round=0
  while [ "$round" -lt 6 ]; do
    printf 'resolved corr=%s [key=k%s]: answered %s\n' "$CORR" "$round" "$round" >> "$status"
    whole=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    inc=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions_incremental "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    [ "$whole" = "$inc" ] \
      || fail "folds disagreed after closing k$round: whole=[$whole] incremental=[$inc]"
    [ "$(printf '%s' "$whole" | grep -c .)" -eq "$((5 - round))" ] \
      || fail "after closing k$round the folds agreed on the wrong set: [$whole]"
    case "$whole" in
      *"k$round"*) fail "the correlated closer for k$round left it open in both folds: [$whole]" ;;
    esac
    round=$((round + 1))
  done

  [ -z "$whole" ] || fail "correlated closers left decisions open in both folds: $whole"

  pass "the cursor-backed fold and the whole-file fold agree on every correlated transition"
}

test_a_cursor_written_before_this_change_is_rebuilt() {
  # The persisted cursor carries a folded open set, so every one written under
  # the previous reading holds decisions computed while correlated lines were
  # invisible. Without a fold-version bump those homes would keep serving the old
  # answer forever - the live openers would stay missing after the fix landed.
  local dir state status cursor out view
  dir=$(make_case stale-cursor)
  state="$dir/state"
  status="$state/task-stale.status"

  printf 'needs-decision corr=%s [key=owed]: a decision the captain is owed\n' "$CORR" > "$status"
  # A cursor claiming the whole file is already folded, with an empty open set -
  # byte for byte what the previous reading would have persisted here.
  cursor="$state/.task-stale.open-decisions-cursor"
  {
    printf 'version=4\n'
    printf 'offset=%s\n' "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')"
    printf 'ident=%s\n' "$(bash -c '. "$1"; _fm_open_decisions_file_ident "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")"
  } > "$cursor"

  out="$dir/drain.out"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-stale'*'[key=owed]'*) : ;;
    *) fail "a cursor from the previous reading hid the decision instead of being rebuilt: $view" ;;
  esac

  pass "a cursor persisted under the previous reading is discarded and refolded"
}

# --- the grammar pin ---------------------------------------------------------

test_the_real_writers_produce_tokens_this_library_reads() {
  # This library states the token SHAPE a second time because the library that
  # OWNS the grammar sources this one and cannot be sourced back. That second
  # statement is only safe while it is pinned to the real writers, so this drives
  # both of them for real and asserts the classifier reads their output.
  local dir state token line verb helper_line
  dir=$(make_case writer-pin)
  state="$dir/state"

  # Writer 1: the correlation library's own token builder, over ids it generates.
  local i=0 corr
  while [ "$i" -lt 5 ]; do
    corr=$(bash -c '. "$1"; fm_pending_reply_new_id' _ "$ROOT/bin/fm-pending-reply-lib.sh")
    [ -n "$corr" ] || fail "the correlation library produced an empty id"
    token=$(bash -c '. "$1"; fm_pending_reply_corr_token "$2"' _ \
      "$ROOT/bin/fm-pending-reply-lib.sh" "$corr")
    line="needs-decision $token [key=pinned]: a decision"
    verb=$(status_line_verb "$line")
    [ "$verb" = needs-decision ] \
      || fail "the classifier did not read through a real correlation token '$token' (verb=[$verb])"
    i=$((i + 1))
  done

  # Writer 2: the optional secondmate report helper, whose bracketed shape must
  # be read through just as completely. Drive the real script from a seeded
  # mate home so it resolves the parent channel itself.
  local parent mate
  parent="$dir"
  mate="$dir/mate"
  mkdir -p "$mate/state"
  printf 'pinned\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$parent
EOF
  FM_HOME="$mate" "$REPORT" "done" "$corr" "audit clean" \
    || fail "$REPORT failed writing a correlated report"
  helper_line=$(tail -1 "$state/pinned.status")
  status_line_at_epoch "$helper_line" >/dev/null || fail "report helper emitted no time"
  verb=$(status_line_verb "$helper_line")
  [ "$verb" = "done" ] \
    || fail "the classifier did not read through the helper's own line '$helper_line' (verb=[$verb])"
  status_is_terminal_verb "$helper_line" \
    || fail "the helper's own line is not seen as a terminal captain verb"

  FM_HOME="$mate" "$REPORT" --doc needs-decision "$corr" data/x/report.md "see the report" \
    || fail "$REPORT failed writing a correlated doc-pointer report"
  helper_line=$(tail -1 "$state/pinned.status")
  status_line_at_epoch "$helper_line" >/dev/null || fail "doc report helper emitted no time"
  verb=$(status_line_verb "$helper_line")
  [ "$verb" = needs-decision ] \
    || fail "the classifier did not read through the helper's doc line '$helper_line' (verb=[$verb])"

  pass "both real correlation-token writers produce lines this classifier reads through"
}

test_optional_event_time() {
  local line stamped epoch before after dir
  before=$(date +%s)
  line="needs-decision corr=$CORR [key=timed]: choose: A or B"
  stamped=$(status_stamp_line "$line") || fail "status writer could not stamp an event"
  after=$(date +%s)
  epoch=$(status_line_at_epoch "$stamped") || fail "new event has no emission time"
  [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ] || fail "event time is not append time"
  [ "$(status_line_verb "$stamped")" = needs-decision ] || fail "time changed verb"
  [ "$(_fm_decision_key "$stamped")" = timed ] || fail "time changed key"
  [ "$(status_line_note "$stamped")" = 'choose: A or B' ] || fail "time changed note"
  [ "$(status_stamp_line "$stamped")" = "$stamped" ] || fail "restamping changed emission time"
  line='done [at=1700000000]: old event'
  [ "$(status_stamp_line "$line")" = "$line" ] || fail "writer replaced an old emission time"
  (
    # shellcheck disable=SC2329 # status_stamp_line invokes this clock stub indirectly.
    date() { return 1; }
    [ "$(status_stamp_line 'done: clock unavailable')" = 'done: clock unavailable' ]
  ) || fail "clock failure lost the event"
  for line in 'done: legacy' 'done: [at=1700000000] prose' \
    'done [at=bad]: malformed' 'done [at=-1]: negative' \
    'done [at=01700000000]: noncanonical' 'done [at=99999999999999999999]: overflow' \
    'done [at=1] [at=2]: ambiguous'; do
    if status_line_at_epoch "$line" >/dev/null; then fail "invented time for $line"; fi
  done
  for line in "done [at=1700000000] [corr=$CORR]: finished" \
    "done [corr=$CORR] [at=1700000000]: finished"; do
    [ "$(status_line_at_epoch "$line")" = 1700000000 ] || fail "metadata order changed time"
  done
  dir=$(make_case event-time)
  # The real parent publisher deduplicates a retry against both timed and
  # legacy records without rewriting the first event's time.
  . "$ROOT/bin/fm-parent-channel-lib.sh"
  line="done [corr=$CORR]: path: C:\\notes"
  printf '%s\n' "$(status_stamp_line "$line")" > "$dir/state/retry.status"
  stamped=$(cat "$dir/state/retry.status")
  fm_parent_channel_append_once "$dir/state/retry.status" "$line" || fail "parent retry failed"
  [ "$(cat "$dir/state/retry.status")" = "$stamped" ] || fail "retry duplicated or restamped event"
  printf '%s\n' "$line" > "$dir/state/legacy.status"
  fm_parent_channel_append_once "$dir/state/legacy.status" "$line" || fail "legacy retry failed"
  [ "$(cat "$dir/state/legacy.status")" = "$line" ] || fail "legacy retry acquired an invented time"
  fm_parent_channel_append_once "$dir/state/retry.status" "done [corr=$CORR2]: path: C:\\notes"
  [ "$(wc -l < "$dir/state/retry.status")" -eq 2 ] || fail "dedup discarded different correlation"
  fm_parent_channel_append_once "$dir/state/retry.status" 'done: prose [at=1]'
  fm_parent_channel_append_once "$dir/state/retry.status" 'done: prose [at=2]'
  [ "$(wc -l < "$dir/state/retry.status")" -eq 4 ] || fail "dedup stripped a time mention from prose"
  stamped=$(status_stamp_line "needs-decision corr=$CORR [key=timed]: choose: A or B")
  printf '%s\n' "$stamped" 'working [at=1700000000]: unrelated progress' > "$dir/state/task.status"
  [ -n "$(status_open_decisions "$dir/state/task.status")" ] || fail "time cleared an open decision"
  printf '%s\n' 'resolved [at=1700000001] [key=timed]: answered' >> "$dir/state/task.status"
  [ -z "$(status_open_decisions "$dir/state/task.status")" ] || fail "timed resolution did not close decision"
  pass "optional event time preserves parsing and legacy unknown time"
}

test_captain_override_ignores_event_time() {
  local dir verb line event
  local FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'
  dir=$(make_case captain-override-time)
  for verb in done needs-decision blocked failed; do
    for line in "$verb: audit complete" "$verb [at=1700000000]: audit complete"; do
      status_is_captain_relevant "$line" || fail "override missed actionable event: $line"
      printf '%s\n' "$line" > "$dir/state/task.status"
      event=$(status_span_first_actionable "$dir/state/task.status" 0) \
        || fail "override hid actionable status span: $line"
      [ "$event" = "$line" ] || fail "classification changed surfaced event bytes: $event"
      [ "$(cat "$dir/state/task.status")" = "$line" ] || fail "classification rewrote stored event"
    done
  done
  FM_CAPTAIN_RE='done:'
  for line in 'blocked: waiting' 'blocked [at=1700000000]: waiting'; do
    status_is_captain_relevant "$line" && fail "override admitted excluded event: $line"
    printf '%s\n' "$line" > "$dir/state/task.status"
    status_span_has_actionable "$dir/state/task.status" 0 \
      && fail "override surfaced excluded event: $line"
  done
  for verb in working paused resolved captain-held; do
    for line in "$verb: done: mentioned" "$verb [at=1700000000]: done: mentioned"; do
      status_is_captain_relevant "$line" && fail "override bypassed nonterminal suppression: $line"
    done
  done
  FM_CAPTAIN_RE='^custom-verb: audit complete$'
  for line in 'custom-verb: audit complete' 'custom-verb [at=1700000000]: audit complete'; do
    status_is_captain_relevant "$line" || fail "timestamp broke custom verb override: $line"
  done
  FM_CAPTAIN_RE="^done \\[corr=$CORR\\]: literal \\[at=1700000000\\]$"
  for line in "done [corr=$CORR]: literal [at=1700000000]" \
    "done [at=1700000000] [corr=$CORR]: literal [at=1700000000]" \
    "done [corr=$CORR] [at=1700000000]: literal [at=1700000000]"; do
    status_is_captain_relevant "$line" || fail "normalization changed correlation metadata or note: $line"
  done
  pass "captain regex overrides preserve timed and legacy relevance and event bytes"
}

test_captain_override_ignores_event_time
test_optional_event_time
test_tokened_opener_opens_and_tokened_closer_closes
test_token_is_read_through_in_every_position_it_is_written_in
test_untokened_pair_is_unchanged
test_prose_and_malformed_tokens_never_become_transitions
test_token_first_word_never_impersonates_a_transition
test_captain_relevance_and_pause_are_unchanged_without_a_token
test_consumer_verdicts_read_through_the_token
test_daemon_and_crew_state_case_arms_read_through_the_token
test_pending_reply_escalation_matching_is_unaffected
test_incremental_and_whole_file_folds_agree_over_correlated_lines
test_a_cursor_written_before_this_change_is_rebuilt
test_the_real_writers_produce_tokens_this_library_reads
