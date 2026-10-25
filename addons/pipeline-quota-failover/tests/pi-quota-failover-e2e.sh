#!/usr/bin/env bash
# pi-quota-failover e2e: the real wrapper against a stub pi on PATH in a
# throwaway HOME, driven with the exact argv shape no-mistakes builds
# (--model <m> --thinking <e> --mode json --no-session, prompt on stdin).
# The stub's zai/glm-5.3-flash route answers with the fleet's real quota
# error surface (pi exits 0, the error rides in the stream as errorMessage,
# 429 "You've reached your 5-hour usage limit"); openai-codex/gpt-6-luna
# answers normally, or with a codex usage-limit surface when STUB_LUNA_DEAD is set. Asserts on the pinned GLM -> GPT-6 Luna chain: one glm attempt,
# then one GPT-6 Luna attempt, the successful Luna stream on stdout, failover
# logged with timings, and the whole call under 10s; a quota-dead Luna after
# glm ends in the terminal "quota exhausted" line, exit 1. Also covers:
# non-quota (401) passthrough byte-for-byte, a pin outside the chain running the chain (never the pinned model), a
# --session resume dropping the session on failover, quota-dead markers (written
# on a quota error, the model skipped while fresh, tried again once expired,
# cleared by an answer), stdin kept flowing to pi, and install.sh's key-level config edit in a throwaway config.
# The default chain is the pipeline route, Claude Haiku through claude-bridge: a Codex-pinned call and a
# GLM-pinned call land on it, and the pinned model never runs. The failover journeys below pin their own chain
# (a DeepSeek quota error moves to Haiku, a silent DeepSeek call has its own idle limit, and GLM quota failures
# (Z.AI's balance and rate-limit refusals too) move on to the next hop), so they are unaffected by the default.
# Also covers the quota-axi pre-check (a stub quota-axi: exhausted_now skips the route without a pi call, a failing
# quota-axi still calls it), the idle watchdog (a silent stub is killed after a short IDLE_SECS and fails over for that
# call only: no marker, the next call tries the route again, a stall on the last model is not "quota exhausted"; the
# limit is per model, claude-bridge/* on BRIDGE_IDLE_SECS and every other model on IDLE_SECS), a
# future-dated marker's skip line showing the time left, and a call killed from outside keeping its marker. Also covers
# the extension set every call runs with (-ne plus the extensions pi would load, minus pi-hermes-memory).
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
wrapper=$here/../pi-quota-failover
[ -f "$wrapper" ] || { echo "not ok - $wrapper is missing"; exit 1; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home stub=$work/bin log=$work/pqf.log
mkdir -p "$home" "$stub"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
# out_has <name> <pattern>: matches against $OUT
out_has() { if printf '%s' "$OUT" | grep -q -- "$2"; then ok "$1"; else no "$1: output lacks [$2]"; fi; }
# out_count <name> <pattern> <want>: counts in $OUT
out_count() { local got; got=$(printf '%s' "$OUT" | grep -c -- "$2") || got=0; is "$1" "$got" "$3"; }
# log_has <name> <pattern>
log_has() { if grep -q -- "$2" "$log" 2>/dev/null; then ok "$1"; else no "$1: $log lacks [$2]"; fi; }
# err_has <name> <file> <pattern>
err_has() { if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1: $2 lacks [$3]"; fi; }

# The stub pi: a quota-dead glm route (real 429 usage-limit surface, exit 0),
# a GPT-6 Luna route that is healthy unless STUB_LUNA_DEAD, and a route that
# echoes the requested model for passthrough checks. Each call's argv is one
# line in $STUB_ARGV.
cat >"$stub/pi" <<'STUB'
#!/usr/bin/env bash
# pi list (the wrapper's extension lookup) prints $STUB_PI_LIST and exits $STUB_PI_LIST_EXIT; it is not a model call.
[ "${1:-}" = list ] && { [ -n "${STUB_PI_LIST:-}" ] && cat "$STUB_PI_LIST"; exit "${STUB_PI_LIST_EXIT:-0}"; }
printf '%s\n' "$*" >>"$STUB_ARGV"
model=''
prev=''
for a in "$@"; do
  [ "$prev" = "--model" ] && model=$a
  prev=$a
done
case $model in
  bad/hang) sleep 600 & printf '%s\n' "$!" >"$STUB_CHILD"; wait; exit 0 ;;
  bad/graceful) trap 'exit 0' TERM; bash -c 'trap "sleep 2; touch \"\$STUB_CLEANUP\"; exit 0" TERM; sleep 600 & wait' & wait; exit 0 ;;
  bad/quiet) printf '%s\n' "$$" >"$STUB_PI"; sleep 600; exit 0 ;;
  bad/quiet-3s | claude-bridge/quiet-3s) sleep 3 ;;
  claude-bridge/silent) sleep 600; exit 0 ;;
  bad/stubborn) trap '' TERM; bash -c 'sleep 600 & printf "%s\n" "$!" >"$STUB_CHILD"; wait' & while :; do sleep 1; done ;;
  bad/flaky) n=$(cat "$STUB_FLAKY" 2>/dev/null || echo 0); echo $((n + 1)) >"$STUB_FLAKY"; [ "$n" -lt "${STUB_FLAKY_STALLS:-1}" ] && sleep 600 ;;
  bad/slow-stream)
    printf '%s\n' '{"type":"session","id":"s-1"}'
    for _ in 1 2 3 4; do sleep 1; printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}'; done
    printf '%s\n' '{"type":"message_end","role":"assistant","model":"bad/slow-stream","content":"PONG"}'
    exit 0 ;;
  zai/glm-5.3-flash*) [ -n "${STUB_GLM_KILL:-}" ] && kill -TERM $$ ;;
  deepseek/deepseek-flash) [ -n "${STUB_DS_SILENT:-}" ] && sleep "$STUB_DS_SILENT" ;;
esac
printf '%s\n' '{"type":"session","id":"s-1"}'
printf '%s\n' "{\"type\":\"attempt\",\"model\":\"$model\"}"
case $model in
  zai/glm-5.3-flash*)
    if [ -n "${STUB_GLM_TEXT:-}" ]; then
      printf '{"type":"message_update","errorMessage":%s}\n' "$(jq -Rn --arg t "$STUB_GLM_TEXT" '$t')"
      exit 0
    fi
    printf '%s\n' '{"type":"message_update","errorMessage":"429: {\"message\":\"You'"'"'ve reached your 5-hour usage limit for your plan. Your limit resets at 2026-10-17\"}"}'
    exit 0 ;;
  deepseek/deepseek-flash)
    if [ -n "${STUB_DS_DEAD:-}" ]; then
      printf '%s\n' '{"type":"message_update","errorMessage":"402: {\"message\":\"Insufficient Balance\"}"}'
      exit 0
    fi
    printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
    exit 0 ;;
  openai-codex/gpt-6-luna)
    if [ -n "${STUB_LUNA_DEAD:-}" ]; then
      printf '%s\n' '{"type":"message_update","errorMessage":"429: {\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\"}"}'
      exit 0
    fi
    printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
    exit 0 ;;
  bad/waitdelay)
    echo 'pi parse events: exec: WaitDelay expired before I/O complete' >&2
    exit 1 ;;
  bad/extwarn)
    echo 'Warning: extension /x/ext.ts failed to load' >&2
    exit 1 ;;
  bad/nocredit)
    printf '%s\n' '{"type":"message_update","errorMessage":"402: {\"message\":\"Insufficient credits\"}"}'
    exit 0 ;;
  bad/always-429)
    printf '%s\n' '{"type":"message_update","errorMessage":"429: {\"type\":\"GoUsageLimitError\",\"message\":\"Go usage limit exceeded\"}"}'
    exit 0 ;;
  bad/http401)
    printf '%s\n' '{"type":"message_update","errorMessage":"401: {\"code\":\"401\",\"message\":\"token expired or incorrect\"}"}'
    exit 0 ;;
  *)
    printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
    exit 0 ;;
esac
STUB
chmod +x "$stub/pi"

# The stub quota-axi: each call is one line in $STUB_QUOTA_LOG; providers named in $STUB_QUOTA_EXHAUSTED (comma
# list) report all_models exhausted_now, $STUB_QUOTA_FAIL makes it exit 1, $STUB_QUOTA_JSON replaces the answer verbatim.
# A provider name outside quota-axi's list gets the real quota-axi rejection. quota-axi calls openai-codex "codex",
# and the wrapper maps the pi name before asking.
cat >"$stub/quota-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_QUOTA_LOG"
[ -z "${STUB_QUOTA_FAIL:-}" ] || { echo 'quota-axi: vendor unreachable' >&2; exit 1; }
p=''
prev=''
for a in "$@"; do
  [ "$prev" = "--provider" ] && p=$a
  prev=$a
done
case $p in
  claude|codex|cursor|copilot|grok|kimi|zai|agy|alibaba|opencode-go|commandcode|minimax|mimo|deepseek|openrouter|elevenlabs|devin) ;;
  *) printf '%s\n' "error: \"unsupported provider: $p\"" 'code: VALIDATION_ERROR' 'help[1]: "Supported providers: claude, codex, cursor, copilot, grok, kimi, zai, agy, alibaba, opencode-go, commandcode, minimax, mimo, deepseek, openrouter, elevenlabs, devin"'; exit 2 ;;
esac
[ -z "${STUB_QUOTA_JSON:-}" ] || { printf '%s\n' "$STUB_QUOTA_JSON"; exit 0; }
status=known
case ",${STUB_QUOTA_EXHAUSTED:-}," in *",$p,"*) status=exhausted_now ;; esac
printf '{"providers":[{"provider":"%s","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"%s"}}]}}]}\n' "$p" "$status"
STUB
chmod +x "$stub/quota-axi"

# The argv every wrapped call carries before the caller's flags: -ne, then the built-in extensions (no user packages or
# extension files in this HOME, so the list is just pi's built-ins).
ext_prefix='-ne -e builtin:mcp -e builtin:llama.cpp -e builtin:codemode -e builtin:tool-search'
export PI_QUOTA_FAILOVER_REAL_PI="$stub/pi"
export PI_QUOTA_FAILOVER_LOG="$log" STUB_ARGV=$work/argv STUB_QUOTA_LOG=$work/quota.log
export HOME="$home" XDG_STATE_HOME="$work/state" STUB_CHILD=$work/child STUB_PI=$work/pi.pid
PATH="$stub:$PATH"
# The credit probe is one more pi call per run; it is off except in its own journey (section R below).
export PI_QUOTA_FAILOVER_PROBE=0
prompt='Reply with the single word PONG.'
prompt_file=$work/prompt
printf '%s' "$prompt" >"$prompt_file"
# Quota-dead markers: cleared before journeys that need every model tried.
dead=$work/state/pi-quota-failover-dead
nodead() { rm -f -- "$dead"/*; }
# age_of <model>: seconds since its marker, or "none".
age_of() { local at; read -r _ at 2>/dev/null <"$dead/${1//\//%}" && echo $(($(date +%s) - at)) || echo none; }
backdate() { printf '%s %s\n' "$1" $(($(date +%s) - 3601)) >"$dead/${1//\//%}"; }
fresh() { local a; a=$(age_of "$2"); if [ "$a" != none ] && [ "$a" -lt 5 ]; then ok "$1"; else no "$1: marker age [$a]"; fi; }
# child_gone: the tool child started by the last bad/hang stub is no longer running (a zombie counts as gone).
child_gone() {
  local c s
  c=$(cat "$STUB_CHILD" 2>/dev/null) || return 1
  for _ in $(seq 30); do
    s=$(ps -o stat= -p "$c" 2>/dev/null | tr -d ' ')
    case $s in ''|Z*) return 0 ;; esac
    sleep 0.1
  done
  kill "$c" 2>/dev/null
  return 1
}

is "default chain is Claude Haiku through claude-bridge (the pipeline route)" "$(PI_QUOTA_FAILOVER_PRINT_CHAIN=1 "$wrapper" </dev/null)" \
  "claude-bridge/claude-haiku-5-5"

# 0. The default chain, no override. A Codex-pinned call (the first-draft fix step's route) runs the chain and lands on
#    the pipeline route: quota-axi is asked for claude-bridge and does not skip it, and Codex and GLM are not called.
nodead
: >"$STUB_ARGV"
: >"$STUB_QUOTA_LOG"
OUT=$(printf '%s' "$prompt" | env -u PI_QUOTA_FAILOVER_CHAIN "$wrapper" --model openai-codex/gpt-6-luna --mode json --no-session 2>"$work/err0a")
is "codex-pinned call exits 0" "$?" "0"
out_has "codex-pinned call lands on the pipeline route" '"model":"claude-bridge/claude-haiku-5-5"'
is "codex-pinned call makes one pi call" "$(wc -l <"$STUB_ARGV")" "1"
is "codex never called" "$(grep -c 'openai-codex' "$STUB_ARGV")" "0"
is "quota-axi asked for claude-bridge" "$(grep -c -- '--provider claude-bridge ' "$STUB_QUOTA_LOG")" "1"

# 0b. GLM is out of the chain: a GLM-pinned call never reaches GLM, it runs the pipeline route.
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | env -u PI_QUOTA_FAILOVER_CHAIN "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err0b")
is "glm-pinned call exits 0" "$?" "0"
out_has "glm-pinned call runs the pipeline route" '"model":"claude-bridge/claude-haiku-5-5"'
is "glm never called with the default chain" "$(grep -c 'zai/glm' "$STUB_ARGV")" "0"

# 0c. A DeepSeek quota error moves on to Claude Haiku in the same call, and writes its marker.
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_DS_DEAD=1 PI_QUOTA_FAILOVER_CHAIN="deepseek/deepseek-flash claude-bridge/claude-haiku-5-5" "$wrapper" --model deepseek/deepseek-flash --mode json --no-session 2>"$work/err0c")
is "deepseek quota error exits 0" "$?" "0"
out_has "deepseek quota error moves to Haiku" '"model":"claude-bridge/claude-haiku-5-5"'
is "deepseek quota error: DeepSeek then Haiku, nothing else" "$(sed -e 's/^.*--model //' -e 's/ .*//' "$STUB_ARGV" | tr '\n' ' ')" "deepseek/deepseek-flash claude-bridge/claude-haiku-5-5 "
log_has "deepseek quota error logged with its hop" "model=deepseek/deepseek-flash quota-error.*moving to claude-bridge/claude-haiku-5-5"
fresh "deepseek quota error writes its marker" deepseek/deepseek-flash

# 0d. A silent DeepSeek call is killed only by its own limit: 4 s of silence survives IDLE_SECS=2 (the generic limit),
#     and DEEPSEEK_IDLE_SECS=2 kills the same call and moves on to Haiku.
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_DS_SILENT=4 PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN="deepseek/deepseek-flash claude-bridge/claude-haiku-5-5" "$wrapper" --model deepseek/deepseek-flash --mode json --no-session 2>"$work/err0d")
is "silent deepseek under its own limit exits 0" "$?" "0"
out_has "silent deepseek answers itself" '"model":"deepseek/deepseek-flash"'
is "silent deepseek under its own limit: one pi call" "$(wc -l <"$STUB_ARGV")" "1"
if grep -q 'no output for' "$log"; then no "silent deepseek was killed under its own limit"; else ok "silent deepseek is not killed under the generic limit"; fi
nodead
: >"$log"
OUT=$(printf '%s' "$prompt" | STUB_DS_SILENT=4 PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN="deepseek/deepseek-flash claude-bridge/claude-haiku-5-5" "$wrapper" --model deepseek/deepseek-flash --mode json --no-session 2>"$work/err0d2")
is "deepseek over its own limit exits 0" "$?" "0"
log_has "deepseek own limit kills the silent call" "model=deepseek/deepseek-flash stalled.*no output for 2s.*moving to claude-bridge/claude-haiku-5-5"
out_has "deepseek over its own limit moves to Haiku" '"model":"claude-bridge/claude-haiku-5-5"'

# 0e. A GLM quota failure moves on to the next hop. Z.AI's balance refusal, its rate-limit refusal and OpenRouter's 402 requires-more-credits text are quota failures,
#     so GLM writes its marker and DeepSeek answers the same call (before this change the run ended on them).
for text in 'Insufficient balance or no resource package. Please recharge.' 'Rate limit reached for requests' '402: {"message":"This request requires more credits, or fewer max_tokens. You requested up to 64000 tokens, but can only afford 2118. To increase, visit https://openrouter.ai/settings/credits and upgrade to a paid account","code":402}'; do
  nodead
  : >"$log"
  OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='zai/glm-5.3-flash deepseek/deepseek-flash claude-bridge/claude-haiku-5-5' STUB_GLM_TEXT="$text" "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err0e")
  is "glm failure [$text] exits 0" "$?" "0"
  out_has "glm failure [$text] moves to DeepSeek" '"model":"deepseek/deepseek-flash"'
  log_has "glm failure [$text] is a quota error" "model=zai/glm-5.3-flash quota-error.*moving to deepseek/deepseek-flash"
  fresh "glm failure [$text] writes the glm marker" zai/glm-5.3-flash
done

# The failover cases below exercise the GLM -> GPT-6 Luna route (the stub's codex usage-limit surface and the
# quota-axi codex name are about that pair), so they pin the chain; the default is checked above.
export PI_QUOTA_FAILOVER_CHAIN='zai/glm-5.3-flash openai-codex/gpt-6-luna'

# 1. Quota failover: glm dead -> GPT-6 Luna answers, one attempt each.
nodead
: >"$log"
t0=$(date +%s%3N)
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --thinking medium --mode json --no-session 2>"$work/err1")
rc=$?
t1=$(date +%s%3N)
is "failover exits 0" "$rc" "0"
out_has "stdout is the GPT-6 Luna stream" '"model":"openai-codex/gpt-6-luna"'
out_count "no glm attempt delivered" '"model":"zai/glm-5.3-flash"' 0
out_count "no error event delivered" 'errorMessage' 0
log_has "failover logged with timing" "moving to openai-codex/gpt-6-luna"
log_has "log names the failed model" 'model=zai/glm-5.3-flash quota-error'
log_has "log names the quota cause" "usage limit"
if [ "$(grep -c 'quota-error' "$log")" = 1 ]; then ok "exactly one failed attempt (no same-model retry)"; else no "wrong attempt count in log"; fi
if [ $((t1 - t0)) -lt 10000 ]; then ok "failover took $((t1 - t0))ms (< 10s)"; else no "failover took $((t1 - t0))ms, expected < 10s"; fi
# quota-axi is asked for the codex provider under its own name, so the GPT-6 Luna route is pre-checked, not skipped.
is "quota-axi asked for codex, not the pi name" "$(grep -c -- '--provider codex ' "$STUB_QUOTA_LOG")" "1"
if grep -q -- '--provider openai-codex' "$STUB_QUOTA_LOG"; then no "quota-axi was asked for openai-codex"; else ok "quota-axi was never asked for openai-codex"; fi
if grep -q 'not pre-checked' "$log"; then no "GPT-6 Luna route was not pre-checked"; else ok "GPT-6 Luna route was pre-checked"; fi
log_has "success logged with model, duration and bytes" 'model=openai-codex/gpt-6-luna answered in [0-9]*ms ([0-9]* bytes)'

# 2. Non-quota failure passes through untouched (pi's real 401 surface, exit 0), with no failover.
nodead
: >"$log"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='bad/http401 openai-codex/gpt-6-luna' "$wrapper" --model bad/http401 --mode json --no-session 2>"$work/err2")
is "401 passthrough exits 0" "$?" "0"
out_has "401 stream untouched" "token expired or incorrect"
if grep -q 'moving to' "$log"; then no "non-quota error failed over"; else ok "no failover for non-quota"; fi

# 3. A model outside the chain never runs: the chain runs in chain order instead (no passthrough).
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model kimi/k2 --mode json --no-session 2>"$work/err3")
is "off-chain pin: call exits 0" "$?" "0"
if grep -q kimi "$STUB_ARGV"; then no "off-chain pin reached kimi"; else ok "off-chain pin never reaches kimi"; fi
case $(sed -n 1p "$STUB_ARGV") in *zai/glm-5.3-flash*) ok "off-chain pin runs the chain head" ;; *) no "off-chain pin argv: $(sed -n 1p "$STUB_ARGV")" ;; esac

# 4. A resumed session is dropped on the failover attempt only.
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --session 01234567-89ab-cdef-0123-456789abcdef 2>"$work/err4")
is "session failover exits 0" "$?" "0"
out_has "failover stream is GPT-6 Luna" '"model":"openai-codex/gpt-6-luna"'
is "first attempt keeps the session" "$(sed -n 1p "$STUB_ARGV")" \
  "$ext_prefix --model zai/glm-5.3-flash --mode json --session 01234567-89ab-cdef-0123-456789abcdef"
is "failover attempt drops the session" "$(sed -n 2p "$STUB_ARGV")" \
  "$ext_prefix --model openai-codex/gpt-6-luna --mode json"

# 5. Default chain exhausted (glm, then a quota-dead GPT-6 Luna): each model
#    once, terminal "quota exhausted", exit 1.
: >"$log"
nodead
OUT=$(printf '%s' "$prompt" | STUB_LUNA_DEAD=1 "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5")
rc=$?
is "exhausted chain exits 1" "$rc" "1"
err_has "terminal line present" "$work/err5" "quota exhausted"
if [ -z "$OUT" ]; then ok "no error stream delivered on exhaustion"; else no "stdout should be empty on exhaustion"; fi
if [ "$(grep -c 'quota-error' "$log")" = 2 ]; then ok "each chain model attempted once"; else no "wrong attempt count in log: $(grep -c 'quota-error' "$log")"; fi
log_has "glm attempt logged" 'model=zai/glm-5.3-flash quota-error'
log_has "GPT-6 Luna usage-limit attempt logged" 'model=openai-codex/gpt-6-luna quota-error.*usage limit'
log_has "exhaustion logged" "no model left in the chain"

# 5b. Each quota error left a marker holding the model and the time.
fresh "glm marker written" zai/glm-5.3-flash
fresh "Luna marker written" openai-codex/gpt-6-luna
is "marker names the model" "$(cut -d' ' -f1 "$dead/zai%glm-5.3-flash")" "zai/glm-5.3-flash"

# 5c. Every model inside its window: no pi call at all, terminal line, exit 1.
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5c")
is "all-skipped chain exits 1" "$?" "1"
err_has "all-skipped terminal line" "$work/err5c" "quota exhausted"
is "no pi call while every marker is fresh" "$(wc -l <"$STUB_ARGV")" "0"
log_has "skip logged with its window" 'model=zai/glm-5.3-flash skipped: quota error [0-9]*s ago (skip window 3600s)'

# 5d. glm fresh, Luna's window over: glm is skipped, Luna runs first with the
#     session dropped, and its answer clears its marker.
backdate openai-codex/gpt-6-luna
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --session 01234567-89ab-cdef-0123-456789abcdef 2>"$work/err5d")
is "skipped-glm call exits 0" "$?" "0"
out_has "skipped-glm call answers from Luna" '"model":"openai-codex/gpt-6-luna"'
is "glm skipped: one pi call, Luna, no session" "$(cat "$STUB_ARGV")" "$ext_prefix --model openai-codex/gpt-6-luna --mode json"
is "Luna answer cleared its marker" "$(age_of openai-codex/gpt-6-luna)" "none"

# 5e. glm's window over: glm is tried again first, and its new quota error
#     renews the marker.
backdate zai/glm-5.3-flash
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5e")
is "expired-marker call exits 0" "$?" "0"
is "expired glm tried again first" "$(sed -n 1p "$STUB_ARGV")" "$ext_prefix --model zai/glm-5.3-flash --mode json --no-session"
fresh "glm marker renewed" zai/glm-5.3-flash

# 5f. A marker dated 120s in the future (clock step): glm is skipped, and the skip line shows the time left until it
#     expires (window plus the 120s offset), never a negative number.
nodead
: >"$log"
: >"$STUB_ARGV"
mkdir -p "$dead"
printf '%s %s\n' zai/glm-5.3-flash $(($(date +%s) + 120)) >"$dead/zai%glm-5.3-flash"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5f")
is "future-dated marker call exits 0" "$?" "0"
out_has "future-dated glm skipped, GPT-6 Luna answers" '"model":"openai-codex/gpt-6-luna"'
log_has "future-dated skip shows time left" 'model=zai/glm-5.3-flash skipped: quota error dated in the future, 37[0-9][0-9]s until it expires'
skip_msg=$(grep 'skipped: quota error dated' "$log" | sed 's/^[^ ]* //')
case $skip_msg in *" -"[0-9]*) no "future-dated skip line has a negative number: $skip_msg" ;; *) ok "future-dated skip line has no negative number" ;; esac

# 6. A pin outside the chain (Muse) is not run: the chain runs in chain order, Muse is never called, and the prompt
#    still reaches pi (stdin kept flowing through the chain).
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model muse-spark-1.3-contributor --mode json --no-session 2>"$work/err6")
is "non-chain pin exits 0" "$?" "0"
out_has "prompt reached pi through the chain" "PONG"
is "muse never called" "$(grep -c 'muse' "$STUB_ARGV")" "0"
is "non-chain pin runs the chain head first" "$(sed -n 1p "$STUB_ARGV")" "$ext_prefix --model zai/glm-5.3-flash --mode json --no-session"

# 6b. A profile set to a later chain model fails over to the earlier ones in
# chain order (B2: Muse first, GLM backup), the requested model tried once.
: >"$log"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='deepseek/deepseek-v4.1-flash bad/always-429 muse-spark-1.3-contributor' "$wrapper" --model bad/always-429 --mode json --no-session 2>"$work/err6b")
is "requested-first failover exits 0" "$?" "0"
out_has "earlier chain model answers" '"model":"deepseek/deepseek-v4.1-flash"'
out_count "later chain model not tried" '"model":"muse' 0
log_has "moves to the earlier chain model" 'model=bad/always-429 quota-error.*moving to deepseek/deepseek-v4.1-flash'
if [ "$(grep -c 'quota-error' "$log")" = 1 ]; then ok "requested model attempted once"; else no "wrong attempt count in log"; fi

# 7. Host-memory gate: runs before pi with no command, its output kept off the stream; a gate still waiting at the
#    bound lets pi start anyway with one log line.
cat >"$stub/gate" <<'GATE'
#!/bin/sh
[ $# -eq 0 ] && echo "gate ran" >>"$GATE_LOG" && echo "fm-mem-gate: waiting" && sleep "${GATE_SLEEP:-0}"
GATE
chmod +x "$stub/gate"
export GATE_LOG=$work/gate.log
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_GATE="$stub/gate" "$wrapper" --model muse-spark-1.3-contributor --mode json --no-session 2>"$work/err7")
is "gated call exits 0" "$?" "0"
is "gate ran once, with no command" "$(cat "$work/gate.log" 2>/dev/null)" "gate ran"
out_has "gated prompt reached pi" "PONG"
out_count "gate output kept off the stream" "fm-mem-gate" 0
OUT=$(printf '%s' "$prompt" | GATE_SLEEP=5 PI_QUOTA_FAILOVER_GATE="$stub/gate" PI_QUOTA_FAILOVER_GATE_SECS=1 "$wrapper" --model muse-spark-1.3-contributor --mode json --no-session 2>"$work/err7b")
is "bounded gate wait still runs pi" "$?" "0"
out_has "pi answered after the bound" "PONG"
log_has "bound logged" "memory gate still waiting after 1s; starting pi anyway"

# 9. quota-axi reports the route's provider exhausted_now: the route is skipped without a pi call, its marker written.
nodead
: >"$STUB_ARGV"
: >"$STUB_QUOTA_LOG"
OUT=$(printf '%s' "$prompt" | STUB_QUOTA_EXHAUSTED=zai "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err9")
is "exhausted route call exits 0" "$?" "0"
out_has "exhausted route answers from GPT-6 Luna" '"model":"openai-codex/gpt-6-luna"'
is "exhausted glm never called" "$(grep -c 'zai/glm' "$STUB_ARGV")" "0"
is "GPT-6 Luna called once" "$(wc -l <"$STUB_ARGV")" "1"
log_has "exhausted skip logged" "model=zai/glm-5.3-flash skipped: quota-axi reports exhausted_now"
fresh "exhausted route gets a dead marker" zai/glm-5.3-flash
is "quota-axi asked for the glm provider" "$(grep -c -- '--provider zai ' "$STUB_QUOTA_LOG")" "1"

# 9e. quota-axi reports another model of the route's provider exhausted_now and the chain's second provider as unsupported:
#     the route is still called first and answers, so the second chain model is never called.
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='zai/glm-5.2-test openai-codex/gpt-6-luna' STUB_QUOTA_JSON='{"providers":[{"provider":"zai","quotaSemantics":{"effectiveAvailability":[{"scope":"model:glm-5.3-flash","runway":{"status":"exhausted_now"}}]}}]}' "$wrapper" --model zai/glm-5.2-test --mode json --no-session 2>"$work/err9e")
is "other model exhausted: exits 0" "$?" "0"
out_has "other model exhausted: route answers" '"model":"zai/glm-5.2-test"'
is "other model exhausted: route called once" "$(wc -l <"$STUB_ARGV")" "1"
is "other model exhausted: Luna never called" "$(grep -c 'openai-codex' "$STUB_ARGV")" "0"

# 9f. quota-axi reports the route's own model (model:<id> scope) exhausted_now: the route is skipped without a call, and a
#     chain provider quota-axi does not know is logged as not pre-checked and called.
nodead
: >"$STUB_ARGV"
: >"$log"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='zai/glm-5.2-test bogus/fallback-model' STUB_QUOTA_JSON='{"providers":[{"provider":"zai","quotaSemantics":{"effectiveAvailability":[{"scope":"model:glm-5.2-test","runway":{"status":"exhausted_now"}}]}}]}' "$wrapper" --model zai/glm-5.2-test --mode json --no-session 2>"$work/err9f")
is "own model exhausted: fallback answers" "$(grep -c 'bogus/fallback-model' "$STUB_ARGV")" "1"
is "own model exhausted: route not called" "$(grep -c 'zai/glm-5.2-test' "$STUB_ARGV")" "0"
log_has "unknown provider logged as not pre-checked" "model=bogus/fallback-model not pre-checked"

# 9b. quota-axi failing: the route is still called as before, and its quota error fails over as usual.
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_QUOTA_FAIL=1 "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err9b")
is "failing quota-axi: failover exits 0" "$?" "0"
is "failing quota-axi: glm still called first" "$(sed -n 1p "$STUB_ARGV")" "$ext_prefix --model zai/glm-5.3-flash --mode json --no-session"
out_has "failing quota-axi: GPT-6 Luna answers" '"model":"openai-codex/gpt-6-luna"'

# 9c. A silent pi (stub hangs with no output) is killed after IDLE_SECS: the next chain model answers for that call,
#     and the stall writes no marker, so the hung route is not dead.
nodead
: >"$log"
: >"$STUB_ARGV"
t0=$(date +%s)
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/hang openai-codex/gpt-6-luna' "$wrapper" --model bad/hang --mode json --no-session 2>"$work/err9c")
is "silent hang exits 0" "$?" "0"
out_has "silent hang fails over to GPT-6 Luna" '"model":"openai-codex/gpt-6-luna"'
log_has "idle kill logged" "pi produced no output for 2s; killing it"
log_has "idle kill moves on to GPT-6 Luna" "model=bad/hang stalled.*no output for 2s.*moving to openai-codex/gpt-6-luna"
if [ $(($(date +%s) - t0)) -lt 10 ]; then ok "silent hang failed over in under 10s"; else no "silent hang took $(($(date +%s) - t0))s"; fi
is "stall writes no marker" "$(age_of bad/hang)" none
if child_gone; then ok "idle kill reached the tool child"; else no "tool child survived the idle kill"; fi

# 9c2. The next call still tries the stalled route first (no marker to skip it), stalls again and fails over.
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/hang openai-codex/gpt-6-luna' "$wrapper" --model bad/hang --mode json --no-session 2>"$work/err9c2")
is "second stall exits 0" "$?" "0"
is "next call tries the stalled route first" "$(sed -n 1p "$STUB_ARGV")" "$ext_prefix --model bad/hang --mode json --no-session"
out_has "second stall fails over to GPT-6 Luna" '"model":"openai-codex/gpt-6-luna"'
if grep -q 'model=bad/hang skipped' "$log"; then no "stalled route was skipped on the next call"; else ok "stalled route is not skipped on the next call"; fi
is "second stall writes no marker" "$(age_of bad/hang)" none

# 9c3. The last route retries three stalls, then fails (four calls total); transient stalls can recover.
nodead
rm -f "$work/flaky"
OUT=$(printf '%s' "$prompt" | STUB_FLAKY="$work/flaky" STUB_FLAKY_STALLS=2 PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/flaky' "$wrapper" --model bad/flaky --mode json --no-session 2>"$work/err9c3a")
is "two stalls then answer exits 0" "$?" "0"
is "two stalls then answer is third call" "$(cat "$work/flaky")" "3"
out_has "third call answer passes through" '"model":"bad/flaky"'
is "successful stall retry writes no marker" "$(age_of bad/flaky)" none
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/hang' "$wrapper" --model bad/hang --mode json --no-session 2>"$work/err9c3b")
is "always-stalled last route exits 1" "$?" "1"
is "always-stalled last route gets four calls" "$(wc -l <"$STUB_ARGV")" "4"
if grep -q 'no model in the chain answered' "$work/err9c3b"; then ok "stalled chain keeps current failure message"; else no "stalled chain lost current failure message"; fi
if grep -q 'quota exhausted' "$work/err9c3b"; then no "stalled chain reported as quota exhausted"; else ok "stalled chain is not reported as quota exhausted"; fi
is "stalled last route writes no marker" "$(age_of bad/hang)" none

# 9c4. A real quota error still writes its marker and the chain moves on, as before.
nodead
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='zai/glm-5.3-flash openai-codex/gpt-6-luna' "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err9c4")
is "quota error call exits 0" "$?" "0"
out_has "quota error still fails over to GPT-6 Luna" '"model":"openai-codex/gpt-6-luna"'
fresh "quota error still writes its marker" zai/glm-5.3-flash

# 9k. A silent pi that ignores TERM is KILLed after the idle grace, its tool child with it, and the next model answers.
nodead
: >"$STUB_ARGV"
rm -f "$STUB_CHILD"
printf '%s' "$prompt" >"$work/prompt9k"
PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/stubborn openai-codex/gpt-6-luna' "$wrapper" --model bad/stubborn --mode json --no-session <"$work/prompt9k" >"$work/out9k" 2>"$work/err9k"
is "TERM-ignoring silent pi: failover exits 0" "$?" "0"
OUT=$(cat "$work/out9k")
out_has "TERM-ignoring silent pi: GPT-6 Luna answers" '"model":"openai-codex/gpt-6-luna"'
is "TERM-ignoring silent pi: one pi call per model" "$(wc -l <"$STUB_ARGV")" "2"
if child_gone; then ok "TERM-ignoring pi's tool child was KILLed"; else no "tool child survived the KILL escalation"; fi

# 9l. A silent pi that exits on TERM leaves its tool child a grace to finish cleanup: the child's cleanup runs before KILL.
nodead
rm -f "$work/cleanup"
OUT=$(printf '%s' "$prompt" | STUB_CLEANUP="$work/cleanup" PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/graceful openai-codex/gpt-6-luna' "$wrapper" --model bad/graceful --mode json --no-session 2>"$work/err9l")
is "graceful tool child: failover exits 0" "$?" "0"
out_has "graceful tool child: GPT-6 Luna answers" '"model":"openai-codex/gpt-6-luna"'
if [ -f "$work/cleanup" ]; then ok "tool child finished cleanup within the grace"; else no "tool child was killed before its cleanup"; fi

# 9n. A call that streams steadily for longer than its idle limit (a large answer) is not killed: its own answer
#     passes through and the chain never moves on.
nodead
logged=$(wc -l <"$log" 2>/dev/null || echo 0)
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/slow-stream openai-codex/gpt-6-luna' "$wrapper" --model bad/slow-stream --mode json --no-session 2>"$work/err9n")
is "steady stream past the idle limit exits 0" "$?" "0"
out_has "steady stream answer is the route's own" '"model":"bad/slow-stream"'
out_count "steady stream never fails over" '"model":"openai-codex' 0
if tail -n +"$((logged + 1))" "$log" | grep -q 'no output for'; then no "steady stream was killed as idle"; else ok "steady stream is not killed as idle"; fi

# 9o. A route that stays silent on its first call and answers on the next is retried once when it is the last route,
#     so the call succeeds with no quota marker and no failover.
nodead
rm -f "$work/flaky"
OUT=$(printf '%s' "$prompt" | STUB_FLAKY="$work/flaky" PI_QUOTA_FAILOVER_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='bad/flaky' "$wrapper" --model bad/flaky --mode json --no-session 2>"$work/err9o")
is "one silent call on the last route exits 0" "$?" "0"
out_has "retried call answers from the same route" '"model":"bad/flaky"'
is "silent-then-answering route was called twice" "$(cat "$work/flaky")" "2"
is "stall retry writes no marker" "$(age_of bad/flaky)" none

# 9p. The idle limit is per model: a claude-bridge route silent for 3 s is not killed under BRIDGE_IDLE_SECS=4 and answers
#     itself; a non-bridge route silent for the same 3 s is killed under IDLE_SECS=1 and the chain moves on.
nodead
: >"$log"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=1 PI_QUOTA_FAILOVER_BRIDGE_IDLE_SECS=4 PI_QUOTA_FAILOVER_CHAIN='claude-bridge/quiet-3s openai-codex/gpt-6-luna' "$wrapper" --model claude-bridge/quiet-3s --mode json --no-session 2>"$work/err9p1")
is "silent bridge route under its limit exits 0" "$?" "0"
out_has "silent bridge route answers itself" '"model":"claude-bridge/quiet-3s"'
if grep -q 'no output for' "$log"; then no "bridge route under its limit was killed"; else ok "bridge route under its limit is not killed"; fi
nodead
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=1 PI_QUOTA_FAILOVER_BRIDGE_IDLE_SECS=4 PI_QUOTA_FAILOVER_CHAIN='bad/quiet-3s openai-codex/gpt-6-luna' "$wrapper" --model bad/quiet-3s --mode json --no-session 2>"$work/err9p2")
is "silent non-bridge route over its limit exits 0" "$?" "0"
out_has "silent non-bridge route fails over to GPT-6 Luna" '"model":"openai-codex/gpt-6-luna"'
log_has "non-bridge kill names IDLE_SECS" "pi produced no output for 1s; killing it"
# The bridge route's own limit is named when it is killed: BRIDGE_IDLE_SECS=2 kills a silent claude-bridge route at 2 s.
nodead
: >"$log"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_IDLE_SECS=1 PI_QUOTA_FAILOVER_BRIDGE_IDLE_SECS=2 PI_QUOTA_FAILOVER_CHAIN='claude-bridge/silent openai-codex/gpt-6-luna' "$wrapper" --model claude-bridge/silent --mode json --no-session 2>"$work/err9p3")
is "silent bridge route over its limit exits 0" "$?" "0"
log_has "bridge kill names BRIDGE_IDLE_SECS" "pi produced no output for 2s; killing it"
log_has "bridge stall detail names BRIDGE_IDLE_SECS" "model=claude-bridge/silent stalled.*no output for 2s"

# 9d. A call killed from outside (not a quota error) keeps the route's existing marker and passes its exit through.
nodead
: >"$log"
backdate zai/glm-5.3-flash
before=$(cat "$dead/zai%glm-5.3-flash")
OUT=$(printf '%s' "$prompt" | STUB_GLM_KILL=1 "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err9d")
rc=$?
is "killed attempt exits with its status" "$rc" "143"
is "killed attempt keeps the glm marker" "$(cat "$dead/zai%glm-5.3-flash")" "$before"

# 9m. An INT to the wrapper's process group leaves no pi alive.
nodead
rm -f "$work/pi.pid"
set -m
PI_QUOTA_FAILOVER_CHAIN='bad/quiet openai-codex/gpt-6-luna' "$wrapper" --model bad/quiet --mode json --no-session <"$prompt_file" >"$work/out9m" 2>"$work/err9m" &
wpid=$!
set +m
for _ in $(seq 50); do [ -s "$work/pi.pid" ] && break; sleep 0.1; done
spid=$(cat "$work/pi.pid" 2>/dev/null)
is "quiet pi started before the INT" "${spid:+yes}" yes
kill -INT -- "-$wpid" 2>/dev/null
wait "$wpid" 2>/dev/null
gone=no
for _ in $(seq 30); do
  s=$(ps -o stat= -p "$spid" 2>/dev/null | tr -d ' ')
  case $s in ''|Z*) gone=yes; break ;; esac
  sleep 0.1
done
kill -KILL "$spid" 2>/dev/null
is "INT to the wrapper's group leaves no pi alive" "$gone" yes

# 10. Extensions: every call runs pi with -ne and -e for each extension pi would load except pi-hermes-memory: pi list
#     packages (manifests, or extensions/ without one), the user extensions dir without backup copies, settings and the
#     built-ins. A settings "-builtin:" entry turns that built-in off. An unreadable pi list runs pi as before, one log line.
pkgs=$work/pkgs
mkdir -p "$pkgs/pi-hermes-memory/src" "$pkgs/pi-claude-bridge/src" "$pkgs/pi-web-access/dist" "$pkgs/pi-plain/extensions" "$home/.pi/agent/extensions"
printf '%s\n' '{"pi":{"extensions":["./src/index.ts"]}}' >"$pkgs/pi-hermes-memory/package.json"
printf '%s\n' '{"pi":{"extensions":["./src/index.ts"]}}' >"$pkgs/pi-claude-bridge/package.json"
printf '%s\n' '{"pi":{"extensions":["./dist"]}}' >"$pkgs/pi-web-access/package.json"
for f in "$pkgs/pi-hermes-memory/src/index.ts" "$pkgs/pi-claude-bridge/src/index.ts" "$pkgs/pi-web-access/dist/index.js" \
  "$pkgs/pi-plain/extensions/a.ts" "$home/.pi/agent/extensions/fm-rm-guard.ts" "$home/.pi/agent/extensions/fm-literal-delete.ts" \
  "$home/.pi/agent/extensions/fm-rm-guard.ts.bak-x"; do echo '// stub' >"$f"; done
printf 'User packages:\n  npm:pi-hermes-memory\n    %s\n  npm:pi-claude-bridge\n    %s\n  npm:pi-web-access\n    %s\n  npm:pi-plain\n    %s\n' \
  "$pkgs/pi-hermes-memory" "$pkgs/pi-claude-bridge" "$pkgs/pi-web-access" "$pkgs/pi-plain" >"$work/pi-list.txt"
export STUB_PI_LIST=$work/pi-list.txt
nodead
has_arg() { case " $(sed -n 1p "$STUB_ARGV") " in *" $1 "*) ok "$2" ;; *) no "$2: argv lacks [$1]: $(sed -n 1p "$STUB_ARGV")" ;; esac; }
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err10")
is "extension run exits 0" "$?" "0"
case $(sed -n 1p "$STUB_ARGV") in "-ne "*) ok "pi runs with -ne" ;; *) no "pi argv lacks -ne first" ;; esac
has_arg "-e $home/.pi/agent/extensions/fm-rm-guard.ts" "fm-rm-guard loads"
has_arg "-e $home/.pi/agent/extensions/fm-literal-delete.ts" "fm-literal-delete loads"
has_arg "-e $pkgs/pi-claude-bridge/src/index.ts" "a package's manifest entry loads"
has_arg "-e $pkgs/pi-web-access/dist/index.js" "a manifest directory loads its index"
has_arg "-e $pkgs/pi-plain/extensions/a.ts" "a package without a manifest loads its extensions dir"
has_arg "-e builtin:mcp" "built-in mcp loads"
case " $(sed -n 1p "$STUB_ARGV") " in *pi-hermes-memory* | *.bak-x*) no "hermes or a backup copy is in argv" ;; *) ok "no pi-hermes-memory and no backup copy in argv" ;; esac

# A settings "-builtin:mcp" turns that built-in off; a pinned call runs with -ne as well.
printf '%s\n' '{"extensions":["-builtin:mcp"]}' >"$home/.pi/agent/settings.json"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err10b")
case " $(sed -n 1p "$STUB_ARGV") " in *" builtin:mcp "*) no "settings -builtin:mcp still loads mcp" ;; *) ok "settings -builtin:mcp turns mcp off" ;; esac
case $(sed -n 1p "$STUB_ARGV") in "-ne "*) ok "pinned call runs with -ne" ;; *) no "pinned call lacks -ne" ;; esac
has_arg "-e builtin:llama.cpp" "other built-ins stay on"
rm -f -- "$home/.pi/agent/settings.json"

# An unreadable pi list: pi runs as before (no -ne), one log line says why, and the call still answers.
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_PI_LIST_EXIT=1 "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err10c")
is "unreadable list: call exits 0" "$?" "0"
case $(sed -n 1p "$STUB_ARGV") in "--model "*) ok "unreadable list: pi runs without -ne" ;; *) no "unreadable list: argv is $(sed -n 1p "$STUB_ARGV")" ;; esac
is "unreadable list: one log line per call" "$(grep -c 'extension list unreadable (pi list exited 1)' "$log")" "1"
out_has "unreadable list: call still answers" '"model":"openai-codex/gpt-6-luna"'

unset STUB_PI_LIST
rm -f -- "$home/.pi/agent/extensions/fm-rm-guard.ts" "$home/.pi/agent/extensions/fm-literal-delete.ts" "$home/.pi/agent/extensions/fm-rm-guard.ts.bak-x"

# 8. install.sh: key-level config edit in a throwaway config, never printing it.
cfg=$work/config.yaml
printf '# no-mistakes global configuration\nagent: pi\nagent_config:\n  pi:\n    model: zai/glm-5.3-flash\n' >"$cfg"
python3 -c 'import yaml' 2>/dev/null || { echo "not ok - python3-yaml missing; skipping install tests"; exit "$fails"; }
if "$here/../install.sh" --dry-run --config "$cfg" --home "$work/share" >"$work/dry" 2>&1; then
  ok "install dry-run exits 0"
else
  no "install dry-run failed"
fi
err_has "dry-run announces the key edit" "$work/dry" "would add key agent_path_override.pi"
before=$(md5sum "$cfg" | cut -d' ' -f1)
if "$here/../install.sh" --config "$cfg" --home "$work/share" >"$work/inst" 2>&1; then
  ok "install exits 0"
else
  no "install failed: $(cat "$work/inst")"
fi
if [ "$before" != "$(md5sum "$cfg" | cut -d' ' -f1)" ]; then ok "config changed"; else no "config unchanged"; fi
if python3 - "$cfg" <<'EOF'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c['agent_path_override']['pi'].endswith('/pi-quota-failover'), c
assert c['agent_config']['pi']['model'] == 'zai/glm-5.3-flash'
assert c['agent'] == 'pi'
EOF
then ok "config parses; only the new key added"; else no "config edit broke YAML"; fi
if "$here/../install.sh" --config "$cfg" --home "$work/share" >/dev/null 2>&1; then
  ok "second install is idempotent"
else
  no "second install failed"
fi
if "$here/../install.sh" --restore --config "$cfg" --home "$work/share" >/dev/null 2>&1; then
  ok "restore exits 0"
else
  no "restore failed"
fi
if python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); assert "agent_path_override" not in c; assert c["agent"] == "pi"' "$cfg"; then
  ok "restore removed only the added key"
else
  no "restore left the key behind or broke the config"
fi
ls "$cfg".bak-pqf-* >/dev/null 2>&1 && ok "backup written" || no "no backup file"

# R. Route failures fall through: a WaitDelay exit, an extension-warning exit and a route with no credit (probe) each
#    move to the next route; a healthy first route is unaffected and is not failed over.
for bad in waitdelay extwarn; do
  nodead
  : >"$log"
  OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN="bad/$bad deepseek/deepseek-flash" "$wrapper" --model bad/$bad --mode json --no-session 2>"$work/errR")
  is "$bad exit falls through, exit 0" "$?" "0"
  out_has "$bad exit lands on the next route" '"model":"deepseek/deepseek-flash"'
  log_has "$bad exit logged as a route failure" 'route-failure'
  is "$bad exit writes no quota marker" "$(age_of "bad/$bad")" "none"
done
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_PROBE=1 PI_QUOTA_FAILOVER_CHAIN="bad/nocredit deepseek/deepseek-flash" "$wrapper" --model bad/nocredit --thinking high --mode json --no-session 2>"$work/errR")
is "no-credit route falls through, exit 0" "$?" "0"
out_has "no-credit route lands on the next route" '"model":"deepseek/deepseek-flash"'
log_has "no-credit probe writes a pulse line" 'pulse: model=bad/nocredit skipped'
is "no-credit route never runs for real" "$(grep -c 'bad/nocredit.*--thinking' "$STUB_ARGV")" "0"
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_PROBE=1 PI_QUOTA_FAILOVER_CHAIN="deepseek/deepseek-flash claude-bridge/claude-haiku-5-5" "$wrapper" --model deepseek/deepseek-flash --thinking high --mode json --no-session 2>"$work/errR")
is "healthy first route exits 0" "$?" "0"
out_has "healthy first route answers" '"model":"deepseek/deepseek-flash"'
is "healthy first route: no haiku call" "$(grep -c 'claude-bridge' "$STUB_ARGV")" "0"
if grep -q 'skipped\|moving to' "$log"; then no "healthy first route was failed over"; else ok "healthy first route logs no skip"; fi

# S. The free MiniMax route heads the default chain and is never credit-probed; an empty-credit route is skipped.
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_PROBE=1 PI_QUOTA_FAILOVER_CHAIN="openrouter/minimax/minimax-m3.1-flash:free bad/nocredit" "$wrapper" --model openrouter/minimax/minimax-m3.1-flash:free --mode json --no-session 2>"$work/errS")
is "free route ahead of an empty-credit route: exit 0" "$?" "0"
out_has "free route answers" '"model":"openrouter/minimax/minimax-m3.1-flash:free"'
is "free route: one pi call, no probe" "$(grep -c ':free' "$STUB_ARGV")" "1"
if grep -q 'skipped' "$log"; then no "free route was skipped"; else ok "free route logs no skip"; fi
nodead
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_PROBE=1 PI_QUOTA_FAILOVER_CHAIN="bad/nocredit openrouter/minimax/minimax-m3.1-flash:free" "$wrapper" --model bad/nocredit --mode json --no-session 2>"$work/errS2")
is "empty-credit route first, free route second: exit 0" "$?" "0"
out_has "empty-credit route skipped, free route answers" '"model":"openrouter/minimax/minimax-m3.1-flash:free"'
log_has "empty-credit route skipped by the probe" 'pulse: model=bad/nocredit skipped'

echo
if [ "$fails" = 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
