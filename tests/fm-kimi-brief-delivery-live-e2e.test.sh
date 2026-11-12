#!/usr/bin/env bash
# tests/fm-kimi-brief-delivery-live-e2e.test.sh - opt-in guard proving the
# INSTALLED Kimi Code CLI still needs a pause before Enter, and that one Enter
# after that pause submits the brief pointer.
#
# Why this file exists: Kimi 2.4.0 treats Enter within 120ms of a fast paste as
# a newline, so the pointer stays in the composer until a later Enter. A stub
# can only replay that assumption. This guard types the same pointer spawn
# sends, on a private tmux server, with a disposable HOME and KIMI_CODE_HOME
# and the updater off. The real trust store and install are untouched. No
# login is present, so the submit stops at Kimi's local "LLM not set" error
# and spends no model tokens. It stays opt-in because it does submit a prompt.
# Run it after every Kimi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIMI_BRIEF_DELIVERY_LIVE tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KIMI_BIN=$(command -v kimi 2>/dev/null || true)
if [ -z "$KIMI_BIN" ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
  KIMI_BIN=$HOME/.kimi-code/bin/kimi
fi
if [ -z "$KIMI_BIN" ]; then
  if [ "${FM_KIMI_BRIEF_DELIVERY_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    printf 'not ok - FM_KIMI_BRIEF_DELIVERY_LIVE was requested but kimi is not installed\n' >&2
    exit 1
  fi
  printf 'skip: live: kimi absent\n'
  exit 0
fi
VERSION=$("$KIMI_BIN" --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$VERSION" ] || VERSION=unknown
WHO="kimi $VERSION"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-kimi-delivery-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-delivery.XXXXXX")
POINTER='Read the brief at /tmp/fm-kimi-delivery-brief.md and follow it exactly.'
PANE=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

if git -C "$LAB" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "$WHO: the lab $LAB is inside a git checkout; set TMPDIR outside any checkout"
fi

mkdir -p "$LAB/shim" "$LAB/burst" "$LAB/settle"
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

launch_kimi() {
  local session=$1 dir=$2 home
  home=$LAB/home-$session
  mkdir -p "$home"
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$session" -x 100 -y 32 -c "$dir" \
    -- env -u KIMI_CODE_TRUST_WORKSPACE HOME="$home" KIMI_CODE_HOME="$home/.kimi-code" \
    KIMI_CODE_NO_AUTO_UPDATE=1 "$KIMI_BIN" --auto \
    || fail "$WHO: could not launch a private tmux session for $session"
}

capture() { # <target>
  fm_backend_visible_capture tmux "$1" 2>/dev/null || true
}

# A content row of the bordered composer is the only place the unsent pointer
# appears. The submitted user line has no box border.
pane_holds_pointer() {
  printf '%s\n' "$1" | grep -F '│' | grep -Fq 'Read the brief at'
}

submission_is_visible() {
  printf '%s\n' "$1" | grep -Fq 'LLM not set' && return 0
  printf '%s\n' "$1" | grep -Fq '❯ Read the brief at' && return 0
  return 1
}

wait_until_ready() { # <target>
  local target=$1
  local _i
  for _i in $(seq 1 300); do
    PANE=$(capture "$target")
    if kimi_pane_announces_project_mcp_servers "$PANE"; then
      fail "$WHO: $target: the folder prompt announces project MCP servers, so this guard will not answer it; visible pane:
$PANE"
    fi
    if kimi_trust_prompt_is_paged "$PANE"; then
      fail "$WHO: $target: the folder prompt pages its disclosure, so this guard will not answer it; visible pane:
$PANE"
    fi
    if kimi_trust_dialog_is_visible "$PANE"; then
      fm_backend_send_key tmux "$target" Enter \
        || fail "$WHO: $target: the trust Enter could not be sent"
      sleep 0.2
      continue
    fi
    if printf '%s\n' "$PANE" | grep -Fq 'Welcome to Kimi Code!' \
      && ! kimi_trust_marker_is_present "$PANE"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

type_pointer() { # <target>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$1" -l "$POINTER" \
    || fail "$WHO: $1: the brief pointer could not be typed"
}

# --- immediate Enter is a newline, not a submit -----------------------------
launch_kimi burst "$LAB/burst"
wait_until_ready burst \
  || fail "$WHO: burst: no ready pane within 60s; visible pane:
$PANE"
type_pointer burst
"$REAL_TMUX" -L "$SOCKET" send-keys -t burst Enter \
  || fail "$WHO: burst: Enter could not be sent"
held=0
for _ in $(seq 1 25); do
  PANE=$(capture burst)
  if pane_holds_pointer "$PANE"; then
    held=1
    break
  fi
  if submission_is_visible "$PANE"; then
    fail "$WHO: burst: an immediate Enter submitted the pointer; visible pane:
$PANE"
  fi
  sleep 0.2
done
[ "$held" -eq 1 ] || fail "$WHO: burst: the pointer never appeared in the composer after an immediate Enter; visible pane:
$PANE"
sleep 1
PANE=$(capture burst)
if ! pane_holds_pointer "$PANE" || submission_is_visible "$PANE"; then
  fail "$WHO: burst: the pointer did not stay typed after an immediate Enter; visible pane:
$PANE"
fi
pass "$WHO: an immediate Enter leaves the brief pointer typed in the composer"

# --- one Enter after the paste window submits -------------------------------
launch_kimi settle "$LAB/settle"
wait_until_ready settle \
  || fail "$WHO: settle: no ready pane within 60s; visible pane:
$PANE"
type_pointer settle
seen=0
for _ in $(seq 1 25); do
  PANE=$(capture settle)
  if pane_holds_pointer "$PANE"; then
    seen=1
    break
  fi
  sleep 0.2
done
[ "$seen" -eq 1 ] || fail "$WHO: settle: the pointer never appeared in the composer; visible pane:
$PANE"
# The burst window starts when Kimi paints the paste. Waiting here, after that
# paint, is the same 0.25s pause spawn uses before its one Enter.
sleep 0.25
"$REAL_TMUX" -L "$SOCKET" send-keys -t settle Enter \
  || fail "$WHO: settle: Enter could not be sent"
submitted=0
for _ in $(seq 1 75); do
  PANE=$(capture settle)
  if ! pane_holds_pointer "$PANE" && submission_is_visible "$PANE"; then
    submitted=1
    break
  fi
  sleep 0.2
done
[ "$submitted" -eq 1 ] || fail "$WHO: settle: one Enter after 0.25s did not submit the pointer; visible pane:
$PANE"
note "$WHO: one Enter after 0.25s cleared the composer; $(printf '%s\n' "$PANE" | grep -E 'LLM not set|❯ Read the brief at|context:' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | head -5 | tr '\n' ';')"
pass "$WHO: one Enter after the paste-burst window submits the brief pointer"
