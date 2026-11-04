#!/usr/bin/env bash
# fm-fleet-stall-check.sh - the registered watcher check that notices the whole
# fleet stalling on its model gateway, and pages the captain when it persists.
#
# Usage:
#   fm-fleet-stall-check.sh [check]   run the poll (silent unless it should wake)
#   fm-fleet-stall-check.sh status    print the last recorded verdict (no capture)
#   fm-fleet-stall-check.sh arm       write state/fleet-stall.check.sh and bind it
#   fm-fleet-stall-check.sh disarm    remove the shim, its trust binding, and the record
#   fm-fleet-stall-check.sh --help    print this help
#
# WHY THIS EXISTS. On 2026-10-18 fifteen workers sat dead from 08:17Z to 13:09Z
# because the local model gateway had no live credential ("auth_unavailable: no
# auth available ... Refresh token expired") and nothing woke firstmate: every
# per-worker signal treats a single idle or erroring worker as that worker's own
# business. A gateway outage is a FLEET event, and only a fleet-wide view sees
# it. This check takes that view on every watcher slow-poll.
#
# ONE OWNER. This check owns the fleet-wide episode and the captain page. The
# per-worker half - a single dead endpoint, one frozen pane, one failed unit -
# is owned by bin/fm-watchdog-worker.sh, which runs off the fleet's own timer
# with no firstmate turn and no watcher poll.
#
# PER WORKER. Every task record in state/*.meta whose endpoint answers a capture
# is a live worker; a capture that fails is a gone endpoint and is not counted.
# A live worker is STALLED for one of two reasons:
#
#   gateway-error  a line among the last 12 non-blank pane lines is an error
#                  line (it starts, after box and gutter glyphs, with "Error",
#                  "API Error", or "Retrying") naming an upstream or gateway
#                  failure: auth_unavailable / no auth available, a refresh
#                  token or invalid_grant, a 5xx or 529 API error, an
#                  api_error / overloaded_error / authentication_error body,
#                  overloaded, connection reset, request timed out, upstream,
#                  ECONNREFUSED, fetch failed, an expired OAuth token or login.
#                  It must hold on GATEWAY_POLLS (2) consecutive polls over a
#                  pane whose text, numbers aside, did not change: a retry
#                  counter ticking is still the same stall, while a worker that
#                  merely printed such a sentence and moved on is not one.
#   no-progress    the worker reads busy (bin/fm-busy-lib.sh) and neither its
#                  token counter (Pi's footer `↑<in> ↓<out>`, Claude Code's
#                  `<n> tokens`) nor its pane text, timers and spinners aside,
#                  has moved for no_progress_secs. Both are required, because a
#                  long silent tool call legitimately holds the counter still.
#
# WAITING IS NOT STALLED. A worker that is waiting on firstmate or on its own
# pipeline is quiet by design, so every worker the rules above flag is read once
# more, through bin/fm-crew-state.sh (bounded, and only for those candidates),
# before it counts (inside what the captures left of the poll budget; a
# candidate whose state could not be read in time counts as flagged). A worker
# that reads parked, paused, blocked, done, or failed
# is excluded, and so is one whose newest status-log event declares
# needs-decision, blocked, or paused: a busy pane makes fm-crew-state report
# working without consulting the log, and that declared wait is exactly what a
# crew parked at a decision leaves behind. A no-progress candidate whose current
# state comes from its no-mistakes run-step is excluded too, because the
# pipeline, not the agent, is doing the work its quiet pane waits on.
#
# THE FLEET. A stall opens an episode when at least min_workers (default 3) live
# workers are stalled at once. The check prints one line on the onset, naming
# every stalled worker and its reason plus the gateway probe below; it reminds
# every remind_secs (default 1800) while the episode holds; once the episode has
# held page_after_secs (default 900) it pages the captain, once per episode; and
# it prints a recovered line when fewer than min_workers remain stalled. The
# page runs the page command from config/fleet-stall.env (see "Paging") and also
# posts a macOS notification; firstmate has been woken by then, so the page is
# for the case where firstmate is itself stalled on the same gateway.
#
# THE GATEWAY PROBE. The local CLIProxyAPI gateway (default
# http://127.0.0.1:8317, auth inventory ~/.cli-proxy-api, log
# ~/.cli-proxy-api/logs/main.log) is probed on every poll, read-only:
#
#   down       the URL gives no HTTP answer within 3s.
#   auth       an enabled auth file whose access token expires within
#              expiry_window_secs (default 1800) and has not been refreshed: it
#              has already expired, or its expiry has stayed in the window with
#              the same value for refresh_grace_secs (default 900, one
#              CLIProxyAPI auto-refresh interval), or the log shows a refresh
#              failure for it within error_window_secs. One condition per
#              account. This file-based rule applies only when no better-ccflare
#              account store is present (below).
#   ccflare    when better-ccflare owns refresh (its account store
#              ~/.config/better-ccflare/better-ccflare.db exists), auth health is
#              read from that store instead, read-only: an anthropic account
#              that is not paused and either requires re-authentication or
#              expires within expiry_window_secs, or no usable account at all
#              (every one paused or needing re-authentication). The access-sync
#              agent that copies ccflare's access tokens into the CLIProxyAPI
#              inventory (log ~/Library/Logs/ccflare-access-sync.log, errors in
#              the .err beside it) is a condition when its log has not moved
#              for access_sync_stale_secs (default 600) or its newest run wrote
#              an error. In this mode the claude-* inventory files (the
#              sync's copies) and CLIProxyAPI's "credential refresh failed"
#              lines for them are ignored: CLIProxyAPI never holds a refresh
#              token ccflare has not rotated, so its invalid_grant warnings are
#              expected noise. Other inventory files keep the file rule.
#   errors     the gateway answered at least error_min (default 30) requests in
#              the last error_window_secs (default 300) and error_rate_pct
#              (default 50) percent or more of them were 5xx or 401; it clears
#              below half of either bound, so a hovering rate does not flap.
#
# Each gateway condition prints on its onset and once more when it clears, and
# rides on a fleet-stall line as the likely cause only when at least one stalled
# worker shows a gateway error: an account that expired hours ago does not
# explain workers that merely stopped moving. A home whose auth
# inventory is absent and whose URL does not answer runs no CLIProxyAPI, which
# is not a condition; FM_FLEET_STALL_PROXY=off disables the probe.
#
# CONFIGURATION. config/fleet-stall.env (gitignored, per-home) holds KEY=value
# lines and is parsed, never sourced. A set environment variable of the same
# name wins. Keys (defaults in parentheses):
#   FM_FLEET_STALL_MIN_WORKERS (3)          FM_FLEET_STALL_NO_PROGRESS_SECS (900)
#   FM_FLEET_STALL_PAGE_AFTER_SECS (900)    FM_FLEET_STALL_REMIND_SECS (1800)
#   FM_FLEET_STALL_PAGE_CMD (none)          FM_FLEET_STALL_PROXY (on)
#   FM_FLEET_STALL_PROXY_URL (http://127.0.0.1:8317)
#   FM_FLEET_STALL_PROXY_AUTH_DIR (~/.cli-proxy-api)
#   FM_FLEET_STALL_PROXY_LOG (<auth dir>/logs/main.log)
#   FM_FLEET_STALL_EXPIRY_WINDOW_SECS (1800) FM_FLEET_STALL_REFRESH_GRACE_SECS (900)
#   FM_FLEET_STALL_ERROR_WINDOW_SECS (300)   FM_FLEET_STALL_ERROR_MIN (30)
#   FM_FLEET_STALL_ERROR_RATE_PCT (50)       FM_FLEET_STALL_CAPTURE_JOBS (16)
#   FM_FLEET_STALL_CCFLARE_DB (~/.config/better-ccflare/better-ccflare.db; empty = file mode)
#   FM_FLEET_STALL_ACCESS_SYNC_LOG (~/Library/Logs/ccflare-access-sync.log; empty = not watched)
#   FM_FLEET_STALL_ACCESS_SYNC_STALE_SECS (600)
#
# Paging. FM_FLEET_STALL_PAGE_CMD is a shell command run with the page text as
# both $1 and stdin, bounded at 20 seconds; point it at whatever reaches the
# captain's phone (a Slack bot DM, ntfy, SMS). With none configured the onset
# line says so, and the macOS notification is the only page.
#
# RECORD. state/.fleet-stall.json holds each worker's last token signature and
# pane hashes with the time each last moved, the open episode, the gateway
# conditions, and the auth expiries in the window, stamped with its schema; a
# record with another stamp is treated as no record at all.
#
# BOUNDED. The whole poll - captures, current-state reads, and the verdict - is
# budgeted at half the watcher's FM_CHECK_TIMEOUT, at most 15 seconds, so it ends
# well inside it even on a loaded machine: the watcher runs every check one after
# another, and a check that spends most of its timeout on every sweep is what
# kept its beacon from advancing. Captures run FM_FLEET_STALL_CAPTURE_JOBS at a
# time and stop at two thirds of the budget; a worker not captured in time is
# simply not counted (it keeps its history, and the next poll may reach it). The
# current-state reads get what the captures left, less a reserve for the verdict,
# at most 4 seconds, and are skipped when under 2 seconds remain. The macOS
# notification never waits, and a page command gets what is left of
# FM_CHECK_TIMEOUT less a 3-second margin.
#
# Test seams: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_FLEET_STALL_NOW (frozen
# clock), FM_FLEET_STALL_CREW_STATE_BIN (the current-state reader, default
# bin/fm-crew-state.sh), and FM_FLEET_STALL_CAPTURE_DIR, a directory of <id>.cap pane texts and
# <id>.busy verdicts used instead of live captures (a missing .cap is a gone
# endpoint). osascript is resolved from PATH.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENV_FILE="$CONFIG_DIR/fleet-stall.env"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

CHECK_ID='fleet-stall'
RECORD="$STATE/.fleet-stall.json"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
# The whole poll, captures and current-state reads together, ends inside this:
# half the watcher's per-check timeout, at most 15 seconds.
CHECK_TIMEOUT_SECS=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT_SECS" in ''|*[!0-9]*) CHECK_TIMEOUT_SECS=30 ;; esac
POLL_BUDGET_SECS=$((CHECK_TIMEOUT_SECS / 2))
[ "$POLL_BUDGET_SECS" -le 15 ] || POLL_BUDGET_SECS=15
[ "$POLL_BUDGET_SECS" -ge 3 ] || POLL_BUDGET_SECS=3
CAPTURE_DEADLINE_SECS=$((POLL_BUDGET_SECS * 2 / 3))
# Seconds kept back from the current-state reads for the verdict engine.
ENGINE_RESERVE_SECS=2
MAX_LINE=1500

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

now_epoch() {
  case "${FM_FLEET_STALL_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FLEET_STALL_NOW" ;;
  esac
}

# conf <KEY> <default>: a set environment variable, else the env file's value,
# else the default. The file is parsed line by line and never sourced.
conf() {
  local key=$1 default=$2 line value='' found=0
  eval "value=\${$key:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*)
          value=${line#*=}
          case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
          esac
          found=1
          ;;
      esac
    done < "$ENV_FILE"
  fi
  if [ "$found" = 1 ] && [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

conf_int() {  # <KEY> <default>
  local v
  v=$(conf "$1" "$2")
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s\n' "$v"
}

# capture_one <id> <backend> <target> <harness> <out-dir>: the pane tail and
# busy verdict of one worker, written as <id>.cap and <id>.busy; nothing at all
# for a gone endpoint.
capture_one() {
  local id=$1 backend=$2 target=$3 harness=$4 out=$5 text busy
  [ -n "$target" ] || return 0
  text=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 0
  [ -n "$text" ] || return 0
  busy=$(fm_busy_classify "$backend" "$target" "$harness" "$id" "$STATE" "$text" 2>/dev/null) || busy='unknown error'
  printf '%s\n' "${busy%% *}" > "$out/$id.busy"
  printf '%s\n' "$text" > "$out/$id.cap.tmp" && mv -f "$out/$id.cap.tmp" "$out/$id.cap"
}

# ordered_metas: every task record worth capturing, quietest first. An Orca
# home answers one `orca terminal list` for the whole fleet, so a record whose
# terminal Orca no longer lists is a gone endpoint and costs no read at all,
# and the rest are read in order of their last output, oldest first: a worker
# stopped on an error has gone quiet, so it is read early even when the
# deadline cuts the pass short. Other backends keep record order.
ordered_metas() {
  local list=''
  if grep -l '^backend=orca$' "$STATE"/*.meta >/dev/null 2>&1 && command -v orca >/dev/null 2>&1; then
    list=$(fm_run_timed 5 orca terminal list --json --limit 1000 2>/dev/null) || list=''
  fi
  FS_STATE="$STATE" FS_ORCA_LIST="$list" python3 - <<'PY'
import glob
import json
import os

orca = None
raw = os.environ.get("FS_ORCA_LIST", "")
if raw:
    try:
        data = json.loads(raw)
        rows = data.get("result", data) if isinstance(data, dict) else data
        if isinstance(rows, dict):
            rows = rows.get("terminals")
        if isinstance(rows, list):
            orca = {}
            for row in rows:
                if isinstance(row, dict) and row.get("handle"):
                    try:
                        orca[row["handle"]] = int(row.get("lastOutputAt") or 0)
                    except (TypeError, ValueError):
                        orca[row["handle"]] = 0
    except ValueError:
        orca = None
quiet, rest = [], []
for meta in sorted(glob.glob(os.path.join(os.environ["FS_STATE"], "*.meta"))):
    if os.path.islink(meta) or not os.path.isfile(meta):
        continue
    fields = {}
    try:
        with open(meta, errors="replace") as f:
            for line in f:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    fields[key] = value
    except OSError:
        continue
    if fields.get("backend") == "orca" and orca is not None:
        handle = fields.get("terminal", "")
        if handle not in orca:
            continue
        quiet.append((orca[handle], meta, fields))
    else:
        rest.append((meta, fields))
def emit(meta, fields):
    backend = fields.get("backend") or "tmux"
    if backend == "orca":
        target = fields.get("terminal") or fields.get("window", "")
    else:
        target = fields.get("window", "")
    if not target or "\t" in target:
        return
    wid = os.path.basename(meta)[:-5]
    print("\t".join((wid, backend, target, fields.get("harness", ""))))


for _, meta, fields in sorted(quiet, key=lambda q: (q[0], q[1])):
    emit(meta, fields)
for meta, fields in rest:
    emit(meta, fields)
PY
}

# capture_all <out-dir>: the ordered task records, a bounded number at a time,
# inside one overall deadline. Portable to bash 3.2 (no `wait -n`).
capture_all() {
  local out=$1 jobs deadline id backend target harness pid alive
  local -a pids=()
  jobs=$(conf_int FM_FLEET_STALL_CAPTURE_JOBS 16)
  [ "$jobs" -ge 1 ] || jobs=1
  deadline=$((SECONDS + CAPTURE_DEADLINE_SECS))
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 0
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh" || return 0
  while IFS=$'\t' read -r id backend target harness; do
    [ -n "$id" ] || continue
    while :; do
      alive=0
      for pid in "${pids[@]:-}"; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
      done
      [ "$alive" -ge "$jobs" ] || break
      [ "$SECONDS" -lt "$deadline" ] || break 2
      sleep 0.05
    done
    capture_one "$id" "$backend" "$target" "$harness" "$out" &
    pids+=("$!")
  done <<EOF
$(ordered_metas)
EOF
  while [ "$SECONDS" -lt "$deadline" ]; do
    alive=0
    for pid in "${pids[@]:-}"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1 && break
    done
    [ "$alive" = 1 ] || break
    sleep 0.05
  done
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  wait 2>/dev/null || true
  rm -f "$out"/*.tmp 2>/dev/null || true
}

# crew_states <capture-dir> <ids>: the current state of each stall candidate,
# written as <id>.crew, all at once and inside one bound. A reader that times
# out leaves no file, and the candidate then counts as it would have.
crew_states() {
  local dir=$1 ids=$2 bin id bound
  bin=${FM_FLEET_STALL_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
  [ -n "$ids" ] && [ -x "$bin" ] || return 0
  # What the captures left of the poll budget, less the verdict's reserve, at
  # most 4 seconds.
  bound=$((POLL_BUDGET_SECS - ENGINE_RESERVE_SECS - SECONDS))
  [ "$bound" -le 4 ] || bound=4
  [ "$bound" -ge 2 ] || return 0
  for id in $ids; do
    (
      FM_CREW_STATE_NM_TIMEOUT=4 fm_run_timed "$bound" "$bin" "$id" > "$dir/$id.crew.tmp" 2>/dev/null \
        && mv -f "$dir/$id.crew.tmp" "$dir/$id.crew"
      rm -f "$dir/$id.crew.tmp"
    ) &
  done
  wait 2>/dev/null || true
}

# The notification is fire-and-forget: it is detached so the poll never waits on
# it.
notify_macos() {  # <text>
  command -v osascript >/dev/null 2>&1 || return 0
  ( fm_run_timed 10 osascript -e \
    "display notification \"$(printf '%s' "$1" | tr -d '"\134' | cut -c1-200)\" with title \"Firstmate: fleet stalled\" sound name \"Submarine\"" \
    >/dev/null 2>&1 & ) || true
}

page() {  # <text>
  local text=$1 cmd bound
  notify_macos "$text"
  cmd=$(conf FM_FLEET_STALL_PAGE_CMD '')
  [ -n "$cmd" ] || return 1
  # What is left of the watcher's per-check timeout, less a 3-second margin.
  bound=$((CHECK_TIMEOUT_SECS - 3 - SECONDS))
  [ "$bound" -le 20 ] || bound=20
  [ "$bound" -ge 2 ] || return 1
  fm_run_timed "$bound" sh -c "$cmd" fm-fleet-stall "$text" <<< "$text" >/dev/null 2>&1
}

run_engine() {  # <action> <capture-dir>
  local action=$1 dir=$2 auth_dir
  auth_dir=$(conf FM_FLEET_STALL_PROXY_AUTH_DIR "$HOME/.cli-proxy-api")
  FS_ACTION="$action" FS_DIR="$dir" FS_RECORD="$RECORD" FS_STATE="$STATE" \
  FS_NOW="$(now_epoch)" \
  FS_MIN_WORKERS="$(conf_int FM_FLEET_STALL_MIN_WORKERS 3)" \
  FS_NO_PROGRESS_SECS="$(conf_int FM_FLEET_STALL_NO_PROGRESS_SECS 900)" \
  FS_PAGE_AFTER_SECS="$(conf_int FM_FLEET_STALL_PAGE_AFTER_SECS 900)" \
  FS_REMIND_SECS="$(conf_int FM_FLEET_STALL_REMIND_SECS 1800)" \
  FS_PAGE_CONFIGURED="$( [ -n "$(conf FM_FLEET_STALL_PAGE_CMD '')" ] && echo 1 || echo 0)" \
  FS_PROXY="$(conf FM_FLEET_STALL_PROXY on)" \
  FS_PROXY_URL="$(conf FM_FLEET_STALL_PROXY_URL http://127.0.0.1:8317)" \
  FS_PROXY_AUTH_DIR="$auth_dir" \
  FS_PROXY_LOG="$(conf FM_FLEET_STALL_PROXY_LOG "$auth_dir/logs/main.log")" \
  FS_EXPIRY_WINDOW_SECS="$(conf_int FM_FLEET_STALL_EXPIRY_WINDOW_SECS 1800)" \
  FS_REFRESH_GRACE_SECS="$(conf_int FM_FLEET_STALL_REFRESH_GRACE_SECS 900)" \
  FS_ERROR_WINDOW_SECS="$(conf_int FM_FLEET_STALL_ERROR_WINDOW_SECS 300)" \
  FS_ERROR_MIN="$(conf_int FM_FLEET_STALL_ERROR_MIN 30)" \
  FS_ERROR_RATE_PCT="$(conf_int FM_FLEET_STALL_ERROR_RATE_PCT 50)" \
  FS_CCFLARE_DB="$(conf FM_FLEET_STALL_CCFLARE_DB "$HOME/.config/better-ccflare/better-ccflare.db")" \
  FS_ACCESS_SYNC_LOG="$(conf FM_FLEET_STALL_ACCESS_SYNC_LOG "$HOME/Library/Logs/ccflare-access-sync.log")" \
  FS_ACCESS_SYNC_STALE_SECS="$(conf_int FM_FLEET_STALL_ACCESS_SYNC_STALE_SECS 600)" \
  python3 - <<'PY'
import datetime
import glob
import hashlib
import json
import os
import re
import sqlite3
import time
import urllib.error
import urllib.request

SCHEMA = "fm-fleet-stall-v1"
GATEWAY_POLLS = 2
E = os.environ
ACTION = E["FS_ACTION"]
DIR = E["FS_DIR"]
RECORD = E["FS_RECORD"]
NOW = int(E["FS_NOW"])


def ival(name):
    try:
        return int(E.get(name, "0"))
    except ValueError:
        return 0


MIN_WORKERS = max(1, ival("FS_MIN_WORKERS"))
NO_PROGRESS = ival("FS_NO_PROGRESS_SECS")
PAGE_AFTER = ival("FS_PAGE_AFTER_SECS")
REMIND = ival("FS_REMIND_SECS")
EXPIRY_WINDOW = ival("FS_EXPIRY_WINDOW_SECS")
REFRESH_GRACE = ival("FS_REFRESH_GRACE_SECS")
ERROR_WINDOW = ival("FS_ERROR_WINDOW_SECS")
ERROR_MIN = ival("FS_ERROR_MIN")
ERROR_RATE = ival("FS_ERROR_RATE_PCT")

# An error line: after gutter and box glyphs it starts with one of these.
ERROR_LEAD = re.compile(r"^[\s│┃|⎿●•✗✘×⚠!>*-]*(?:api\s+error\b|error\b|retrying\b)", re.I)
GATEWAY = re.compile(
    r"auth_unavailable|no auth available|refresh token|invalid_grant|"
    r"api error:?\s*5\d\d|\b5\d\d\s*\{\s*\"type\"\s*:\s*\"error\"|"
    r"\"type\"\s*:\s*\"(?:api_error|overloaded_error|authentication_error)\"|"
    r"overloaded|connection reset|request timed out|upstream|econnrefused|"
    r"fetch failed|oauth token has expired|token has expired|login expired|please run /login",
    re.I)
TIMER = re.compile(r"\b\d+(?:\.\d+)?\s*(?:ms|s|m|h|sec|secs|min|mins)\b|\b\d+:\d\d(?::\d\d)?\b", re.I)
SPINNER_LINE = re.compile(r"esc to interrupt|ctrl\+c to (?:stop|interrupt)|working\.\.\.|thinking", re.I)
PI_TOKENS = re.compile(r"↑\s*\S+\s+↓\s*\S+")
CLAUDE_TOKENS = re.compile(r"([\d][\d.,]*\s*[kKmM]?)\s+tokens\b")


def h(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]


def load_record():
    try:
        with open(RECORD) as f:
            data = json.load(f)
        if isinstance(data, dict) and data.get("schema") == SCHEMA:
            return data
    except Exception:
        pass
    return {"schema": SCHEMA}


def save_record(rec):
    rec["schema"] = SCHEMA
    rec["updated"] = NOW
    tmp = RECORD + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(rec, f, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, RECORD)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def fmt_age(secs):
    secs = max(0, int(secs))
    if secs >= 3600:
        return "%dh%02dm" % (secs // 3600, (secs % 3600) // 60)
    return "%dm" % (secs // 60)


def short(text, n=90):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 3] + "..."


# --- per worker ---------------------------------------------------------------

def classify_worker(wid, text, busy, prev):
    lines = [l for l in text.splitlines() if l.strip()]
    tail = lines[-12:]
    err = None
    for line in reversed(tail):
        if ERROR_LEAD.search(line) and GATEWAY.search(line):
            err = line.strip()
            break
    # Hash without numbers: a ticking retry counter is the same stall.
    static_hash = h(re.sub(r"\d+", "#", "\n".join(tail)))
    # Content without timers, spinners and footers: what real progress changes.
    body = [l for l in lines if not SPINNER_LINE.search(l) and not PI_TOKENS.search(l)]
    content_hash = h(TIMER.sub("", "\n".join(body[-30:])))
    tokens = None
    for line in reversed(lines):
        m = PI_TOKENS.search(line)
        if m:
            tokens = m.group(0)
            break
    if tokens is None:
        found = CLAUDE_TOKENS.findall(text)
        if found:
            tokens = found[-1].strip()
    sig = "%s|%s" % (tokens or "-", content_hash)
    cur = {
        "seen": NOW,
        "sig": sig,
        "sig_since": NOW,
        "ehash": static_hash if err else "",
        "epolls": 0,
    }
    if prev and prev.get("sig") == sig:
        cur["sig_since"] = prev.get("sig_since", NOW)
    if err:
        if prev and prev.get("ehash") == static_hash:
            cur["epolls"] = int(prev.get("epolls", 0)) + 1
        else:
            cur["epolls"] = 1
    reason = None
    if err and cur["epolls"] >= GATEWAY_POLLS:
        reason = "gateway-error: %s" % short(err, 100)
    elif busy == "busy" and NO_PROGRESS > 0 and NOW - cur["sig_since"] >= NO_PROGRESS:
        reason = "no token movement for %s while busy" % fmt_age(NOW - cur["sig_since"])
    return cur, reason


# --- gateway probe ------------------------------------------------------------

def parse_iso(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def tail_bytes(path, limit=4 * 1024 * 1024):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - limit))
            data = f.read()
        return data.decode("utf-8", "replace")
    except OSError:
        return None


LOG_TS = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]")
GIN = re.compile(r"\[gin_logger\.go:\d+\]\s+(\d{3})\s+\|")
REFRESH_FAIL = re.compile(r"credential refresh failed for \S+ \(([^)]+)\)")


# Inventory files the ccflare access sync writes (claude-<ccflare name>.json).
CCFLARE_PREFIX = "claude-"


def probe_ccflare(db_path):
    """Return {key: message} for the better-ccflare-owned auth conditions."""
    out = {}
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=2)
        try:
            rows = con.execute(
                "SELECT name, expires_at, requires_reauth, paused FROM accounts"
                " WHERE coalesce(provider, 'anthropic') = 'anthropic'").fetchall()
        finally:
            con.close()
    except Exception as exc:
        out["ccflare"] = "gateway account store %s cannot be read: %s" % (db_path, exc)
        return out
    usable = 0
    for name, expires_at, reauth, paused in rows:
        if paused:
            continue
        if reauth:
            out["auth:" + name] = "gateway account %s needs re-authentication in better-ccflare" % name
            continue
        usable += 1
        if not isinstance(expires_at, int) or expires_at <= 0:
            continue
        remaining = expires_at / 1000.0 - NOW
        if remaining <= 0:
            out["auth:" + name] = "gateway account %s expired %s ago in better-ccflare" % (name, fmt_age(-remaining))
        elif remaining <= EXPIRY_WINDOW:
            out["auth:" + name] = "gateway account %s expires in %s in better-ccflare" % (name, fmt_age(remaining))
    if rows and usable == 0:
        out["ccflare"] = "better-ccflare has no usable account: every one is paused or needs re-authentication"
    log = E.get("FS_ACCESS_SYNC_LOG", "")
    if log and os.path.isfile(log):
        stale = ival("FS_ACCESS_SYNC_STALE_SECS")
        log_mtime = os.path.getmtime(log)
        err = os.path.splitext(log)[0] + ".err"
        if NOW - log_mtime >= stale:
            out["access-sync-stale"] = "ccflare access sync has not run for %s (log %s)" % (fmt_age(NOW - log_mtime), log)
        elif os.path.isfile(err) and os.path.getsize(err) > 0 and os.path.getmtime(err) >= log_mtime - 5:
            last = ""
            text = tail_bytes(err, 4096) or ""
            for line in reversed(text.splitlines()):
                if line.strip():
                    last = line.strip()[:200]
                    break
            out["access-sync-failed"] = "ccflare access sync's last run failed: %s" % (last or "see %s" % err)
    return out


def probe_proxy(rec):
    """Return {key: message} for the gateway conditions holding now."""
    out = {}
    if E.get("FS_PROXY", "on").lower() in ("off", "0", "no", "false"):
        return out
    auth_dir = E.get("FS_PROXY_AUTH_DIR", "")
    have_inventory = os.path.isdir(auth_dir)
    answered = False
    try:
        with urllib.request.urlopen(E.get("FS_PROXY_URL", ""), timeout=3) as resp:
            resp.read(256)
        answered = True
    except urllib.error.HTTPError:
        answered = True
    except Exception:
        answered = False
    if not have_inventory and not answered:
        return out
    if not answered:
        out["down"] = "gateway %s gives no answer" % E.get("FS_PROXY_URL", "")

    # When better-ccflare owns refresh, its store is the auth truth and the
    # inventory files are only access-token copies.
    ccflare_db = E.get("FS_CCFLARE_DB", "")
    ccflare = bool(ccflare_db) and os.path.isfile(ccflare_db)

    log = tail_bytes(E.get("FS_PROXY_LOG", "")) if E.get("FS_PROXY_LOG") else None
    total = errors = 0
    refresh_failed = set()
    if log:
        cutoff = NOW - ERROR_WINDOW
        for line in log.splitlines():
            m = LOG_TS.match(line)
            if not m:
                continue
            try:
                ts = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
            except ValueError:
                continue
            if ts < cutoff or ts > NOW + 60:
                continue
            g = GIN.search(line)
            if g:
                total += 1
                code = int(g.group(1))
                if code >= 500 or code == 401:
                    errors += 1
                continue
            r = REFRESH_FAIL.search(line)
            if r and not (ccflare and os.path.basename(r.group(1)).startswith(CCFLARE_PREFIX)):
                refresh_failed.add(os.path.basename(r.group(1)))
    prev_errors = "errors" in (rec.get("proxy") or {})
    rate = (100.0 * errors / total) if total else 0.0
    if prev_errors:
        holds = errors >= ERROR_MIN / 2.0 and rate >= ERROR_RATE / 2.0
    else:
        holds = errors >= ERROR_MIN and rate >= ERROR_RATE
    if total and holds:
        out["errors"] = "gateway error rate %d%% (%d of %d requests in %s were 5xx or 401)" % (
            rate, errors, total, fmt_age(ERROR_WINDOW))

    seen = rec.get("auth_seen") or {}
    now_seen = {}
    if ccflare:
        out.update(probe_ccflare(ccflare_db))
    if have_inventory:
        for path in sorted(glob.glob(os.path.join(auth_dir, "*.json"))):
            name = os.path.basename(path)
            # The access sync owns the claude-* copies of ccflare's accounts;
            # every other inventory file is still CLIProxyAPI's own.
            if ccflare and name.startswith(CCFLARE_PREFIX):
                continue
            try:
                with open(path) as f:
                    data = json.load(f)
            except Exception:
                continue
            if not isinstance(data, dict) or data.get("disabled") is True:
                continue
            if not data.get("refresh_token"):
                continue
            expiry = parse_iso(data.get("expired"))
            if expiry is None:
                continue
            remaining = expiry - NOW
            if remaining > EXPIRY_WINDOW:
                continue
            raw = str(data.get("expired"))
            first = seen.get(name, {})
            since = first.get("since", NOW) if first.get("expired") == raw else NOW
            now_seen[name] = {"expired": raw, "since": since}
            account = name[:-5] if name.endswith(".json") else name
            if remaining <= 0:
                out["auth:" + account] = "gateway auth %s expired %s ago with no refresh" % (
                    account, fmt_age(-remaining))
            elif name in refresh_failed:
                out["auth:" + account] = "gateway auth %s expires in %s and its refresh is failing" % (
                    account, fmt_age(remaining))
            elif NOW - since >= REFRESH_GRACE:
                out["auth:" + account] = "gateway auth %s expires in %s and has not refreshed for %s" % (
                    account, fmt_age(remaining), fmt_age(NOW - since))
    rec["auth_seen"] = now_seen
    return out


# --- actions --------------------------------------------------------------------

def action_status():
    rec = load_record()
    if "updated" not in rec:
        print("fleet-stall status: no poll recorded yet")
        return
    print("fleet-stall status: last poll %s ago" % fmt_age(NOW - rec["updated"]))
    print("live workers: %s, stalled: %s" % (rec.get("live", 0), len(rec.get("stalled") or {})))
    for wid, reason in sorted((rec.get("stalled") or {}).items()):
        print("  %s: %s" % (wid, reason))
    for wid, why in sorted((rec.get("waiting") or {}).items()):
        print("  %s: quiet but waiting (%s), not counted" % (wid, why))
    ep = rec.get("episode")
    if ep:
        print("episode: open %s, paged=%s" % (fmt_age(NOW - ep.get("since", NOW)), "yes" if ep.get("paged") else "no"))
    else:
        print("episode: none")
    for key, msg in sorted((rec.get("proxy") or {}).items()):
        print("gateway: %s" % msg)


WAITING_STATES = ("parked", "paused", "blocked", "done", "failed")
DECLARED_WAIT = re.compile(r"^(needs-decision|blocked|paused)\b")


def crew_state(wid):
    """(state, source) from the candidate's fm-crew-state.sh line, or None."""
    try:
        with open(os.path.join(DIR, wid + ".crew"), errors="replace") as f:
            line = f.readline()
    except OSError:
        return None
    m = re.match(r"state:\s*(\S+)\s*\S*\s*source:\s*(\S+)", line)
    return (m.group(1), m.group(2)) if m else None


def declared_wait(wid):
    """The verb of the newest status-log event when it declares a wait."""
    path = os.path.join(E.get("FS_STATE", ""), wid + ".status")
    text = tail_bytes(path, 8192)
    if not text:
        return None
    for line in reversed(text.splitlines()):
        if line.strip():
            m = DECLARED_WAIT.match(line.strip())
            return m.group(1) if m else None
    return None


def waiting_reason(wid, reason):
    """Why a stall candidate is waiting rather than stalled, or None."""
    current = crew_state(wid)
    if current and current[0] in WAITING_STATES:
        return "current state %s" % current[0]
    verb = declared_wait(wid)
    if verb:
        return "declared %s" % verb
    if current and current[1] == "run-step" and not reason.startswith("gateway-error"):
        return "its no-mistakes run is %s" % current[0]
    return None


def classify_all(rec):
    prev_tasks = rec.get("tasks") or {}
    # A worker the capture deadline skipped keeps its history for a day, so a
    # stall it was building is not reset by one missed read.
    tasks = {w: t for w, t in prev_tasks.items()
             if isinstance(t, dict) and NOW - int(t.get("seen", 0)) < 86400}
    stalled = {}
    live = 0
    for cap in sorted(glob.glob(os.path.join(DIR, "*.cap"))):
        wid = os.path.basename(cap)[:-4]
        try:
            with open(cap, errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        try:
            with open(os.path.join(DIR, wid + ".busy")) as f:
                busy = f.read().strip()
        except OSError:
            busy = "unknown"
        live += 1
        cur, reason = classify_worker(wid, text, busy, prev_tasks.get(wid))
        tasks[wid] = cur
        if reason:
            stalled[wid] = reason
    return tasks, stalled, live


def action_candidates():
    _, stalled, _ = classify_all(load_record())
    for wid in sorted(stalled):
        print(wid)


def action_check():
    rec = load_record()
    tasks, candidates, live = classify_all(rec)
    stalled = {}
    waiting = {}
    for wid, reason in candidates.items():
        why = waiting_reason(wid, reason)
        if why:
            waiting[wid] = why
        else:
            stalled[wid] = reason
    # A gateway condition explains the stall only when a stalled pane shows the
    # gateway failing; otherwise it is reported on its own, not as the cause.
    gateway_seen = any(r.startswith("gateway-error") for r in stalled.values())

    prev_proxy = rec.get("proxy") or {}
    proxy = probe_proxy(rec)
    lines = []
    for key in sorted(set(proxy) - set(prev_proxy)):
        lines.append("WAKE\tfleet-stall: %s" % proxy[key])
    for key in sorted(set(prev_proxy) - set(proxy)):
        lines.append("WAKE\tfleet-stall: gateway recovered: %s" % key)

    def summary():
        parts = ["%s (%s)" % (w, stalled[w]) for w in sorted(stalled)[:15]]
        if len(stalled) > 15:
            parts.append("+%d more" % (len(stalled) - 15))
        text = "%d of %d live workers stalled: %s" % (len(stalled), live, "; ".join(parts))
        if proxy and gateway_seen:
            text += " | likely cause: " + "; ".join(proxy[k] for k in sorted(proxy))
        return text

    ep = rec.get("episode")
    if len(stalled) >= MIN_WORKERS:
        if not ep:
            ep = {"since": NOW, "reported": NOW, "paged": 0}
            note = "" if E.get("FS_PAGE_CONFIGURED") == "1" else \
                " (no FM_FLEET_STALL_PAGE_CMD in config/fleet-stall.env: the captain page is a macOS notification only)"
            lines.append("WAKE\tfleet-stall: FLEET-STALL %s; the captain is paged if it holds %s%s" % (
                summary(), fmt_age(PAGE_AFTER), note))
        elif REMIND > 0 and NOW - ep.get("reported", NOW) >= REMIND:
            ep["reported"] = NOW
            lines.append("WAKE\tfleet-stall: FLEET-STALL persisting %s: %s" % (
                fmt_age(NOW - ep["since"]), summary()))
        if not ep.get("paged") and NOW - ep["since"] >= PAGE_AFTER:
            ep["paged"] = NOW
            lines.append("PAGE\tFirstmate fleet stall: %d workers have been stuck for %s (%s). %s"
                         "If firstmate has not acted, open the firstmate chat." % (
                             len(stalled), fmt_age(NOW - ep["since"]),
                             ", ".join(sorted(stalled)[:10]) + (" ..." if len(stalled) > 10 else ""),
                             ("Likely cause: " + "; ".join(proxy[k] for k in sorted(proxy)) + ". ") if proxy and gateway_seen else ""))
            lines.append("WAKE\tfleet-stall: FLEET-STALL paged the captain after %s: %s" % (
                fmt_age(NOW - ep["since"]), summary()))
        rec["episode"] = ep
    elif ep:
        lines.append("WAKE\tfleet-stall: FLEET-STALL recovered after %s: %d of %d live workers still stalled" % (
            fmt_age(NOW - ep.get("since", NOW)), len(stalled), live))
        rec.pop("episode", None)

    rec["tasks"] = tasks
    rec["stalled"] = stalled
    rec["waiting"] = waiting
    rec["live"] = live
    rec["proxy"] = proxy
    save_record(rec)
    for line in lines:
        print(line)


if ACTION == "status":
    action_status()
elif ACTION == "candidates":
    action_candidates()
else:
    action_check()
PY
}

action_check() {
  local dir out kind text line own_dir=0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  if [ -n "${FM_FLEET_STALL_CAPTURE_DIR:-}" ]; then
    dir=$FM_FLEET_STALL_CAPTURE_DIR
  else
    dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-stall.XXXXXX") || return 0
    own_dir=1
    capture_all "$dir"
  fi
  crew_states "$dir" "$(run_engine candidates "$dir" 2>/dev/null)"
  out=$(run_engine check "$dir" 2>/dev/null) || out='WAKE	fleet-stall: could-not-determine the poll engine failed'
  [ "$own_dir" = 0 ] || rm -rf -- "$dir"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%	*}
    text=${line#*	}
    case "$kind" in
      WAKE) fm_cap_line "$text" "$MAX_LINE" ;;
      PAGE)
        if ! page "$text"; then
          fm_cap_line "fleet-stall: the captain page command did not run or failed; only the macOS notification went out" "$MAX_LINE"
        fi
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

action_status() {
  run_engine status "${TMPDIR:-/tmp}"
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-fleet-stall-check.sh - fleet stall poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-fleet-stall-check.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-fleet-stall-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-fleet-stall-check \
    fm-fleet-stall-check "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD"
}

case "${1:-check}" in
  check) action_check ;;
  status) action_status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
