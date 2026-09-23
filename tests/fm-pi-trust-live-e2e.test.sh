#!/usr/bin/env bash
# Live guard for the Pi scoped one-run project-resource approval
# (live-harness-optin family). Per .agents/skills/firstmate-coding-guidelines
# "Harness-dependent checks", the claim that `--approve` prevents Pi's
# folder-trust stall - and that omitting it stalls - must be proven against
# the REAL installed Pi, because the trust dialog is a vendor-rendered
# surface no stub can confirm (the launch-prompt backstop guard exists for
# exactly that reason: an initial Pi signature read off the binary's own UI
# strings never matched the real screen).
#
# Against the real pi and the real fm-spawn on an isolated Herdr lab session,
# with an isolated PI_CODING_AGENT_DIR trust store (so the operator's own
# trust.json is never read or written and every case starts untrusted):
#
#   1. trigger: a bare pi TUI (no --approve, no submitted prompt) in a fresh
#      worktree carrying a project-local trust-requiring resource renders
#      "Trust project folder?" and parks - the stall the fleet kept hitting;
#   2. prevention: a real fm-spawn scout launch carries --approve (asserted
#      from the recorded launch arguments), never renders the dialog, and the
#      real model processes the launch brief to its marker line - this one
#      case spends model tokens, which is why the whole guard is opt-in;
#   3. one-run scope: the isolated trust.json is still empty after the
#      approved launch, and the operator's real trust.json is byte-identical
#      from before the guard to after it;
#   4. already-trusted: with a saved parent-path decision in the isolated
#      store, a bare pi TUI (still no --approve, no submitted prompt) skips
#      the dialog - proving saved trust is what masks the stall on
#      previously answered slots, which is why the bug is per-slot
#      intermittent rather than universal;
#   5. refusal: a pi whose --help omits --approve makes the real fm-spawn
#      refuse before any endpoint or metadata exists.
#
# Cases 1, 4, and 5 spend no model tokens, but case 2 submits the real
# launch brief, so the guard as a whole stays opt-in. Run it after every Pi
# upgrade and before trusting a refreshed docs/verification/runtime-backends.md
# "Pi one-run project-resource approval" entry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate opt-in FM_PI_TRUST_LIVE_E2E herdr pi jq git

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
REAL_PI=$(command -v pi)
version_note() { printf ' [herdr %s, pi %s]' "$HERDR_VERSION" "$PI_VERSION"; }

SESSION="fm-lab-pi-trust-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
OP_TRUST="$HOME/.pi/agent/trust.json"
OP_TRUST_BEFORE=
cleanup_all() {
  local status=$?
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  if [ -n "${OP_TRUST_BEFORE:-}" ] && [ -f "$OP_TRUST" ]; then
    local after
    after=$(sha256sum "$OP_TRUST" | cut -d' ' -f1)
    [ "$after" = "$OP_TRUST_BEFORE" ] \
      || printf 'not ok - the operator trust store changed during the guard%s\n' "$(version_note)" >&2
  fi
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

OP_TRUST_BEFORE=$(sha256sum "$OP_TRUST" 2>/dev/null | cut -d' ' -f1) \
  || fail "could not hash the operator trust store before the guard"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-trust.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"

# The repro project: a git repo whose every pooled worktree carries a
# project-local trust-requiring resource (.pi/settings.json), with the
# treehouse pool kept in-project so nothing outside the scratch dir is
# touched. This is the exact trigger shape a real scout spawn launches into.
PROJECT="$SCRATCH/project"
mkdir -p "$PROJECT/.pi"
git -C "$PROJECT" init -q || fail "could not initialize the repro project"
git -C "$PROJECT" config user.email probe@localhost
git -C "$PROJECT" config user.name probe
printf '%s\n' '{}' > "$PROJECT/.pi/settings.json"
printf '%s\n' 'max_trees = 4' 'root = "."' > "$PROJECT/treehouse.toml"
printf '%s\n' '.treehouse/' > "$PROJECT/.gitignore"
git -C "$PROJECT" add -A || fail "could not stage the repro project"
git -C "$PROJECT" commit -qm "repro project with a project-local pi resource" \
  || fail "could not commit the repro project"

# The isolated trust-store shim: fm-spawn resolves `pi` from PATH once and
# launches that concrete path, so a PATH-fronted pass-through shim is the one
# surgical way to point every launch at an isolated PI_CODING_AGENT_DIR while
# keeping the real executable, real credentials (copied, so a token refresh
# never writes the operator's store), and real trust behavior. The shim also
# records the exact arguments of every call for the --approve assertions.
make_shim() { # <dir> <agent-dir> <omit-approve:0|1>
  local dir=$1 agent=$2 omit=$3 log
  log="$SCRATCH/args-$(basename "$dir").log"
  mkdir -p "$dir" "$agent"
  printf '%s\n' '{}' > "$agent/trust.json"
  cp "$HOME/.pi/agent/auth.json" "$agent/auth.json" 2>/dev/null \
    || fail "no pi auth store to copy; this guard needs the machine's real pi credentials"
  cat > "$dir/pi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$(date +%s) \$*" >> '$log'
export PI_CODING_AGENT_DIR='$agent'
if [ "\${1:-}" = --help ] && [ "$omit" = 1 ]; then
  printf '%s\n' 'Pi 0.0.0-controlled' 'Options: --help --tui-mode <mode>'
  exit 0
fi
exec '$REAL_PI' "\$@"
EOF
  chmod +x "$dir/pi"
}

make_home() { # <home-dir>
  mkdir -p "$1/data" "$1/state" "$1/config"
  printf 'manual\n' > "$1/config/backlog-backend"
}

write_brief() { # <home> <id>
  local home=$1 id=$2 brief
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" repro-project --scout >/dev/null 2>&1 \
    || fail "could not scaffold the scout brief for $id"
  brief="$home/data/$id/brief.md"
  python3 - "$brief" "$home/instruction-processed" <<'PY' || fail "could not fill the scout brief"
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('{TASK}', f'Confirm you are processing instructions: write the single line INSTRUCTION_PROCESSED to {sys.argv[2]} and then stop working. Do not read or change anything else.')
s = s.replace('{FIRSTMATE_SPEC}', 'This is a launch-readiness probe. Create the requested marker file exactly once and stop.')
open(p, 'w').write(s)
if '{TASK}' in s or '{FIRSTMATE_SPEC}' in s:
    sys.exit(1)
PY
}

capture() { # <pane-id>
  lab pane read --source recent --lines 60 "$1" 2>/dev/null || true
}

wait_for_regex() { # <pane-id> <regex> <tries> <label>
  local pane=$1 regex=$2 tries=$3 label=$4 tail='' i
  for ((i = 0; i < tries; i++)); do
    tail=$(capture "$pane")
    if printf '%s' "$tail" | grep -qiE "$regex"; then
      printf '%s' "$tail" | tail -30 >&2
      note "seen within budget: $label"
      return 0
    fi
    sleep 2
  done
  printf '%s' "$tail" | tail -30 >&2
  fail "never seen within budget: $label$(version_note)"
}

# --- Case 1: the bare launch stalls on the trust dialog (the incident) -----
make_shim "$SCRATCH/shim-1" "$SCRATCH/agent-1" 0
WS1=$(lab workspace create --label fm-pi-trust-trigger --cwd "$PROJECT" 2>&1) \
  || fail "could not create the trigger workspace: $WS1"
PANE1=$(printf '%s' "$WS1" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE1" ] || fail "workspace create did not return a root pane id"
PATH="$SCRATCH/shim-1:$PATH" lab pane run "$PANE1" pi >/dev/null 2>&1 \
  || fail "could not launch the real pi in the trigger pane"
wait_for_regex "$PANE1" 'Trust project folder\?' 45 'the folder-trust dialog (the stall)'
pass "bare pi in a fresh untrusted worktree parks on Trust project folder?$(version_note)"
# Escape cancels the dialog; no Enter is ever sent, so no trust decision is
# saved and no prompt is submitted.
lab pane send-keys "$PANE1" Escape >/dev/null 2>&1 || true
sleep 1
lab pane send-text "$PANE1" '/quit' >/dev/null 2>&1 || true
sleep 0.5
lab pane send-keys "$PANE1" Enter >/dev/null 2>&1 || true
lab pane close "$PANE1" >/dev/null 2>&1 || true

# --- Case 2: the managed launch approves project resources for the run -----
make_shim "$SCRATCH/shim-2" "$SCRATCH/agent-2" 0
make_home "$SCRATCH/home-2"
write_brief "$SCRATCH/home-2" pitrust2
MARKER2="$SCRATCH/home-2/instruction-processed"
[ ! -e "$MARKER2" ] || fail "the instruction-processing marker already exists before launch"
(
  cd "$SCRATCH" \
    && PATH="$SCRATCH/shim-2:$PATH" FM_HOME="$SCRATCH/home-2" \
      FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-spawn.sh" pitrust2 "$PROJECT" \
      --scout --harness pi --backend herdr
) > "$SCRATCH/spawn-2.out" 2>&1 \
  || fail "the fixed fm-spawn scout launch failed: $(tail -5 "$SCRATCH/spawn-2.out")"
META2="$SCRATCH/home-2/state/pitrust2.meta"
[ -f "$META2" ] || fail "the scout spawn recorded no task metadata"
TARGET2=$(sed -n 's/^window=//p' "$META2" | head -1)
PANE2=${TARGET2#*:}
[ -n "$PANE2" ] || fail "the scout spawn recorded no endpoint pane"
LAUNCH2=$(grep -m1 -E -- '--tui-mode|--approve' "$SCRATCH/args-shim-2.log" || true)
printf '%s' "$LAUNCH2" | grep -q -- '--approve' \
  || fail "the real launch arguments omitted --approve: $LAUNCH2"
note "launch arguments: $(printf '%s' "$LAUNCH2" | cut -c1-160)"
# The real model must process the brief while the dialog never renders:
# poll continuously and fail the instant the trust dialog appears.
SEEN_MARKER=0
for ((i = 0; i < 150; i++)); do
  TAIL2=$(capture "$PANE2")
  if printf '%s' "$TAIL2" | grep -qiE 'Trust project folder\?'; then
    fail "the approved launch still rendered the folder-trust dialog$(version_note)"
  fi
  if [ -f "$MARKER2" ] && [ "$(cat "$MARKER2")" = INSTRUCTION_PROCESSED ]; then
    SEEN_MARKER=1
    break
  fi
  sleep 2
done
[ "$SEEN_MARKER" = 1 ] \
  || fail "the approved launch never processed its brief within budget$(version_note); last tail:\n$(printf '%s' "$TAIL2" | tail -30)"
pass "the managed launch carries --approve, never renders the dialog, and processes its brief$(version_note)"

# --- Case 3: the approval is one-run and never touches the operator store --
[ "$(cat "$SCRATCH/agent-2/trust.json")" = '{}' ] \
  || fail "the approved launch persisted a trust decision: $(cat "$SCRATCH/agent-2/trust.json")"
OP_TRUST_MID=$(sha256sum "$OP_TRUST" | cut -d' ' -f1)
[ "$OP_TRUST_MID" = "$OP_TRUST_BEFORE" ] \
  || fail "the operator trust store changed during the launches"
pass "one-run approval left both the isolated and the operator trust stores untouched"

# --- Case 4: a saved parent decision masks the stall (why slots vary) ------
WORKTREE4=$(sed -n 's/^worktree=//p' "$META2" | head -1)
[ -n "$WORKTREE4" ] && [ -d "$WORKTREE4/.pi" ] \
  || fail "no recorded worktree with project-local resources"
PARENT4=$(dirname "$WORKTREE4")
make_shim "$SCRATCH/shim-4" "$SCRATCH/agent-4" 0
WS4_UNTRUSTED=$(lab workspace create --label fm-pi-trust-unsaved --cwd "$WORKTREE4" 2>&1) \
  || fail "could not create the untrusted child workspace: $WS4_UNTRUSTED"
PANE4_UNTRUSTED=$(printf '%s' "$WS4_UNTRUSTED" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE4_UNTRUSTED" ] || fail "workspace create did not return a root pane id"
PATH="$SCRATCH/shim-4:$PATH" lab pane run "$PANE4_UNTRUSTED" pi >/dev/null 2>&1 \
  || fail "could not launch the real pi in the untrusted child pane"
wait_for_regex "$PANE4_UNTRUSTED" 'Trust project folder\?' 45 'the same child worktree without parent trust'
lab pane close "$PANE4_UNTRUSTED" >/dev/null 2>&1 \
  || fail "could not close the untrusted child pane"
[ "$(cat "$SCRATCH/agent-4/trust.json")" = '{}' ] \
  || fail "the untrusted child launch persisted a trust decision"
jq -n --arg parent "$PARENT4" '{($parent): true}' > "$SCRATCH/agent-4/trust.json"
WS4=$(lab workspace create --label fm-pi-trust-saved --cwd "$WORKTREE4" 2>&1) \
  || fail "could not create the saved-trust workspace: $WS4"
PANE4=$(printf '%s' "$WS4" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE4" ] || fail "workspace create did not return a root pane id"
PATH="$SCRATCH/shim-4:$PATH" lab pane run "$PANE4" pi >/dev/null 2>&1 \
  || fail "could not launch the real pi in the saved-trust pane"
# With no --approve and no submitted prompt, a saved decision must carry the
# TUI past the trust gate: the dialog never renders and pi registers its
# idle state with herdr (the same lifecycle signal the stale-registration
# guard uses), proving the engine actually started instead of parking.
DIALOG4=0
for ((i = 0; i < 30; i++)); do
  if capture "$PANE4" | grep -qiE 'Trust project folder\?'; then
    DIALOG4=1
    break
  fi
  REG4=$(herdr agent get "$PANE4" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$REG4" in working|idle|done|blocked) break ;; esac
  sleep 1
done
REG4=$(herdr agent get "$PANE4" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
[ "$DIALOG4" = 0 ] || fail "a saved parent-path decision still rendered the trust dialog$(version_note)"
case "$REG4" in
  working|idle|done|blocked) ;;
  *) fail "with a saved decision pi never reached a lifecycle state (read '${REG4:-none}')$(version_note)" ;;
esac
pass "a saved parent-path trust decision skips the dialog on a bare launch (the per-slot masking)$(version_note)"
lab pane send-text "$PANE4" '/quit' >/dev/null 2>&1 || true
sleep 0.5
lab pane send-keys "$PANE4" Enter >/dev/null 2>&1 || true
lab pane close "$PANE4" >/dev/null 2>&1 || true

# --- Case 5: a pi without --approve is refused before anything is created --
make_shim "$SCRATCH/shim-5" "$SCRATCH/agent-5" 1
make_home "$SCRATCH/home-5"
write_brief "$SCRATCH/home-5" pitrust5
(
  cd "$SCRATCH" \
    && PATH="$SCRATCH/shim-5:$PATH" FM_HOME="$SCRATCH/home-5" \
      FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-spawn.sh" pitrust5 "$PROJECT" \
      --scout --harness pi --backend herdr
) > "$SCRATCH/spawn-5.out" 2>&1
RC5=$?
[ "$RC5" -ne 0 ] || fail "a pi without --approve was launched anyway$(version_note)"
grep -q -- '--approve' "$SCRATCH/spawn-5.out" \
  || fail "the refusal did not name the missing --approve capability: $(tail -3 "$SCRATCH/spawn-5.out")"
[ ! -e "$SCRATCH/home-5/state/pitrust5.meta" ] \
  || fail "the unsupported-capability refusal still recorded task metadata"
pass "a pi whose --help omits --approve is refused before endpoint or metadata exists$(version_note)"

cleanup_all
trap - EXIT
