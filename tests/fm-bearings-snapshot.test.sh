#!/usr/bin/env bash
# Behavior tests for the bearings projection wrapper over fm-fleet-snapshot.sh.
# Covers the output/token bound, TOON/JSON parity, the local-only default (zero
# GitHub/network calls), the --include-prs opt-in path, graceful degradation on a
# partial PR-fetch failure, end-to-end unresolved-decision durability, and current
# report pointers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings)
# Keep disposable homes outside the snapshot's fixture repo boundary even when
# TMPDIR is inside an isolated source worktree.
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fakebin that stubs the local tools the canonical snapshot may reach for, plus a
# gh/gh-axi that RECORDS every call to $NET_LOG so a test can prove the default path
# makes no network call. gh returns one fixture open PR keyed to the ship task.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_NM_SLEEP:-0}" = 1 ] && sleep 30
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane)
    case "$*" in
      *fm-domain-alpha*) printf 'stale terminal summary: Phase 7 started\n> \n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "${FAKE_GH_SLEEP:-0}" = 1 ]; then sleep 30; fi
if [ "${FAKE_GH_MANY:-0}" = 1 ]; then
  cat <<'JSON'
[{"number":1,"title":"One","url":"https://github.com/acme/repo/pull/1","headRefName":"fm/one","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"Two","url":"https://github.com/acme/repo/pull/2","headRefName":"fm/two","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":3,"title":"Three","url":"https://github.com/acme/repo/pull/3","headRefName":"fm/three","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]
JSON
  exit 0
fi
cat <<'JSON'
[{"number":9,"title":"Ship the thing","url":"https://github.com/kunchenguid/firstmate/pull/9","headRefName":"fm/ship-task","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]
JSON
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
[ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi" "$fb/curl"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 semantic_state=$3 gen event
  case "$semantic_state" in
    busy) event=user-prompt-submit ;;
    idle) event=stop ;;
    *) fail "unsupported semantic fixture state: $semantic_state" ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$semantic_state" --gen "$gen" \
    --source claude-hook --event "$event"
}

fixture_mate_home() {  # <parent-home>
  printf '%s/%s-secondmate-home\n' "$TMP_ROOT" "$(basename "$1")"
}

# Standard fixture: a ship task with a recorded PR, a scout task with a report, a
# secondmate with a MASKED open decision (needs-decision then a later unrelated
# done), and a backlog with a superseded queued item.
write_fixture() {  # <home>
  local home=$1 mate
  mate=$(fixture_mate_home "$home")
  mkdir -p "$home/projects/ship-wt" "$home/data/scout-x" "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-11)\n' \
    "$mate" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] scout-x - Investigate the thing data/scout-x/report.md (repo: firstmate) (kind: scout) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] dead-gate - Old conditional work (repo: firstmate) (kind: scout)
  NOT REQUIRED - superseded 2026-07-11; kept as reference only.

## Done
- [x] done-a - Landed thing https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  printf '# Scout X\n' > "$home/data/scout-x/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  record_claude_state "$home/state" ship-task busy
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-x.meta" \
    "window=firstmate:fm-scout-x" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_state "$home/state" scout-x idle
  printf 'done: report ready\n' > "$home/state/scout-x.status"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$mate" \
    "project=$mate" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$mate" \
    "projects=firstmate"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$home/state/mate.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/mate.status"
  fm_write_meta "$home/state/external-wait.meta" \
    "window=firstmate:fm-external-wait" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_state "$home/state" external-wait idle
  printf 'paused: declared external-wait for upstream release\n' > "$home/state/external-wait.status"
  # The secondmate's OWN home backlog records a merge it managed. This lands in the
  # secondmate home, never the main backlog, so landed-work views only see it via the
  # bounded cross-home Done roll-up.
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Decide subscription order (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] mate-decision-race - Choose subscription order (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] mate-landed - Secondmate-managed fix https://github.com/kunchenguid/firstmate/pull/50 (repo: firstmate) (kind: ship) (merged 2026-07-11)
EOF
  mkdir -p "$mate/projects/mate"
  fm_write_meta "$mate/state/mate.meta" \
    "window=firstmate:fm-mate" "worktree=$mate/projects/mate" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" mate idle
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$mate/state/mate.status"
}

refresh_local_secondmate_ledgers() {  # <parent-home>
  local parent=$1 registry line mate refresh_path=$PATH
  registry="$parent/data/secondmates.md"
  [ -f "$registry" ] && [ -r "$registry" ] || return 0
  # Once this fixture's fake backend exists, ledger production must use it too;
  # otherwise child state depends on whether the CI host has a live tmux server.
  [ ! -x "$parent/fakebin/tmux" ] || refresh_path="$parent/fakebin:$refresh_path"
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
    mate=$SECONDMATE_REGISTRY_HOME
    [ -f "$mate/.fm-secondmate-home" ] && [ -f "$mate/AGENTS.md" ] \
      && [ -d "$mate/bin" ] && [ -d "$mate/data" ] && [ -d "$mate/state" ] || continue
    PATH="$refresh_path" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1783792800 \
      "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null 2>&1 || true
  done < "$registry"
}

run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  case " $* " in
    *" --all-landed "*) PATH="$fakebin:$PATH" FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 refresh_local_secondmate_ledgers "$home" ;;
    *) PATH="$fakebin:$PATH" refresh_local_secondmate_ledgers "$home" ;;
  esac
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" "$BEARINGS" "$@"
}

write_remote_home_summary() {  # <remote-home> <generated-epoch>
  local home=$1 epoch=$2
  mkdir -p "$home/state"
  jq -n --arg home "$home" --argjson epoch "$epoch" '{
    schema:"fm-secondmate-home-summary.v1",
    generated:"2026-09-01T22:00:00Z",generated_epoch:$epoch,home:$home,
    valid:true,reason:null,invalidity:{kind:null,ids:[]},state:"no_active_work",
    active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[]
  }' > "$home/state/home-summary.json"
}

make_remote_ledger_fleet() {  # <parent-home> <count>
  local parent=$1 count=$2 i id remote_home
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$parent/projects"
  : > "$parent/data/backlog.md"
  : > "$parent/data/secondmates.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="ledger-$i"
    remote_home="$TMP_ROOT/remote-ledger-home-$i"
    mkdir -p "$remote_home/state"
    remote_home=$(cd "$remote_home" && pwd -P)
    printf -- '- %s - ledger fixture (host: host-%s; root: /remote/root; home: %s; scope: fixture; projects: sample; added 2026-09-01)\n' \
      "$id" "$i" "$remote_home" >> "$parent/data/secondmates.md"
    fm_write_meta "$parent/state/$id.meta" \
      "kind=secondmate" "mode=secondmate" "harness=pi" \
      "remote_host=host-$i" "remote_root=/remote/root" "home=$remote_home"
    write_remote_home_summary "$remote_home" 1000
    i=$((i + 1))
  done
}

make_remote_ledger_ssh() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$3")
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$4")
printf '%s\t%s\n' "$remote_home" "${args[0]:-}" >> "$FM_TEST_LEDGER_CALL_LOG"
if [ -f "$remote_home/state/slow-ledger-read" ]; then
  sleep 30 &
  sleeper=$!
  printf '%s %s\n' "$$" "$sleeper" >> "$FM_TEST_LEDGER_PID_LOG"
  wait "$sleeper"
fi
case "${args[0]:-}" in
  fm-remote-file.sh)
    [ -f "$remote_home/state/home-summary.json" ] || exit 1
    if [ -f "$remote_home/state/unbounded-ledger-read" ]; then
      yes x
    else
      cat "$remote_home/state/home-summary.json"
    fi
    ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

run_remote_ledger_bearings() {  # <parent-home> <fakebin> <epoch>
  local parent=$1 fakebin=$2 epoch=$3
  FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_TEST_LEDGER_CALL_LOG="$parent/ledger-calls.log" \
    FM_TEST_LEDGER_PID_LOG="$parent/ledger-pids.log" \
    FM_SNAPSHOT_CACHE_DIR="$parent/state/summary-cache" \
    FM_SNAPSHOT_BUDGET=3 FM_SNAPSHOT_NOW_EPOCH="$epoch" \
    FM_BEARINGS_NOW=2026-09-01T22:00:00Z "$BEARINGS" --json
}

# End-to-end Domain Alpha regression fixture.
# The parent event claims Phase 7 started, while the registered home has no child
# metadata, every sample-rollout item is Done, and only an external legal hold remains.
write_domain_alpha_fixture() {  # <parent-home> <secondmate-home>
  local home=$1 mate=$2 i
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'domain-alpha\n' > "$mate/.fm-secondmate-home"
  printf -- '- domain-alpha - sample rollout (home: %s; scope: sample rollout and legal release; projects: sample; added 2026-07-13)\n' \
    "$mate" > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/domain-alpha.meta" "$mate" "firstmate:fm-domain-alpha" sample
  printf 'working [key=phase7]: Phase 7 started\n' > "$home/state/domain-alpha.status"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] legal-release - Release approval blocked-by: external-legal - external legal dependency (repo: sample) (kind: ship)

## Done
EOF
  i=1
  while [ "$i" -le 7 ]; do
    printf -- '- [x] phase%s - Sample rollout Phase %s (repo: sample) (kind: ship) (done 2026-07-%02d)\n' \
      "$i" "$i" "$i" >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  refresh_local_secondmate_ledgers "$home"
}

# This is the Domain Alpha failure shape exactly: the structured home says Phase 7 is Done
# and no child is active, so the stale parent event must never become Underway.
test_domain_alpha_stale_parent_event_does_not_become_current_work() {
  local home mate fakebin json canonical
  home=$(make_home domain-alpha-parent)
  mate="$TMP_ROOT/domain-alpha-home"
  write_domain_alpha_fixture "$home" "$mate"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.[]; .id == "domain-alpha") | not)
      and (.secondmates | any(.[];
        .id == "domain-alpha"
          and .state == "externally_held"
          and .provenance == "structured-home"
          and .freshness == "fresh"
          and .contradiction == true))
      and (.gates | any(.[]; .id == "legal-release" and .owner == "domain-alpha"))
      and (.landed | any(.[]; .id == "phase7" and .owner == "domain-alpha"))
  ' >/dev/null || fail "stale parent Phase 7 event overrode authoritative Domain Alpha state: $json"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 FM_SNAPSHOT_TERMINAL_LINES=2 FM_SNAPSHOT_TERMINAL_BYTES=64 \
    NET_LOG="$home/net.log" FAKE_GH_FAIL=1 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "domain-alpha")
    | .provenance.selected == "structured-home"
      and .freshness.status == "fresh"
      and .terminal_evidence.provenance == "parent-direct-report-terminal"
      and .terminal_evidence.trust == "untrusted-supplement"
      and .terminal_evidence.captured == true
      and .terminal_evidence.lines == 2
      and .terminal_evidence.bytes <= 64
      and (.terminal_evidence | has("content") | not)
      and .terminal_evidence.event_note_seen == true
      and .terminal_evidence.contradiction == true
      and .contradiction == true
  ' >/dev/null || fail "bounded terminal contradiction evidence was not labeled and subordinate: $canonical"
  [ ! -s "$home/net.log" ] || fail "Domain Alpha structured-home read made a network call: $(cat "$home/net.log")"
  pass "Domain Alpha structured state overrides a stale parent Phase 7 event"
}

test_gnu_stat_uses_file_formats_without_bsd_fallback_pollution() {
  local home mate fakebin canonical stat_log
  home=$(make_home gnu-stat-parent)
  mate="$TMP_ROOT/gnu-stat-home"
  write_domain_alpha_fixture "$home" "$mate"
  fakebin=$(make_fakebin "$home")
  stat_log="$home/stat.log"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STAT_LOG"
case "$1 $2" in
  '-c %a') printf '600\n' ;;
  '-c %Y') printf '1783792800\n' ;;
  '-c %s') LC_ALL=C wc -c < "$3" | tr -d ' ' ;;
  -f\ *)
    printf '  File: "%s"\nBlocks: Total: 1\n' "$2"
    exit 1
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  canonical=$(PATH="$fakebin:$PATH" STAT_LOG="$stat_log" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1783792800 \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "domain-alpha")
    | .provenance.selected == "structured-home"
      and .parent_event.activity_scan.available == true
  ' >/dev/null || fail "GNU stat fixture corrupted the authoritative secondmate summary: $canonical"
  assert_contains "$(cat "$stat_log")" '-c %a' "GNU registry mode must use stat -c"
  assert_contains "$(cat "$stat_log")" '-c %Y' "GNU parent-event mtime must use stat -c"
  assert_contains "$(cat "$stat_log")" '-c %s' "GNU parent-event size must use stat -c"
  if grep -q '^-f ' "$stat_log"; then
    fail "GNU snapshot invoked BSD stat -f before its GNU file reads: $(cat "$stat_log")"
  fi
  pass "GNU stat file reads select -c without BSD filesystem-report pollution"
}

test_parent_activity_evidence_is_bounded_and_disclosed() {
  local home mate fakebin canonical json i
  home=$(make_home bounded-parent-activity)
  mate="$TMP_ROOT/bounded-parent-activity-home"
  write_domain_alpha_fixture "$home" "$mate"
  : > "$home/state/domain-alpha.status"
  i=1
  while [ "$i" -le 6 ]; do
    printf 'working [key=phase%s]: Phase %s started\n' "$i" "$i" >> "$home/state/domain-alpha.status"
    i=$((i + 1))
  done
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_PARENT_ACTIVITY_LINES=4 FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=4096 \
    FM_SNAPSHOT_PARENT_ACTIVITIES=2 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "domain-alpha")
    | .parent_event.activity_scan.available == true
      and .parent_event.activity_scan.input_truncated == true
      and .parent_event.activity_scan.retained_truncated == true
      and .parent_event.activity_scan.lines_in_window == 4
      and .parent_event.activity_scan.records_in_window == 4
      and .parent_event.activity_scan.reasons == ["line_limit", "activity_limit"]
      and (.parent_event.open_activities | map(.key)) == ["phase5", "phase6"]
  ' >/dev/null || fail "parent activity evidence was not bounded and disclosed: $canonical"
  json=$(FM_SNAPSHOT_PARENT_ACTIVITY_LINES=4 FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=4096 \
    FM_SNAPSHOT_PARENT_ACTIVITIES=2 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .omitted | any(.surface == "secondmate parent activity evidence truncated for 1 record(s)")
  ' >/dev/null || fail "bearings did not disclose bounded parent activity evidence: $json"
  pass "parent activity evidence is bounded and disclosed"
}

test_active_child_overrides_old_parent_event() {
  local home mate fakebin json canonical
  home=$(make_home active-child-parent)
  mate="$TMP_ROOT/active-child-home"
  write_domain_alpha_fixture "$home" "$mate"
  mkdir -p "$mate/projects/phase8"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] phase8 - Sample rollout Phase 8 (repo: sample) (kind: ship) (since 2026-07-13)

## Queued

## Done
- [x] phase7 - Sample rollout Phase 7 (repo: sample) (kind: ship) (done 2026-07-12)
EOF
  fm_write_meta "$mate/state/phase8.meta" \
    "window=firstmate:fm-phase8" "worktree=$mate/projects/phase8" "project=sample" \
    "harness=codex" "kind=ship" "mode=no-mistakes"
  printf 'working [key=phase8]: implementing Phase 8 parity\nneeds-decision [key=release]: choose release A or B\n' \
    > "$mate/state/phase8.status"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.secondmates | any(.[]; .id == "domain-alpha" and .state != "captain_decision"
      and (.doing | contains("release A or B") | not)))
      and (.decisions_open | any(.owner == "domain-alpha") | not)
  ' >/dev/null || fail "status-only child decision leaked into Bearings: $json"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "domain-alpha") | .endpoints[] | select(.id == "phase8")
    | .endpoint.status == "unknown"
      and .endpoint.exists == true
      and .endpoint.freshness == "fresh"
      and .endpoint.observed_at == "2026-07-11T18:00:00Z"
  ' >/dev/null || fail "child endpoint observation lacked bounded current freshness: $canonical"
  pass "Bearings excludes a status-only child decision"
}

test_structured_child_decision_reaches_captains_call() {
  local home mate fakebin json
  home=$(make_home child-decision-parent)
  mate="$TMP_ROOT/child-decision-home"
  write_domain_alpha_fixture "$home" "$mate"
  mkdir -p "$mate/projects/phase8"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] phase8 - Sample rollout Phase 8 (repo: sample) (kind: ship) (since 2026-07-13)

## Queued
- [ ] phase8-decision-release - Choose sample release (repo: sample) (kind: captain) (hold: captain release choice pending) (hold-kind: captain)

## Done
- [x] phase7 - Sample rollout Phase 7 (repo: sample) (kind: ship) (done 2026-07-12)
EOF
  fm_write_meta "$mate/state/phase8.meta" \
    "window=firstmate:fm-phase8" "worktree=$mate/projects/phase8" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" phase8 idle
  printf 'needs-decision [key=release]: choose release A or B\n' > "$mate/state/phase8.status"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.secondmates | any(.[]; .id == "domain-alpha" and .state == "captain_decision"))
      and (.decisions_open | any(.[]; .id == "domain-alpha/phase8-decision-release"
        and .key == "phase8-decision-release" and .verb == "captain-hold"))
      and (.in_flight | any(.[]; .id == "domain-alpha") | not)
  ' >/dev/null || fail "structured child captain hold did not reach Captain Call: $json"
  pass "a structured child captain hold reaches Captain's Call"
}

make_valid_secondmate_home() {  # <id> <home>
  local id=$1 home=$2
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  printf '# Firstmate fixture\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

append_secondmate_registry() {  # <parent> <id> <home>
  printf -- '- %s - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-07-13)\n' \
    "$2" "$3" >> "$1/data/secondmates.md"
}

append_landed_row() {  # <secondmate-home> <id> <title> <date>
  printf -- '- [x] %s - %s (repo: firstmate) (kind: ship) (merged %s)\n' \
    "$2" "$3" "$4" >> "$1/data/backlog.md"
}

make_landed_secondmate() {  # <parent> <id>
  local parent=$1 id=$2 mate
  mate="$TMP_ROOT/$(basename "$parent")-$id-home"
  make_valid_secondmate_home "$id" "$mate"
  append_secondmate_registry "$parent" "$id" "$mate"
  printf '%s\n' "$mate"
}

write_parent_secondmate_event() {  # <parent> <id> <home> <note>
  fm_write_secondmate_meta "$1/state/$2.meta" "$3" "firstmate:fm-$2" sample
  printf 'working [key=%s]: %s\n' "$2" "$4" > "$1/state/$2.status"
}

test_bad_secondmate_homes_never_revive_parent_work() {
  local home fakebin missing invalid unreadable malformed unknown_child wt json
  home=$(make_home bad-homes)
  : > "$home/data/secondmates.md"
  missing="$TMP_ROOT/missing-home"
  invalid="$TMP_ROOT/invalid-home"
  unreadable="$TMP_ROOT/unreadable-home"
  malformed="$TMP_ROOT/malformed-home"
  unknown_child="$TMP_ROOT/unknown-child-home"

  append_secondmate_registry "$home" missing "$missing"

  make_valid_secondmate_home invalid "$invalid"
  printf 'someone-else\n' > "$invalid/.fm-secondmate-home"
  append_secondmate_registry "$home" invalid "$invalid"
  write_parent_secondmate_event "$home" invalid "$invalid" "old invalid work"

  make_valid_secondmate_home unreadable "$unreadable"
  chmod 000 "$unreadable/data"
  append_secondmate_registry "$home" unreadable "$unreadable"
  write_parent_secondmate_event "$home" unreadable "$unreadable" "old unreadable work"

  make_valid_secondmate_home malformed "$malformed"
  printf '## In flight\nthis current row is not structured\n' > "$malformed/data/backlog.md"
  append_secondmate_registry "$home" malformed "$malformed"
  write_parent_secondmate_event "$home" malformed "$malformed" "old malformed work"

  make_valid_secondmate_home unknown-child "$unknown_child"
  wt="$unknown_child/projects/slow"
  fm_git_init_commit "$wt"
  git -C "$wt" checkout -q -b fm/slow
  printf '## In flight\n- [ ] slow - Slow child (repo: sample) (kind: ship) (since 2026-07-13)\n\n## Queued\n\n## Done\n' > "$unknown_child/data/backlog.md"
  fm_write_meta "$unknown_child/state/slow.meta" \
    "window=firstmate:fm-slow" "worktree=$wt" "project=sample" \
    "harness=codex" "kind=ship" "mode=no-mistakes"
  append_secondmate_registry "$home" unknown-child "$unknown_child"
  write_parent_secondmate_event "$home" unknown-child "$unknown_child" "old unknown work"

  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  chmod 700 "$unreadable/data"
  printf '%s' "$json" | jq -e '
    (.secondmates | length) == 5
      and all(.secondmates[]; .state == "unknown")
      and (.in_flight | map(.id) | all(. != "invalid" and . != "unreadable" and . != "malformed" and . != "unknown-child"))
      and (.secondmates | any(.[]; .id == "missing" and .provenance == "unknown"
        and .freshness == "unknown" and (.reason | contains("invalid home"))))
      and ([.secondmates[] | select(.id == "invalid" or .id == "unreadable" or .id == "malformed")]
        | all(.provenance == "parent-event-fallback" and .freshness == "historical-event"))
      and (.secondmates | any(.[]; .id == "unknown-child" and .provenance == "structured-home"
        and .freshness == "fresh"))
      and (.secondmates | any(.[]; .id == "invalid" and (.reason | contains("marked for"))))
      and (.secondmates | any(.[]; .id == "unreadable" and (.reason | test("invalid home|unreadable"))))
      and (.secondmates | any(.[]; .id == "malformed" and (.reason | contains("unstructured current backlog row"))))
      and (.secondmates | any(.[]; .id == "unknown-child" and (.reason | contains("child current state unavailable"))))
      and ([.secondmate_reconcile[].id] == ["malformed", "unknown-child"])
      and (.secondmate_reconcile[0].kind == "unstructured_current")
      and (.secondmate_reconcile[1].kind == "child_current_unavailable")
  ' >/dev/null || fail "bad home outcomes revived stale work or lacked provenance: $json"
  pass "missing, invalid, unreadable, malformed, and unavailable-child homes stay explicit unknowns"
}

test_oversized_secondmate_summary_stays_strict_unknown() {
  local home mate fakebin json i
  home=$(make_home oversized-home)
  mate="$TMP_ROOT/oversized-secondmate-home"
  make_valid_secondmate_home oversized "$mate"
  append_secondmate_registry "$home" oversized "$mate"
  fm_write_secondmate_meta "$home/state/oversized.meta" "$mate" "firstmate:fm-oversized" sample
  printf 'working [key=old]: stale parent activity\n' > "$home/state/oversized.status"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  i=1
  while [ "$i" -le 30 ]; do
    printf -- '- [x] landed-%02d - Bounded landed fixture %02d (repo: sample) (kind: ship) (done 2026-07-01)\n' \
      "$i" "$i" >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  fakebin=$(make_fakebin "$home")
  json=$(FM_SNAPSHOT_SECONDMATE_MAX_BYTES=512 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.secondmates | any(.id == "oversized" and .state == "unknown"
      and .provenance == "parent-event-fallback"
      and (.reason | contains("exceeded byte limit"))))
      and (.in_flight | any(.id == "oversized") | not)
      and (.decisions_open | any(.owner == "oversized") | not)
      and (.landed | any(.owner == "oversized") | not)
  ' >/dev/null || fail "oversized summary revived or retained unvalidated surfaces: $json"
  pass "oversized ledgers stay strict unknown"
}

test_secondmate_and_child_bounds_are_disclosed() {
  local home fakebin id mate child json expanded canonical i
  home=$(make_home secondmate-bounds)
  : > "$home/data/secondmates.md"
  for id in a b c; do
    mate="$TMP_ROOT/bounds-$id"
    make_valid_secondmate_home "$id" "$mate"
    append_secondmate_registry "$home" "$id" "$mate"
  done
  mate="$TMP_ROOT/bounds-a"
  : > "$mate/data/backlog.md"
  printf '## In flight\n' >> "$mate/data/backlog.md"
  i=1
  while [ "$i" -le 3 ]; do
    child="child-$i"
    mkdir -p "$mate/projects/$child"
    printf -- '- [ ] %s - Active %s (repo: sample) (kind: ship) (since 2026-07-13)\n' "$child" "$child" >> "$mate/data/backlog.md"
    fm_write_meta "$mate/state/$child.meta" \
      "window=firstmate:fm-$child" "worktree=$mate/projects/$child" "project=sample" \
      "harness=claude" "kind=ship" "mode=no-mistakes"
    record_claude_state "$mate/state" "$child" busy
    printf 'working [key=%s]: active child %s\n' "$child" "$i" > "$mate/state/$child.status"
    i=$((i + 1))
  done
  printf '\n## Queued\n\n## Done\n' >> "$mate/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  PATH="$fakebin:$PATH" FM_SNAPSHOT_SECONDMATE_CHILDREN=2 refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_SECONDMATES=2 FM_SNAPSHOT_SECONDMATE_CHILDREN=2 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.total_registered == 3
      and .secondmate_current.shown == 2
      and .secondmate_current.truncated == 1
      and (.secondmate_current.records[] | select(.id == "a")
        | .counts.active_children == 3 and (.active_children | length) == 2
          and (.omitted | any(.surface == "active_children" and .count == 1)))
      and (.secondmate_current.records | any(.id == "b" and .current.state == "no_active_work"))
  ' >/dev/null || fail "canonical secondmate or child bounds were not enforced: $canonical"
  json=$(FM_SNAPSHOT_SECONDMATES=2 FM_SNAPSHOT_SECONDMATE_CHILDREN=2 FM_BEARINGS_SECONDMATES=1 \
    run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.secondmates | length) == 1
      and ([.in_flight[].id] | sort) == ["a/child-1", "a/child-2"]
      and ([.omitted[].surface] | any(test("secondmate a active children omitted by snapshot bound: 1")))
      and ([.omitted[].surface] | any(test("secondmates showing 1 of 2")))
      and ([.omitted[].surface] | any(test("registered secondmates omitted by snapshot bound: 1")))
  ' >/dev/null || fail "bearings secondmate or child bound was not disclosed: $json"
  expanded=$(FM_SNAPSHOT_SECONDMATE_CHILDREN=2 FM_BEARINGS_SECONDMATES=1 \
    run "$home" "$fakebin" --json --all-secondmates)
  printf '%s' "$expanded" | jq -e '
    (.secondmates | length) == 3
      and ([.omitted[].surface] | any(test("secondmates showing|registered secondmates omitted")) | not)
  ' >/dev/null || fail "--all-secondmates did not expand the canonical and bearings bounds: $expanded"
  pass "secondmate and per-home child counts are bounded, disclosed, and explicitly expandable"
}

test_parent_decision_is_untrusted_contradiction_only() {
  local home mate fakebin canonical json
  home=$(make_home parent-decision-only)
  mate="$TMP_ROOT/parent-decision-only-home"
  make_valid_secondmate_home authority "$mate"
  append_secondmate_registry "$home" authority "$mate"
  fm_write_secondmate_meta "$home/state/authority.meta" "$mate" "firstmate:fm-authority" sample
  printf 'needs-decision [key=stale]: old parent question\n' > "$home/state/authority.status"
  fakebin=$(make_fakebin "$home")
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "authority")
    | .current.state == "no_active_work"
      and .decisions_open == []
      and .contradiction == true
      and (.parent_event.open_decisions | any(.key == "stale" and .verb == "needs-decision"))
  ' >/dev/null || fail "parent decision crossed structured-home authority boundary: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.secondmates | any(.[]; .id == "authority" and .state == "no_active_work" and .contradiction == true))
      and (.decisions_open | any(.[]; .id == "authority") | not)
  ' >/dev/null || fail "bearings promoted a stale parent decision: $json"
  pass "parent decisions remain untrusted contradiction evidence"
}

test_parent_evidence_reconciles_by_verb_and_key() {
  local home hold blocked decision fakebin canonical mate child
  home=$(make_home keyed-parent-evidence)
  hold="$TMP_ROOT/keyed-parent-hold-home"
  blocked="$TMP_ROOT/keyed-parent-blocked-home"
  decision="$TMP_ROOT/keyed-parent-decision-home"
  make_valid_secondmate_home hold "$hold"
  make_valid_secondmate_home blocked "$blocked"
  make_valid_secondmate_home decision "$decision"
  append_secondmate_registry "$home" hold "$hold"
  append_secondmate_registry "$home" blocked "$blocked"
  append_secondmate_registry "$home" decision "$decision"
  fm_write_secondmate_meta "$home/state/hold.meta" "$hold" "firstmate:fm-hold" sample
  fm_write_secondmate_meta "$home/state/blocked.meta" "$blocked" "firstmate:fm-blocked" sample
  fm_write_secondmate_meta "$home/state/decision.meta" "$decision" "firstmate:fm-decision" sample
  printf 'working [key=stale-work]: old work still running\n' > "$home/state/hold.status"
  printf 'paused [key=legal-release]: waiting for legal release\n' >> "$home/state/hold.status"
  printf 'paused: legacy pause without an identity\n' >> "$home/state/hold.status"
  printf 'blocked [key=vendor-release]: waiting for vendor release\n' > "$home/state/blocked.status"
  printf 'blocked: legacy block without an identity\n' >> "$home/state/blocked.status"
  printf 'needs-decision [key=stale-route]: choose the old route\n' > "$home/state/decision.status"
  printf 'working: legacy work without an identity\n' >> "$home/state/decision.status"
  cat > "$hold/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] legal-release - Legal release blocked-by: external-legal - legal review (repo: sample) (kind: ship)

## Done
EOF
  cat > "$blocked/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] vendor-release - Vendor release blocked-by: external-vendor - vendor review (repo: sample) (kind: ship)

## Done
EOF
  child='decision-child'
  mkdir -p "$decision/projects/$child"
  cat > "$decision/data/backlog.md" <<EOF
## In flight
- [ ] $child - Decision child (repo: sample) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$decision/state/$child.meta" \
    "window=firstmate:fm-$child" "worktree=$decision/projects/$child" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$decision/state" "$child" idle
  printf 'needs-decision [key=live-route]: choose the current route\n' > "$decision/state/$child.status"
  fakebin=$(make_fakebin "$home")
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    (.secondmate_current.records[] | select(.id == "hold")
      | .current.state == "externally_held"
        and .contradiction == true
        and .terminal_evidence.captured == false
        and (.parent_event.reconciliation.activities
          | any(.verb == "paused" and .key == "legal-release" and .verdict == "corroborates"))
        and (.parent_event.reconciliation.activities
          | any(.verb == "paused" and .key == "default" and .verdict == "inconclusive" and .matched == null))
        and (.parent_event.reconciliation.activities
          | any(.verb == "working" and .key == "stale-work" and .verdict == "contradicts")))
      and (.secondmate_current.records[] | select(.id == "blocked")
        | .current.state == "externally_held"
          and .contradiction == false
          and (.parent_event.reconciliation.decisions
            | any(.verb == "blocked" and .key == "vendor-release" and .verdict == "corroborates"))
          and (.parent_event.reconciliation.decisions
            | any(.verb == "blocked" and .key == "default" and .verdict == "inconclusive" and .matched == null)))
      and (.secondmate_current.records[] | select(.id == "decision")
        | .current.state == "captain_decision"
          and .contradiction == true
          and .terminal_evidence.captured == false
          and (.parent_event.reconciliation.activities
            | any(.verb == "working" and .key == "default" and .verdict == "inconclusive" and .matched == null))
          and (.parent_event.reconciliation.decisions
            | any(.verb == "needs-decision" and .key == "stale-route" and .verdict == "contradicts")))
  ' >/dev/null || fail "parent evidence was not reconciled by verb and key: $canonical"
  pass "parent evidence reconciliation distinguishes matching holds, blocks, and decisions"
}

test_nonprogressing_child_states_are_explicit() {
  local home mate fakebin canonical
  home=$(make_home child-state-classification)
  mate="$TMP_ROOT/child-state-classification-home"
  make_valid_secondmate_home states "$mate"
  append_secondmate_registry "$home" states "$mate"
  mkdir -p "$mate/projects/parked" "$mate/projects/done" "$mate/projects/failed"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] parked - Parked child (repo: sample) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$mate/state/parked.meta" \
    "window=firstmate:fm-parked" "worktree=$mate/projects/parked" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" parked idle
  printf 'needs-decision [key=parked]: choose a route\n' > "$mate/state/parked.status"
  fakebin=$(make_fakebin "$home")
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "states")
    | .current.state == "captain_decision"
      and .active_children == []
      and (.holds | any(.id == "parked" and .source == "child-state"))
  ' >/dev/null || fail "parked child was classified as active work: $canonical"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "states")
    | .current.state == "captain_decision"
      and (.current.reason | contains("live child state has no in-flight backlog item"))
      and (.current.reason | contains("parked=parked"))
      and .provenance.selected == "structured-home"
      and .provenance.trust == "partial-structured"
      and .invalidity == {kind:"unowned_current",ids:["parked"]}
      and [.decisions_open[].key] == ["parked"]
  ' >/dev/null || fail "unowned held child lost its classification or decisions: $canonical"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] done - Done child still in flight (repo: sample) (kind: ship) (since 2026-07-11)
- [ ] failed - Failed child still in flight (repo: sample) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$mate/state/done.meta" \
    "window=firstmate:fm-done" "worktree=$mate/projects/done" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$mate/state/failed.meta" \
    "window=firstmate:fm-failed" "worktree=$mate/projects/failed" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" "done" idle
  record_claude_state "$mate/state" failed idle
  printf 'done: complete\n' > "$mate/state/done.status"
  printf 'failed: stopped\n' > "$mate/state/failed.status"
  rm "$mate/state/parked.meta" "$mate/state/parked.status"
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "states")
    | .current.state == "no_active_work"
      and (.current.reason | contains("terminal child state"))
      and (.current.reason | contains("done=done"))
      and (.current.reason | contains("failed=failed"))
      and .provenance.selected == "structured-home"
      and .provenance.trust == "partial-structured"
      and .invalidity == {kind:"terminal_in_flight",ids:["done","failed"]}
  ' >/dev/null || fail "terminal in-flight rows discarded the readable home: $canonical"
  pass "nonprogressing child states are explicit and inconsistent terminal rows invalidate"
}

test_registry_unavailability_and_bounds_are_explicit() {
  local home fakebin json canonical id mate boundary
  home=$(make_home registry-unavailable)
  mate="$TMP_ROOT/registry-hidden"
  make_valid_secondmate_home hidden "$mate"
  printf -- '- hidden - fixture (home: %s; scope: fixture; projects: sample; added 2026-07-11)\n' "$mate" > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/hidden.meta" "$mate" "firstmate:fm-hidden" sample
  chmod 000 "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  json=$(run "$home" "$fakebin" --json)
  chmod 600 "$home/data/secondmates.md"
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.registry.complete == false
      and (.secondmate_current.records[] | select(.id == "hidden")
        | .registered == null
          and (.current.reason | contains("registration is unknown")))
  ' >/dev/null || fail "unavailable registry produced false unregistered provenance: $canonical"
  printf '%s' "$json" | jq -e '
    (.secondmates | any(.[]; .id == "(registry)" and .state == "unknown"
      and .provenance == "registered-table" and .freshness == "unavailable"))
      and (.omitted | any(.surface | contains("secondmate registry unavailable")))
  ' >/dev/null || fail "unreadable registry disappeared from bearings: $json"
  home=$(make_home registry-bounds)
  : > "$home/data/secondmates.md"
  for id in one two three; do
    mate="$TMP_ROOT/registry-$id"
    make_valid_secondmate_home "$id" "$mate"
    append_secondmate_registry "$home" "$id" "$mate"
  done
  fakebin=$(make_fakebin "$home")
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_REGISTRY_RECORDS=2 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.registry
    | .available == true and .provenance == "registered-table"
      and .freshness.status == "fresh" and .records_truncated == true
      and .records_in_window == 3 and (.records | length) == 2
      and (.reasons | index("record_limit") != null)
  ' >/dev/null || fail "registry record bound was not enforced or disclosed: $canonical"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_REGISTRY_LINES=2 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.registry
    | .input_truncated == true and .records_truncated == false
      and .lines_in_window == 2 and (.records | length) == 2
      and .reasons == ["line_limit"]
  ' >/dev/null || fail "registry line bound was not enforced or disclosed: $canonical"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_REGISTRY_BYTES=100 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.registry
    | .input_truncated == true and (.reasons | index("byte_limit") != null)
      and .records_in_window < 3
  ' >/dev/null || fail "registry byte bound was not enforced or disclosed: $canonical"
  boundary=$(LC_ALL=C head -n 1 "$home/data/secondmates.md" | wc -c | tr -d ' ')
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_REGISTRY_BYTES="$((boundary - 1))" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.registry
    | .input_truncated == true and .complete == false
      and (.reasons | index("byte_limit") != null)
  ' >/dev/null || fail "registry newline byte boundary hid truncation: $canonical"
  json=$(FM_SNAPSHOT_REGISTRY_RECORDS=2 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .omitted | any(.surface == "secondmate registry records omitted by bounded read")
  ' >/dev/null || fail "bearings omitted registry truncation disclosure: $json"
  mate="$TMP_ROOT/registry-z-hidden"
  make_valid_secondmate_home z-hidden "$mate"
  append_secondmate_registry "$home" z-hidden "$mate"
  fm_write_secondmate_meta "$home/state/z-hidden.meta" "$mate" "firstmate:fm-z-hidden" sample
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_REGISTRY_RECORDS=3 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.registry.complete == false
      and (.secondmate_current.records[] | select(.id == "z-hidden")
        | .registered == null
          and (.current.reason | contains("registration is unknown")))
  ' >/dev/null || fail "truncated registry produced false unregistered provenance: $canonical"
  pass "registry unavailability and bounded truncation remain explicit"
}

test_current_landed_baseline_is_repeatable_and_prior_report_independent() {
  local home fakebin one two
  home=$(make_home standalone-baseline); write_fixture "$home"
  cat > "$home/data/status-report-2026-07-10.md" <<'EOF'
# Misleading old report

## Recently Landed
- fake-old-item

## Underway
- Phase 7 started
EOF
  fakebin=$(make_fakebin "$home")
  one=$(run "$home" "$fakebin" --json)
  two=$(run "$home" "$fakebin" --json)
  [ "$(printf '%s' "$one" | jq -c '.landed')" = "$(printf '%s' "$two" | jq -c '.landed')" ] \
    || fail "the same structured state produced different recent-completion baselines"
  printf '%s' "$two" | jq -e '
    (.landed | any(.id == "done-a"))
      and (.landed | any(.id == "mate-landed"))
      and (.landed | any(.id == "fake-old-item") | not)
      and (.in_flight | any(.doing == "Phase 7 started") | not)
  ' >/dev/null || fail "prior status report influenced the standalone snapshot: $two"
  pass "repeated snapshots keep the same current landed baseline and ignore prior reports"
}

test_default_is_bounded_and_local_only() {
  local home fakebin toon json backlog
  home=$(make_home bounded); write_fixture "$home"
  backlog="$home/data/backlog.md"
  awk '{if ($0 ~ /^- \[ \] ship-task /) sub(/ \(repo: firstmate\)/, ""); print}' \
    "$backlog" > "$backlog.tmp" && mv "$backlog.tmp" "$backlog"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Bound: well under the ~50 KB tool-display limit.
  [ "${#toon}" -lt 50000 ] || fail "default TOON must stay under the display bound, got ${#toon}"
  # TOON is materially smaller than the canonical snapshot it projects.
  local canon; canon=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  [ "${#toon}" -lt "${#canon}" ] || fail "projection must be smaller than the canonical snapshot"
  # Local-only: no GitHub/network call on the default path.
  [ ! -s "$home/net.log" ] || fail "default run must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  # Definitive not-requested PR state, never a silent omission.
  assert_contains "$toon" 'prs: "not_requested' "default must state PR checks were not requested"
  assert_contains "$toon" "live PR discovery + checks,\"--include-prs\"" "omitted must mark the dropped live-PR surface"
  # Valid JSON, correct schema.
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.in_flight | any(.id == "ship-task" and .repo == "firstmate"))
  ' >/dev/null || fail "json schema or main Underway repository wrong: $json"
  pass "default output is bounded, local-only, and marks omitted surfaces"
}

test_toon_json_parity() {
  local home fakebin toon json keys k
  home=$(make_home parity); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Same top-level keys in both representations.
  keys=$(printf '%s' "$json" | jq -r 'keys_unsorted[]')
  for k in $keys; do
    if printf '%s' "$json" | jq -e --arg k "$k" '.[$k] | type == "array"' >/dev/null; then
      local n hdr
      n=$(printf '%s' "$json" | jq --arg k "$k" '.[$k] | length')
      if [ "$n" = 0 ]; then
        assert_contains "$toon" "$k: []" "empty array $k must render as 'key: []'"
      else
        # Header must declare the same count and the same field set.
        hdr=$(printf '%s' "$toon" | grep -E "^$k\[[0-9]+\]\{" || true)
        [ -n "$hdr" ] || fail "TOON missing tabular header for $k"
        assert_contains "$hdr" "[$n]" "TOON $k row count must equal JSON length $n"
        local jfields tfields
        jfields=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k][0] | keys_unsorted | join(",")')
        tfields=$(printf '%s' "$hdr" | sed -E 's/^[^{]*\{//; s/\}:.*$//; s/"//g')
        [ "$jfields" = "$tfields" ] || fail "TOON $k fields ($tfields) must equal JSON fields ($jfields)"
      fi
    else
      # Scalar: the key must appear as a "key: value" line.
      assert_contains "$toon" "$k: " "TOON must carry scalar field $k"
    fi
  done
  pass "TOON and JSON are parity representations of the same model"
}

test_open_decision_surfaces_end_to_end() {
  local home fakebin json
  home=$(make_home e2e-decision); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.[]; .id == "mate/mate-decision-race"
      and .key == "mate-decision-race" and .verb == "captain-hold")
  ' >/dev/null || fail "an authoritative captain hold must surface in decisions_open: $json"
  pass "an authoritative captain hold surfaces end-to-end"
}

test_report_pointers_surface() {
  local home fakebin json
  home=$(make_home reports); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e --arg p "$home/data/scout-x/report.md" '
    .reports | any(.[]; .id == "scout-x" and .path == $p)
  ' >/dev/null || fail "current scout report pointer must surface: $json"
  pass "current report pointers surface"
}

test_superseded_queued_item_dropped_by_default() {
  local home fakebin json
  home=$(make_home superseded); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | any(.[]; .id == "live-gate")) and (.gates | any(.[]; .id == "dead-gate") | not)
  ' >/dev/null || fail "default gates must include live and drop superseded: $json"
  json=$(run "$home" "$fakebin" --json --all-queued)
  printf '%s' "$json" | jq -e '.gates | any(.[]; .id == "dead-gate")' >/dev/null \
    || fail "--all-queued must restore the superseded item"
  pass "superseded queued items are dropped by default and restored with --all-queued"
}

# The collapsed captain-call contract: any due, unblocked captain-held task is
# Captain's Call whatever its kind; a date-deferred hold is a dated gate until
# due; a prose-deferred hold leaves the default views with a disclosure; and
# Recently Landed excludes only what closed while still held for the captain.
test_collapsed_captain_call_deferral_and_landed() {
  local home fakebin json
  home=$(make_home collapsed-call)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] work-gate - Captain-gated ship work (repo: firstmate) (kind: ship) (hold: captain go needed) (hold-kind: captain)
- [ ] later-call - Deferred captain call (repo: firstmate) (kind: captain) (hold: revisit with the captain) (hold-kind: captain) (hold-until: 2026-08-01)
- [ ] due-call - Due captain call (repo: firstmate) (kind: captain) (hold: overdue captain choice) (hold-kind: captain) (hold-until: 2026-07-11)
- [ ] parked-call - Prose-parked captain call (repo: firstmate) (kind: ship) (hold: DEFERRED by captain revisit later) (hold-kind: captain)
- [ ] external-gate - Externally held work (repo: firstmate) (kind: ship) (hold: upstream release pending) (hold-kind: external)

## Done
- [x] answered-call - Answered captain question (repo: firstmate) (kind: captain) (done 2026-07-10) (hold: captain choice pending) (hold-kind: captain)
- [x] shipped-work - Ordinary landed work (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "work-gate"))
      and (.decisions_open | any(.[]; .id == "due-call"))
      and (.decisions_open | any(.[]; .id == "later-call") | not)
      and (.decisions_open | any(.[]; .id == "parked-call") | not)
      and (.decisions_open | any(.[]; .id == "external-gate") | not)
      and (.gates | any(.[]; .id == "later-call" and (.reason | startswith("until 2026-08-01"))))
      and (.gates | any(.[]; .id == "work-gate") | not)
      and (.gates | any(.[]; .id == "parked-call") | not)
      and (.gates | any(.[]; .id == "external-gate"))
      and (.landed | any(.[]; .id == "shipped-work"))
      and (.landed | any(.[]; .id == "answered-call") | not)
      and (.omitted | any(.[]; .surface | startswith("captain holds marked deferred")))
  ' >/dev/null || fail "the collapsed captain-call projection is wrong: $json"
  json=$(run "$home" "$fakebin" --json --all-decisions --all-queued)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "parked-call"))
      and (.gates | any(.[]; .id == "parked-call") | not)
  ' >/dev/null || fail "--all-decisions must reveal the prose-deferred call: $json"
  pass "captain-held tasks of any kind reach Captain's Call, deferral is honored, and landed excludes answered calls"
}

test_include_prs_is_the_only_fetch_path() {
  local home fakebin json
  home=$(make_home prs); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --include-prs --json)
  # Now gh WAS called, exactly for pr list.
  grep -q '^gh pr list ' "$home/net.log" || fail "--include-prs must call gh pr list"
  printf '%s' "$json" | jq -e '
    .prs | startswith("checked")
  ' >/dev/null || fail "--include-prs must report checked PR state"
  printf '%s' "$json" | jq -e '
    .candidate_prs | any(.[]; .num == "9" and .task == "ship-task" and .checks == "passing" and .review == "APPROVED")
  ' >/dev/null || fail "candidate_prs must carry the fetched PR cross-referenced to its task: $json"
  pass "--include-prs is the only path that fetches, and it enriches correctly"
}

test_partial_github_failure_degrades() {
  local home fakebin json rc
  home=$(make_home partial); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --include-prs --json); rc=$?
  expect_code 0 "$rc" "a PR-fetch failure must not crash the view"
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.candidate_prs | length) == 0
      and (.prs | test("unavailable"))
      and (.in_flight | length) > 0
  ' >/dev/null || fail "on gh failure the view must still emit, with an unavailable note: $json"
  pass "a partial GitHub failure degrades gracefully"
}

test_perl_fallback_bounds_github_call() {
  local home fakebin toolbin cmd json started elapsed
  home=$(make_home perl-timeout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toolbin="$home/toolbin"
  mkdir -p "$toolbin"
  for cmd in bash dirname basename jq date sed git grep tail cut tr head sort wc perl sleep cat find mktemp rm mkdir chmod mv cp awk; do
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  for cmd in shasum sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  started=$(date +%s)
  json=$(PATH="$fakebin:$toolbin" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    FM_BEARINGS_PR_TIMEOUT=1 NET_LOG="$home/net.log" FAKE_GH_SLEEP=1 "$BEARINGS" --include-prs --json)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] || fail "Perl fallback did not bound a stalled gh call (${elapsed}s)"
  printf '%s' "$json" | jq -e '.prs | test("unavailable")' >/dev/null \
    || fail "timed-out gh call did not fail soft: $json"
  pass "Perl fallback bounds stalled GitHub calls without coreutils timeout"
}

write_large_fixture() {  # <home> <count>
  local home=$1 count=$2 i id
  : > "$home/data/backlog.md"
  printf '## Queued\n' >> "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="dead-$i"
    mkdir -p "$home/projects/$id" "$home/data/$id"
    printf '# Report\n' > "$home/data/$id/report.md"
    printf -- '- [ ] gate-%s - Gate %s blocked-by: task-%s (repo: repo-%s) (kind: ship)\n' "$i" "$i" "$i" "$i" >> "$home/data/backlog.md"
    printf -- '- [ ] decision-%s - Decision %s (repo: repo-%s) (kind: captain) (hold: captain choice pending) (hold-kind: captain)\n' "$i" "$i" "$i" >> "$home/data/backlog.md"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=scout" \
      "mode=scout" \
      "pr=https://github.com/acme/repo-$i/pull/$i"
    printf 'needs-decision [key=q%s]: choose %s\n' "$i" "$i" > "$home/state/$id.status"
    i=$((i + 1))
  done
}

test_section_caps_and_expansion_flags() {
  local home fakebin json expanded
  home=$(make_home caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight|length) == 2 and (.decisions_open|length) == 2 and (.gates|length) == 2
    and (.reports|length) == 2 and (.recorded_prs|length) == 2 and (.unhealthy_endpoints|length) == 2
    and ([.omitted[].surface] | index("in_flight showing 2 of 5") != null)
    and ([.omitted[].surface] | index("decisions_open showing 2 of 5") != null)
    and ([.omitted[].surface] | index("gates showing 2 of 5") != null)
    and ([.omitted[].surface] | index("reports showing 2 of 5") != null)
    and ([.omitted[].surface] | index("recorded_prs showing 2 of 5") != null)
    and ([.omitted[].surface] | index("unhealthy_endpoints showing 2 of 5") != null)
  ' >/dev/null || fail "section caps or counted omissions are wrong: $json"
  expanded=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json --all-in-flight --all-decisions --all-queued \
      --all-reports --all-recorded-prs --all-unhealthy)
  printf '%s' "$expanded" | jq -e '
    (.in_flight|length) == 5 and (.decisions_open|length) == 5 and (.gates|length) == 5
    and (.reports|length) == 5 and (.recorded_prs|length) == 5 and (.unhealthy_endpoints|length) == 5
  ' >/dev/null || fail "section expansion flags did not reveal full sets: $expanded"
  pass "all fleet-sized sections are capped with counted opt-in expansion"
}

test_pr_repository_cap_and_expansion() {
  local home fakebin json expanded
  home=$(make_home repo-caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 2 ] || fail "default PR repository cap was not enforced"
  printf '%s' "$json" | jq -e '
    [.omitted[] | select(.surface == "PR repositories showing 2 of 5" and .reveal == "--all-pr-repos")] | length == 1
  ' >/dev/null || fail "PR repository truncation was not recorded: $json"
  : > "$home/net.log"
  expanded=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --all-pr-repos --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 5 ] || fail "--all-pr-repos did not reveal every repository"
  printf '%s' "$expanded" | jq -e '.candidate_prs | length == 5' >/dev/null \
    || fail "expanded PR repository set did not enrich every repository: $expanded"
  pass "live PR enrichment caps repositories with counted expansion"
}

test_per_repository_pr_cap_is_disclosed() {
  local home fakebin json toon
  home=$(make_home pr-row-cap); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs --json)
  toon=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs)
  printf '%s' "$json" | jq -e '
    (.candidate_prs | length) == 2
    and (.prs | test("2 shown, at least 3 open; capped in 1 repo"))
    and ([.omitted[] | select(.surface == "candidate_prs showing 2 of at least 3; capped in 1 repo(s)" and .reveal == "raise FM_BEARINGS_PR_LIMIT")] | length) == 1
  ' >/dev/null || fail "per-repository PR truncation was not disclosed: $json"
  assert_contains "$toon" 'candidate_prs showing 2 of at least 3' "TOON did not preserve PR truncation disclosure"
  pass "per-repository open-PR caps are disclosed with an expansion knob"
}

install_failing_jq() {  # <fakebin> <model|toon>
  local fakebin=$1 phase=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'def trunc'*) [ "$phase" = model ] && exit 9 ;;
  *'def q:'*) [ "$phase" = toon ] && exit 9 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

test_projection_and_toon_fail_closed() {
  local home fakebin out err rc
  home=$(make_home fail-closed); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  install_failing_jq "$fakebin" model
  err="$home/model.err"
  out=$(run "$home" "$fakebin" --json 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "projection failure exited successfully"
  [ -z "$out" ] || fail "projection failure emitted output"
  grep -F 'projection failed' "$err" >/dev/null || fail "projection failure lacked a diagnostic"
  install_failing_jq "$fakebin" toon
  err="$home/toon.err"
  out=$(run "$home" "$fakebin" 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "TOON rendering failure exited successfully"
  [ -z "$out" ] || fail "TOON rendering failure emitted output"
  grep -F 'TOON rendering failed' "$err" >/dev/null || fail "TOON failure lacked a diagnostic"
  pass "projection and TOON rendering failures exit nonzero with diagnostics"
}

# The Lavish-103 defect, end to end: a COMPLETED scout that raised a decision and
# then finished (done), whose report body reads like that decision, must surface as
# a report POINTER only - never in decisions_open. Report prose must never open or
# reopen a pending decision; only the keyed durable state does.
test_completed_scout_report_not_pending() {
  local home fakebin json
  home=$(make_home completed-scout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/lav-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/lav-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B; this needs a captain decision.\n' > "$home/data/lavish-103/report.md"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "lavish-103") | not)
      and (.reports | any(.[]; .id == "lavish-103"))
  ' >/dev/null || fail "completed scout must be a report pointer, never a pending decision: $json"
  pass "a completed scout with decision-like report prose is a pointer, not pending"
}

# Recently Landed must include merges a secondmate managed. Those completion records
# live in the secondmate home's OWN backlog, not the main one, so the projection must
# roll them up. Local, deterministic, no GitHub call.
test_landed_includes_secondmate_home_merges() {
  local home fakebin json
  home=$(make_home mate-landed); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.landed | any(.[]; .id == "mate-landed" and (.artifact | test("/pull/50"))))
      and (.landed | any(.[]; .id == "done-a"))
  ' >/dev/null || fail "landed must merge secondmate-home Done with main-home Done: $json"
  # Still zero network on this default path.
  [ ! -s "$home/net.log" ] || fail "landed roll-up must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  pass "landed includes secondmate-managed merges alongside main-home merges"
}

test_landed_default_balances_dominant_and_sparse_homes() {
  local home dominant sparse_a sparse_b sparse_c fakebin json i actual expected
  home=$(make_home landed-balanced-default)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  dominant=$(make_landed_secondmate "$home" dominant)
  sparse_a=$(make_landed_secondmate "$home" sparse-a)
  sparse_b=$(make_landed_secondmate "$home" sparse-b)
  sparse_c=$(make_landed_secondmate "$home" sparse-c)
  i=1
  while [ "$i" -le 12 ]; do
    append_landed_row "$dominant" "$(printf 'dominant-landed-%02d' "$i")" \
      "$(printf 'Dominant landed %02d' "$i")" "$(printf '2026-07-%02d' "$((31 - i))")"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le 2 ]; do
    append_landed_row "$sparse_a" "$(printf 'sparse-a-landed-%02d' "$i")" \
      "$(printf 'Sparse A landed %02d' "$i")" "$(printf '2026-07-%02d' "$((12 - i))")"
    append_landed_row "$sparse_b" "$(printf 'sparse-b-landed-%02d' "$i")" \
      "$(printf 'Sparse B landed %02d' "$i")" "$(printf '2026-07-%02d' "$((10 - i))")"
    append_landed_row "$sparse_c" "$(printf 'sparse-c-landed-%02d' "$i")" \
      "$(printf 'Sparse C landed %02d' "$i")" "$(printf '2026-07-%02d' "$((8 - i))")"
    i=$((i + 1))
  done
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  actual=$(printf '%s' "$json" | jq -r '.landed[] | "\(.owner)/\(.id)"')
  expected='dominant/dominant-landed-01
sparse-a/sparse-a-landed-01
sparse-b/sparse-b-landed-01
sparse-c/sparse-c-landed-01
dominant/dominant-landed-02
sparse-a/sparse-a-landed-02'
  [ "$actual" = "$expected" ] || fail "default landed selection was not balanced across homes: $actual"
  printf '%s' "$json" | jq -e '
    (.landed | length) == 6
      and ([.landed[].owner] | unique | length) == 4
      and ([.omitted[].surface] | any(test("landed showing 6 of 12")))
  ' >/dev/null || fail "balanced landed default did not preserve cap disclosure: $json"
  pass "default landed selection balances one dominant home with sparse homes"
}

test_landed_default_refills_capacity_after_sparse_homes_exhaust() {
  local home dominant sparse fakebin json actual expected i
  home=$(make_home landed-sparse-refill)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  dominant=$(make_landed_secondmate "$home" dominant)
  sparse=$(make_landed_secondmate "$home" sparse)
  i=1
  while [ "$i" -le 5 ]; do
    append_landed_row "$dominant" "$(printf 'dominant-landed-%02d' "$i")" \
      "$(printf 'Dominant landed %02d' "$i")" "$(printf '2026-07-%02d' "$((20 - i))")"
    i=$((i + 1))
  done
  append_landed_row "$sparse" sparse-landed-01 "Sparse landed 01" 2026-07-01
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  actual=$(printf '%s' "$json" | jq -r '.landed[] | "\(.owner)/\(.id)"')
  expected='dominant/dominant-landed-01
sparse/sparse-landed-01
dominant/dominant-landed-02
dominant/dominant-landed-03
dominant/dominant-landed-04
dominant/dominant-landed-05'
  [ "$actual" = "$expected" ] || fail "sparse homes wasted landed capacity: $actual"
  pass "landed selection refills capacity after sparse homes exhaust"
}

test_landed_default_uses_deterministic_home_order_when_homes_exceed_cap() {
  local home mate fakebin json actual expected i id
  home=$(make_home landed-home-order)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  i=1
  while [ "$i" -le 8 ]; do
    id=$(printf 'home-%02d' "$i")
    mate=$(make_landed_secondmate "$home" "$id")
    append_landed_row "$mate" "$id-landed-01" "$id landed 01" 2026-07-10
    i=$((i + 1))
  done
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  actual=$(printf '%s' "$json" | jq -r '.landed[] | "\(.owner)/\(.id)"')
  expected='home-01/home-01-landed-01
home-02/home-02-landed-01
home-03/home-03-landed-01
home-04/home-04-landed-01
home-05/home-05-landed-01
home-06/home-06-landed-01'
  [ "$actual" = "$expected" ] || fail "landed home-order tie was not deterministic: $actual"
  printf '%s' "$json" | jq -e '
    ([.omitted[].surface] | any(test("landed showing 6 of 8")))
  ' >/dev/null || fail "more-homes-than-cap omission was not disclosed: $json"
  pass "landed selection uses deterministic home order when homes exceed the cap"
}

test_landed_default_preserves_internal_order_for_ties() {
  local home tie_a tie_b fakebin json actual expected
  home=$(make_home landed-ties)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  tie_a=$(make_landed_secondmate "$home" tie-a)
  tie_b=$(make_landed_secondmate "$home" tie-b)
  append_landed_row "$tie_b" tie-b-a "Tie B A" 2026-07-10
  append_landed_row "$tie_b" tie-b-z "Tie B Z" 2026-07-10
  append_landed_row "$tie_a" tie-a-a "Tie A A" 2026-07-10
  append_landed_row "$tie_a" tie-a-z "Tie A Z" 2026-07-10
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  actual=$(printf '%s' "$json" | jq -r '.landed[] | "\(.owner)/\(.id)"')
  expected='tie-a/tie-a-z
tie-b/tie-b-z
tie-a/tie-a-a
tie-b/tie-b-a'
  [ "$actual" = "$expected" ] || fail "landed tie ordering changed: $actual"
  pass "landed selection preserves deterministic home and internal tie ordering"
}

test_landed_default_handles_no_landed_items() {
  local home fakebin json
  home=$(make_home landed-empty)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.landed | length) == 0
      and ([.omitted[].surface] | any(test("landed")) | not)
  ' >/dev/null || fail "empty landed set was not handled cleanly: $json"
  pass "landed selection handles no landed items"
}

test_all_landed_keeps_complete_global_order() {
  local home alpha beta fakebin json actual expected
  home=$(make_home landed-all-order)
  : > "$home/data/secondmates.md"
  printf '## Done\n' > "$home/data/backlog.md"
  alpha=$(make_landed_secondmate "$home" alpha)
  beta=$(make_landed_secondmate "$home" beta)
  append_landed_row "$alpha" alpha-old "Alpha old" 2026-07-01
  append_landed_row "$alpha" alpha-new "Alpha new" 2026-07-09
  append_landed_row "$beta" beta-new "Beta new" 2026-07-10
  append_landed_row "$beta" beta-mid "Beta mid" 2026-07-05
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_LANDED=1 run "$home" "$fakebin" --json --all-landed)
  actual=$(printf '%s' "$json" | jq -r '.landed[] | "\(.owner)/\(.id)"')
  expected='beta/beta-new
alpha/alpha-new
beta/beta-mid
alpha/alpha-old'
  [ "$actual" = "$expected" ] || fail "--all-landed global order changed: $actual"
  printf '%s' "$json" | jq -e '
    (.landed | length) == 4
      and ([.omitted[].surface] | any(test("landed|snapshot layer")) | not)
  ' >/dev/null || fail "--all-landed no longer revealed the complete landed set: $json"
  pass "--all-landed keeps the complete global landed output"
}

# The roll-up stays bounded: a per-home cap and an overall cap, both disclosed in
# omitted[], with --all-landed as the counted expansion knob. This also covers the
# previously-silent main-home landed truncation.
test_landed_bounded_and_disclosed() {
  local home mate fakebin json i expected actual
  home=$(make_home mate-landed-caps); write_fixture "$home"
  mate=$(fixture_mate_home "$home")
  {
    printf '## In flight\n'
    printf '%s\n\n' '- [ ] mate - Decide subscription order (repo: firstmate) (kind: ship) (since 2026-07-11)'
    printf '## Done\n'
  } > "$mate/data/backlog.md"
  i=1
  while [ "$i" -le 12 ]; do
    printf -- '- [x] mate-landed-%02d - Secondmate fix %02d (repo: firstmate) (kind: ship) (merged 2026-06-%02d)\n' \
      "$i" "$i" "$((13 - i))" >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_LANDED=20 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.landed[].id | select(startswith("mate-landed-"))] | length) == 10
      and ([.omitted[].surface] | any(test("snapshot layer")))
  ' >/dev/null || fail "default landed path must retain and disclose the snapshot per-home cap: $json"
  json=$(FM_BEARINGS_LANDED=1 run "$home" "$fakebin" --json --all-landed)
  expected=done-a
  i=1
  while [ "$i" -le 12 ]; do
    expected="$expected
$(printf 'mate-landed-%02d' "$i")"
    i=$((i + 1))
  done
  expected=$(printf '%s\n' "$expected" | LC_ALL=C sort)
  actual=$(printf '%s' "$json" | jq -r '.landed[].id' | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || fail "--all-landed returned wrong identities: $actual"
  printf '%s' "$json" | jq -e '
    (.landed | length) == 13
      and ([.omitted[].surface] | any(test("landed|snapshot layer")) | not)
  ' >/dev/null || fail "--all-landed must reveal the exact full landed set: $json"
  pass "landed stays bounded with per-home + overall caps and omitted[] disclosure"
}

# Bearings projects authoritative structured state rather than inventing return
# policy. A live blocked child remains a live in-flight record with state=blocked
# and an open blocker; it must never be converted into a queued `gates` record.
# The return-catch-up owner prevents this state from reaching ordinary rendering
# during an away return, while this test pins Bearings' own projection boundary.
test_live_blocker_is_not_charted_queue_work() {
  local home fakebin json
  home=$(make_home live-blocker); write_fixture "$home"
  printf 'blocked [key=synthetic-dependency]: firstmate can refresh the synthetic token\n' > "$home/state/ship-task.status"
  record_claude_state "$home/state" ship-task idle
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.[]; .id == "ship-task" and .state == "blocked"))
      and (.decisions_open | any(.[]; .id == "ship-task") | not)
      and (.gates | any(.[]; .id == "ship-task") | not)
  ' >/dev/null || fail "live blocked work was projected as queued/deferred work: $json"
  pass "Bearings keeps a live blocker in structured live state and never converts it to Charted Next queue work"
}

# Captain's Call is populated only from the durable keyed open-decision set. The
# anti-leak guard: action-free highlights - a working task, a completed scout,
# queued/gated items, landed work - must never surface as an open decision, so they
# cannot leak into Captain's Call. The standard fixture has exactly one genuine open
# decision (the secondmate's structured captain hold).
test_captains_call_anti_leak() {
  local home fakebin json canonical
  home=$(make_home anti-leak); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  jq -n -e --argjson bearings "$json" --argjson canonical "$canonical" '
    ([$bearings.decisions_open[].id] == ["mate/mate-decision-race"])
      and ($canonical.secondmate_current.records[] | select(.id == "mate")
        | (.decisions_open | any(.source == "status"))
          and (.decisions_open | any(.source == "backlog")))
      and ([$bearings.decisions_open[].id] | index("ship-task") | not)
      and ([$bearings.decisions_open[].id] | index("scout-x") | not)
      and ([$bearings.decisions_open[].id] | index("external-wait") | not)
      and ([$bearings.decisions_open[].id] | index("done-a") | not)
      and ([$bearings.decisions_open[].id] | index("mate-landed") | not)
      and ([$bearings.decisions_open[].id] | index("live-gate") | not)
      and ([$bearings.decisions_open[].id] | index("dead-gate") | not)
  ' >/dev/null || fail "only genuine open decisions may feed Captain's Call: $json"
  pass "action-free items (working/done/queued/landed) do not leak into Captain's Call"
}

# R1: main-home orphan in-flight and unstructured current rows must not vanish
# silently. Meta remains the sole live-work inventory; disclosure is via
# main_inventory + omitted[] + a Charted Next gate line, never fake Underway.
test_main_orphan_in_flight_is_disclosed_not_invented() {
  local home fakebin json canonical
  home=$(make_home main-orphan)
  : > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] only-orphan - Structured in flight without meta (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "in-flight backlog item has no child metadata"
      and (.main_inventory.orphan_in_flight == ["only-orphan"])
      and .main_inventory.unstructured_current_count == 0
      and (.tasks | length) == 0
  ' >/dev/null || fail "canonical main inventory missed orphan: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | length) == 0
      and ([.in_flight[].id] | index("only-orphan") | not)
      and ([.decisions_open[].id] | index("only-orphan") | not)
      and (.gates | any(.id == "(main-inventory)"
        and (.title | contains("in-flight backlog item has no child metadata"))))
      and (.omitted | any(.surface == "main in-flight backlog item(s) have no child metadata: 1"))
  ' >/dev/null || fail "orphan in-flight was invented or not disclosed: $json"
  pass "main orphan in-flight stays out of Underway and is disclosed in omitted/gates"
}

test_main_unstructured_current_is_disclosed_with_structured_sibling() {
  local home fakebin json canonical
  home=$(make_home main-unstructured)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/structured-ship"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
this current row is not structured
- [ ] structured-ship - Visible structured sibling (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
another free-form note without checkbox
- [ ] structured-queued - Structured queued (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/structured-ship.meta" \
    "window=firstmate:fm-structured-ship" \
    "worktree=$home/projects/structured-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: structured sibling still projects\n' > "$home/state/structured-ship.status"
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight | length) == 0
  ' >/dev/null || fail "canonical main inventory missed unstructured current: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] == ["structured-ship"])
      and ([.gates[].id] | index("structured-queued") != null)
      and (.gates | any(.id == "(main-inventory)"
        and (.title | contains("unstructured current backlog row"))))
      and (.omitted | any(.surface == "main unstructured current backlog row(s): 2"))
      and ([.decisions_open[].id] | index("(main-inventory)") | not)
  ' >/dev/null || fail "unstructured current not disclosed or structured sibling lost: $json"
  pass "main unstructured current is disclosed while structured siblings still project"
}

test_main_orphan_counterfactual_meta_clears_inventory_warning() {
  local home fakebin json_before json_after
  home=$(make_home main-orphan-counterfactual)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/orphan-ship"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Gains meta in counterfactual (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Already live (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Ordinary queue (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/orphan-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: visible sibling\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  json_before=$(run "$home" "$fakebin" --json)
  printf '%s' "$json_before" | jq -e '
    ([.in_flight[].id] == ["visible-ship"])
      and ([.in_flight[].id] | index("orphan-ship") | not)
      and (.omitted | any(.surface == "main in-flight backlog item(s) have no child metadata: 1"))
      and (.gates | any(.id == "(main-inventory)"))
      and ([.gates[].id] | index("queued-ship") != null)
  ' >/dev/null || fail "pre-meta orphan fixture failed: $json_before"
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/orphan-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: orphan now has meta\n' > "$home/state/orphan-ship.status"
  json_after=$(run "$home" "$fakebin" --json)
  printf '%s' "$json_after" | jq -e '
    ([.in_flight[].id] | sort) == ["orphan-ship", "visible-ship"]
      and ([.omitted[].surface] | any(test("main in-flight backlog item")) | not)
      and ([.gates[].id] | index("(main-inventory)") | not)
      and ([.decisions_open[].id] | index("orphan-ship") | not)
  ' >/dev/null || fail "adding meta did not clear inventory warning or project orphan: $json_after"
  pass "counterfactual meta clears main inventory warning and projects the live task"
}

seed_working_child() {  # <mate-home> <id> <doing> [repo]
  local mate=$1 id=$2 doing=$3 repo=${4-sample} repo_field=
  mkdir -p "$mate/projects/$id"
  [ -z "$repo" ] || repo_field=" (repo: $repo)"
  printf -- '- [ ] %s - %s%s (kind: ship) (since 2026-07-13)\n' \
    "$id" "$doing" "$repo_field" >> "$mate/data/backlog.md"
  fm_write_meta "$mate/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$mate/projects/$id" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" "$id" busy
  printf 'working: %s\n' "$doing" > "$mate/state/$id.status"
}

test_active_children_project_independent_of_home_captain_hold() {
  local home mate fakebin json
  home=$(make_home underway-hold-parent)
  : > "$home/data/secondmates.md"
  mate="$TMP_ROOT/underway-hold-home"
  make_valid_secondmate_home busy-hold "$mate"
  append_secondmate_registry "$home" busy-hold "$mate"
  fakebin=$(make_fakebin "$home")

  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
EOF
  seed_working_child "$mate" child-a "first live child" ""
  seed_working_child "$mate" child-b "second live child"
  cat >> "$mate/data/backlog.md" <<'EOF'

## Queued
- [ ] release-call - Choose release route (repo: sample) (kind: captain) (hold: pick route A or B) (hold-kind: captain)

## Done
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] | sort) == ["busy-hold/child-a", "busy-hold/child-b"]
      and ([.in_flight[].state] | unique) == ["working"]
      and ([.in_flight[].repo] | unique) == ["sample"]
      and ([.in_flight[] | select(.id == "busy-hold")] | length) == 0
      and ([.decisions_open[] | select(.id == "busy-hold/release-call"
        and .verb == "captain-hold")] | length) == 1
      and (.secondmates | any(.id == "busy-hold" and .state == "captain_decision"))
  ' >/dev/null || fail "a captain hold hid active children from Underway: $json"

  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] release-call - Choose release route (repo: sample) (kind: captain) (hold: pick route A or B) (hold-kind: captain)

## Done
EOF
  rm -f "$mate/state/child-a.meta" "$mate/state/child-a.status" \
    "$mate/state/child-b.meta" "$mate/state/child-b.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[] | select(.id | startswith("busy-hold/"))] | length) == 0
      and ([.decisions_open[] | select(.id == "busy-hold/release-call")] | length) == 1
      and (.secondmates | any(.id == "busy-hold" and .state == "captain_decision"))
  ' >/dev/null || fail "a hold-only home invented Underway rows: $json"

  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
EOF
  seed_working_child "$mate" child-a "first live child"
  seed_working_child "$mate" child-b "second live child"
  cat >> "$mate/data/backlog.md" <<'EOF'

## Queued

## Done
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] | sort) == ["busy-hold/child-a", "busy-hold/child-b"]
      and ([.decisions_open[] | select(.owner == "busy-hold")] | length) == 0
      and (.secondmates | any(.id == "busy-hold" and .state == "active_child_work"))
  ' >/dev/null || fail "active-children-only Underway projection changed: $json"
  pass "active children reach Underway independently of a home captain hold"
}

test_mixed_secondmate_roles_partial_state_and_captain_readiness() {
  local home fakebin hibit wheel sshhip ha canonical json
  home=$(make_home mixed-domain-regressions)
  : > "$home/data/secondmates.md"
  hibit="$TMP_ROOT/mixed-hibit-home"
  wheel="$TMP_ROOT/mixed-wheel-home"
  sshhip="$TMP_ROOT/mixed-sshhip-home"
  ha="$TMP_ROOT/mixed-ha-home"
  make_valid_secondmate_home hibit "$hibit"
  make_valid_secondmate_home wheel "$wheel"
  make_valid_secondmate_home sshhip "$sshhip"
  make_valid_secondmate_home home-assistant "$ha"
  append_secondmate_registry "$home" hibit "$hibit"
  append_secondmate_registry "$home" wheel "$wheel"
  append_secondmate_registry "$home" sshhip "$sshhip"
  append_secondmate_registry "$home" home-assistant "$ha"

  mkdir -p "$hibit/projects/worker" "$wheel/projects/worker" "$sshhip/projects/child" "$ha/projects/prep"
  cat > "$hibit/data/backlog.md" <<'EOF'
## In flight
- [ ] dogfood-program - Long-lived dogfood program (repo: hibit) (kind: program)
- [ ] hibit-worker - Finalize progress (repo: hibit) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$hibit/state/hibit-worker.meta" \
    "window=firstmate:fm-hibit-worker" "worktree=$hibit/projects/worker" "project=hibit" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$hibit/state" hibit-worker busy
  printf 'working: finalizing progress\n' > "$hibit/state/hibit-worker.status"

  cat > "$wheel/data/backlog.md" <<'EOF'
## In flight
- [ ] production-observation - Observe production (repo: wheelhouse) (kind: scout) (hold: documented no live worker) (hold-kind: external)
- [ ] wheel-worker - Initial triage (repo: wheelhouse) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$wheel/state/wheel-worker.meta" \
    "window=firstmate:fm-wheel-worker" "worktree=$wheel/projects/worker" "project=wheelhouse" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$wheel/state" wheel-worker busy
  printf 'working: active validation\n' > "$wheel/state/wheel-worker.status"

  cat > "$sshhip/data/backlog.md" <<'EOF'
## In flight
- [ ] unreadable-child - Submit App Store build (repo: sshhip) (kind: ship)

## Queued
- [ ] reviewer-decision - Choose reviewer remediation (repo: sshhip) (kind: captain) (hold: choose reviewer remediation A or B) (hold-kind: captain)

## Done
- [x] prior-release - Prior release (repo: sshhip) (kind: ship) (done 2026-07-21)
EOF
  fm_write_meta "$sshhip/state/unreadable-child.meta" \
    "window=firstmate:dead-sshhip-child" "worktree=$sshhip/projects/child" "project=sshhip" \
    "harness=codex" "kind=ship" "mode=no-mistakes"

  cat > "$ha/data/backlog.md" <<'EOF'
## In flight
- [ ] prep - Prepare canary (repo: home-assistant) (kind: ship)

## Queued
- [ ] security - Security review (repo: home-assistant) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: security (repo: home-assistant) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$ha/state/prep.meta" \
    "window=firstmate:fm-prep" "worktree=$ha/projects/prep" "project=home-assistant" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$ha/state" prep busy
  printf 'working: preparing canary\n' > "$ha/state/prep.status"

  fakebin=$(make_fakebin "$home")
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    (.secondmate_current.records[] | select(.id == "hibit")
      | .current.state == "active_child_work"
        and [.active_children[].id] == ["hibit-worker"]
        and ([.endpoints[].id] | index("dogfood-program") | not))
      and (.secondmate_current.records[] | select(.id == "wheel")
        | .current.state == "active_child_work"
          and [.active_children[].id] == ["wheel-worker"]
          and [.queued[].id] == ["production-observation"]
          and [.holds[].id] == ["production-observation"])
      and (.secondmate_current.records[] | select(.id == "sshhip")
        | .current.state == "unknown"
          and (.current.reason | contains("child current state unavailable: unreadable-child"))
          and .provenance.selected == "structured-home"
          and .provenance.summary_valid == false
          and .provenance.trust == "partial-structured"
          and .invalidity == {kind:"child_current_unavailable",ids:["unreadable-child"]}
          and [.decisions_open[].id] == ["reviewer-decision"]
          and [.holds[].id] == ["reviewer-decision"]
          and [.queued[].id] == ["reviewer-decision"]
          and [.landed[].id] == ["prior-release"]
          and [.endpoints[].id] == ["unreadable-child"]
          and .counts.decisions_open == 1
          and .counts.holds == 1
          and .counts.queued == 1
          and .counts.landed == 1
          and .counts.endpoints == 1)
      and (.secondmate_landed.partial | length) == 1
      and (.secondmate_landed.partial[0] | endswith("/mixed-sshhip-home"))
      and (.secondmate_landed.unreadable | length) == 0
      and (.secondmate_current.records[] | select(.id == "home-assistant")
        | .current.state == "active_child_work"
          and .decisions_open == []
          and [.active_children[].id] == ["prep"]
          and (.queued[] | select(.id == "captain-run")
            | .blocked_by_ids == ["prep", "security"]
              and .unresolved_blocker_ids == ["prep", "security"]
              and .captain_actionable == false))
  ' >/dev/null || fail "canonical mixed-domain classification was wrong: $canonical"
  json=$(run "$home" "$fakebin" --json --fields bodies --all-landed)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] | sort) == ["hibit/hibit-worker", "home-assistant/prep", "wheel/wheel-worker"]
      and (.decisions_open | any(.id == "sshhip/reviewer-decision"))
      and (.decisions_open | any(.id == "home-assistant/captain-run") | not)
      and (.gates | any(.id == "production-observation" and .owner == "wheel"
        and .reason == "documented no live worker"))
      and (.gates | any(.id == "captain-run" and .owner == "home-assistant"
        and .blocked_by == "prep,security"))
      and (.secondmates | any(.id == "sshhip" and .state == "unknown"
        and (.reason | contains("unreadable-child"))))
  ' >/dev/null || fail "end-to-end mixed-domain projection was wrong: $json"

  sed '/unreadable-child/a\
- [ ] ordinary-orphan - Unowned release task (repo: sshhip) (kind: ship)' \
    "$sshhip/data/backlog.md" > "$sshhip/data/backlog.next"
  mv "$sshhip/data/backlog.next" "$sshhip/data/backlog.md"
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "sshhip")
    | .current.state == "unknown"
      and (.current.reason | contains("in-flight backlog item has no child metadata: ordinary-orphan"))
      and .provenance.selected == "structured-home"
      and .provenance.trust == "partial-structured"
      and .invalidity == {kind:"orphan_in_flight",ids:["ordinary-orphan"]}
      and [.decisions_open[].id] == ["reviewer-decision"]
      and [.holds[].id] == ["reviewer-decision"]
      and [.queued[].id] == ["reviewer-decision"]
      and [.landed[].id] == ["prior-release"]
      and [.endpoints[].id] == ["unreadable-child"]
  ' >/dev/null || fail "an ordinary orphan discarded a readable home alongside an unknown child: $canonical"
  sed '/ordinary-orphan/d' "$sshhip/data/backlog.md" > "$sshhip/data/backlog.next"
  mv "$sshhip/data/backlog.next" "$sshhip/data/backlog.md"

  sed '/unreadable-child/d' "$sshhip/data/backlog.md" > "$sshhip/data/backlog.next"
  mv "$sshhip/data/backlog.next" "$sshhip/data/backlog.md"
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "sshhip")
    | .current.state == "unknown"
      and (.current.reason | contains("live child state has no in-flight backlog item: unreadable-child=unknown"))
      and .provenance.selected == "structured-home"
      and .provenance.trust == "partial-structured"
      and .invalidity == {kind:"unowned_current",ids:["unreadable-child"]}
      and [.decisions_open[].id] == ["reviewer-decision"]
      and [.holds[].id] == ["reviewer-decision"]
      and [.queued[].id] == ["reviewer-decision"]
      and [.landed[].id] == ["prior-release"]
  ' >/dev/null || fail "an unowned unknown child discarded the readable home: $canonical"
  sed '/## In flight/a\
- [ ] unreadable-child - Submit App Store build (repo: sshhip) (kind: ship)' \
    "$sshhip/data/backlog.md" > "$sshhip/data/backlog.next"
  mv "$sshhip/data/backlog.next" "$sshhip/data/backlog.md"

  fm_write_meta "$wheel/state/production-observation.meta" \
    "window=firstmate:fm-production-observation" "worktree=$wheel/projects/worker" "project=wheelhouse" \
    "harness=claude" "kind=scout" "mode=scout"
  record_claude_state "$wheel/state" production-observation idle
  printf 'paused: observation is deliberately held\n' > "$wheel/state/production-observation.status"
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "wheel")
    | ([.queued[] | select(.id == "production-observation")] | length) == 1
      and ([.holds[] | select(.id == "production-observation")] | length) == 1
      and ([.endpoints[] | select(.id == "production-observation")] | length) == 1
  ' >/dev/null || fail "held metadata plus a real child duplicated or discarded the record: $canonical"

  fm_write_meta "$sshhip/state/unreadable-child.meta" \
    "window=firstmate:fm-unreadable-child" "worktree=$sshhip/projects/child" "project=sshhip" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$sshhip/state" unreadable-child busy
  printf 'working: app store submission restored\n' > "$sshhip/state/unreadable-child.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.secondmates | any(.id == "sshhip" and .state == "captain_decision" and .reason == "-"))
      and ([.decisions_open[] | select(.id == "sshhip/reviewer-decision")] | length) == 1
  ' >/dev/null || fail "restoring the SSHHIP child did not clear only its narrow warning: $json"

  cat > "$ha/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] security - Security review (repo: home-assistant) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: security (repo: home-assistant) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: home-assistant) (kind: ship) (done 2026-07-22)
EOF
  rm "$ha/state/prep.meta" "$ha/state/prep.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "home-assistant/captain-run") | not)
      and (.gates | any(.id == "captain-run" and .owner == "home-assistant" and .blocked_by == "security"))
  ' >/dev/null || fail "one remaining Home Assistant blocker became actionable: $json"

  cat > "$ha/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: security (repo: home-assistant) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: home-assistant) (kind: ship) (done 2026-07-22)
- [x] security - Security review (repo: home-assistant) (kind: ship) (done 2026-07-22)
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.decisions_open[] | select(.id == "home-assistant/captain-run")] | length) == 1
      and (.gates | any(.id == "captain-run" and .owner == "home-assistant") | not)
  ' >/dev/null || fail "zero Home Assistant blockers did not yield exactly one captain action: $json"

  sed 's/blocked-by: security/blocked-by: missing/' "$ha/data/backlog.md" > "$ha/data/backlog.next"
  mv "$ha/data/backlog.next" "$ha/data/backlog.md"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "home-assistant/captain-run") | not)
      and (.gates | any(.id == "captain-run" and .owner == "home-assistant" and .blocked_by == "missing"))
  ' >/dev/null || fail "a missing Home Assistant blocker was treated as Done: $json"

  sed 's/(kind: program)/(kind: mystery)/' "$hibit/data/backlog.md" > "$hibit/data/backlog.next"
  mv "$hibit/data/backlog.next" "$hibit/data/backlog.md"
  refresh_local_secondmate_ledgers "$home"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "hibit")
    | .current.state == "active_child_work"
      and (.current.reason | contains("in-flight backlog item has no child metadata: dogfood-program"))
      and .provenance.selected == "structured-home"
      and .provenance.trust == "partial-structured"
      and .invalidity == {kind:"orphan_in_flight",ids:["dogfood-program"]}
      and [.active_children[].id] == ["hibit-worker"]
      and [.endpoints[].id] == ["hibit-worker"]
  ' >/dev/null || fail "an unrecognized worker kind hid the home's live work: $canonical"
  pass "mixed secondmate roles, partial state, and captain readiness project independently"
}

test_main_captain_readiness_matches_secondmate_projection() {
  local home fakebin json
  home=$(make_home main-captain-readiness)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/prep" "$home/projects/observation"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] observation - Held observation (repo: firstmate) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] prep - Prepare canary (repo: firstmate) (kind: ship)

## Queued
- [ ] review - Security review (repo: firstmate) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/prep.meta" \
    "window=firstmate:fm-prep" "worktree=$home/projects/prep" "project=firstmate" \
    "harness=codex" "kind=ship" "mode=no-mistakes"
  printf 'working: preparing main canary\n' > "$home/state/prep.status"
  fm_write_meta "$home/state/observation.meta" \
    "window=firstmate:fm-observation" "worktree=$home/projects/observation" "project=firstmate" \
    "harness=codex" "kind=scout" "mode=scout"
  printf 'paused: observation is deliberately held\n' > "$home/state/observation.status"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.id == "prep"))
      and (.in_flight | any(.id == "observation") | not)
      and ([.gates[] | select(.id == "observation" and .reason == "watch production")] | length) == 1
      and (.decisions_open | any(.id == "captain-run") | not)
      and (.gates | any(.id == "captain-run" and .blocked_by == "prep,review"))
  ' >/dev/null || fail "main blocked captain action or held-child projection was wrong: $json"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] review - Security review (repo: firstmate) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: firstmate) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/prep.meta" "$home/state/prep.status" \
    "$home/state/observation.meta" "$home/state/observation.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "captain-run") | not)
      and (.gates | any(.id == "captain-run" and .blocked_by == "review"))
  ' >/dev/null || fail "main one-blocker captain action became premature: $json"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: firstmate) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: firstmate) (kind: ship) (done 2026-07-22)
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.decisions_open[] | select(.id == "captain-run")] | length) == 1
      and (.gates | any(.id == "captain-run") | not)
  ' >/dev/null || fail "main zero-blocker captain action was not projected exactly once: $json"
  pass "main and secondmate captain actionability use the same blocker readiness"
}

test_task_teardown_during_metadata_capture_does_not_abort_snapshot() {
  local home fakebin real_cp output snapshot_pid i
  home=$(make_home metadata-teardown-race)
  fakebin=$(make_fakebin "$home")
  real_cp=$(command -v cp)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] a-hold - Stable local worker (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/a-hold.meta" \
    "window=fixture:a-hold" "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/z-gone.meta" \
    "window=fixture:z-gone" "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working: stable fixture\n' > "$home/state/a-hold.status"
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */a-hold.meta)
      : > "$FAKE_CP_STARTED"
      while [ ! -e "$FAKE_CP_RELEASE" ]; do sleep 0.01; done
      break
      ;;
  esac
done
exec "$REAL_CP" "$@"
SH
  chmod +x "$fakebin/cp"

  REAL_CP="$real_cp" FAKE_CP_STARTED="$home/cp-started" FAKE_CP_RELEASE="$home/cp-release" \
    run "$home" "$fakebin" --json > "$home/snapshot.json" &
  snapshot_pid=$!
  i=0
  while [ ! -e "$home/cp-started" ] && [ "$i" -lt 500 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$home/cp-started" ]; then
    kill "$snapshot_pid" 2>/dev/null || true
    wait "$snapshot_pid" 2>/dev/null || true
    fail "snapshot never entered metadata capture"
  fi
  rm -f "$home/state/z-gone.meta"
  : > "$home/cp-release"
  wait "$snapshot_pid" || fail "task teardown aborted the public Bearings snapshot"
  output=$(<"$home/snapshot.json")
  printf '%s' "$output" | jq -e '
    .schema == "fm-bearings.v1"
      and ([.in_flight[].id] | sort) == ["a-hold"]
  ' >/dev/null || fail "snapshot after concurrent teardown was not usable: $output"
  pass "task teardown during metadata capture is omitted without aborting the snapshot"
}

test_current_state_uses_captured_status_observation() {
  local home fakebin real_cp worktree json
  home=$(make_home captured-status-race)
  fakebin=$(make_fakebin "$home")
  real_cp=$(command -v cp)
  worktree="$home/projects/captured-status"
  mkdir -p "$worktree"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] captured-status - Captured status fixture (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/captured-status.meta" \
    "window=fixture:captured-status" "worktree=$worktree" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=stable-generation"
  printf 'working: captured state\n' > "$home/state/captured-status.status"
  record_claude_state "$home/state" captured-status idle
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
"$REAL_CP" "$@" || exit
for arg in "$@"; do
  if [ "$arg" = "$RACE_STATUS" ] && mkdir "$RACE_ONCE" 2>/dev/null; then
    printf 'needs-decision[new]: appended after capture\n' >> "$RACE_STATUS"
    break
  fi
done
SH
  chmod +x "$fakebin/cp"

  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 NET_LOG="$home/net.log" REAL_CP="$real_cp" \
    RACE_ONCE="$home/status-race-once" RACE_STATUS="$home/state/captured-status.status" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot failed during captured status race"
  printf '%s' "$json" | jq -e '
    .tasks[] | select(.id == "captured-status")
    | .current_state.state == "working"
      and .current_state.source == "status-log"
      and .paths.status_log.last_event.raw == "working: captured state"
      and .hints.pending_decision == false
      and .hints.open_decisions == []
  ' >/dev/null || fail "current state escaped the captured status observation: $json"
  [ "$(tail -n 1 "$home/state/captured-status.status")" = \
      "needs-decision[new]: appended after capture" ] \
    || fail "captured status race fixture did not append the live decision"
  pass "current state and decision hints share one captured status observation"
}

test_relaunched_task_does_not_inherit_reused_endpoint_state() {
  local home fakebin worktree json
  home=$(make_home endpoint-generation-race)
  worktree="$home/projects/generation-race-not-created"
  fakebin=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] generation-race - Generation identity fixture (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/generation-race.meta" \
    "window=fixture:fm-generation-race" "worktree=$worktree" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=old-generation"
  printf 'working: old generation\n' > "$home/state/generation-race.status"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  if mkdir "$RACE_ONCE" 2>/dev/null; then
    tmp="$RACE_META.tmp.$$"
    cat > "$tmp" <<EOF
window=fixture:fm-generation-race
worktree=$RACE_WORKTREE
project=firstmate
harness=claude
kind=ship
mode=no-mistakes
spawn_gen=new-generation
EOF
    mv "$tmp" "$RACE_META"
    printf 'needs-decision[replacement]: replacement-only decision https://github.com/acme/firstmate/pull/999\n' > "$RACE_STATUS"
    mkdir -p "$(dirname "$RACE_REPORT")"
    printf 'replacement-only report\n' > "$RACE_REPORT"
  fi
  # The old endpoint disappeared while a replacement reused the same target.
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/tmux"

  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 NET_LOG="$home/net.log" \
    RACE_ONCE="$home/relaunch-once" RACE_META="$home/state/generation-race.meta" \
    RACE_STATUS="$home/state/generation-race.status" \
    RACE_REPORT="$home/data/generation-race/report.md" RACE_WORKTREE="$worktree" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot failed during endpoint generation race"
  printf '%s' "$json" | jq -e '
    .tasks[] | select(.id == "generation-race")
    | .spawn_gen == "old-generation"
      and .current_state.state == "unknown"
      and .endpoint.exists == null
      and .endpoint.agent_alive == "unknown"
      and .endpoint.status == "unknown"
      and .pr.url == null
      and .paths.status_log.present == false
      and .paths.report.present == false
      and .hints.pending_decision == false
      and .hints.open_decisions == []
      and .hints.scout_report_present == false
      and .hints.last_event_text == ""
  ' >/dev/null || fail "replacement live state crossed task generations: $json"
  pass "reused live state is discarded when task generation changes"
}

test_large_local_snapshot_overlaps_local_reads_without_projection_drift() {
  local home fakebin worktree serial parallel parallel_file snapshot_pid i
  local serial_started serial_elapsed parallel_started parallel_elapsed saved
  home=$(make_home large-local-snapshot)
  worktree="$home/projects/shared-worktree"
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -qb fm/synthetic-large-local
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "axi status" ] && [ "${FAKE_NM_DELAY:-0}" = 1 ]; then
  [ -z "${FAKE_NM_SIGNAL:-}" ] || : > "$FAKE_NM_SIGNAL"
  sleep 1
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"

  {
    printf '## In flight\n'
    i=1
    while [ "$i" -le 5 ]; do
      printf -- '- [ ] local-%s - Synthetic local worker %s (repo: firstmate) (kind: ship)\n' "$i" "$i"
      i=$((i + 1))
    done
    printf '\n## Queued\n\n## Done\n'
    i=1
    while [ "$i" -le 300 ]; do
      printf -- '- [x] history-%s - Historical completed item %s https://github.com/acme/firstmate/pull/%s (repo: firstmate) (kind: ship) (done 2026-01-01)\n' "$i" "$i" "$i"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"
  i=1
  while [ "$i" -le 5 ]; do
    fm_write_meta "$home/state/local-$i.meta" \
      "window=fixture:local-$i" "worktree=$worktree" "project=firstmate" \
      "harness=claude" "kind=ship" "mode=no-mistakes"
    printf 'working: synthetic fixture\n' > "$home/state/local-$i.status"
    i=$((i + 1))
  done

  serial=$(FAKE_NM_DELAY=0 FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 run "$home" "$fakebin" --json)

  # Serialized reads pay every worker's delay end to end while concurrent reads
  # overlap them. Time both runs and compare, because the two pay the same
  # composition overhead: the difference isolates the overlap this change
  # delivers, where an absolute wall-clock budget would instead measure how
  # loaded the host happens to be and flake on a busy runner.
  serial_started=$(date +%s)
  FAKE_NM_DELAY=1 FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 \
    run "$home" "$fakebin" --json >/dev/null \
    || fail "serialized local snapshot failed"
  serial_elapsed=$(( $(date +%s) - serial_started ))

  parallel_started=$(date +%s)
  parallel_file="$home/parallel-snapshot.json"
  FAKE_NM_DELAY=1 FAKE_NM_SIGNAL="$home/nm-started" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8 \
    run "$home" "$fakebin" --json > "$parallel_file" &
  snapshot_pid=$!
  i=0
  while [ ! -e "$home/nm-started" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -e "$home/nm-started" ]; then
    kill "$snapshot_pid" 2>/dev/null || true
    wait "$snapshot_pid" 2>/dev/null || true
    fail "concurrent local snapshot never began a current-state read"
  fi
  wait "$snapshot_pid" || fail "concurrent local snapshot failed"
  parallel=$(<"$parallel_file")
  parallel_elapsed=$(( $(date +%s) - parallel_started ))
  # Five one-second reads serialize into five seconds and overlap into about
  # one, so at least two of those four seconds must show up as real savings.
  # Serializing the reads again collapses that difference to roughly zero.
  saved=$(( serial_elapsed - parallel_elapsed ))
  [ "$saved" -ge 2 ] \
    || fail "concurrent local reads saved no measurable time (serial ${serial_elapsed}s vs concurrent ${parallel_elapsed}s)"
  [ "$parallel" = "$serial" ] \
    || fail "concurrent local observation changed the fm-bearings.v1 projection"
  printf '%s' "$parallel" | jq -e '
    .schema == "fm-bearings.v1"
      and (.in_flight | length) == 5
      and ([.in_flight[].id] | sort) == ["local-1","local-2","local-3","local-4","local-5"]
      and ([.in_flight[] | select(.id == "local-1" and .kind == "ship")] | length) == 1
  ' >/dev/null || fail "large local snapshot lost a worker row: $parallel"
  pass "large local snapshot overlaps local reads with byte-identical serial and concurrent projections"
}

test_remote_ledgers_share_one_concurrent_budget_and_fall_back_to_cache() {
  local parent fakebin json started elapsed i remote_home pid collector_pid sleeper_pid duplicate_base
  parent=$(make_home concurrent-remote-ledgers)
  make_remote_ledger_fleet "$parent" 5
  fakebin=$(make_remote_ledger_ssh "$parent/remote-ssh")
  : > "$parent/ledger-calls.log"
  : > "$parent/ledger-pids.log"

  json=$(run_remote_ledger_bearings "$parent" "$fakebin" 1100)
  [ "$(wc -l < "$parent/ledger-calls.log" | tr -d ' ')" -eq 5 ] \
    || fail "a healthy snapshot did not issue exactly one remote file read per home"
  printf '%s' "$json" | jq -e '
    (.secondmates | length) == 5
      and all(.secondmates[]; .freshness == "fresh" and .age_seconds == 100)
  ' >/dev/null || fail "healthy remote ledgers did not project their generated-epoch ages: $json"

  duplicate_base="$TMP_ROOT/remote-ledger-home-1/state/home-summary.single"
  cp "$TMP_ROOT/remote-ledger-home-1/state/home-summary.json" "$duplicate_base"
  cat "$duplicate_base" "$duplicate_base" > "$TMP_ROOT/remote-ledger-home-1/state/home-summary.json"
  : > "$parent/ledger-calls.log"
  json=$(run_remote_ledger_bearings "$parent" "$fakebin" 1100)
  printf '%s' "$json" | jq -e '
    ([.secondmates[] | select(.id == "ledger-1" and .freshness == "cached" and .age_seconds == 100)] | length) == 1
      and ([.secondmates[] | select(.id != "ledger-1" and .freshness == "fresh")] | length) == 4
  ' >/dev/null || fail "a multi-document live ledger bypassed the valid cache: $json"
  [ "$(wc -l < "$parent/ledger-calls.log" | tr -d ' ')" -eq 5 ] \
    || fail "rejecting a multi-document live ledger added remote reads"
  mv "$duplicate_base" "$TMP_ROOT/remote-ledger-home-1/state/home-summary.json"

  : > "$TMP_ROOT/remote-ledger-home-1/state/unbounded-ledger-read"
  : > "$parent/ledger-calls.log"
  json=$(run_remote_ledger_bearings "$parent" "$fakebin" 1100)
  printf '%s' "$json" | jq -e '
    ([.secondmates[] | select(.id == "ledger-1" and .freshness == "cached")] | length) == 1
      and ([.secondmates[] | select(.id != "ledger-1" and .freshness == "fresh")] | length) == 4
  ' >/dev/null || fail "an unbounded primary ledger stream consumed the shared collector budget: $json"
  [ "$(wc -l < "$parent/ledger-calls.log" | tr -d ' ')" -eq 5 ] \
    || fail "bounding one faulty primary ledger added remote reads"
  rm -f "$TMP_ROOT/remote-ledger-home-1/state/unbounded-ledger-read"

  i=1
  while [ "$i" -le 5 ]; do
    remote_home="$TMP_ROOT/remote-ledger-home-$i"
    : > "$remote_home/state/slow-ledger-read"
    i=$((i + 1))
  done
  : > "$parent/ledger-calls.log"
  : > "$parent/ledger-pids.log"
  started=$(date +%s)
  json=$(run_remote_ledger_bearings "$parent" "$fakebin" 2000)
  elapsed=$(( $(date +%s) - started ))
  # The three-second bound covers remote collection, while setup, cache validation,
  # and projection run outside it. Keep the end-to-end ceiling well below the
  # fifteen seconds that five serial three-second reads would require, without
  # treating slower stock-macOS jq/process startup as collector serialization.
  [ "$elapsed" -lt 12 ] || fail "five wedged remote reads behaved serially despite the shared three-second budget (${elapsed}s)"
  printf '%s' "$json" | jq -e '
    (.secondmates | length) == 5
      and all(.secondmates[]; .freshness == "cached" and .age_seconds == 1000
        and .provenance == "structured-home-cache")
      and ([.omitted[] | select(.surface | contains("served from cached home ledger"))] | length) == 5
  ' >/dev/null || fail "wedged homes did not use and disclose age-labeled cache rows: $json"
  sleep 0.3
  while read -r collector_pid sleeper_pid; do
    for pid in "$collector_pid" "$sleeper_pid"; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then
        fail "a cancelled remote ledger collector process survived the total budget (pid $pid)"
      fi
    done
  done < "$parent/ledger-pids.log"

  i=1
  while [ "$i" -le 5 ]; do
    remote_home="$TMP_ROOT/remote-ledger-home-$i"
    remote_home=$(cd "$remote_home" && pwd -P)
    rm -f "$remote_home/state/slow-ledger-read"
    write_remote_home_summary "$remote_home" 1990
    i=$((i + 1))
  done
  : > "$TMP_ROOT/remote-ledger-home-1/state/slow-ledger-read"
  : > "$parent/ledger-calls.log"
  : > "$parent/ledger-pids.log"
  json=$(run_remote_ledger_bearings "$parent" "$fakebin" 2000)
  printf '%s' "$json" | jq -e '
    ([.secondmates[] | select(.freshness == "fresh" and .age_seconds == 10)] | length) == 4
      and ([.secondmates[] | select(.id == "ledger-1" and .freshness == "cached"
        and .age_seconds == 1000 and .provenance == "structured-home-cache")] | length) == 1
      and ([.omitted[] | select(.surface == "secondmate ledger-1 served from cached home ledger")] | length) == 1
  ' >/dev/null || fail "one slow home prevented four fresh rows or hid its cache disclosure: $json"
  [ "$(wc -l < "$parent/ledger-calls.log" | tr -d ' ')" -eq 5 ] \
    || fail "the mixed-speed snapshot made more than one remote read per ledger home"
  pass "remote ledgers collect concurrently under one budget, reuse aged cache, and cancel wedged collectors"
}

test_a_remote_home_without_any_ledger_is_explicitly_unreadable_without_remote_compute() {
  local parent fakebin remote_home json
  parent=$(make_home remote-ledger-missing)
  make_remote_ledger_fleet "$parent" 1
  remote_home="$TMP_ROOT/remote-ledger-home-1"
  rm -f "$remote_home/state/home-summary.json" "$remote_home/state/slow-ledger-read"
  fakebin=$(make_remote_ledger_ssh "$parent/remote-ssh")
  : > "$parent/ledger-calls.log"
  : > "$parent/ledger-pids.log"

  json=$(run_remote_ledger_bearings "$parent" "$fakebin" 1100)
  printf '%s' "$json" | jq -e '
    (.secondmates | length) == 1
      and .secondmates[0].state == "unknown"
      and .secondmates[0].provenance == "unknown"
      and (.secondmates[0].reason | contains("home ledger is missing, unreadable, or invalid"))
      and (.omitted | any(.surface == "secondmate home(s) with unreadable structured state: 1"))
  ' >/dev/null || fail "a no-ledger remote home was not explicitly disclosed as unreadable: $json"
  [ "$(wc -l < "$parent/ledger-calls.log" | tr -d ' ')" -eq 1 ] \
    || fail "a no-ledger remote home issued more than its single ledger read"
  [ "$(awk -F '\t' 'NR == 1 { print $2 }' "$parent/ledger-calls.log")" = "fm-remote-file.sh" ] \
    || fail "a no-ledger remote home triggered remote summary computation: $(cat "$parent/ledger-calls.log")"
  pass "a missing remote ledger stays explicitly unreadable without remote summary computation"
}

test_task_teardown_during_metadata_capture_does_not_abort_snapshot
test_current_state_uses_captured_status_observation
test_relaunched_task_does_not_inherit_reused_endpoint_state
test_large_local_snapshot_overlaps_local_reads_without_projection_drift
test_remote_ledgers_share_one_concurrent_budget_and_fall_back_to_cache
test_a_remote_home_without_any_ledger_is_explicitly_unreadable_without_remote_compute
test_domain_alpha_stale_parent_event_does_not_become_current_work
test_gnu_stat_uses_file_formats_without_bsd_fallback_pollution
test_parent_activity_evidence_is_bounded_and_disclosed
test_active_child_overrides_old_parent_event
test_structured_child_decision_reaches_captains_call
test_bad_secondmate_homes_never_revive_parent_work
test_oversized_secondmate_summary_stays_strict_unknown
test_secondmate_and_child_bounds_are_disclosed
test_parent_decision_is_untrusted_contradiction_only
test_parent_evidence_reconciles_by_verb_and_key
test_nonprogressing_child_states_are_explicit
test_registry_unavailability_and_bounds_are_explicit
test_current_landed_baseline_is_repeatable_and_prior_report_independent
test_default_is_bounded_and_local_only
test_toon_json_parity
test_landed_includes_secondmate_home_merges
test_landed_default_balances_dominant_and_sparse_homes
test_landed_default_refills_capacity_after_sparse_homes_exhaust
test_landed_default_uses_deterministic_home_order_when_homes_exceed_cap
test_landed_default_preserves_internal_order_for_ties
test_landed_default_handles_no_landed_items
test_all_landed_keeps_complete_global_order
test_landed_bounded_and_disclosed
test_live_blocker_is_not_charted_queue_work
test_captains_call_anti_leak
test_main_orphan_in_flight_is_disclosed_not_invented
test_main_unstructured_current_is_disclosed_with_structured_sibling
test_main_orphan_counterfactual_meta_clears_inventory_warning
test_active_children_project_independent_of_home_captain_hold
test_mixed_secondmate_roles_partial_state_and_captain_readiness
test_main_captain_readiness_matches_secondmate_projection
test_completed_scout_report_not_pending
test_open_decision_surfaces_end_to_end
test_report_pointers_surface
test_superseded_queued_item_dropped_by_default
test_include_prs_is_the_only_fetch_path
test_partial_github_failure_degrades
test_perl_fallback_bounds_github_call
test_section_caps_and_expansion_flags
test_collapsed_captain_call_deferral_and_landed
test_pr_repository_cap_and_expansion
test_per_repository_pr_cap_is_disclosed
test_projection_and_toon_fail_closed
