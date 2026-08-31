#!/usr/bin/env bash
# Opt-in credentialed live guard for the writable roots firstmate grants a codex
# crewmate. Whether codex's sandbox actually honors those roots is a
# HARNESS-DEPENDENT fact: only the installed binary can answer it, and a portable
# test asserting the flag is present would keep passing after codex renamed or
# dropped it. tests/fm-codex-sandbox-grant.test.sh pins the composition and the
# root set; this guard proves the vendor still enforces them, and fails naming the
# codex version so a refreshed claim in docs/verification/codex-sandbox.md is
# never older than the binary it describes.
#
# Two halves, both against the real binary:
#   1. `codex sandbox` runs a command under the same seatbelt policy with no model
#      call, so the deny-without / allow-with boundary is deterministic.
#   2. `codex exec` drives a real model turn with the EXACT --add-dir flags
#      fm-spawn composed, which is the only way to prove the flag firstmate ships
#      reaches the sandbox policy at all.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex sandbox-grant guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found; this guard refuses to pass without checking the real binary"
CODEX_VERSION=$(codex --version)

# The lab lives under the repo, NOT under $TMPDIR: codex's workspace-write sandbox
# grants /tmp and $TMPDIR by default, so a lab there would make every "denied"
# assertion below silently vacuous.
LAB="$ROOT/.codex-sandbox-grant-live.$$"
mkdir -p "$LAB"
# FM_CODEX_KEEP_LAB=1 preserves the lab (and the real model transcript inside it)
# when this guard is run to produce evidence rather than as a pass/fail check.
cleanup() {
  chmod -R u+w "$LAB" 2>/dev/null || true
  if [ "${FM_CODEX_KEEP_LAB:-0}" = 1 ]; then
    printf 'lab preserved: %s\n' "$LAB" >&2
    return 0
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

HOME_DIR="$LAB/fmhome"
PROJECT="$LAB/project"
WT="$LAB/wt"
ID=codex-grant-live
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/config" "$HOME_DIR/projects"
printf 'brief\n' > "$HOME_DIR/data/$ID/brief.md"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
touch "$HOME_DIR/state/.last-watcher-beat"

# A real project with a real LINKED worktree, so the git common dir under test is
# the out-of-tree one a pooled task worktree actually has.
git init -q -b main "$PROJECT"
( cd "$PROJECT" && printf 'a\n' > a.txt && git add a.txt \
  && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null
# A local bare origin, because a spawn refuses to launch a pooled worktree whose
# base it cannot freshen against origin.
git clone --quiet --bare "$PROJECT" "$PROJECT.origin.git"
git -C "$PROJECT" remote add origin "file://$(cd "$PROJECT.origin.git" && pwd)"
git -C "$PROJECT" worktree add -q -b "fm/$ID" "$WT"

# The roots under test come from fm-spawn itself, never from a list retyped here.
FAKEBIN="$LAB/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l|Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/treehouse"

LAUNCH_LOG="$LAB/launch.log"
: > "$LAUNCH_LOG"
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" codex --scout > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn could not compose a codex scout launch: $(tail -5 "$LAB/spawn.log")"

ADD_DIR_FLAGS=$(grep -F -- '--add-dir' "$LAUNCH_LOG" | tail -1 \
  | tr ' ' '\n' | grep -A1 -F -- '--add-dir' | grep -v -F -- '--add-dir' \
  | grep -v '^--$' | sed "s/^'//; s/'\$//")
[ -n "$ADD_DIR_FLAGS" ] || fail "the composed codex launch granted no writable roots"

ROOTS_TOML=$(printf '%s\n' "$ADD_DIR_FLAGS" | sed 's/.*/"&"/' | paste -sd, -)
CLI_FLAGS=()
while IFS= read -r r; do
  [ -n "$r" ] || continue
  CLI_FLAGS+=(--add-dir "$r")
done <<EOF
$ADD_DIR_FLAGS
EOF

STATUS_FILE="$HOME_DIR/state/$ID.status"
REPORT="$HOME_DIR/data/$ID/report.md"
DENIED="$HOME_DIR/config/must-stay-denied.txt"

# --- 1. The seatbelt boundary, with no model call --------------------------

probe="$LAB/probe.sh"
cat > "$probe" <<'SH'
#!/bin/bash
# <status file> <report> <denied path> <worktree>
printf 'status:%s\n' "$( (echo 'working: live guard' >> "$1") 2>/dev/null && echo allowed || echo denied)"
printf 'report:%s\n' "$( (printf '# report\n' > "$2") 2>/dev/null && echo allowed || echo denied)"
printf 'denied:%s\n' "$( (echo x >> "$3") 2>/dev/null && echo allowed || echo denied)"
cd "$4" || exit 1
printf 'stage:%s\n' "$( (echo w > w.txt && git add w.txt) >/dev/null 2>&1 && echo allowed || echo denied)"
SH
chmod +x "$probe"

out=$(cd "$WT" && codex sandbox -c sandbox_mode='"workspace-write"' \
  -- "$probe" "$STATUS_FILE" "$REPORT" "$DENIED" "$WT" 2>/dev/null)
printf '%s\n' "$out" | grep -qx 'status:denied' \
  || fail "$CODEX_VERSION: an ungranted workspace-write sandbox already allows the status append; the grant's premise is stale ($out)"
printf '%s\n' "$out" | grep -qx 'stage:denied' \
  || fail "$CODEX_VERSION: an ungranted sandbox already allows staging in a linked worktree ($out)"

git -C "$WT" reset -q 2>/dev/null || true
rm -f "$WT/w.txt"
out=$(cd "$WT" && codex sandbox -c sandbox_mode='"workspace-write"' \
  -c "sandbox_workspace_write.writable_roots=[$ROOTS_TOML]" \
  -- "$probe" "$STATUS_FILE" "$REPORT" "$DENIED" "$WT" 2>/dev/null)
printf '%s\n' "$out" | grep -qx 'status:allowed' \
  || fail "$CODEX_VERSION: the granted roots did not make the status append possible ($out)"
printf '%s\n' "$out" | grep -qx 'report:allowed' \
  || fail "$CODEX_VERSION: the granted roots did not make the report possible ($out)"
printf '%s\n' "$out" | grep -qx 'stage:allowed' \
  || fail "$CODEX_VERSION: the granted roots did not make staging possible ($out)"
printf '%s\n' "$out" | grep -qx 'denied:denied' \
  || fail "$CODEX_VERSION: the grant leaked past the named roots into config/ ($out)"

# --- 2. The launch flag itself, through a real model turn ------------------

: > "$STATUS_FILE"
rm -f "$REPORT" "$DENIED"
transcript="$LAB/exec.log"
(
  cd "$WT" || exit 1
  codex exec -s workspace-write "${CLI_FLAGS[@]}" --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    "Run exactly these three shell commands, each separately, then stop: (1) echo 'working: live guard' >> $STATUS_FILE (2) printf '# report\n' > $REPORT (3) echo x >> $DENIED . Report for each whether it succeeded or was denied. Do nothing else and do not retry a denied command." \
    < /dev/null
) > "$transcript" 2>&1 || fail "$CODEX_VERSION: the codex exec turn failed: $(tail -20 "$transcript")"

[ -s "$STATUS_FILE" ] \
  || fail "$CODEX_VERSION: --add-dir did not make the status file writable through the launch flags: $(tail -20 "$transcript")"
[ -s "$REPORT" ] \
  || fail "$CODEX_VERSION: --add-dir did not make the report writable through the launch flags: $(tail -20 "$transcript")"
[ ! -e "$DENIED" ] \
  || fail "$CODEX_VERSION: the launch flags granted more than the named roots; config/ was writable"

printf 'ok - %s enforces exactly the granted writable roots, and the launch flags reach that policy\n' "$CODEX_VERSION"

# --- 3. The captain-hold completion gate, inside the real sandbox -----------
#
# The gate is the one contract clause the two halves above do not touch, and it
# is the clause that fails DIFFERENTLY: it does not just append to a file, it
# CREATES new entries in state/ (a lock symlink plus a mktemp-named owner
# directory), which is why a scout's grant must name the state DIRECTORY and not
# the two per-task files a ship crewmate gets. A run under `codex sandbox` proves
# the vendor's own policy admits those unnameable new entries, which no portable
# chmod confinement can establish.

if ! command -v tasks-axi >/dev/null 2>&1; then
  printf 'not ok - tasks-axi not found; the captain-hold half of this guard refuses to pass unchecked\n' >&2
  exit 1
fi

# Firstmate owns backlog state, so seed it BEFORE entering the sandbox: the gate
# only reads the call from a crewmate's side.
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml" || fail "could not seed the backlog config"
( cd "$HOME_DIR" && tasks-axi add "$ID" --title origin ) >/dev/null \
  || fail "could not seed the origin task"
( cd "$HOME_DIR" && tasks-axi add "$ID-call" --title call ) >/dev/null \
  || fail "could not seed the captain call"
( cd "$HOME_DIR" && tasks-axi hold "$ID-call" --reason "captain call" --kind captain ) >/dev/null \
  || fail "could not hold the captain call"

hold_probe="$LAB/hold.sh"
cat > "$hold_probe" <<'SH'
#!/bin/bash
# <root> <fm home> <origin id> <call id>
if out=$(FM_ROOT_OVERRIDE="$1" FM_HOME="$2" \
    FM_STATE_OVERRIDE="$2/state" FM_DATA_OVERRIDE="$2/data" \
    "$1/bin/fm-captain-hold.sh" complete "$3" "$4" 2>&1); then
  printf 'hold:allowed\n'
else
  printf 'hold:denied %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
fi
SH
chmod +x "$hold_probe"

# Ungranted first: the gate must be the thing the bare sandbox breaks, otherwise
# this half is vacuous and the scout's directory-wide grant is unjustified.
out=$(cd "$WT" && codex sandbox -c sandbox_mode='"workspace-write"' \
  -- "$hold_probe" "$ROOT" "$HOME_DIR" "$ID" "$ID-call" 2>/dev/null)
case "$out" in
  hold:denied*) ;;
  *) fail "$CODEX_VERSION: an ungranted sandbox already completes the captain-hold gate; the scout grant's premise is stale ($out)" ;;
esac

out=$(cd "$WT" && codex sandbox -c sandbox_mode='"workspace-write"' \
  -c "sandbox_workspace_write.writable_roots=[$ROOTS_TOML]" \
  -- "$hold_probe" "$ROOT" "$HOME_DIR" "$ID" "$ID-call" 2>/dev/null)
case "$out" in
  hold:allowed) ;;
  *) fail "$CODEX_VERSION: the granted roots did not let the captain-hold completion gate run ($out)" ;;
esac

printf 'ok - %s admits the captain-hold completion gate under the granted roots and denies it without them\n' "$CODEX_VERSION"
