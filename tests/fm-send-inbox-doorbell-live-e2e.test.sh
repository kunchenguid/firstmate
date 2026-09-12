#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. A stub can
# only confirm the assumption already
# written into the stub, so per .agents/skills/firstmate-coding-guidelines
# this is proven against every INSTALLED verified harness: each is launched
# idle in an isolated tmux server, steered through the REAL fm-send (durable
# record + doorbell), and must both ACT on the instruction (create a named
# file) and ACKNOWLEDGE it (the mv into handled/), failing loudly with the
# harness name and version.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E,FM_AGY_LIFECYCLE_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
LIFECYCLE_TMUX_WIDTH=${FM_AGY_LIFECYCLE_TMUX_WIDTH:-220}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
RING_COUNTER_FILE="$LAB/doorbell-ring.count"
: > "$RING_COUNTER_FILE"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *"Firstmate instruction waiting:"*)
        count=\$(cat "$RING_COUNTER_FILE" 2>/dev/null || printf '0')
        printf '%s\n' "\$((count + 1))" > "$RING_COUNTER_FILE"
        break
        ;;
    esac
  done
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x "$LIFECYCLE_TMUX_WIDTH" -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    agy) printf '%s' 'agy --dangerously-skip-permissions --effort low' ;;
    *) return 1 ;;
  esac
}

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window> [harness]
  local win=$1 harness=${2:-} i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win" "$harness")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "$cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win" "$name"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

if [ "${FM_AGY_LIFECYCLE_LIVE_E2E:-}" != 1 ]; then
  HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse agy'}
  for h in $HARNESSES; do
    if command -v "$h" >/dev/null 2>&1; then
      check_harness_doorbell "$h"
    else
      note "harness absent, not verified here: $h"
    fi
  done

  if [ "$FAILED" -ne 0 ]; then
    printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
    exit 1
  fi
  if [ "$CHECKED" -eq 0 ]; then
    printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
    exit 1
  fi
  pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
fi

run_agy_canonical_lifecycle() (
  local task="live-agy-lifecycle-$$" lab project home status target version stable_verdict stable_count draft_landed content note_line
  local doorbell_inbox doorbell_acted doorbell_marker doorbell_brief ring_count record
  local spawned=0 state capture busy=0 turn_end=0 verdict=unknown trust_seen=0
  [ "${FM_AGY_LIFECYCLE_LIVE_E2E:-}" = 1 ] || return 0
  die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
  cleanup_lifecycle() {
    if [ "$spawned" -eq 1 ]; then
      TMUX_TMPDIR="$lab/tmux" tmux kill-server >/dev/null 2>&1 || true
    fi
    [ -z "${lab:-}" ] || rm -rf "$lab"
  }
  trap cleanup_lifecycle EXIT
  command -v agy >/dev/null 2>&1 || die 'agy lifecycle guard requested but agy is absent'
  command -v treehouse >/dev/null 2>&1 || die 'agy lifecycle guard requested but treehouse is absent'
  version=$(agy --version 2>/dev/null | head -1 || printf 'version-unknown')
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-lifecycle.XXXXXX")
  project="$lab/project"
  home="$lab/home"
  status="$home/state/$task.status"
  mkdir -p "$home/state" "$home/config" "$home/data/$task" "$lab/tmux"
  git clone -q "$ROOT" "$project" || die "agy ($version): could not create the isolated lifecycle project"
  if ! git -C "$project" symbolic-ref -q HEAD >/dev/null 2>&1; then
    git -C "$project" switch -c main >/dev/null 2>&1 \
      || die "agy ($version): could not attach the isolated lifecycle project to a branch"
  fi
  git -C "$project" config user.email 'agy-lifecycle-test@example.invalid'
  git -C "$project" config user.name 'agy lifecycle test'
  printf 'tmux\n' > "$home/config/backend"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$task" lifecycle --scout \
    >/dev/null || die "agy ($version): could not scaffold the lifecycle brief"
  cat > "$home/data/$task/brief.md" <<'EOF'
# Task

Run the exact shell command `sleep 60` and wait for it to finish.
Do not run any other command.
EOF
  TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$task" "$project" --scout --harness agy --effort low --backend tmux \
    >/dev/null || die "agy ($version): canonical fm-spawn could not launch"
  spawned=1
  state="$home/state"
  target=$(awk -F= '/^window=/{print $2}' "$state/$task.meta")
  [ -n "$target" ] || die "agy ($version): canonical spawn did not publish an endpoint"
  [ -f "$state/$task.agy-hooks/.agents/hooks.json" ] \
    || die "agy ($version): canonical spawn did not generate private hooks"
  for _ in $(seq 1 120); do
    capture=$(TMUX_TMPDIR="$lab/tmux" tmux capture-pane -p -t "$target" 2>/dev/null || true)
    if [ "$trust_seen" -eq 0 ] && printf '%s\n' "$capture" | grep -qi 'trust'; then
      TMUX_TMPDIR="$lab/tmux" tmux send-keys -t "$target" Enter || \
        die "agy ($version): trust dialog could not be accepted"
      trust_seen=1
      sleep 1
      continue
    fi
    if printf '%s\n' "$capture" | grep -Eq 'esc to cancel|Working|Generating'; then
      busy=1
      break
    fi
    sleep 1
  done
  [ "$busy" -eq 1 ] || die "agy ($version): initial brief never reached a real running tool"
  grep -Fq 'state=busy' "$state/$task.busy-state" \
    || die "agy ($version): canonical spawn did not seed semantic busy state"
  TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-control.sh" "$task" interrupt > "$lab/control.out" 2>&1 \
    || die "agy ($version): control-plane interrupt failed"
  grep -Fq 'cancel=unconfirmed' "$lab/control.out" \
    || die "agy ($version): control-plane interrupt did not report unconfirmed cancellation"
  grep -Fq 'state=unknown' "$state/$task.busy-state" \
    || die "agy ($version): control-plane interrupt did not preserve unknown semantic state"
  for _ in $(seq 1 60); do
    verdict=$(TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_tmux_composer_state "$2" agy' _ "$ROOT" "$target" 2>/dev/null || true)
    [ "$verdict" = empty ] && break
    sleep 1
  done
  [ "$verdict" = empty ] || die "agy ($version): control interrupt did not return to a proven empty composer"
  doorbell_inbox="$state/$task.inbox"
  doorbell_acted="$lab/AGY_DOORBELL_RESULT"
  doorbell_marker="AGY_DOORBELL_$(date +%s)-$$"
  if [ -d "$doorbell_inbox" ]; then
    for record in "$doorbell_inbox"/*.msg "$doorbell_inbox"/handled/*.msg; do
      [ ! -e "$record" ] || die "agy ($version): doorbell inbox was not empty before the steer"
    done
  fi
  [ ! -e "$doorbell_acted" ] || die "agy ($version): doorbell action artifact already existed"
  : > "$RING_COUNTER_FILE"
  doorbell_brief="Run the exact shell command \`printf '%s\\n' '$doorbell_marker' > '$doorbell_acted'\` once, then stop."
  FM_SEND_SETTLE=0 TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-send.sh" "$task" "$doorbell_brief" >/dev/null 2>&1 \
    || die "agy ($version): doorbell steer could not be recorded"
  [ -f "$doorbell_inbox/001.msg" ] || [ -f "$doorbell_inbox/handled/001.msg" ] \
    || die "agy ($version): doorbell steer left no durable inbox record"
  ring_count=$(cat "$RING_COUNTER_FILE" 2>/dev/null || printf '0')
  [ "$ring_count" = 1 ] || die "agy ($version): fm-send rang the doorbell $ring_count times, expected exactly once"
  for _ in $(seq 1 120); do
    if [ -f "$doorbell_acted" ] && grep -Fqx "$doorbell_marker" "$doorbell_acted" 2>/dev/null \
      && [ -f "$doorbell_inbox/handled/001.msg" ]; then
      break
    fi
    sleep 1
  done
  [ -f "$doorbell_acted" ] && grep -Fqx "$doorbell_marker" "$doorbell_acted" \
    || die "agy ($version): doorbell instruction was not acted on"
  [ -f "$doorbell_inbox/handled/001.msg" ] \
    || die "agy ($version): doorbell instruction was not acknowledged"
  rm -f "$state/$task.progress"
  lifecycle_progress_brief='Run the exact shell command "printf AGY_TOOL_PROGRESS" once, then stop.'
  FM_SEND_SETTLE=0 TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-send.sh" "$task" \
    "$lifecycle_progress_brief" >/dev/null 2>&1 \
    || die "agy ($version): progress probe turn could not be submitted"
  for _ in $(seq 1 120); do
    [ -f "$state/$task.progress" ] && break
    sleep 1
  done
  [ -f "$state/$task.progress" ] \
    || die "agy ($version): PostToolUse did not refresh progress during a real tool call"
  lifecycle_natural_brief="Run \`printf AGY_LIFECYCLE_DONE\` exactly once, then stop."
  FM_SEND_SETTLE=0 TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-send.sh" "$task" \
    "$lifecycle_natural_brief" >/dev/null 2>&1 \
    || die "agy ($version): natural turn could not be submitted"
  for _ in $(seq 1 120); do
    if [ -f "$state/$task.turn-ended" ] && grep -Fq 'state=idle' "$state/$task.busy-state" 2>/dev/null; then
      turn_end=1
      break
    fi
    sleep 1
  done
  [ "$turn_end" -eq 1 ] || die "agy ($version): natural Stop did not publish idle and turn-ended state"
  lifecycle_tool_brief="Run the exact shell command \`sleep 60\` and wait for it to finish. Do not run any other command."
  FM_SEND_SETTLE=0 TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-send.sh" "$task" \
    "$lifecycle_tool_brief" \
    >/dev/null 2>&1 || die "agy ($version): data-plane turn could not be submitted"
  for _ in $(seq 1 120); do
    capture=$(TMUX_TMPDIR="$lab/tmux" tmux capture-pane -p -t "$target" 2>/dev/null || true)
    if printf '%s\n' "$capture" | grep -Eq 'esc to cancel|Working|Generating'; then
      break
    fi
    sleep 1
  done
  TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-send.sh" "$task" --key Escape > "$lab/data.out" 2>&1 \
    || die "agy ($version): data-plane interrupt failed"
  grep -Fq 'unknown fm-interrupt' "$state/$task.busy-state" 2>/dev/null || \
    grep -Fq 'state=unknown' "$state/$task.busy-state" \
    || die "agy ($version): data-plane interrupt did not preserve unknown semantic state"
  lifecycle_exit_draft='AGY_EXIT_UNSENT_DRAFT'
  stable_verdict=unknown
  stable_count=0
  for _ in $(seq 1 20); do
    verdict=$(TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_tmux_composer_state "$2" agy' _ "$ROOT" "$target" 2>/dev/null || true)
    if [ "$verdict" = "$stable_verdict" ] && [ "$verdict" != unknown ]; then
      stable_count=$((stable_count + 1))
    else
      stable_verdict=$verdict
      stable_count=1
    fi
    [ "$stable_count" -ge 2 ] && break
    sleep 0.25
  done
  [ "$stable_count" -ge 2 ] || die "agy ($version): composer did not settle before the exit draft"
  draft_landed=0
  for _ in 1 2; do
    TMUX_TMPDIR="$lab/tmux" tmux send-keys -t "$target" -l "$lifecycle_exit_draft" \
      || die "agy ($version): could not leave an unsent composer draft before exit"
    for _ in $(seq 1 20); do
      verdict=$(TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_tmux_composer_state "$2" agy' _ "$ROOT" "$target" 2>/dev/null || true)
      if [ "$verdict" = pending ]; then
        content=$(TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
          bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agy_composer_content tmux "$2" "$3"' _ "$ROOT" "$target" "fm-$task" 2>/dev/null || true)
        case "$content" in
          *"$lifecycle_exit_draft"*) draft_landed=1; break ;;
        esac
      fi
      sleep 0.25
    done
    [ "$draft_landed" -eq 1 ] && break
  done
  [ "$draft_landed" -eq 1 ] || die "agy ($version): exit draft did not reach the composer with its marker intact"
  TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-control.sh" "$task" exit >/dev/null 2>&1 \
    || die "agy ($version): exit command failed"
  note_line=$(grep -F 'note: exit cleared unsent composer text:' "$status" | tail -1 || true)
  printf '%s\n' "$note_line" | grep -Fq "$lifecycle_exit_draft" \
    || die "agy ($version): exit did not record the cleared composer marker"
  mkdir -p "$home/data/$task"
  : > "$home/data/$task/report.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-decision-hold.sh" complete "$task" --none \
    >/dev/null 2>&1 || die "agy ($version): decision hold cleanup failed"
  local teardown_out teardown_rc=0
  teardown_out=$(TMUX_TMPDIR="$lab/tmux" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-teardown.sh" "$task" 2>&1) || teardown_rc=$?
  [ "$teardown_rc" -eq 0 ] || die "agy ($version): teardown failed: $teardown_out"
  [ ! -e "$state/$task.agy-hooks" ] || die "agy ($version): teardown left private hooks behind"
  pass "agy ($version): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed"
)

run_agy_canonical_lifecycle || exit 1
