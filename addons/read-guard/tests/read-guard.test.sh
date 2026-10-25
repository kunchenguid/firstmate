#!/usr/bin/env bash
# End-to-end guard proof with fixture HOME only.
# shellcheck disable=SC2016 # protected shell references are literal test input
set -euo pipefail
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
H=$T/home; mkdir -p "$H/.claude" "$H/.pi/agent" "$H/.config/opencode" "$H/.local/state/crewhouse/people/person1" "$H/.local/share/byokit/people/1" "$H/.codex" "$H/.local/share/opencode" "$H/.pi/agent" "$H/.no-mistakes"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$H/.claude/settings.json"
mkdir -p "$T/pool1" "$H/.muxr/plans"; echo '{}' > "$T/pool1/settings.json" # a pool account's CLAUDE_CONFIG_DIR
jq -n --arg f "$T/pool1" '{accounts: [{provider: "claude", folder: $f}]}' > "$H/.muxr/plans/accounts-v1.json"
HOME=$H XDG_DATA_HOME=$H/.local/share "$ADDON/install.sh" >/dev/null
jq -e '[.hooks.PreToolUse[].hooks[].command] == ["node '\''\($d)/fm-read-guard/guard.mjs'\''"]' --arg d "$H/.local/share" "$T/pool1/settings.json" >/dev/null || { echo "FAIL pool account settings lack the hook"; exit 1; }
G=$H/.local/share/fm-read-guard/guard.mjs
run() { HOME=$H node "$G" --runtime claude; }
block() {
  local rc=0 err
  err=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg s "$1" '$s')" | run 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [[ "$err" == *"BLOCKED by the fleet read guard"* && "$err" == *"block is final"* ]] || { echo "FAIL not blocked: $1"; return 1; }
}
allow() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg s "$1" '$s')" | run >/dev/null
}
for cmd in \
  'cat ~/.local/share/opencode/auth.json | head -c 300' \
  'cat "$HOME/.codex/auth.json"' \
  'cp ${HOME}/.pi/agent/auth.json /tmp/copy' \
  'base64 ~/.claude/.credentials.json' \
  'jq ~/.no-mistakes/config.yaml' \
  'grep ~/.local/state/crewhouse/people/person1/auth.json' \
  'cat ~/.codex/auth*' \
  'ls $(cat ~/.codex/auth.json)' \
  'python -c "open(\"$HOME/.claude/.credentials.json\").read()"' \
  'grep -r key ~/.codex' \
  'tar czf x ~/.codex' \
  'cp -r ~/.pi/agent /tmp' \
  'rsync ~/.local/share/opencode/ x' \
  'cd ~/.local/share/opencode && cat auth.json' \
  'cat ~/.claude' \
  'cat ~/.codex/*' \
  'cat ~/.codex/a*' \
  'cat ~/*/auth.json' \
  'grep -r secret ~/.no-mistakes' \
  'cat ~/.muxr/plans/claude/f22e0bd0/.credentials.json' \
  'cp -r ~/.local/share/byokit/people/1 /tmp'; do block "$cmd"; done
# Non-secret files and runtime session data remain readable.
allow 'cat ~/.pi/agent/sessions/x/y.jsonl'
allow 'cat ~/.codex/config.toml'
allow 'ls ~/.no-mistakes/evidence'
allow 'grep -r foo ~/.pi/agent/sessions'
# 13:38Z BYOKit stored credential path.
block 'cat ~/.local/share/byokit/people/1/auth.json'
# 13:39Z Python one-liner embeds the absolute fixture path in a code token.
block "python3 -c \"print(open('$H/.pi/agent/auth.json').read())\""
# 13:39Z Node one-liner concatenates HOME with a protected-path suffix.
block 'node -e "console.log(require(\\"fs\\").readFileSync(process.env.HOME+\\"/.pi/agent/auth.json\\",\\"utf8\\"))"'
# 13:39Z heredoc body also contains a protected credential path.
block "python3 - <<'EOF'
printf(open('$H/.pi/agent/auth.json').read())
EOF"
block "cat $H/.codex/auth.json"
block 'cat ~/.local/state/crewhouse/people/*/auth.json'
allow 'ls -l ~/.codex/auth.json'
allow "ls -l $H/.codex/auth.json"
allow 'stat ~/.local/share/opencode/auth.json'
allow 'test -e "$HOME/.claude/.credentials.json"'
# A markdown report is body text, not a path: bold markers and question marks pass.
STARS=$(printf '\052\052')
allow "cat > $T/report.md <<'EOF'
## Report
Status ${STARS} why? ${STARS} done
EOF"
# A JS doc-comment opener is text: a "/**" or "/*" fragment is not a root-wide glob, whether written in a heredoc or echoed.
OPEN=$(printf '/\052\052')
allow "cat > $T/doc.js <<'EOF'
$OPEN
 * Docs
 */
EOF"
for opener in "$OPEN" "$(printf '/\052')" "$(printf '/\052\052/')"; do allow "echo $opener"; done
# Text-only commands (echo, printf, fm-send.sh) may name a login folder as an example.
allow "bin/fm-send.sh task-1 'never read ~/.codex'"
allow "echo 'never read ~/.codex/auth.json'"
allow "printf '%s\n' 'never read ~/.codex'"
# Text-only commands still block when a login path is substituted, redirected, read as input, or chained after a read.
block 'echo "$(cat ~/.codex/auth.json)"'
block 'bin/fm-send.sh task-1 "$(cat ~/.codex/auth.json)"'
block 'bin/fm-send.sh task-1 < ~/.codex/auth.json'
block 'echo hi > ~/.codex/auth.json'
block 'echo hi; cat ~/.codex/auth.json'
# A piped text-only command passes its path on to a reader, so the whole command must have no pipe.
block "printf '%s\n' ~/.codex/auth.json | xargs cat"
block 'echo ~/.codex/auth.json | sh'
# A glob with no literal path segment is text, but "~/" plus a wildcard is still a glob reference.
TILDE_GLOB=$(printf '\176/\052\052')
block "cat $TILDE_GLOB"
# Absolute globs with a literal segment (the fixture root) still block.
block "cat $T/*/.pi/agent/*"
block "cat $T/*/.codex/*"
# The exact incident command reaches the installed Claude PreToolUse hook and is refused.
HOOK=$(jq -r '.hooks.PreToolUse[] | select(.matcher | contains("Bash")) | .hooks[] | select(.command | contains("fm-read-guard")) | .command' "$H/.claude/settings.json")
printf '{"tool_name":"Bash","tool_input":{"command":"cat ~/.local/share/opencode/auth.json | head -c 300"}}' |
  HOME=$H bash -c "$HOOK" >/dev/null 2>"$T/hook.err" && { echo 'FAIL Claude hook allowed defect command'; exit 1; } || rc=$?
[ "${rc:-0}" -eq 2 ] && grep -q 'BLOCKED by the fleet read guard' "$T/hook.err"
# Drive the installed pi entry point, not a direct call to the shared function.
cat > "$T/pi.mjs" <<'EOF'
process.argv[1] = "/$bunfs/root/pi";
const hooks = {}, ext = await import(process.argv[2]);
ext.default({ on: (name, fn) => hooks[name] = fn });
for (const event of [
  { toolName: "bash", input: { command: "cat ~/.local/share/opencode/auth.json | head -c 300" } },
  { toolName: "read", input: { path: `${process.env.HOME}/.codex/auth.json` } },
]) {
  const result = await hooks.tool_call(event);
  if (!result?.block || !result.reason.includes("block is final")) process.exit(1);
}
EOF
HOME=$H node "$T/pi.mjs" "$H/.pi/agent/extensions/fm-read-guard.ts" >/dev/null
# Pi Read and Claude Read/Grep/Glob tool inputs are blocked too.
node --input-type=module - "$G" "$H" <<'EOF'
const { guardTool } = await import(process.argv[2]); const home = process.argv[3];
for (const [tool, input] of [["read", {path:`${home}/.codex/auth.json`}], ["Read", {file_path:`${home}/.claude/.credentials.json`}], ["Grep", {path:`${home}/.pi/agent/auth.json`}], ["Grep", {path:"~/.codex"}], ["Glob", {pattern:`${home}/.local/share/opencode/auth*`}]])
  if (!guardTool(tool, input)?.includes("fleet read guard")) throw Error(`${tool} was allowed`);
if (guardTool("Grep", {path:"~/.pi/agent/sessions"})) throw Error("Claude Grep over sessions was blocked");
// Pi write of a markdown report: its content is body text, so bold markers and question marks pass.
if (guardTool("write", {path:`${home}/report.md`, content:`Status ${"\x2a\x2a"} why? ${"\x2a\x2a"} done`})) throw Error("Pi write of markdown report was blocked");
// Pi find takes a glob pattern, so a home-rooted codex login glob is still blocked.
if (!guardTool("find", {path:home, pattern:"~/.codex/a*"})?.includes("fleet read guard")) throw Error("Pi find of codex login glob was allowed");
EOF
# Guarding is at the agent boundary: normal process/library reads of fixture credentials still work.
printf 'fixture-secret' > "$H/.codex/auth.json"
HOME=$H node -e 'const fs=require("node:fs"); if(fs.readFileSync(process.env.HOME+"/.codex/auth.json","utf8")!=="fixture-secret") process.exit(1)'
HOME=$H XDG_DATA_HOME=$H/.local/share "$ADDON/uninstall.sh" >/dev/null
jq -e '[.hooks.PreToolUse[].hooks[].command] == ["keep-me"]' "$H/.claude/settings.json" >/dev/null && jq -e '(has("hooks") | not)' "$T/pool1/settings.json" >/dev/null \
  || { echo "FAIL uninstall left a read-guard hook"; exit 1; }
# No real auth contents are read, copied, or printed.
echo 'read-guard e2e: PASS'
