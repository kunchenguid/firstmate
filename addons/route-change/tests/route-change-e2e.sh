#!/usr/bin/env bash
# route-change e2e: the real script against a fixture home and no-mistakes
# config, with the real pipeline-quota-failover wrapper as the route list and
# stub quota-axi and pi on PATH. Journeys: an unknown route, a route quota-axi
# reads exhausted, a route quota-failover holds out, and an unusable quota-axi
# reading are refused with nothing written; a dry run writes
# nothing; a good route moves every dispatch list, the gate and the non-Claude
# lead pins and keeps a backup of each; a route whose real request fails
# restores every file. Needs bash, jq, flock, timeout and python3 with yaml;
# no real tool, home or config is touched.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
rc_bin=$here/../route-change wrapper=$here/../../pipeline-quota-failover/pi-quota-failover
[ -x "$rc_bin" ] && [ -x "$wrapper" ] || { echo "not ok - route-change or pi-quota-failover is missing"; exit 1; }
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home stub=$work/bin
mkdir -p "$home/state" "$home/bin" "$home/config/secondmates/lead-claude" "$home/config/secondmates/lead-glm" "$stub"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else no "$1: output lacks [$3]"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then no "$1: output has [$3]"; else ok "$1"; fi; }

awk -v w="$work" '
  /^#--- / { file = w "/" substr($0, 6); next }
  file { print > file }
' <<'FIXTURE' || exit 1
#--- home/bin/fm-quota-axi-lib.sh
# shellcheck shell=bash
# The schema-5 join of firstmate's bin/fm-quota-axi-lib.sh.
FM_QUOTA_ROW_JQ='def quota_lane($harness; $model): "";
  def quota_row($snapshot; $provider; $lane): ([$snapshot.providers[]? | select(.provider == $provider)] | first) // null;'
fm_quota_json_valid() { jq -e '.schemaVersion == 5 and (.providers | type) == "array"' >/dev/null 2>&1; }
#--- home/config/crew-dispatch.json
{"rules": [
  {"when": "tough", "use": [
    {"harness": "claude", "model": "claude-opus-5-5", "effort": "max"},
    {"harness": "opencode", "model": "opencode-go/deepseek-v4.1-flash", "provider": "opencode-go"},
    {"harness": "opencode", "model": "opencode-go/muse-spark-1.3-contributor", "provider": "opencode-go"},
    {"harness": "pi", "model": "zai/glm-5.3-flash", "provider": "zai"}]},
  {"when": "opus only", "use": [{"harness": "claude", "model": "claude-opus-5-5", "effort": "high"}]},
  {"when": "mechanical", "use": [
    {"harness": "pi", "model": "zai/glm-5.3-flash", "provider": "zai"},
    {"harness": "pi", "model": "muse-spark-1.3-contributor", "provider": "opencode-go"}]}],
 "default": [{"harness": "pi", "model": "zai/glm-5.3-flash", "provider": "zai"}],
 "notes": ["kept as is"]}
#--- home/config/secondmate-harness
# global lead default
opencode opencode/deepseek-v4.1-flash-free high
#--- home/config/secondmates/lead-claude/harness
claude claude-opus-5-5 high
#--- home/config/secondmates/lead-glm/harness
pi zai/glm-5.3-flash high
#--- nm.yaml
# no-mistakes config
agent: opencode # pipeline and reviews stay on free/cheap models, never Claude
api_key: SECRET-never-printed
agent_config:
  claude:
    model: claude-haiku-5-5
    effort: low
  pi:
    # the gate model
    model: zai/glm-5.3-flash # operator decision on the board
    effort: medium
  opencode:
    model: opencode-go/muse-spark-1.3-contributor
auto_fix:
  review: true
agent_path_override:
  pi: WRAPPER
#--- bin/pi
#!/usr/bin/env bash
# --list-models as real pi prints it; a prompt answers PONG unless STUB_PI_FAIL.
if [ "$1" = --list-models ]; then
  printf 'provider     model                         context\n'
  printf 'zai          glm-5.3-flash                 1M\n'
  printf 'opencode-go  muse-spark-1.3-contributor    1M\n'
  printf 'commandcode  deepseek/deepseek-v4.1-flash  262K\n'
  printf 'opencode-go  deepseek-v4.1-flash           1M\n'
  exit 0
fi
printf '%s\n' "$*" >>"$STUB_LOG"
[ -z "${STUB_PI_FAIL:-}" ] || { echo 'Error: 402 insufficient credits on commandcode'; exit 0; }
echo PONG
#--- bin/quota-axi
#!/usr/bin/env bash
cat "$STUB_QUOTA"
#--- quota.json
{"schemaVersion": 5, "providers": [
  {"provider": "zai", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 0,
     "runway": {"status": "exhausted_now", "limitingWindowId": "weekly"}}]}},
  {"provider": "opencode-go", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 60,
     "runway": {"status": "through_reset"}}]}}]}
FIXTURE
sed -i "s|WRAPPER|$wrapper|" "$work/nm.yaml"
chmod +x "$stub/pi" "$stub/quota-axi"
export PATH="$stub:$PATH" NM_CONFIG=$work/nm.yaml STUB_QUOTA=$work/quota.json STUB_LOG=$work/pi.log
# A fixed three-route list, so these journeys do not follow the wrapper's default chain.
export PI_QUOTA_FAILOVER_CHAIN='zai/glm-5.3-flash muse-spark-1.3-contributor deepseek/deepseek-v4.1-flash'
: >"$STUB_LOG"

pins=("$home/config/crew-dispatch.json" "$NM_CONFIG" "$home/config/secondmate-harness"
  "$home/config/secondmates/lead-claude/harness" "$home/config/secondmates/lead-glm/harness")
snap() { cat "${pins[@]}" | sha256sum; }
baks() { find "$work" -name '*.bak-route-change-*' | wc -l; }
models() { jq -c "$1 | map(.model)" "$home/config/crew-dispatch.json"; }
first=$(snap)
cp "$home/config/crew-dispatch.json" "$work/dispatch.orig"

# An unknown route and an exhausted route: refused, nothing written.
out=$("$rc_bin" "$home" opus-anything 2>&1)
is "unknown route exits non-zero" "$?" 1
has "unknown route names the route list" "$out" "routes: zai/glm-5.3-flash muse-spark-1.3-contributor deepseek/deepseek-v4.1-flash"
out=$("$rc_bin" "$home" zai/glm-5.3-flash 2>&1)
is "exhausted route exits non-zero" "$?" 1
has "exhausted route gives the reason" "$out" "refused: quota-axi reads zai exhausted now (all_models, window weekly)"
is "refusals change no file" "$(snap)" "$first"
is "refusals keep no backup" "$(baks)" 0
is "refusals send no request" "$(wc -l <"$STUB_LOG")" 0

# A route quota-failover holds out of dispatch, stored provider-prefixed as
# the fleet writes opencode profiles: refused. The deepseek entry then left in
# the file stays a different account, so the later commandcode deepseek
# journeys still run.
jq -n '[{when: "tough", profile: {harness: "opencode",
  model: "opencode-go/muse-spark-1.3-contributor", provider: "opencode-go"}}]' >"$home/state/quota-failover-dead.json"
out=$("$rc_bin" "$home" muse-spark-1.3-contributor 2>&1)
is "dead-file route exits non-zero" "$?" 1
has "dead-file route is refused" "$out" "refused: quota-failover holds muse-spark-1.3-contributor out of dispatch"
is "the dead-file refusal changes no file" "$(snap)" "$first"
is "the dead-file refusal sends no request" "$(wc -l <"$STUB_LOG")" 0
jq -n '[{when: null, profile: {harness: "opencode",
  model: "opencode-go/deepseek-v4.1-flash", provider: "opencode-go"}}]' >"$home/state/quota-failover-dead.json"

# Dry run: the plan, nothing written.
out=$("$rc_bin" --dry-run "$home" muse-spark-1.3-contributor 2>&1)
is "dry run exits 0" "$?" 0
has "dry run plans the gate" "$out" "agent_config.pi.model zai/glm-5.3-flash -> muse-spark-1.3-contributor"
has "dry run plans a lead pin" "$out" "lead-glm/harness: pi zai/glm-5.3-flash high -> pi muse-spark-1.3-contributor high"
is "dry run changes no file" "$(snap)" "$first"
is "dry run keeps no backup" "$(baks)" 0

# A good route moves every pin together.
out=$("$rc_bin" "$home" muse-spark-1.3-contributor 2>&1)
is "good route exits 0" "$?" 0
lacks "no config value but route names is printed" "$out" SECRET
is "tough rule: Opus keeps its place, the list's own entry for the route leads the rest" \
  "$(jq -c '.rules[0].use | map(.harness + " " + .model)' "$home/config/crew-dispatch.json")" \
  '["claude claude-opus-5-5","opencode opencode-go/muse-spark-1.3-contributor","opencode opencode-go/deepseek-v4.1-flash","pi zai/glm-5.3-flash"]'
is "an Opus-only rule is left alone" "$(models '.rules[1].use')" '["claude-opus-5-5"]'
is "a list holding the route moves it first, once" "$(models '.rules[2].use')" \
  '["muse-spark-1.3-contributor","zai/glm-5.3-flash"]'
is "default list" "$(models '.default')" '["muse-spark-1.3-contributor","zai/glm-5.3-flash"]'
is "a list without the route gets a pi profile with pi's provider" \
  "$(jq -c '.default[0]' "$home/config/crew-dispatch.json")" '{"harness":"pi","model":"muse-spark-1.3-contributor","provider":"opencode-go"}'
is "gate keys move" "$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print(c["agent"], c["agent_config"]["pi"]["model"])' "$NM_CONFIG")" \
  "pi muse-spark-1.3-contributor"
is "gate: every other key and comment is unchanged" \
  "$(diff "$NM_CONFIG" "$NM_CONFIG".bak-route-change-* | grep -c '^[<>]')" 4
is "the agent line keeps its provenance comment" "$(grep -cF 'agent: pi # pipeline and reviews stay on free/cheap models' "$NM_CONFIG")" 1
is "the model line keeps its provenance comment" \
  "$(grep -cF 'model: muse-spark-1.3-contributor # operator decision on the board' "$NM_CONFIG")" 1
is "global lead pin" "$(tail -n 1 "$home/config/secondmate-harness")" "pi muse-spark-1.3-contributor high"
is "Claude lead pin stays" "$(cat "$home/config/secondmates/lead-claude/harness")" "claude claude-opus-5-5 high"
is "route lead pin" "$(cat "$home/config/secondmates/lead-glm/harness")" "pi muse-spark-1.3-contributor high"
is "one backup per changed file" "$(baks)" 4
if cmp -s "$work/dispatch.orig" "$home/config/crew-dispatch.json".bak-route-change-*; then ok "the backup holds the old file"; else no "the backup holds the old file"; fi
is "one real request, on the route, as the gate calls pi" "$(cat "$STUB_LOG")" \
  "--model muse-spark-1.3-contributor -p --no-session Reply with the single word PONG."
is "one log line" "$(grep -c 'zai/glm-5.3-flash -> muse-spark-1.3-contributor (opencode-go)' "$home/state/route-change.log")" 1

# A failed real request restores every file.
moved=$(snap)
out=$(STUB_PI_FAIL=1 "$rc_bin" "$home" deepseek/deepseek-v4.1-flash 2>&1)
is "failed request exits non-zero" "$?" 1
has "failed request names the cause" "$out" "the real request on deepseek/deepseek-v4.1-flash failed (exit 0): Error: 402 insufficient credits"
has "failed request restores" "$out" "restored 4 file(s)"
is "every file is back" "$(snap)" "$moved"
is "no log line for the failed switch" "$(grep -c deepseek "$home/state/route-change.log")" 0

# An unusable quota-axi reading (lib signature drift): refused, nothing written.
mkdir -p "$work/home2/config" "$work/home2/state" "$work/home2/bin"
sed 's/def quota_row(/def quota_row_unusable(/' "$home/bin/fm-quota-axi-lib.sh" >"$work/home2/bin/fm-quota-axi-lib.sh"
cp "$work/dispatch.orig" "$work/home2/config/crew-dispatch.json"
out=$("$rc_bin" "$work/home2" muse-spark-1.3-contributor 2>&1)
is "an unusable quota reading exits non-zero" "$?" 1
has "an unusable quota reading is refused" "$out" "quota-axi reading unusable"
is "the unusable-reading refusal writes nothing" \
  "$(cmp -s "$work/dispatch.orig" "$work/home2/config/crew-dispatch.json" && echo same)" same

[ "$fails" = 0 ] && echo "PASS route-change e2e" || { echo "FAIL route-change e2e ($fails)"; exit 1; }
