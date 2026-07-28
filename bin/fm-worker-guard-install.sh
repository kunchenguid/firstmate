#!/usr/bin/env bash
# Install deterministic PR-merge denial into one ordinary Firstmate worker.
#
# Usage:
#   fm-worker-guard-install.sh --preflight <harness>
#   fm-worker-guard-install.sh --remove <workspace> <state-dir> <task-id>
#   fm-worker-guard-install.sh <harness> <workspace> <state-dir> <task-id> <task-temp-dir> <turn-end-file>
#
# Preflight verifies support and dependencies before the runtime endpoint exists.
# Full installation prints the generated PATH-prefix directory and nothing else.
# Claude, Codex, OpenCode, Pi, pi-signed, and Grok receive native blocking
# hooks plus worker-only gh and gh-axi PATH wrappers.
# Kimi and unverified raw harnesses are refused because they have no verified
# blocking shell-tool hook.
# Installation never overwrites project-owned hooks, so a workspace that already
# carries .codex/hooks.json must already register this guard. Firstmate's own
# tracked .codex/hooks.json therefore includes the fm-worker-pretool-check.sh
# PreToolUse entry (inert without a registration): removing it would make every
# Codex worker spawned on a firstmate-repo worktree refuse to launch, which
# tests/fm-worker-merge-guard.test.sh asserts against the tracked file.
set -eu

# Physical, so the recorded checker= binding matches the path the checker itself
# derives with `pwd -P` even when firstmate is reached through a symlink.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
preflight() {
  local harness=$1 required
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok) : ;;
    kimi)
      echo "error: refusing ordinary Kimi worker spawn because Kimi has no verified blocking shell-tool hook for deterministic PR merge denial; select claude, codex, opencode, pi, pi-signed, or grok" >&2
      return 1
      ;;
    *)
      echo "error: refusing worker spawn on '$harness' because its production launch path has no verified deterministic PR merge guard" >&2
      return 1
      ;;
  esac
  command -v node >/dev/null 2>&1 || { echo "error: worker merge guard requires node" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: worker merge guard requires jq" >&2; return 1; }
  for required in "$SCRIPT_DIR/fm-worker-pretool-check.sh" "$SCRIPT_DIR/fm-worker-command-policy.mjs" "$SCRIPT_DIR/fm-worker-github.sh"; do
    [ -f "$required" ] && [ ! -L "$required" ] || { echo "error: worker merge guard component is unavailable: $required" >&2; return 1; }
  done
}

if [ "$#" -eq 2 ] && [ "$1" = --preflight ]; then
  preflight "$2"
  exit $?
fi
if [ "$#" -eq 4 ] && [ "$1" = --remove ]; then
  WORKSPACE_REMOVE=$(CDPATH='' cd -- "$2" && pwd -P) || exit 1
  STATE_REMOVE=$(CDPATH='' cd -- "$3" && pwd -P) || exit 1
  ID_REMOVE=$4
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_task_id_creation_valid "$ID_REMOVE" || exit 1
  POINTER_REMOVE="$WORKSPACE_REMOVE/.fm-worker-guard"
  [ -f "$POINTER_REMOVE" ] && [ ! -L "$POINTER_REMOVE" ] || exit 1
  AUTH_REMOVE=$(sed -n 's/^auth=//p' "$POINTER_REMOVE" | tail -1)
  TOKEN_REMOVE=$(cat "$STATE_REMOVE/$ID_REMOVE.worker-guard-token" 2>/dev/null || true)
  case "$TOKEN_REMOVE" in fm.????????????) : ;; *) exit 1 ;; esac
  [ "$AUTH_REMOVE" = "$STATE_REMOVE/.worker-guard.d/$TOKEN_REMOVE" ] || exit 1
  [ -f "$AUTH_REMOVE" ] && [ ! -L "$AUTH_REMOVE" ] || exit 1
  [ "$(sed -n 's/^workspace=//p' "$AUTH_REMOVE" | tail -1)" = "$WORKSPACE_REMOVE" ] || exit 1
  rm -f "$AUTH_REMOVE" "$STATE_REMOVE/$ID_REMOVE.worker-guard-token" \
    "$STATE_REMOVE/$ID_REMOVE.worker-guard.pi-ext.ts" "$POINTER_REMOVE" \
    "$WORKSPACE_REMOVE/.claude/settings.local.json" \
    "$WORKSPACE_REMOVE/.opencode/plugins/fm-worker-pretool-check.js"
  if [ -f "$WORKSPACE_REMOVE/.fm-worker-guard-codex-generated" ] \
     && [ ! -L "$WORKSPACE_REMOVE/.fm-worker-guard-codex-generated" ]; then
    rm -f "$WORKSPACE_REMOVE/.codex/hooks.json" "$WORKSPACE_REMOVE/.fm-worker-guard-codex-generated"
  fi
  exit 0
fi
[ "$#" -eq 6 ] || { echo "error: invalid worker guard installation request" >&2; exit 2; }
HARNESS=$1
WORKSPACE=$2
STATE=$3
ID=$4
TASK_TMP=$5
TURNEND=$6
preflight "$HARNESS" || exit 1

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
fm_task_id_creation_valid "$ID" || { echo "error: invalid worker guard task id" >&2; exit 2; }
WORKSPACE_REAL=$(CDPATH='' cd -- "$WORKSPACE" && pwd -P)
STATE_REAL=$(CDPATH='' cd -- "$STATE" && pwd -P)
CHECKER="$SCRIPT_DIR/fm-worker-pretool-check.sh"
POLICY="$SCRIPT_DIR/fm-worker-command-policy.mjs"
WRAPPER="$SCRIPT_DIR/fm-worker-github.sh"
for required in "$CHECKER" "$POLICY" "$WRAPPER"; do
  [ -f "$required" ] && [ ! -L "$required" ] || { echo "error: worker merge guard component is unavailable: $required" >&2; exit 1; }
done

exclude_path() {
  local rel=$1 exclude git_dir
  git_dir=$(git -C "$WORKSPACE_REAL" rev-parse --absolute-git-dir 2>/dev/null || true)
  [ -n "$git_dir" ] || return 1
  exclude="$git_dir/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF "$rel" "$exclude" 2>/dev/null || printf '%s\n' "$rel" >> "$exclude"
}

GENERATED_CODEX=0
AUTH=
POINTER="$WORKSPACE_REAL/.fm-worker-guard"
GUARD_BIN="$TASK_TMP/worker-guard-bin"
PI_EXT="$STATE_REAL/$ID.worker-guard.pi-ext.ts"
if [ -e "$POINTER" ] || [ -L "$POINTER" ]; then
  # A recovery or projection respawn reclaims only a registration this same
  # locked task owns; --remove proves that binding before removing anything.
  "$SCRIPT_DIR/fm-worker-guard-install.sh" --remove "$WORKSPACE_REAL" "$STATE_REAL" "$ID" 2>/dev/null || {
    echo "error: existing worker guard registration is ambiguous at $POINTER" >&2
    exit 1
  }
fi
cleanup_failure() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  rm -f "$POINTER" "$PI_EXT" "$STATE_REAL/$ID.worker-guard-token"
  [ -z "$AUTH" ] || rm -f "$AUTH"
  rm -rf "$GUARD_BIN"
  rm -f "$WORKSPACE_REAL/.opencode/plugins/fm-worker-pretool-check.js"
  if [ "$GENERATED_CODEX" -eq 1 ]; then
    rm -f "$WORKSPACE_REAL/.codex/hooks.json" "$WORKSPACE_REAL/.fm-worker-guard-codex-generated"
  fi
  return "$rc"
}
trap cleanup_failure EXIT HUP INT TERM

mkdir -p "$STATE_REAL/.worker-guard.d" "$GUARD_BIN"
chmod 0700 "$STATE_REAL/.worker-guard.d" "$GUARD_BIN"
old_umask=$(umask)
umask 077
AUTH=$(mktemp "$STATE_REAL/.worker-guard.d/fm.XXXXXXXXXXXX")
umask "$old_umask"
cat > "$AUTH" <<EOF
version=fm-worker-guard-v1
workspace=$WORKSPACE_REAL
checker=$CHECKER
EOF
chmod 0600 "$AUTH"
cat > "$POINTER" <<EOF
version=fm-worker-guard-v1
auth=$AUTH
EOF
chmod 0600 "$POINTER"
exclude_path '.fm-worker-guard'
printf '%s\n' "${AUTH##*/}" > "$STATE_REAL/$ID.worker-guard-token"
chmod 0600 "$STATE_REAL/$ID.worker-guard-token"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
absolute_tool() {
  local tool=$1 candidate dir
  candidate=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *) dir=$(CDPATH='' cd -- "$(dirname "$candidate")" && pwd -P); printf '%s/%s\n' "$dir" "$(basename "$candidate")" ;;
  esac
}
for tool in gh gh-axi; do
  real=$(absolute_tool "$tool" || true)
  [ -n "$real" ] || continue
  if [ "$tool" = gh ]; then
    aliases=$("$real" alias list 2>/dev/null) || {
      echo "error: cannot verify existing gh aliases before worker launch" >&2
      exit 1
    }
    case "$aliases" in
      *'pr merge'*|*'/pulls/'*'/merge'*|*mergePullRequest*)
        echo "error: existing gh alias can merge a PR; remove it before launching a worker" >&2
        exit 1
        ;;
    esac
  fi
  cat > "$GUARD_BIN/$tool" <<EOF
#!/usr/bin/env bash
exec $(shell_quote "$WRAPPER") --tool $tool --real $(shell_quote "$real") -- "\$@"
EOF
  chmod 0700 "$GUARD_BIN/$tool"
done

CHECKER_Q=$(shell_quote "$CHECKER")
WORKSPACE_Q=$(shell_quote "$WORKSPACE_REAL")
TURNEND_Q=$(shell_quote "$TURNEND")
case "$HARNESS" in
  claude)
    mkdir -p "$WORKSPACE_REAL/.claude"
    CLAUDE_HOOK="$WORKSPACE_REAL/.claude/settings.local.json"
    if [ -e "$CLAUDE_HOOK" ] || [ -L "$CLAUDE_HOOK" ]; then
      if ! { [ -f "$CLAUDE_HOOK" ] && [ ! -L "$CLAUDE_HOOK" ] \
        && grep -Fq 'fm-worker-pretool-check.sh' "$CLAUDE_HOOK"; }; then
        echo "error: existing Claude local settings are not an owned worker merge guard; refusing rather than overwriting project settings" >&2
        exit 1
      fi
    fi
    CLAUDE_COMMAND="$(shell_quote "$CHECKER") --claude --workspace \"\$CLAUDE_PROJECT_DIR\""
    CLAUDE_COMMAND_JSON=$(printf '%s' "$CLAUDE_COMMAND" | jq -Rs .)
    TURNEND_COMMAND_JSON=$(printf 'touch %s' "$TURNEND_Q" | jq -Rs .)
    cat > "$CLAUDE_HOOK" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":$CLAUDE_COMMAND_JSON}]}],"Stop":[{"hooks":[{"type":"command","command":$TURNEND_COMMAND_JSON}]}]}}
EOF
    exclude_path '.claude/settings.local.json'
    ;;
  codex)
    mkdir -p "$WORKSPACE_REAL/.codex"
    CODEX_HOOK="$WORKSPACE_REAL/.codex/hooks.json"
    if [ -e "$CODEX_HOOK" ] || [ -L "$CODEX_HOOK" ]; then
      [ -f "$CODEX_HOOK" ] && [ ! -L "$CODEX_HOOK" ] || { echo "error: existing Codex hook path is unsafe" >&2; exit 1; }
      jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains("fm-worker-pretool-check.sh"))' "$CODEX_HOOK" >/dev/null 2>&1 || {
        echo "error: existing .codex/hooks.json does not enforce Firstmate worker merge denial; refusing rather than overwriting project hooks" >&2
        exit 1
      }
    else
      CODEX_COMMAND="bash -lc 'payload=\$(cat 2>/dev/null || true); [ -n \"\$payload\" ] || exit 2; printf \"%s\" \"\$payload\" | $CHECKER_Q --workspace $WORKSPACE_Q'"
      CODEX_COMMAND_JSON=$(printf '%s' "$CODEX_COMMAND" | jq -Rs .)
      cat > "$CODEX_HOOK" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":$CODEX_COMMAND_JSON,"timeout":10}]}]}}
EOF
      printf 'generated=1\n' > "$WORKSPACE_REAL/.fm-worker-guard-codex-generated"
      GENERATED_CODEX=1
      exclude_path '.codex/hooks.json'
      exclude_path '.fm-worker-guard-codex-generated'
    fi
    ;;
  opencode)
    mkdir -p "$WORKSPACE_REAL/.opencode/plugins"
    OPENCODE_HOOK="$WORKSPACE_REAL/.opencode/plugins/fm-worker-pretool-check.js"
    if [ -e "$OPENCODE_HOOK" ] || [ -L "$OPENCODE_HOOK" ]; then
      if ! { [ -f "$OPENCODE_HOOK" ] && [ ! -L "$OPENCODE_HOOK" ] \
        && grep -Fq 'fm-worker-pretool-check.sh' "$OPENCODE_HOOK"; }; then
        echo "error: existing OpenCode worker hook is unsafe or unrecognized" >&2
        exit 1
      fi
    fi
    CHECKER_JS=$(printf '%s' "$CHECKER" | jq -Rs .)
    WORKSPACE_JS=$(printf '%s' "$WORKSPACE_REAL" | jq -Rs .)
    cat > "$OPENCODE_HOOK" <<EOF
import { spawnSync } from "node:child_process";
const checker = $CHECKER_JS;
const workspace = $WORKSPACE_JS;
export const FmWorkerPretoolCheck = async () => ({
  "tool.execute.before": async (input, output) => {
    if (input?.tool !== "bash") return;
    const command = output?.args?.command;
    if (typeof command !== "string" || command.length === 0) throw new Error("[worker-guard-unavailable] registered worker shell command is unavailable");
    const result = spawnSync(checker, ["--workspace", workspace, "--command", command], { encoding: "utf8" });
    if (result.status === 0) return;
    throw new Error((result.stderr || result.stdout || "[worker-guard-unavailable] registered worker merge guard failed").trim());
  },
});
EOF
    exclude_path '.opencode/plugins/fm-worker-pretool-check.js'
    ;;
  pi|pi-signed)
    if [ -e "$PI_EXT" ] || [ -L "$PI_EXT" ]; then
      echo "error: existing Pi worker guard extension is ambiguous at $PI_EXT" >&2
      exit 1
    fi
    CHECKER_JS=$(printf '%s' "$CHECKER" | jq -Rs .)
    WORKSPACE_JS=$(printf '%s' "$WORKSPACE_REAL" | jq -Rs .)
    cat > "$PI_EXT" <<EOF
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { spawnSync } from "node:child_process";
const checker = $CHECKER_JS;
const workspace = $WORKSPACE_JS;
export default function fmWorkerGuard(pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    const command = (event.input as { command?: unknown })?.command;
    if (typeof command !== "string" || command.length === 0) return { block: true, reason: "[worker-guard-unavailable] registered worker shell command is unavailable" };
    const result = spawnSync(checker, ["--workspace", workspace, "--command", command], { encoding: "utf8" });
    if (result.status === 0) return;
    return { block: true, reason: (result.stderr || result.stdout || "[worker-guard-unavailable] registered worker merge guard failed").trim() };
  });
}
EOF
    chmod 0600 "$PI_EXT"
    ;;
  grok)
    GROK_HOOKS="${GROK_HOME:-${HOME:?}/.grok}/hooks"
    mkdir -p "$GROK_HOOKS"
    cat > "$GROK_HOOKS/fm-worker-pretool-check.sh" <<'EOF'
#!/usr/bin/env bash
set -u
PAYLOAD=$(cat 2>/dev/null || true)
WORKSPACE=${GROK_WORKSPACE_ROOT:-}
[ -n "$WORKSPACE" ] || exit 0
POINTER="$WORKSPACE/.fm-worker-guard"
[ -f "$POINTER" ] && [ ! -L "$POINTER" ] || exit 0
AUTH=$(sed -n 's/^auth=//p' "$POINTER" 2>/dev/null | tail -1)
CHECKER=$(sed -n 's/^checker=//p' "$AUTH" 2>/dev/null | tail -1)
if [ -z "$CHECKER" ] || [ ! -x "$CHECKER" ]; then
  printf '%s\n' '{"decision":"deny","reason":"[worker-guard-unavailable] registered Firstmate worker merge guard is unavailable"}'
  exit 2
fi
printf '%s' "$PAYLOAD" | exec "$CHECKER" --workspace "$WORKSPACE"
EOF
    chmod 0700 "$GROK_HOOKS/fm-worker-pretool-check.sh"
    GROK_COMMAND="bash -lc 'exec \"\$0\"' $(shell_quote "$GROK_HOOKS/fm-worker-pretool-check.sh")"
    GROK_COMMAND_JSON=$(printf '%s' "$GROK_COMMAND" | jq -Rs .)
    cat > "$GROK_HOOKS/fm-worker-pretool-check.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":$GROK_COMMAND_JSON,"timeout":10}]}]}}
EOF
    chmod 0600 "$GROK_HOOKS/fm-worker-pretool-check.json"
    ;;
esac

trap - EXIT HUP INT TERM
printf '%s\n' "$GUARD_BIN"
