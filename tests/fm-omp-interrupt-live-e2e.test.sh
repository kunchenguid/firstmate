#!/usr/bin/env bash
# Opt-in live guard (live-harness-optin family) for the omp watch extension's
# interrupted-run recovery (.omp/extensions/fm-primary-omp-watch.ts header).
#
# The restore that strands a Firstmate wake lives in omp's interactive input
# controller, which the RPC-mode tests/fm-omp-primary-live-e2e.test.sh never
# drives. This guard launches a real omp as a second mate in an isolated Herdr
# lab, queues a real watcher wake behind a busy tool turn, and runs two cases,
# each in its own scratch home:
#   escape  Escape with the wake queued. omp must restore the wake into the
#           composer (the stall's precondition), and the extension must then
#           clear exactly that text and deliver the wake again.
#   enter   An empty Enter with the wake queued. omp must abort and strand the
#           wake in its queue with an empty composer, and the extension's one
#           steer must then start the turn that delivers it.
# In both cases the home's durable wake queue must drain and the composer must
# read empty with no further key. The extension's settle wait is stretched so
# the precondition stays observable before the recovery acts; a precondition
# that no longer holds fails naming the omp version, because the recovery's
# assumptions about omp then need re-checking.
#
# It submits prompts, so it is opt-in: FM_OMP_INTERRUPT_LIVE_E2E=1 after an omp
# upgrade and before trusting the docs/verification/runtime-backends.md
# "2026-09-27 interrupted-run recovery" entry. FM_OMP_LIVE_MODEL overrides the
# model, FM_OMP_INTERRUPT_LIVE_CASES selects cases (default "escape enter"),
# HERDR_LAB_SESSION supplies a session bin/fm-herdr-lab.sh already named, and
# FM_OMP_INTERRUPT_LIVE_KEEP=1 keeps the lab homes for inspection.
# Every Herdr call, including adapter calls, goes through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_INTERRUPT_LIVE_E2E omp herdr jq node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
unset NO_MISTAKES_GATE FM_TASK_ID FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -n "${TARGET:-}" ]; then
    printf '# last lab pane rows (%s):\n' "$TARGET" >&2
    fm_backend_herdr_capture "$TARGET" 40 2>/dev/null | sed 's/^/#   /' >&2 || true
    printf '# durable wake queue rows: %s\n' "$(queue_rows 2>/dev/null)" >&2
  fi
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

[ -x "$LAB_HELPER" ] || fail "FM_OMP_INTERRUPT_LIVE_E2E=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

OMP_BIN=$(command -v omp)
OMP_VERSION=$("$OMP_BIN" --version 2>/dev/null | head -1)
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
SETTLE_MS=8000
ORIGINAL_PATH=$PATH
# A caller may pass a session the helper already named; otherwise name one.
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name omp-interrupt)} || fail "could not name an isolated Herdr lab session"
fm_herdr_lab_validate_name "$SESSION" || fail "refusing Herdr lab session '$SESSION'"
LAB="$ROOT/.omp-interrupt-live.$$"
FAKEBIN="$LAB/fakebin"
CHECKED=0

# Every process a case starts names its lab path on its command line.
reap_lab() {
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  reap_lab
  if [ "${FM_OMP_INTERRUPT_LIVE_KEEP:-0}" = 1 ]; then
    printf '# lab homes kept at %s\n' "$LAB" >&2
  else
    rm -rf "$LAB"
  fi
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN"
# Library calls reach Herdr only through this wrapper, which refuses any call
# not scoped to the lab session and forwards it through the helper.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the Herdr backend adapter"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

WHO="omp $OMP_VERSION ($MODEL) through Herdr"
TARGET=
HOME_ROOT=

screen() { fm_backend_herdr_capture "$TARGET" 40 2>/dev/null || true; }
busy() { screen | grep -Eq "$FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT"; }
composer() { fm_backend_composer_state herdr "$TARGET" 2>/dev/null || printf 'unknown'; }
queue_rows() { [ -s "$HOME_ROOT/state/.wake-queue" ] && wc -l < "$HOME_ROOT/state/.wake-queue" | tr -d ' ' || printf '0'; }
type_line() {
  fm_backend_herdr_send_literal "$TARGET" "$1" || fail "$WHO: could not type into the lab pane"
  sleep 0.5
  fm_backend_herdr_send_key "$TARGET" Enter || fail "$WHO: could not press Enter in the lab pane"
}
wait_until() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
watcher_live() {
  local pid
  pid=$(cat "$HOME_ROOT/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
# The model's reply renders the token alone on its row; the prompt row that
# asked for it carries other words.
reply_seen() { screen | grep -Eq "^[^[:alnum:]]*$1[[:space:]]*\$"; }
settled_idle() { ! busy && sleep 2 && ! busy; }
# omp 18.3.0 does not render queued follow-ups during a tool call, so the
# wake's close is read from the watcher's own delivery log, and the extension
# queues its follow-up right after that close.
wake_closed() { grep -q 'labtask.status' "$HOME_ROOT/state/.watch-deliveries.log" 2>/dev/null; }
queue_drained() { [ "$(queue_rows)" = 0 ]; }
composer_empty() { [ "$(composer)" = empty ]; }
# The extension's own continuation steer, as omp renders the submitted message.
steer_seen() { fm_backend_herdr_capture "$TARGET" 200 2>/dev/null | grep -q 'Firstmate supervision continues in a new turn'; }

# A second-mate home built from this checkout's tracked files at their
# working-tree content, outside any git repository.
build_home() {  # <case>
  HOME_ROOT="$LAB/$1/root"
  mkdir -p "$HOME_ROOT"
  git -C "$ROOT" ls-files -z --cached | (cd "$ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$HOME_ROOT"
  [ -f "$HOME_ROOT/.omp/extensions/fm-primary-omp-watch.ts" ] || fail "could not export the checkout into the $1 lab home"
  printf 'labmate\n' > "$HOME_ROOT/.fm-secondmate-home"
  mkdir -p "$HOME_ROOT/state" "$HOME_ROOT/config" "$HOME_ROOT/data"
}

launch_omp() {  # <case>
  local ws pane
  ws=$(lab workspace create --cwd "$HOME_ROOT" --label "fm-ompint-$1" --no-focus) \
    || fail "could not create the $1 lab workspace"
  pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail "workspace create returned no pane id"
  TARGET="$SESSION:$pane"
  # The second-mate launch line from bin/fm-spawn.sh with lab-only cadence.
  lab pane run "$pane" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_TASK_ID -u OMPCODE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE GIT_CEILING_DIRECTORIES='$LAB' FM_HOME='$HOME_ROOT' FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_OMP_INTERRUPT_SETTLE_MS=$SETTLE_MS '$OMP_BIN' --config '$HOME_ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$HOME_ROOT' --no-session --model '$MODEL' --thinking low" >/dev/null \
    || fail "could not launch $WHO in the $1 lab pane"
}

run_case() {  # <escape|enter>
  local kind=$1 key want broken composer_now screen_now
  build_home "$kind"
  launch_omp "$kind"
  wait_until 60 composer_empty || fail "$WHO: the $kind lab omp never showed an empty composer (composer=$(composer))"
  type_line 'Reply with exactly LAB-READY and nothing else. Do not run any tool.'
  wait_until 120 test -e "$HOME_ROOT/state/.lock" || fail "$WHO: the native session start never took the $kind lab lock"
  wait_until 120 reply_seen LAB-READY || fail "$WHO: the first $kind turn never replied"
  wait_until 120 settled_idle || fail "$WHO: omp never went idle after the first $kind turn"
  watcher_live || type_line '/fm-watch-arm-omp'
  wait_until 60 watcher_live || fail "$WHO: /fm-watch-arm-omp never armed a watcher in the $kind lab"
  wait_until 120 settled_idle || fail "$WHO: omp never went idle after arming in the $kind lab"
  type_line 'Use the bash tool to run exactly this command and nothing else: sleep 60 ; echo LONGTURN-SLEPT . After it returns, reply with exactly LONGTURN-DONE and nothing else.'
  wait_until 60 busy || fail "$WHO: the long $kind turn never showed omp's busy footer"
  : > "$HOME_ROOT/state/labtask.meta"
  printf 'done: lab wake\n' >> "$HOME_ROOT/state/labtask.status"
  wait_until 30 wake_closed || fail "$WHO: the watcher never closed on the $kind wake"
  sleep 5
  busy || fail "$WHO: the long $kind turn ended before the wake could queue behind it"
  [ "$(queue_rows)" -gt 0 ] || fail "$WHO: the $kind wake left no durable queue row"
  case "$kind" in
    escape) key=Escape; want=pending; broken="Escape with a queued wake no longer restores it into the composer" ;;
    enter) key=Enter; want=empty; broken="an empty Enter with a queued wake no longer strands it in omp's queue" ;;
  esac
  fm_backend_herdr_send_key "$TARGET" "$key" || fail "$WHO: could not press $key in the $kind lab"
  sleep 3
  screen_now=$(screen)
  composer_now=$(composer)
  if printf '%s' "$screen_now" | grep -Eq "$FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT"; then
    fail "$WHO: $key during a busy tool turn with a queued wake no longer ends the run; re-check the extension's interrupted-run recovery"
  fi
  if [ "$composer_now" != "$want" ] || ! printf '%s' "$screen_now" | grep -q 'FIRSTMATE WATCHER WAKE'; then
    fail "$WHO: $broken (composer=$composer_now); re-check the extension's interrupted-run recovery"
  fi
  note "$kind precondition held: composer=$composer_now, $(queue_rows) durable rows"
  CHECKED=$((CHECKED + 1))
  if [ "$kind" = enter ]; then
    wait_until 60 steer_seen || fail "$WHO: after the empty-Enter strand the extension's continuation steer never reached omp's transcript"
  fi
  wait_until 300 queue_drained || fail "$WHO: after $key the durable wake queue never drained with no further key ($(queue_rows) rows left)"
  wait_until 180 settled_idle || fail "$WHO: omp never went idle after the $kind recovery"
  wait_until 30 composer_empty || fail "$WHO: after the $kind recovery the composer reads $(composer), not empty"
  type_line '/quit'
  pass "live omp interrupt recovery ($kind): $WHO drained the wake with no further key and left an empty composer in isolated session $SESSION"
}

cases=${FM_OMP_INTERRUPT_LIVE_CASES:-escape enter}
for kind in $cases; do
  case "$kind" in
    escape|enter) run_case "$kind" ;;
    *) fail "unknown FM_OMP_INTERRUPT_LIVE_CASES entry '$kind' (expected escape or enter)" ;;
  esac
done
[ "$CHECKED" -gt 0 ] || fail "FM_OMP_INTERRUPT_LIVE_E2E=1 checked no case"
