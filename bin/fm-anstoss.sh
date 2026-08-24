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
# API-error signature ("API Error", cloudflare) is REPORTED once per incident
# instead of silently nudged - a provider outage is firstmate's call, not a
# worker motivation problem. The signature list lives in api_error_matches()
# below and owns that vocabulary.
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
# Every sweep prints NOTHING unless firstmate must act: exactly one line for a
# stage-2 escalation or a first-time O-0018 finding. Fleet stop
# (state/.fleet-stop) silences all nudges and reports (U0.1).
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
                             lanes, run the two-step nudge ladder, report
                             O-0018 API-error panes instead of nudging them
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

# Ladder bookkeeping clears. <last> (contact epoch) and <backoff> (L34
# doublings) survive a plain clear so a refuted nudge's extended interval
# keeps biting after the counter itself is gone.
anstoss_state_clear() {  # <id>
  rm -f "$STATE/.anstoss-count-$1" \
    "$STATE/.anstoss-fp-$1" "$STATE/.anstoss-o0018-$1"
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

# Refutation bookkeeping (L34): a lane proven working right after a nudge
# doubles that lane's spacing, anchored on the contact epoch. A terminal
# status closes cleanly and resets everything instead.
note_liveness_recovery() {  # <id> <terminal-seen(0/1)>
  local count n
  if [ "${2:-0}" = 1 ]; then
    anstoss_state_reset_all "$1"
    return 0
  fi
  count=$(cat "$STATE/.anstoss-count-$1" 2>/dev/null || echo 0)
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  [ "$count" -ge 1 ] || {
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

classify_lane() {  # <id> <meta> ; sets globals: LANE_VERDICT LANE_DETAIL CAPTURE_TEXT
  local id=$1 meta=$2 backend target harness kind marker capture status_line
  local agent reason_detail='' err_line
  LANE_VERDICT=''
  LANE_DETAIL=''

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

  # Condition 3: known harness working marker anywhere in the full capture.
  marker=$(working_marker_regex "$harness")
  if [ -n "$marker" ] && printf '%s\n' "$capture" | grep -qE "$marker"; then
    note_liveness_recovery "$id" 0
    return 0
  fi

  # O-0018 separation BEFORE the work-evidence gates: an alive endpoint, no
  # working marker, and an API-error image anywhere in the FULL capture is the
  # incident shape itself (2026-08-24). It is reported, not nudged - retries
  # burning CPU behind a dead stream must not reclassify the stall as work,
  # and an old transcript error in a recovered lane costs one surplus report,
  # never an automatic action. Reported on first sighting; identical images
  # stay quiet through the fingerprint marker.
  err_line=$(api_error_matches "$capture" || true)
  if [ -n "$err_line" ]; then
    local fp_err
    fp_err=$(printf '%s' "$err_line" | _anstoss_hash)
    if [ "$(cat "$STATE/.anstoss-o0018-$id" 2>/dev/null || true)" != "$fp_err" ]; then
      printf '%s\n' "$fp_err" > "$STATE/.anstoss-o0018-$id" || return 0
      LANE_VERDICT=o0018
      LANE_DETAIL="O-0018-API-Fehlerbild an $id: $(printf '%s' "$err_line" | cut -c1-100) - nicht automatisch angestossen, Erstbefund bei Firstmate"
    fi
    return 0
  fi
  rm -f "$STATE/.anstoss-o0018-$id"

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
  return 0
}

run_ladder() {  # <id> <detail> ; reads CAPTURE_TEXT from classify_lane
  local id=$1 detail=$2 now count last fp stored_fp min_spaced
  now=$(date +%s)
  count=$(cat "$STATE/.anstoss-count-$id" 2>/dev/null || echo 0)
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  last=$(cat "$STATE/.anstoss-last-$id" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  fp=$(situation_fingerprint "$(last_status_line "$STATE/$id.status")" "${CAPTURE_TEXT:-}")

  if [ "$count" -eq 0 ]; then
    # Spacing guard after a refutation (L34): stay quiet until the doubled
    # interval has passed since the last contact with this lane.
    [ "$((now - last))" -ge "$(effective_interval "$id")" ] || return 0
    if FM_HOME="$FM_HOME" "$SEND_BIN" "$id" "$(stage1_nudge_message "$id" 1 "$detail")" >/dev/null 2>&1; then
      printf '1\n' > "$STATE/.anstoss-count-$id"
      printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
      printf '%s\n' "$fp" > "$STATE/.anstoss-fp-$id"
    fi
    return 0
  fi

  # Stage 2 territory: a previous nudge exists. Escalate only when the
  # situation is byte-identical to the one the last nudge addressed and the
  # spacing interval has passed.
  stored_fp=$(cat "$STATE/.anstoss-fp-$id" 2>/dev/null || true)
  min_spaced=$((now - last))
  if [ "$fp" = "$stored_fp" ] && [ "$min_spaced" -ge "$(effective_interval "$id")" ]; then
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE/.anstoss-count-$id"
    printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
    printf 'anstoss: Bahn %s steht unveraendert still (%d. Anstoss wirkungslos, Zustand seit %d min unveraendert) - Weckruf an Firstmate: Neustart-Entscheid faellen\n' \
      "$id" "$count" "$((min_spaced / 60))"
    return 0
  fi

  # Situation changed since the last nudge: record the new fingerprint so the
  # next unchanged cycle can escalate against the CURRENT state, and let the
  # spacing clock restart from now.
  if [ "$fp" != "$stored_fp" ]; then
    printf '%s\n' "$fp" > "$STATE/.anstoss-fp-$id"
    printf '%s\n' "$now" > "$STATE/.anstoss-last-$id"
  fi
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
    classify_lane "$id" "$meta" || true
    case "$LANE_VERDICT" in
      standing)
        # Reuse the classification capture for the ladder fingerprint.
        run_ladder "$id" "$LANE_DETAIL"
        ;;
      o0018)
        printf '%s\n' "$LANE_DETAIL"
        ;;
    esac
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
      count | last | fp | backoff | o0018) ;;
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
