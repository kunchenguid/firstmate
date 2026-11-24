#!/usr/bin/env bash
# Real, idle Pi/Pi-signed and Claude TUIs display followed-PR outcomes without
# submitting a prompt. Only forge reads are fake; no PR or model is contacted.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PR_FOLLOW_LIVE_E2E tmux jq node
TMP_ROOT=$(fm_test_tmproot fm-pr-follow-live)
SOCKET="fm-follow-$$"
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT

mkdir -p "$TMP_ROOT/tools"
cat > "$TMP_ROOT/tools/gh" <<'SH'
#!/usr/bin/env bash
cat "$FM_FOLLOW_FIXTURE"
SH
chmod +x "$TMP_ROOT/tools/gh"
cat > "$TMP_ROOT/fixture.ts" <<'TS'
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { loadSkillsFromDir } from "@earendil-works/pi-coding-agent";
export default function(pi) {
  pi.on("session_start", (_event, ctx) => {
    const state = `${process.env.FM_HOME}/state`;
    mkdirSync(state, {recursive:true});
    execFileSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-lock.sh`], {stdio: "ignore"});
    writeFileSync(`${process.env.FM_HOME}/project-skills.json`, JSON.stringify(
      loadSkillsFromDir({dir: `${process.env.FM_ROOT_OVERRIDE}/.agents/skills`, source: "project"}).skills));
    // Pi keeps a never-prompted session in memory, so inspect its live entries.
    setInterval(() => writeFileSync(`${process.env.FM_HOME}/entries.json`,
      JSON.stringify(ctx.sessionManager.getEntries())), 100).unref();
  });
  pi.on("before_agent_start", () => {
    appendFileSync(`${process.env.FM_HOME}/turns`, "turn\n");
    throw new Error("This idle presentation test must not start a model turn");
  });
}
TS

screen() { tmux -L "$SOCKET" capture-pane -p -S -500 -t subject 2>/dev/null || true; }
wait_marker() {
  local i shot
  for i in $(seq 1 120); do
    [ ! -s "$home/state/.pr-follow-surface" ] || return 0
    shot=$(screen)
    case "$shot" in
      *'Yes, I trust this folder'*) tmux -L "$SOCKET" send-keys -t subject Down Enter ;;
    esac
    sleep 0.25
  done
  screen >&2
  fail "$harness $version did not advertise its live outcome surface"
}
wait_notice() {
  local i
  for i in $(seq 1 120); do
    if [ "$(tr -d '\n' 2>/dev/null < "$home/state/.branch-notices-cursor" || true)" = "$1" ] \
      && screen | grep -F "$2" >/dev/null; then return 0; fi
    sleep 0.25
  done
  screen >&2
  fail "$harness $version did not show $2 without a prompt"
}
fixture() {
  jq -n --arg state "$1" --arg conclusion "${2:-SUCCESS}" --arg head "${3:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    '{state:$state,headRefOid:$head,reviewDecision:"APPROVED",statusCheckRollup:[{name:"test",status:"COMPLETED",conclusion:$conclusion}]}' > "$FM_FOLLOW_FIXTURE"
}
follow() { bash "$ROOT/bin/fm-pr-follow.sh" "$@"; }
ran=0
for harness in pi pi-signed claude; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf 'skip: %s is not installed for the live PR-follow proof\n' "$harness"
    continue
  fi
  version=$("$harness" --version)
  home="$TMP_ROOT/$harness"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/project" "$home/agent"
  touch "$home/config/pr-follow"
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT"
  export FM_FOLLOW_FIXTURE="$home/forge.json"
  export PATH="$TMP_ROOT/tools:$PATH"
  if [ "$harness" = claude ]; then
    # Claude Code writes tsconfig.json and types into a --plugin-dir, which would
    # dirty the checkout and fail the mod-shape test; load a private copy.
    cp -R "$ROOT/.claude/mods/firstmate-calm" "$home/calm"
    session=$(node -e 'console.log(require("node:crypto").randomUUID())')
    printf '%s\n' "$session" > "$home/state/.lock-session"
    command="exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CONFIG_DIR CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --session-id '$session' --setting-sources project --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --plugin-dir '$home/calm' --debug-file '$home/debug.log'"
  else
    command="exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PI_CODING_AGENT_DIR='$home/agent' $harness --offline --no-extensions --no-mcp --no-skills --no-prompt-templates --no-context-files --no-themes --session-dir '$home/sessions' -e '$TMP_ROOT/fixture.ts' -e '$ROOT/.pi/extensions/fm-branch-supervision.ts'"
  fi
  tmux -L "$SOCKET" new-session -d -s subject -x 220 -y 55 -c "$home/project" \
    "export FM_HOME='$home' FM_ROOT_OVERRIDE='$ROOT' FM_STATE_OVERRIDE='$home/state' FM_DATA_OVERRIDE='$home/data' FM_CONFIG_OVERRIDE='$home/config' FM_FOLLOW_FIXTURE='$home/forge.json' PATH='$PATH'; $command"
  if [ "$harness" = claude ]; then tmux -L "$SOCKET" display-message -p -t subject '#{pane_pid}' > "$home/state/.lock"; fi
  wait_marker
  if [ "$harness" != claude ]; then
    jq -e 'length > 0 and all(.[]; .name != "pr-follow")' "$home/project-skills.json" >/dev/null \
      || fail "$harness advertised a follow trigger in the unconditional skill index"
  fi
  for event in merged closed failed; do
    case "$event" in merged) number=1; word=MERGED ;; closed) number=2; word=CLOSED ;; failed) number=3; word=FAILURE ;; esac
    url="https://github.com/example/project/pull/$number"
    fixture OPEN
    follow add "$url" --requested "Tell me about $event" >/dev/null
    case "$event" in merged) fixture MERGED ;; closed) fixture CLOSED ;; failed) fixture OPEN FAILURE bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;; esac
    follow poll
    follow poll
    wait_notice "$number" "$word"
    [ "$(screen | grep -F -c "$url")" = 1 ] || { screen >&2; fail "$harness rendered duplicate outcome lines for $url"; }
    follow remove "$url" >/dev/null
  done
  [ ! -s "$home/state/.wake-queue" ] || fail "$harness queued a model wake for an informational follow"
  [ ! -e "$home/state/.branch-session" ] || fail "$harness opened a supervision model session"
  [ ! -s "$home/turns" ] || fail "$harness opened a primary model turn"
  if [ "$harness" != claude ]; then
    for _ in $(seq 1 40); do
      if jq -e '[.[] | select(.customType == "fm-branch-visible-outcome")] | length == 3' "$home/entries.json" >/dev/null 2>&1; then break; fi
      sleep 0.25
    done
    jq -e '[.[] | select(.customType == "fm-branch-visible-outcome")] | length == 3' "$home/entries.json" >/dev/null || fail 'direct transcript entries missing or duplicated'
    jq -e 'all(.[]; .type != "message" or (.message.role != "user" and .message.role != "assistant"))' "$home/entries.json" >/dev/null || fail 'primary transcript gained a model turn'
  else
    # Claude logs model requests even if authentication fails before a response.
    if grep -E 'API Request|api_request|Query.*model|Sending.*request.*anthropic' "$home/debug.log" >/dev/null; then
      fail "Claude $version attempted a model request during idle presentation"
    fi
  fi
  screen | grep -E 'MERGED:|CLOSED:|Checks test: FAILURE' || fail "$harness outcome lines disappeared"
  pass "$harness $version: three taskless forge changes produced three visible lines, no primary turn or wake"
  tmux -L "$SOCKET" kill-session -t subject
  ran=$((ran + 1))
done
[ "$ran" -gt 0 ] || fail 'no installed primary was exercised'
