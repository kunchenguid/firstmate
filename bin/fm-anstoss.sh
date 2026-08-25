#!/usr/bin/env bash
# fm-anstoss.sh - the Anstoss-Automat: detect lanes that silently exited and
# nudge them up a two-step ladder, so a restart order does not always have to
# come from the captain (order anstoss-automatik, 2026-08-24; O-0023 incident:
# four of six fresh Ox lanes of one wave stood silently while their status
# lines kept claiming working).
#
# Detection is STATE AT THE ENDPOINT, never stillness-over-time (window-
# stillness alarms are abolished, Flottenordnung L28). One sweep iterates ONLY
# this home's own state/*.meta records (L86) and classifies each ordinary
# ship/scout lane. A lane stands silently exited when ALL of:
#   1. its backlog post is in_flight,
#   2. its recorded endpoint holds a verified live agent,
#   3. its pane carries NO known harness working marker anywhere in the FULL
#      visible capture (the whole capture-pane surface is read, never a tail -
#      an API-error banner often renders far above the prompt and a short tail
#      was blind for 2 of 3 standing windows on 2026-08-24),
#   4. its status file ends on no terminal verb (done/failed/blocked, plus
#      needs-decision: that post waits on firstmate by design, not on a nudge),
#   5. no working child processes: no CPU delta across the sweep interval and
#      no advancing no-mistakes run - a lane correctly waiting on real CI or a
#      declared pipeline counts as WORKING and is never nudged,
#   6. no active machine wait field (bin/fm-wait-lib.sh).
# fm-crew-state's aggregate working verdict is deliberately NOT consulted: on
# 2026-08-24 it said working for three standing lanes, so only endpoint-owned
# signals feed this classifier.
#
# Working markers come from the verified adapter knowledge (.agents/skills/
# harness-adapters/SKILL.md), never guessed: claude/claude-ox render
# "esc to interrupt", grok renders "Ctrl+c:cancel", cursor renders the token
# "ctrl+c to stop". Harnesses with no verified rendered marker (codex, kimi,
# muse, opencode, pi) simply contribute no pane signal here - condition 3
# passes vacuously for them and conditions 5/6 carry the liveness verdict.
#
# Failure-class separation (O-0018): a standing pane whose capture matches an
# API-error signature ("API Error", cloudflare) runs its OWN two-nudge ladder
# instead of being silently folded into the standing-lane ladder above
# (captain's word, 25.08. mittags: "geht das nicht per waechter? Arbeiter
# scannen und wenn die letzte ausgabe API-Error enthaellt einfach 'weiter
# gehts' schreiben?!?" - EN: "can't the watcher do this? Scan workers and if
# the last output contains API-Error just type 'keep going'?!?"). The
# signature list lives in api_error_matches() below and owns that vocabulary.
# The one exception: a pane whose capture ALSO shows an open interactive
# choice (a numbered "N. Yes" menu, vocabulary owned by dialog_choice_pending()
# below) is never typed into - reported once per distinct image instead,
# exactly the pre-automation path, because a freeform nudge line typed into a
# live selection is a fresh mistake, not a recovery.
#
# Ladder per lane, counted in state/.anstoss-count-<id>:
#   Stage 1 (automatic, silent): one fm-send nudge carrying a written end
#     condition - verify what is committed at the artifact, answer the open
#     acceptance points, then report done: with evidence, or blocked:/paused:
#     with a reason, or declare a machine wait field. Minimum spacing between
#     nudges is FM_ANSTOSS_INTERVAL seconds.
#   Stage 2 (from the SECOND ineffective nudge): when the situation fingerprint
#     (status tail plus full capture) is UNCHANGED after the spacing interval,
#     print one line waking firstmate with the lane id and counter - a relaunch
#     stays firstmate's decision.
#   Refuted nudge (L34): a lane that turns out working after being nudged
#     doubles that lane's minimum spacing (capped doublings), so a false alarm
#     makes the Automat quieter, never louder. A lane closing with a terminal
#     verb resets everything.
#
# O-0018 ladder per lane, counted in state/.anstoss-o18n-<id> (separate from
# the standing-lane counter above; a lane classifies as EITHER standing OR
# O-0018 on a given sweep, never both):
#   Nudges 1 and 2 (automatic, silent): the same fm-send path types a fixed
#     API-recovery line - resume the work, measure the worktree instead of
#     recalling it, close on a terminal status line. Spacing is the same
#     FM_ANSTOSS_INTERVAL/backoff clock the standing ladder uses (shared per
#     lane, so a refutation on this lane quiets both ladders together).
#   From the third API failure (i.e. the second nudge proved ineffective): no
#     further auto-nudge - one line wakes firstmate instead, repeating every
#     spacing interval while the lane stays stuck (account re-routing stays
#     supervisor business, O-0018).
#   Refuted nudge and terminal close: identical L34/reset handling to the
#     standing ladder, through the same shared note_liveness_recovery() path.
#
# Every sweep prints NOTHING to STDOUT unless firstmate must act: exactly one
# line for a standing-lane stage-2 escalation, an O-0018 escalation, or a
# dialog-blocked O-0018 first sighting. Fleet stop (state/.fleet-stop) silences
# all nudges and reports (U0.1).
#
# Check observability (O-0041 root cause, captain's word 25.08.: he nudged
# worker 6 past an API error BY HAND because it was undecidable whether past
# sweeps had even seen the pane - green selftests prove nothing against the
# live case without a record of it, L03): every sweep APPENDS one line per
# suspicious pane to its own log, state/.anstoss-check.log - NOT the
# revival-era .fm-anstoss.log, which belongs to a different function. A pane
# is suspicious when its capture carries an API-error signature (whatever the
# outcome: nudge typed, spaced out with reason, escalated, dialog reported,
# or silenced by the harness working marker) or when it classifies as a
# standing lane. Each line carries: timestamp, lane id, matched signature,
# busy/idle verdict, O-0018 counter as of AFTER the action, and the action
# (stufe1-getippt / stufe2-getippt / eskaliert / erstbefund-gemeldet /
# uebersprungen with reason). Healthy panes log nothing, so volume is bounded
# by stuck lanes x sweep rounds and shrinks with every recovery; an ignored
# stuck lane keeps waking firstmate long before unbounded history could
# accumulate, so this log needs no rotation.
#
# Latency decision (brief item 3; numbers measured 25.08., sources in bin/):
# detection is bound by fm-watch's shared check cadence - CHECK_INTERVAL=300s
# default plus at most POLL=15s loop jitter - because nudge-on-detect already
# fires on the FIRST sighting of an error pane. Anything below that cadence is
# unreachable from this script alone; lowering CHECK_INTERVAL would speed up
# all dozen registered checks at once and stays firstmate's call. The binding
# gap was the SHARED nudge spacing instead: FM_ANSTOSS_INTERVAL=600s gated the
# O-0018 ladder too, putting worst-case onset-to-escalation at roughly 25-35
# minutes (derived: ~315s detect + two sweep-gated spacings of 600..900s each).
# The O-0018 auto-nudges therefore run their OWN spacing,
# FM_ANSTOSS_O18_NUDGE_INTERVAL=120s (still L34-doubled): below the 300s sweep
# floor the sweep itself is the clock, so nudge #2 lands on the very next
# round; any value in (0,300] behaves identically at live cadence and 120
# keeps a real floor for manual or faster sweeps. Escalation repeats stay on
# the shared 600s/L34 clock, so firstmate's wake volume is unchanged and the
# only added machine work is one earlier send-keys per stuck lane.
#
# FM_ANSTOSS_DEBUG=1 prints a stderr decision trace (counter, clock, gate) for
# every ladder pass - forensics for exactly the undecidable cases the check
# log exists to prevent; it stays off by default and writes nowhere else.
#
# Commands:
#   fm-anstoss.sh check            one detection-and-ladder sweep (default)
#   fm-anstoss.sh arm              write and register state/anstoss.check.sh
#   fm-anstoss.sh disarm           remove the check shim and its trust binding
#   fm-anstoss.sh --selftest       verify the sources this check needs
#   fm-anstoss.sh --help           print this command summary
#
# Arming follows the disarm-after-measurement pattern: the shim is written and
# registered only AFTER this lands in the deploying home, never from a feature
# worktree. Paths follow the house overrides (FM_ROOT_OVERRIDE, FM_HOME,
# FM_STATE_OVERRIDE) exactly as fm-brett-antworten.sh resolves them.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=anstoss
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
SEND_BIN="${FM_ANSTOSS_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
CAPTURE_LINES=${FM_ANSTOSS_CAPTURE_LINES:-400}
INTERVAL=${FM_ANSTOSS_INTERVAL:-600}
BACKOFF_MAX=${FM_ANSTOSS_BACKOFF_MAX:-4}
CHECK_LOG="$STATE/.anstoss-check.log"
O18_NUDGE_INTERVAL=${FM_ANSTOSS_O18_NUDGE_INTERVAL:-120}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wait-lib.sh
. "$SCRIPT_DIR/fm-wait-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-anstoss.sh check        one state-based sweep: detect silently exited
                             lanes, run the two-step nudge ladder, run the
                             O-0018 API-error ladder (two auto-nudges, then
                             escalate; open dialogs are reported, never typed);
                             appends one audit line per suspicious pane to
                             state/.anstoss-check.log
  fm-anstoss.sh arm          write and register state/anstoss.check.sh
  fm-anstoss.sh disarm       remove the check shim and its trust binding
  fm-anstoss.sh --selftest   verify the sources this check needs
  fm-anstoss.sh --help       print this summary

The full mechanics contract is owned by the header comment of this script.
EOF
}

die_usage() {
  printf 'fm-anstoss: %s\n' "$1" >&2
  usage >&2
  exit 2
}

_anstoss_hash() {  # stdin -> hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Working-marker vocabulary per harness, from the verified adapter knowledge
# only. Unknown harness -> empty regex (no pane signal; see header).
working_marker_regex() {  # <harness>
  case "$1" in
    claude | claude-ox) printf '%s' 'esc to interrupt' ;;
    grok) printf '%s' 'Ctrl\+c:cancel' ;;
    cursor) printf '%s' 'ctrl\+c to stop' ;;
    *) printf '' ;;
  esac
}

# O-0018 API-error signatures. This function owns the vocabulary; extend it
# only with a measured rendering, never a guess.
api_error_matches() {  # <capture-text>
  printf '%s\n' "$1" | grep -Eim1 'API Error|[Cc]loudflare'
}

# An open interactive choice (a numbered "N. Yes" menu row - the verified
# shape of a Yes/No-style confirmation, e.g. "1. Yes" or "  2. Yes, continue")
# anywhere in the capture. This function owns that vocabulary; item 4 of the
# anstoss-selbst-tippen brief: never type into one, report it instead.
dialog_choice_pending() {  # <capture-text> -> 0 if a choice row is present
  printf '%s\n' "$1" | grep -Eiq '[0-9]+\.[[:space:]]*Yes\b'
}

backoff_doublings() {  # <id> -> current doubling exponent
  local n
  n=$(cat "$STATE/.anstoss-backoff-$1" 2>/dev/null || echo 0)
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  [ "$n" -gt "$BACKOFF_MAX" ] && n=$BACKOFF_MAX
  printf '%s' "$n"
}

effective_interval() {  # <id> -> minimum seconds between this lane's nudges
  echo $(( INTERVAL * (1 << $(backoff_doublings "$1")) ))
}

# The O-0018 ladder's own nudge spacing (header, latency decision): the shared
# INTERVAL clock keeps gating escalation repeats, this faster floor gates
# auto-nudges 1 and 2 only. L34 doublings apply identically.
o18_nudge_interval() {  # <id> -> seconds between O-0018 auto-nudges
  echo $(( O18_NUDGE_INTERVAL * (1 << $(backoff_doublings "$1")) ))
}

# Check-round audit line (header owns the contract). Best effort: a logging
# failure must never kill the sweep mid-ladder, but it is visible in the log's
# absence - the file stops growing, which the next hand-audit reads as a gap,
# never as an all-clear (L33).
anstoss_trace() {  # <context...> ; stderr decision trace, only when asked
  [ "${FM_ANSTOSS_DEBUG:-}" = 1 ] || return 0
  printf 'anstoss-trace: %s\n' "$*" >&2
}

anstoss_log() {  # <id> <sig> <state> <action> <reason>
  local sig=${2:0:80}
  printf '[%s] id=%s sig="%s" state=%s o18n=%s action=%s reason=%s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "${sig:--}" \
    "$3" "$(cat "$STATE/.anstoss-o18n-$1" 2>/dev/null || echo 0)" \
    "$4" "${5:--}" >> "$CHECK_LOG" 2>/dev/null || true
}

# Ladder bookkeeping clears. <last> (contact epoch) and <backoff> (L34
# doublings) survive a plain clear so a refuted nudge's extended interval
# keeps biting after the counter itself is gone.
anstoss_state_clear() {  # <id>
  rm -f "$STATE/.anstoss-count-$1" \
    "$STATE/.anstoss-fp-$1" "$STATE/.anstoss-o0018-$1" "$STATE/.anstoss-o18n-$1"
}

anstoss_state_reset_all() {  # <id>
  anstoss_state_clear "$1"
  rm -f "$STATE/.anstoss-last-$1" "$STATE/.anstoss-backoff-$1"
}

# Backlog post state for <id>, or empty when unreadable (which skips the lane:
# an unreadable premise is never resolved toward a nudge).
backlog_task_state() {  # <id> <home>
  (cd "$2" 2>/dev/null &&
    tasks-axi show "$1" --file "$2/data/backlog.md" 2>/dev/null ||
    true) |
    sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -1
}

# Fingerprint of the lane situation: status tail plus whitespace-normalized
# full capture, so repaint noise on unchanged content does not fake change.
situation_fingerprint() {  # <status-line> <capture-text>
  {
    printf '%s\n' "$1"
    printf '%s\n' "$2" | sed 's/[[:space:]]*$//' | grep -v '^$' || true
  } | _anstoss_hash
}

stage1_nudge_message() {  # <id> <count> <reason-detail>
  cat <<EOF
Anstoss-Automat (#$2): dieser Posten wirkt still ausgestiegen ($3). Endbedingung dieses Anstosses: verifiziere zuerst am Artefakt, was committet ist, bearbeite die offenen Abnahmepunkte aus deinem Brief und melde anschliessend eine Statuszeile mit Belegen - "done:" mit dem committeten Stand, oder "blocked:"/"paused:" mit Grund, oder deklariere ein Maschinen-Wartefeld per bin/fm-wait.sh declare. Bleibt der Zustand nicht sichtbar veraendert, eskaliert der naechste unwirksame Anstoss an Firstmate.
EOF
}

# Fixed text per the O-0023 ladder end condition (sinngemaess captain's word,
# 25.08. mittags). Typed identically on nudge 1 and 2; only the counter in the
# prefix changes, matching stage1_nudge_message's own numbering convention.
o18_nudge_message() {  # <id> <count>
  cat <<EOF
Anstoss nach API-Abbruch (#$2, O-0018): nimm die Arbeit wieder auf - miss den Stand am Worktree, statt ihn zu erinnern. Endbedingung: eine terminale Statuszeile (done:/blocked:/needs-decision:). Weitere API-Abbrueche dieser Bahn werden erneut angestossen.
EOF
}

# Refutation bookkeeping (L34): a lane proven working right after a nudge
# doubles that lane's spacing, anchored on the contact epoch. A terminal
# status closes cleanly and resets everything instead. Checks BOTH ladder
# counters (standing and O-0018) - either one having sent a real nudge makes
# this a genuine refutation, not just an unmeasured first sighting.
note_liveness_recovery() {  # <id> <terminal-seen(0/1)>
  local count count_o18 n
  if [ "${2:-0}" = 1 ]; then
    anstoss_state_reset_all "$1"
    return 0
  fi
  count=$(cat "$STATE/.anstoss-count-$1" 2>/dev/null || echo 0)
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  count_o18=$(cat "$STATE/.anstoss-o18n-$1" 2>/dev/null || echo 0)
  case "$count_o18" in '' | *[!0-9]*) count_o18=0 ;; esac
  { [ "$count" -ge 1 ] || [ "$count_o18" -ge 1 ]; } || {
    anstoss_state_clear "$1"
    return 0
  }
  n=$(backoff_doublings "$1")
  n=$((n + 1))
  [ "$n" -gt "$BACKOFF_MAX" ] && n=$BACKOFF_MAX
  printf '%s\n' "$n" > "$STATE/.anstoss-backoff-$1.tmp" &&
    mv -f "$STATE/.anstoss-backoff-$1.tmp" "$STATE/.anstoss-backoff-$1"
  date +%s > "$STATE/.anstoss-last-$1"
  anstoss_state_clear "$1"
  return 0
}

classify_lane() {  # <id> <meta> ; sets globals: LANE_VERDICT LANE_DETAIL
                   # CAPTURE_TEXT SIG_HIT LANE_STATE (LADDER_ACTION/LADDER_REASON
                   # are filled by the ladder functions)
  local id=$1 meta=$2 backend target harness kind marker capture status_line
  local agent reason_detail='' err_line
  LANE_VERDICT=''
  LANE_DETAIL=''
  SIG_HIT=''
  LANE_STATE=''

  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    ship | scout) ;;
    *) return 0 ;; # secondmates idle healthily (L86: their homes supervise themselves)
  esac
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  harness=$(fm_meta_get "$meta" harness)

  # Condition 2: endpoint alive. dead/missing belong to stuck-recovery;
  # anything unproven never reaches a nudge.
  agent=$(fm_backend_agent_state "$backend" "$target")
  [ "$agent" = alive ] || return 0

  # Condition 6: an ACTIVE machine wait field silences this lane entirely.
  if fm_wait_read "$STATE" "$id" && [ "${FM_WAIT_STATE:-}" = active ]; then
    return 0
  fi

  # Condition 4: terminal verbs close the lane (needs-decision included: that
  # post waits on firstmate's answer, not on a nudge).
  status_line=$(last_status_line "$STATE/$id.status")
  if status_is_terminal_verb "$status_line"; then
    note_liveness_recovery "$id" 1
    return 0
  fi

  # Full visible capture, once, untrimmed (2026-08-24: a tail-cut was blind
  # for 2 of 3 standing windows because the error banner sat far above).
  capture=$(fm_backend_capture "$backend" "$target" "$CAPTURE_LINES" 2>/dev/null || true)
  CAPTURE_TEXT=$capture

  # The error signature is read BEFORE the working-marker gate: a pure read,
  # so ordering cannot change behavior, but it lets the busy-with-error-image
  # case below be logged instead of vanishing (O-0041 observability).
  err_line=$(api_error_matches "$capture" || true)

  # Condition 3: known harness working marker anywhere in the full capture.
  marker=$(working_marker_regex "$harness")
  if [ -n "$marker" ] && printf '%s\n' "$capture" | grep -qE "$marker"; then
    note_liveness_recovery "$id" 0
    if [ -n "$err_line" ]; then
      # Error image UNDER a working marker is the ambiguous recovery shape:
      # logged as busy so a later hand-audit can tell "seen, considered
      # working" apart from "never seen".
      SIG_HIT=$err_line
      LANE_STATE=busy-marker
      LADDER_ACTION=uebersprungen
      LADDER_REASON=arbeitszeichen-des-harness-sichtbar
    fi
    return 0
  fi

  # O-0018 separation BEFORE the work-evidence gates: an alive endpoint, no
  # working marker, and an API-error image anywhere in the FULL capture is the
  # incident shape itself (2026-08-24). It runs the O-0018 ladder
  # (run_o18_ladder, header owns the contract) instead of the CPU/no-mistakes
  # work-evidence gates below - retries burning CPU behind a dead stream must
  # not reclassify the stall as work. An open interactive choice is the one
  # exception: reported once per distinct image, never typed into.
  if [ -n "$err_line" ]; then
    if dialog_choice_pending "$capture"; then
      # An open interactive choice is never typed into (item 4): reported
      # once per distinct image, exactly the pre-automation O-0018 path.
      local fp_err
      fp_err=$(printf '%s' "$err_line" | _anstoss_hash)
      rm -f "$STATE/.anstoss-o18n-$id"
      SIG_HIT=$err_line
      LANE_STATE=idle-dialog
      if [ "$(cat "$STATE/.anstoss-o0018-$id" 2>/dev/null || true)" != "$fp_err" ]; then
        printf '%s\n' "$fp_err" > "$STATE/.anstoss-o0018-$id" || return 0
        LANE_VERDICT=o0018
        LANE_DETAIL="O-0018-API-Fehlerbild an $id (Dialog offen, nicht angetippt): $(printf '%s' "$err_line" | cut -c1-100) - Erstbefund bei Firstmate"
        LADDER_ACTION=erstbefund-gemeldet
        LADDER_REASON=''
      else
        LADDER_ACTION=uebersprungen
        LADDER_REASON=dialog-bild-unveraendert-bereits-gemeldet
      fi
      return 0
    fi
    rm -f "$STATE/.anstoss-o0018-$id"
    LANE_VERDICT=o0018auto
    LANE_DETAIL=$err_line
    SIG_HIT=$err_line
    LANE_STATE=idle-o18
    return 0
  fi
  rm -f "$STATE/.anstoss-o0018-$id" "$STATE/.anstoss-o18n-$id"

  # Condition 5a: CPU delta across the sweep interval (child processes).
  # The very first sample only seeds the delta's baseline: an unmeasured pane
  # never counts as "no working children", so a lane's earliest possible nudge
  # is its second sighting.
  local cpu_verdict
  cpu_verdict=$(fm_busy_cpu_progress "$backend" "$target" "$STATE" "anstoss-$id")
  case "$cpu_verdict" in
    progress*)
      note_liveness_recovery "$id" 0
      return 0
      ;;
    no-baseline)
      return 0
      ;;
    no-source | flat*) ;; # absent source or proven-flat feeds the conjunction
  esac

  # Condition 5b: an advancing no-mistakes run - the CI/pipeline waiter that
  # must count as WORKING (2026-08-24: a lane correctly waiting on a hanging
  # CI runner would otherwise be the wrong one to nudge). Asked only here,
  # on the about-to-condemn path, to bound the sweep's cost.
  if [ "$kind" = ship ] && command -v no-mistakes >/dev/null 2>&1 &&
    crew_run_progressed "$id" "$STATE"; then
    note_liveness_recovery "$id" 0
    return 0
  fi

  # Condition 1: the backlog post must be in_flight; unreadable skips.
  [ "$(backlog_task_state "$id" "$FM_HOME")" = in_flight ] || return 0

  reason_detail="Posten in_flight, Endpunkt lebt, kein Arbeitszeichen im Pane, keine arbeitenden Kinder, keine terminale Statuszeile, kein Wartefeld"

  LANE_VERDICT=standing
  LANE_DETAIL="$reason_detail"
  LANE_STATE=idle-standing
  return 0
}

run_ladder() {  # <id> <detail> ; reads CAPTURE_TEXT from classify_lane;
  # sets LADDER_ACTION/LADDER_REASON for the check log
  local id=$1 detail=$2 now count last fp stored_fp min_spaced gate
  now=$(date +%s)
  count=$(cat "$STATE/.anstoss-count-$id" 2>/dev/null || echo 0)
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  last=$(cat "$STATE/.anstoss-last-$id" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  fp=$(situation_fingerprint "$(last_status_line "$STATE/$id.status")" "${CAPTURE_TEXT:-}")

  if [ "$count" -eq 0 ]; then
    # Spacing guard after a refutation (L34): stay quiet until the doubled
    # interval has passed since the last contact with this lane.
    gate=$(effective_interval "$id")
    if [ "$((now - last))" -lt "$gate" ]; then
      LADDER_ACTION=uebersprungen
      LADDER_REASON="spacing-wait-$((now - last))s<${gate}s"
      return 0
    fi
    if FM_HOME="$FM_HOME" "$SEND_BIN" "$id" "$(stage1_nudge_message "$id" 1 "$detail")" >/dev/null 2>&1; then
      printf '1\n' > "$STATE/.anstoss-count-$id"
      printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
      printf '%s\n' "$fp" > "$STATE/.anstoss-fp-$id"
      LADDER_ACTION=stufe1-getippt
      LADDER_REASON=''
    else
      LADDER_ACTION=uebersprungen
      LADDER_REASON=send-fehlgeschlagen
    fi
    return 0
  fi

  # Stage 2 territory: a previous nudge exists. Escalate only when the
  # situation is byte-identical to the one the last nudge addressed and the
  # spacing interval has passed.
  stored_fp=$(cat "$STATE/.anstoss-fp-$id" 2>/dev/null || true)
  min_spaced=$((now - last))
  gate=$(effective_interval "$id")
  if [ "$fp" = "$stored_fp" ] && [ "$min_spaced" -ge "$gate" ]; then
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE/.anstoss-count-$id"
    printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
    printf 'anstoss: Bahn %s steht unveraendert still (%d. Anstoss wirkungslos, Zustand seit %d min unveraendert) - Weckruf an Firstmate: Neustart-Entscheid faellen\n' \
      "$id" "$count" "$((min_spaced / 60))"
    LADDER_ACTION=eskalatiert
    LADDER_REASON="zustand-$((min_spaced / 60))min-unveraendert"
    return 0
  fi

  # Situation changed since the last nudge: record the new fingerprint so the
  # next unchanged cycle can escalate against the CURRENT state, and let the
  # spacing clock restart from now. Otherwise the spacing clock simply has not
  # run out yet against an unchanged situation.
  if [ "$fp" != "$stored_fp" ]; then
    printf '%s\n' "$fp" > "$STATE/.anstoss-fp-$id"
    printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
    LADDER_ACTION=uebersprungen
    LADDER_REASON=situation-veraendert-fp-neu-gesetzt
  else
    LADDER_ACTION=uebersprungen
    LADDER_REASON="spacing-wait-${min_spaced}s<${gate}s"
  fi
  return 0
}

# The O-0018 ladder (captain's word, 25.08. mittags): nudges 1 and 2 type the
# fixed API-recovery line automatically; from the third API failure of this
# lane (the second nudge already proved ineffective) no further auto-nudge
# happens - one line wakes firstmate instead, repeating every spacing
# interval while the lane stays stuck. One counter, state/.anstoss-o18n-<id>,
# carries both halves: values 1-2 are nudges already sent, values 3+ are
# escalation reports already printed. Spacing reuses the SAME
# .anstoss-last-<id>/.anstoss-backoff-<id> clock the standing ladder uses, so
# a refutation elsewhere on this lane (note_liveness_recovery) quiets this
# ladder too.
run_o18_ladder() {  # <id> <err-line> ; the standing ladder's counterpart;
  # sets LADDER_ACTION/LADDER_REASON for the check log
  local id=$1 err_line=$2 now count last next gate
  now=$(date +%s)
  count=$(cat "$STATE/.anstoss-o18n-$id" 2>/dev/null || echo 0)
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  last=$(cat "$STATE/.anstoss-last-$id" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  # Nudges 1 and 2 run on the faster O-0018 spacing (header, latency
  # decision); escalation repeats keep the shared INTERVAL/L34 clock, so the
  # wake volume to firstmate is unchanged.
  if [ "$count" -lt 2 ]; then
    gate=$(o18_nudge_interval "$id")
  else
    gate=$(effective_interval "$id")
  fi
  anstoss_trace "o18 id=$id count=$count now=$now last=$last gate=$gate elapsed=$((now - last))"
  if [ "$((now - last))" -lt "$gate" ]; then
    LADDER_ACTION=uebersprungen
    LADDER_REASON="spacing-wait-$((now - last))s<${gate}s"
    return 0
  fi
  next=$((count + 1))

  if [ "$count" -lt 2 ]; then
    if FM_HOME="$FM_HOME" "$SEND_BIN" "$id" "$(o18_nudge_message "$id" "$next")" >/dev/null 2>&1; then
      printf '%s\n' "$next" > "$STATE/.anstoss-o18n-$id"
      printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
      LADDER_ACTION="stufe${next}-getippt"
      LADDER_REASON=''
    else
      LADDER_ACTION=uebersprungen
      LADDER_REASON=send-fehlgeschlagen
    fi
    return 0
  fi

  printf '%s\n' "$next" > "$STATE/.anstoss-o18n-$id"
  printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
  printf 'anstoss: Bahn %s bleibt nach API-Abbruch still (%d. Anstoss wirkungslos, O-0018) - Weckruf an Firstmate: Neustart-Entscheid faellen. Letzter Fehlerbefund: %s\n' \
    "$id" "$next" "$(printf '%s' "$err_line" | cut -c1-100)"
  LADDER_ACTION=eskalatiert
  LADDER_REASON="zwei-nudges-wirkungslos-o18n-$next"
  return 0
}

action_check() {
  # Fleet stop silences every nudge and report (U0.1: automations read the
  # order states before revival).
  [ -f "$STATE/.fleet-stop" ] && exit 0
  command -v tasks-axi >/dev/null 2>&1 || exit 0

  local meta id
  CAPTURE_TEXT=''
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    LANE_VERDICT=''
    LANE_DETAIL=''
    SIG_HIT=''
    LANE_STATE=''
    LADDER_ACTION=''
    LADDER_REASON=''
    classify_lane "$id" "$meta" || true
    case "$LANE_VERDICT" in
      standing)
        # Reuse the classification capture for the ladder fingerprint.
        run_ladder "$id" "$LANE_DETAIL"
        ;;
      o0018)
        printf '%s\n' "$LANE_DETAIL"
        ;;
      o0018auto)
        run_o18_ladder "$id" "$LANE_DETAIL"
        ;;
    esac
    # Check-round audit line (header owns the scope); stdout stays untouched.
    if [ -n "$SIG_HIT" ] || [ "$LANE_VERDICT" = standing ]; then
      anstoss_log "$id" "$SIG_HIT" "${LANE_STATE:-idle}" \
        "${LADDER_ACTION:-keine}" "$LADDER_REASON"
    fi
  done

  # Prune ladder state for lanes whose metadata is gone (teardown cleanup
  # already removed the inbox; these counters are ours alone).
  local b kind2
  for meta in "$STATE"/.anstoss-*; do
    [ -e "$meta" ] || continue
    b=${meta##*/}
    b=${b#.anstoss-}
    kind2=${b%%-*}
    case "$kind2" in
      count | last | fp | backoff | o0018 | o18n) ;;
      *) continue ;;
    esac
    id=${b#"$kind2"-}
    case "$id" in
      '' | *[!A-Za-z0-9._-]*) continue ;;
    esac
    [ -f "$STATE/$id.meta" ] || rm -f "$meta"
  done
  exit 0
}

shim_content() {  # <home-abs>
  cat <<EOF
#!/usr/bin/env bash
# Auto-generated by fm-anstoss.sh - Anstoss-Automat poll shim.
# The watcher validates these bytes, then dispatches the trusted check script.
[ -f "$1/state/.fleet-stop" ] && exit 0
export FM_HOME='$1'
exec '$SCRIPT_DIR/fm-anstoss.sh' check
EOF
}

ARM_BACKUP=
shim_backup() {
  local backup
  backup=$(mktemp "$STATE/.anstoss-shim-prior.XXXXXX") || return 1
  cp -p "$CHECK_SHIM" "$backup" || {
    rm -f -- "$backup"
    return 1
  }
  ARM_BACKUP=$backup
}

arm_rollback() {
  if [ -n "$ARM_BACKUP" ] && [ -f "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM"
    FM_HOME="$FM_HOME" "$REGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
  else
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  fi
}

arm_interrupted() {
  arm_rollback
  exit 130
}

action_arm() {
  local home want
  command -v tasks-axi >/dev/null 2>&1 || {
    printf 'fm-anstoss: tasks-axi is missing, the detector could never classify a lane\n' >&2
    return 1
  }
  [ -x "$SEND_BIN" ] || {
    printf 'fm-anstoss: %s is missing, a nudge could never be delivered\n' "$SEND_BIN" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  case $FM_HOME in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-anstoss: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    shim_backup || {
      printf 'fm-anstoss: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! printf '%s' "$want" > "$CHECK_SHIM"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-anstoss: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  chmod 0700 "$CHECK_SHIM"
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-anstoss: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_selftest() {
  local ok=1
  [ -x "$SEND_BIN" ] || {
    echo "SELFTEST FAIL: $SEND_BIN fehlt"
    ok=0
  }
  [ -x "$REGISTER_BIN" ] || {
    echo "SELFTEST FAIL: $REGISTER_BIN fehlt"
    ok=0
  }
  command -v tasks-axi >/dev/null 2>&1 || {
    echo "SELFTEST FAIL: tasks-axi fehlt - der Detector kann keinen Posten-Zustand lesen"
    ok=0
  }
  if [ -f "$FM_HOME/data/backlog.md" ]; then
    echo "SELFTEST OK: backlog lesbar"
  else
    echo "SELFTEST FAIL: backlog fehlt unter $FM_HOME/data/backlog.md"
    ok=0
  fi
  [ "$ok" = 1 ] && echo "SELFTEST OK: Quellen lesbar, sechs Bedingungen aktiv, Zweistufen-Leiter scharf"
  [ "$ok" = 1 ]
}

case ${1:-check} in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  --selftest) action_selftest ;;
  -h | --help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
