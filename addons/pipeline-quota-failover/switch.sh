#!/usr/bin/env bash
# switch.sh - move the no-mistakes pipeline agent, and therefore every pipeline
# step including review, to one accepted agent and one model.
#
# Usage: switch.sh [--dry-run] [--restore-latest] [--config <path>] [--pool-config <path>]
#                  [--agent <name>] [--model <provider/model>]
#
# The pipeline's agent is global: every step (intent, rebase, review, test,
# document, lint, push, PR, CI) runs the configured `agent`. This edits only
# two keys by name:
#   agent: <agent>
#   agent_config.<agent>.model: <model>
# Every other key, value and comment is left untouched. A timestamped backup is
# written next to the config first. A real request on the model must answer
# before the edit is kept; otherwise the backup is restored.
#
# With neither --agent nor --model, the route comes from fm-model-pool pick
# (Claude above the eligibility floor, else Sol then Goat then Cursor auto).
# Explicit --agent/--model keep the old pin. Never hand-edit the live config.
#
# The no-mistakes daemon re-reads its config per run, so no daemon restart is
# needed for this edit. No config value is ever printed; only key names and the
# route are. Folder paths and unset names only; never credentials or login files.
set -u

die() { echo "switch.sh: $*" >&2; exit 1; }

dry=0
restore=0
config=${NM_CONFIG:-${HOME:?}/.no-mistakes/config.yaml}
# Empty PI_QUOTA_FAILOVER_ACCOUNT_POOL turns pool picking off (use - not :- so empty sticks).
if [ -n "${PI_QUOTA_FAILOVER_ACCOUNT_POOL+x}" ]; then
  pool_config=$PI_QUOTA_FAILOVER_ACCOUNT_POOL
elif [ -n "${FM_HOME:-}" ]; then
  pool_config=$FM_HOME/config/account-pool
else
  pool_config=$HOME/firstmate/config/account-pool
fi
agent=pi
model=claude-bridge/claude-haiku-5-5
agent_set=0
model_set=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --restore-latest) restore=1 ;;
    --config) config=$2; shift ;;
    --pool-config) pool_config=$2; shift ;;
    --agent) agent=$2; agent_set=1; shift ;;
    --model) model=$2; model_set=1; shift ;;
    *) die "unknown argument: $1 (use --dry-run, --restore-latest, --config <path>, --pool-config <path>, --agent <name>, --model <provider/model>)" ;;
  esac
  shift
done

[ -f "$config" ] || die "no no-mistakes config at $config"

# Resolve fm-model-pool and map a pick onto agent + model when the caller did not pin either.
model_pool=${PI_QUOTA_FAILOVER_MODEL_POOL:-}
if [ -z "$model_pool" ]; then
  for cand in \
    "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/account-pool/bin/fm-model-pool" \
    "${FM_ADDONS_DIR:+$FM_ADDONS_DIR/account-pool/bin/fm-model-pool}" \
    "${FM_HOME:+$FM_HOME/projects/firstmate-addons/account-pool/bin/fm-model-pool}"; do
    [ -n "${cand:-}" ] && [ -x "$cand" ] && { model_pool=$cand; break; }
  done
fi
pool_sel=''
if [ "$agent_set" = 0 ] && [ "$model_set" = 0 ] && [ -n "$pool_config" ] && [ -f "$pool_config" ] && [ -n "$model_pool" ]; then
  req=$(jq -nc --arg p "$pool_config" '{v:1,purpose:"work",pool_config:$p,capabilities:["text"],attempted:[]}')
  pool_sel=$(printf '%s' "$req" | timeout 120 "$model_pool" pick --json 2>/dev/null) || pool_sel=''
  jq -e '.ok == true' <<<"$pool_sel" >/dev/null 2>&1 || die "fm-model-pool pick refused: $(jq -r '.reason // "no answer"' <<<"${pool_sel:-}" 2>/dev/null)"
  harness=$(jq -r '.harness // empty' <<<"$pool_sel")
  m=$(jq -r '.model // empty' <<<"$pool_sel")
  case $harness in
    claude)
      agent=pi
      case $m in '' ) model=claude-bridge/claude-haiku-5-5 ;; */*) model=$m ;; *) model=claude-bridge/$m ;; esac
      ;;
    codex) agent=codex; model=$m ;;
    opencode|cursor) agent=pi; model=$m ;;
    *) die "fm-model-pool returned unsupported harness=$harness" ;;
  esac
  echo "fm-model-pool pick id=$(jq -r '.selection_id // .id' <<<"$pool_sel") -> agent=$agent model=$model"
fi

if [ "$restore" = 1 ]; then
  latest=$(find "$(dirname "$config")" -maxdepth 1 -name "$(basename "$config").bak-pipeline-opencode-*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)
  [ -n "$latest" ] || die "no pipeline-opencode backup next to $config"
  cp -p "$latest" "$config" || die "cannot restore $config from $latest"
  echo "restored the pipeline agent config from the latest pipeline-opencode backup"
  exit 0
fi

case $agent in
  codex|claude|pi|acp:omp) ;;
  *) die "agent must be one of codex, claude, pi, acp:omp (no-mistakes gate neutralization)" ;;
esac
case $agent in
  pi) command -v pi >/dev/null 2>&1 || die "pi is not on PATH" ;;
  claude) command -v claude >/dev/null 2>&1 || die "claude is not on PATH" ;;
  codex) command -v codex >/dev/null 2>&1 || die "codex is not on PATH" ;;
  acp:omp) command -v omp >/dev/null 2>&1 || die "omp is not on PATH" ;;
esac
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"

tmp=$(mktemp -d) || die "no temp dir"
trap 'rm -rf -- "$tmp"' EXIT

python3 -I - "$config" "$tmp/edited" "$agent" "$model" <<'EOF' || exit 1
import re, sys, yaml

src, dst, agent, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
orig = yaml.safe_load(text) or {}
if not isinstance(orig, dict):
    sys.exit("switch.sh: config root is not a mapping")
want = dict(orig)
want["agent"] = agent
ac = want.get("agent_config")
if ac is None:
    ac = {}
elif not isinstance(ac, dict):
    sys.exit("switch.sh: agent_config is not a mapping")
else:
    ac = dict(ac)
child = ac.get(agent)
if child is None:
    child = {}
elif not isinstance(child, dict):
    sys.exit("switch.sh: agent_config.%s is not a mapping" % agent)
else:
    child = dict(child)
child["model"] = model
ac[agent] = child
want["agent_config"] = ac

lines = text.splitlines(keepends=True)

def top_level(line):
    return bool(line.strip()) and not line.startswith((" ", "\t"))

def set_agent(lines):
    for i, line in enumerate(lines):
        if re.match(r"^agent:", line):
            lines[i] = re.sub(r"^(agent:\s*)\S+", lambda m: m.group(1) + agent, line, count=1)
            return True
    return False

def set_model(lines):
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^agent_config:\s*(#.*)?$", line):
            start = i
            break
    if start is None:
        lines.append("\nagent_config:\n  " + agent + ":\n    model: " + model + "\n")
        return
    if "{" in lines[start] or "[" in lines[start]:
        sys.exit("switch.sh: agent_config is inline; refusing a lossy edit")
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if top_level(lines[j]):
            end = j
            break
    child_at = None
    child_re = re.compile(r"^  " + re.escape(agent) + r":\s*(#.*)?$")
    for j in range(start + 1, end):
        if child_re.match(lines[j]):
            child_at = j
            break
    if child_at is None:
        lines.insert(start + 1, "  " + agent + ":\n    model: " + model + "\n")
        return
    child_end = end
    for j in range(child_at + 1, end):
        if lines[j].strip() and not lines[j].startswith(("    ", "\t")):
            child_end = j
            break
    for j in range(child_at + 1, child_end):
        if re.match(r"^    model:", lines[j]):
            lines[j] = re.sub(r"^(    model:\s*)\S+", lambda m: m.group(1) + model, lines[j], count=1)
            return
    lines.insert(child_at + 1, "    model: " + model + "\n")

if not set_agent(lines):
    lines.insert(0, "agent: " + agent + "\n")
set_model(lines)

result = "".join(lines)
if yaml.safe_load(result) != want:
    sys.exit("switch.sh: the edit would change keys other than agent and agent_config.%s.model" % agent)
open(dst, "w").write(result)
EOF

if cmp -s "$config" "$tmp/edited"; then
  echo "pipeline agent is already $agent on $model; nothing to change"
  exit 0
fi

if [ "$dry" = 1 ]; then
  echo "dry-run: would set agent=$agent and agent_config.$agent.model=$model in $config (backup first)"
  exit 0
fi

echo "testing $agent on $model"
# Apply the pick's folder and shed list for the probe only (paths and names, never credentials).
probe_env=(env)
if [ -n "$pool_sel" ]; then
  folder=$(jq -r '.set.CLAUDE_CONFIG_DIR // empty' <<<"$pool_sel")
  [ -n "$folder" ] && probe_env+=(CLAUDE_CONFIG_DIR="$folder")
  while IFS= read -r v; do
    [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    probe_env+=(-u "$v")
  done < <(jq -r '.unset[]?' <<<"$pool_sel")
fi
case $agent in
  pi)
    if ! out=$(cd "$tmp" && "${probe_env[@]}" pi -p --no-session --model "$model" "Reply with exactly: PONG" 2>&1); then
      die "pi failed on $model: $(printf '%s' "$out" | tail -n 3 | head -c 400)"
    fi
    ;;
  claude)
    if ! out=$(cd "$tmp" && "${probe_env[@]}" claude -p --model "$model" "Reply with exactly: PONG" 2>&1); then
      die "claude failed on $model: $(printf '%s' "$out" | tail -n 3 | head -c 400)"
    fi
    ;;
  codex)
    if ! out=$(cd "$tmp" && "${probe_env[@]}" codex exec --skip-git-repo-check --model "$model" "Reply with exactly: PONG" 2>&1); then
      die "codex failed on $model: $(printf '%s' "$out" | tail -n 3 | head -c 400)"
    fi
    ;;
  acp:omp)
    if ! out=$(cd "$tmp" && "${probe_env[@]}" omp -p --model "$model" "Reply with exactly: PONG" 2>&1); then
      die "omp failed on $model: $(printf '%s' "$out" | tail -n 3 | head -c 400)"
    fi
    ;;
esac
case "$out" in
  *PONG*) ;;
  *) die "$agent did not answer PONG on $model: $(printf '%s' "$out" | tail -n 3 | head -c 400)" ;;
esac

backup="$config.bak-pipeline-opencode-$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$config" "$backup" || die "cannot back up $config; nothing written"
if ! cat "$tmp/edited" > "$config"; then
  cat "$backup" > "$config"
  die "cannot write $config; restored from $backup"
fi
echo "pipeline agent: $agent on $model (keys agent, agent_config.$agent.model); backup $backup"
echo "the no-mistakes daemon re-reads its config per run; no restart needed"
