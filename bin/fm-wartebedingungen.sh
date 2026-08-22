#!/usr/bin/env bash
# fm-wartebedingungen.sh - check the home's waiting backlog entries against the
# outside world, so an entry whose condition was met days ago cannot keep being
# presented as open just because nobody looked.
#
# Usage:
#   fm-wartebedingungen.sh [check]    report entries whose wait is over (silent otherwise)
#   fm-wartebedingungen.sh report     print every scanned entry and its verdict
#   fm-wartebedingungen.sh probe <art> [args...]   evaluate one condition and exit
#   fm-wartebedingungen.sh arm        write and register state/wartebedingungen.check.sh
#   fm-wartebedingungen.sh disarm     remove the check shim, its trust binding, and the record
#   fm-wartebedingungen.sh --help     print this help
#
# WHY. A held or externally waiting entry carries its truth OUTSIDE firstmate: a
# pull request's state at the forge, an account or payment state, a rolled-out
# service, an answer someone else has to send. Discipline alone re-checks that
# truth only when somebody happens to present the entry, which is exactly when a
# long-resolved condition gets quoted as still open. This check moves that
# re-reading to the machine: it runs on the watcher's ordinary check cadence,
# probes each deposited condition read-only, and wakes firstmate when reality has
# already satisfied one. It never closes an entry - firstmate closes it, with the
# evidence the wake carried.
#
# DEPOSIT FORM. A condition is one line in a backlog entry's note body, indented
# like every other body line:
#
#   wartet-auf: <art> [argumente...]
#
# The probe kinds, and what each of them treats as "the wait is over":
#
#   pr-merged <url>
#       The pull request or merge request is merged at the forge. The URL is
#       parsed and the state read through bin/fm-pr-poll.sh, which is this
#       repo's single owner of that lookup for both GitHub and GitLab, so a
#       failed or unreadable lookup can never be read as a merge.
#   gh-runs-green <owner/repo> [<seit YYYY-MM-DD>]
#       The newest workflow run of the repository has actually STARTED and
#       concluded successfully - and, with the optional date, started on or
#       after it. Starting is half the condition on purpose: a stopped account
#       does not fail runs, it stops them from being created at all, so "the
#       newest run is green" alone would keep reporting a pre-outage success.
#   url-status <url> <erwarteter-code>
#       An https GET answers with exactly that status code. This is how a
#       rollout is asked about rather than remembered.
#   datum <YYYY-MM-DD>
#       Today is on or after that date. A date gate keeps an entry out of the
#       dispatchable queue but wakes nobody when it lapses; this does.
#   cmd <einzeiliges lesendes Kommando>
#       A one-line reading command; exit 0 means the wait is over, exit 1 means
#       it is not, anything else is a failed probe. This is the extension point
#       for a condition no built-in kind covers.
#   unpruefbar <grund>
#       No reading probe exists for this wait, and that is recorded rather than
#       left to memory. Deliberately silent, and the reason is what a later
#       reader needs to judge whether a probe has become possible.
#
# An entry may carry several lines; the entry is reported as soon as any one of
# them is met, each with its own evidence. An entry with no line at all is
# scanned too: an entry declared as waiting on the outside (hold kind
# "external") but carrying no condition is reported once as a risk marker, so
# the gap is visible without every old entry having to be retrofitted first.
#
# `probe <art> [args...]` evaluates one condition by hand and exits 0 met, 1 still
# waiting, 2 probe failed. Use it to check a condition before depositing it, and
# to re-verify a forge probe against the real service after a CLI upgrade, which
# the stubbed regressions in tests/ deliberately cannot do.
#
# READ-ONLY, AND NEVER A SHELL SURPRISE. Every built-in probe reads; none of them
# writes, retries, repairs, or closes anything. The cmd kind is the one that runs
# text out of the backlog, so it is gated on the same trust mechanic that governs
# every custom watcher check: a cmd probe runs only while
# state/wartebedingungen.check.sh is bound to its current bytes by
# bin/fm-check-register.sh. Unbound, the cmd probe is refused and REPORTED as
# refused rather than skipped quietly, because a silently skipped probe is the
# failure this check exists to end.
#
# NO NAGGING, NO SILENCE. state/.wartebedingungen records the exact finding set
# the last report was made from, so one unhandled finding is reported once
# instead of on every poll, while a new, changed, or returning finding is news
# again. A probe that keeps failing is reported as a failed probe; it is never
# counted as "not yet met", because that is how a dead detector would go quiet.
#
# The sweep must finish inside FM_CHECK_TIMEOUT (default 30), because a check the
# watcher kills prints nothing and records nothing, and would then repeat that
# silence on every poll. So FM_WARTE_BUDGET_SECS is cut down to what fits rather
# than being refused, and the cut is reported. Cadence, per-probe and sweep
# bounds, and their valid ranges are documented in docs/configuration.md.
set -u
export LC_ALL=C
# A forge probe must never stop to ask for credentials; an unauthenticated read
# has to fail inside its bound instead of waiting for an answer.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
RECORD="$STATE/.wartebedingungen"
CHECK_ID=wartebedingungen
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
PR_POLL_BIN="$SCRIPT_DIR/fm-pr-poll.sh"
RECORD_SCHEMA=fm-wartebedingungen-v1
# One finding names a task id and its evidence, which can be a URL plus a run id
# and a timestamp; wider than the digest default for that reason.
MAX_LINE=300
# The whole report reaches firstmate as one wake payload, so the number of
# findings carried at once is bounded and the remainder is disclosed by count.
MAX_FINDINGS=12

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-wartebedingungen.sh [check]   report waiting entries whose condition is already met (silent otherwise)
  fm-wartebedingungen.sh report    print every scanned entry with its condition and verdict
  fm-wartebedingungen.sh probe <art> [args...]
                                   evaluate one condition: 0 met, 1 still waiting, 2 probe failed
  fm-wartebedingungen.sh arm       write and register state/wartebedingungen.check.sh
  fm-wartebedingungen.sh disarm    remove the check shim, its trust binding, and the record
  fm-wartebedingungen.sh --help    print this help

Conditions are deposited as "wartet-auf: <art> [argumente...]" lines in a backlog
entry's note body. Probe kinds: pr-merged, gh-runs-green, url-status, datum, cmd,
unpruefbar. See this script's header for what each kind treats as met, and
docs/configuration.md for cadence and bounds.
EOF
}

die_usage() {
  printf 'fm-wartebedingungen: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- bounds -----------------------------------------------------------------

INTERVAL=${FM_WARTE_INTERVAL:-900}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-wartebedingungen: FM_WARTE_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  printf 'fm-wartebedingungen: FM_WARTE_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
  exit 2
fi

PROBE_SECS=${FM_WARTE_PROBE_SECS:-5}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-wartebedingungen: FM_WARTE_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  printf 'fm-wartebedingungen: FM_WARTE_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_WARTE_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-wartebedingungen: FM_WARTE_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  printf 'fm-wartebedingungen: FM_WARTE_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

# The smallest bound a probe can be given, because fm_run_timed treats a
# non-positive bound as no bound.
PROBE_MIN_SECS=1
# Both clocks count whole seconds, so a probe can start when the arithmetic says
# a second is left while almost none of it really is, and still get a full bound.
CLOCK_ROUNDING_SECS=1
# fm_run_timed asks its runner for -k 1, so a probe that ignores TERM is only
# killed a second after its bound.
KILL_GRACE_SECS=1

# The watcher's per check bound, read from this check's own environment, so an
# operator who raised it is seen here too and an unset value resolves to the same
# default on both sides.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
# Cut rather than refuse: a refusal would be reported once and then suppressed by
# the no-nag gate, which is exactly a dead, quiet detector.
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

# --- small helpers ----------------------------------------------------------

# The record epoch is overridable so a test can drive the cadence gate; the sweep
# budget always uses real time so a frozen epoch cannot disable it.
record_epoch_now() {
  case "${FM_WARTE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_WARTE_NOW" ;;
  esac
}

real_epoch() { date +%s; }

today() {
  case "${FM_WARTE_TODAY:-}" in
    '') date +%F ;;
    *) printf '%s\n' "$FM_WARTE_TODAY" ;;
  esac
}

DEADLINE=0

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

# What one probe may be given: never more than the sweep has left, never less
# than fm_run_timed can act on.
probe_bound() {
  local left
  left=$((DEADLINE - $(real_epoch)))
  [ "$left" -lt "$PROBE_SECS" ] && PROBE_BOUND=$left || PROBE_BOUND=$PROBE_SECS
  [ "$PROBE_BOUND" -ge "$PROBE_MIN_SECS" ] || PROBE_BOUND=$PROBE_MIN_SECS
}
PROBE_BOUND=$PROBE_MIN_SECS

# --- backlog parsing --------------------------------------------------------
#
# The markdown backlog is read directly rather than through tasks-axi, because
# the schema this needs is the note body and tasks-axi's listing truncates it,
# and because the check must still work in a home whose backlog backend is set
# to manual. .tasks.toml pins the markdown backend and its path; this reads the
# same file.
#
# An entry is one "- [ ] <id> - ..." line plus every indented line under it.

ENTRY_IDS=()
ENTRY_EXTERNAL=()
ENTRY_SPECS=()
SPEC_SEP=$'\x1f'

parse_reset() {
  ENTRY_IDS=()
  ENTRY_EXTERNAL=()
  ENTRY_SPECS=()
}

# Whether an entry declares a wait on something outside firstmate, which is what
# makes a missing condition worth reporting. Hold kind "external" is the
# machine-readable declaration and is taken at its word. An untyped hold is read
# from its reason, because a hold that says in so many words that it is waiting
# for something is the same risk whether or not anyone typed the kind. The other
# kinds are deliberately excluded: "future" and "captain" are firstmate's own
# dated or owned waits, and "parked" and "load" are not waits on the world at all.
entry_waits_outside() {
  local line=$1 reason
  case "$line" in
    *'(hold-kind: external)'*) printf '%s\n' 1; return 0 ;;
    *'(hold-kind: '*) printf '%s\n' 0; return 0 ;;
  esac
  if [[ "$line" =~ \(hold:\ ([^\)]*)\) ]]; then
    reason=${BASH_REMATCH[1]}
    if [[ "$reason" =~ [Ww]arte(t|n|)[[:space:]]+auf ]] || [[ "$reason" =~ [Aa]waiting ]]; then
      printf '%s\n' 1
      return 0
    fi
  fi
  printf '%s\n' 0
}

backlog_parse() {
  local line id external specs open_id open_external open_specs
  parse_reset
  [ -f "$BACKLOG" ] || return 1
  open_id=
  open_external=0
  open_specs=
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^-\ \[([\ xX])\]\ ([A-Za-z0-9][A-Za-z0-9._-]*)\ -\  ]]; then
      [ -z "$open_id" ] || parse_flush "$open_id" "$open_external" "$open_specs"
      open_id=
      open_external=0
      open_specs=
      # A done entry waits on nothing; it is skipped whole, body included.
      [ "${BASH_REMATCH[1]}" = ' ' ] || continue
      id=${BASH_REMATCH[2]}
      external=$(entry_waits_outside "$line")
      open_id=$id
      open_external=$external
      continue
    fi
    case "$line" in
      '#'*|'- '*|'* '*)
        # A heading or an unrelated list item ends the entry above it.
        [ -z "$open_id" ] || parse_flush "$open_id" "$open_external" "$open_specs"
        open_id=
        open_external=0
        open_specs=
        continue
        ;;
    esac
    [ -n "$open_id" ] || continue
    if [[ "$line" =~ ^[[:space:]]+wartet-auf:[[:space:]]*(.*)$ ]]; then
      specs=${BASH_REMATCH[1]}
      specs=${specs%"${specs##*[![:space:]]}"}
      [ -n "$specs" ] || specs='(leer)'
      if [ -z "$open_specs" ]; then
        open_specs=$specs
      else
        open_specs="$open_specs$SPEC_SEP$specs"
      fi
    fi
  done < "$BACKLOG"
  [ -z "$open_id" ] || parse_flush "$open_id" "$open_external" "$open_specs"
  return 0
}

# An entry is kept when it carries a condition - wherever it sits, because the
# entry that got mis-steered while its pull request was already merged was in
# flight, not held - or when it declares an external wait and carries none.
parse_flush() {
  local id=$1 external=$2 specs=$3
  if [ -z "$specs" ] && [ "$external" != 1 ]; then
    return 0
  fi
  ENTRY_IDS+=("$id")
  ENTRY_EXTERNAL+=("$external")
  ENTRY_SPECS+=("$specs")
}

# --- probes -----------------------------------------------------------------
#
# Every probe answers exactly one question and says how it knows:
#   PROBE_STATE=met       the wait is over; PROBE_DETAIL carries the evidence
#   PROBE_STATE=open      still waiting
#   PROBE_STATE=accepted  no reading probe exists and that was recorded
#   PROBE_STATE=error     the probe could not answer; PROBE_DETAIL says why
# "error" is never folded into "open": a probe that cannot answer is a finding.

PROBE_STATE=error
PROBE_DETAIL=

probe_pr_merged() {
  local url=${1-} out rc
  if [ "$#" -ne 1 ] || [ -z "$url" ]; then
    PROBE_STATE=error
    PROBE_DETAIL='pr-merged braucht genau eine URL'
    return 0
  fi
  if ! fm_pr_url_parse "$url"; then
    PROBE_STATE=error
    PROBE_DETAIL="keine gueltige PR/MR-URL: $url"
    return 0
  fi
  if [ ! -f "$PR_POLL_BIN" ]; then
    PROBE_STATE=error
    PROBE_DETAIL='PR-Abfrage nicht verfuegbar'
    return 0
  fi
  probe_bound
  out=$(fm_run_timed "$PROBE_BOUND" "$PR_POLL_BIN" --validated \
    "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    PROBE_STATE=error
    PROBE_DETAIL="PR-Abfrage zeitueberschritten: $url"
    return 0
  fi
  if [ "$out" = merged ]; then
    PROBE_STATE=met
    PROBE_DETAIL="am Forge als gemergt gemeldet: $url"
    return 0
  fi
  # The poll is silent on every error by design, so an unreadable lookup is
  # indistinguishable from an open request here and stays "open" rather than
  # ever being reported as a merge.
  PROBE_STATE=open
  PROBE_DETAIL="noch nicht gemergt: $url"
}

probe_gh_runs_green() {
  local repo=${1-} since=${2-} out rc status conclusion created id
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$repo" ]; then
    PROBE_STATE=error
    PROBE_DETAIL='gh-runs-green braucht <owner/repo> und optional ein Datum'
    return 0
  fi
  if ! [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]]; then
    PROBE_STATE=error
    PROBE_DETAIL="kein gueltiges owner/repo: $repo"
    return 0
  fi
  if [ -n "$since" ] && ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    PROBE_STATE=error
    PROBE_DETAIL="kein gueltiges Datum: $since"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    PROBE_STATE=error
    PROBE_DETAIL='gh ist nicht installiert'
    return 0
  fi
  probe_bound
  out=$(fm_run_timed "$PROBE_BOUND" gh api \
    "repos/$repo/actions/runs?per_page=1" \
    --jq '.workflow_runs[0] | "\(.id) \(.status) \(.conclusion) \(.created_at)"' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    PROBE_STATE=error
    PROBE_DETAIL="Laufabfrage fehlgeschlagen: $repo"
    return 0
  fi
  read -r id status conclusion created <<< "$out"
  if [ -z "$id" ] || [ "$id" = null ]; then
    # No run has ever been created. That is the stopped-account shape itself,
    # not a green pipeline, so it stays waiting rather than passing.
    PROBE_STATE=open
    PROBE_DETAIL="kein Lauf vorhanden: $repo"
    return 0
  fi
  if [ "$status" != completed ] || [ "$conclusion" != success ]; then
    PROBE_STATE=open
    PROBE_DETAIL="juengster Lauf $id: $status/$conclusion"
    return 0
  fi
  if [ -n "$since" ] && [ "${created%%T*}" \< "$since" ]; then
    PROBE_STATE=open
    PROBE_DETAIL="juengster gruener Lauf $id stammt von $created, vor $since"
    return 0
  fi
  PROBE_STATE=met
  PROBE_DETAIL="juengster Lauf $id gestartet $created und gruen: $repo"
}

probe_url_status() {
  local url=${1-} want=${2-} out rc
  if [ "$#" -ne 2 ] || [ -z "$url" ]; then
    PROBE_STATE=error
    PROBE_DETAIL='url-status braucht <url> und <erwarteten code>'
    return 0
  fi
  case "$url" in
    https://*) ;;
    *)
      PROBE_STATE=error
      PROBE_DETAIL="url-status verlangt eine https-URL: $url"
      return 0
      ;;
  esac
  case "$url" in
    *[[:space:]]*)
      PROBE_STATE=error
      PROBE_DETAIL='url-status vertraegt keine Leerzeichen in der URL'
      return 0
      ;;
  esac
  if ! [[ "$want" =~ ^[1-5][0-9][0-9]$ ]]; then
    PROBE_STATE=error
    PROBE_DETAIL="kein gueltiger HTTP-Code: $want"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    PROBE_STATE=error
    PROBE_DETAIL='curl ist nicht installiert'
    return 0
  fi
  probe_bound
  out=$(fm_run_timed "$PROBE_BOUND" curl -sS -o /dev/null -L \
    --max-time "$PROBE_BOUND" -w '%{http_code}' "$url" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || ! [[ "$out" =~ ^[0-9]{3}$ ]]; then
    PROBE_STATE=error
    PROBE_DETAIL="keine Antwort von $url"
    return 0
  fi
  if [ "$out" = "$want" ]; then
    PROBE_STATE=met
    PROBE_DETAIL="HTTP $out von $url"
    return 0
  fi
  PROBE_STATE=open
  PROBE_DETAIL="HTTP $out statt $want von $url"
}

probe_datum() {
  local want=${1-} now
  if [ "$#" -ne 1 ] || ! [[ "$want" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    PROBE_STATE=error
    PROBE_DETAIL='datum braucht genau ein YYYY-MM-DD'
    return 0
  fi
  now=$(today)
  if [ "$now" \< "$want" ]; then
    PROBE_STATE=open
    PROBE_DETAIL="Zeitfenster ab $want, heute ist $now"
    return 0
  fi
  PROBE_STATE=met
  PROBE_DETAIL="Zeitfenster ab $want ist offen, heute ist $now"
}

# The one probe that runs text out of the backlog, and therefore the one gated on
# this check being bound to its current bytes. Unbound it is refused OUT LOUD:
# a quietly skipped probe would leave the entry looking checked.
probe_cmd() {
  local cmd=$* out rc
  if [ -z "${cmd//[[:space:]]/}" ]; then
    PROBE_STATE=error
    PROBE_DETAIL='cmd braucht ein Kommando'
    return 0
  fi
  if ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    PROBE_STATE=error
    PROBE_DETAIL='cmd-Probe laeuft nur mit gebundenem Check (bin/fm-check-register.sh)'
    return 0
  fi
  probe_bound
  out=$(fm_run_timed "$PROBE_BOUND" bash -c "$cmd" 2>/dev/null)
  rc=$?
  case "$rc" in
    0)
      PROBE_STATE=met
      out=$(printf '%s' "$out" | head -1)
      [ -n "$out" ] || out='Kommando meldet erfuellt'
      PROBE_DETAIL="$out"
      ;;
    1)
      PROBE_STATE=open
      PROBE_DETAIL='Kommando meldet noch nicht erfuellt'
      ;;
    124)
      PROBE_STATE=error
      PROBE_DETAIL='Kommando zeitueberschritten'
      ;;
    *)
      PROBE_STATE=error
      PROBE_DETAIL="Kommando endete mit $rc"
      ;;
  esac
}

# probe_run_spec takes one deposited line and hands its fields to probe_run.
# The split happens here and only here: the fields are read into an array rather
# than left to the shell's own word splitting, so nothing a backlog note contains
# is expanded as a path pattern on the way in. A cmd condition keeps its
# remainder verbatim as one argument, because collapsing its spacing would change
# the command that runs.
probe_run_spec() {
  local spec=$1 art rest
  local -a args=()
  art=${spec%%[[:space:]]*}
  if [ "$art" = "$spec" ]; then
    rest=
  else
    rest=${spec#*[[:space:]]}
    rest=${rest#"${rest%%[![:space:]]*}"}
  fi
  if [ "$art" = cmd ]; then
    probe_run cmd "$rest"
    return 0
  fi
  if [ -n "$rest" ]; then
    IFS=$' \t' read -r -a args <<< "$rest"
  fi
  probe_run "$art" ${args[@]+"${args[@]}"}
}

probe_run() {
  local art=${1-}
  PROBE_STATE=error
  PROBE_DETAIL=
  shift || true
  case "$art" in
    pr-merged) probe_pr_merged "$@" ;;
    gh-runs-green) probe_gh_runs_green "$@" ;;
    url-status) probe_url_status "$@" ;;
    datum) probe_datum "$@" ;;
    cmd) probe_cmd "$@" ;;
    unpruefbar)
      PROBE_STATE=accepted
      PROBE_DETAIL=${*:-'kein Grund hinterlegt'}
      ;;
    *)
      PROBE_STATE=error
      PROBE_DETAIL="unbekannte Probenart: ${art:-(leer)}"
      ;;
  esac
}

# --- sweep ------------------------------------------------------------------

FINDINGS=
FINDING_LINES=()
FINDING_OVERFLOW=0

finding_add() {  # <token> <line>
  local token=$1 line=$2
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$token
  else
    FINDINGS="$FINDINGS;$token"
  fi
  if [ "${#FINDING_LINES[@]}" -ge "$MAX_FINDINGS" ]; then
    FINDING_OVERFLOW=$((FINDING_OVERFLOW + 1))
    return 0
  fi
  fm_cap_line_var "$line" "$MAX_LINE"
  FINDING_LINES+=("$FM_LINE_CAP_LINE")
}

# Evaluate every parsed entry. VERBOSE adds the still-waiting and accepted
# verdicts, which the report wants and the check must never print.
VERBOSE=0

sweep() {
  local i id external specs spec rest
  FINDINGS=
  FINDING_LINES=()
  FINDING_OVERFLOW=0
  DEADLINE=$(($(real_epoch) + BUDGET_SECS))
  if [ -n "$BUDGET_CUT_FROM" ]; then
    finding_add "budget-cut" \
      "Wartebedingungen: Zeitbudget ${BUDGET_CUT_FROM}s auf ${BUDGET_SECS}s gekuerzt, damit der Waechter-Zeitrahmen von ${CHECK_TIMEOUT}s haelt"
  fi
  if ! backlog_parse; then
    finding_add "no-backlog" "Wartebedingungen nicht pruefbar: kein Backlog unter $BACKLOG"
    return 0
  fi
  i=0
  while [ "$i" -lt "${#ENTRY_IDS[@]}" ]; do
    id=${ENTRY_IDS[$i]}
    external=${ENTRY_EXTERNAL[$i]}
    specs=${ENTRY_SPECS[$i]}
    i=$((i + 1))
    if [ -z "$specs" ]; then
      # Declared as waiting on the outside with nothing a machine can read.
      if [ "$external" = 1 ]; then
        finding_add "offen:$id" "Bedingung unpruefbar hinterlegt: $id"
      fi
      continue
    fi
    rest=$specs
    while [ -n "$rest" ]; do
      case "$rest" in
        *"$SPEC_SEP"*) spec=${rest%%"$SPEC_SEP"*}; rest=${rest#*"$SPEC_SEP"} ;;
        *) spec=$rest; rest= ;;
      esac
      if budget_exhausted; then
        finding_add "budget:$id" "Wartebedingungen nicht zuende geprueft: ab $id blieb das Zeitbudget aus"
        return 0
      fi
      probe_run_spec "$spec"
      case "$PROBE_STATE" in
        met) finding_add "met:$id" "Bedingung laengst erfuellt: $id - $PROBE_DETAIL" ;;
        error) finding_add "err:$id" "Wartebedingung nicht pruefbar: $id - $PROBE_DETAIL" ;;
        accepted)
          [ "$VERBOSE" = 1 ] && finding_add "ok:$id" "Bewusst unpruefbar: $id - $PROBE_DETAIL"
          ;;
        *)
          [ "$VERBOSE" = 1 ] && finding_add "warte:$id" "Wartet weiter: $id - $PROBE_DETAIL"
          ;;
      esac
    done
  done
  return 0
}

findings_print() {
  local line
  for line in "${FINDING_LINES[@]+"${FINDING_LINES[@]}"}"; do
    printf '%s\n' "$line"
  done
  if [ "$FINDING_OVERFLOW" -gt 0 ]; then
    printf 'und %s weitere Wartebedingungen mit Befund (bin/fm-wartebedingungen.sh report)\n' \
      "$FINDING_OVERFLOW"
  fi
}

# --- no-nag record ----------------------------------------------------------

RECORD_EPOCH=0
RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

action_check() {
  local now
  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$((now - RECORD_EPOCH))" -lt "$INTERVAL" ]; then
    return 0
  fi
  sweep
  if [ "${#FINDING_LINES[@]}" -gt 0 ] && [ "$FINDINGS" != "$RECORD_REPORTED" ]; then
    findings_print
  fi
  record_write "$FINDINGS" || true
  return 0
}

action_report() {
  local i
  VERBOSE=1
  printf 'Backlog: %s\n' "$BACKLOG"
  if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'Check:   state/%s.check.sh ist gebunden und scharf\n' "$CHECK_ID"
  else
    printf 'Check:   state/%s.check.sh ist NICHT gebunden - cmd-Proben werden verweigert\n' "$CHECK_ID"
  fi
  if [ ! -f "$BACKLOG" ]; then
    printf 'Kein Backlog unter %s\n' "$BACKLOG" >&2
    return 1
  fi
  sweep
  printf 'Eintraege im Blick: %s\n' "${#ENTRY_IDS[@]}"
  i=0
  while [ "$i" -lt "${#ENTRY_IDS[@]}" ]; do
    if [ -z "${ENTRY_SPECS[$i]}" ]; then
      printf '  %s: keine wartet-auf-Zeile\n' "${ENTRY_IDS[$i]}"
    else
      printf '  %s: %s\n' "${ENTRY_IDS[$i]}" \
        "$(printf '%s' "${ENTRY_SPECS[$i]}" | tr "$SPEC_SEP" '|')"
    fi
    i=$((i + 1))
  done
  printf 'Befunde:\n'
  if [ "${#FINDING_LINES[@]}" -eq 0 ]; then
    printf '  keine\n'
  else
    findings_print | sed 's/^/  /'
  fi
  return 0
}

action_probe() {
  [ "$#" -ge 1 ] || die_usage 'probe braucht eine Probenart'
  DEADLINE=$(($(real_epoch) + BUDGET_SECS))
  probe_run "$@"
  printf '%s: %s\n' "$PROBE_STATE" "$PROBE_DETAIL"
  case "$PROBE_STATE" in
    met) return 0 ;;
    open|accepted) return 1 ;;
    *) return 2 ;;
  esac
}

# --- arm / disarm -----------------------------------------------------------
#
# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and from a private snapshot copy, so a relative
# spelling would resolve against a different home, or none at all.

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-wartebedingungen.sh - waiting-condition poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-wartebedingungen.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-wartebedingungen-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-wartebedingungen-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the rule after a failed
# or interrupted arm is that the home never holds a shim without a matching trust
# binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-wartebedingungen: arming was interrupted, so state/%s.check.sh is not armed\n' \
    "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -f "$BACKLOG" ]; then
    printf 'fm-wartebedingungen: no backlog at %s\n' "$BACKLOG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-wartebedingungen: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-wartebedingungen: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-wartebedingungen: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-wartebedingungen: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  report) action_report ;;
  probe) shift; action_probe "$@" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
