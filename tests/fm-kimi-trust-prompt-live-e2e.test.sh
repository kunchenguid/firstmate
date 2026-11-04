#!/usr/bin/env bash
# tests/fm-kimi-trust-prompt-live-e2e.test.sh - default-on guard proving the
# INSTALLED Kimi Code CLI's folder prompt is still read the way
# bin/fm-spawn.sh answers it, through the predicates in
# bin/fm-kimi-trust-lib.sh:
#   - a directory with no project MCP servers shows a prompt the
#     complete-dialog test recognizes, and Enter clears it into a ready pane;
#   - a directory declaring project MCP servers in a root .mcp.json, and one
#     declaring them in .kimi-code/mcp.json, each show a prompt the
#     announcement test refuses, and the declared command never runs;
#   - a pane too short to confirm shows a prompt no test accepts, and a pane
#     that pages the disclosure is reported paged while looking complete.
#
# Why this file exists: the prompt is vendor-rendered text. Kimi Code CLI
# 2.3.0 reworded every line of it and began reading a root .mcp.json as a
# project declaration, and only a real release shows that. The portable
# regression in tests/fm-kimi-harness.test.sh replays captures recorded from
# that release (tests/captures/kimi-code-2.3.0/README.md); this guard asks the
# installed binary and fails naming it and its version.
#
# Kimi is launched bare in a private tmux server with a disposable HOME and
# KIMI_CODE_HOME and its updater off, so the real trust store, configuration,
# and install are untouched. The prompt shows before any login, no prompt text
# is ever submitted, and the only keys sent are Enter on the plain prompt and
# Escape to leave the others, so this spends no model tokens and needs no
# credentials. Run it after every Kimi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_KIMI_TRUST_PROMPT_LIVE tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Mirror bin/fm-spawn.sh's own resolution order so the guard covers the binary
# firstmate would launch: PATH first, then the installer's default location.
KIMI_BIN=$(command -v kimi 2>/dev/null || true)
if [ -z "$KIMI_BIN" ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
  KIMI_BIN=$HOME/.kimi-code/bin/kimi
fi
if [ -z "$KIMI_BIN" ]; then
  if [ "${FM_KIMI_TRUST_PROMPT_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    printf 'not ok - FM_KIMI_TRUST_PROMPT_LIVE was requested but kimi is not installed\n' >&2
    exit 1
  fi
  printf 'skip: live: kimi absent\n'
  exit 0
fi
VERSION=$("$KIMI_BIN" --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$VERSION" ] || VERSION=unknown
WHO="kimi $VERSION"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-kimi-trust-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-trust.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

# Kimi resolves a root .mcp.json at the git worktree root when the launch
# directory sits inside a checkout, so the lab must not.
if git -C "$LAB" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "$WHO: the lab $LAB is inside a git checkout, so a root .mcp.json would not be read there; set TMPDIR outside any checkout"
fi

mkdir -p "$LAB/shim" "$LAB/plain" "$LAB/root-mcp-json" "$LAB/kimi-code-mcp-json/.kimi-code"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-kimi-trust-lib.sh"

MARKER_LOG=$LAB/marker.log
: > "$MARKER_LOG"
cat > "$LAB/marker.sh" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> '$MARKER_LOG'
sleep 2
SH
chmod +x "$LAB/marker.sh"
printf '{"mcpServers":{"guard-marker":{"command":"%s","args":["--from-root-mcp-json"]}}}\n' "$LAB/marker.sh" \
  > "$LAB/root-mcp-json/.mcp.json"
printf '{"mcpServers":{"guard-marker":{"command":"%s","args":["--from-kimi-code-mcp-json"]}}}\n' "$LAB/marker.sh" \
  > "$LAB/kimi-code-mcp-json/.kimi-code/mcp.json"

# launch_kimi <session> <dir> <cols> <rows>: a fresh disposable home per launch,
# so no trust answer carries over, and no ambient per-process trust switch.
launch_kimi() {
  local session=$1 dir=$2 cols=$3 rows=$4 home
  home=$LAB/home-$session
  mkdir -p "$home"
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$session" -x "$cols" -y "$rows" -c "$dir" \
    -- env -u KIMI_CODE_TRUST_WORKSPACE HOME="$home" KIMI_CODE_HOME="$home/.kimi-code" \
    KIMI_CODE_NO_AUTO_UPDATE=1 "$KIMI_BIN" --auto \
    || fail "$WHO: could not launch a private tmux session for $session"
}

PANE=
# wait_for_prompt <target>: poll the visible viewport until prompt text is on
# it, then take one more capture so a half-painted frame is not judged.
wait_for_prompt() {
  local target=$1
  for _ in $(seq 1 300); do
    PANE=$(fm_backend_visible_capture tmux "$target" 2>/dev/null || true)
    if kimi_trust_marker_is_present "$PANE"; then
      sleep 1
      PANE=$(fm_backend_visible_capture tmux "$target" 2>/dev/null || true)
      return 0
    fi
    sleep 0.2
  done
  return 1
}

assert_marker_log_empty() { # <context>
  [ ! -s "$MARKER_LOG" ] || fail "$WHO: $1: the declared project MCP command ran: $(cat "$MARKER_LOG")"
}

# --- plain directory: recognized, answered, cleared --------------------------
launch_kimi plain "$LAB/plain" 120 40
wait_for_prompt plain || fail "$WHO: plain directory: no folder prompt text appeared within 60s"
kimi_trust_dialog_is_visible "$PANE" \
  || fail "$WHO: plain directory: the folder prompt is not recognized as the complete dialog; visible pane:
$PANE"
note "$WHO: plain prompt options read '$KIMI_TRUST_AFFIRMATIVE' / '$KIMI_TRUST_NEGATIVE'"
if kimi_pane_announces_project_mcp_servers "$PANE"; then
  fail "$WHO: plain directory: the prompt reads as announcing project MCP servers; visible pane:
$PANE"
fi
if kimi_trust_prompt_is_paged "$PANE"; then
  fail "$WHO: plain directory: the prompt reads as paged in a 120x40 pane; visible pane:
$PANE"
fi
fm_backend_send_key tmux plain Enter || fail "$WHO: plain directory: Enter could not be sent"
cleared=0
for _ in $(seq 1 300); do
  PANE=$(fm_backend_visible_capture tmux plain 2>/dev/null || true)
  if [ -n "$PANE" ] && ! kimi_trust_marker_is_present "$PANE" \
    && [ "$(fm_backend_composer_state tmux plain 2>/dev/null)" = empty ]; then
    cleared=1
    break
  fi
  sleep 0.2
done
[ "$cleared" -eq 1 ] || fail "$WHO: plain directory: the prompt did not clear into an empty composer within 60s after Enter; visible pane:
$PANE"
pass "$WHO: a plain directory's folder prompt is the complete dialog, and Enter clears it into a ready pane"

# --- declaring directories: recognized, announced, never answered ------------
for case_name in root-mcp-json kimi-code-mcp-json; do
  launch_kimi "$case_name" "$LAB/$case_name" 120 40
  wait_for_prompt "$case_name" || fail "$WHO: $case_name: no folder prompt text appeared within 60s"
  kimi_trust_dialog_is_visible "$PANE" \
    || fail "$WHO: $case_name: the prompt is not the complete dialog, so this guard cannot show the announcement is what keeps Enter off it; visible pane:
$PANE"
  kimi_pane_announces_project_mcp_servers "$PANE" \
    || fail "$WHO: $case_name: the prompt does not announce the declared project MCP server; visible pane:
$PANE"
  note "$WHO: $case_name prompt announces: $(printf '%s\n' "$PANE" | grep -E 'MCP server|Config:' | sed 's/^[[:space:]]*//' | tr '\n' ';')"
  fm_backend_send_key tmux "$case_name" Escape || fail "$WHO: $case_name: Escape could not be sent"
  sleep 2
  assert_marker_log_empty "$case_name"
  pass "$WHO: a $case_name declaration is announced on the folder prompt, which receives no answer, and its command never ran"
done

# --- short panes: collapsed, then paged ------------------------------------
launch_kimi short "$LAB/root-mcp-json" 100 7
wait_for_prompt short || fail "$WHO: 100x7 pane: no folder prompt text appeared within 60s"
if kimi_trust_dialog_is_visible "$PANE"; then
  fail "$WHO: 100x7 pane: a prompt Kimi collapsed for a short terminal reads as the complete dialog; visible pane:
$PANE"
fi
note "$WHO: 100x7 pane shows: $(printf '%s\n' "$PANE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//' | tr '\n' ';')"
"$REAL_TMUX" -L "$SOCKET" resize-window -t short -x 100 -y 12 \
  || fail "$WHO: could not resize the short pane"
paged=0
for _ in $(seq 1 100); do
  PANE=$(fm_backend_visible_capture tmux short 2>/dev/null || true)
  if kimi_trust_prompt_is_paged "$PANE"; then
    paged=1
    break
  fi
  sleep 0.2
done
[ "$paged" -eq 1 ] || fail "$WHO: 100x12 pane: the prompt did not page its disclosure within 20s; visible pane:
$PANE"
kimi_trust_dialog_is_visible "$PANE" \
  || fail "$WHO: 100x12 pane: the paged prompt is not the complete dialog, so this guard cannot show the page marker is what keeps Enter off it; visible pane:
$PANE"
if kimi_pane_announces_project_mcp_servers "$PANE"; then
  note "$WHO: 100x12 pane: the announcement is on the shown page"
else
  note "$WHO: 100x12 pane: the announcement is on a hidden page, so only the page marker refuses this prompt"
fi
fm_backend_send_key tmux short Escape || fail "$WHO: short pane: Escape could not be sent"
sleep 2
assert_marker_log_empty "short panes"
pass "$WHO: a short pane collapses the prompt below the complete dialog, and a slightly taller one pages it with the page marker on screen"

pass "$WHO: folder-prompt predicates agree with the installed Kimi on every recorded wording"
