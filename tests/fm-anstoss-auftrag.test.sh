#!/usr/bin/env bash
# tests/fm-anstoss-auftrag.test.sh - the work-without-an-order class of the
# Anstoss-Automat (bin/fm-anstoss-auftrag-lib.sh, hooked into
# bin/fm-anstoss.sh): a LIVE lane must be able to name the commissioned post it
# works on (Flottenordnung v2, L98).
#
# Red-green matrix: armed gate + v2 meta without a post reference REPORTS (and
# never types); the same lane with the gate unarmed stays silent; a v2 lane
# whose brief carries an Order-Bezug line, and a lane whose post is in_flight,
# stay silent; a Bestand lane (meta without account=) is never alarmed and
# produces exactly ONE inventory line; the report repeats only after its own
# spacing interval; and the stage-2 fingerprint changes when the backlog post
# state changes underneath an otherwise identical pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANSTOSS="$ROOT/bin/fm-anstoss.sh"
TMP_ROOT=$(fm_test_tmproot fm-anstoss-auftrag-tests)

# One hermetic case: state dir plus fake tmux/ps/tasks-axi/fm-send, all reading
# canned answers from files under the case dir (same fake world as
# tests/fm-anstoss.test.sh, trimmed to what this class needs).
make_case() {  # <name> -> case-dir
  local name=$1 dir fakebin
  dir=$TMP_ROOT/$name
  fakebin=$dir/fakebin
  mkdir -p "$dir/state" "$dir/data" "$fakebin"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "${FM_FAKE_TMUX_WINDOWS:-/dev/null}" 2>/dev/null; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_tty*) printf '%s\n' "${FM_FAKE_TMUX_TTY:-/dev/pts/42}"; exit 0 ;;
        *pane_current_command*)
          cmd=$(awk '$2 == $3 { print $4 }' "$(dirname "$0")/ps.table" 2>/dev/null | head -1)
          printf '%s\n' "${cmd:-claude1}"; exit 0 ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    exit 0 ;;
esac
exit 1
SH

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
prev=""
pid=""
for a in "$@"; do
  case "$a" in
    time=*) cat "$here/cputime.txt" 2>/dev/null; exit 0 ;;
    -o) ;;
    -p) ;;
    args=)
      printf '/bin/%s\n' "$(awk -v p="$pid" '$1 == p { print $4 }' "$here/ps.table" 2>/dev/null)"
      exit 0 ;;
    *comm=* | *pgid=*) cat "$here/ps.table" 2>/dev/null; exit 0 ;;
    *) [ -z "$prev" ] || [ "$prev" = "-p" ] && pid=$a ;;
  esac
  prev=$a
done
exit 1
SH

  printf '%s\n' '100 100 100 claude1' > "$fakebin/ps.table"
  printf '0:10\n' > "$fakebin/cputime.txt"

  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# canned backlog: lines "<id> <state>" in $FAKE_AXI_STATES
set -u
if [ "${1:-}" = show ]; then
  id=${2:-}
  state=$(awk -v i="$id" '$1 == i { print $2 }' "${FAKE_AXI_STATES:-/dev/null}" 2>/dev/null)
  printf 'task:\n  id: %s\n  state: %s\n' "$id" "${state:-none}"
  exit 0
fi
exit 1
SH

  cat > "$fakebin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${2:-}" >> "${FM_ANSTOSS_SENT_LOG:?FM_ANSTOSS_SENT_LOG unset}"
exit 0
SH

  chmod +x "$fakebin"/tmux "$fakebin"/ps "$fakebin"/tasks-axi "$fakebin"/fm-send.sh
  : > "$dir/axi.states"
  : > "$dir/windows.txt"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  printf '%s\n' "$dir"
}

arm_gate() { : > "$1/state/.tor-arbeit-ohne-auftrag-scharf"; }

# A lane that is alive and idle at its endpoint. <extra...> become further meta
# lines, which is how a v2 spawn's account=/spawn_gen= fields enter the fixture.
write_lane() {  # <case-dir> <id> [extra-meta-line...]
  local dir=$1 id=$2
  shift 2
  fm_write_meta "$dir/state/$id.meta" \
    "window=test:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=/nonexistent-$id" \
    "project=/nonexistent" \
    "harness=claude-ox" \
    "kind=ship" \
    "$@"
  printf 'fm-%s\n' "$id" >> "$dir/windows.txt"
  : > "$dir/state/$id.status"
}

write_brief() {  # <case-dir> <id> <order-bezug-value>
  local dir=$1 id=$2 value=$3
  mkdir -p "$dir/data/$id"
  {
    printf '# Brief %s\n' "$id"
    printf 'Order-Bezug: %s\n' "$value"
    printf '\nAuftrag: irgendetwas\n'
  } > "$dir/data/$id/brief.md"
}

sweep() {  # <case-dir> [ENV=v ...]
  local dir=$1
  shift
  env \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_ANSTOSS_SEND_BIN="$dir/fakebin/fm-send.sh" \
    FM_ANSTOSS_SENT_LOG="$dir/sent.log" \
    FAKE_AXI_STATES="$dir/axi.states" \
    FM_FAKE_TMUX_WINDOWS="$dir/windows.txt" \
    FM_FAKE_TMUX_CAPTURE="$dir/capture.txt" \
    PATH="$dir/fakebin:$PATH" \
    "$@" \
    "$ANSTOSS" check
}

test_v2_lane_without_post_is_reported_never_nudged() {
  local dir id=ohneauftrag out
  dir=$(make_case v2-ohne-posten)
  arm_gate "$dir"
  write_lane "$dir" "$id" "account=/home/x/.claude2" "spawn_gen=2"
  printf '%s queued\n' "$id" >> "$dir/axi.states"   # commissioned nowhere

  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q "arbeitet ohne Auftrag" ||
    fail "a v2 lane without a post reference did not wake firstmate: $out"
  printf '%s\n' "$out" | grep -q "$id" || fail "the report does not name the lane: $out"
  printf '%s\n' "$out" | grep -q "Flottenordnung v2" || fail "the report names no source: $out"
  printf '%s\n' "$out" | grep -q "Auswege:" || fail "the report offers no exit: $out"
  [ ! -s "$dir/sent.log" ] || fail "the lane was nudged: $(cat "$dir/sent.log")"
  [ "$(cat "$dir/state/.anstoss-auftrag-$id")" = 1 ] || fail "the report counter is not 1"
  grep -q "id=$id .*state=idle-ohne-auftrag .*action=gemeldet" "$dir/state/.anstoss-check.log" ||
    fail "check log lacks the report line: $(cat "$dir/state/.anstoss-check.log")"
  grep -q '"tor":"arbeit-ohne-auftrag".*"verdikt":"rot"' \
    "$dir/state/tor-log/arbeit-ohne-auftrag.jsonl" ||
    fail "no rot Tor-Log line for the raised alarm"

  pass "a v2 lane without a post reference is reported to firstmate and never nudged"
}

test_unarmed_gate_passes_silently() {
  local dir id=unscharf out
  dir=$(make_case v2-tor-unscharf)
  write_lane "$dir" "$id" "account=/home/x/.claude2" "spawn_gen=2"
  printf '%s queued\n' "$id" >> "$dir/axi.states"

  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q "ohne Auftrag" &&
    fail "the unarmed gate raised an alarm anyway: $out"
  [ ! -e "$dir/state/.anstoss-auftrag-$id" ] || fail "the unarmed gate advanced its counter"
  grep -q '"verdikt":"gruen".*"ausweg":"tor-nicht-scharf"' \
    "$dir/state/tor-log/arbeit-ohne-auftrag.jsonl" ||
    fail "the withheld alarm left no gruen Tor-Log line, so 'off' and 'never looked' are indistinguishable"

  pass "without state/.tor-arbeit-ohne-auftrag-scharf the class passes silently but visibly"
}

test_brief_order_bezug_satisfies_the_class() {
  local dir id=mitbrief out
  dir=$(make_case v2-mit-order-bezug)
  arm_gate "$dir"
  write_lane "$dir" "$id" "account=/home/x/.claude2" "spawn_gen=2"
  printf '%s queued\n' "$id" >> "$dir/axi.states"
  write_brief "$dir" "$id" "O-0083 (Kontobindung)"

  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q "ohne Auftrag" &&
    fail "a brief with an Order-Bezug line was alarmed anyway: $out"
  [ ! -s "$dir/sent.log" ] || fail "the lane was nudged"

  # An EMPTY Order-Bezug value answers nothing and must not satisfy the class.
  write_brief "$dir" "$id" ""
  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q "arbeitet ohne Auftrag" ||
    fail "an empty Order-Bezug value was accepted as a post reference: $out"

  pass "a brief's Order-Bezug line satisfies the class; an empty value does not"
}

test_in_flight_post_satisfies_the_class() {
  local dir id=inflight out
  dir=$(make_case v2-in-flight)
  arm_gate "$dir"
  write_lane "$dir" "$id" "account=/home/x/.claude2" "spawn_gen=2"
  printf '%s in_flight\n' "$id" >> "$dir/axi.states"

  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q "ohne Auftrag" &&
    fail "an in_flight post was alarmed anyway: $out"
  [ ! -e "$dir/state/.anstoss-auftrag-$id" ] || fail "an in_flight post advanced the report counter"

  pass "a lane whose backlog post is in_flight carries its order and is never alarmed"
}

test_bestand_lane_is_inventoried_once_not_alarmed() {
  local dir id=bestand out
  dir=$(make_case bestand-lane)
  arm_gate "$dir"
  write_lane "$dir" "$id"                      # no account= -> pre-v2 spawn
  printf '%s queued\n' "$id" >> "$dir/axi.states"

  out=$(sweep "$dir")
  printf '%s\n' "$out" | grep -q "ohne Auftrag" &&
    fail "a Bestand lane was alarmed although the transition rule exempts it: $out"
  [ ! -s "$dir/sent.log" ] || fail "a Bestand lane was nudged"
  [ "$(grep -c "action=inventur" "$dir/state/.anstoss-check.log")" = 1 ] ||
    fail "the Bestand lane did not leave exactly one inventory line: $(cat "$dir/state/.anstoss-check.log")"

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ "$(grep -c "action=inventur" "$dir/state/.anstoss-check.log")" = 1 ] ||
    fail "the inventory line repeated on later sweeps"

  pass "a Bestand lane (meta without account=) is inventoried exactly once and never alarmed"
}

test_report_repeats_only_after_its_own_spacing() {
  local dir id=takt out
  dir=$(make_case report-spacing)
  arm_gate "$dir"
  write_lane "$dir" "$id" "account=/home/x/.claude2" "spawn_gen=2"
  printf '%s queued\n' "$id" >> "$dir/axi.states"

  sweep "$dir" >/dev/null                       # report #1
  out=$(sweep "$dir")                           # too soon
  [ -z "$out" ] || fail "the report repeated before its spacing interval passed: $out"
  grep -Eq "id=$id .*action=uebersprungen .*reason=spacing-wait-[0-9]+s<600s" \
    "$dir/state/.anstoss-check.log" ||
    fail "the withheld repeat is not shown waiting on its own clock"

  sleep 1.1
  out=$(sweep "$dir" FM_ANSTOSS_INTERVAL=1)
  printf '%s\n' "$out" | grep -q "2. Meldung" ||
    fail "the report did not repeat once its interval had passed: $out"

  pass "the report class repeats once per interval, counting its own reports"
}

# The stage-2 fingerprint must notice a post that moved underneath an otherwise
# byte-identical pane, so an escalation is never raised against a stale premise.
test_fingerprint_covers_the_backlog_post_state() {
  local a b
  a=$(bash -c ". '$ANSTOSS' --help >/dev/null 2>&1; situation_fingerprint 'status' 'pane' in_flight")
  b=$(bash -c ". '$ANSTOSS' --help >/dev/null 2>&1; situation_fingerprint 'status' 'pane' done")
  [ -n "$a" ] || fail "the fingerprint function produced nothing"
  [ "$a" != "$b" ] ||
    fail "the fingerprint ignores the backlog post state, so a moved post reads as an unchanged situation"

  pass "the stage-2 fingerprint covers the backlog post state"
}

for t in \
  test_v2_lane_without_post_is_reported_never_nudged \
  test_unarmed_gate_passes_silently \
  test_brief_order_bezug_satisfies_the_class \
  test_in_flight_post_satisfies_the_class \
  test_bestand_lane_is_inventoried_once_not_alarmed \
  test_report_repeats_only_after_its_own_spacing \
  test_fingerprint_covers_the_backlog_post_state; do
  "$t"
done
