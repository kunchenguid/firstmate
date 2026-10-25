#!/usr/bin/env bash
# pi-quota-failover route test: the real wrapper against a stub pi and a stub
# quota-axi in a throwaway HOME, with the exact argv shape no-mistakes builds
# (--model <m> --mode json --no-session, prompt on stdin). It pins the
# persisted pipeline route and the fm-model-pool adoption:
#   - without a pool, the default chain is Claude Haiku through claude-bridge;
#   - with a pool, route/account come from fm-model-pool pick/next (A=70% over
#     B=40%, A limit then B, all Claude under floor then Sol -> Goat -> Cursor);
#   - an openrouter/* route takes the deepseek idle limit.
# Nothing real is called: no network, no config, no login copy. Needs bash, jq,
# timeout and pgrep.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
wrapper=$here/../pi-quota-failover
helper=$addons/account-pool/bin/fm-model-pool
pick=$addons/claude-accounts/bin/claude-accounts-pick
[ -f "$wrapper" ] || { echo "not ok - $wrapper is missing"; exit 1; }
[ -x "$helper" ] || { echo "not ok - $helper is missing"; exit 1; }
[ -x "$pick" ] || { echo "not ok - $pick is missing"; exit 1; }

route=claude-bridge/claude-haiku-5-5
or=openrouter/deepseek/deepseek-v4.1-flash-1017:floor

work=$(mktemp -d) || exit 1
trap 'rm -rf -- "$work"' EXIT
home=$work/home stub=$work/bin log=$work/pqf.log
mkdir -p "$home" "$stub" "$work/a" "$work/b" "$work/pool" "$work/log"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
out_has() { if printf '%s' "$OUT" | grep -q -- "$2"; then ok "$1"; else no "$1: output lacks [$2]"; fi; }
log_has() { if grep -q -- "$2" "$log" 2>/dev/null; then ok "$1"; else no "$1: $log lacks [$2]"; fi; }

cat >"$stub/pi" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = list ] && exit 0
printf '%s\n' "$*" >>"$STUB_ARGV"
model=''
prev=''
for a in "$@"; do
  [ "$prev" = "--model" ] && model=$a
  prev=$a
done
[ "$model" = "${STUB_SILENT:-}" ] && { sleep 600; exit 0; }
[ "$1" = --help ] || printf '%s\n' "${CLAUDE_CONFIG_DIR:-default-login}" >>"$STUB_ACCOUNTS"
printf '%s\n' '{"type":"session","id":"s-1"}'
# Limit only a named Claude folder listed in STUB_LIMITED, or a named model in STUB_LIMIT_MODELS.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [[ " ${STUB_LIMITED:-} " = *" ${CLAUDE_CONFIG_DIR##*/} "* ]]; then
  printf '%s\n' '{"type":"message_end","stopReason":"error","errorMessage":"Claude rate limit (five_hour) resets in 3h: You are out of usage"}'
  exit 0
fi
if [[ " ${STUB_LIMIT_MODELS:-} " = *" $model "* ]]; then
  printf '%s\n' '{"type":"message_end","stopReason":"error","errorMessage":"rate limit exceeded"}'
  exit 0
fi
printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
exit 0
STUB
chmod +x "$stub/pi"

cat >"$stub/quota-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_QUOTA_LOG"
p=''
prev=''
for a in "$@"; do
  [ "$prev" = "--provider" ] && p=$a
  prev=$a
done
printf '{"providers":[{"provider":"%s","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"known"}}]}}]}\n' "$p"
STUB
chmod +x "$stub/quota-axi"

# Recording stand-in wraps the real chooser (same recipe as account-pool/tests/model-pool.test.sh).
cat >"$stub/pool-cmd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/log/pool-cmd.log"
exec env FM_HOME="$home" FM_CLAUDE_ACCOUNTS_REGISTRY="$work/registry.json" FM_CLAUDE_ACCOUNTS_FRESH=999999 \
  FM_ACCOUNT_POOL_REST_FLOOR=15 FM_MODEL_POOL_FLOOR=15 "$pick" "\$@"
SH
chmod +x "$stub/pool-cmd"
for name in claude codex cursor opencode; do
  printf '#!/bin/sh\necho "error: real model CLI blocked: %s" >&2\nexit 97\n' "$name" >"$stub/$name"
  chmod +x "$stub/$name"
done

printf 'state=%s\ncommand=%s\n' "$work/pool" "$stub/pool-cmd" >"$work/account-pool"
cat >"$work/registry.json" <<R
{"version":1,"accounts":[
 {"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"$work/a"},
 {"id":"pa_umer_b","provider":"claude","name":"Umer B","folder":"$work/b"}
]}
R
reading() {
  local now
  now=$(date +%s)
  jq -n --argjson at "$now" --arg a pa_umer_a --arg b pa_umer_b \
    --arg fa "$work/a" --arg fb "$work/b" \
    --argjson h1 "$1" --argjson d1 "$2" --argjson h2 "$3" --argjson d2 "$4" \
    '{schema:1, generated_at:$at, accounts:[
      {id:$a,name:"Umer A",folder:$fa,five_hour:{left:$h1},seven_day:{left:$d1},read_at:$at,problem:null},
      {id:$b,name:"Umer B",folder:$fb,five_hour:{left:$h2},seven_day:{left:$d2},read_at:$at,problem:null}]}' \
    >"$work/pool/claude-accounts.json"
  mkdir -p "$home/state"
  cp "$work/pool/claude-accounts.json" "$home/state/claude-accounts.json"
}

unset CLAUDE_CONFIG_DIR
export PI_QUOTA_FAILOVER_REAL_PI="$stub/pi" STUB_ACCOUNTS=$work/accounts
export PI_QUOTA_FAILOVER_LOG="$log" STUB_ARGV=$work/argv STUB_QUOTA_LOG=$work/quota.log
export PI_QUOTA_FAILOVER_MODEL_POOL=$helper
export HOME="$home" XDG_STATE_HOME="$work/state" FM_HOME="$home"
export FM_CLAUDE_ACCOUNTS_REGISTRY=$work/registry.json
export FM_MODEL_POOL_FLOOR=15 FM_ACCOUNT_POOL_REST_FLOOR=15 FM_CLAUDE_ACCOUNTS_LOW=5 FM_CLAUDE_ACCOUNTS_FRESH=999999
PATH="$stub:$PATH"
export PI_QUOTA_FAILOVER_PROBE=0
# Empty pool path keeps the static chain for cases 1-4 (live homes must not leak in).
export PI_QUOTA_FAILOVER_ACCOUNT_POOL=''
prompt='Reply with the single word PONG.'

# 1. Without a pool, the default chain is the persisted pipeline route.
is "default chain is Claude Haiku through claude-bridge" "$(PI_QUOTA_FAILOVER_PRINT_CHAIN=1 "$wrapper" </dev/null)" "$route"

# 2. A call pinned to the config's route runs that route (no pool).
: >"$STUB_ARGV"
: >"$STUB_QUOTA_LOG"
OUT=$(printf '%s' "$prompt" | env -u PI_QUOTA_FAILOVER_CHAIN \
  "$wrapper" --model "$route" --mode json --no-session 2>"$work/err2")
is "call on the config's route exits 0" "$?" "0"
out_has "the config's route answers" "\"model\":\"$route\""
is "one pi call" "$(wc -l <"$STUB_ARGV")" "1"

# 3. Off-chain pin without a pool lands on the chain route.
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | env -u PI_QUOTA_FAILOVER_CHAIN \
  "$wrapper" --model openai-codex/gpt-6-luna --mode json --no-session 2>"$work/err3")
is "off-chain pin exits 0" "$?" "0"
out_has "off-chain pin lands on the pipeline route" "\"model\":\"$route\""
is "the pinned model never runs" "$(grep -c 'openai-codex' "$STUB_ARGV")" "0"

# 4. openrouter/* takes the deepseek idle limit.
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_SILENT="$or" PI_QUOTA_FAILOVER_IDLE_SECS=1 PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS=5 \
  PI_QUOTA_FAILOVER_CHAIN="$or $route" \
  "$wrapper" --model "$or" --mode json --no-session 2>"$work/err4")
is "silent openrouter route exits 0" "$?" "0"
out_has "the next chain route answers" '"model":"claude-bridge/claude-haiku-5-5"'
log_has "the openrouter route is killed by its own limit" "no output for 5s"

# 5. Forced-limit row: A=70% B=40%; A limited -> B answers on the same bridge route.
reading 70 70 40 40
: >"$log"; : >"$STUB_ARGV"; : >"$STUB_ACCOUNTS"
OUT=$(printf '%s' "$prompt" | STUB_LIMITED=a PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool ANTHROPIC_API_KEY=x \
  "$wrapper" --model "$route" --mode json --no-session 2>"$work/err5")
is "A=70% B=40%: a limit still answers" "$?" "0"
out_has "bridge route answers after account move" "\"model\":\"$route\""
is "first account a (70%), then b (40%), never default login" "$(sed 's|.*/||' "$STUB_ACCOUNTS" | paste -sd, -)" "a,b"
log_has "fm-model-pool next moved off A" "next id=pa_umer_b"
is "no quota marker for the Claude route" "$(find "$work/state" -path "*pi-quota-failover-dead/*" 2>/dev/null | wc -l)" "0"

# 6. All Claude under the eligibility floor: Sol then Goat then Cursor auto.
reading 10 10 5 5
: >"$log"; : >"$STUB_ARGV"; : >"$STUB_ACCOUNTS"
OUT=$(printf '%s' "$prompt" | STUB_LIMIT_MODELS='openai-codex/gpt-6.1-sol deepseek/deepseek-goat' \
  PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool \
  "$wrapper" --model "$route" --mode json --no-session 2>"$work/err6")
is "all Claude low falls over to Cursor auto" "$?" "0"
out_has "Cursor auto answers" '"model":"auto"'
is "Sol then Goat then Cursor were tried" "$(grep -cE 'openai-codex/gpt-6.1-sol|deepseek/deepseek-goat|--model auto' "$STUB_ARGV")" "3"
log_has "Sol was selected first under floor" "model=openai-codex/gpt-6.1-sol"
log_has "Goat followed Sol" "model=deepseek/deepseek-goat"
is "no Claude bridge when all under floor" "$(grep -c 'claude-bridge' "$STUB_ARGV")" "0"

# 7. Helper refusal (every route attempted) ends quota exhausted without a Claude ambient fallback.
reading 10 10 5 5
: >"$log"; : >"$STUB_ACCOUNTS"; : >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_LIMIT_MODELS='openai-codex/gpt-6.1-sol deepseek/deepseek-goat auto' \
  PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool \
  "$wrapper" --model "$route" --mode json --no-session 2>"$work/err7")
is "exhausted helper routes fail" "$?" "1"
log_has "quota exhausted when helper next refuses" "quota exhausted\|fm-model-pool next refused"
is "no Claude bridge when every fallover is limited" "$(grep -c 'claude-bridge' "$STUB_ARGV")" "0"

echo
if [ "$fails" = 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
