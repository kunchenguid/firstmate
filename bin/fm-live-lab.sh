#!/usr/bin/env bash
# fm-live-lab.sh - stand up, check, drive, and tear down one disposable live
# supervision lab: a real lab main session on Claude or Pi, with the
# supervision host (Claude) or branch (Pi) wired as a real home runs it,
# optionally a real seeded local second mate and a real gated worker.
#
# Usage:
#   fm-live-lab.sh up --harness claude|pi [--mate] [--worker]
#                     [--model <m>] [--effort <e>]
#                     [--supervision-host <line>|none|off] [--expect-host yes|no]
#                     [--source <repo>] [--ref <rev>] [--timeout <seconds>]
#                     [<lab-root>]
#   fm-live-lab.sh check <lab-root>
#   fm-live-lab.sh say <lab-root> [--window <name>] <text>
#   fm-live-lab.sh pane <lab-root> [--window <name>] [--lines <n>]
#   fm-live-lab.sh down <lab-root>
#
# up builds everything under <lab-root> (a fresh path; default a new
# /tmp/fmlab.XXXXXX), verifies readiness itself, and prints one line per check.
# It exits 0 only when every check passed; otherwise it exits 1 and leaves the
# lab up for inspection, so run down either way. check re-runs the same checks
# once. say types text into a lab window and presses Enter (window main, the
# lab primary, by default; mate and worker name the lab's own tasks). pane
# prints a window's recent scrollback. down stops every lab process, removes the
# lab's Claude trust entries by one atomic replace, removes <lab-root>, and exits
# non-zero if the recorded Pi trust store or ~/.treehouse gained changes.
#
# What up builds:
#   home/            the lab main home: bin/fm-lab-home.sh create, then the
#                    committed tree <ref> of <source> (default: HEAD of the
#                    checkout this script runs from) checked out as a genuine
#                    primary checkout, with FM_HOME at its root.
#   config/          backend tmux, Claude crews and second mates, and
#                    supervision-host <line> (default claude on Claude, absent
#                    on Pi; none leaves the file absent; off writes the
#                    inherited supervision-host-off opt-out instead, so the
#                    mate spawn inherits it).
#   tmux server      private, through the lab home's bin/fm-lab-home.sh
#                    tmux-dir, with no user tmux config (its plugins never run
#                    in a lab), started from an empty environment so no inherited
#                    TMUX, Herdr, or Pi marker reaches a lab process.
#                    TREEHOUSE_ROOT points into <lab-root>, so a worker's pool
#                    never lands in ~/.treehouse, and DISABLE_AUTOUPDATER=1
#                    keeps Claude Code from replacing the shared binary under
#                    a running lab, as every live run does (tests/lib.sh).
#                    A set CLAUDE_CONFIG_DIR (absolute) is passed to every lab
#                    process. up records the Claude store, Pi trust store, and
#                    ~/.treehouse it selected, so check and down use those same
#                    paths even from a later shell with another HOME.
#   trust            Claude: bin/fm-claude-trust.sh --lab-home for the primary
#                    and the spawn's own registration for the mate and worker. Pi:
#                    --approve, which trusts project-local files for this run
#                    only, so the Pi trust store is never written and all of
#                    .pi/extensions loads; sessions stay under
#                    <lab-root>/pi-sessions.
#   task ids         lab<nonce>-mate and lab<nonce>-worker, unique per lab,
#                    because a spawn keeps a task temp dir at /tmp/fm-<id>
#                    that a fixed id would share with other labs and tasks.
#   mate/            --mate: bin/fm-home-seed.sh <mate-id> <lab-root>/mate
#                    --no-projects (an explicit path cloned from the git lab
#                    home), launched by bin/fm-spawn.sh --secondmate.
#   worker           --worker: a lab project notes with a lab-private origin
#                    (local-only +yolo), a scaffolded brief, a backlog item, and
#                    a real bin/fm-spawn.sh worker that parks on
#                    <lab-root>/home/data/<worker-id>/gate until that file
#                    exists; touch the gate and message the worker to resume.
#   primary          window main: claude --setting-sources project,local
#                    (default sonnet, medium, permission mode auto) or pi
#                    (default openai-codex/gpt-6-luna, medium), launched
#                    after the mate and worker so its first turn end arms
#                    supervision. up then sends one harmless probe prompt.
#
# Readiness checks (check prints "ok <name>: ..." or "fail <name>: ..."):
#   primary       window main is alive, in the lab home, which is a primary
#                 checkout, and the lab session lock names a live process.
#   probe         the primary answered the probe with its nonce (the model is
#                 accepted and a whole turn ran).
#   trust         Claude: the lab home carries registered trust.
#                 Pi: the Pi trust store is byte-identical to before up.
#   mirror        Claude with --expect-host yes: the tree's
#                 fm-host-mirror.sh verified claude and fm-host-mirror.sh check
#                 pass, and the mirror holds a captain and a main entry.
#   extensions    Pi: the watcher, turn-end guard, and branch extensions are
#                 loaded by the process holding the lab session lock, at the
#                 current on-disk builds.
#   host          Claude: with --expect-host yes (the default on Claude unless
#                 --supervision-host off) the supervision host runs; with no,
#                 none runs. Skipped when the lab has no mate or worker, since
#                 an empty fleet arms nothing.
#   watcher       a live watcher with a fresh beacon holds this home's lock
#                 (skipped on an empty fleet).
#   mate          --mate: its window is alive and its own session lock names a
#                 live process, so it got past trust into its charter. With
#                 --supervision-host off, its inherited flag and disabled host
#                 gate are also required.
#   worker        --worker: its current crew state is paused on the gate.
#   treehouse     ~/.treehouse gained no entry since up began.
#
# Every tmux call names the lab's socket explicitly (tmux -S), never through
# TMUX_TMPDIR alone, so no lab command can reach another tmux server even after
# the private tmux directory is gone.
#
# down refuses any path without the lab record up writes. It kills only the
# lab's recorded launch pane PIDs and their descendants, and the lab's private
# tmux server, which it touches only while that server's socket exists;
# runs bin/fm-lab-home.sh teardown; removes the task temp and launch dirs the
# lab's spawns kept under /tmp, including a failed spawn's; removes every
# project entry at or under <lab-root> from the recorded Claude store, following
# a symlinked store to its target (compare-and-swap atomic replace, unrelated
# entries kept); reports a changed Pi trust store or a new
# ~/.treehouse entry without touching either; and removes <lab-root>.
# Transcripts under ~/.claude/projects are left as history. The lab never uses
# Herdr.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUILDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LAB_HOME_HELPER="$SCRIPT_DIR/fm-lab-home.sh"
CLAUDE_TRUST="$SCRIPT_DIR/fm-claude-trust.sh"
RECORD_NAME=.fm-live-lab
RECORD_TOKEN='fm-live-lab v1'
PI_TRUST_STORE="$HOME/.pi/agent/trust.json"
TREEHOUSE_DIR="$HOME/.treehouse"

die() { echo "fm-live-lab: $*" >&2; exit 1; }
help_text() { sed -n '/^# Usage:/,/^# up builds/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
usage() { help_text >&2; exit 2; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

digest() {  # <file> -> sha256 of its bytes, or "absent"
  [ -f "$1" ] || { echo absent; return; }
  shasum -a 256 "$1" | awk '{print $1}'
}

treehouse_listing() { ls -1A "$TREEHOUSE_DIR" 2>/dev/null || true; }

rec_get() {  # <root> <key>
  sed -n "s/^$2=//p" "$1/$RECORD_NAME" | head -n 1
}

load_lab() {  # <root>: refuse anything up did not build, then load its record
  local root=$1
  [ -n "$root" ] || usage
  ROOT=$(real_dir "$root") || die "no lab at '$root'"
  [ -f "$ROOT/$RECORD_NAME" ] && [ ! -L "$ROOT/$RECORD_NAME" ] && [ -O "$ROOT/$RECORD_NAME" ] \
    && [ "$(sed -n 1p "$ROOT/$RECORD_NAME")" = "$RECORD_TOKEN" ] \
    || die "refusing '$ROOT': it carries no lab record written by fm-live-lab.sh up"
  HARNESS=$(rec_get "$ROOT" harness)
  LAB=$(rec_get "$ROOT" home)
  TMUX_DIR=$(rec_get "$ROOT" tmux_dir)
  EXPECT_HOST=$(rec_get "$ROOT" expect_host)
  HOST_OFF=$(rec_get "$ROOT" host_off)
  WANT_MATE=$(rec_get "$ROOT" mate)
  WANT_WORKER=$(rec_get "$ROOT" worker)
  NONCE=$(rec_get "$ROOT" nonce)
  MATE_ID=$(rec_get "$ROOT" mate_id)
  WORKER_ID=$(rec_get "$ROOT" worker_id)
  GATE=$(rec_get "$ROOT" gate)
  PI_TRUST_BEFORE=$(rec_get "$ROOT" pi_trust)
  CLAUDE_DIR=$(rec_get "$ROOT" claude_config_dir)
  CLAUDE_STORE=$(rec_get "$ROOT" claude_store)
  PI_TRUST_STORE=$(rec_get "$ROOT" pi_trust_store)
  TREEHOUSE_DIR=$(rec_get "$ROOT" treehouse_dir)
}

# lab_socket: the explicit path of the lab's tmux socket, the one a lab process
# reaches through TMUX_TMPDIR=$TMUX_DIR. Every tmux call this script makes names
# it with -S, never TMUX_TMPDIR alone: tmux uses TMUX_TMPDIR only while that
# directory exists and otherwise silently falls back to /tmp/tmux-<uid>, where a
# lab command would reach the user's own default server.
lab_socket() {
  [ -n "${TMUX_DIR:-}" ] || return 1
  printf '%s/tmux-%s/default\n' "$TMUX_DIR" "$(id -u)"
}

lab_tmux() {
  local socket
  socket=$(lab_socket) || return 1
  env -u TMUX tmux -S "$socket" "$@"
}

# lab_kill_server: stop the lab's tmux server, and do nothing at all when its
# socket does not exist.
lab_kill_server() {
  local socket
  socket=$(lab_socket) || return 0
  [ -S "$socket" ] || return 0
  lab_tmux kill-server 2>/dev/null || true
}

# The empty-environment base every lab process starts from. TMUX_TMPDIR here is
# how the lab's own firstmate backend finds the lab server; those processes run
# only while that server, and so its directory, exists.
lab_env_base() {
  printf '%s\n' "HOME=$HOME" "USER=${USER:-$(id -un)}" "LOGNAME=${USER:-$(id -un)}" \
    "PATH=$PATH" "SHELL=${SHELL:-/bin/zsh}" "TERM=xterm-256color" "LANG=${LANG:-en_US.UTF-8}" \
    "TMUX_TMPDIR=$TMUX_DIR" "TREEHOUSE_ROOT=$ROOT/treehouse" "FM_BACKEND=tmux" "DISABLE_AUTOUPDATER=1"
  [ -z "${CLAUDE_DIR:-}" ] || printf '%s\n' "CLAUDE_CONFIG_DIR=$CLAUDE_DIR"
}

lab_run() {  # [NAME=VALUE...] <command...>: run in the lab's clean environment
  local -a base=()
  local line
  while IFS= read -r line; do base+=("$line"); done < <(lab_env_base)
  env -i "${base[@]}" "$@"
}

# window_id <name>: the tmux id of the lab window with exactly this name, or
# nothing. A name is matched here and never passed as a target, because tmux
# resolves a target it cannot find, even an exact =name, to the current window,
# while a stale window id fails. mate and worker name the lab's own tasks, whose
# windows the spawn recorded in their metadata.
window_id() {
  local name=$1 window
  case "$name" in
    mate) name=$MATE_ID ;;
    worker) name=$WORKER_ID ;;
  esac
  window=$(sed -n 's/^window=//p' "$LAB/state/$name.meta" 2>/dev/null)
  [ -z "$window" ] || name=${window#*:}
  lab_tmux list-windows -t firstmate -F "#{window_name}$(printf '\t')#{window_id}" 2>/dev/null \
    | awk -F '\t' -v n="$name" '$1 == n { print $2; exit }'
}

window_field() {  # <name> <format>
  local id
  id=$(window_id "$1")
  [ -n "$id" ] || return 1
  lab_tmux display-message -p -t "$id" "$2" 2>/dev/null
}

window_alive() {  # <name>
  [ "$(window_field "$1" '#{pane_dead}')" = 0 ]
}

pid_alive() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; kill -0 "$1" 2>/dev/null; }

fleet_nonempty() { [ "$WANT_MATE" = yes ] || [ "$WANT_WORKER" = yes ]; }

# ---- readiness checks -------------------------------------------------------

check_primary() {
  local path gitdir common pid
  window_alive main || { echo "fail primary: window main is not running"; return 1; }
  path=$(window_field main '#{pane_current_path}')
  [ "$(real_dir "$path")" = "$LAB" ] || { echo "fail primary: window main runs in '$path', not the lab home $LAB"; return 1; }
  gitdir=$(real_dir "$(git -C "$LAB" rev-parse --absolute-git-dir 2>/dev/null)")
  common=$(cd "$LAB" && real_dir "$(git rev-parse --git-common-dir 2>/dev/null)")
  [ -n "$gitdir" ] && [ "$gitdir" = "$common" ] || { echo "fail primary: the lab home is not a primary checkout"; return 1; }
  pid=$(sed -n 1p "$LAB/state/.lock" 2>/dev/null)
  pid_alive "$pid" || { echo "fail primary: the lab session lock names no live process (session start has not run)"; return 1; }
  echo "ok primary: $HARNESS pid $pid in $LAB"
}

check_probe() {
  local id
  id=$(window_id main)
  if [ -n "$id" ] && lab_tmux capture-pane -p -J -t "$id" -S -5000 2>/dev/null | grep -Fq "LABREADY-$NONCE"; then
    echo "ok probe: the primary answered LABREADY-$NONCE"
  else
    echo "fail probe: no LABREADY-$NONCE reply in window main (model refused, turn still running, or a dialog is open)"
    return 1
  fi
}

lab_trust_present() {
  node -e 'const [s,k]=process.argv.slice(1);const j=JSON.parse(require("node:fs").readFileSync(s,"utf8"));process.exit(j.projects?.[k]?.hasTrustDialogAccepted===true?0:1)' \
    "$CLAUDE_STORE" "$LAB" 2>/dev/null
}

check_trust() {
  if [ "$HARNESS" = pi ]; then
    [ "$(digest "$PI_TRUST_STORE")" = "$PI_TRUST_BEFORE" ] \
      || { echo "fail trust: the Pi trust store changed since up began"; return 1; }
    echo "ok trust: Pi trust store unchanged (session-only --approve)"
    return 0
  fi
  if lab_trust_present; then
    echo "ok trust: $LAB is trusted in the Claude store"
  else
    echo "fail trust: $LAB has no registered Claude workspace trust"
    return 1
  fi
}

check_mirror() {
  local out rc entries
  out=$(cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-host-mirror.sh" verified claude 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "fail mirror: fm-host-mirror.sh verified claude exited $rc ${out:+($out)}"; return 1; }
  out=$(cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-host-mirror.sh" check 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "fail mirror: fm-host-mirror.sh check exited $rc ${out:+($(printf '%s' "$out" | head -n 1))}"; return 1; }
  entries=$(jq -rs '[.[].tag] | "captain=\(map(select(.=="captain"))|length) main=\(map(select(.=="main"))|length)"' \
    "$LAB/state/.host-mirror.jsonl" 2>/dev/null)
  case "$entries" in
    captain=0*|*main=0|'') echo "fail mirror: the dialog mirror has no captain and main entry yet (${entries:-no mirror file})"; return 1 ;;
  esac
  echo "ok mirror: verified writer, check passed, $entries"
}

check_extensions() {
  local pair source marker phase version out=""
  for pair in fm-primary-pi-watch.ts:.pi-watch-extension-loaded:active fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded; do
    source=${pair%%:*}; marker=${pair#*:}; phase=${marker#*:}; marker=${marker%%:*}
    [ "$phase" != "$marker" ] || phase=
    # shellcheck disable=SC2016 # Expanded by the inner shell.
    version=$(FM_HOME="$LAB" bash -c '. "$1/bin/fm-wake-lib.sh" && fm_pi_extension_version "$1/.pi/extensions/$2"' _ "$LAB" "$source" 2>/dev/null)
    # shellcheck disable=SC2016 # Expanded by the inner shell.
    FM_HOME="$LAB" bash -c '. "$1/bin/fm-wake-lib.sh" && fm_pi_extension_loaded "$1/state/$2" "$3" "$1/state/.lock" "$4"' \
      _ "$LAB" "$marker" "$version" "$phase" 2>/dev/null \
      || { echo "fail extensions: $source is not loaded at its current build by the lock holder"; return 1; }
    out="$out ${source%.ts}"
  done
  [ "$(sed -n 1p "$LAB/state/.pi-branch-extension-loaded" 2>/dev/null)" = "$(sed -n 1p "$LAB/state/.lock" 2>/dev/null)" ] \
    || { echo "fail extensions: fm-branch-supervision.ts is not loaded by the lock holder"; return 1; }
  echo "ok extensions:$out fm-branch-supervision"
}

check_host() {
  local pid
  fleet_nonempty || { echo "ok host: skipped (empty fleet arms no supervision)"; return 0; }
  pid=$(awk -F '\t' '$1=="host"{print $2; exit}' "$LAB/state/.supervision-host" 2>/dev/null)
  if [ "$EXPECT_HOST" = yes ]; then
    pid_alive "$pid" || { echo "fail host: no live supervision host (expected one)"; return 1; }
    echo "ok host: supervision host pid $pid"
  else
    ! pid_alive "$pid" || { echo "fail host: supervision host pid $pid runs (expected none)"; return 1; }
    echo "ok host: none running, as expected"
  fi
}

check_watcher() {
  fleet_nonempty || { echo "ok watcher: skipped (empty fleet)"; return 0; }
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  if FM_HOME="$LAB" bash -c '. "$1/bin/fm-wake-lib.sh" && fm_watcher_healthy "$1/state" "$1/bin/fm-watch.sh" 300 "$1"' _ "$LAB" 2>/dev/null; then
    echo "ok watcher: live watcher with a fresh beacon"
  else
    echo "fail watcher: no live watcher with a fresh beacon holds the lab home"
    return 1
  fi
}

check_mate() {
  local pid gate_rc
  window_alive mate || { echo "fail mate: the $MATE_ID window is not running"; return 1; }
  pid=$(sed -n 1p "$ROOT/mate/state/.lock" 2>/dev/null)
  pid_alive "$pid" || { echo "fail mate: the mate holds no session lock yet (wedged before its charter?)"; return 1; }
  if [ "$HOST_OFF" = yes ]; then
    [ -f "$ROOT/mate/config/supervision-host-off" ] \
      || { echo "fail mate: the inherited supervision-host-off flag is missing"; return 1; }
    bash "$ROOT/mate/bin/fm-supervision-engine-lib.sh" enabled "$ROOT/mate/config" claude
    gate_rc=$?
    [ "$gate_rc" -eq 1 ] || { echo "fail mate: the supervision-host gate did not read off (exit $gate_rc)"; return 1; }
  fi
  echo "ok mate: $MATE_ID pid $pid in $ROOT/mate"
}

check_worker() {
  local state
  window_alive worker || { echo "fail worker: the $WORKER_ID window is not running"; return 1; }
  state=$(cd "$LAB" && lab_run FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 "$LAB/bin/fm-crew-state.sh" "$WORKER_ID" 2>/dev/null)
  case "$state" in
    "state: paused · "*"$GATE"*) ;;
    *) echo "fail worker: the worker is not currently parked on $GATE (${state:-no state})"; return 1 ;;
  esac
  echo "ok worker: $WORKER_ID parked on $GATE"
}

check_treehouse() {
  local added
  added=$(comm -13 "$ROOT/.treehouse-before" <(treehouse_listing | sort) 2>/dev/null)
  [ -z "$added" ] || { echo "fail treehouse: new ~/.treehouse entries: $(printf '%s' "$added" | tr '\n' ' ')"; return 1; }
  echo "ok treehouse: ~/.treehouse unchanged"
}

run_checks() {
  local rc=0
  check_primary || rc=1
  check_probe || rc=1
  check_trust || rc=1
  if [ "$HARNESS" = claude ]; then
    if [ "$EXPECT_HOST" = yes ]; then check_mirror || rc=1; fi
    check_host || rc=1
  else
    check_extensions || rc=1
  fi
  check_watcher || rc=1
  if [ "$WANT_MATE" = yes ]; then check_mate || rc=1; fi
  if [ "$WANT_WORKER" = yes ]; then check_worker || rc=1; fi
  check_treehouse || rc=1
  return "$rc"
}

# ---- up ---------------------------------------------------------------------

say_text() {  # <window> <text>
  local id
  id=$(window_id "$1")
  [ -n "$id" ] || { echo "fm-live-lab: no lab window named '$1'" >&2; return 1; }
  lab_tmux send-keys -t "$id" -l "$2" || return 1
  sleep 1
  lab_tmux send-keys -t "$id" Enter
}

make_notes_project() {
  local seed="$ROOT/origins/notes-seed" origin="$ROOT/origins/notes.git"
  mkdir -p "$seed/notes" "$seed/tests"
  git init -q -b main "$seed"
  cat > "$seed/notes/__init__.py" <<'PY'
"""A tiny notes library used by the firstmate live lab."""

NOTES = []


def add_note(text, tags=None):
    NOTES.append({"text": text, "tags": list(tags or [])})
    return len(NOTES) - 1


def list_notes():
    return list(NOTES)
PY
  cat > "$seed/tests/test_notes.py" <<'PY'
import unittest

import notes


class NotesTest(unittest.TestCase):
    def setUp(self):
        notes.NOTES.clear()

    def test_add_and_list(self):
        notes.add_note("hello", ["a"])
        self.assertEqual(notes.list_notes(), [{"text": "hello", "tags": ["a"]}])


if __name__ == "__main__":
    unittest.main()
PY
  cat > "$seed/README.md" <<'MD'
# notes

A tiny notes library for lab work.
Run the checks with `python3 -m unittest discover -s tests`.
MD
  git -C "$seed" add -A
  git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "seed notes"
  git clone -q --bare "$seed" "$origin"
  rm -rf "$seed"
  git clone -q "$origin" "$LAB/projects/notes"
  printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"
}

spawn_worker() {
  local brief="$LAB/data/$WORKER_ID/brief.md" gate="$GATE"
  make_notes_project || return 1
  (cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-brief.sh" "$WORKER_ID" notes --mode local-only) >/dev/null || return 1
  TASK_TEXT="Lab gated worker for a live supervision lab. Add count_notes(), which returns how many notes are stored, to notes/__init__.py with a unit test, but only after the gate file $gate exists and you receive a message to resume." \
  SPEC_TEXT="Right after setup, append one paused status line naming the gate file $gate and end your turn. Do not poll or sleep in a foreground command. When a later message resumes you, check that $gate exists before implementing count_notes() in notes/__init__.py and a test in tests/test_notes.py; if it is absent, remain paused and end your turn again. Once the gate exists, run python3 -m unittest discover -s tests, commit, and report done. Nothing else is in scope." \
    python3 - "$brief" <<'PY' || return 1
import os, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"], 1)
open(path, "w", encoding="utf-8").write(text)
PY
  (cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-tasks-axi.sh" add "$WORKER_ID" "lab gated worker" --kind ship --repo notes) >/dev/null || return 1
  (cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-spawn.sh" "$WORKER_ID" "$LAB/projects/notes" \
    --mode local-only --yolo on --harness claude --model sonnet --effort low)
}

spawn_mate() {
  local charter='Provide an idle live-validation lab second mate. When explicitly steered for a synthetic test, report only honest local lab outcomes; do not claim external PR activity, merge, or retire yourself.'
  (cd "$LAB" && lab_run FM_HOME="$LAB" FM_SECONDMATE_CHARTER="$charter" \
    FM_SECONDMATE_SCOPE='second-mate live validation synthetic status relay' \
    "$LAB/bin/fm-home-seed.sh" "$MATE_ID" "$ROOT/mate" --no-projects) || return 1
  (cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-spawn.sh" "$MATE_ID" --secondmate)
}

cmd_up() {
  local harness="" mate=no worker=no model="" effort=medium host_line=__default__ expect_host="" source="$BUILDER_ROOT" ref=HEAD timeout=600
  local root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness) harness=${2:-}; shift 2 ;;
      --mate) mate=yes; shift ;;
      --worker) worker=yes; shift ;;
      --model) model=${2:-}; shift 2 ;;
      --effort) effort=${2:-}; shift 2 ;;
      --supervision-host) host_line=${2:-}; shift 2 ;;
      --expect-host) expect_host=${2:-}; shift 2 ;;
      --source) source=${2:-}; shift 2 ;;
      --ref) ref=${2:-}; shift 2 ;;
      --timeout) timeout=${2:-}; shift 2 ;;
      -h|--help) help_text; exit 0 ;;
      -*) die "unknown option '$1'" ;;
      *) [ -z "$root" ] || usage; root=$1; shift ;;
    esac
  done
  case "$harness" in claude|pi) ;; *) die "--harness must be claude or pi" ;; esac
  case "$timeout" in ''|*[!0-9]*) die "--timeout takes seconds" ;; esac
  [ -n "$expect_host" ] || { [ "$harness" = claude ] && [ "$host_line" != off ] && expect_host=yes || expect_host=no; }
  case "$expect_host" in yes|no) ;; *) die "--expect-host takes yes or no" ;; esac
  [ "$host_line" != __default__ ] || { [ "$harness" = claude ] && host_line=claude || host_line=none; }
  HOST_OFF=no
  [ "$host_line" != off ] || HOST_OFF=yes
  [ -n "$model" ] || { [ "$harness" = claude ] && model=sonnet || model=openai-codex/gpt-6-luna; }
  CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-}
  case "$CLAUDE_DIR" in ''|/*) ;; *) die "CLAUDE_CONFIG_DIR must be an absolute path" ;; esac
  CLAUDE_STORE="${CLAUDE_DIR:-$HOME}/.claude.json"
  [ -z "$root" ] || [ ! -e "$root" ] || die "refusing '$root': a lab root must not exist yet"
  for tool in git tmux jq node python3 shasum "$harness"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required and was not found on PATH"
  done

  if [ -z "$root" ]; then
    root=$(mktemp -d /tmp/fmlab.XXXXXX) || die "cannot create a lab root"
  else
    mkdir -p "$root" || die "cannot create '$root'"
  fi
  ROOT=$(real_dir "$root")
  LAB="$ROOT/home"
  HARNESS=$harness EXPECT_HOST=$expect_host WANT_MATE=$mate WANT_WORKER=$worker
  NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
  MATE_ID="lab${NONCE:0:12}-mate" WORKER_ID="lab${NONCE:0:12}-worker"
  GATE="$LAB/data/$WORKER_ID/gate"
  PI_TRUST_BEFORE=$(digest "$PI_TRUST_STORE")
  treehouse_listing | sort > "$ROOT/.treehouse-before"
  {
    echo "$RECORD_TOKEN"
    echo "harness=$harness"
    echo "home=$LAB"
    echo "expect_host=$expect_host"
    if [ "$host_line" = off ]; then echo 'host_off=yes'; else echo 'host_off=no'; fi
    echo "mate=$mate"
    echo "worker=$worker"
    echo "nonce=$NONCE"
    echo "mate_id=$MATE_ID"
    echo "worker_id=$WORKER_ID"
    echo "gate=$GATE"
    echo "pi_trust=$PI_TRUST_BEFORE"
    echo "claude_config_dir=$CLAUDE_DIR"
    echo "claude_store=$CLAUDE_STORE"
    echo "pi_trust_store=$PI_TRUST_STORE"
    echo "treehouse_dir=$TREEHOUSE_DIR"
  } > "$ROOT/$RECORD_NAME"
  echo "lab: $ROOT (tear down with: $0 down $ROOT)"

  "$LAB_HOME_HELPER" create "$LAB" >/dev/null || die "cannot create the lab home"
  git -C "$LAB" init -q -b main || die "cannot initialize the lab home"
  git -C "$LAB" fetch -q "$source" "$ref" || die "cannot fetch $ref from $source"
  git -C "$LAB" checkout -q -f -B main FETCH_HEAD || die "cannot check out $ref"
  git -C "$LAB" config user.name lab && git -C "$LAB" config user.email lab@example.invalid
  mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse"
  printf 'tmux\n' > "$LAB/config/backend"
  printf 'claude\n' > "$LAB/config/crew-harness"
  printf 'claude sonnet low\n' > "$LAB/config/secondmate-harness"
  printf 'auto\n' > "$LAB/config/claude-permission-mode"
  case "$host_line" in
    none) ;;
    off) : > "$LAB/config/supervision-host-off" ;;
    *) printf '%s\n' "$host_line" > "$LAB/config/supervision-host" ;;
  esac
  echo "tree: $(git -C "$LAB" rev-parse HEAD) from $source"

  TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$LAB") || die "cannot create the private tmux directory"
  echo "tmux_dir=$TMUX_DIR" >> "$ROOT/$RECORD_NAME"
  mkdir -m 700 "$TMUX_DIR/tmux-$(id -u)" || die "cannot create the lab tmux socket directory"
  lab_run tmux -S "$(lab_socket)" -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT" || die "cannot start the lab tmux server"
  record_launch_pid "$(lab_tmux display-message -p '#{pid}')"

  if [ "$mate" = yes ]; then
    spawn_mate || die "cannot seed and launch the second mate"
    record_launch_pid "$(window_field mate '#{pane_pid}')"
  fi
  if [ "$worker" = yes ]; then
    spawn_worker || die "cannot launch the gated worker"
    record_launch_pid "$(window_field worker '#{pane_pid}')"
    echo "gate: $GATE (touch, then message the worker to resume)"
  fi

  local -a primary=()
  if [ "$harness" = claude ]; then
    local settle=$(( $(date +%s) + 300 )) retry
    until { [ "$mate" != yes ] || check_mate >/dev/null; } && { [ "$worker" != yes ] || [ -s "$LAB/state/$WORKER_ID.status" ]; }; do
      [ "$(date +%s)" -lt "$settle" ] || break
      sleep 2
    done
    for (( retry=0; retry<3; retry++ )); do
      lab_run "$CLAUDE_TRUST" --lab-home "$LAB" >/dev/null || die "cannot register Claude trust for the lab home"
      sleep 1
      lab_trust_present && break
    done
    lab_trust_present || die "the lab home's Claude trust keeps disappearing from $CLAUDE_STORE"
    primary=(claude --setting-sources "project,local" --model "$model" --effort "$effort" --permission-mode auto)
  else
    primary=(pi --approve --session-dir "$ROOT/pi-sessions" --model "$model" --thinking "$effort")
  fi
  lab_tmux new-window -d -t firstmate: -n main -c "$LAB" \
    env FM_HOME="$LAB" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false "${primary[@]}" \
    || die "cannot launch the lab primary"
  lab_tmux set-option -w -t "$(window_id main)" remain-on-exit on >/dev/null
  record_launch_pid "$(window_field main '#{pane_pid}')"
  echo "primary: ${primary[*]}"

  local deadline=$(( $(date +%s) + 180 ))
  until [ -f "$LAB/state/.session-start-complete" ] || [ "$(date +%s)" -ge "$deadline" ]; do sleep 2; done
  sleep 5
  say_text main "Lab readiness probe from bin/fm-live-lab.sh. Run no tool or command for this message. Reply with only the word LABREADY, a hyphen, and then $NONCE, with no spaces." \
    || die "cannot send the readiness probe"

  deadline=$(( $(date +%s) + timeout ))
  local report
  while :; do
    report=$(run_checks) && { printf '%s\n' "$report"; echo "ready: $ROOT"; return 0; }
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  printf '%s\n' "$report"
  echo "not ready after ${timeout}s; the lab is left up for inspection: $0 pane $ROOT, then $0 down $ROOT" >&2
  return 1
}

# ---- down -------------------------------------------------------------------

record_launch_pid() {
  local start
  case "${1:-}" in ''|*[!0-9]*) die "cannot record lab process: missing or invalid PID '${1:-}'" ;; esac
  start=$(ps -o lstart= -p "$1" | awk '{$1=$1; print}')
  [ -n "$start" ] || die "cannot record start time for lab process $1"
  printf 'launch_pid=%s\nlaunch_start=%s\n' "$1" "$start" >> "$ROOT/$RECORD_NAME"
}

# Resolve recorded roots only while their start times match, before tmux
# reparents their descendants.
lab_pids() {
  ps -axo pid=,ppid=,lstart= | awk -v record="$ROOT/$RECORD_NAME" '
    BEGIN {
      while ((getline line < record) > 0) {
        if (line ~ /^launch_pid=[0-9]+$/) { sub(/^launch_pid=/, "", line); root=line }
        else if (line ~ /^launch_start=/ && root != "") {
          sub(/^launch_start=/, "", line); starts[root]=line; root=""
        }
      }
      close(record)
    }
    {
      pid[NR]=$1; ppid[$1]=$2
      start=$3 " " $4 " " $5 " " $6 " " $7
      if ($1 in starts && start == starts[$1]) roots[$1]=1
    }
    END {
      for (i = 1; i <= NR; i++) {
        p = pid[i]
        for (q = p; q > 1 && (q in ppid); q = ppid[q]) {
          if (q in roots) { print p; break }
        }
      }
    }'
}

# Extend the pre-kill snapshot with descendants of still-matching processes
# and live members of captured lab process groups. Retain old pairs after reparenting.
expand_pairs() {
  awk -v groups="$2" '
    BEGIN { split(groups, ids, /[[:space:]]+/); for (i in ids) if (ids[i] > 1) group[ids[i]]=1 }
    NR==FNR { split($0, fields, "\t"); if (fields[1] ~ /^[0-9]+$/) saved[fields[1]]=fields[2]; next }
    {
      pid=$1; parent[pid]=$2; pgid[pid]=$3; state[pid]=$4
      start[pid]=$5 " " $6 " " $7 " " $8 " " $9
      if (pid in saved && start[pid] == saved[pid] && state[pid] !~ /^Z/) owned[pid]=1
    }
    END {
      for (pid in saved) print pid "\t" saved[pid]
      for (pid in parent) {
        if (pid in saved || state[pid] ~ /^Z/) continue
        if (pgid[pid] in group) { print pid "\t" start[pid]; continue }
        for (p=parent[pid]; p > 1 && (p in parent); p=parent[p]) {
          if (p in owned) { print pid "\t" start[pid]; break }
        }
      }
    }' <(printf '%s\n' "$1") <(printf '%s\n' "$3")
}

# A group is eligible only while each scan still sees an identity-valid member.
# Once absent, it is removed from the caller's group list and cannot be rediscovered.
prune_groups() {
  awk -v groups="$1" '
    BEGIN { n=split(groups, ids, /[[:space:]]+/) }
    NR==FNR { split($0, fields, "\t"); if (fields[1] ~ /^[0-9]+$/) saved[fields[1]]=fields[2]; next }
    {
      pid=$1; pgid=$3; state=$4
      start=$5 " " $6 " " $7 " " $8 " " $9
      if (state !~ /^Z/ && (!(pid in saved) || saved[pid] == start)) live[pgid]=1
    }
    END { for (i=1; i<=n; i++) if (ids[i] in live) printf "%s ", ids[i] }
  ' <(printf '%s\n' "$2") <(printf '%s\n' "$3")
}

refresh_pairs() {
  local snapshot
  snapshot=$(ps -axo pid=,ppid=,pgid=,stat=,lstart=)
  pairs=$(expand_pairs "$pairs" "$groups" "$snapshot")
  groups=$(prune_groups "$groups" "$pairs" "$snapshot")
}

# <pid TAB lstart> pairs captured before tmux shutdown. Recheck identity even
# after a root exits and its children are reparented or a PID is reused.
live_pids() {
  local pid start current
  while IFS=$'\t' read -r pid start; do
    [ -n "$pid" ] || continue
    current=$(ps -o stat=,lstart= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
    case "$current" in ''|Z*) ;; *)
      [ "${current#* }" = "$start" ] && echo "$pid"
      ;;
    esac
  done <<< "$1"
}

forget_claude_entries() {  # remove every project entry at or under ROOT; prints the count
  [ -e "$CLAUDE_STORE" ] || { echo 0; return 0; }
  node - "$CLAUDE_STORE" "$ROOT" "${ROOT#/private}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [link, ...roots] = process.argv.slice(2);
const store = fs.realpathSync(link);
const stat = fs.statSync(store);
if (!stat.isFile() || stat.uid !== process.getuid()) {
  console.error(`error: ${store} is not a regular file this user owns`); process.exit(1);
}
const inLab = (key) => roots.some((r) => key === r || key.startsWith(`${r}/`));
const fingerprint = (buf) => crypto.createHash("sha256").update(buf).digest("hex");
for (let attempt = 0; attempt < 3; attempt += 1) {
  const original = fs.readFileSync(store);
  const root = JSON.parse(original.toString("utf8"));
  const projects = root.projects;
  if (projects === undefined) { console.log(0); process.exit(0); }
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    console.error(`error: ${store} has a non-object "projects" value`); process.exit(1);
  }
  const removed = Object.keys(projects).filter(inLab);
  if (removed.length === 0) { console.log(0); process.exit(0); }
  const kept = Object.keys(projects).filter((k) => !inLab(k));
  for (const key of removed) delete projects[key];
  const tmp = path.join(path.dirname(store), `.claude.json.fm-live-lab.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: fs.statSync(store).mode & 0o777, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(fs.readFileSync(store)) !== fingerprint(original)) continue;
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = Object.keys(JSON.parse(fs.readFileSync(store, "utf8")).projects || {});
  if (back.some(inLab) || kept.some((k) => !back.includes(k))) {
    console.error(`error: ${store} did not keep exactly the non-lab entries`); process.exit(1);
  }
  console.log(removed.length);
  process.exit(0);
}
console.error(`error: ${store} kept changing while lab entries were being removed`);
process.exit(1);
NODE
}

cmd_down() {
  load_lab "${1:-}"
  local rc=0 pids pairs pid start survivors n removed added id meta dir home_hash groups pgid own_group caller_group details
  local -a ids=()
  pids=$(lab_pids)
  pairs='' groups=''
  own_group=$(ps -o pgid= -p "$$" | awk '{$1=$1; print}')
  caller_group=$(ps -o pgid= -p "$PPID" | awk '{$1=$1; print}')
  for pid in $pids; do
    start=$(ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
    [ -n "$start" ] || continue
    pairs+="$pid"$'\t'"$start"$'\n'
    pgid=$(ps -o pgid=,lstart= -p "$pid" 2>/dev/null | awk -v start="$start" '{ if ($2 " " $3 " " $4 " " $5 " " $6 == start) print $1 }')
    case "$pgid" in ''|0|1|*[!0-9]*) continue ;; esac
    [ "$pgid" = "$own_group" ] || [ "$pgid" = "$caller_group" ] || groups+="$pgid "
  done
  lab_kill_server
  refresh_pairs
  survivors=$(live_pids "$pairs")
  if [ -n "$survivors" ]; then
    # shellcheck disable=SC2086 # One identity-checked pid per word.
    kill $survivors 2>/dev/null || true
  fi
  for n in {1..40}; do
    refresh_pairs
    survivors=$(live_pids "$pairs")
    if [ -z "$survivors" ]; then
      sleep 0.5
      refresh_pairs
      survivors=$(live_pids "$pairs")
      [ -n "$survivors" ] || break
    fi
    if [ "$n" -ge 20 ]; then
      # shellcheck disable=SC2086 # One identity-checked pid per word.
      kill -9 $survivors 2>/dev/null || true
    fi
    sleep 0.5
  done
  refresh_pairs
  survivors=$(live_pids "$pairs")
  if [ -n "$survivors" ]; then
    details=''
    for pid in $survivors; do
      details+="$(ps -o pid=,ppid=,pgid=,stat=,command= -p "$pid" 2>/dev/null)"$'\n'
    done
    die "refusing to remove the lab: its processes did not exit (pid ppid pgid state command): $details"
  fi
  echo "stopped: lab tmux server and lab processes"
  # A spawn keeps /tmp/fm-<id> and /tmp/fm-<id>+<sha256 of the spawning home>.
  # The second is scoped to this lab home for any task it spawned; the first is
  # removed only for the lab's own unique ids, since another home may share it.
  home_hash=$(printf '%s' "$LAB" | shasum -a 256 | awk '{print $1}')
  ids=("$MATE_ID" "$WORKER_ID")
  for meta in "$LAB"/state/*.meta; do
    [ -f "$meta" ] && ids+=("$(basename "$meta" .meta)")
  done
  for id in "${ids[@]}"; do
    [ -n "$id" ] || continue
    for dir in "/tmp/fm-$id+$home_hash" "/tmp/fm-$id"; do
      [ "$dir" != "/tmp/fm-$id" ] || [ "$id" = "$MATE_ID" ] || [ "$id" = "$WORKER_ID" ] || continue
      if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; then
        rm -rf "$dir" && echo "removed: task temp $dir"
      fi
    done
  done
  if [ -f "$LAB/.fm-lab-home" ]; then
    "$LAB_HOME_HELPER" teardown "$LAB" || die "cannot remove the private tmux directory"
  fi
  removed=$(forget_claude_entries) || die "cannot remove the lab's Claude trust entries"
  echo "removed: $removed Claude project entries under $ROOT"
  if [ "$(digest "$PI_TRUST_STORE")" != "$PI_TRUST_BEFORE" ]; then
    echo "warning: the Pi trust store changed since up began; left as is" >&2
    rc=1
  fi
  added=$(comm -13 "$ROOT/.treehouse-before" <(treehouse_listing | sort) 2>/dev/null)
  if [ -n "$added" ]; then
    echo "warning: ~/.treehouse gained entries during the lab; left as is: $(printf '%s' "$added" | tr '\n' ' ')" >&2
    rc=1
  fi
  chmod -R u+w "$ROOT" 2>/dev/null
  rm -rf "$ROOT" || die "cannot remove $ROOT"
  [ ! -e "$ROOT" ] || die "$ROOT is still present"
  echo "removed: $ROOT"
  return "$rc"
}

# ---- say / pane / check -----------------------------------------------------

cmd_say() {
  local window=main
  load_lab "${1:-}"; shift
  [ "${1:-}" = --window ] && { window=${2:-}; shift 2; }
  [ "$#" -ge 1 ] || usage
  say_text "$window" "$*"
}

cmd_pane() {
  local window=main lines=200
  load_lab "${1:-}"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --window) window=${2:-}; shift 2 ;;
      --lines) lines=${2:-}; shift 2 ;;
      *) usage ;;
    esac
  done
  local id
  id=$(window_id "$window")
  [ -n "$id" ] || die "no lab window named '$window'"
  lab_tmux capture-pane -p -J -t "$id" -S "-$lines" | grep -v '^[[:space:]]*$'
}

cmd_check() {
  load_lab "${1:-}"
  run_checks
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  check) shift; cmd_check "$@" ;;
  say) shift; cmd_say "$@" ;;
  pane) shift; cmd_pane "$@" ;;
  down) shift; cmd_down "$@" ;;
  -h|--help) help_text ;;
  *) usage ;;
esac
