#!/usr/bin/env bash
# fm-totmann.sh - quota-free dead-man revival for the firstmate session (plan v3 U1.7).
#
# Usage:
#   fm-totmann.sh check      probe, and revive when the session is dead (timer entry point)
#   fm-totmann.sh status     report the verdict without acting; exit 0 alive, 1 dead
#   fm-totmann.sh --help
#
# Verdict, from structural evidence only - no vendor command names (L11/L28):
#   1. $FM_HOME/state/.lock carries the session lock holder's pid (owner:
#      bin/fm-lock.sh). A live lock pid means the session is alive, wherever
#      its window lives.
#   2. Otherwise the tmux pane $FM_TOTMANN_TARGET (default firstmate:0) is
#      alive when its pane_pid either has a live child process or is itself no
#      shell: a dead session leaves a bare shell with no children.
#      pane_current_command is deliberately not read - version-named harness
#      binaries broke that check and produced duplicate sessions (W3).
#   3. Neither holds -> dead: after the debounce the revival types the relaunch
#      command into the target window, creating session and window when
#      missing, and notifies the captain best-effort via the notifier. The
#      command is DERIVED, not literal: the account ledger config/konten.tsv
#      names the storage holding role `firstmate`, and its wrapper plus
#      `--continue` is what gets typed (owner: bin/fm-totmann-relaunch-lib.sh
#      via bin/fm-konten-lib.sh). FM_TOTMANN_RELAUNCH_CMD overrides it; an
#      unreadable ledger is a loud refusal, never a guessed wrapper.
#   4. The revival then reads its own RESULT back: after a short settle the
#      target pane is captured, and a capture showing `No conversation found`,
#      the onboarding wizard, the login chooser or the trust dialog means the
#      relaunch landed in a bare shell (the measured failure after the seat
#      move). That aborts the revival episode loudly - notifier plus exit 3 -
#      instead of arming a kicker that would type into nothing.
#   5. A resumed LARGE session instead stops at the harness's summary-vs-full
#      resume chooser (wording owner: bin/fm-totmann-relaunch-lib.sh, half 2b;
#      seen live 26.08.2026). That chooser is ANSWERED, not aborted: up to
#      three Enters take the highlighted default "Resume from summary" - the
#      re-anchoring comes from the files anyway, full history is never needed.
#      A chooser that survives them aborts the episode like a failed start.
#
# Revival mode - boot versus day-hang (captain finding 24.08.2026, O-0063
# night: a post-reboot `--continue` resumed stale pre-reboot context and the
# session idled at the prompt until the captain cleared and kicked it):
#   The boot epoch (/proc/stat btime) compared against .totmann-last-restart
#   decides, before the debounce overwrites it. A boot NEWER than the last
#   recorded revival is a BOOT REVIVAL: the relaunched session will resume
#   stale context, so after waiting for its first startup digest (the
#   state/.startup-network.timings marker moving past the pre-launch snapshot)
#   the revival types /clear - the fm-neustart mechanics - with the kicker's
#   stamp created BEFORE the clear, so only the post-clear digest triggers the
#   kick. A DAY-HANG (boot older than the last revival) keeps --continue plus
#   the kick and never clears automatically. Both modes arm
#   $FM_TOTMANN_ANSTOSS --hintergrund with that stamp, because a relaunched
#   Claude Code session starts no turn by itself. An unreadable boot epoch
#   falls back to day-hang behavior and says so loudly; the decision is never
#   skipped silently.
#
# The fleet stop does NOT gate this revival: after the nightly day-close reboot
# the leadership session must return, and state/.fleet-stop then keeps
# everything else from starting (plan v3 U1.7). Workers and officers are NEVER
# woken: the tool only ever touches the one configured target window.
#
# State (this header is the single owner):
#   $FM_HOME/state/.totmann-last-restart   epoch seconds of the last revival (debounce)
#
# Environment:
#   FM_TOTMANN_TARGET        tmux target pane (default firstmate:0)
#   FM_TOTMANN_RELAUNCH_CMD  command typed to revive (default: derived from the
#                            account ledger config/konten.tsv - the wrapper of the
#                            storage holding role `firstmate`, plus --continue)
#   FM_TOTMANN_ERGEBNIS_SECS seconds to settle before reading the relaunch result
#                            back from the pane (default 20; 0 disables the check)
#   FM_TOTMANN_TMUX          extra tmux args, e.g. "-L testsock" (tests)
#   FM_TOTMANN_DEBOUNCE      seconds between revivals (default 1800)
#   FM_TOTMANN_NOTIFY        notifier executable (default claw-notify; "" disables)
#   FM_TOTMANN_ANSTOSS       kicker armed after every revival (default
#                            ~/.local/bin/fm-anstoss; "" disables), called as
#                            "<kicker> --hintergrund <target> <stamp>"
#   FM_TOTMANN_READY_SECS    seconds the boot path waits for the fresh session's
#                            first digest before typing /clear anyway (default 240)
#   FM_TOTMANN_PROC_STAT     proc-stat source for the boot epoch
#                            (default /proc/stat; tests inject synthetic files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
MARKER="$STATE/.startup-network.timings"
TARGET="${FM_TOTMANN_TARGET:-firstmate:0}"
SESSION="${TARGET%%:*}"
RELAUNCH="${FM_TOTMANN_RELAUNCH_CMD:-}"
DEBOUNCE="${FM_TOTMANN_DEBOUNCE:-1800}"
NOTIFY="${FM_TOTMANN_NOTIFY-claw-notify}"
ANSTOSS="${FM_TOTMANN_ANSTOSS-$HOME/.local/bin/fm-anstoss}"
READY_SECS="${FM_TOTMANN_READY_SECS:-240}"
ERGEBNIS_SECS="${FM_TOTMANN_ERGEBNIS_SECS:-20}"
PROC_STAT="${FM_TOTMANN_PROC_STAT:-/proc/stat}"
read -r -a TMUX_EXTRA <<< "${FM_TOTMANN_TMUX:-}"

# --- account hook (owner: bin/fm-totmann-relaunch-lib.sh) -------------------
# The relaunch command and the result check both live in that library; kept to
# this block so the ledger can move without touching the revival mechanics.
# shellcheck source=bin/fm-totmann-relaunch-lib.sh
. "$SCRIPT_DIR/fm-totmann-relaunch-lib.sh"

relaunch_cmd() { # the command to type; loud refusal instead of a guessed account
  [ -z "$RELAUNCH" ] || { printf '%s\n' "$RELAUNCH"; return 0; }
  fm_totmann_relaunch_default && return 0
  echo "fm-totmann: no relaunch command - the account ledger config/konten.tsv named no firstmate seat." >&2
  echo "fm-totmann: move the seat with bin/fm-sitzwechsel.sh or set FM_TOTMANN_RELAUNCH_CMD; refusing to guess an account." >&2
  return 2
}

ergebnis_pruefen() { # after the relaunch: did the seat really start? 0 yes, 1 no
  local text grund ausweg versuche=0
  [ "$ERGEBNIS_SECS" -gt 0 ] 2>/dev/null || return 0
  sleep "$ERGEBNIS_SECS"
  text="$(tmx capture-pane -p -t "$TARGET" 2>/dev/null || true)"
  if [ -z "$text" ]; then
    echo "note: relaunch result unreadable (empty capture of $TARGET) - treating as started"
    return 0
  fi
  # The summary-vs-full chooser has a safe default (lib half 2b): answer it
  # with bounded Enters so a revival never waits on a human for this. A
  # chooser that survives every attempt is a failed start like any other.
  while fm_totmann_resume_dialog_pending "$text"; do
    versuche=$((versuche + 1))
    if [ "$versuche" -gt 3 ]; then
      echo "FEHLSTART: der Resume-Dialog (Summary gegen voller Verlauf) blieb in $TARGET nach 3 Enter-Versuchen offen." >&2
      echo "FEHLSTART: Der Sitz braucht von Hand einen Menschen; nichts wurde bewaffnet, kein Reset getippt." >&2
      if [ -n "$NOTIFY" ] && command -v "$NOTIFY" >/dev/null 2>&1; then
        "$NOTIFY" "Die Firstmate-Sitzung haengt im Resume-Dialog (Summary gegen voller Verlauf); 3 automatische Enter haben ihn nicht geschlossen. Bitte einmal von Hand nachsehen." \
          --prio hoch --projekt default >/dev/null 2>&1 || true
      fi
      return 1
    fi
    echo "note: resume chooser open - answering with the default (Enter on 'Resume from summary')"
    tmx send-keys -t "$TARGET" Enter
    sleep "$ERGEBNIS_SECS"
    text="$(tmx capture-pane -p -t "$TARGET" 2>/dev/null || true)"
    [ -n "$text" ] || break
  done
  grund="$(fm_totmann_fehlstart_grund "$text")" || return 0
  ausweg="$(fm_totmann_fehlstart_ausweg "$grund")"
  echo "FEHLSTART: die Wiederbelebung tippte '$RELAUNCH' in $TARGET, aber das Fenster zeigt: $grund" >&2
  echo "FEHLSTART: Quelle des Sitzes ist config/konten.tsv (Leser bin/fm-konten-lib.sh). Ausweg: $ausweg" >&2
  if [ -n "$NOTIFY" ] && command -v "$NOTIFY" >/dev/null 2>&1; then
    "$NOTIFY" "Die Firstmate-Sitzung liess sich NICHT wiederbeleben: $grund. Der Sitz kommt aus config/konten.tsv, gestartet wurde '$RELAUNCH'. Ausweg: $ausweg" \
      --prio hoch --projekt default >/dev/null 2>&1 || true
  fi
  return 1
}
# ---------------------------------------------------------------------------

usage() { sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
tmx() { tmux ${TMUX_EXTRA[@]+"${TMUX_EXTRA[@]}"} "$@"; }

is_shell_comm() { # the stable system shells; anything else in a pane is a live program
  case "$1" in
    bash|sh|dash|zsh|fish|ksh|-bash|-sh|-zsh) return 0 ;;
    *) return 1 ;;
  esac
}

verdict() { # prints the reason; exit 0 alive, 1 dead
  local lock_pid pane_pid comm
  lock_pid="$(cat "$STATE/.lock" 2>/dev/null || true)"
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "alive: session lock pid $lock_pid is running"
    return 0
  fi
  pane_pid="$(tmx display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null || true)"
  if [ -n "$pane_pid" ]; then
    if pgrep -P "$pane_pid" >/dev/null 2>&1; then
      echo "alive: pane $TARGET (pid $pane_pid) has a live child process"
      return 0
    fi
    comm="$(cat "/proc/$pane_pid/comm" 2>/dev/null || true)"
    if [ -n "$comm" ] && ! is_shell_comm "$comm"; then
      echo "alive: pane $TARGET runs '$comm' directly"
      return 0
    fi
    echo "dead: pane $TARGET is a bare shell (pid $pane_pid, comm ${comm:-unknown}) and no lock holder is alive"
    return 1
  fi
  echo "dead: no live lock holder and no pane $TARGET"
  return 1
}

boot_epoch() { # prints the running system's boot time as epoch seconds; fails when unreadable
  local b
  b="$(awk '$1 == "btime" { print $2; exit }' "$PROC_STAT" 2>/dev/null || true)"
  case "$b" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$b" ;;
  esac
}

LIB_SOURCED=""
clear_resumed_session() { # <pre-relaunch marker mtime>; returns 0 when /clear was proven submitted
  local pre_marker=$1 deadline digest_seen=0 busy comp verdict
  deadline=$(( $(date +%s) + READY_SECS ))
  if [ -z "$LIB_SOURCED" ]; then
    # shellcheck source=bin/fm-tmux-lib.sh
    . "$FM_ROOT/bin/fm-tmux-lib.sh"
    LIB_SOURCED=1
  fi
  # Wait for proof the fresh CLI rendered its first digest (the session-start
  # marker moved past our pre-launch snapshot); typing earlier risks the TUI
  # swallowing or misplacing the reset. A missing digest still clears at the
  # deadline - skipping would leave exactly the stale-context idle this
  # script exists to prevent.
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)" -gt "$pre_marker" ]; then
      digest_seen=1
      break
    fi
    sleep 3
  done
  # Type only into an idle pane with a proven-empty composer; the submit core
  # retries Enter only and never retypes.
  while [ "$(date +%s)" -lt "$deadline" ]; do
    busy="$(fm_pane_busy_state "$TARGET")"
    comp="$(fm_tmux_composer_state "$TARGET")"
    if [ "$busy" = idle ] && [ "$comp" = empty ]; then break; fi
    sleep 3
  done
  verdict="$(fm_tmux_submit_core "$TARGET" '/clear' 3 2 1)"
  if [ "$verdict" != empty ]; then
    echo "warn: /clear verdict '$verdict' (digest_seen=$digest_seen, waited up to ${READY_SECS}s) - arming the kicker anyway"
    return 1
  fi
  if [ "$digest_seen" != 1 ]; then
    echo "note: /clear submitted on the deadline fallback, without a seen digest marker"
  fi
  return 0
}

arm_anstoss() { # <stamp>: best-effort background kicker for the revived session
  local stamp=$1
  if [ -z "$ANSTOSS" ]; then
    echo "anstoss: disabled (empty FM_TOTMANN_ANSTOSS)"
    return 0
  fi
  if [ ! -x "$ANSTOSS" ]; then
    echo "warn: kicker '$ANSTOSS' missing or not executable - the revived session gets no automatic turn"
    return 1
  fi
  "$ANSTOSS" --hintergrund "$TARGET" "$stamp"
}

cmd="${1:-check}"
case "$cmd" in
  status)
    if verdict; then exit 0; fi
    exit 1
    ;;
  check)
    if verdict; then exit 0; fi
    mkdir -p "$STATE"
    now="$(date +%s)"
    last="$(cat "$STATE/.totmann-last-restart" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "$DEBOUNCE" ]; then
      echo "dead, but debounced: last revival $((now - last))s ago (< ${DEBOUNCE}s)"
      exit 0
    fi
    RELAUNCH="$(relaunch_cmd)" || exit 2
    mode="day-hang"
    boot_now="$(boot_epoch || true)"
    if [ -n "$boot_now" ]; then
      if [ "$boot_now" -gt "$last" ]; then mode="boot"; fi
    else
      echo "warn: boot epoch unreadable from $PROC_STAT - reviving as day-hang (no automatic /clear)"
    fi
    echo "$now" > "$STATE/.totmann-last-restart"
    pre_marker="$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)"
    if ! tmx has-session -t "$SESSION" 2>/dev/null; then
      tmx new-session -d -s "$SESSION" -c "$FM_HOME"
    fi
    tmx send-keys -t "$TARGET" "$RELAUNCH" Enter
    # Read the result back before anything is armed: a relaunch that answered
    # "No conversation found" or stopped at onboarding/trust left a bare shell,
    # and a kicker aimed at a bare shell types into nothing.
    if ! ergebnis_pruefen; then
      echo "aborted: revival episode stopped after a failed start in $TARGET (nothing armed, no reset typed)" >&2
      exit 3
    fi
    # The kicker's stamp predates the boot-path /clear, so only a digest
    # printed AFTER the reset counts (fm-neustart contract).
    stamp="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/fm-totmann-stempel.XXXXXX")"
    clear_ok=""
    if [ "$mode" = boot ]; then
      if clear_resumed_session "$pre_marker"; then clear_ok=yes; fi
    fi
    arm_anstoss "$stamp" || true
    case "$mode:$clear_ok" in
      boot:yes) note="boot revival: context reset (/clear) typed, kicker armed for the fresh digest" ;;
      boot:*)   note="boot revival: /clear unconfirmed, kicker armed anyway" ;;
      *)        note="day-hang revival: resumed without a reset, kicker armed" ;;
    esac
    echo "revived: typed relaunch into $TARGET ($note)"
    if [ -n "$NOTIFY" ] && command -v "$NOTIFY" >/dev/null 2>&1; then
      stop_note=""
      [ -f "$STATE/.fleet-stop" ] && stop_note=" Der Flottenstopp steht weiter - ausser der Fuehrung startet nichts."
      "$NOTIFY" "Firstmate war stehen geblieben und wurde automatisch wiederbelebt.${stop_note} Der naechste Startlauf bestaetigt den Zustand." \
        --prio warn --projekt default >/dev/null 2>&1 || true
    fi
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
