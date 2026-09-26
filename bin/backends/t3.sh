#!/usr/bin/env bash
# bin/backends/t3.sh - the T3 Code (t3code) GUI-host session-provider adapter.
#
# T3 Code is a desktop and web GUI for coding agents whose headless server
# (`t3 serve`) exposes owner-authenticated HTTP endpoints. This adapter makes
# one T3 THREAD the task endpoint, so a crewmate or scout shows up as its own
# thread in the T3 project that owns the task's repository while firstmate
# keeps every supervision primitive it has on a terminal backend. Treehouse
# remains the worktree provider: the thread is created with `worktreePath` set
# to the task's isolated worktree, and T3 runs its provider process there
# (verified live on T3 Code v0.0.42: the launched `claude` process's cwd was the
# worktree, never the project root). It is EXPERIMENTAL, explicit-only, never
# auto-detected, and supports the claude harness family only (below).
#
# Target string shape: the thread id, a UUID this adapter mints at creation and
# passes in `thread.create`, so the record is bound before T3 ever answers.
# Task meta records `window=<thread id>` (the shared alias every reader uses),
# `t3_thread_id=<thread id>` (the exact binding cleanup validation requires) and
# `t3_project_id=<project id>`.
#
# Transport. Origin: `${T3CODE_HOME:-$HOME/.t3}/userdata/server-runtime.json`'s
# `origin` (FM_T3_ORIGIN overrides it for tests).
# Reads: GET /api/orchestration/shell (projects and thread summaries) and
# GET /api/orchestration/threads/<id> (detail; `?turnLimit=N` bounds it).
# Writes: POST /api/orchestration/dispatch with the same typed commands the web
# client sends - project.create, thread.create, thread.turn.start,
# thread.runtime-mode.set, thread.turn.interrupt, thread.session.stop,
# thread.archive.
# Every call carries a short-lived bearer session minted with
# `t3 auth session issue --ttl <FM_T3_TOKEN_TTL, default 1h> --json`, cached per
# home under state/.t3-session (session id and local expiry) and
# state/.t3-session.header (the header line curl reads through `-H @file`), both
# mode 0600, refreshed inside the last five minutes of the TTL, re-minted on a
# 401, and revoked with `t3 auth session revoke <id>` when the home's last T3
# task is torn down (fm_backend_t3_session_release_if_unused). The token never
# appears in argv, task metadata, status lines, or this adapter's output.
#
# What survives a T3-launched worker, and how the rest is replaced. T3 owns the
# provider command line, so firstmate's launch-line wiring cannot ride argv.
# Verified on v0.0.42, whose claude launch passes
# `--setting-sources=user,project,local`:
#   - busy-state and turn-end hooks: the worktree's .claude/settings.local.json
#     (bin/fm-spawn.sh's claude arm) loads unchanged; UserPromptSubmit, Stop and
#     SessionEnd all fired live, including Stop on an interrupted turn;
#   - launch environment (GOTMPDIR, FM_TASK_ID, COMPACT_ADVISER_DISABLE,
#     LAVISH_AXI_HOST, TRACEPARENT, the claude feedback and suggestion switches,
#     and the GIT_CONFIG_COUNT/GIT_CONFIG_KEY_0=core.hooksPath/GIT_CONFIG_VALUE_0
#     override that points git at the AI-trailer strip hooks):
#     the same settings file's `env` map, verified to reach the worker's shell;
#   - the attribution-off and feedbackDrafts policies: settings keys in that file;
#   - the launch brief: the first `thread.turn.start` message, encoded exactly as
#     a terminal launch encodes it (bin/fm-operational-input.sh launch-brief);
#   - the claude `--append-system-prompt` trust statement: NOT deliverable - no
#     settings key carries it, and T3 sets argv. The brief's own worker-role
#     section still establishes the task identity, and every other harness
#     firstmate runs already works without that statement. Documented as a
#     limit in docs/t3-backend.md.
# Only the claude harness is admitted because its wiring is the one proven to
# load through T3; codex's turn-end rides `-c notify=` on argv, which T3 owns.
#
# State mapping (verified transitions on v0.0.42; `session` is T3's own record
# of the provider process it supervises):
#   session.status starting|running  -> busy, a turn is in flight
#   session.status ready             -> idle, provider process alive between turns
#   session absent|idle|stopped|interrupted -> idle, no provider process; T3
#                                      starts one again on the next turn.start
#                                      (observed: `--resume` of the same claude
#                                      session, conversation preserved)
#   session.status error             -> agent state dead (recovery needed)
#   GET 404                          -> missing: T3 hides ARCHIVED threads from
#                                      the detail endpoint and the shell exactly
#                                      like deleted ones, so "gone" covers both.
# fm_backend_t3_agent_state therefore reports `alive` for any readable,
# unarchived thread: the thread is the agent identity and T3 resumes its
# provider on demand, so a stopped session is a resumable idle, not an exit.
# The one verb that needs the process itself gone - fm-control exit - reads
# fm_backend_t3_session_live instead, and fm-spawn --relaunch gates on the same
# primitive.
#
# Lifecycle verbs:
#   send text      thread.turn.start; accepted (200) while a turn is running too
#                  - T3 queues it as a user message and claude receives it
#                  mid-turn (UserPromptSubmit fired), so a doorbell never
#                  needs a composer. A 200 is NOT delivery by itself: the
#                  server also answers 200 for a turn on an archived thread
#                  and drops it, so send_text_submit re-reads the thread and
#                  reports `empty` only once the message is in its transcript.
#   Escape / C-c   thread.turn.interrupt; T3 then STOPS the provider session
#                  about two seconds later (observed), Stop and SessionEnd fire.
#   exit           thread.session.stop; status reads stopped within ~2s and the
#                  process is gone.
#   kill           session.stop when live, wait for it, THEN thread.archive,
#                  then re-read: only a 404 proves the close. Stopping first is
#                  load-bearing: a session.stop dispatched AFTER archive was
#                  ignored live and left the provider process running.
#
# Capture is a rendered transcript tail: the thread's messages and tool
# activity summaries in time order, the last N lines, plus one footer line with
# the session and turn state so a peek shows live state and a changed state
# changes the watcher's screen hash.
#
# Version pin. This adapter is verified against T3 Code v0.0.42 only. T3's
# Orchestrator V2 rewrite (https://github.com/pingdotgg/t3code/pull/2829)
# removes POST /api/orchestration/dispatch - the only write path above - and
# renames the thread commands it carries, while its HTTP contract keeps the
# shell and thread GET reads, so a read succeeding proves nothing about the
# write path. fm_backend_t3_dispatch_check probes the write path itself before
# a spawn, relaunch, control action, or teardown does real work: an
# authenticated POST of an empty JSON object is decoded and refused as 400 with
# nothing dispatched by a server that exposes the route, and an unknown route
# answers 404 with an empty body (both verified on v0.0.42;
# docs/verification/runtime-backends.md). 400 therefore passes, 404 refuses
# with a message naming the verified version and the V2 removal, 401/403 and
# 5xx refuse as an auth or server failure, and any other answer refuses as a
# server this adapter was not verified against. A write that still reaches a
# server without the endpoint fails with the same message and changes nothing;
# the best-effort inbox doorbell discards that stderr by design.

# Shared composer-content classifier is deliberately NOT sourced here: a T3
# thread has no composer. fm_backend_t3_composer_state answers from session
# state alone (below).

FM_T3_HTTP_TIMEOUT=${FM_T3_HTTP_TIMEOUT:-15}
FM_T3_TOKEN_TTL=${FM_T3_TOKEN_TTL:-1h}
FM_T3_STOP_WAIT=${FM_T3_STOP_WAIT:-15}
FM_T3_START_WAIT=${FM_T3_START_WAIT:-60}
FM_T3_CAPTURE_TURNS=${FM_T3_CAPTURE_TURNS:-6}
FM_BACKEND_T3_HTTP_CODE=
FM_BACKEND_T3_VERIFIED_VERSION=v0.0.42
FM_BACKEND_T3_V2_URL=https://github.com/pingdotgg/t3code/pull/2829

fm_backend_t3_tool_check() {
  local missing=
  command -v t3 >/dev/null 2>&1 || missing="$missing t3"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  [ -z "$missing" ] || {
    echo "error: backend=t3 selected but required tool(s) are not installed:$missing" >&2
    return 1
  }
}

fm_backend_t3_home() {
  if [ -n "${T3CODE_HOME:-}" ]; then
    printf '%s' "$T3CODE_HOME"
  else
    printf '%s/.t3' "${HOME:-}"
  fi
}

fm_backend_t3_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

# fm_backend_t3_origin: the running server's origin. server-runtime.json is
# written by `t3 serve` at startup and is the same discovery `t3 project add`
# uses; an absent or origin-less file means no server this adapter can reach.
fm_backend_t3_origin() {
  local runtime origin
  if [ -n "${FM_T3_ORIGIN:-}" ]; then
    printf '%s' "${FM_T3_ORIGIN%/}"
    return 0
  fi
  runtime="$(fm_backend_t3_home)/userdata/server-runtime.json"
  [ -f "$runtime" ] || {
    echo "error: backend=t3 needs a running T3 Code server, but $runtime does not exist; start it with 't3 serve' (or 't3 service install')" >&2
    return 1
  }
  origin=$(jq -r '.origin // empty' "$runtime" 2>/dev/null) || origin=
  case "$origin" in
    http://*|https://*) ;;
    *)
      echo "error: backend=t3: $runtime records no usable origin; is the T3 Code server running?" >&2
      return 1
      ;;
  esac
  printf '%s' "${origin%/}"
}

fm_backend_t3_uuid() {
  local u
  if command -v uuidgen >/dev/null 2>&1; then
    u=$(uuidgen 2>/dev/null) || u=
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || u=
  elif command -v python3 >/dev/null 2>&1; then
    u=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null) || u=
  fi
  u=$(printf '%s' "$u" | tr 'A-F' 'a-f' | tr -d '[:space:]')
  [[ $u =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    echo "error: backend=t3 could not mint a UUID (no uuidgen, /proc/sys/kernel/random/uuid, or python3)" >&2
    return 1
  }
  printf '%s' "$u"
}

fm_backend_t3_now() {
  date -u +%Y-%m-%dT%H:%M:%S.000Z
}

# --- bearer session -----------------------------------------------------------

fm_backend_t3_ttl_seconds() {  # <ttl> -> seconds, or failure on an unrecognised form
  local ttl=$1 n unit
  case "$ttl" in
    *[!0-9smhd]*|'') return 1 ;;
  esac
  n=${ttl%[smhd]}
  unit=${ttl#"$n"}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    ''|s) printf '%s' "$n" ;;
    m) printf '%s' $((n * 60)) ;;
    h) printf '%s' $((n * 3600)) ;;
    d) printf '%s' $((n * 86400)) ;;
    *) return 1 ;;
  esac
}

fm_backend_t3_session_files() {
  local state
  state=$(fm_backend_t3_state_dir)
  FM_T3_SESSION_FILE="$state/.t3-session"
  FM_T3_SESSION_HEADER="$state/.t3-session.header"
  FM_T3_SESSION_LOCK="$state/.t3-session.lock"
}

fm_backend_t3_session_lock() {
  local tries=0
  while ! mkdir "$FM_T3_SESSION_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      rm -rf "$FM_T3_SESSION_LOCK" 2>/dev/null || true
      mkdir "$FM_T3_SESSION_LOCK" 2>/dev/null && return 0
      echo "error: backend=t3 could not lock the bearer-session cache at $FM_T3_SESSION_LOCK" >&2
      return 1
    fi
    sleep 0.1
  done
}

fm_backend_t3_session_unlock() {
  rmdir "$FM_T3_SESSION_LOCK" 2>/dev/null || true
}

# fm_backend_t3_session_valid: 0 when a cached session exists and has more
# than five minutes (or half its TTL, whichever is smaller) left.
fm_backend_t3_session_valid() {
  local expires now margin ttl_secs
  [ -f "$FM_T3_SESSION_FILE" ] && [ -f "$FM_T3_SESSION_HEADER" ] || return 1
  expires=$(sed -n 's/^expires=//p' "$FM_T3_SESSION_FILE" | head -n 1)
  case "$expires" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  ttl_secs=$(fm_backend_t3_ttl_seconds "$FM_T3_TOKEN_TTL") || ttl_secs=3600
  margin=300
  [ "$((ttl_secs / 2))" -ge "$margin" ] || margin=$((ttl_secs / 2))
  [ "$((expires - now))" -gt "$margin" ]
}

fm_backend_t3_session_id() {
  [ -f "$FM_T3_SESSION_FILE" ] || return 1
  sed -n 's/^session_id=//p' "$FM_T3_SESSION_FILE" | head -n 1
}

# fm_backend_t3_session_mint: issue a fresh session and replace the cache
# atomically. The issue JSON is held in memory only; nothing of it is echoed.
fm_backend_t3_session_mint() {
  local json token sid ttl_secs expires state tmp_meta tmp_hdr old_sid
  fm_backend_t3_tool_check || return 1
  fm_backend_t3_ttl_seconds "$FM_T3_TOKEN_TTL" >/dev/null || {
    echo "error: FM_T3_TOKEN_TTL='$FM_T3_TOKEN_TTL' is not a duration like 30m or 1h" >&2
    return 1
  }
  json=$(t3 auth session issue --ttl "$FM_T3_TOKEN_TTL" --label "firstmate:$FM_HOME" --json 2>/dev/null) || {
    echo "error: 't3 auth session issue' failed; is the T3 Code server running and this user its owner?" >&2
    return 1
  }
  token=$(printf '%s' "$json" | jq -r '.token // empty' 2>/dev/null) || token=
  sid=$(printf '%s' "$json" | jq -r '.sessionId // empty' 2>/dev/null) || sid=
  json=
  if [ -z "$token" ] || [ -z "$sid" ]; then
    echo "error: 't3 auth session issue --json' returned no token or session id" >&2
    return 1
  fi
  ttl_secs=$(fm_backend_t3_ttl_seconds "$FM_T3_TOKEN_TTL")
  expires=$(( $(date +%s) + ttl_secs ))
  state=$(fm_backend_t3_state_dir)
  mkdir -p "$state"
  old_sid=$(fm_backend_t3_session_id 2>/dev/null || true)
  tmp_meta="$FM_T3_SESSION_FILE.tmp.$$"
  tmp_hdr="$FM_T3_SESSION_HEADER.tmp.$$"
  if ! (umask 077 && printf 'session_id=%s\nexpires=%s\n' "$sid" "$expires" >"$tmp_meta" \
      && printf 'Authorization: Bearer %s\n' "$token" >"$tmp_hdr" \
      && chmod 0600 "$tmp_meta" "$tmp_hdr" \
      && mv -f "$tmp_hdr" "$FM_T3_SESSION_HEADER" && mv -f "$tmp_meta" "$FM_T3_SESSION_FILE"); then
    rm -f "$tmp_meta" "$tmp_hdr"
    token=
    echo "error: backend=t3 could not write the bearer-session cache under $state" >&2
    return 1
  fi
  token=
  if [ -n "$old_sid" ] && [ "$old_sid" != "$sid" ]; then
    t3 auth session revoke "$old_sid" >/dev/null 2>&1 || true
  fi
}

# fm_backend_t3_auth_header_file: the 0600 header file for curl -H @file,
# minting or refreshing the session under the cache lock when needed.
# --force re-mints even a valid-looking cache (after a 401).
fm_backend_t3_auth_header_file() {  # [--force]
  fm_backend_t3_session_files
  if [ "${1:-}" != --force ] && fm_backend_t3_session_valid; then
    printf '%s' "$FM_T3_SESSION_HEADER"
    return 0
  fi
  fm_backend_t3_session_lock || return 1
  if [ "${1:-}" = --force ] || ! fm_backend_t3_session_valid; then
    if ! fm_backend_t3_session_mint; then
      fm_backend_t3_session_unlock
      return 1
    fi
  fi
  fm_backend_t3_session_unlock
  printf '%s' "$FM_T3_SESSION_HEADER"
}

# fm_backend_t3_session_release: revoke and forget this home's cached session.
fm_backend_t3_session_release() {
  local sid
  fm_backend_t3_session_files
  fm_backend_t3_session_lock || return 1
  sid=$(fm_backend_t3_session_id 2>/dev/null || true)
  rm -f "$FM_T3_SESSION_FILE" "$FM_T3_SESSION_HEADER"
  fm_backend_t3_session_unlock
  if [ -n "$sid" ] && command -v t3 >/dev/null 2>&1; then
    t3 auth session revoke "$sid" >/dev/null 2>&1 || true
  fi
  return 0
}

# fm_backend_t3_session_release_if_unused: release the cached session once no
# OTHER task record in <state-dir> still runs on this backend.
fm_backend_t3_session_release_if_unused() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta other
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    other=${meta##*/}
    other=${other%.meta}
    [ "$other" != "$id" ] || continue
    [ "$(fm_meta_get "$meta" backend)" != t3 ] || return 0
  done
  fm_backend_t3_session_release
}

# --- HTTP ---------------------------------------------------------------------

# fm_backend_t3_http: one request. Writes the response body to <out-file>,
# sets FM_BACKEND_T3_HTTP_CODE, and returns 0 on 2xx, 4 on 404, 1 otherwise.
# The body goes to a file rather than stdout so callers can invoke this
# directly, where the status variable survives, instead of through a command
# substitution that would discard it. A 401 re-mints the session once and
# retries. The token travels only through the header file.
fm_backend_t3_http() {  # <method> <path> <out-file> [json-body]
  local method=$1 path=$2 out=$3 body=${4-} origin hdr code attempt=0 force=
  FM_BACKEND_T3_HTTP_CODE=000
  origin=$(fm_backend_t3_origin) || return 1
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if [ -n "$force" ]; then
      hdr=$(fm_backend_t3_auth_header_file --force) || return 1
    else
      hdr=$(fm_backend_t3_auth_header_file) || return 1
    fi
    if [ -n "$body" ]; then
      code=$(curl -sS -o "$out" -w '%{http_code}' --max-time "$FM_T3_HTTP_TIMEOUT" \
        -H @"$hdr" -H 'content-type: application/json' -X "$method" \
        --data-binary "$body" "$origin$path" 2>/dev/null) || code=000
    else
      code=$(curl -sS -o "$out" -w '%{http_code}' --max-time "$FM_T3_HTTP_TIMEOUT" \
        -H @"$hdr" -X "$method" "$origin$path" 2>/dev/null) || code=000
    fi
    FM_BACKEND_T3_HTTP_CODE=$code
    if [ "$code" = 401 ] && [ "$attempt" -lt 2 ]; then
      force=--force
      continue
    fi
    case "$code" in
      2[0-9][0-9]) return 0 ;;
      404) return 4 ;;
      000) echo "error: backend=t3 could not reach $origin$path (connection failed or timed out after ${FM_T3_HTTP_TIMEOUT}s)" >&2; return 1 ;;
    esac
    return 1
  done
  return 1
}

# fm_backend_t3_error_reason: the reason or code a T3 error body carries.
fm_backend_t3_error_reason() {  # <body-file> <http-code>
  local reason
  reason=$(jq -r '.reason // .code // empty' "${1-}" 2>/dev/null) || reason=
  printf 'HTTP %s%s' "${2-}" "${reason:+ ($reason)}"
}

fm_backend_t3_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/fm-t3-http.XXXXXX"
}

# fm_backend_t3_dispatch: one command. Prints the response body; returns the
# HTTP helper's status, 4 on a 404, which is never worth retrying. A dispatch
# 404 whose body carries no reason is the verified v0.0.42 route-missing shape,
# reported as the removed endpoint; any other 404 is reported with its reason.
fm_backend_t3_dispatch() {  # <command-json> -> response body
  local out rc=0
  out=$(fm_backend_t3_tmpfile) || return 1
  fm_backend_t3_http POST /api/orchestration/dispatch "$out" "$1" || rc=$?
  if [ "$rc" -eq 0 ]; then
    cat "$out"
    rm -f "$out"
    return 0
  fi
  echo "error: t3 dispatch $(printf '%s' "$1" | jq -r '.type // "command"' 2>/dev/null) failed: $(fm_backend_t3_error_reason "$out" "$FM_BACKEND_T3_HTTP_CODE")" >&2
  if [ "$rc" -eq 4 ] && [ -z "$(jq -r '.reason // empty' "$out" 2>/dev/null)" ]; then
    fm_backend_t3_dispatch_removed_message "$(fm_backend_t3_origin 2>/dev/null)"
  fi
  rm -f "$out"
  return "$rc"
}

fm_backend_t3_shell() {
  local out rc=0
  out=$(fm_backend_t3_tmpfile) || return 1
  fm_backend_t3_http GET /api/orchestration/shell "$out" || rc=$?
  if [ "$rc" -eq 0 ]; then
    cat "$out"
    rm -f "$out"
    return 0
  fi
  echo "error: t3 shell snapshot failed: $(fm_backend_t3_error_reason "$out" "$FM_BACKEND_T3_HTTP_CODE")" >&2
  rm -f "$out"
  return 1
}

# fm_backend_t3_thread_json: the thread detail. Returns 0 with the body, 4 on
# a 404 (archived or deleted), 1 on any other failure.
fm_backend_t3_thread_json() {  # <thread-id> [turn-limit]
  local thread=$1 limit=${2-} path out rc=0
  case "$thread" in ''|*[!A-Za-z0-9._@%+-]*) echo "error: refusing malformed T3 thread id" >&2; return 1 ;; esac
  path="/api/orchestration/threads/$thread"
  [ -z "$limit" ] || path="$path?turnLimit=$limit"
  out=$(fm_backend_t3_tmpfile) || return 1
  fm_backend_t3_http GET "$path" "$out" || rc=$?
  case "$rc" in
    0)
      cat "$out"
      rm -f "$out"
      return 0
      ;;
    4)
      rm -f "$out"
      return 4
      ;;
  esac
  echo "error: t3 thread read failed: $(fm_backend_t3_error_reason "$out" "$FM_BACKEND_T3_HTTP_CODE")" >&2
  rm -f "$out"
  return 1
}

# fm_backend_t3_account_pin_check <harness> <worker-account-selection>: T3 owns
# the provider launch and runs it under its server's own login, so neither a
# pinned CLAUDE_CONFIG_DIR nor the credential shedding can reach a T3 worker.
fm_backend_t3_account_pin_check() {
  [ "$1" = claude ] && [ -n "$2" ] || return 0
  echo "error: config/claude-account pins the Claude account, but T3 Code launches the provider with its server's own login, so backend=t3 cannot honor the pin; remove config/claude-account or use another backend" >&2
  return 1
}

fm_backend_t3_dispatch_removed_message() {  # <origin>
  echo "error: backend=t3: the T3 Code server at ${1:-the discovered origin} does not expose POST /api/orchestration/dispatch, the only write path this backend has; Firstmate's T3 backend is verified against T3 Code $FM_BACKEND_T3_VERIFIED_VERSION only, and T3's Orchestrator V2 ($FM_BACKEND_T3_V2_URL) removes that endpoint and renames the thread commands, so run the verified $FM_BACKEND_T3_VERIFIED_VERSION server or use another backend" >&2
}

# fm_backend_t3_dispatch_check: the version pin's capability gate (header).
# Refuses unless the server still exposes the dispatch endpoint, and never
# dispatches an accepted command.
fm_backend_t3_dispatch_check() {
  local origin out reason
  origin=$(fm_backend_t3_origin) || return 1
  out=$(fm_backend_t3_tmpfile) || return 1
  fm_backend_t3_http POST /api/orchestration/dispatch "$out" '{}' || true
  reason=$(fm_backend_t3_error_reason "$out" "$FM_BACKEND_T3_HTTP_CODE")
  rm -f "$out"
  case "$FM_BACKEND_T3_HTTP_CODE" in
    400) return 0 ;;
    404) fm_backend_t3_dispatch_removed_message "$origin" ;;
    000) ;;
    401|403) echo "error: backend=t3 requires an owner-authenticated T3 Code server; $origin refused the dispatch capability probe's bearer session: $reason" >&2 ;;
    5[0-9][0-9]) echo "error: backend=t3: the T3 Code server at $origin failed the dispatch capability probe: $reason" >&2 ;;
    *) echo "error: backend=t3: the dispatch capability probe against $origin answered $reason where T3 Code $FM_BACKEND_T3_VERIFIED_VERSION refuses the empty command with 400; refusing a server this backend was not verified against" >&2 ;;
  esac
  return 1
}

fm_backend_t3_runtime_check() {
  fm_backend_t3_tool_check || return 1
  fm_backend_t3_origin >/dev/null || return 1
  fm_backend_t3_dispatch_check || return 1
  fm_backend_t3_shell >/dev/null || {
    echo "error: backend=t3 requires a reachable, owner-authenticated T3 Code server; the shell snapshot read failed" >&2
    return 1
  }
}

# --- projects and threads -----------------------------------------------------

fm_backend_t3_real_path() {  # <path>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

# fm_backend_t3_repo_key: a remote URL normalized the way T3 itself normalizes
# one (v0.0.42 normalizeGitRemoteUrl): lowercased host/owner/repo with the
# scheme, user, port, trailing slash, and .git suffix dropped, so the scp,
# ssh://, and https spellings of one remote compare equal.
fm_backend_t3_repo_key() {  # <remote-url>
  jq -rn --arg u "$1" '
    ($u | gsub("^\\s+|\\s+$"; "") | ascii_downcase | sub("/+$"; "") | sub("\\.git$"; "")) as $n
    | if ($n | test("^(ssh|https?|git)://")) then
        (($n | capture("^[a-z]+://([^@/]*@)?(?<host>[^/:?#]+)(:[0-9]*)?(?<path>[^?#]*)")) // null) as $m
        | ((($m.path // "") | split("/") | map(select(length > 0)) | join("/"))) as $p
        | if $m != null and ($p | contains("/")) then "\($m.host)/\($p)" else $n end
      else
        (($n | capture("^[a-z0-9._-]+@(?<host>[^:/\\s]+):(?<path>[^/\\s]+(/[^/\\s]+)+)$")) // null) as $m
        | if $m != null then "\($m.host)/\($m.path)" else $n end
      end'
}

fm_backend_t3_git_repo_key() {  # <dir> -> key of its origin, empty without one
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) && [ -n "$url" ] || return 0
  fm_backend_t3_repo_key "$url"
}

# fm_backend_t3_project_find: the id of the T3 project for <project-path>;
# prints nothing when T3 has none. The project whose workspaceRoot is the path
# (compared physically) wins; otherwise the repository's own project, matched
# by normalized origin URL: a firstmate clone is never the checkout the captain
# registered. A candidate's origin is read from its workspaceRoot; only an
# unreadable root falls back to repositoryIdentity, and only when its locator
# names the origin remote, because T3 builds that identity from `upstream`
# first (v0.0.42 pickPrimaryRemote), so its canonicalKey is not an origin.
# Several matches resolve to the one titled after the repository, then the
# oldest, and an origin match is announced on stderr.
fm_backend_t3_project_find() {  # <project-path>
  local project=$1 real shell id key pid remote url ckey root title matched='' chosen
  real=$(fm_backend_t3_real_path "$project")
  shell=$(fm_backend_t3_shell) || return 1
  id=$(printf '%s' "$shell" | jq -r --arg root "$real" --arg raw "$project" \
    '[.projects[] | select(.workspaceRoot == $root or .workspaceRoot == $raw)] | .[0].id // empty') || id=
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  key=$(fm_backend_t3_git_repo_key "$real")
  [ -n "$key" ] || return 0
  while IFS=$'\037' read -r pid remote url root; do
    [ -n "$pid" ] || continue
    ckey=
    if [ -d "$root" ] && [ -r "$root" ]; then
      ckey=$(fm_backend_t3_git_repo_key "$root")
    elif [ "$remote" = origin ] && [ -n "$url" ]; then
      ckey=$(fm_backend_t3_repo_key "$url")
    fi
    [ "$ckey" != "$key" ] || matched="$matched$pid"$'\n'
  done <<EOF
$(printf '%s' "$shell" | jq -r '.projects[]
  | [.id, (.repositoryIdentity.locator.remoteName // ""), (.repositoryIdentity.locator.remoteUrl // ""),
     (.workspaceRoot // "")] | join("\u001f")' 2>/dev/null)
EOF
  [ -n "$matched" ] || return 0
  chosen=$(printf '%s' "$shell" | jq -r --arg ids "$matched" --arg name "${key##*/}" '
    ($ids | split("\n") | map(select(length > 0))) as $ids
    | [.projects[] | select(.id as $i | any($ids[]; . == $i))]
    | sort_by((if ((.title // "") | ascii_downcase) == $name then 0 else 1 end), (.createdAt // ""), .id)
    | .[0] | [.id, (.title // ""), (.workspaceRoot // "")] | join("\u001f")') || return 1
  IFS=$'\037' read -r id title root <<EOF
$chosen
EOF
  echo "notice: T3 has no project rooted at $real; using project '$title' at $root, the T3 project for the same repository ($key)" >&2
  printf '%s' "$id"
}

# fm_backend_t3_project_ensure: the project fm_backend_t3_project_find names,
# registered through project.create when T3 has none for the repository.
# Prints the id.
fm_backend_t3_project_ensure() {  # <project-path>
  local project=$1 real shell id title cmd
  id=$(fm_backend_t3_project_find "$project") || return 1
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  real=$(fm_backend_t3_real_path "$project")
  id=$(fm_backend_t3_uuid) || return 1
  title=${real##*/}
  [ -n "$title" ] || title=$real
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg pid "$id" --arg title "$title" \
    --arg root "$real" --arg now "$(fm_backend_t3_now)" \
    '{type:"project.create",commandId:$cid,projectId:$pid,title:$title,workspaceRoot:$root,createdAt:$now}') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null || return 1
  shell=$(fm_backend_t3_shell) || return 1
  printf '%s' "$shell" | jq -e --arg id "$id" '.projects[] | select(.id == $id)' >/dev/null 2>&1 || {
    echo "error: t3 project.create for $real was accepted but the project did not appear in the shell snapshot" >&2
    return 1
  }
  printf '%s' "$id"
}

fm_backend_t3_project_default_model() {  # <project-id> -> modelSelection JSON or failure
  local shell sel
  shell=$(fm_backend_t3_shell) || return 1
  sel=$(printf '%s' "$shell" | jq -c --arg id "$1" \
    '[.projects[] | select(.id == $id)] | .[0].defaultModelSelection // empty') || sel=
  [ -n "$sel" ] && [ "$sel" != null ] || return 1
  printf '%s' "$sel"
}

fm_backend_t3_harness_check() {  # <harness>
  case "$1" in
    claude*) return 0 ;;
  esac
  echo "error: backend=t3 supports the claude harness family only (got '$1'); T3 owns the provider command line, and only claude's settings-file wiring is verified to load through it" >&2
  return 1
}

# fm_backend_t3_model_selection: the thread.create modelSelection for a claude
# task. Precedence: explicit --model, then the T3 project's own default when it
# names claudeAgent, then T3's cached model manifest default for claudeAgent
# (userdata/model-manifest.json). Effort rides options [{id:"effort",value}].
fm_backend_t3_model_selection() {  # <harness> <model> <effort> <project-id-or-empty>
  local harness=$1 model=${2-} effort=${3-} project=${4-} manifest sel instance=claudeAgent
  fm_backend_t3_harness_check "$harness" || return 1
  if [ -z "$model" ] && [ -n "$project" ]; then
    if sel=$(fm_backend_t3_project_default_model "$project"); then
      if [ "$(printf '%s' "$sel" | jq -r '.instanceId // .provider // empty')" = "$instance" ]; then
        model=$(printf '%s' "$sel" | jq -r '.model // empty')
      fi
    fi
  fi
  if [ -z "$model" ]; then
    manifest="$(fm_backend_t3_home)/userdata/model-manifest.json"
    [ ! -f "$manifest" ] || model=$(jq -r --arg p "$instance" \
      '.manifest.providers[$p].defaults.chat // empty' "$manifest" 2>/dev/null) || model=
  fi
  [ -n "$model" ] || {
    echo "error: backend=t3 needs a model for the T3 thread and none was given (--model), set as the T3 project default, or present in T3's model manifest" >&2
    return 1
  }
  if [ -n "$effort" ]; then
    jq -cn --arg i "$instance" --arg m "$model" --arg e "$effort" \
      '{instanceId:$i,model:$m,options:[{id:"effort",value:$e}]}'
  else
    jq -cn --arg i "$instance" --arg m "$model" '{instanceId:$i,model:$m}'
  fi
}

# fm_backend_t3_runtime_mode: T3's runtimeMode for the claude permission flag
# bin/fm-spawn.sh resolved from config/claude-permission-mode.
fm_backend_t3_runtime_mode() {  # <claude-perm-flag>
  case "${1-}" in
    *'--permission-mode auto'*) printf 'auto' ;;
    *) printf 'full-access' ;;
  esac
}

# fm_backend_t3_thread_create: create the task thread bound to <worktree> and
# prove the binding by reading it back. Prints the thread id - on a failure too,
# once the id is minted, because T3 may hold the thread anyway and the caller
# owns closing it (a thread T3 never created reads not-found, a proven close).
fm_backend_t3_thread_create() {  # <project-id> <title> <worktree> <branch-or-empty> <model-selection-json> <runtime-mode>
  local project=$1 title=$2 worktree=$3 branch=${4-} model=$5 mode=$6 thread cmd body bound
  thread=$(fm_backend_t3_uuid) || return 1
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg tid "$thread" --arg pid "$project" \
    --arg title "$title" --argjson model "$model" --arg mode "$mode" \
    --arg branch "$branch" --arg wt "$worktree" --arg now "$(fm_backend_t3_now)" \
    '{type:"thread.create",commandId:$cid,threadId:$tid,projectId:$pid,title:$title,
      modelSelection:$model,runtimeMode:$mode,interactionMode:"default",
      branch:(if $branch == "" then null else $branch end),worktreePath:$wt,createdAt:$now}') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null || {
    printf '%s' "$thread"
    return 1
  }
  body=$(fm_backend_t3_thread_json "$thread") || {
    echo "error: t3 thread.create was accepted but thread $thread could not be read back" >&2
    printf '%s' "$thread"
    return 1
  }
  bound=$(printf '%s' "$body" | jq -r '.thread.worktreePath // empty')
  [ "$bound" = "$worktree" ] || {
    echo "error: t3 thread $thread records worktreePath '${bound:-none}', not the task worktree '$worktree'; refusing to launch a worker outside its isolated copy" >&2
    printf '%s' "$thread"
    return 1
  }
  printf '%s' "$thread"
}

# fm_backend_t3_turn_start: send one user message. Prints the message id it
# minted so a caller can prove the message landed (fm_backend_t3_message_landed):
# the server answers 200 for a turn on an ARCHIVED thread too and simply drops
# it (observed live), so acceptance alone is not delivery. <runtime-mode> is
# informational to T3 v0.0.42, which starts the provider under the thread's own
# runtimeMode (fm_backend_t3_runtime_mode_ensure changes that). A non-empty
# <model-selection-json> switches the thread's model for this turn onward.
fm_backend_t3_turn_start() {  # <thread-id> <text> <runtime-mode> [model-selection-json]
  local cmd mid
  mid=$(fm_backend_t3_uuid) || return 1
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg tid "$1" --arg mid "$mid" \
    --arg text "$2" --arg mode "$3" --arg model "${4-}" --arg now "$(fm_backend_t3_now)" \
    '{type:"thread.turn.start",commandId:$cid,threadId:$tid,
      message:{messageId:$mid,role:"user",text:$text,attachments:[]},
      runtimeMode:$mode,interactionMode:"default",createdAt:$now}
     + (if $model == "" then {} else {modelSelection:($model | fromjson)} end)') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null || return $?
  printf '%s' "$mid"
}

# fm_backend_t3_runtime_mode_ensure: make the thread's own runtimeMode - the
# posture T3 starts its provider under - <runtime-mode>, dispatching
# thread.runtime-mode.set only when it differs, and prove it by re-read.
fm_backend_t3_runtime_mode_ensure() {  # <thread-id> <runtime-mode>
  local thread=$1 mode=$2 current cmd
  current=$(fm_backend_t3_thread_json "$thread" 1 2>/dev/null | jq -r '.thread.runtimeMode // empty' 2>/dev/null) || current=
  [ "$current" != "$mode" ] || return 0
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg tid "$thread" --arg mode "$mode" --arg now "$(fm_backend_t3_now)" \
    '{type:"thread.runtime-mode.set",commandId:$cid,threadId:$tid,runtimeMode:$mode,createdAt:$now}') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null || return 1
  current=$(fm_backend_t3_thread_json "$thread" 1 2>/dev/null | jq -r '.thread.runtimeMode // empty' 2>/dev/null) || current=
  [ "$current" = "$mode" ] || {
    echo "error: t3 thread $thread records runtimeMode '${current:-unreadable}' after thread.runtime-mode.set $mode" >&2
    return 1
  }
}

# fm_backend_t3_message_landed: 0 when the thread's transcript holds <message-id>,
# 4 when the thread is gone, 1 when it is unreadable or the message is absent.
fm_backend_t3_message_landed() {  # <thread-id> <message-id>
  local body rc=0
  body=$(fm_backend_t3_thread_json "$1" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$body" | jq -e --arg mid "$2" '.thread.messages[]? | select(.id == $mid)' >/dev/null 2>&1 || return 1
}

fm_backend_t3_turn_interrupt() {  # <thread-id>
  local cmd
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg tid "$1" --arg now "$(fm_backend_t3_now)" \
    '{type:"thread.turn.interrupt",commandId:$cid,threadId:$tid,createdAt:$now}') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null
}

# --- state reads --------------------------------------------------------------

# fm_backend_t3_session_status: one token - a T3 session status, `none` for a
# readable thread with no session record, `missing` on 404, `unreadable`
# otherwise.
fm_backend_t3_session_status() {  # <thread-id>
  local body rc=0 status
  body=$(fm_backend_t3_thread_json "$1" 1 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    4) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  status=$(printf '%s' "$body" | jq -r '.thread.session.status // "none"' 2>/dev/null) || status=unreadable
  case "$status" in
    starting|running|ready|idle|stopped|interrupted|error|none) printf '%s' "$status" ;;
    *) printf 'unreadable' ;;
  esac
}

fm_backend_t3_session_live() {  # <thread-id> -> 0 when a provider process is up
  case "$(fm_backend_t3_session_status "$1")" in
    starting|running|ready) return 0 ;;
  esac
  return 1
}

fm_backend_t3_busy_state() {  # <thread-id> -> busy|idle|unknown
  case "$(fm_backend_t3_session_status "$1")" in
    starting|running) printf 'busy' ;;
    ready|idle|stopped|interrupted|none) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_t3_target_exists() {  # <thread-id> [expected-label]
  fm_backend_t3_thread_json "$1" 1 >/dev/null 2>&1
}

# fm_backend_t3_agent_state: alive|dead|missing|unreadable (header: the thread
# is the agent; only a provider error is dead, only a 404 is missing).
fm_backend_t3_agent_state() {  # <thread-id>
  case "$(fm_backend_t3_session_status "$1")" in
    missing) printf 'missing' ;;
    unreadable) printf 'unreadable' ;;
    error) printf 'dead' ;;
    *) printf 'alive' ;;
  esac
}

fm_backend_t3_current_path() {  # <thread-id>
  local body
  body=$(fm_backend_t3_thread_json "$1" 1) || return 1
  printf '%s' "$body" | jq -r '.thread.worktreePath // empty'
}

fm_backend_t3_capture() {  # <thread-id> <lines> [expected-label]
  local thread=$1 lines=${2:-40} body
  case "$lines" in ''|*[!0-9]*|0) lines=40 ;; esac
  body=$(fm_backend_t3_thread_json "$thread" "$FM_T3_CAPTURE_TURNS") || return 1
  printf '%s' "$body" | jq -r '
    ([ (.thread.messages[]? | {at: .createdAt, line: ("\(.role): \(.text // "")")}),
       (.thread.activities[]? | select(.tone == "tool" or .tone == "error" or .tone == "approval")
         | {at: .createdAt, line: ("[\(.tone)] \(.summary // .kind)")}) ]
     | sort_by(.at) | .[].line),
    "[t3 thread=\(.thread.id) session=\(.thread.session.status // "none") turn=\(.thread.latestTurn.state // "none")]"
  ' | tail -n "$lines"
}

# fm_backend_t3_composer_state: a thread has no composer, so the only question
# a caller can ask is "may a message be submitted without concatenating onto
# typed text?" - always yes for a readable thread. Busy threads still accept a
# queued turn.start, but report unknown so a guard that must not interleave
# with a running turn stays conservative.
fm_backend_t3_composer_state() {  # <thread-id> [expected-label]
  case "$(fm_backend_t3_session_status "$1")" in
    ready|idle|stopped|interrupted|none) printf 'empty' ;;
    *) printf 'unknown' ;;
  esac
}

# --- sends ---------------------------------------------------------------------

fm_backend_t3_send_key() {  # <thread-id> <key> [expected-label]
  case "$2" in
    Escape|Esc|esc|escape|C-c|ctrl+c|Ctrl-c|Ctrl-C) fm_backend_t3_turn_interrupt "$1" ;;
    Enter|enter) return 0 ;;
    *) echo "error: unsupported T3 key '$2' (a thread has no terminal; Escape and C-c interrupt the turn, Enter is a no-op)" >&2; return 1 ;;
  esac
}

# fm_backend_t3_send_text_submit: one thread.turn.start, then a re-read that
# finds the message in the thread's transcript; that is delivery and reports
# `empty`. A dispatch 404 reports `send-failed` without retrying, after the
# capability check names a removed endpoint when the 404 is the verified
# route-missing shape, and so does a thread the re-read finds gone after a
# silently dropped turn; other dispatch failures retry <retries> times; an
# accepted send whose landing could not be read or is not yet visible reports
# `pending`: accepted, landing not confirmed.
fm_backend_t3_send_text_submit() {  # <thread-id> <text> <retries> <enter-sleep> <settle> [expected-label]
  local thread=$1 text=$2 retries=${3:-1} sleep_s=${4:-0.5} attempt=0 rc mid mode
  case "$retries" in ''|*[!0-9]*|0) retries=1 ;; esac
  mode=$(fm_backend_t3_thread_json "$thread" 1 2>/dev/null | jq -r '.thread.runtimeMode // empty' 2>/dev/null) || mode=
  [ -n "$mode" ] || mode=full-access
  while [ "$attempt" -lt "$retries" ]; do
    attempt=$((attempt + 1))
    rc=0
    mid=$(fm_backend_t3_turn_start "$thread" "$text" "$mode" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      rc=0
      fm_backend_t3_message_landed "$thread" "$mid" || rc=$?
      case "$rc" in
        0) printf 'empty' ;;
        4) printf 'send-failed' ;;
        *) printf 'pending' ;;
      esac
      return 0
    fi
    if [ "$rc" -eq 4 ]; then
      fm_backend_t3_dispatch_check || true
      break
    fi
    [ "$attempt" -ge "$retries" ] || sleep "$sleep_s"
  done
  printf 'send-failed'
}

# A terminal backend types these into a pane shell before launch; a T3 thread
# has no shell, and fm-spawn delivers their content through the worker's
# settings file instead. Refusing here keeps any stray caller loud.
fm_backend_t3_send_text_line() {  # <thread-id> <text>
  echo "error: backend=t3 has no pane shell to type '$2' into; the launch delivers environment through .claude/settings.local.json" >&2
  return 1
}

fm_backend_t3_send_literal() {
  fm_backend_t3_send_text_line "$@"
}

# --- lifecycle -----------------------------------------------------------------

# fm_backend_t3_session_stop: stop the provider session and wait until T3
# reports it not live. Idempotent on an already-stopped session.
fm_backend_t3_session_stop() {  # <thread-id> [wait-secs]
  local thread=$1 wait=${2:-$FM_T3_STOP_WAIT} cmd elapsed=0 status
  wait=${wait%%.*}
  case "$wait" in ''|*[!0-9]*) wait=0 ;; esac
  status=$(fm_backend_t3_session_status "$thread")
  case "$status" in
    missing) return 0 ;;
    unreadable) return 1 ;;
    starting|running|ready) ;;
    *) return 0 ;;
  esac
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg tid "$thread" --arg now "$(fm_backend_t3_now)" \
    '{type:"thread.session.stop",commandId:$cid,threadId:$tid,createdAt:$now}') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null || return 1
  while :; do
    fm_backend_t3_session_live "$thread" || return 0
    [ "$elapsed" -lt "$wait" ] || break
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "error: t3 thread $thread still reports a live session ${wait}s after session.stop" >&2
  return 1
}

# fm_backend_t3_wait_session_started: 0 once a turn is observed starting or
# running (the launch brief was taken), 1 after <secs> without one.
fm_backend_t3_wait_session_started() {  # <thread-id> <secs>
  local thread=$1 wait=${2:-$FM_T3_START_WAIT} elapsed=0
  wait=${wait%%.*}
  case "$wait" in ''|*[!0-9]*) wait=0 ;; esac
  while :; do
    case "$(fm_backend_t3_session_status "$thread")" in
      starting|running) return 0 ;;
    esac
    [ "$elapsed" -lt "$wait" ] || return 1
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

# fm_backend_t3_kill: close the task endpoint - stop the provider session,
# then archive the thread, then prove it with a re-read. A 404 before or after
# is the endpoint gone (0); anything short of that returns 1 so the caller
# keeps the record naming the thread.
fm_backend_t3_kill() {  # <thread-id> [ignored...]
  local thread=$1 status cmd rc
  fm_backend_t3_tool_check || return 1
  status=$(fm_backend_t3_session_status "$thread")
  case "$status" in
    missing) return 0 ;;
    unreadable) echo "error: t3 thread $thread could not be read, so its close was not attempted" >&2; return 1 ;;
  esac
  fm_backend_t3_session_stop "$thread" || return 1
  cmd=$(jq -cn --arg cid "$(fm_backend_t3_uuid)" --arg tid "$thread" \
    '{type:"thread.archive",commandId:$cid,threadId:$tid}') || return 1
  fm_backend_t3_dispatch "$cmd" >/dev/null || return 1
  rc=0
  fm_backend_t3_thread_json "$thread" 1 >/dev/null 2>&1 || rc=$?
  case "$rc" in
    4) return 0 ;;
    0) echo "error: t3 thread $thread is still readable after thread.archive; refusing to report it closed" >&2; return 1 ;;
    *) echo "error: t3 thread $thread could not be re-read after thread.archive, so the close is unproven" >&2; return 1 ;;
  esac
}
