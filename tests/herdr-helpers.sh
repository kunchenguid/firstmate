#!/usr/bin/env bash
# tests/herdr-helpers.sh - fakes for the multiplexer seam.
#
# THE RULE THESE FAKES EXIST TO ENFORCE: a gate must not pass against a stub
# that would never satisfy the real multiplexer. So the fake herdr here is not
# a yes-machine. It reproduces the constraints verified against herdr 0.8.2:
#
#   * `agent rename` REJECTS anything but ^[a-z][a-z0-9_-]{0,31}$ with
#     invalid_agent_name - which is what proved the old `<project>/<work>`
#     naming convention unusable;
#   * `tab create` without --workspace is a bug, not a default, so the fake
#     records the flag and the tests assert on it;
#   * `agent prompt` on a blocked agent returns agent_blocked BEFORE sending;
#   * responses are single-line JSON over the socket API.
#
# Live coverage against a real server lives in the *-live gates; these fakes
# carry the branches a live run cannot reach on demand (no server, blocked
# agent, rejected name).

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_herdr_fake_server <dir> -> prints a fakebin dir holding a herdr stub.
# Behaviour knobs, all read at call time from the environment:
#   HERDR_SERVER      running|stopped   (default running)
#   HERDR_WORKSPACES  "id=label,id=label"  the workspaces that already exist
#   HERDR_BLOCKED     1 -> agent prompt returns agent_blocked
#   HERDR_NO_AGENT    1 -> agent prompt/get return agent_not_found
#   HERDR_AGENTS      comma list of NAMED agents (their tab carries the name)
#   HERDR_UNNAMED_AGENTS  comma list of agents whose tab has herdr's default
#                     numeric label - the pane-id-fallback case
#   HERDR_TITLE       terminal_title on every agent record (defaults to text
#                     containing "working", the rendered-text hazard)
#   HERDR_PANE_CWD    what `pane get` reports as foreground_cwd
#   HERDR_KEY_FAIL    1 -> both `agent send-keys` and `pane send-keys` refuse
#   HERDR_PANE_FILE   file whose contents `agent read`/`pane read` return
#   HERDR_RUN_MODE    echo|deaf|cmd - what the pane's shell does with `pane run`
#   HERDR_READ_FAIL   1 -> both `agent read` and `pane read` refuse
#   CALLS             file every invocation's argv is appended to
#
# EVERY error envelope goes to STDERR, as the real binary's does, and no branch
# gets to be the exception. Today every consumer of these paths merges the two
# streams, so a fake that answered on stdout would look correct - and the moment
# one stops merging (fm_herdr_read already does, deliberately, to keep tool
# chatter out of pane text) it would silently see nothing and a gate asserting
# on the error would go green against a lie. This branch has been bitten four
# times by a fake diverging from herdr 0.8.2; the stream is not worth a fifth.
fm_herdr_fake_server() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
# CALLS is optional: a suite that only needs herdr kept away from the live
# server does not have to set up call recording to use this fake.
printf '%s\n' "$*" >> "${CALLS:-/dev/null}"
ws_json() {
  local out='{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":['
  local first=1 pair id label
  IFS=,; for pair in ${HERDR_WORKSPACES:-}; do
    [ -n "$pair" ] || continue
    id=${pair%%=*}; label=${pair#*=}
    [ "$first" = 1 ] || out="$out,"
    first=0
    out="$out{\"label\":\"$label\",\"workspace_id\":\"$id\"}"
  done
  unset IFS
  printf '%s]}}\n' "$out"
}
# A real agent record carries RENDERED TEXT beside the lifecycle field - the
# terminal title, which routinely contains words like "working" while the agent
# is idle or blocked. HERDR_TITLE defaults to exactly that hazard so a caller
# that greps the whole record instead of reading agent_status is caught here.
agent_get_json() {  # <agent_status>
  printf '{"id":"cli:agent:get","result":{"agent":{"agent":"claude","agent_session":{"agent":"claude","kind":"id","value":"fake"},"agent_status":"%s","cwd":"%s","pane_id":"wZ:p9","tab_id":"wZ:t9","terminal_title":"%s","terminal_title_stripped":"%s","workspace_id":"wZ"},"type":"agent_info"}}\n' \
    "$1" "${HERDR_PANE_CWD:-/proj}" \
    "${HERDR_TITLE:-i want to start working on our fm-herdr script}" \
    "${HERDR_TITLE:-i want to start working on our fm-herdr script}"
}
# HERDR_GONE=1 is the pane that is ALREADY CLOSED - the captain shut the tab by
# hand, or herdr reaped it with its agent. Verified against herdr 0.8.2: every
# one of these verbs returns rc=1 with a *_not_found envelope for an id that no
# longer exists, which is indistinguishable by exit code alone from a close that
# genuinely could not happen.
if [ "${HERDR_GONE:-0}" = 1 ]; then
  case "$1 $2" in
    "pane get"|"pane close")
      echo '{"error":{"code":"pane_not_found","message":"pane not found"},"id":"cli:pane"}' >&2
      exit 1 ;;
    "tab close")
      echo '{"error":{"code":"tab_not_found","message":"tab not found"},"id":"cli:tab:close"}' >&2
      exit 1 ;;
  esac
fi
case "$1 $2" in
  "session list")
    # herdr manages NAMED persistent sessions, so the fake must be able to run
    # one that is not called `default` - a reachability predicate pinned to that
    # name reported a plainly-running fleet as unreachable.
    #
    # The DEFAULT is the session the verbs would reach, resolved the same way
    # fm_herdr_session resolves it, so a fake server always models a server that
    # is actually reachable. Hardcoding `default` here made the fake disagree
    # with the real binary the moment a session was pinned - the fake reported
    # `default running` while the probe asked for the pinned name. A case that
    # wants them to DIVERGE says so by setting HERDR_SESSION_NAME explicitly.
    printf 'name                 status   directory\n%-20s %s  /x\n' \
      "${HERDR_SESSION_NAME:-${HERDR_SESSION:-default}}" "${HERDR_SERVER:-running}" ;;
  "workspace list") ws_json ;;
  "workspace create")
    # A created workspace joins the live set for the rest of this process tree.
    label=""; while [ $# -gt 0 ]; do [ "$1" = --label ] && label=$2; shift; done
    printf '{"id":"cli:workspace:create","result":{"workspace":{"label":"%s","workspace_id":"wNEW"},"type":"workspace_created"}}\n' "$label"
    printf '%s\n' "wNEW=$label" >> "${HERDR_WS_CREATED:-/dev/null}" ;;
  "tab list")
    printf '{"id":"cli:tab:list","result":{"tabs":['
    first=1
    if [ -s "${HERDR_TABS:-/dev/null}" ]; then
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"label":"%s","tab_id":"wT:t9"}' "$l"
      done < "${HERDR_TABS:-/dev/null}"
    fi
    # The agents' own tabs: a named agent's tab carries its name, an unnamed
    # one carries herdr's default numeric label.
    n=0
    IFS=,; set -- ${HERDR_AGENTS:-}; unset IFS
    for a in "$@"; do
      [ -n "$a" ] || continue
      n=$((n + 1))
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"label":"%s","tab_id":"wZ:t%s","workspace_id":"wZ"}' "$a" "$n"
    done
    n=0
    IFS=,; set -- ${HERDR_UNNAMED_AGENTS:-}; unset IFS
    for a in "$@"; do
      [ -n "$a" ] || continue
      n=$((n + 1))
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"label":"%s","tab_id":"wU:t%s","workspace_id":"wZ"}' "$n" "$n"
    done
    printf '],"type":"tab_list"}}\n' ;;
  "tab create")
    ws=""; label=""; cwd=""
    while [ $# -gt 0 ]; do
      case "$1" in --workspace) ws=$2 ;; --label) label=$2 ;; --cwd) cwd=$2 ;; esac
      shift
    done
    if [ -z "$ws" ]; then
      # The real trap: an unscoped create lands wherever focus happens to be.
      echo '{"error":{"code":"missing_workspace","message":"refusing an unscoped tab create"}}' >&2
      exit 1
    fi
    printf '%s\n' "$label" >> "${HERDR_TABS:-/dev/null}"
    printf '{"id":"cli:tab:create","result":{"root_pane":{"cwd":"%s","foreground_cwd":"%s","pane_id":"%s:p2","tab_id":"%s:t2"},"tab":{"label":"%s","tab_id":"%s:t2"},"type":"tab_created"}}\n' \
      "$cwd" "$cwd" "$ws" "$ws" "$label" "$ws" ;;
  "tab rename")
    # Free text: a tab label has no character restriction. `tab rename <TAB>
    # <LABEL>`, so the LABEL is $4 - recording $3 filed the tab id under the
    # name and made every label assertion read a value nothing renamed.
    printf '%s\n' "$4" >> "${HERDR_TABS:-/dev/null}"
    printf '{"id":"cli:tab:rename","result":{"type":"ok"}}\n' ;;
  "tab close")   printf '{"id":"cli:tab:close","result":{"type":"ok"}}\n' ;;
  "pane get")
    # HERDR_NO_TAB drops tab_id, the shape a caller sees when herdr cannot give
    # a tab to rename - which is how a pane ends up unnamed.
    if [ "${HERDR_NO_TAB:-0}" = 1 ]; then
      printf '{"id":"cli:pane:get","result":{"pane":{"cwd":"%s","foreground_cwd":"%s","pane_id":"%s"},"type":"pane_info"}}\n' \
        "${HERDR_PANE_CWD:-/proj}" "${HERDR_PANE_CWD:-/proj}" "$3"
    else
      printf '{"id":"cli:pane:get","result":{"pane":{"cwd":"%s","foreground_cwd":"%s","pane_id":"%s","tab_id":"wT:t9"},"type":"pane_info"}}\n' \
        "${HERDR_PANE_CWD:-/proj}" "${HERDR_PANE_CWD:-/proj}" "$3"
    fi ;;
  "pane run")
    # The pane's SHELL, which is what the readiness probe is really asking about.
    #   echo (default) a shell at a prompt: it runs the line, so the marker comes
    #                  back on a line of its own
    #   deaf           a shell mid-command: the line is swallowed and nothing is
    #                  echoed - the state that left two secondmates dead
    #   cmd            the line is echoed as TEXT and never run, so the pane holds
    #                  the marker only inside the command it was typed in
    case "${HERDR_RUN_MODE:-echo}" in
      deaf) : ;;
      cmd)  printf '$ %s \n' "$4" >> "${HERDR_PANE_FILE:-/dev/null}" ;;
      *)    case "$4" in
              "printf '%s\n' "*) printf '%s\n' "${4##*\' }" >> "${HERDR_PANE_FILE:-/dev/null}" ;;
            esac ;;
    esac
    printf '{"id":"cli:pane:run","result":{"type":"ok"}}\n' ;;
  "pane read"|"agent read")
    # HERDR_READ_FAIL=1 refuses BOTH read verbs. A read is the first step of the
    # stale-wake and stuck-crewmate playbooks, so a dead pane and a quiet
    # crewmate must not look identical.
    if [ "${HERDR_READ_FAIL:-0}" = 1 ]; then
      echo '{"error":{"code":"pane_not_found","message":"no such pane"}}' >&2
      exit 1
    fi
    cat "${HERDR_PANE_FILE:-/dev/null}" 2>/dev/null ;;
  "pane close")  printf '{"id":"cli:pane:close","result":{"type":"ok"}}\n' ;;
  "agent list")
    # THE SHAPE THE REAL BINARY EMITS. herdr 0.8.2's AgentInfo has NO name field
    # at all - a fake that invented `agent_name` is exactly why a digest gate
    # passed green while the captain's real digest showed opaque pane ids. The
    # readable name lives on the TAB, so each agent here gets a tab that `tab
    # list` labels with its name; HERDR_UNNAMED_AGENTS get herdr's default
    # numeric tab label instead, which is the unnamed case.
    printf '{"id":"cli:agent:list","result":{"agents":['
    first=1; n=0
    IFS=,; set -- ${HERDR_AGENTS:-}; unset IFS
    for a in "$@"; do
      [ -n "$a" ] || continue
      n=$((n + 1))
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"agent":"claude","agent_status":"idle","pane_id":"wZ:p%s","tab_id":"wZ:t%s","terminal_title":"\u271b %s","terminal_title_stripped":"%s","workspace_id":"wZ"}' \
        "$n" "$n" "$a" "$a"
    done
    IFS=,; set -- ${HERDR_UNNAMED_AGENTS:-}; unset IFS
    for a in "$@"; do
      [ -n "$a" ] || continue
      n=$((n + 1))
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"agent":"claude","agent_status":"idle","pane_id":"wZ:p%s","tab_id":"wU:t%s","terminal_title":"\u271b %s","terminal_title_stripped":"%s","workspace_id":"wZ"}' \
        "$n" "$n" "$a" "$a"
    done
    printf '],"type":"agent_list"}}\n' ;;
  "agent get")
    [ "${HERDR_NO_AGENT:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}' >&2; exit 1; }
    # HERDR_STATES scripts a LIFECYCLE: successive `agent get` calls walk the
    # comma-separated list and the last entry sticks. That is what lets a test
    # model "working, then the turn ends, then a new turn starts" - the sequence
    # a queued prompt actually produces - versus "working, turn ends, stays
    # idle", which is a prompt that was swallowed.
    if [ -n "${HERDR_STATES:-}" ]; then
      _cur="${HERDR_STATE_CURSOR:-/dev/null}"
      _n=$(cat "$_cur" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
      _i=0; _st=""
      IFS=,; for _s in $HERDR_STATES; do
        _st=$_s
        [ "$_i" -ge "$_n" ] && break
        _i=$((_i + 1))
      done
      unset IFS
      [ "$_cur" = /dev/null ] || printf '%s' "$((_n + 1))" > "$_cur"
      agent_get_json "$_st"
      exit 0
    fi
    agent_get_json "${AGENT_STATE:-idle}" ;;
  "agent wait")
    # Mirrors the real verb: succeeds when the scripted lifecycle reaches one of
    # the requested states within the budget, fails otherwise.
    _want=""
    for _a in "$@"; do case "$_prev" in --until) _want="$_want $_a" ;; esac; _prev=$_a; done
    _cur="${HERDR_STATE_CURSOR:-/dev/null}"
    _n=$(cat "$_cur" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    _i=0; _st=""
    IFS=,; for _s in ${HERDR_STATES:-idle}; do
      _st=$_s
      [ "$_i" -ge "$_n" ] && break
      _i=$((_i + 1))
    done
    unset IFS
    [ "$_cur" = /dev/null ] || printf '%s' "$((_n + 1))" > "$_cur"
    for _w in $_want; do
      [ "$_w" = "$_st" ] && { printf '{"result":{"agent_status":"%s"}}\n' "$_st"; exit 0; }
    done
    echo '{"error":{"code":"timeout","message":"timed out waiting for agent status"}}' >&2
    exit 1 ;;
  "agent prompt")
    # An arbitrary failure the pattern list does not know about - a dropped
    # socket, a CLI parse error, a changed error envelope. The point is that the
    # EXIT STATUS is what makes it a failure, not the words.
    if [ -n "${HERDR_PROMPT_OUT:-}" ] || [ -n "${HERDR_PROMPT_RC:-}" ]; then
      [ -z "${HERDR_PROMPT_OUT:-}" ] || printf '%s
' "$HERDR_PROMPT_OUT" >&2
      exit "${HERDR_PROMPT_RC:-0}"
    fi
    [ "${HERDR_BLOCKED:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_blocked","message":"agent is blocked"}}' >&2; exit 1; }
    # herdr accepts the submission and THEN waits for a state change; when none
    # arrives the text has already gone in. Observed live against a claude TUI
    # herdr reported as idle while it was still booting.
    [ "${HERDR_STALLED:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed state change within 5000 ms"}}' >&2; exit 1; }
    [ "${HERDR_NO_AGENT:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}' >&2; exit 1; }
    # A prompt WITHOUT --wait is valid and is what the seam sends to an agent
    # that is already working: there, --wait "does not track turns" and can be
    # satisfied by the turn that was already running, so its verdict would be
    # about the wrong turn. The fake must not invent a rule the binary does not
    # have - doing so is what made a gate assert the opposite of the truth.
    :
    printf '{"id":"cli:agent:prompt","result":{"agent":{"agent_status":"done"},"type":"agent_info"}}\n' ;;
  "agent rename")
    name=$4
    # THE REAL CONSTRAINT, verified against herdr 0.8.2.
    if printf '%s' "$name" | grep -qE '^[a-z][a-z0-9_-]{0,31}$'; then
      printf '{"id":"cli:agent:rename","result":{"type":"ok"}}\n'
    else
      printf '{"error":{"code":"invalid_agent_name","message":"agent name must start with a lowercase letter and contain only lowercase letters, digits, %s-%s or %s_%s (1-32 characters)"},"id":"cli:agent:rename"}\n' "'" "'" "'" "'" >&2
      exit 1
    fi ;;
  "agent send-keys"|"pane send-keys")
    # HERDR_KEY_FAIL=1 refuses BOTH key verbs. Sending a key is the documented
    # trust-dialog clearing step, so its failure has to be visible.
    if [ "${HERDR_KEY_FAIL:-0}" = 1 ]; then
      echo '{"error":{"code":"pane_not_found","message":"no such pane"}}' >&2
      exit 1
    fi
    printf '{"id":"cli:%s:send-keys","result":{"type":"ok"}}\n' "$1" ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fm_herdr_fake_tmux <dir> -> a tmux that records argv and answers the few reads
# the seam performs. TMUX_RC forces a failure of the MUTATING verbs; PANE_FILE
# backs capture-pane.
#
# The READ verbs carry their own status (TMUX_LIST_RC, default 0) because the
# real binary's do: `kill-window` fails for a window that no longer exists while
# `list-windows` happily succeeds and simply does not name it, and that gap is
# precisely how a close tells "already gone" from "could not be determined". One
# shared rc would model a tmux where an absent window makes the listing fail
# too, which no tmux does - and a caller that fails open on an unreadable
# listing would then look correct here.
fm_herdr_fake_tmux() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS:-/dev/null}"
case "$1" in
  capture-pane) cat "${PANE_FILE:-/dev/null}" 2>/dev/null ;;
  display-message)
    # Two different reads share this verb: the session name (#S) and the pane's
    # cwd (#{pane_current_path}). Answering both with one value would make the
    # treehouse-get wait resolve instantly to a bogus worktree.
    case "$*" in
      *pane_current_path*) printf '%s\n' "${TMUX_CWD:-}" ;;
      *) printf '%s\n' "${TMUX_SESSION:-firstmate}" ;;
    esac ;;
  list-windows) printf '%s\n' "${TMUX_WINDOWS:-}"; exit "${TMUX_LIST_RC:-0}" ;;
  has-session) exit "${TMUX_HAS_SESSION:-0}" ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        "printf '%s\n' "*) printf '%s\n' "${a##*\' }" >> "${PANE_FILE:-/dev/null}" ;;
      esac
    done ;;
esac
exit "${TMUX_RC:-0}"
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# The named binary absent entirely: PATH with no copy of it on it at all, the
# deny shim's included. Defaults to herdr; pass tmux for the drain paths, whose
# "could not close" and "could not determine" answers differ.
fm_herdr_path_without_binary() {  # [tool]
  local tool=${1:-herdr} p out=""
  IFS=:; for p in $PATH; do
    [ -n "$p" ] || continue
    [ -x "$p/$tool" ] && continue
    out="${out:+$out:}$p"
  done
  unset IFS
  printf '%s\n' "$out"
}

# assert_eq <actual> <expected> <msg> - the shape most of these gates need, and
# one that avoids the `A && pass || fail` idiom shellcheck flags as ambiguous.
assert_eq() {
  if [ "$1" = "$2" ]; then return 0; fi
  fail "$3 (expected '$2', got '$1')"
}
