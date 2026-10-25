#!/usr/bin/env bash
# Forced-limit journey for fm-model-pool: fixture Umer A/B, A=70% B=40%, A limit then B,
# all Claude under floor then Sol -> Goat -> Cursor, no repeated attempted id, credits refused.
# No network, no real login copy, no real model CLI.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
helper=$addons/account-pool/bin/fm-model-pool
pool=$addons/claude-accounts/bin/claude-accounts-pick
w=$(mktemp -d "${TMPDIR:-/tmp}/model-pool-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/state" "$w/home/config" "$w/a" "$w/b" "$w/c" "$w/pool" "$w/bin" "$w/log"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }

# Recording stand-in for rest/status/pick under prefer: wraps the real chooser and logs argv.
cat >"$w/bin/pool-cmd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$w/log/pool-cmd.log"
exec env FM_HOME="$w/home" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" FM_CLAUDE_ACCOUNTS_FRESH=999999 \
  FM_ACCOUNT_POOL_REST_FLOOR=15 FM_MODEL_POOL_FLOOR=15 "$pool" "\$@"
SH
chmod +x "$w/bin/pool-cmd"
# Refuse any real model binary if PATH leaks.
for name in claude codex cursor opencode pi; do
  printf '#!/bin/sh\necho "error: real model CLI blocked in fixture: %s" >&2\nexit 97\n' "$name" >"$w/bin/$name"
  chmod +x "$w/bin/$name"
done

printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/bin/pool-cmd" >"$w/home/config/account-pool"
cat >"$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"$w/a"},
 {"id":"pa_umer_b","provider":"claude","name":"Umer B","folder":"$w/b"},
 {"id":"pa_credits","provider":"claude","name":"Credits","folder":"$w/c","usage_credits":true}
]}
R

reading() { # fiveA sevenA fiveB sevenB [fiveC sevenC]
  local now
  now=$(date +%s)
  jq -n --argjson at "$now" --arg a pa_umer_a --arg b pa_umer_b --arg c pa_credits \
    --arg fa "$w/a" --arg fb "$w/b" --arg fc "$w/c" \
    --argjson h1 "$1" --argjson d1 "$2" --argjson h2 "$3" --argjson d2 "$4" \
    --argjson h3 "${5:-100}" --argjson d3 "${6:-100}" \
    '{schema:1, generated_at:$at, accounts:[
      {id:$a,name:"Umer A",folder:$fa,five_hour:{left:$h1},seven_day:{left:$d1},read_at:$at,problem:null},
      {id:$b,name:"Umer B",folder:$fb,five_hour:{left:$h2},seven_day:{left:$d2},read_at:$at,problem:null},
      {id:$c,name:"Credits",folder:$fc,five_hour:{left:$h3},seven_day:{left:$d3},read_at:$at,problem:null}]}' \
    >"$w/pool/claude-accounts.json"
  cp "$w/pool/claude-accounts.json" "$w/home/state/claude-accounts.json"
}

run() { # verb json -> sets out/rc; network blocked via empty SSL and no net helpers needed (local only)
  local verb=$1 json=$2
  out=$(printf '%s' "$json" | env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" \
    FM_HOME="$w/home" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" \
    FM_MODEL_POOL_FLOOR=15 FM_ACCOUNT_POOL_REST_FLOOR=15 FM_CLAUDE_ACCOUNTS_LOW=5 \
    FM_CLAUDE_ACCOUNTS_FRESH=999999 \
    "$helper" "$verb" --json 2>"$w/err"); rc=$?
}

cfg=$w/home/config/account-pool
base=$(jq -nc --arg p "$cfg" '{v:1,purpose:"work",pool_config:$p,capabilities:["text"],attempted:[]}')

# A=70 B=40: pick A (greatest runway above 15% eligibility floor).
reading 70 70 40 40
run pick "$base"
is "A (70%) wins over B (40%)" "$(jq -r .id <<<"$out")" pa_umer_a
is "pick ok" "$(jq -r .ok <<<"$out")" true
is "floor wording names both percents" "$(jq -r '.floor.eligibility,.floor.launch_admission' <<<"$out" | tr '\n' ' ')" "15 5 "
is "credits-check logged for A" "$(grep -c 'credits-check accept id=pa_umer_a' "$w/err")" 1

# Typed limit on A -> next returns B; A stays in attempted.
sel=$out
next=$(jq -nc --argjson b "$base" --argjson s "$sel" --argjson a '["pa_umer_a"]' \
  '$b + {selection:$s, cause:"quota", attempted:$a}')
run next "$next"
is "after A limit, B is next" "$(jq -r .id <<<"$out")" pa_umer_b
is "B not a repeat of A" "$(jq -r .id <<<"$out")" pa_umer_b
is "next request carried attempted A" "$(jq -r '.attempted | index("pa_umer_a") != null' <<<"$next")" true

# All Claude below eligibility floor (15%): fall over Sol -> Goat -> Cursor.
reading 10 10 5 5 10 10
run pick "$base"
is "all Claude under floor -> Sol first" "$(jq -r .id <<<"$out")" "route:openai-codex/gpt-6.1-sol"
is "Sol model id" "$(jq -r .model <<<"$out")" "openai-codex/gpt-6.1-sol"
sol=$out
run next "$(jq -nc --argjson b "$base" --argjson s "$sol" --argjson a '["route:openai-codex/gpt-6.1-sol"]' \
  '$b + {selection:$s, cause:"quota", attempted:$a}')"
is "Sol limit -> Goat" "$(jq -r .id <<<"$out")" "route:deepseek/deepseek-goat"
goat=$out
run next "$(jq -nc --argjson b "$base" --argjson s "$goat" --argjson a '["route:openai-codex/gpt-6.1-sol","route:deepseek/deepseek-goat"]' \
  '$b + {selection:$s, cause:"quota", attempted:$a}')"
is "Goat limit -> Cursor auto" "$(jq -r .id <<<"$out")" "route:cursor/auto"
is "Cursor model is auto" "$(jq -r .model <<<"$out")" auto

# No repeated attempted id when asking next again with Cursor already attempted and Claude still low.
run next "$(jq -nc --argjson b "$base" --argjson s "$out" --argjson a '["route:openai-codex/gpt-6.1-sol","route:deepseek/deepseek-goat","route:cursor/auto"]' \
  '$b + {selection:$s, cause:"quota", attempted:$a}')"
is "exhausted routes refuse" "$rc" 1
is "refusal is typed" "$(jq -r .ok <<<"$out")" false

# Credits-enabled account refused even at 100%; fall to Sol and log the check.
cat >"$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"pa_credits","provider":"claude","name":"Credits","folder":"$w/c","usage_credits":true}
]}
R
now=$(date +%s)
jq -n --argjson at "$now" --arg c pa_credits --arg fc "$w/c" \
  '{schema:1,generated_at:$at,accounts:[{id:$c,name:"Credits",folder:$fc,five_hour:{left:100},seven_day:{left:100},read_at:$at,problem:null}]}' \
  >"$w/pool/claude-accounts.json"
cp "$w/pool/claude-accounts.json" "$w/home/state/claude-accounts.json"
: >"$w/err"
run pick "$base"
is "only credits-enabled Claude falls to Sol" "$(jq -r .id <<<"$out")" "route:openai-codex/gpt-6.1-sol"
is "credits refuse logged" "$(grep -c 'credits-check refuse id=pa_credits' "$w/err")" 1

# Deadline across attempts.
past=$(jq -nc --arg p "$cfg" --argjson dl $(($(date +%s) - 5)) '{v:1,purpose:"work",pool_config:$p,deadline:$dl,attempted:[]}')
# restore A/B registry for a clean deadline check
cat >"$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"$w/a"},
 {"id":"pa_umer_b","provider":"claude","name":"Umer B","folder":"$w/b"}
]}
R
reading 70 70 40 40
run pick "$past"
is "past deadline refuses" "$rc" 2
is "deadline reason" "$(jq -r .reason <<<"$out")" "overall deadline passed"

# Default pool_config (lfm account_picker omits it): three cases.
# 1) FM_HOME/config/account-pool when readable.
nopool=$(jq -nc '{v:1,purpose:"work",capabilities:["text"],attempted:[]}')
reading 70 70 40 40
run pick "$nopool"
is "no pool_config uses FM_HOME default" "$(jq -r .id <<<"$out")" pa_umer_a
is "no pool_config pick ok" "$(jq -r .ok <<<"$out")" true

# 2) Explicit pool_config still wins over the FM_HOME default (relative state=
# would never come from the good FM_HOME file; using it proves the request path).
mkdir -p "$w/explicit"
printf 'state=not-absolute\ncommand=%s\n' "$w/bin/pool-cmd" >"$w/explicit/account-pool"
explicit=$(jq -nc --arg p "$w/explicit/account-pool" '{v:1,purpose:"work",pool_config:$p,capabilities:["text"],attempted:[]}')
run pick "$explicit"
is "explicit pool_config wins over FM_HOME default" "$rc" 1
is "explicit config is what was parsed" "$(jq -r .reason <<<"$out")" \
  "config/account-pool must name absolute state="

# 3) No pool_config and no readable default file keeps today's refusal.
run_nodefault() {
  local verb=$1 json=$2
  out=$(printf '%s' "$json" | env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w/emptyhome" TMPDIR="$w" \
    FM_MODEL_POOL_FLOOR=15 FM_ACCOUNT_POOL_REST_FLOOR=15 FM_CLAUDE_ACCOUNTS_LOW=5 \
    FM_CLAUDE_ACCOUNTS_FRESH=999999 \
    "$helper" "$verb" --json 2>"$w/err"); rc=$?
}
mkdir -p "$w/emptyhome"
run_nodefault pick "$nopool"
is "no pool_config and no default refuses" "$rc" 1
is "no-default refusal reason" "$(jq -r .reason <<<"$out")" \
  "pool_config is required (absolute path to config/account-pool)"

# No real model CLI invoked.
is "no model CLI runs" "$(grep -c 'real model CLI blocked' "$w/err" || true)" 0
is "pool-cmd was used" "$(test -s "$w/log/pool-cmd.log" && echo yes || echo no)" yes

[ "$fails" -eq 0 ] || { echo "FAIL: $fails assertions"; exit 1; }
echo "PASS: model-pool forced-limit journey"
exit 0
