#!/usr/bin/env bash
# Opt-in credentialed live E2E for bin/fm-sentinel.sh against a real Herdr
# restart. In one guarded named Herdr lab it runs a real Claude lab primary, a
# real seeded Claude second mate (the lead), and the lead's real Claude worker
# spawned by bin/fm-spawn.sh. With every turn ended and both watchers armed, it
# stops and restarts the lab server through bin/fm-herdr-lab.sh, which kills
# every agent and watcher the way an out-of-memory kill of the Herdr service
# does, and Herdr resumes the sessions it recorded. It then proves, with no
# human input:
#   - Herdr resumed the worker in its pane's creation folder (the primary
#     checkout), and a new spawn on that project refuses the pool slot the
#     worker's record still names once Treehouse reports it free;
#   - one sentinel tick in the primary's home detects the restart, orders the
#     lead to recover, and wakes the primary;
#   - the primary and the lead each re-arm supervision (fresh watcher beacons);
#   - the lead's reconcile relaunches the worker inside its recorded worktree.
# Claude runs on a dedicated signed-in test HOME named by
# FM_SENTINEL_E2E_CLAUDE_HOME (its .claude and .claude.json are symlinked into
# a throwaway lab HOME, never copied); the live default Herdr session, the
# operator's ~/.claude, and ~/.treehouse are never touched.
# Set FM_SENTINEL_E2E_EVIDENCE=<dir> to keep pane captures and logs.
# shellcheck disable=SC2016 # inner bash -c scripts expand their own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SENTINEL_LIVE_E2E herdr jq claude treehouse node git python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CRED_HOME=${FM_SENTINEL_E2E_CLAUDE_HOME:-}
EVID=${FM_SENTINEL_E2E_EVIDENCE:-}
MODEL=${FM_SENTINEL_E2E_MODEL:-sonnet}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ -n "$CRED_HOME" ] && [ -d "$CRED_HOME/.claude" ] && [ -f "$CRED_HOME/.claude.json" ] \
  || fail "FM_SENTINEL_E2E_CLAUDE_HOME must name a signed-in test Claude HOME (holding .claude/ and .claude.json)"
# Take the test credential's run lock when it has one, so live runs sharing it
# take turns.
if [ -f "$CRED_HOME/../run.lock" ] && command -v flock >/dev/null 2>&1; then
  exec 9<"$CRED_HOME/../run.lock"
  flock -w "${FM_SENTINEL_E2E_LOCK_WAIT:-1800}" 9 || fail "the test credential stayed busy past the lock wait"
fi

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
LABROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-sentinel-e2e.XXXXXX")
# A unix socket path is capped near 108 bytes and Herdr keeps its session
# sockets under $HOME/.config, so the lab HOME gets its own short path.
LABHOME=$(mktemp -d /tmp/fmsn.XXXXXX)
FAKEBIN="$LABROOT/fakebin"
MAIN="$LABROOT/main"
LEAD_ID=lab-lead
LEAD="$LABROOT/lead"
WORKER_ID=lab-worker
SPARE_ID=lab-spare
NOTES="$LEAD/projects/notes"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-oom-guard)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
LAB_READY=0

forget_claude_entries() {  # drop every Claude project entry under LABROOT or LABHOME
  node - "$LABHOME/.claude.json" "$LABROOT" "$LABHOME" <<'NODE'
const fs = require("node:fs");
const [link, ...roots] = process.argv.slice(2);
const store = fs.realpathSync(link);
const data = JSON.parse(fs.readFileSync(store, "utf8"));
const projects = data.projects || {};
const drop = Object.keys(projects).filter((k) => roots.some((r) => k === r || k.startsWith(`${r}/`)));
if (drop.length === 0) process.exit(0);
for (const k of drop) delete projects[k];
const tmp = `${store}.fm-sentinel-e2e.${process.pid}`;
fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, { mode: fs.statSync(store).mode & 0o777 });
fs.renameSync(tmp, store);
NODE
}

capture() {  # <name> <pane>: keep a pane's recent output as evidence
  [ -n "$EVID" ] || return 0
  lab pane read "$2" --source recent --lines 80 > "$EVID/$1.txt" 2>&1 || true
}

kill_lab_processes() {
  local pids
  mapfile -t pids < <(pgrep -f "$LABROOT/|$LABHOME/" | grep -vx "$$")
  [ "${#pids[@]}" -eq 0 ] || kill -KILL "${pids[@]}" 2>/dev/null || true
}
cleanup() {
  local status=$? pane
  if [ -n "$EVID" ]; then
    cp "$MAIN/state/.sentinel.log" "$EVID/main-sentinel.log" 2>/dev/null || true
    cp "$LEAD/state/.sentinel.log" "$EVID/lead-sentinel.log" 2>/dev/null || true
    cp "$LABROOT/spare-spawn.err" "$EVID/spare-spawn.err" 2>/dev/null || true
    if [ "$status" -ne 0 ] && [ "$LAB_READY" -eq 1 ]; then
      lab pane list > "$EVID/fail-panes.json" 2>&1 || true
      for pane in $(jq -r '.result.panes[]?.pane_id' "$EVID/fail-panes.json" 2>/dev/null); do
        capture "fail-${pane//:/-}" "$pane"
      done
      if [ -n "${WORKER_WT:-}" ]; then
        { fm "$LEAD" bash -x "$LEAD/bin/fm-claude-trust.sh" "$WORKER_WT" "$NOTES"; echo "rc=$?"; } \
          > "$EVID/fail-worker-trust.txt" 2>&1 || true
      fi
    fi
  fi
  if [ "$LAB_READY" -eq 1 ]; then
    lab_env "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null || status=1
  fi
  kill_lab_processes
  [ ! -e "$LABHOME/.claude.json" ] || forget_claude_entries || status=1
  chmod -R u+w "$LABROOT" 2>/dev/null
  rm -rf "$LABROOT" "$LABHOME" "/tmp/fm-$LEAD_ID"* "/tmp/fm-$WORKER_ID"* "/tmp/fm-$SPARE_ID"*
  exit "$status"
}
trap cleanup EXIT

# A throwaway HOME whose Claude state is the test credential's, by symlink.
# $LABROOT/treehouse is the pool root the treehouse.toml files below point at.
mkdir -p "$FAKEBIN" "$LABROOT/treehouse"
[ -z "$EVID" ] || mkdir -p "$EVID"

# Treehouse v2.0.1 resolves its pool root exclusively from a treehouse.toml
# inside the repository of its working directory (default root $HOME), never
# from the TREEHOUSE_ROOT environment variable, so wire that config into every
# lab repo a lab treehouse call can run from (the worker's project and the lab
# home), keeping every copy under $LABROOT. The file stays untracked: only the
# get that allocates a copy reads it, never the copies.
wire_treehouse_root() {  # <repo-root>
  printf 'root = "%s"\n' "$LABROOT/treehouse" > "$1/treehouse.toml"
}
ln -s "$CRED_HOME/.claude" "$LABHOME/.claude"
ln -s "$CRED_HOME/.claude.json" "$LABHOME/.claude.json"
printf '[user]\n\tname = Umer\n\temail = umer@example.invalid\n' > "$LABHOME/.gitconfig"

# Every Herdr call from a lab pane resolves this shim first: it strips the lab
# session flag the adapter appends, refuses any other session, and delegates to
# the guarded helper, so production code reaches only the named lab.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
# Herdr resumes `claude --resume <id>` without launch flags. The captain's install
# keeps a user-level bypass default, which the shared test credential's settings
# must not change, so this shim gives a resumed lab session the auto mode it was
# launched with; project settings cannot grant it without a trust dialog.
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --resume "*) case " \$* " in *" --permission-mode "*) ;; *) set -- --permission-mode auto "\$@" ;; esac ;;
esac
exec '$(command -v claude)' "\$@"
SH
chmod +x "$FAKEBIN/claude"
cat > "$LABHOME/.bashrc" <<EOF
export PATH='$FAKEBIN':"\$PATH"
export HERDR_SESSION='$HERDR_LAB_SESSION' HERDR_LAB_SESSION='$HERDR_LAB_SESSION'
export HERDR_LAB_HELPER='$HERDR_LAB_HELPER' REAL_HERDR='$REAL_HERDR' HERDR_ORIGINAL_PATH='$HERDR_ORIGINAL_PATH'
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
EOF
printf '. ~/.bashrc\n' > "$LABHOME/.bash_profile"

# The lab server and every pane run in this minimal environment, so nothing
# from the operator's own session reaches a lab agent.
lab_env() {
  env -i HOME="$LABHOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" LANG="${LANG:-C.UTF-8}" \
    TERM=xterm-256color SHELL=/bin/bash PATH="$HERDR_ORIGINAL_PATH" \
    FM_HERDR_LAB_FLEET_HOME="$HOME" DISABLE_AUTOUPDATER=1 "$@"
}
lab() { lab_env "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
# Production entrypoints the test itself drives, routed like a lab pane.
fm() {  # <home> <command...>
  local home=$1
  shift
  lab_env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
    HERDR_LAB_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_HELPER="$HERDR_LAB_HELPER" \
    REAL_HERDR="$REAL_HERDR" HERDR_ORIGINAL_PATH="$HERDR_ORIGINAL_PATH" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" "$@"
}
wait_for() {  # <seconds> <what> <command...>
  local deadline=$(( $(date +%s) + $1 )) what=$2
  shift 2
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for $what"
    sleep 3
  done
}
mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
beacon_newer() { [ "$(mtime "$1/state/.last-watcher-beat")" -gt "$2" ]; }
snapshot() { lab api snapshot; }
agent_field() {  # <pane> <jq-field>
  snapshot | jq -r --arg p "$1" ".result.snapshot.agents[]? | select(.pane_id == \$p) | $2 // empty" | head -n 1
}
pane_of_meta() { sed -n 's/^herdr_pane_id=//p' "$1" | tail -n 1; }

LAB_READY=1
lab_env "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail "could not provision the Herdr lab"

# Settings every lab Claude session needs, as Herdr's Claude integration and
# the operator's defaults give them on a real host: a SessionStart report of the
# session identity (so Herdr can resume it) and bypass as the default mode (a
# resumed session gets no launch flags).
cat > "$LABROOT/herdr-hook.sh" <<'SH'
#!/usr/bin/env bash
in=$(cat)
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
[ -z "$(printf '%s' "$in" | jq -r '.agent_id // empty')" ] || exit 0
sid=$(printf '%s' "$in" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
set -- --source herdr:claude --agent claude --seq "$(date +%s%N)" --agent-session-id "$sid" \
  --session-start-source "$(printf '%s' "$in" | jq -r '.source // "startup"')"
path=$(printf '%s' "$in" | jq -r '.transcript_path // empty')
[ -z "$path" ] || set -- "$@" --agent-session-path "$path"
herdr pane report-agent-session "$@" "$HERDR_PANE_ID" >/dev/null 2>&1
exit 0
SH
lab_settings() {  # <dir>
  mkdir -p "$1/.claude"
  cat > "$1/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "matcher": "^(startup|resume|clear|compact|fork)\$",
        "hooks": [ { "type": "command", "command": "bash '$LABROOT/herdr-hook.sh' session", "timeout": 10 } ] }
    ]
  }
}
EOF
}

# The lab primary home: a marked lab home holding this branch's tree.
"$ROOT/bin/fm-lab-home.sh" create "$MAIN" >/dev/null || fail "cannot create the lab primary home"
git -C "$MAIN" init -q -b main
git -C "$MAIN" fetch -q "$ROOT" HEAD
git -C "$MAIN" checkout -q -f -B main FETCH_HEAD
cp -R "$ROOT/bin/." "$MAIN/bin/"
git -C "$MAIN" add -A bin
git -C "$MAIN" -c user.name=Umer -c user.email=umer@example.invalid commit -q -m "lab: working tree" >/dev/null || true
mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config" "$MAIN/projects"
wire_treehouse_root "$MAIN"
printf 'herdr\n' > "$MAIN/config/backend"
printf 'claude\n' > "$MAIN/config/crew-harness"
printf 'claude %s low\n' "$MODEL" > "$MAIN/config/secondmate-harness"
# Lab launches use auto mode, so no lab agent stops at the bypass acceptance prompt.
printf 'auto\n' > "$MAIN/config/claude-permission-mode"
lab_settings "$MAIN"

# The lead: a real seeded second mate home with its own project and worker.
fm "$MAIN" env FM_SECONDMATE_CHARTER='Lab second mate for a Herdr restart test. Act only on orders from your parent; never spawn, merge, or edit project files yourself.' \
  FM_SECONDMATE_SCOPE='lab restart recovery test' \
  "$MAIN/bin/fm-home-seed.sh" "$LEAD_ID" "$LEAD" --no-projects >"$LABROOT/seed.out" 2>&1 \
  || fail "cannot seed the lead home: $(tail -5 "$LABROOT/seed.out")"
cp "$MAIN/config/backend" "$MAIN/config/crew-harness" "$MAIN/config/claude-permission-mode" "$LEAD/config/"
lab_settings "$LEAD"
git init -q -b main "$LABROOT/notes-seed"
printf '# notes\n' > "$LABROOT/notes-seed/README.md"
mkdir -p "$LABROOT/notes-seed/.claude"
cp "$LEAD/.claude/settings.local.json" "$LABROOT/notes-seed/.claude/settings.json"
git -C "$LABROOT/notes-seed" add -A
git -C "$LABROOT/notes-seed" -c user.name=Umer -c user.email=umer@example.invalid commit -q -m seed
git clone -q --bare "$LABROOT/notes-seed" "$LABROOT/notes.git"
git clone -q "$LABROOT/notes.git" "$NOTES"
wire_treehouse_root "$NOTES"
printf '# Projects\n\n- notes [local-only +yolo] - lab notes fixture\n' > "$LEAD/data/projects.md"

write_brief() {  # <id>
  fm "$LEAD" bash -c 'cd "$FM_HOME" && bin/fm-brief.sh "$1" notes --mode local-only' _ "$1" >/dev/null || fail "cannot scaffold brief $1"
  TASK_TEXT='Lab worker for a Herdr restart test. Change no file.' \
  SPEC_TEXT='Right after setup, append one paused status line saying you wait for a resume message, and end your turn. Whenever a later message arrives, append that same paused line again and end your turn. Nothing else is in scope.' \
    python3 - "$LEAD/data/$1/brief.md" <<'PY'
import os, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"], 1)
open(p, "w", encoding="utf-8").write(t)
PY
  fm "$LEAD" bash -c 'cd "$FM_HOME" && bin/fm-tasks-axi.sh add "$1" "lab worker" --kind ship --repo notes' _ "$1" >/dev/null \
    || fail "cannot file backlog item $1"
}
# Claude sessions sharing one .claude.json can lose each other's writes, such as
# a trust entry fm-spawn records, so the lab starts one agent at a time: the
# worker first, so the lead has work under way and arms its watcher.
MAIN_PANE='' LEAD_PANE='' WORKER_PANE=''
START=$(date +%s)
# A fresh test credential shows Claude's one-time renderer tip after the first
# reply; dismiss it so the composer reads empty, as on a long-used install.
dismiss_tips() {
  local pane
  for pane in "$MAIN_PANE" "$LEAD_PANE" "$WORKER_PANE"; do
    lab pane read "$pane" --source visible 2>/dev/null | grep -q 'Try the new fullscreen renderer' \
      && lab pane send-keys "$pane" Escape >/dev/null 2>&1
  done
  return 0
}
primary_armed() {
  ! lab pane read "$MAIN_PANE" --source visible 2>/dev/null | grep -q 'Please run /login' \
    || fail "the test Claude credential is signed out; sign it in again and rerun"
  dismiss_tips
  beacon_newer "$MAIN" "$START"
}
write_brief "$WORKER_ID"
fm "$LEAD" "$LEAD/bin/fm-spawn.sh" "$WORKER_ID" "$NOTES" --mode local-only --yolo on \
  --harness claude --model "$MODEL" --effort low >"$LABROOT/worker-spawn.out" 2>&1 \
  || fail "worker spawn failed: $(tail -5 "$LABROOT/worker-spawn.out")"
WORKER_META="$LEAD/state/$WORKER_ID.meta"
WORKER_WT=$(sed -n 's/^worktree=//p' "$WORKER_META" | tail -n 1)
WORKER_PANE=$(pane_of_meta "$WORKER_META")
[ -d "$WORKER_WT" ] && [ -n "$WORKER_PANE" ] || fail "worker record lacks a worktree or pane"
wait_for 600 "the worker to settle on its brief" test -s "$LEAD/state/$WORKER_ID.status"
fm "$MAIN" "$MAIN/bin/fm-spawn.sh" "$LEAD_ID" --secondmate >"$LABROOT/lead-spawn.out" 2>&1 \
  || fail "lead spawn failed: $(tail -5 "$LABROOT/lead-spawn.out")"
LEAD_PANE=$(pane_of_meta "$MAIN/state/$LEAD_ID.meta")
wait_for 600 "the lead's turn to end with its watcher armed" beacon_newer "$LEAD" "$START"

# The lab primary, launched the way an operator starts Firstmate.
fm "$MAIN" "$MAIN/bin/fm-claude-trust.sh" --lab-home "$MAIN" >/dev/null || fail "cannot register trust for the lab primary"
MAIN_WS=$(lab workspace create --cwd "$MAIN" --label lab-main --no-focus) || fail "cannot create the primary workspace"
MAIN_PANE=$(printf '%s' "$MAIN_WS" | jq -r '.result.root_pane.pane_id')
lab pane run "$MAIN_PANE" "claude --model $MODEL --effort low 'This is a disposable Firstmate lab. Run no command for this message: reply with only MAIN-READY and end your turn. For each later message, handle the Firstmate operational input it names with as few commands as possible, never spawn, steer, merge, or edit project files, and end your turn as soon as it is handled.'" >/dev/null \
  || fail "cannot launch the lab primary"
wait_for 600 "the primary's first turn to end with its watcher armed" primary_armed
MAIN_SID=$(head -n 1 "$MAIN/state/.lock-session")
main_session_reported() { [ "$(agent_field "$MAIN_PANE" '.agent_session.value')" = "$MAIN_SID" ]; }
wait_for 120 "Herdr to record the primary's Claude session" main_session_reported
capture before-main "$MAIN_PANE"; capture before-lead "$LEAD_PANE"; capture before-worker "$WORKER_PANE"
pass "lab primary, lead, and worker are live with both watchers armed and every turn ended"

fm "$MAIN" "$MAIN/bin/fm-sentinel.sh" tick >/dev/null
[ -s "$MAIN/state/.sentinel-herdr-identity" ] || fail "sentinel recorded no Herdr identity"

# The incident: the server dies and its supervisor restarts it.
lab_env "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "could not stop the lab server"
# oomd kills the whole Herdr unit, but a lab stop leaves detached watchers alive.
kill_lab_processes
RESTART=$(date +%s)
lab_env "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail "could not restart the lab server"
worker_resumed() { [ -n "$(agent_field "$WORKER_PANE" '.pane_id')" ]; }
wait_for 180 "Herdr to resume the worker session" worker_resumed
sleep 10
WORKER_CWD_AFTER=$(agent_field "$WORKER_PANE" '.foreground_cwd // .cwd')
[ -n "$EVID" ] && snapshot > "$EVID/snapshot-after-restart.json"
case "$WORKER_CWD_AFTER/" in
  "$WORKER_WT"/*) fail "Herdr resumed the worker inside its worktree; the misplacement did not reproduce" ;;
esac
pass "Herdr resumed the worker in $WORKER_CWD_AFTER, outside its worktree $WORKER_WT"

# Treehouse now reports the worker's slot free; a new spawn must not take it.
write_brief "$SPARE_ID"
if fm "$LEAD" "$LEAD/bin/fm-spawn.sh" "$SPARE_ID" "$NOTES" --mode local-only --yolo on \
    --harness claude --model "$MODEL" --effort low >"$LABROOT/spare-spawn.out" 2>"$LABROOT/spare-spawn.err"; then
  SPARE_WT=$(sed -n 's/^worktree=//p' "$LEAD/state/$SPARE_ID.meta" | tail -n 1)
  [ "$SPARE_WT" != "$WORKER_WT" ] || fail "a new spawn took the worker's recorded slot"
  pass "Treehouse handed the new spawn a different slot ($SPARE_WT)"
else
  grep -q "task $WORKER_ID still records it as its worktree" "$LABROOT/spare-spawn.err" \
    || fail "spare spawn failed for another reason: $(tail -5 "$LABROOT/spare-spawn.err")"
  pass "a new spawn refused the pool slot $WORKER_ID's record still names"
fi

fm "$MAIN" "$MAIN/bin/fm-sentinel.sh" tick >"$LABROOT/tick.out" 2>&1 || true
grep -q "restarted" "$LABROOT/tick.out" || fail "sentinel did not detect the restart: $(cat "$LABROOT/tick.out")"
grep -q "$LEAD_ID: ordered to recover" "$LABROOT/tick.out" || fail "sentinel did not order the lead: $(cat "$LABROOT/tick.out")"
until grep -q "primary: woke" "$MAIN/state/.sentinel.log"; do
  [ "$(date +%s)" -lt "$((RESTART + 300))" ] || fail "sentinel never woke the primary: $(tail -5 "$MAIN/state/.sentinel.log")"
  sleep 10
  fm "$MAIN" "$MAIN/bin/fm-sentinel.sh" tick >/dev/null 2>&1 || true
done
pass "one sentinel pass detected the restart, ordered the lead, and woke the primary"

wait_for 600 "the primary to re-arm supervision" beacon_newer "$MAIN" "$RESTART"
pass "the primary re-armed with no human input"
wait_for 600 "the lead to re-arm supervision" beacon_newer "$LEAD" "$RESTART"
pass "the lead re-armed with no human input"
in_worktree() {
  local cwd
  cwd=$(agent_field "$(pane_of_meta "$WORKER_META")" '.foreground_cwd // .cwd')
  case "$cwd/" in "$WORKER_WT"/*) return 0 ;; *) return 1 ;; esac
}
wait_for 600 "the lead to relaunch the worker in its worktree" in_worktree
grep -q "$WORKER_ID: .*relaunched in" "$LEAD/state/.sentinel.log" || fail "lead's reconcile logged no worker relaunch"
capture after-main "$MAIN_PANE"; capture after-lead "$LEAD_PANE"; capture after-worker "$(pane_of_meta "$WORKER_META")"
pass "the lead's reconcile relaunched the worker inside $WORKER_WT"
