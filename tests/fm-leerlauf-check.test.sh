#!/usr/bin/env bash
# tests/fm-leerlauf-check.test.sh - the Leerlauf-Waechter v2
# (bin/fm-leerlauf-check.sh): one NAMED reminder per idle officer home, sent
# once per post change, with no ladder and no hourly clock (Flottenordnung v2,
# L98; the abolished v1 ladder is regeln/ABGESCHAFFT.md
# `leerlauf-eskalationsleiter`).
#
# Red-green matrix: an unarmed gate reads nothing at all; ready==0 is silence;
# a home with a live worker is silence; ready>0 without a worker sends exactly
# ONE reminder naming the oldest post by id and title; the same oldest post is
# never reminded twice, while a CHANGED oldest post reminds again; a snooze
# skips the home; and a ready post without a v2 plan approval additionally
# wakes the firstmate on stdout, which a v=2 record silences.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-leerlauf-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-leerlauf-check-tests)

# One hermetic case: a firstmate home (state/, secondmates fixture, fakebin)
# plus one officer home whose ready group and post titles are canned files the
# fake tasks-axi reads from the cwd it is called in - which is exactly the
# officer home, because the script cds there before asking.
make_case() {  # <name> -> case-dir
  local dir=$1 fakebin
  dir=$TMP_ROOT/$1
  fakebin=$dir/fakebin
  mkdir -p "$dir/state" "$dir/heim/state" "$fakebin"

  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# Canned backlog of the home this is called in: ./ready.ids (one id per line,
# oldest first) and ./titles.tsv (<id>\t<title>).
set -u
case "${1:-}" in
  ready)
    n=$(grep -c . ./ready.ids 2>/dev/null || true)
    printf 'count: %s\n' "${n:-0}"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "${n:-0}"
    while IFS= read -r i; do
      [ -n "$i" ] || continue
      t=$(awk -F'\t' -v want="$i" '$1 == want { print $2 }' ./titles.tsv 2>/dev/null)
      printf '  %s,queued,task,"-","%s"\n' "$i" "$t"
    done < ./ready.ids
    exit 0
    ;;
  show)
    id=${2:-}
    t=$(awk -F'\t' -v want="$id" '$1 == want { print $2 }' ./titles.tsv 2>/dev/null)
    printf 'task:\n  id: %s\n  title: "%s"\n  state: queued\n' "$id" "$t"
    exit 0
    ;;
esac
exit 1
SH

  cat > "$fakebin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${2:-}" >> "${FM_LEERLAUF_SENT_LOG:?FM_LEERLAUF_SENT_LOG unset}"
exit 0
SH

  chmod +x "$fakebin/tasks-axi" "$fakebin/fm-send.sh"
  : > "$dir/heim/ready.ids"
  : > "$dir/heim/titles.tsv"
  printf -- '- sm-test - Zweiter Offizier fuer den Test (home: %s/heim; projects: x; added 2026-08-26)\n' \
    "$dir" > "$dir/secondmates.md"
  printf '%s\n' "$dir"
}

arm_gate() { : > "$1/state/.tor-leerlauf-mahnung-scharf"; }

# The officer home's ready group, oldest post first.
set_ready() {  # <case-dir> <id> <titel> [<id> <titel> ...]
  local dir=$1
  shift
  : > "$dir/heim/ready.ids"
  : > "$dir/heim/titles.tsv"
  while [ "$#" -ge 2 ]; do
    printf '%s\n' "$1" >> "$dir/heim/ready.ids"
    printf '%s\t%s\n' "$1" "$2" >> "$dir/heim/titles.tsv"
    shift 2
  done
}

sweep() {  # <case-dir>
  local dir=$1
  env \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_LEERLAUF_SECONDMATES="$dir/secondmates.md" \
    FM_LEERLAUF_SEND_BIN="$dir/fakebin/fm-send.sh" \
    FM_LEERLAUF_SENT_LOG="$dir/sent.log" \
    PATH="$dir/fakebin:$PATH" \
    "$CHECK" check
}

sent_count() { grep -c . "$1/sent.log" 2>/dev/null || true; }

test_unarmed_gate_reads_nothing() {
  local dir out
  dir=$(make_case tor-unscharf)
  set_ready "$dir" alt-posten "Etwas Bereites"

  out=$(sweep "$dir")
  [ -z "$out" ] || fail "the unarmed gate woke firstmate: $out"
  [ ! -s "$dir/sent.log" ] || fail "the unarmed gate sent a reminder: $(cat "$dir/sent.log")"
  [ ! -e "$dir/state/tor-log/leerlauf-mahnung.jsonl" ] ||
    fail "the unarmed gate read a home and logged, although it must read nothing at all"

  pass "without state/.tor-leerlauf-mahnung-scharf the watcher reads no home at all"
}

test_empty_home_is_silence() {
  local dir out
  dir=$(make_case ready-null)
  arm_gate "$dir"
  # ready == 0: a healthy empty home has nothing to dispatch and nothing to answer for.

  out=$(sweep "$dir")
  [ -z "$out" ] || fail "an empty home woke firstmate: $out"
  [ ! -s "$dir/sent.log" ] || fail "an empty home was nagged: $(cat "$dir/sent.log")"
  # An empty home is not this gate's subject at all, so it must not even appear
  # in the gate log - otherwise the healthy majority drowns the real decisions.
  [ ! -e "$dir/state/tor-log/leerlauf-mahnung.jsonl" ] ||
    fail "an empty home left a gate-log line: $(cat "$dir/state/tor-log/leerlauf-mahnung.jsonl")"

  pass "ready==0 is silence: a healthy empty home is never reminded and never logged"
}

test_working_home_is_silence() {
  local dir out
  dir=$(make_case heim-arbeitet)
  arm_gate "$dir"
  set_ready "$dir" alt-posten "Etwas Bereites"
  : > "$dir/heim/state/laufende-bahn.meta"   # a live worker answers for its own dispatch

  out=$(sweep "$dir")
  [ -z "$out" ] || fail "a working home woke firstmate: $out"
  [ ! -s "$dir/sent.log" ] || fail "a working home was reminded: $(cat "$dir/sent.log")"

  pass "a home with a live worker is not this gate's subject"
}

test_one_named_reminder_per_post() {
  local dir out sent
  dir=$(make_case mahnung-namentlich)
  arm_gate "$dir"
  set_ready "$dir" alt-posten "Aeltester bereiter Posten" jung-posten "Juengerer Posten"
  : > "$dir/heim/state/alt-posten.plan-approval"
  printf 'v=2\n' > "$dir/heim/state/alt-posten.plan-approval"

  out=$(sweep "$dir")
  [ -z "$out" ] ||
    fail "an approved post still woke firstmate about a missing Plan-Freigabe: $out"
  sent=$(cat "$dir/sent.log" 2>/dev/null || true)
  printf '%s\n' "$sent" | grep -q 'sm-test' || fail "the reminder did not reach the officer: $sent"
  printf '%s\n' "$sent" | grep -q 'dispatch alt-posten' ||
    fail "the reminder does not name the oldest post by id: $sent"
  printf '%s\n' "$sent" | grep -q 'Aeltester bereiter Posten' ||
    fail "the reminder does not carry the post's real title: $sent"
  printf '%s\n' "$sent" | grep -q 'jung-posten' &&
    fail "the reminder names a younger post instead of the oldest one: $sent"
  printf '%s\n' "$sent" | grep -q 'begruende per Status' ||
    fail "the reminder offers no second exit besides dispatch: $sent"
  grep -q '"tor":"leerlauf-mahnung".*"verdikt":"rot"' \
    "$dir/state/tor-log/leerlauf-mahnung.jsonl" ||
    fail "no rot Tor-Log line for the sent reminder"

  pass "ready work without a worker draws exactly one reminder naming the oldest post"
}

test_same_post_is_never_reminded_twice() {
  local dir
  dir=$(make_case eine-mahnung-je-posten)
  arm_gate "$dir"
  set_ready "$dir" alt-posten "Aeltester bereiter Posten"

  sweep "$dir" >/dev/null
  [ "$(sent_count "$dir")" = 1 ] || fail "the first sweep did not send exactly one reminder"
  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ "$(sent_count "$dir")" = 1 ] ||
    fail "the same oldest post was reminded again: $(cat "$dir/sent.log")"
  grep -q '"regel":"mahnung-bereits-erteilt".*"verdikt":"gruen"' \
    "$dir/state/tor-log/leerlauf-mahnung.jsonl" ||
    fail "the deliberate silence left no gruen Tor-Log line, so 'seen and left alone' and 'never looked' are indistinguishable"

  # A CHANGED oldest post is a new subject and draws its own single reminder.
  set_ready "$dir" neu-posten "Neuer aeltester Posten"
  sweep "$dir" >/dev/null
  [ "$(sent_count "$dir")" = 2 ] ||
    fail "a changed oldest post drew no fresh reminder: $(cat "$dir/sent.log")"
  grep -q 'dispatch neu-posten' "$dir/sent.log" ||
    fail "the second reminder does not name the new oldest post: $(cat "$dir/sent.log")"

  pass "one reminder per post change - repeats only when the oldest ready post changes"
}

test_snooze_skips_the_home() {
  local dir
  dir=$(make_case schlummer)
  arm_gate "$dir"
  set_ready "$dir" alt-posten "Aeltester bereiter Posten"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$dir/state/.leerlauf-snooze-sm-test"

  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "a snoozed home was reminded: $(cat "$dir/sent.log")"
  [ ! -e "$dir/state/.leerlauf-posten-sm-test" ] ||
    fail "a snoozed home kept a remembered post, so the first sweep after the snooze would stay silent"

  # An EXPIRED snooze must let the reminder through again.
  printf '%s\n' "$(( $(date +%s) - 60 ))" > "$dir/state/.leerlauf-snooze-sm-test"
  sweep "$dir" >/dev/null
  [ "$(sent_count "$dir")" = 1 ] ||
    fail "an expired snooze did not release the reminder: $(cat "$dir/sent.log")"

  pass "a future .leerlauf-snooze-<sm> epoch skips the home; an expired one releases it"
}

test_missing_v2_approval_wakes_firstmate() {
  local dir out
  dir=$(make_case ohne-plan-freigabe)
  arm_gate "$dir"
  set_ready "$dir" alt-posten "Aeltester bereiter Posten"
  # A v1 record predates the 5-question Freigabenotiz and is exactly the Bestand
  # this transition rule is about - it must NOT count as an approval.
  printf 'v=1\n' > "$dir/heim/state/alt-posten.plan-approval"

  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q 'ohne Plan-Freigabe' ||
    fail "a ready post without a v2 approval did not wake firstmate: $out"
  printf '%s\n' "$out" | grep -q 'Firstmate schuldet die Freigabe' ||
    fail "the wake does not name whose debt this is: $out"
  printf '%s\n' "$out" | grep -q 'alt-posten' || fail "the wake does not name the post: $out"
  printf '%s\n' "$out" | grep -q 'Ausweg:' || fail "the wake offers no exit: $out"
  grep -q '"regel":"ohne-plan-freigabe".*"verdikt":"rot"' \
    "$dir/state/tor-log/leerlauf-mahnung.jsonl" ||
    fail "no rot Tor-Log line for the missing plan approval"
  # The officer still gets his one reminder; the debt is named on top of it.
  [ "$(sent_count "$dir")" = 1 ] || fail "the officer reminder was swallowed by the firstmate wake"

  pass "a ready post without a v2 approval wakes the firstmate too, naming his own debt"
}

for t in \
  test_unarmed_gate_reads_nothing \
  test_empty_home_is_silence \
  test_working_home_is_silence \
  test_one_named_reminder_per_post \
  test_same_post_is_never_reminded_twice \
  test_snooze_skips_the_home \
  test_missing_v2_approval_wakes_firstmate; do
  "$t"
done
