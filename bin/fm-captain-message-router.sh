#!/usr/bin/env bash
# fm-captain-message-router.sh - Captain-message continuity router (bash owner).
#
# NOT watcher continuity. This has nothing to do with docs/watcher-continuity.md,
# the supervision/watcher cycle, or bin/fm-continuity-*. This owner routes an
# incoming CAPTAIN CHAT MESSAGE relative to primary-session open asks and
# per-session briefs so a late or unrelated reply does not silently steer the
# wrong turn. See docs/captain-message-router.md for current behavior.
#
# The Firstmate PRIMARY agent never runs this. The Pi hook calls it; bash owns
# the truth and the agent owns nothing. Submit ALWAYS spawns an ephemeral router
# agent: the model decides the verdict, and the deterministic layer survives
# only as the fail-open fallback. The built-in profile reuses upstream
# Firstmate's verified Cursor Agent CLI owner.
#
# Modes (assistant message or captain message on stdin):
#   fm-captain-message-router.sh --on-settle [--session-id <id>]
#   fm-captain-message-router.sh --on-submit [--session-id <id>] [--chat-history-file <path>]
#   fm-captain-message-router.sh --help
#
# --on-settle: extract question anchors (split on `?`, normalized, deduped) and
#   overwrite the current open-ask set. Also refresh
#   state/captain-router/sessions/<session-id>.brief (topic head + anchors) and
#   record the current session id. Deterministic multi-ask verification: if two
#   or more questions were asked but fewer than two distinct anchors survive,
#   surface a one-line warning to stderr (never blocks). stdout stays empty.
#
# --on-submit: classify the message and print exactly one machine-readable
#   verdict line to stdout:
#     verdict=<same|reroute|new> target=<session-id|-> confidence=<det|model>
#   The ephemeral Cursor router agent is spawned on EVERY submit. Its prompt carries the role
#   instructions, a bounded redacted recent-chat excerpt, every session brief,
#   and the captain message. It must answer with a three-line block:
#     verdict=<same|reroute|new>
#     target=<session-id|->
#     explanation=<up to 3 sentences>
#   `explanation` is recorded (explanations.log + the staged pending route) and
#   is NEVER forwarded into the routed/new session context. A model verdict is
#   recorded with confidence=model. Spawn error, timeout, or unparseable output
#   fails open to `same` against the current session with confidence=det and a
#   failures.log row. Every verdict is appended to verdicts.log. Reroute/new also
#   stage a durable pending route under state/captain-router/pending/. Cross-session
#   delivery is not implemented, so this owner does not compact or inject sessions.
#
# --chat-history-file <path>: optional bounded recent-transcript excerpt for the
#   submit prompt. The harness hook writes it; this owner re-bounds it
#   (FM_CAPTAIN_ROUTER_HISTORY_CHARS, default 6000; last lines kept) and redacts
#   Firstmate operational injections and secret-shaped values before the model
#   ever sees it. Absent or empty means the model gets briefs + message only.
#
# Session id (assumption, labeled): prefer --session-id, else
#   FM_CAPTAIN_ROUTER_SESSION_ID, else the prior current.session pointer, else
#   the stable home-scoped fallback `primary`. Hooks should pass the harness
#   session id when available.
#
# State (all local-only, never committed), under $STATE/captain-router/:
#   anchors.current       - one normalized open-ask anchor per line (settle)
#   current.session       - session id for the live primary this home last settled
#   sessions/<id>.brief   - per-session topic head + anchors
#   pending/<ts>-<digest>.route - staged reroute/new handoff for later delivery
#   pending/LATEST        - basename of the most recent pending route file
#   verdicts.log          - append-only verdict rows
#   explanations.log      - append-only model rationale rows, keyed by the same
#                           message digest as verdicts.log (audit only, never
#                           forwarded into any session prompt)
#   failures.log          - append-only fail-open failure rows
#
# Router agent override (tests): FM_CAPTAIN_ROUTER_AGENT_CMD, when set, is
# executed instead of the configured CLI. The command receives the prompt on stdin and must
# print a parseable verdict block on stdout. No real model calls in unit tests.
# FM_CAPTAIN_ROUTER_TIMEOUT_SECS (default 90) bounds the spawn when a `timeout`
# or `gtimeout` binary is available.
#
# Scope: a genuine firstmate PRIMARY home only (main home or a marked secondmate
# home), exactly like bin/fm-sessionstart-nudge.sh. It is inert (silent exit 0) in
# a child crew/scout worktree and for a no-mistakes gate agent.
#
# FAIL-OPEN: every error path (bad scope, missing dir, empty input, missing
# hashing tool, router spawn/parse failure) exits 0 and never blocks the captain.
# Only invalid CLI usage exits non-zero. The captain is never locked out by a
# broken router.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ROUTER_DIR="$STATE/captain-router"
ANCHORS_FILE="$ROUTER_DIR/anchors.current"
CURRENT_SESSION_FILE="$ROUTER_DIR/current.session"
SESSIONS_DIR="$ROUTER_DIR/sessions"
PENDING_DIR="$ROUTER_DIR/pending"
VERDICTS_LOG="$ROUTER_DIR/verdicts.log"
EXPLANATIONS_LOG="$ROUTER_DIR/explanations.log"
FAILURES_LOG="$ROUTER_DIR/failures.log"

# Cursor encodes the classifier effort in the model id and has no separate
# effort flag. The model remains overridable without adding a fork-specific
# harness configuration schema.
ROUTER_MODEL=${FM_CAPTAIN_ROUTER_MODEL:-cursor-grok-4.6-low}

# Bounds for the recent-chat excerpt handed to the router model.
HISTORY_CHAR_CAP=${FM_CAPTAIN_ROUTER_HISTORY_CHARS:-6000}
case "$HISTORY_CHAR_CAP" in
'' | *[!0-9]*) HISTORY_CHAR_CAP=6000 ;;
esac
ROUTER_TIMEOUT_SECS=${FM_CAPTAIN_ROUTER_TIMEOUT_SECS:-90}
case "$ROUTER_TIMEOUT_SECS" in
'' | *[!0-9]*) ROUTER_TIMEOUT_SECS=90 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

usage() {
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# extract_anchors: read text on stdin, print one normalized question anchor per
# line. Newlines fold to spaces, the text splits on `?`, and each question keeps
# only the clause after its last sentence terminator, lowercased and reduced to
# space-separated alphanumeric words. Not deduped here (the caller dedupes so it
# can also see the raw pre-dedup count for multi-ask verification).
extract_anchors() {
	tr '\n' ' ' | awk '
    {
      n = split($0, parts, "?")
      for (i = 1; i < n; i++) {
        q = parts[i]
        gsub(/.*[.!]/, "", q)
        q = tolower(q)
        gsub(/[^a-z0-9]+/, " ", q)
        gsub(/^ +| +$/, "", q)
        if (q ~ /[a-z0-9]/) print q
      }
    }
  '
}

digest_message() {
	{ shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk '{print substr($1,1,12)}'
}

iso_now() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown\n'
}

record_verdict() { # <verdict> <target> <confidence>; message on stdin
	local verdict=$1 target=$2 conf=$3 ts digest
	ts=$(iso_now)
	digest=$(digest_message)
	[ -n "$digest" ] || digest=nodigest
	printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$verdict" "$target" "$conf" "$digest" >>"$VERDICTS_LOG"
}

# record_explanation: audit-only rationale row, keyed by the same message digest
# as verdicts.log. This file is never read back into any session prompt.
record_explanation() { # <verdict> <target> <digest> <explanation>
	local verdict=$1 target=$2 digest=$3 text=$4 ts
	[ -n "$text" ] || return 0
	ts=$(iso_now)
	text=$(printf '%s' "$text" | tr '\n\t' '  ')
	printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$verdict" "$target" "$digest" "$text" \
		>>"$EXPLANATIONS_LOG" 2>/dev/null || true
}

record_failure() { # <note>
	local ts
	ts=$(iso_now)
	printf '%s\t%s\n' "$ts" "$1" >>"$FAILURES_LOG" 2>/dev/null || true
}

# Resolve the session id for this invocation.
resolve_session_id() {
	local sid=${SESSION_ID_ARG-}
	if [ -z "$sid" ]; then
		sid=${FM_CAPTAIN_ROUTER_SESSION_ID-}
	fi
	if [ -z "$sid" ] && [ -s "$CURRENT_SESSION_FILE" ]; then
		IFS= read -r sid <"$CURRENT_SESSION_FILE" || sid=
		sid=${sid//[[:space:]]/}
	fi
	if [ -z "$sid" ]; then
		sid=primary
	fi
	# Keep filenames safe.
	case "$sid" in
	*[!A-Za-z0-9._-]*) sid=primary ;;
	esac
	printf '%s\n' "$sid"
}

topic_head() {
	# Single-line topic from settle text: collapse whitespace, truncate.
	tr '\n' ' ' | awk '{
      gsub(/[ \t]+/, " ")
      gsub(/^ +| +$/, "")
      if (length($0) > 160) $0 = substr($0, 1, 157) "..."
      print
    }'
}

write_session_brief() { # <session-id> <topic> ; anchors on stdin (or empty)
	local sid=$1 topic=$2 brief tmp
	brief="$SESSIONS_DIR/$sid.brief"
	tmp="$brief.tmp.$$"
	mkdir -p "$SESSIONS_DIR" 2>/dev/null || return 0
	{
		printf 'session_id=%s\n' "$sid"
		printf 'updated=%s\n' "$(iso_now)"
		printf 'topic=%s\n' "$topic"
		printf -- '---\n'
		awk 'NF'
	} >"$tmp" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		return 0
	}
	mv -f "$tmp" "$brief" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

stage_pending_route() { # <verdict> <target> <confidence> <explanation> ; message on stdin
	local verdict=$1 target=$2 conf=$3 explanation=${4-} ts digest path rel msg
	msg=$(cat)
	ts=$(iso_now | tr -d ':-')
	digest=$(printf '%s' "$msg" | digest_message)
	[ -n "$digest" ] || digest=nodigest
	mkdir -p "$PENDING_DIR" 2>/dev/null || return 0
	rel="${ts}-${digest}.route"
	path="$PENDING_DIR/$rel"
	{
		printf 'verdict=%s\n' "$verdict"
		printf 'target=%s\n' "$target"
		printf 'confidence=%s\n' "$conf"
		printf 'session_from=%s\n' "$(resolve_session_id)"
		printf 'created=%s\n' "$(iso_now)"
		printf 'message_digest=%s\n' "$digest"
		# Audit-only rationale. Header side of the file, never the message body
		# that a later cross-session delivery would carry into the target session.
		[ -n "$explanation" ] &&
			printf 'explanation=%s\n' "$(printf '%s' "$explanation" | tr '\n' ' ')"
		printf -- '---\n'
		printf '%s\n' "$msg"
	} >"$path" 2>/dev/null || return 0
	printf '%s\n' "$rel" >"$PENDING_DIR/LATEST" 2>/dev/null || true
}

# redact_history: read a raw transcript excerpt on stdin, print a bounded,
# privacy-safe version. Drops any line carrying a Firstmate operational
# injection (the FIRSTMATE_OP carrier, the from-firstmate label, or a legacy
# wake/turn-end payload) and masks secret-shaped tokens before the excerpt
# reaches the model.
redact_history() {
	awk '
    index($0, "FIRSTMATE_OP:") { next }
    index($0, "[fm-from-firstmate]") { next }
    index($0, "FIRSTMATE WATCHER WAKE:") { next }
    index($0, "TURN WOULD END BLIND") { next }
    {
      n = split($0, w, / /)
      out = ""
      prev = ""
      for (i = 1; i <= n; i++) {
        t = tolower(w[i])
        if (t ~ /(token|secret|password|passwd|api_?key|access_?key|authorization)[^a-z0-9]*[:=]/) {
          sub(/[:=].*/, "=[redacted]", w[i])
        } else if (t ~ /^(sk|pk|ghp|gho|ghu|ghs|ghr|github_pat|ntn)[-_]/ || t ~ /^xox[abposr]-/) {
          w[i] = "[redacted]"
        } else if (prev ~ /^(bearer|token|secret|password|passwd|api_?key|access_?key)$/) {
          w[i] = "[redacted]"
        }
        # Keep only the bare keyword so `password:` still guards the next word.
        prev = t
        gsub(/[^a-z0-9_]/, "", prev)
        out = (i == 1 ? w[i] : out " " w[i])
      }
      print out
    }
  ' | tail -c "$HISTORY_CHAR_CAP"
}

build_router_prompt() { # <current-id> <message-file> [history-file]
	local cur=$1 msgfile=$2 histfile=${3-} sid brief history=
	printf 'You are the Firstmate captain-message continuity router.\n'
	printf 'Firstmate runs several long-lived work sessions for one captain, and each\n'
	printf 'session has a brief describing what it is about. Your job is to decide where\n'
	printf 'THIS captain message belongs, using the live conversation and every brief.\n\n'
	printf 'Verdicts:\n'
	printf '  same    - the message continues the current session conversation\n'
	printf '  reroute - the message belongs to a different existing session\n'
	printf '  new     - the message starts work that fits no existing session\n\n'
	printf 'Prefer "same" for ordinary in-conversation replies, follow-ups, corrections,\n'
	printf 'objections, and acknowledgements, even when they share no literal words with\n'
	printf 'the last assistant turn. Choose "reroute" only when the message clearly\n'
	printf 'belongs to a different named session below. Choose "new" only when it starts\n'
	printf 'work that fits no listed session.\n\n'
	printf 'Reply with EXACTLY these three lines and nothing else:\n'
	printf 'verdict=<same|reroute|new>\n'
	printf 'target=<session-id|->\n'
	printf 'explanation=<up to 3 sentences on one line: why this verdict, what context this belongs to>\n\n'
	printf 'Use target=- for verdict=new. For verdict=same use the current session id.\n'
	printf 'For verdict=reroute, target must be one of the session ids listed below.\n'
	printf 'Current session id: %s\n' "$cur"
	if [ -n "$histfile" ] && [ -s "$histfile" ]; then
		history=$(redact_history <"$histfile" 2>/dev/null || true)
	fi
	printf '\n=== RECENT CHAT HISTORY (current session, bounded and redacted) ===\n'
	if [ -n "$history" ]; then
		printf '%s\n' "$history"
	else
		printf '(none available)\n'
	fi
	printf '\n=== SESSION BRIEFS (what each known session is about) ===\n'
	if [ -d "$SESSIONS_DIR" ]; then
		for brief in "$SESSIONS_DIR"/*.brief; do
			[ -f "$brief" ] || continue
			sid=$(basename "$brief" .brief)
			printf -- '--- session %s ---\n' "$sid"
			cat "$brief"
			printf '\n'
		done
	else
		printf '(none)\n'
	fi
	printf '\n=== CAPTAIN MESSAGE (classify this) ===\n'
	cat "$msgfile"
	printf '\n'
}

# Spawn the ephemeral router agent. Prompt on stdin of the agent command.
# Prints agent stdout. Returns 0 on spawn success (even if verdict is bad).
# Bounded by FM_CAPTAIN_ROUTER_TIMEOUT_SECS when a timeout binary exists, so a
# hung model cannot stall the captain's turn; a timeout is a fail-open failure.
spawn_router_agent() { # prompt on stdin
	local prompt_file out status=0 cmd bound=
	prompt_file=$(mktemp "$ROUTER_DIR/prompt.XXXXXX" 2>/dev/null) || return 1
	cat >"$prompt_file" || {
		rm -f "$prompt_file"
		return 1
	}
	if command -v timeout >/dev/null 2>&1; then
		bound=timeout
	elif command -v gtimeout >/dev/null 2>&1; then
		bound=gtimeout
	fi
	if [ -n "${FM_CAPTAIN_ROUTER_AGENT_CMD-}" ]; then
		# shellcheck disable=SC2086 # intentional word-split of override command
		out=$(eval "$FM_CAPTAIN_ROUTER_AGENT_CMD" <"$prompt_file" 2>/dev/null) || status=$?
	else
		# Reuse upstream's verified resolver instead of carrying another Cursor
		# executable rule in the fork. Ask mode is read-only; --trust only skips
		# the headless workspace prompt and grants no write-capable mode.
		cmd=$(fm_cursor_resolve_binary 2>/dev/null || true)
		if [ -z "$cmd" ]; then
			rm -f "$prompt_file"
			record_failure "Cursor Agent CLI not found"
			return 1
		fi
		if [ -n "$bound" ]; then
			out=$("$bound" "$ROUTER_TIMEOUT_SECS" env \
				-u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_INVOKED_AS \
				"$cmd" --print --output-format text --mode ask --trust \
				--workspace "$FM_HOME" --model "$ROUTER_MODEL" "$(cat "$prompt_file")" 2>/dev/null) || status=$?
		else
			out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_INVOKED_AS \
				"$cmd" --print --output-format text --mode ask --trust \
				--workspace "$FM_HOME" --model "$ROUTER_MODEL" "$(cat "$prompt_file")" 2>/dev/null) || status=$?
		fi
	fi
	rm -f "$prompt_file"
	if [ "$status" -ne 0 ]; then
		if [ "$status" -eq 124 ]; then
			record_failure "router agent timed out after ${ROUTER_TIMEOUT_SECS}s"
		else
			record_failure "router agent exited $status"
		fi
		return 1
	fi
	printf '%s\n' "$out"
	return 0
}

# parse_verdict_block: read the model's reply and set PARSE_VERDICT,
# PARSE_TARGET, PARSE_EXPLANATION. Accepts the three-line block and, for
# resilience, a single `verdict=... target=...` line. Returns 0 when a valid,
# validated verdict was recovered; every other case is a fail-open failure.
parse_verdict_block() { # <blob>
	local blob=$1
	PARSE_VERDICT=
	PARSE_TARGET=
	PARSE_EXPLANATION=
	PARSE_VERDICT=$(printf '%s\n' "$blob" |
		sed -n 's/^[[:space:]]*verdict=\([A-Za-z]*\).*/\1/p' | head -n 1)
	PARSE_TARGET=$(printf '%s\n' "$blob" |
		sed -n 's/^[[:space:]]*verdict=[A-Za-z]*[[:space:]][[:space:]]*target=\([^[:space:]]*\).*/\1/p' | head -n 1)
	if [ -z "$PARSE_TARGET" ]; then
		PARSE_TARGET=$(printf '%s\n' "$blob" |
			sed -n 's/^[[:space:]]*target=\([^[:space:]]*\).*/\1/p' | head -n 1)
	fi
	PARSE_EXPLANATION=$(printf '%s\n' "$blob" |
		sed -n 's/^[[:space:]]*explanation=//p' | head -n 3 | tr '\n' ' ')
	PARSE_EXPLANATION=${PARSE_EXPLANATION%"${PARSE_EXPLANATION##*[![:space:]]}"}
	case "$PARSE_VERDICT" in
	same | reroute | new) ;;
	*) return 1 ;;
	esac
	[ -n "$PARSE_TARGET" ] || return 1
	case "$PARSE_TARGET" in
	*[!A-Za-z0-9._-]*) [ "$PARSE_TARGET" = - ] || return 1 ;;
	esac
	if [ "$PARSE_VERDICT" = new ]; then
		PARSE_TARGET=-
	fi
	if [ "$PARSE_VERDICT" = same ]; then
		PARSE_TARGET=$(resolve_session_id)
	fi
	if [ "$PARSE_VERDICT" = reroute ]; then
		[ "$PARSE_TARGET" != - ] || return 1
		[ -f "$SESSIONS_DIR/$PARSE_TARGET.brief" ] || return 1
	fi
	return 0
}

# emit_verdict: record, stage, and print one verdict. The optional explanation is
# audit-only: it lands in explanations.log and the pending route header, and is
# never printed on the wire line or forwarded into any routed session context.
emit_verdict() { # <verdict> <target> <confidence> [explanation] ; message on stdin
	local verdict=$1 target=$2 conf=$3 explanation=${4-} msg digest
	msg=$(cat)
	printf '%s' "$msg" | record_verdict "$verdict" "$target" "$conf"
	if [ -n "$explanation" ]; then
		digest=$(printf '%s' "$msg" | digest_message)
		[ -n "$digest" ] || digest=nodigest
		record_explanation "$verdict" "$target" "$digest" "$explanation"
	fi
	case "$verdict" in
	reroute | new)
		printf '%s' "$msg" | stage_pending_route "$verdict" "$target" "$conf" "$explanation"
		;;
	esac
	printf 'verdict=%s target=%s confidence=%s\n' "$verdict" "$target" "$conf"
}

# --- CLI -------------------------------------------------------------------

SESSION_ID_ARG=
CHAT_HISTORY_FILE=
mode=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	--on-settle | --on-submit)
		mode=$1
		shift
		;;
	--session-id)
		shift
		SESSION_ID_ARG=${1-}
		[ -n "$SESSION_ID_ARG" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--session-id=*)
		SESSION_ID_ARG=${1#--session-id=}
		[ -n "$SESSION_ID_ARG" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--chat-history-file)
		shift
		CHAT_HISTORY_FILE=${1-}
		[ -n "$CHAT_HISTORY_FILE" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--chat-history-file=*)
		CHAT_HISTORY_FILE=${1#--chat-history-file=}
		[ -n "$CHAT_HISTORY_FILE" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

[ -n "$mode" ] || {
	usage >&2
	exit 2
}

# Inert for a gate agent or outside a genuine primary. Fail-open: silent exit 0.
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
mkdir -p "$ROUTER_DIR" 2>/dev/null || exit 0

session_id=$(resolve_session_id)

if [ "$mode" = --on-settle ]; then
	msg=$(cat)
	raw_anchors=$(printf '%s' "$msg" | extract_anchors)
	uniq_anchors=$(printf '%s\n' "$raw_anchors" | awk 'NF && !seen[$0]++')
	raw_count=$(printf '%s\n' "$raw_anchors" | awk 'NF{c++} END{print c+0}')
	uniq_count=$(printf '%s\n' "$uniq_anchors" | awk 'NF{c++} END{print c+0}')
	printf '%s\n' "$uniq_anchors" | awk 'NF' >"$ANCHORS_FILE" 2>/dev/null || exit 0
	printf '%s\n' "$session_id" >"$CURRENT_SESSION_FILE" 2>/dev/null || true
	topic=$(printf '%s' "$msg" | topic_head)
	printf '%s\n' "$uniq_anchors" | write_session_brief "$session_id" "$topic"
	if [ "$raw_count" -ge 2 ] && [ "$uniq_count" -lt 2 ]; then
		printf 'captain-router: multi-ask verification - %s question(s) asked but %s distinct anchor(s) recorded\n' \
			"$raw_count" "$uniq_count" >&2
	fi
	exit 0
fi

# --on-submit: the model always decides. The deterministic layer below survives
# only as the fail-open fallback when the spawn errors, times out, or returns
# something unparseable, so a broken router never locks the captain out.
msg=$(cat)

tmpmsg=$(mktemp "$ROUTER_DIR/msg.XXXXXX" 2>/dev/null) || {
	record_failure "could not create temp message file"
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
}
printf '%s' "$msg" >"$tmpmsg" 2>/dev/null || {
	rm -f "$tmpmsg"
	record_failure "could not write temp message file"
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
}

agent_out=
if agent_out=$(build_router_prompt "$session_id" "$tmpmsg" "$CHAT_HISTORY_FILE" | spawn_router_agent); then
	rm -f "$tmpmsg"
	if parse_verdict_block "$agent_out"; then
		printf '%s' "$msg" |
			emit_verdict "$PARSE_VERDICT" "$PARSE_TARGET" model "$PARSE_EXPLANATION"
		exit 0
	fi
	record_failure "router agent returned unparseable verdict"
else
	rm -f "$tmpmsg"
	# spawn_router_agent already recorded the failure when it could.
fi

# Fail-open: allow into the current primary.
printf '%s' "$msg" | emit_verdict same "$session_id" det
exit 0
