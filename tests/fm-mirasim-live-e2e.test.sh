#!/usr/bin/env bash
# Credentialed live guard for one synthetic Mirasim model turn and Claude hooks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_MIRASIM_LIVE_E2E mirasim jq

LAB=$(fm_test_tmproot fm-mirasim-live)
STATE="$LAB/state"
WORK="$LAB/empty"
ID=mirasim-live
PROMPT='Reply with exactly MIRASIM_SMOKE_OK and nothing else.'
mkdir -p "$STATE" "$WORK/.claude"

catalog=$(mirasim ui-cli catalog --agent claude 2>&1) \
  || fail "Mirasim catalog lookup failed"
catalog_json=$(printf '%s\n' "$catalog" | sed -n '/^{/,$p')
model=$(printf '%s' "$catalog_json" | jq -r '([.models[].id | select(. == "claude-fable-5-1[1m]")][0]) // .defaultModel // empty')
[ -n "$model" ] || fail "Mirasim catalog returned no default Claude model"

gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") \
  || fail "could not arm the live Mirasim busy record"
open_cmd="'$ROOT/bin/fm-busy-event.sh' apply '$STATE' '$ID' busy --gen '$gen' --source claude-hook --event user-prompt-submit"
close_cmd="'$ROOT/bin/fm-busy-event.sh' apply '$STATE' '$ID' idle --gen '$gen' --source claude-hook --event stop && touch '$STATE/$ID.turn-ended'"
jq -n --arg open "$open_cmd" --arg close "$close_cmd" '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$open}]}],Stop:[{hooks:[{type:"command",command:$close}]}],StopFailure:[{hooks:[{type:"command",command:$close}]}],SessionEnd:[{hooks:[{type:"command",command:$close}]}]}}' \
  > "$WORK/.claude/settings.local.json"

out=$(
  cd "$WORK" || exit 1
  mirasim claude --print --output-format text --tools "" --no-session-persistence \
    --setting-sources local --model "$model" --effort low "$PROMPT"
) || fail "Mirasim model turn failed for requested model $model"
[ "$out" = MIRASIM_SMOKE_OK ] \
  || fail "Mirasim returned unexpected synthetic response for requested model $model: $out"

. "$ROOT/bin/fm-busy-lib.sh"
[ "$(fm_busy_classify tmux unused mirasim "$ID" "$STATE")" = 'idle claude-hook' ] \
  || fail "the real Mirasim turn did not settle through Claude's Stop hook"
[ -f "$STATE/$ID.turn-ended" ] \
  || fail "the real Mirasim Stop hook did not publish completion"

printf 'ok - Mirasim requested model %s completed the synthetic prompt through Claude hooks; served identity remains unproven\n' "$model"
