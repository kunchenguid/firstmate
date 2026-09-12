#!/usr/bin/env bash
# Detect provider quota-exhaustion refusals in assistant, tool, or pane text.
# Usage: fm-quota-refusal.sh detect
#        fm-quota-refusal.sh apply --task <id>
#
# Reads the candidate text from stdin. `detect` prints `provider=` and `reset=`
# lines and exits 0 on a match, 1 otherwise. `apply` records the same match as
# `blocked [key=quota-exhausted]: <provider> reset=<when>` on the task status,
# a provider-scope cooldown through bin/fm-quota-cooldown.sh, and one Slack
# line through bin/fm-slack-post.sh. Repeat apply on the same task is a no-op.
# FM_QUOTA_COOLDOWN_NOW pins the clock for year-less reset stamps in tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-}"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:+$FM_HOME/state}}"

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  detect|apply) COMMAND=$1; shift ;;
  *) echo "error: expected detect, apply, or --help" >&2; exit 2 ;;
esac

TASK=
if [ "$COMMAND" = apply ]; then
  case "${1:-}" in
    --task)
      [ -n "${2:-}" ] || { echo "error: --task requires a value" >&2; exit 2; }
      TASK=$2
      shift 2
      ;;
    --task=*)
      TASK=${1#--task=}
      shift
      ;;
    *) echo "error: apply requires --task <id>" >&2; exit 2 ;;
  esac
  [ -n "$TASK" ] || { echo "error: --task requires a non-empty value" >&2; exit 2; }
  [ $# -eq 0 ] || { echo "error: unexpected argument '$1'" >&2; exit 2; }
  [ -n "$FM_HOME" ] || { echo "error: FM_HOME is not set" >&2; exit 2; }
  [ -n "$STATE" ] || STATE="$FM_HOME/state"
else
  [ $# -eq 0 ] || { echo "error: unexpected argument '$1'" >&2; exit 2; }
fi

TEXT=$(cat)
MATCH=$(FM_QUOTA_COOLDOWN_NOW="${FM_QUOTA_COOLDOWN_NOW:-}" node - "$TEXT" <<'NODE'
const text = process.argv[2] || '';
const nowRaw = process.env.FM_QUOTA_COOLDOWN_NOW || new Date().toISOString();
const now = new Date(nowRaw);
const year = Number.isFinite(now.getTime()) ? now.getUTCFullYear() : new Date().getUTCFullYear();

const TABLE = [
  {provider: 'qwen', re: /token-plan[\s\S]{0,200}(?:quota has been exhausted|insufficient_quota)|insufficient_quota[\s\S]{0,200}token-plan/i},
  {provider: 'cursor', re: /you(?:['’]ve| have) hit your usage limit/i},
  {provider: 'xai', re: /xai(?:'s)? (?:usage )?quota|(?:quota|spending limit).{0,80}xai/i},
  {provider: 'anthropic', re: /rate_limit_error|exceeded your (?:current )?quota.{0,80}(?:claude|anthropic)|anthropic.{0,80}(?:usage (?:limit|quota)|quota)/i},
  {provider: 'openai', re: /insufficient_quota|exceeded your current quota|you have hit your usage limit/i},
];

function iso(value) {
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) return '';
  return parsed.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function resetFrom(source) {
  let match = source.match(/reset(?:s| will reset)?(?: at)?\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))/i);
  if (match) return iso(match[1]);
  match = source.match(/reset(?:s| will reset)?(?: at)?\s+(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})\s*UTC/i);
  if (match) {
    let stamp = iso(`${year}-${match[1]}-${match[2]}T${match[3]}:${match[4]}:${match[5]}Z`);
    if (stamp && new Date(stamp).getTime() <= now.getTime()) {
      stamp = iso(`${year + 1}-${match[1]}-${match[2]}T${match[3]}:${match[4]}:${match[5]}Z`);
    }
    return stamp;
  }
  match = source.match(/resets?\s+(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (match) {
    const month = match[1].padStart(2, '0');
    const day = match[2].padStart(2, '0');
    return iso(`${match[3]}-${month}-${day}T00:00:00Z`);
  }
  return '';
}

for (const row of TABLE) {
  if (!row.re.test(text)) continue;
  const reset = resetFrom(text) || 'unknown';
  const quote = text.replace(/\s+/g, ' ').trim().slice(0, 240);
  process.stdout.write(`provider=${row.provider}\nreset=${reset}\nquote=${quote}\n`);
  process.exit(0);
}
process.exit(1);
NODE
) || {
  [ "$COMMAND" = detect ] && exit 1
  exit 1
}

if [ "$COMMAND" = detect ]; then
  printf '%s\n' "$MATCH" | grep -E '^(provider|reset)='
  exit 0
fi

provider=$(printf '%s\n' "$MATCH" | sed -n 's/^provider=//p' | head -n 1)
reset=$(printf '%s\n' "$MATCH" | sed -n 's/^reset=//p' | head -n 1)
quote=$(printf '%s\n' "$MATCH" | sed -n 's/^quote=//p' | head -n 1)
[ -n "$provider" ] && [ -n "$reset" ] || exit 1
[ -n "$quote" ] || quote="quota exhausted ($provider)"

statusf="$STATE/$TASK.status"
mkdir -p "$STATE"
last=
if [ -f "$statusf" ]; then
  last=$(tail -n 1 "$statusf" 2>/dev/null || true)
fi
line="blocked [key=quota-exhausted]: $provider reset=$reset"
if [ "$last" = "$line" ]; then
  exit 0
fi

expires=$reset
if [ "$reset" = unknown ]; then
  expires=$(node -e 'const now=process.env.FM_QUOTA_COOLDOWN_NOW||new Date().toISOString(); const d=new Date(now); d.setUTCDate(d.getUTCDate()+7); process.stdout.write(d.toISOString());')
fi

printf '%s\n' "$line" >> "$statusf"

"$SCRIPT_DIR/fm-quota-cooldown.sh" record \
  --scope provider \
  --provider "$provider" \
  --evidence-kind provider-refusal \
  --evidence "$quote" \
  --expires-at "$expires" >/dev/null

PATH="$PATH" command -v fm-slack-post.sh >/dev/null 2>&1 \
  && slack=$(command -v fm-slack-post.sh) \
  || slack="$SCRIPT_DIR/fm-slack-post.sh"
"$slack" message "quota exhausted: $TASK provider=$provider reset=$reset" >/dev/null 2>&1 || true
exit 0
