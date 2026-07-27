#!/usr/bin/env bash
# Behavior tests for the agent kill-evidence chain:
#   bin/fm-resource-sample.sh   - per-agent RSS + machine memory sampling, and the
#                                 detector that notices an agent process vanished
#   bin/fm-agent-postmortem.sh  - the evidence record that says WHY it vanished
#   bin/fm-crew-state.sh        - surfaces the recorded cause, so a SIGKILLed crew
#                                 says so on the wake instead of just going quiet
#
# Hermetic: a fake `tmux` serves the pane pid and the pane text, and a fake `ps`
# serves a fixture process table, so no real process is spawned or killed here.
# (The mechanism was ALSO verified against a real `kill -9` and a real kernel
# SIGKILL on macOS - that evidence is in docs/agent-kill-evidence.md; these cases
# pin the logic so it stays fixed.)
#
#   (a) live agent            -> a sample line + state/<id>.agentpid
#   (b) non-tmux backend      -> no pid tracking at all (and never a false death)
#   (c) agent vanished        -> postmortem, abnormal=1, exit_signal read from the pane
#   (d) exited after `done:`  -> postmortem, abnormal=0 (a normal end, not a kill)
#   (e) existing postmortem   -> kept, not overwritten by a later look
#   (f) agent relaunched      -> old postmortem filed aside as .postmortem.prev
#   (g) crew-state            -> carries "agent died: ..." for an abnormal death
#   (h) memory snapshot       -> stable four-field shape on any platform
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-resource-lib.sh
. "$ROOT/bin/fm-resource-lib.sh"

SAMPLE="$ROOT/bin/fm-resource-sample.sh"
POSTMORTEM="$ROOT/bin/fm-agent-postmortem.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-kill-evidence)

# A fake tmux (pane pid from FM_FAKE_PANE_PID, pane text from FM_FAKE_PANE) and a
# fake ps (process table from FM_FAKE_PS, in the real `ps -eo pid=,ppid=,rss=,comm=`
# shape). Both are read by the lib exactly as the real tools are.
make_fakebin() {  # <dir> -> echoes fakebin path
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%s\n' "${FM_FAKE_PANE_PID:-}" ;;
  capture-pane)    printf '%s\n' "${FM_FAKE_PANE:-}" ;;
  # Pane presence is read by ENUMERATING live panes, because tmux answers
  # display-message for a gone window with another window's pane id
  # (bin/backends/tmux.sh's fm_backend_tmux_target_exists). Derive the list from
  # the same metas the scripts read, so a new case needs no fake change.
  list-panes)
    for _m in "${FM_HOME:-}"/state/*.meta; do
      [ -e "$_m" ] || continue
      _w=$(grep '^window=' "$_m" | tail -1 | cut -d= -f2-)
      [ -n "$_w" ] && printf '%s\n' "$_w"
    done
    ;;
  *)               exit 1 ;;
esac
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_PS:-}"
SH
  chmod +x "$fb/tmux" "$fb/ps"
  printf '%s\n' "$fb"
}

new_home() {  # <name> -> echoes home path with state/ and a worktree
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/wt"
  printf '%s\n' "$home"
}

# The agent is NOT a direct child of the pane shell (tmux -> shell -> treehouse ->
# shell -> agent, as on the real fleet), so the fixture nests it two levels down:
# the descendant walk has to actually walk.
PS_WITH_AGENT='  100     1  3000 -zsh
  200   100  7000 /bin/zsh
  300   200 450000 /Users/x/.local/bin/claude
  400     1  1000 /usr/bin/unrelated'
PS_NO_AGENT='  100     1  3000 -zsh
  200   100  7000 /bin/zsh
  400     1  1000 /usr/bin/unrelated'

FB=$(make_fakebin "$TMP_ROOT")
export PATH="$FB:$PATH"
export FM_FAKE_PANE_PID=100
# The postmortem's unified-log probe is a real system call; skip it here so a test
# run never waits on logd. The probe itself is exercised live in
# docs/agent-kill-evidence.md, which is where its (machine-specific) result belongs.
export FM_POSTMORTEM_SKIP_LOG_SHOW=1

# --- (a) live agent: one sample line + the agentpid record -------------------
HOME_A=$(new_home a)
fm_write_meta "$HOME_A/state/t1.meta" \
  "window=firstmate:fm-t1" "worktree=$HOME_A/wt" "project=$HOME_A/wt" \
  "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off"
FM_FAKE_PS=$PS_WITH_AGENT FM_HOME="$HOME_A" "$SAMPLE"
assert_present "$HOME_A/state/t1.resource" "(a) a live agent is sampled"
line=$(cat "$HOME_A/state/t1.resource")
assert_contains "$line" "pid=300" "(a) the sample names the agent pid, not the pane shell"
assert_contains "$line" "rss_kb=450000" "(a) the sample carries the agent's own RSS"
assert_contains "$line" "free_mb=" "(a) the sample carries the machine memory picture"
assert_contains "$(cat "$HOME_A/state/t1.agentpid")" "pid=300" "(a) the live agent pid is recorded"
assert_absent "$HOME_A/state/t1.postmortem" "(a) a live agent has no postmortem"
pass "(a) live agent sampled with RSS and machine memory"

# --- (b) a backend with no pane-pid query is skipped, never mis-read as dead --
HOME_B=$(new_home b)
fm_write_meta "$HOME_B/state/t2.meta" \
  "window=ws:fm-t2" "worktree=$HOME_B/wt" "project=$HOME_B/wt" \
  "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off" "backend=herdr"
FM_FAKE_PS=$PS_WITH_AGENT FM_HOME="$HOME_B" "$SAMPLE"
assert_absent "$HOME_B/state/t2.resource" "(b) no samples for a backend with no pane pid"
assert_absent "$HOME_B/state/t2.agentpid" "(b) no agent pid recorded"
FM_FAKE_PS=$PS_NO_AGENT FM_HOME="$HOME_B" "$SAMPLE"
assert_absent "$HOME_B/state/t2.postmortem" "(b) and never a phantom death for it"
pass "(b) non-tmux backend: no pid tracking, and no false death"

# --- (c) the agent vanishes: postmortem with the exit signal -----------------
HOME_C=$(new_home c)
fm_write_meta "$HOME_C/state/t3.meta" \
  "window=firstmate:fm-t3" "worktree=$HOME_C/wt" "project=$HOME_C/wt" \
  "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off"
echo "working: implementing" >> "$HOME_C/state/t3.status"
FM_FAKE_PS=$PS_WITH_AGENT FM_HOME="$HOME_C" "$SAMPLE"
export FM_FAKE_PANE='[1]    300 killed     claude --dangerously-skip-permissions'
FM_FAKE_PS=$PS_NO_AGENT FM_HOME="$HOME_C" "$SAMPLE"
assert_present "$HOME_C/state/t3.postmortem" "(c) a vanished agent gets a postmortem"
pm=$(cat "$HOME_C/state/t3.postmortem")
assert_contains "$pm" "abnormal=1" "(c) a kill with no done: report is abnormal"
assert_contains "$pm" "exit_signal=SIGKILL" "(c) the exit signal is read from the pane"
assert_contains "$pm" "agent_pid=300" "(c) the postmortem names the dead pid"
assert_contains "$pm" "mem_at_last_sample=" "(c) the memory picture at the death is kept"
assert_contains "$pm" "verdict=" "(c) a verdict is recorded"
assert_no_grep 'verdict=.*OOM kill' "$HOME_C/state/t3.postmortem" \
  "(c) a SIGKILL with no jetsam record is NEVER called an OOM kill"
pass "(c) vanished agent: postmortem with the exit signal and memory picture"

# --- (d) an agent that exited after reporting done is not a kill -------------
HOME_D=$(new_home d)
fm_write_meta "$HOME_D/state/t4.meta" \
  "window=firstmate:fm-t4" "worktree=$HOME_D/wt" "project=$HOME_D/wt" \
  "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off"
echo "done: PR https://example.invalid/pull/1" >> "$HOME_D/state/t4.status"
FM_FAKE_PS=$PS_WITH_AGENT FM_HOME="$HOME_D" "$SAMPLE"
FM_FAKE_PANE='' FM_FAKE_PS=$PS_NO_AGENT FM_HOME="$HOME_D" "$SAMPLE"
assert_grep 'abnormal=0' "$HOME_D/state/t4.postmortem" "(d) a normal exit is not abnormal"
pass "(d) exit after done: recorded, but not as a kill"

# --- (e) the postmortem is written once, at the death ------------------------
before=$(cat "$HOME_C/state/t3.postmortem")
FM_FAKE_PANE='' FM_HOME="$HOME_C" "$POSTMORTEM" t3 >/dev/null
assert_contains "$(cat "$HOME_C/state/t3.postmortem")" "$before" \
  "(e) a later look does not overwrite the evidence captured at the death"
pass "(e) evidence captured at the death is not overwritten"

# --- (f) a relaunched agent files the old postmortem aside -------------------
FM_FAKE_PS='  100     1  3000 -zsh
  200   100  7000 /bin/zsh
  777   200 320000 /Users/x/.local/bin/claude' FM_HOME="$HOME_C" "$SAMPLE"
assert_absent "$HOME_C/state/t3.postmortem" "(f) the dead agent's postmortem stops being surfaced"
assert_present "$HOME_C/state/t3.postmortem.prev" "(f) but the evidence is kept"
assert_grep 'pid=777' "$HOME_C/state/t3.agentpid" "(f) the new agent pid is tracked"
pass "(f) relaunched agent: old postmortem filed aside, evidence kept"

# --- (g) crew-state carries the recorded cause on the wake -------------------
# kind=scout, so no no-mistakes run lookup: the state comes from the pane/log
# fallback exactly as it would for a killed crew that never opened a validation.
HOME_G=$(new_home g)
fm_write_meta "$HOME_G/state/t5.meta" \
  "window=firstmate:fm-t5" "worktree=$HOME_G/wt" "project=$HOME_G/wt" \
  "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
echo "working: investigating" >> "$HOME_G/state/t5.status"
FM_FAKE_PS=$PS_WITH_AGENT FM_HOME="$HOME_G" "$SAMPLE"
FM_FAKE_PANE='[1]    300 killed     claude' FM_FAKE_PS=$PS_NO_AGENT FM_HOME="$HOME_G" "$SAMPLE"
out=$(FM_FAKE_PANE='idle' FM_HOME="$HOME_G" "$CREW_STATE" t5)
assert_contains "$out" "agent died:" "(g) crew-state says the agent died"
assert_contains "$out" "SIGKILL" "(g) and names the signal"
assert_contains "$out" ".postmortem" "(g) and points at the evidence"
# The status log still says `working:` - the crew never got to report anything
# else - so without this the wake would report a working crew whose agent is gone.
assert_contains "$out" "working" "(g) even while the status log still reads working"
pass "(g) crew-state surfaces the recorded cause of death"

# --- (h) the memory snapshot's shape is stable everywhere --------------------
snap=$(fm_res_mem_snapshot)
for field in free_mb= compressor_mb= swap_used_mb= memstat_level=; do
  assert_contains "$snap" "$field" "(h) memory snapshot carries $field"
done
pass "(h) memory snapshot shape is stable (fields degrade to unknown, never vanish)"
