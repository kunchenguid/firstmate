#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

for tool in python3 node jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

TMP_ROOT=$(fm_test_tmproot fm-status-nonstate-note)
WARNING='note [state=none] [at=1700000100]: warning: exclusion not in effect: mcp__late__tool'

append_warnings() {
  local count=0
  while [ "$count" -lt 210 ]; do
    printf '%s\n' "$WARNING"
    count=$((count + 1))
  done >> "$1"
}

test_voice_state_selection() {
  python3 - "$ROOT" "$TMP_ROOT/voice" <<'PY' || fail "voice status selected a non-state note"
import json
import os
from pathlib import Path
import subprocess
import sys

root, home = map(Path, sys.argv[1:])
for directory in ("data", "state", "config"):
    (home / directory).mkdir(parents=True)
(home / "data/backlog.md").write_text("## In flight\n- [ ] worker - Task (kind: scout)\n")
(home / "state/worker.meta").write_text("kind=scout\nmode=scout\n")
warning = "note [state=none] [at=1700000100]: warning: exclusion not in effect: mcp__late__tool\n"
env = dict(os.environ, FM_STATE_OVERRIDE=str(home / "state"),
           FM_DATA_OVERRIDE=str(home / "data"), FM_CONFIG_OVERRIDE=str(home / "config"))


def status(scope="counts"):
    return json.loads(subprocess.check_output([
        sys.executable, str(root / "bin/fm_voice_records.py"), "status",
        "--home", str(home), "--scope", scope,
    ], env=env))


cases = [(f"{verb}: declared\n", verb) for verb in (
    "working", "needs-decision", "blocked", "paused", "done", "failed",
    "resolved", "captain-held", "note",
)]
cases += [
    ("", "no events yet"),
    ("Human continuation prose\n", "note"),
    ("done: complete\nnote: ordinary note\n", "note"),
    ("done: complete\nnote: body mentions [state=none]\n", "note"),
    ("done: complete\nnote [state=other]: ordinary note\n", "note"),
    ("done: complete\nnote [state=none]extra: ordinary note\n", "note"),
    ("done: complete\nnote[state=none]: ordinary note\n", "note"),
    ("working [state=none]: still working\n", "working"),
    ("done: complete\nunknown [state=none]: unknown state\n", "note"),
]
for declaration, expected in cases:
    for suffix in (warning, warning * 210):
        (home / "state/worker.status").write_text(declaration + suffix)
        for scope in ("counts", "full"):
            answer = status(scope)
            assert answer["worker_states"] == {expected: 1}, (declaration, scope, answer)
            if scope == "full":
                assert answer["in_flight_detail"][0]["state"] == expected, answer

for note in (
    "note [state=none]: warning\n",
    "  note [at=1700000100] [state=none]: warning\n",
    "note corr=0123456789ABCDEF [state=none]: warning\n",
    "note [state=none]\n",
):
    (home / "state/worker.status").write_text("done: complete\n" + note)
    answer = status()
    assert answer["worker_states"] == {"done": 1}, (note, answer)

(home / "state/worker.status").write_text(warning + "done: complete\n")
answer = status()
assert answer["worker_states"] == {"done": 1}, answer
PY
  pass "voice counts and full task states ignore non-state notes, including tail and fallback reads"
}

test_shared_state_readers() {
  local log="$TMP_ROOT/shared.status" declaration expected last previous endpoint ident event_end
  for declaration in \
    'working: progressing' 'needs-decision [key=shape]: choose a shape' \
    'blocked [key=access]: waiting for access' 'paused [key=release]: waiting for release' \
    'done: completed task' 'failed: stopped' 'resolved [key=shape]: answered' \
    'captain-held [key=shape]: transferred' 'note: ordinary state note' \
    'Human continuation prose' ''; do
    printf '%s\n' "$declaration" > "$log"
    event_end=$(_fm_status_file_size "$log")
    append_warnings "$log"
    expected=$declaration
    last=$(last_status_line "$log" previous)
    [ "$last" = "$expected" ] || fail "shared latest-event read replaced $declaration: $last"
    [ "$(status_current_line "$log" scout)" = "$expected" ] \
      || fail "shared current-state read replaced $declaration"
    endpoint=$(_fm_status_file_size "$log")
    ident=$(_fm_open_decisions_file_ident "$log")
    if [ -n "$declaration" ]; then
      status_snapshot_latest_event "$log" "$endpoint" "$ident" \
        || fail "captured latest-event read lost $declaration"
      [ "$FM_STATUS_SNAPSHOT_EVENT_LINE" = "$expected" ] \
        || fail "captured latest-event read selected a warning"
      [ "$FM_STATUS_SNAPSHOT_EVENT_ENDPOINT" = "$event_end" ] \
        || fail "captured latest-event read lost the original event byte offset"
    else
      if status_snapshot_latest_event "$log" "$endpoint" "$ident"; then
        fail "captured latest-event read selected a warning without any state"
      fi
    fi
  done
  for last in 'note [state=none]: warning' 'note [at=1700000100] [state=none]: warning' \
    'note corr=0123456789ABCDEF [state=none]: warning' 'note [state=none]'; do
    printf 'done: completed task\n%s' "$last" > "$log"
    endpoint=$(_fm_status_file_size "$log")
    ident=$(_fm_open_decisions_file_ident "$log")
    status_snapshot_latest_event "$log" "$endpoint" "$ident" \
      || fail "captured latest-event read lost completion before $last"
    [ "$FM_STATUS_SNAPSHOT_EVENT_LINE" = 'done: completed task' ] \
      || fail "captured latest-event read disagrees with non-state note grammar: $last"
  done
  printf 'working: previous\ndone: completed task\n' > "$log"
  append_warnings "$log"
  last_status_line "$log" previous >/dev/null
  [ "$previous" = 'working: previous' ] || fail "warning replaced the previous event"
  printf 'paused [key=release]: waiting for release\nresolved [key=shape]: answered\n' > "$log"
  append_warnings "$log"
  [ "$(status_declared_wait_line "$log")" = 'paused [key=release]: waiting for release' ] \
    || fail "warning ended a declared wait during a reverse scan"
  fm_write_meta "$TMP_ROOT/shared.meta" window=firstmate:fm-shared kind=scout
  printf 'done: completed task\n' > "$log"
  append_warnings "$log"
  stale_is_terminal firstmate:fm-shared "$TMP_ROOT" || fail "warning changed terminal wake classification"
  status_line_is_unread_surface "$WARNING" || fail "non-state warnings must remain readable as informational events"
  pass "shared crew-state and wake readers preserve declarations and unread warning presentation"
}

test_fleet_inbox_and_bearings() (
  local home="$TMP_ROOT/fleet" fakebin declaration expected out inbox crew before
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/task"
  fakebin=$(fm_fakebin "$home")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/no-mistakes"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-worker\n' ;;
  display-message) printf 'claude\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  export PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"
  export FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config"
  : > "$home/config/supervision-host-off"
  printf '## In flight\n- [ ] worker - Task (kind: scout)\n' > "$home/data/backlog.md"
  fm_write_meta "$home/state/worker.meta" kind=scout mode=scout harness=claude \
    "worktree=$home/projects/task" window=firstmate:fm-worker project=task
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" worker)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" worker idle --gen "$gen" \
    --source claude-hook --event stop || fail "could not seed idle worker"
  for declaration in 'done [at=1700000000]: completed task' 'note: ordinary state note' ''; do
    printf '%s\n' "$declaration" > "$home/state/worker.status"
    before=$("$ROOT/bin/fm-crew-state.sh" worker) || fail "crew-state baseline failed"
    append_warnings "$home/state/worker.status"
    out=$(FM_SNAPSHOT_NOW_EPOCH=1700000200 "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
      || fail "fleet snapshot failed"
    expected=$(status_line_verb "$declaration")
    printf '%s' "$out" | jq -e --arg state "$expected" --arg raw "$declaration" '
      .tasks[] | select(.id == "worker") | .paths.status_log.last_event
      | .state == $state and .raw == $raw
        and .age_seconds == (if $state == "done" then 200 else null end)
    ' >/dev/null || fail "fleet event history selected a warning: $out"
    crew=$("$ROOT/bin/fm-crew-state.sh" worker) || fail "crew-state failed"
    [ "$crew" = "$before" ] || fail "warning changed reconciled crew state: $before -> $crew"
    inbox=$("$ROOT/bin/fm-inbox.sh" status) || fail "inbox status failed"
    assert_not_contains "$inbox" 'exclusion not in effect' "inbox latest event must not be a warning"
    assert_contains "$inbox" "${declaration:-(no events yet)}" "inbox must preserve its prior event or absence"
    if [ "$expected" = "done" ]; then
      assert_contains "$crew" 'state: done' "idle scout must remain done"
      out=$(FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err") \
        || fail "wake drain failed"
      assert_contains "$out" 'STATUS OUTCOME BACKSTOP (' "wake drain must recover the completion behind warnings"
      assert_contains "$out" 'worker done [at=1700000000]: completed task' "wake drain must surface the original completion"
      assert_contains "$out" "$WARNING" "wake drain must still present unread warnings"
      append_warnings "$home/state/worker.status"
      out=$(FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err") \
        || fail "second wake drain failed"
      assert_not_contains "$out" 'STATUS OUTCOME BACKSTOP (' "later warnings must not replay a handled completion"
      out=$("$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "bearings failed"
      printf '%s' "$out" | jq -e '
        .in_flight[] | select(.id == "worker") | .state == "done" and .doing == "completed task"
      ' >/dev/null || fail "bearings replaced the worker state or activity: $out"
    fi
  done
  pass "fleet, inbox, crew-state and bearings retain worker state after late warnings"
)

test_pi_wake_routing() {
  ROOT="$ROOT" CASE_ROOT="$TMP_ROOT/pi" node --input-type=module <<'JS' \
    || fail "Pi wake routing let a warning replace captain-held state"
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { scopeForUnreadWake, branchOfferForWake } = await import(
  pathToFileURL(`${process.env.ROOT}/.pi/extensions/lib/fm-branch-dispatch.ts`).href
);
const state = `${process.env.CASE_ROOT}/state`;
mkdirSync(state, { recursive: true });
writeFileSync(`${state}/worker.meta`, "project=task\nkind=scout\nwindow=firstmate:fm-worker\n");
const warning = "note [state=none] [at=1700000100]: warning: exclusion not in effect: mcp__late__tool\n";
for (const kind of ["stale", "signal"]) {
  const key = kind === "stale" ? "firstmate:fm-worker" : "worker.status";
  writeFileSync(`${state}/.wake-queue`, `1700000200\t1\t${kind}\t${key}\ttest\n`);
  for (const [declaration, mainOwned] of [
    ["captain-held [key=shape]: transferred\n", true],
    ["needs-decision [key=shape]: choose\n", true],
    ["done: complete\n", false],
    ["", false],
    ["captain-held [key=shape]: transferred\nnote: ordinary state note\n", false],
    ["captain-held [key=shape]: transferred\nnote: body mentions [state=none]\n", false],
  ]) {
    for (const suffix of ["", warning, warning.repeat(210), "note corr=0123456789abcdef [state=none]: warning\n"]) {
      writeFileSync(`${state}/worker.status`, declaration + suffix);
      for (const attendedHost of [false, true]) {
        if (kind === "signal" && !attendedHost) continue;
        const scope = scopeForUnreadWake(state, false, false, attendedHost);
        assert.equal(scope.needsDecisionKeys.includes(key), mainOwned, `${kind}: ${declaration}`);
        assert.equal(scope.eligible, !mainOwned, `${kind}: ${declaration}`);
        assert.equal(branchOfferForWake(state, `${kind}: ${key}`, false, attendedHost).eligible, !mainOwned);
        assert.equal(scopeForUnreadWake(state, false, true, attendedHost).eligible, true);
      }
    }
  }
}
writeFileSync(`${state}/worker.meta`, "project=task\nkind=secondmate\nwindow=firstmate:fm-worker\n");
writeFileSync(`${state}/.wake-queue`, "1700000200\t1\tsignal\tworker.status\ttest\n");
for (const [declaration, mainOwned] of [["captain-held [key=shape]: transferred\n", true], ["done: complete\n", false], ["", false]]) {
  writeFileSync(`${state}/worker.status`, declaration + warning);
  for (const attendedHost of [false, true]) {
    assert.equal(scopeForUnreadWake(state, false, false, attendedHost).eligible, !mainOwned);
  }
}
JS
  pass "Pi and attended-host wake routing ignore non-state notes while preserving ordinary notes"
}

fm_test_run test_voice_state_selection test_shared_state_readers test_fleet_inbox_and_bearings test_pi_wake_routing
