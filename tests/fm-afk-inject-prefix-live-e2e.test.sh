#!/usr/bin/env bash
# Live away-mode injection prefix guard (live-harness-optin family).
#
# A long typed line loses its head on the way into Claude Code, and with it the
# operational prefix that marks every away-mode injection, so the surviving
# tail reads as an unmarked captain message
# (docs/verification/runtime-backends.md "Away-mode transport"). A stub
# composer accepts every byte, so only the real harness can prove the fix.
# This guard drives the daemon's own escalate_add/escalate_flush path with a
# digest far longer than that limit into real Claude Code in an isolated Herdr
# lab. It requires the submitted message to open with the operational prefix
# and to name a file that holds the whole digest, and fails naming the harness
# and version rather than degrading quietly.
#
# Two independent signals can carry the verdict. Claude's own transcript keeps
# the invisible U+2063 marker, so when it is written it must open with the full
# prefix. The rendered pane drops that marker but still shows the visible head.
# A transcript that was written without the prefix fails outright.
#
# Run explicitly with FM_AFK_INJECT_PREFIX_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed "Away-mode transport" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_AFK_INJECT_PREFIX_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_AFK_INJECT_PREFIX_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name afk-inject-prefix-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-afk-inject-prefix-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$FAKEBIN" "$STATE_DIR"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-afkprefix --no-focus) \
  || fail "could not create the isolated away-mode workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done|blocked) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

export FM_STATE_OVERRIDE="$STATE_DIR" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" FM_DAEMON_PRIMARY_HARNESS=claude
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
LOG="$TMP_ROOT/daemon.log"
: > "$STATE_DIR/.afk"
: > "$TMP_ROOT/started"

# Three events of about 1100 bytes each: every one alone is over the 1022-byte
# terminal read limit, and together they are well over Claude's 800-character
# paste threshold, the shape that used to arrive tail-only.
TOKEN="FMAFKPREFIX$$_$RANDOM"
events=''
for n in 1 2 3; do
  item="$TOKEN event $n: done: PR https://example.test/pr/$n $(printf 'tail-%04d ' $(seq 1 110))"
  escalate_add "$STATE_DIR" "$item" "live guard" || fail "escalate_add could not buffer event $n"
  events="$events$item"$'\n'
done
escalate_flush "$STATE_DIR" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the daemon did not confirm delivery: $(tail -1 "$LOG" 2>/dev/null)"

DIGEST_FILE=$(sed -n 's/.*inject delivered: .*-byte digest at \(.*\))$/\1/p' "$LOG" | tail -1)
[ -n "$DIGEST_FILE" ] && [ -f "$DIGEST_FILE" ] \
  || fail "the delivered inject log line does not name an existing digest file: $(tail -1 "$LOG")"
[ "$(tail -n +2 "$DIGEST_FILE")" = "${events%$'\n'}" ] \
  || fail "the digest file does not hold every buffered event verbatim"
POINTER="Supervisor escalate: read the digest at $DIGEST_FILE (pre-read;"

# Signal 1: Claude's transcript, the harness's own record of the submitted
# message. It is absent when the session does not save transcripts, for
# example when Claude Code runs as a child of another Claude Code session.
transcript_msg=''
i=0
while [ "$i" -lt 20 ] && [ -z "$transcript_msg" ]; do
  while IFS= read -r jsonl; do
    transcript_msg=$(jq -r --arg f "$DIGEST_FILE" '
      select(.type == "user") | .message.content
      | if type == "array" then map(.text? // "") | join("") else . end
      | select(type == "string" and contains($f))' "$jsonl" 2>/dev/null | head -1)
    [ -n "$transcript_msg" ] && break
  done < <(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name '*.jsonl' -newer "$TMP_ROOT/started" 2>/dev/null)
  [ -n "$transcript_msg" ] || { i=$((i + 1)); sleep 1; }
done
signals=''
if [ -n "$transcript_msg" ]; then
  CHECKED=$((CHECKED + 1))
  case "$transcript_msg" in
    "${FM_OPERATIONAL_PREFIX}v1 away-supervisor: $POINTER"*) signals="transcript" ;;
    *) fail "Claude Code ($VERSION) on $HERDR_VER: the submitted message lost its operational prefix: $(printf '%s' "$transcript_msg" | head -c 120)" ;;
  esac
fi

# Signal 2: the rendered pane. Claude wraps a long message across rows, so
# compare with all whitespace removed.
want=$(printf '%s' "FIRSTMATE_OP: v1 away-supervisor: $POINTER" | tr -d '[:space:]')
i=0
while [ "$i" -lt 30 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null | tr -d '[:space:]' || true)
  case "$screen" in
    *"$want"*) CHECKED=$((CHECKED + 1)); signals="${signals:+$signals and }rendered pane"; break ;;
  esac
  i=$((i + 1))
  sleep 1
done

[ "$CHECKED" -gt 0 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: neither the transcript nor the rendered pane shows the submitted message opening with the operational prefix"
pass "live away-mode inject: Claude Code ($VERSION) on $HERDR_VER received a $(wc -c < "$DIGEST_FILE" | tr -d ' ')-byte digest as a prefixed pointer line (proven by the $signals) in isolated session $SESSION"
