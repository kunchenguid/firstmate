#!/usr/bin/env bash
# Live drift guard for Kimi Code's folder-trust pre-registration
# (bin/fm-kimi-trust.sh), against the INSTALLED kimi and a real tmux server.
#
# Two arms, because each proves a different half of the claim:
#   - control: a fresh linked worktree that nothing registered parks on the
#     folder-trust dialog. This is what makes the registration necessary; a
#     kimi that stopped gating fresh folders would fail here, naming the
#     version, so the helper is never kept on a stale premise.
#   - treatment: a sibling worktree registered through the helper launches
#     straight to a ready composer with no dialog text on the pane, accepts a
#     brief pointer delivered the way bin/fm-spawn.sh delivers one, and runs
#     the brief. A dialog on this pane means Kimi no longer honours the record
#     the helper writes, and the guard fails naming the record and the version.
# Opt-in because the treatment arm submits a real prompt.
#
# The records land in the operator's REAL Kimi store. Kimi's credentials live
# in the same home and this guard must not read, copy, or relocate them, so a
# throwaway KIMI_CODE_HOME would only ever reach a login prompt. Only
# workspace-trust/ is touched: the guard refuses to start when a record for
# either lab worktree already exists, removes only the record it created, and
# verifies it is gone. Kimi's own session artifacts for the treatment run are
# left where Kimi puts them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMI_BIN=$(command -v kimi 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-kimi-trust-$$"
SESSION=kimi-trust
CONTROL_TARGET="$SESSION:control"
TREATMENT_TARGET="$SESSION:treatment"
CREATED_RECORD=

if command -v sha256sum >/dev/null 2>&1; then SHA256=sha256sum; else SHA256="shasum -a 256"; fi
sha12() { printf '%s' "$1" | $SHA256 | cut -c1-12; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # Only the record this guard created, and only while it still names the lab:
  # anything else in the store is the operator's own trust.
  if [ -n "$CREATED_RECORD" ] && [ -f "$CREATED_RECORD" ] && [ -n "$LAB" ] \
     && grep -Fq "\"root\":\"$LAB/" "$CREATED_RECORD"; then
    rm -f -- "$CREATED_RECORD"
  fi
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_KIMI_TRUST_LIVE kimi tmux
[ -n "$KIMI_BIN" ] || fail "kimi is not installed"
command -v node >/dev/null 2>&1 || fail "node is required by bin/fm-kimi-trust.sh and is not installed"
KIMI_VERSION=$("$KIMI_BIN" --version 2>/dev/null | head -1)
[ -n "$KIMI_VERSION" ] || fail "kimi --version printed nothing"

case ${KIMI_CODE_HOME:-} in
  '') KIMI_HOME="$HOME/.kimi-code" ;;
  /*) KIMI_HOME=$KIMI_CODE_HOME ;;
  *) fail "KIMI_CODE_HOME '$KIMI_CODE_HOME' is relative; the helper refuses it and so does this guard" ;;
esac
STORE="$KIMI_HOME/workspace-trust"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-trust.XXXXXX") || fail "could not create the isolated lab"
LAB=$(cd -P -- "$LAB" && pwd -P) || fail "could not resolve the isolated lab"
trap cleanup EXIT
PROJ="$LAB/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q || fail "could not initialize the lab project"
git -C "$PROJ" -c user.name=guard -c user.email=guard@local commit -q --allow-empty -m init \
  || fail "could not seed the lab project"
git -C "$PROJ" worktree add -q -b control "$LAB/control" || fail "could not add the control worktree"
git -C "$PROJ" worktree add -q -b treatment "$LAB/treatment" || fail "could not add the treatment worktree"
PROJ_REAL=$(cd "$PROJ" && pwd -P) || fail "could not resolve the lab project"
CONTROL=$(cd "$LAB/control" && pwd -P) || fail "could not resolve the control worktree"
TREATMENT=$(cd "$LAB/treatment" && pwd -P) || fail "could not resolve the treatment worktree"
CONTROL_RECORD="$STORE/wd_control_$(sha12 "$CONTROL")"
TREATMENT_RECORD="$STORE/wd_treatment_$(sha12 "$TREATMENT")"
for record in "$CONTROL_RECORD" "$TREATMENT_RECORD"; do
  [ ! -e "$record" ] || fail "refusing to run: a trust record already exists at $record"
done

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$CONTROL" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n treatment -c "$TREATMENT" \
  || fail "could not open the treatment window"

# The visible viewport only, the read bin/fm-spawn.sh makes for every trust
# decision: the dialog is a TUI frame that scrollback keeps reporting.
capture() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" -S -0 2>/dev/null || true
}

dialog_visible() {  # <screen>
  case "$1" in *"Trust this folder"*|*"Don't trust"*) return 0 ;; esac
  return 1
}

ready_visible() {  # <screen>
  case "$1" in *"Welcome to Kimi Code!"*) return 0 ;; esac
  printf '%s\n' "$1" | grep -Eq '│ >[[:space:]]*│'
}

# The same launch line bin/fm-spawn.sh types for a kimi crewmate, minus the
# model flag, so the arm exercises the shape the fleet actually launches.
launch() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$1" -l \
    "export COMPACT_ADVISER_DISABLE=1; env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI '$KIMI_BIN' --auto" \
    || fail "could not type the kimi launch line into $1"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$1" Enter || fail "could not submit the kimi launch line in $1"
}

pane_command() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null || true
}

wait_for_exit() {  # <target> <what>
  for _ in $(seq 1 120); do
    case "$(pane_command "$1")" in *kimi*) sleep 0.5 ;; *) return 0 ;; esac
  done
  fail "$2 never stopped the kimi process in $1"
}

# --- control arm ------------------------------------------------------------
launch "$CONTROL_TARGET"
screen=
verdict=
ready_count=0
for _ in $(seq 1 180); do
  screen=$(capture "$CONTROL_TARGET")
  if dialog_visible "$screen"; then
    verdict=dialog
    break
  fi
  if ready_visible "$screen"; then
    ready_count=$((ready_count + 1))
    if [ "$ready_count" -ge 2 ]; then
      verdict=ready
      break
    fi
  else
    ready_count=0
  fi
  sleep 0.5
done
case "$verdict" in
  dialog)
    pass "control arm: kimi $KIMI_VERSION parks an unregistered fresh worktree on the folder-trust dialog"
    ;;
  ready)
    fail "kimi $KIMI_VERSION reached a ready composer in the unregistered worktree $CONTROL with no folder-trust dialog; re-verify whether pre-registration is still required and where the store now lives"
    ;;
  *)
    fail "kimi $KIMI_VERSION showed neither the folder-trust dialog nor a ready composer in $CONTROL within 90s; last screen: $(printf '%s' "$screen" | tail -8 | tr '\n' '|')"
    ;;
esac
# Escape is "Don't trust", which exits without writing a record - the same
# single Escape bin/fm-control.sh sends as a kimi interrupt, and the key that
# revealed the dialog under three failed spawns.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$CONTROL_TARGET" Escape \
  || fail "could not send Escape to the control dialog"
wait_for_exit "$CONTROL_TARGET" "Escape on the folder-trust dialog"
[ ! -e "$CONTROL_RECORD" ] || fail "declining the dialog wrote a trust record at $CONTROL_RECORD"
pass "control arm: declining the dialog exits kimi and records nothing"

# --- treatment arm ----------------------------------------------------------
out=$("$ROOT/bin/fm-kimi-trust.sh" "$TREATMENT" "$PROJ_REAL" 2>&1) \
  || fail "bin/fm-kimi-trust.sh refused a fresh linked worktree: $out"
[ "$out" = "trusted: $TREATMENT" ] || fail "the helper did not report the one trusted line: $out"
[ -f "$TREATMENT_RECORD" ] || fail "the helper reported trust but wrote no record at $TREATMENT_RECORD"
CREATED_RECORD=$TREATMENT_RECORD
[ "$(file_mode "$TREATMENT_RECORD")" = 600 ] || fail "the record is mode $(file_mode "$TREATMENT_RECORD"), not 600"
pass "treatment arm: the helper registered $TREATMENT_RECORD"

launch "$TREATMENT_TARGET"
screen=
verdict=
ready_count=0
for _ in $(seq 1 180); do
  screen=$(capture "$TREATMENT_TARGET")
  if dialog_visible "$screen"; then
    verdict=dialog
    break
  fi
  if ready_visible "$screen"; then
    ready_count=$((ready_count + 1))
    if [ "$ready_count" -ge 2 ]; then
      verdict=ready
      break
    fi
  else
    ready_count=0
  fi
  sleep 0.5
done
case "$verdict" in
  ready)
    pass "treatment arm: kimi $KIMI_VERSION launched the pre-registered worktree straight to a ready composer"
    ;;
  dialog)
    fail "kimi $KIMI_VERSION showed the folder-trust dialog in the pre-registered worktree $TREATMENT although $TREATMENT_RECORD exists; the store format bin/fm-kimi-trust.sh writes no longer matches this kimi"
    ;;
  *)
    fail "kimi $KIMI_VERSION never reached a ready composer in the pre-registered worktree $TREATMENT within 90s; last screen: $(printf '%s' "$screen" | tail -8 | tr '\n' '|')"
    ;;
esac

# The brief lives outside the worktree and is reached by absolute path, the
# way every kimi crewmate's is. It asks for a computed answer so the awaited
# token never appears in the echoed pointer itself.
BRIEF="$LAB/brief.md"
printf '%s\n' 'Reply with exactly the sum of 12345 and 67890 written as plain digits, and nothing else. Do not run any tools.' > "$BRIEF"
POINTER="Read the brief at $BRIEF and follow it exactly."
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TREATMENT_TARGET" -l "$POINTER" \
  || fail "could not type the brief pointer"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TREATMENT_TARGET" Enter \
  || fail "could not submit the brief pointer"
# Kimi swallows keypresses during its startup window, so the spawn retries
# Enter while the composer still holds the pointer; the guard does the same,
# bounded, and accepts delivery on the echoed submission the spawn accepts.
delivered=
resends=0
for _ in $(seq 1 60); do
  screen=$(capture "$TREATMENT_TARGET")
  case "$screen" in
    *'✨'*'Read the brief at'*) delivered=1; break ;;
  esac
  if [ "$resends" -lt 3 ] && printf '%s\n' "$screen" | grep -Fq '│ > Read the brief at'; then
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TREATMENT_TARGET" Enter || fail "could not re-submit the brief pointer"
    resends=$((resends + 1))
  fi
  sleep 0.5
done
[ -n "$delivered" ] || fail "kimi $KIMI_VERSION never echoed the submitted brief pointer in the pre-registered worktree; last screen: $(printf '%s' "$screen" | tail -8 | tr '\n' '|')"
pass "treatment arm: the brief pointer was delivered (after $resends re-submitted Enter)"

answered=
for _ in $(seq 1 480); do
  screen=$(capture "$TREATMENT_TARGET")
  case "$screen" in *80235*|*80,235*) answered=1; break ;; esac
  sleep 0.5
done
[ -n "$answered" ] || fail "kimi $KIMI_VERSION never answered the brief within 240s; last screen: $(printf '%s' "$screen" | tail -8 | tr '\n' '|')"
pass "treatment arm: kimi $KIMI_VERSION reached its brief and ran it in the pre-registered worktree with no key pressed on its behalf"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TREATMENT_TARGET" -l "/exit" || fail "could not type the exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TREATMENT_TARGET" Enter || fail "could not submit the exit command"
wait_for_exit "$TREATMENT_TARGET" "/exit"
pass "treatment arm: /exit stopped the kimi process"

[ -f "$TREATMENT_RECORD" ] || fail "the record at $TREATMENT_RECORD did not survive the kimi session"
cleanup
[ ! -e "$TREATMENT_RECORD" ] || fail "the record at $TREATMENT_RECORD was not removed from the operator's store"
pass "cleanup: the lab record was removed from $STORE and verified absent"
trap - EXIT
