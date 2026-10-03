#!/usr/bin/env bash
# Live guard for Pi's session-scoped project-trust approval in seeded homes.
#
# Reproduces the Pi "Trust project folder?" stall on a freshly seeded
# secondmate-shaped home (tracked .pi/extensions + .fm-secondmate-home) under a
# disposable PI_CODING_AGENT_DIR, then proves the runtime --approve flag
# clears that stall without rewriting the disposable trust store. An unseeded
# path without --approve still prompts.
#
# Token-free: never submits a prompt and never answers the dialog with Enter.
# Uses Escape / kill-server only. Never touches ~/.pi.
#
# Policy: default-on wherever pi and tmux are installed (fm_live_gate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-pi-seeded-trust-$$"
LAB=
CHECKED=0

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "${LAB:-}" ] || rm -rf -- "$LAB"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

fm_live_gate default-on FM_PI_SEEDED_HOME_TRUST_LIVE pi tmux

PI_BIN=$(command -v pi) || fail "pi missing after live gate"
VERSION_OUT=$("$PI_BIN" --version 2>&1) || fail "pi --version failed: $VERSION_OUT"
note "live pi version: $VERSION_OUT"

if ! "$PI_BIN" --help 2>&1 | grep -Eq -- '(^|[[:space:]])--approve([^[:alnum:]_-]|$)'; then
  note "installed pi does not advertise --approve; this runtime guard cannot exercise the flag"
  echo "# fm-pi-seeded-home-trust-live-e2e: skipped (no --approve on installed pi)"
  exit 0
fi

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-seeded-trust.XXXXXX") || fail "could not create disposable lab"
PI_DIR="$LAB/pi-agent"
mkdir -p "$PI_DIR"
printf '{}\n' > "$PI_DIR/trust.json"
TRUST_BEFORE=$(cat "$PI_DIR/trust.json")

seed_home() {  # <dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/.pi/extensions" "$dir/data" "$dir/state" "$dir/config"
  printf '%s\n' "$id" > "$dir/.fm-secondmate-home"
  printf 'export default function () {}\n' > "$dir/.pi/extensions/fm-primary-turnend-guard.ts"
  printf 'export default function () {}\n' > "$dir/.pi/extensions/fm-primary-pi-watch.ts"
  printf '# test charter\n' > "$dir/data/charter.md"
}

capture_until() {  # <session> <regex> <seconds> <out-file>
  local session=$1 expect=$2 seconds=$3 out=$4
  local target="$session:w" tail='' i limit
  limit=$((seconds * 5))
  for ((i = 0; i < limit; i++)); do
    tail=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -80 2>/dev/null) || true
    if printf '%s' "$tail" | grep -qiE "$expect"; then
      printf '%s' "$tail" > "$out"
      return 0
    fi
    sleep 0.2
  done
  printf '%s' "$tail" > "$out"
  return 1
}

# --- 1. Fresh seeded home WITHOUT --approve stalls on the trust dialog ------
SEED="$LAB/seeded-stall"
seed_home "$SEED" lab-sm-stall
"$REAL_TMUX" -L "$SOCKET" new-session -d -s stall -n w -c "$SEED" -- \
  env HOME="$LAB/home-stall" PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 \
  "$PI_BIN" --no-session --no-skills --no-prompt-templates \
  || fail "could not launch pi without --approve"
if ! capture_until stall 'Trust project folder' 15 "$LAB/pane-stall.txt"; then
  fail "seeded home without --approve never showed Trust project folder? within 15s:
$(cat "$LAB/pane-stall.txt")"
fi
"$REAL_TMUX" -L "$SOCKET" send-keys -t stall:w Escape >/dev/null 2>&1 || true
"$REAL_TMUX" -L "$SOCKET" kill-session -t stall >/dev/null 2>&1 || true
CHECKED=$((CHECKED + 1))
pass "fresh seeded Pi secondmate-shaped home stalls on Trust project folder? without --approve"

# --- 2. Same shape WITH --approve starts past the dialog; trust.json intact -
SEED2="$LAB/seeded-approve"
seed_home "$SEED2" lab-sm-approve
printf '{}\n' > "$PI_DIR/trust.json"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s approve -n w -c "$SEED2" -- \
  env HOME="$LAB/home-approve" PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 \
  "$PI_BIN" --approve --no-session --no-skills --no-prompt-templates \
  || fail "could not launch pi with --approve"
if ! capture_until approve 'fm-primary-turnend-guard|fm-primary-pi-watch|No models available|escape interrupt' 15 \
  "$LAB/pane-approve.txt"; then
  fail "seeded home with --approve never reached a post-trust TUI within 15s:
$(cat "$LAB/pane-approve.txt")"
fi
if printf '%s' "$(cat "$LAB/pane-approve.txt")" | grep -qiE 'Trust project folder'; then
  fail "seeded home with --approve still showed Trust project folder?:
$(cat "$LAB/pane-approve.txt")"
fi
"$REAL_TMUX" -L "$SOCKET" send-keys -t approve:w Escape >/dev/null 2>&1 || true
"$REAL_TMUX" -L "$SOCKET" kill-session -t approve >/dev/null 2>&1 || true
TRUST_AFTER=$(cat "$PI_DIR/trust.json")
[ "$TRUST_AFTER" = "$TRUST_BEFORE" ] || [ "$TRUST_AFTER" = '{}' ] \
  || fail " --approve rewrote the disposable trust store: before=$TRUST_BEFORE after=$TRUST_AFTER"
CHECKED=$((CHECKED + 1))
pass "seeded home with --approve starts past the trust dialog without rewriting trust.json"

# --- 3. Unseeded path without --approve still prompts -----------------------
UNSEEDED="$LAB/unseeded"
mkdir -p "$UNSEEDED/.pi/extensions"
printf 'export default function () {}\n' > "$UNSEEDED/.pi/extensions/dummy.ts"
printf '{}\n' > "$PI_DIR/trust.json"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s unseeded -n w -c "$UNSEEDED" -- \
  env HOME="$LAB/home-unseeded" PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 \
  "$PI_BIN" --no-session --no-skills --no-prompt-templates \
  || fail "could not launch pi on an unseeded path"
if ! capture_until unseeded 'Trust project folder' 15 "$LAB/pane-unseeded.txt"; then
  fail "unseeded path without --approve never showed Trust project folder? within 15s:
$(cat "$LAB/pane-unseeded.txt")"
fi
"$REAL_TMUX" -L "$SOCKET" send-keys -t unseeded:w Escape >/dev/null 2>&1 || true
"$REAL_TMUX" -L "$SOCKET" kill-session -t unseeded >/dev/null 2>&1 || true
CHECKED=$((CHECKED + 1))
pass "unseeded path without --approve still prompts on Trust project folder?"

[ "$CHECKED" -ge 3 ] || fail "guard checked nothing useful (checked=$CHECKED)"
echo "# all fm-pi-seeded-home-trust-live-e2e checks passed ($CHECKED)"
