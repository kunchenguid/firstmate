#!/usr/bin/env bash
# bin/backends/t3code.sh - the T3 Code orchestration-server adapter.
#
# T3 owns the agent session (it launches Claude or Codex itself) while
# Treehouse still owns the task worktree. Firstmate drives the T3 server only
# through its Orchestrator V2 `/mcp` endpoint, signed in as an OAuth
# `mcp-client`; bin/fm-t3-mcp.mjs owns that transport, the credential, the
# `tools/list` capability gate, and the environment-id check, and every
# primitive here is one call to it. There is no terminal: nothing is typed, a
# steer is a t3_thread_send, and Escape/Ctrl-C are a t3_thread_interrupt.
#
# Target string shape: the T3 thread id T3 assigned at launch.
#
# T3 sets environment variables per provider instance, never per thread, so
# every fact firstmate would type into a pane before launch (GOTMPDIR,
# COMPACT_ADVISER_DISABLE, FM_TASK_INBOX, the Git hook override, optional
# LAVISH_AXI_HOST, FM_TASK_ID, TRACEPARENT,
# and a secondmate's FM_* launch prefix) travels
# instead as per-directory harness config that bin/fm-spawn.sh writes into the
# launch directory before the first turn: `.claude/settings.local.json` `env`
# for Claude, `.codex/config.toml` `[shell_environment_policy] set` for Codex.
#
# Config (gitignored config/ of the active home):
#   t3code-token      the mcp-client credential the captain's
#                     `bin/fm-t3-mcp.mjs login` writes, mode 0600
#   t3code-instances  optional `harness=instanceId` lines (claude=claudeAgent,
#                     codex=codex by default)

# T3 has no composer, but the shared submit dispatcher in bin/fm-backend.sh
# prepares and reads the composer dialog sink around every adapter, so this
# adapter loads the same library every other backend does.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

FM_BACKEND_T3CODE_HELPER="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/fm-t3-mcp.mjs"

# Sourced only through fm_backend_source in bin/fm-backend.sh, which owns
# FM_BACKEND_CONFIG_DIR.
fm_backend_t3code_config_dir() {
  printf '%s' "$FM_BACKEND_CONFIG_DIR"
}

fm_backend_t3code_token_file() {
  printf '%s/t3code-token' "$(fm_backend_t3code_config_dir)"
}

fm_backend_t3code_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'node' is not installed" >&2; return 1; }
  command -v treehouse >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'treehouse' is not installed" >&2; return 1; }
}

# fm_backend_t3code_mcp <verb> [args...] - one helper call against this home's
# credential. It prints one JSON object (capture prints text) and exits as its
# header says, including send's delivery-unconfirmed status 7.
# Every failure prints one stderr line.
fm_backend_t3code_mcp() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'node' is not installed" >&2; return 1; }
  node "$FM_BACKEND_T3CODE_HELPER" "$@" --token-file "$(fm_backend_t3code_token_file)"
}

# fm_backend_t3code_json_get <key>: one top-level scalar from the helper's JSON
# on stdin. Fails when the object is not ok or lacks the key.
fm_backend_t3code_json_get() {  # <key>
  node -e '
const key = process.argv[1];
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true) process.exit(1);
const v = d[key];
if (v === undefined || v === null || typeof v === "object") process.exit(1);
process.stdout.write(String(v));
' "$1"
}

# The credential, the capability gate (required t3_* tools and the
# environment id recorded at sign-in), and the telemetry warning, before any
# spawn or control mutation. The helper prints its own one-line reason.
fm_backend_t3code_runtime_check() {
  fm_backend_t3code_tool_check || return 1
  fm_backend_t3code_mcp status >/dev/null
}

fm_backend_t3code_project_ensure() {  # <project-path> -> project id
  local project=$1 real
  real=$(cd "$project" 2>/dev/null && pwd -P) || { echo "error: project path $project is not a directory" >&2; return 1; }
  # The fm- prefix keeps firstmate's projects apart from the owner's own T3
  # project names; matching stays by real path, so the title never binds.
  fm_backend_t3code_mcp project-ensure --root "$real" --title "fm-$(basename "$real")" | fm_backend_t3code_json_get projectId
}

fm_backend_t3code_instance_id() {  # <harness>
  local harness=$1 file line value
  case "$harness" in
    claude) value=claudeAgent ;;
    codex) value=codex ;;
    *) echo "error: backend=t3code supports only the claude and codex harnesses, not '$harness'" >&2; return 1 ;;
  esac
  file="$(fm_backend_t3code_config_dir)/t3code-instances"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$harness="*) value=${line#*=} ;; esac
    done < "$file"
  fi
  [ -n "$value" ] || { echo "error: $file maps harness '$harness' to an empty instance id" >&2; return 1; }
  printf '%s' "$value"
}

# fm_backend_t3code_model_selection: the launch's model selection, resolved
# against T3's own catalog before anything is leased (bin/fm-t3-mcp.mjs
# resolve-selection owns the driver, model, and option checks). Prints the
# selection JSON; the helper prints its own refusal.
fm_backend_t3code_model_selection() {  # <harness> <model> <effort> <project-id> -> JSON
  local harness=$1 model=${2:-default} effort=${3:-default} project_id=$4 instance out
  instance=$(fm_backend_t3code_instance_id "$harness") || return 1
  out=$(fm_backend_t3code_mcp resolve-selection --harness "$harness" --instance "$instance" \
    --model "$model" --effort "$effort" --project "$project_id") || return 1
  printf '%s' "$out" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (!d.ok || !d.selection) process.exit(1);
process.stdout.write(JSON.stringify(d.selection));
'
}

# fm_backend_t3code_thread_create: launch an idle thread at full access and
# print the id T3 assigned. A worktree launches with the existing_worktree
# strategy; an empty one launches at the project's own root, which is a
# secondmate's home. The helper reads the binding back and archives a thread
# T3 bound anywhere else. Exit 1 means the outcome is uncertain: a lost
# reply can leave a thread behind whose id never came back, and a failed
# binding read-back leaves the binding unproven even after requesting archive.
# In either case spawn keeps the lease; the helper owns those failure verdicts.
fm_backend_t3code_thread_create() {  # <project-id> <title> <branch> <worktree> <model-selection-json> -> thread id
  local project_id=$1 title=$2 branch=$3 worktree=$4 selection=$5 out rc
  local -a args=(launch --project "$project_id" --title "$title" --model-selection "$selection")
  [ -z "$branch" ] || args+=(--branch "$branch")
  [ -z "$worktree" ] || args+=(--worktree "$worktree")
  out=$(fm_backend_t3code_mcp "${args[@]}") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | fm_backend_t3code_json_get threadId || return 1
}

# fm_backend_t3code_thread_for_home <home>: the live T3 thread running the
# firstmate whose home is <home>, for away-mode supervisor discovery
# (bin/fm-t3-mcp.mjs thread-for-root owns the cwd match). Exactly one match
# prints its id (0); none prints nothing (1); more than one is an error naming
# the ids (2); an unreadable server is silent (1) so the caller falls through
# to its default.
fm_backend_t3code_thread_for_home() {  # <home> -> thread id
  local home=$1 real out rc
  real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  out=$(fm_backend_t3code_mcp thread-for-root --root "$real" 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0) printf '%s' "$out" | fm_backend_t3code_json_get threadId ;;
    6)
      printf '%s' "$out" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.error("error: " + d.error.message);
'
      return 2
      ;;
    *) return 1 ;;
  esac
}

# One logical delivery keeps one client request id across retries and
# restarts: T3 derives the message id from it, so a resend after a lost reply
# lands on the message T3 already committed instead of a second one. A caller
# that holds its own logical delivery (the away daemon's frozen digest) passes
# its id in FM_T3CODE_CLIENT_REQUEST_ID, with no expiry. Otherwise the id is
# recorded under state/t3code-sends, keyed by thread and text, until an
# outcome is proven; a record older than an hour starts a new delivery, so
# deliberately repeated text later (a constant doorbell) is not swallowed.
# An accepted delivery's outcome (the helper's JSON: clientRequestId,
# messageId, runId, delivery) stays beside it as <request-id>.accepted for a
# day, so it can be reconciled against T3's own message and run.
fm_backend_t3code_send_record() {  # <thread-id> <text> -> record path
  local dir key
  dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}/t3code-sends"
  key=$(printf '%s\0%s' "$1" "$2" | node -e '
process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(0)).digest("hex"));
') || return 1
  printf '%s/%s' "$dir" "$key"
}

# One durable message: it starts an idle thread's next turn or steers the
# running one (t3_thread_send mode auto). The model selection was fixed at
# launch, so the optional third argument is accepted for the caller's
# symmetry and not sent. Exit 0 delivered (its outcome retained); 7 the
# outcome is unproven (the record keeps its request id for a safe retry); any
# other status is proven non-delivery. A request id that may already be in
# flight (the caller's own, or a fresh record from an earlier attempt) ends
# only on acceptance or T3's typed refusal of the send: any other failure,
# including one before the request went out, leaves the earlier attempt
# unproven and reads 7.
fm_backend_t3code_turn_start() {  # <thread-id> <text> [model-selection-json]
  local thread=$1 text=$2 file dir record='' id out rc=0 held=0
  dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}/t3code-sends"
  mkdir -p "$dir" || return 1
  find "$dir" -maxdepth 1 -name '*.accepted' -mmin +1440 -delete 2>/dev/null
  if [ -n "${FM_T3CODE_CLIENT_REQUEST_ID:-}" ]; then
    id=$FM_T3CODE_CLIENT_REQUEST_ID
    held=1
  else
    record=$(fm_backend_t3code_send_record "$thread" "$text") || return 1
    if [ -n "$(find "$record" -mmin -60 2>/dev/null)" ] && id=$(cat "$record" 2>/dev/null) && [ -n "$id" ]; then
      held=1
    else
      id=$(printf 'fm-%s-%s-%s' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM")
      { printf '%s' "$id" > "$record.$$.tmp" && mv -f "$record.$$.tmp" "$record"; } || { rm -f "$record.$$.tmp"; return 1; }
    fi
  fi
  # The brief rides a file: it is the one value too large to trust to argv.
  file=$(mktemp "${TMPDIR:-/tmp}/fm-t3code-msg.XXXXXX") || return 1
  printf '%s' "$text" > "$file" || { rm -f "$file"; return 1; }
  out=$(fm_backend_t3code_mcp send --thread "$thread" --message-file "$file" \
    --client-request-id "$id") || rc=$?
  rm -f "$file"
  if [ "$rc" -eq 0 ] && { ! printf '%s\n' "$out" > "$dir/$id.accepted.$$.tmp" \
    || ! mv -f "$dir/$id.accepted.$$.tmp" "$dir/$id.accepted"; }; then
    rm -f "$dir/$id.accepted.$$.tmp"
  fi
  if [ "$held" = 1 ] && [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    rc=7
  fi
  [ -z "$record" ] || [ "$rc" -eq 7 ] || rm -f "$record"
  return "$rc"
}

fm_backend_t3code_thread_state() {  # <thread-id>
  fm_backend_t3code_mcp state --thread "$1"
}

# fm_backend_t3code_probe: one word naming the thread's row in the status
# table, from its V2 thread status: blocked (any pending runtime request: a
# question or a permission approval waits on a human), idle, starting
# (preparing, queued, starting), running (running, or waiting while the run
# drains), ready (completed), interrupted (interrupted, cancelled,
# rolled_back), error (failed), archived, closing (archived while its run
# still drains: not yet proven closed, so it reads unreadable rather than
# missing), http-404 (the verified server has no such thread), or
# http-failure (unreachable, refused, or unreadable).
fm_backend_t3code_probe() {  # <thread-id>
  local out
  out=$(fm_backend_t3code_thread_state "$1" 2>/dev/null) || { printf 'http-failure'; return 0; }
  printf '%s' "$out" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { d = null; }
const word = () => {
  if (!d || d.ok !== true) return "http-failure";
  if (d.exists === false) return "http-404";
  if (d.archived === true) return d.activeRunId ? "closing" : "archived";
  if (d.pendingRequestCount > 0) return "blocked";
  switch (d.status) {
    case "idle": return "idle";
    case "preparing": case "queued": case "starting": return "starting";
    case "running": case "waiting": return "running";
    case "completed": return "ready";
    case "interrupted": case "cancelled": case "rolled_back": return "interrupted";
    case "failed": return "error";
    default: return "http-failure";
  }
};
process.stdout.write(word());
' 2>/dev/null || printf 'http-failure'
}

# fm_backend_t3code_turn_age: whole seconds since the thread's latest run
# boundary - its completion, or its start while it still runs. Fails when the
# thread is unreadable or carries no parseable run timestamp, so a caller that
# bounds a deferral by this age never defers on missing evidence.
fm_backend_t3code_turn_age() {  # <thread-id>
  local out
  out=$(fm_backend_t3code_thread_state "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const at = Date.parse(JSON.parse(require("fs").readFileSync(0, "utf8")).turnAt || "");
if (!Number.isFinite(at)) process.exit(1);
process.stdout.write(String(Math.max(0, Math.floor((Date.now() - at) / 1000))));
' 2>/dev/null
}

# The one status table: "<busy_state> <agent_state>" per probe row.
fm_backend_t3code_state_row() {  # <probe-row>
  case "$1" in
    starting|running) printf 'busy alive' ;;
    # A pending request is not progress: like a pane's blocked prompt it
    # reads idle, so the wedge ladder never defers it as a running turn.
    blocked|ready|idle|interrupted) printf 'idle alive' ;;
    error) printf 'unknown dead' ;;
    archived|http-404) printf 'unknown missing' ;;
    *) printf 'unknown unreadable' ;;
  esac
}

fm_backend_t3code_busy_state() {  # <thread-id>
  local row
  row=$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$1")")
  printf '%s' "${row%% *}"
}

fm_backend_t3code_agent_state() {  # <thread-id>
  local row
  row=$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$1")")
  printf '%s' "${row#* }"
}

fm_backend_t3code_target_exists() {  # <thread-id>
  case "$(fm_backend_t3code_agent_state "$1")" in
    alive|dead) return 0 ;;
  esac
  return 1
}

# T3 has no composer to clear, so a live thread is always ready for a steer.
fm_backend_t3code_composer_state() {  # <thread-id> [expected-label] -> empty|unknown
  case "$(fm_backend_t3code_probe "$1")" in
    archived|closing|http-404|http-failure) printf 'unknown' ;;
    *) printf 'empty' ;;
  esac
}

fm_backend_t3code_capture() {  # <thread-id> <lines>
  fm_backend_t3code_mcp capture --thread "$1" --lines "${2:-40}"
}

# empty: T3 accepted the message; unconfirmed: the message may have landed
# after a lost reply or failed retry; send-failed: proven not delivered.
# docs/t3code-backend.md owns request-id retention and safe retry rules.
fm_backend_t3code_send_text_submit() {  # <thread-id> <text> <retries> <enter-sleep> <settle>
  local rc=0
  fm_backend_t3code_turn_start "$1" "$2" || rc=$?
  case "$rc" in
    0) printf 'empty' ;;
    7) printf 'unconfirmed' ;;
    *) printf 'send-failed' ;;
  esac
}

# fm_backend_t3code_native_interrupt <thread-id>: interrupt the running turn
# and print T3's own claim, confirmed by its run wait: confirmed,
# not-running, or unconfirmed.
fm_backend_t3code_native_interrupt() {  # <thread-id>
  fm_backend_t3code_mcp interrupt --thread "$1" | fm_backend_t3code_json_get cancel
}

fm_backend_t3code_send_key() {  # <thread-id> <key>
  local thread=$1 key=$2
  case "$key" in
    Escape|escape|Esc|esc|C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_t3code_native_interrupt "$thread" >/dev/null
      ;;
    Enter|enter) return 0 ;;
    *)
      echo "error: unsupported T3 key '$key'" >&2
      return 1
      ;;
  esac
}

# Interrupt any running turn, then archive the thread so it can never act in
# a returned slot, and succeed only on T3's read-back of archived:true with no
# active run (the helper's archive owns that proof). Archiving keeps the
# transcript visible in T3. Idempotent: an archived thread with no active run,
# or one the verified server no longer has, is already the end state.
fm_backend_t3code_kill() {  # <thread-id>
  local thread=$1 out
  out=$(fm_backend_t3code_thread_state "$thread") || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get exists)" = true ] || return 0
  if [ "$(printf '%s' "$out" | fm_backend_t3code_json_get archived)" = true ] \
    && ! printf '%s' "$out" | fm_backend_t3code_json_get activeRunId >/dev/null; then
    return 0
  fi
  if printf '%s' "$out" | fm_backend_t3code_json_get activeRunId >/dev/null; then
    fm_backend_t3code_native_interrupt "$thread" >/dev/null || return 1
  fi
  out=$(fm_backend_t3code_mcp archive --thread "$thread") || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get closed)" = true ]
}

# --- pending requests ---------------------------------------------------------
#
# A pending runtime request (pendingRequestCount) waits on a human. T3's
# pending-request tools read and answer user-input questions only; a
# permission approval stays answerable in T3 Code itself, so it is surfaced
# as an approval count and never answered here. bin/fm-t3-answer.sh is the
# supervisor's entry point.

fm_backend_t3code_pending_requests() {  # <thread-id> -> requests JSON
  fm_backend_t3code_mcp requests --thread "$1"
}

fm_backend_t3code_answer_request() {  # <thread-id> <request-id> <answers-json-file>
  fm_backend_t3code_mcp respond --thread "$1" --request "$2" --answers-file "$3" >/dev/null
}

# --- native event wait ----------------------------------------------------------
#
# The watcher's push splice (bin/fm-watch.sh event_wait_or_sleep) calls these
# through bin/fm-backend.sh. T3 refuses the `/mcp` credential on its WebSocket
# stream, but t3_thread_wait is itself an event-driven wait on stored run
# updates, so one bounded `fm-t3-mcp.mjs watch` call per cycle covers every
# recorded T3 worker: a new or changed pending request is the actionable
# `blocked` edge, escalated once per request signature; a run reaching a
# terminal status ends the wait early so the poll loop reconciles that turn at
# once; and with no active run the wait sleeps its budget rather than
# re-arming, so idle threads never spin. The poll loop remains the backstop.

FM_BACKEND_T3CODE_ESCALATED_PREFIX=.t3code-escalated-

fm_backend_t3code_escalation_marker() {  # <state_dir> <thread-id>
  printf '%s/%s%s' "$1" "$FM_BACKEND_T3CODE_ESCALATED_PREFIX" "$(printf '%s' "$2" | tr ':/.' '___')"
}

fm_backend_t3code_events_capable() {  # <session>
  fm_backend_t3code_mcp status >/dev/null 2>&1
}

# fm_backend_t3code_wait_transition: 0 with a normalized `blocked` record
# (pane_id = thread id, workspace_id = request signature) on a fresh pending
# request; 1 when a run ended, the budget passed, or nothing was running (the
# budget is slept); 2 when the server could not be read.
fm_backend_t3code_wait_transition() {  # <session> <timeout_secs> <state_dir> <thread...>
  local timeout=$2 state=$3 thread marker out
  shift 3
  local -a args=(watch --timeout-ms "$((timeout * 1000))")
  for thread in "$@"; do
    args+=(--thread "$thread")
    marker=$(fm_backend_t3code_escalation_marker "$state" "$thread")
    [ ! -f "$marker" ] || args+=(--escalated "$thread=$(cat "$marker")")
  done
  out=$(fm_backend_t3code_mcp "${args[@]}" 2>/dev/null) || return 2
  # shellcheck disable=SC2016  # ${...} belongs to the Node snippet.
  out=$(printf '%s' "$out" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
for (const id of d.cleared ?? []) console.log(`cleared\t${id}`);
if (d.event === "blocked") console.log(`blocked\t${d.threadId}\t${d.signature}`);
else console.log(`event\t${d.event}`);
') || return 2
  local kind a b
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      cleared) rm -f "$(fm_backend_t3code_escalation_marker "$state" "$a")" ;;
      blocked)
        fm_transition_record "$a" "$b" "" blocked t3code
        return 0
        ;;
      event) [ "$a" != none ] || sleep "$timeout" ;;
    esac
  done <<< "$out"
  return 1
}

fm_backend_t3code_commit_transition() {  # <state_dir> <session> <record>
  local thread signature
  thread=$(fm_transition_pane_id "$3")
  signature=$(fm_transition_workspace_id "$3")
  [ -n "$thread" ] || return 1
  printf '%s' "$signature" > "$(fm_backend_t3code_escalation_marker "$1" "$thread")"
}

fm_backend_t3code_clear_transition() {  # <state_dir> <thread-id>
  [ -n "$2" ] || return 0
  rm -f "$(fm_backend_t3code_escalation_marker "$1" "$2")"
}

# fm_backend_t3code_transition_note: the escalation detail for a blocked
# record, naming what is pending and how it is answered.
fm_backend_t3code_transition_note() {  # <record>
  local signature questions approvals
  signature=$(fm_transition_workspace_id "$1")
  questions=${signature#q:}
  questions=${questions%%;*}
  approvals=${signature##*;a:}
  [ -z "$questions" ] || printf 'T3 question %s pending - read and answer with bin/fm-t3-answer.sh' "$questions"
  if [ "${approvals:-0}" != 0 ]; then
    [ -z "$questions" ] || printf '; '
    printf '%s T3 permission approval(s) pending - only T3 Code itself can approve' "$approvals"
  fi
}

# T3's pull-request tools (link_pull_request, list_thread_pull_requests,
# unlink_pull_request) once crashed a Claude session on a pre-V2 T3 build, so
# Claude workers were told never to call them. All three ran cleanly in a
# Claude thread on this first verified build (docs/verification/
# runtime-backends.md "Claude pull-request tools"); the opt-in live guard
# tests/fm-backend-t3code-pr-tools-live-e2e.test.sh re-proves it.
FM_BACKEND_T3CODE_PR_TOOLS_VERIFIED_FROM=0.0.46-nightly.20261010.2935

# fm_backend_t3code_version_at_least <version> <floor>: 0 when <version> is at
# or past <floor>. A release outranks every nightly of its own version, and
# nightlies order by date then build; anything unparseable is not at least.
fm_backend_t3code_version_at_least() {  # <version> <floor>
  node -e '
const parse = (v) => {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-nightly\.(\d+)\.(\d+))?$/.exec(String(v).trim());
  if (!m) return null;
  return [+m[1], +m[2], +m[3], m[4] === undefined ? Infinity : +m[4], m[5] === undefined ? Infinity : +m[5]];
};
const [a, b] = [parse(process.argv[1]), parse(process.argv[2])];
if (!a || !b) process.exit(1);
for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) process.exit(a[i] > b[i] ? 0 : 1);
' "$1" "$2"
}

# fm_backend_t3code_claude_pr_tools_verified: 0 when the signed-in server is
# at or past the first build whose pull-request tools were verified safe for
# Claude; an unreadable server keeps the older, safer instruction.
fm_backend_t3code_claude_pr_tools_verified() {
  local version
  version=$(fm_backend_t3code_mcp status 2>/dev/null | fm_backend_t3code_json_get serverVersion) || return 1
  fm_backend_t3code_version_at_least "$version" "$FM_BACKEND_T3CODE_PR_TOOLS_VERIFIED_FROM"
}

# fm_backend_t3code_resume_failed: continue a secondmate whose last run
# failed in its own readable thread, rather than replacing the thread and
# losing its conversation. A new turn runs on the same driver and transcript.
fm_backend_t3code_resume_failed() {  # <thread-id>
  fm_backend_t3code_turn_start "$1" "Firstmate recovery: your previous T3 run ended failed. Reconcile the work already recorded in your home, report anything your parent needs through your parent channel, then idle as your charter says."
}

fm_backend_t3code_validate_harness() {  # <harness>
  case "$1" in
    claude|codex) return 0 ;;
    *) echo "error: backend=t3code runs only the claude and codex harnesses, not '$1'" >&2; return 1 ;;
  esac
}

# There is no pane: bin/fm-spawn.sh's launch-time typing helpers land here.
fm_backend_t3code_send_literal() {
  echo "error: backend=t3code has no pane to type into" >&2
  return 1
}
