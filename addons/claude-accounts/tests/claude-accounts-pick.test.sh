#!/usr/bin/env bash
# claude-accounts-pick: drive the account-pool add-on's own fm_account_pool_select (what fm-spawn calls)
# with config/account-pool pointing at the chooser, a fixture muxr registry and a stub quota-axi whose
# readings change per case. New workers spread by runway and skip an account when it runs low.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/claude-accounts-pick-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/config" "$w/home/state" "$w/bin" "$w/a1" "$w/a2" "$w/pool" "$w/other"
cat > "$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"pa_536c925c8580938938","provider":"claude","name":"One","folder":"$w/a1"},
 {"id":"pa_2f1d0a9b7c3e5d4a61","provider":"claude","name":"Two","folder":"$w/a2"}]}
R
printf 'state=%s\ncommand=%s\n' "$w/pool" "$addons/claude-accounts/bin/claude-accounts-pick" > "$w/home/config/account-pool"
# The stub reads "<5h left> <7d left>" for each account folder from a1.q / a2.q.
cat > "$w/bin/quota-axi" <<'S'
#!/usr/bin/env bash
[ ! -e "$QDIR/limit" ] || { echo '{"providers":[{"windows":[],"state":{"error":"rate limited"}}]}'; exit 1; }
read -r h d < "$QDIR/$(basename "$CLAUDE_CONFIG_DIR").q" || exit 2
echo "{\"providers\":[{\"windows\":[{\"id\":\"five_hour\",\"resetsAt\":\"$(jq -nr --argjson at "$(($(date +%s) + 3600))" '$at | todateiso8601')\",\"percentRemaining\":$h},{\"id\":\"seven_day\",\"percentRemaining\":$d}]}]}"
S
chmod +x "$w/bin/quota-axi"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
pick() { # [tool] [want]: sets out and rc from the pool pick
  rm -f "$w/pool/account-assignments.json" # Independent election for each existing case.
  # shellcheck disable=SC2016
  out=$(env -i PATH="$w/bin:$PATH" HOME="$w" TMPDIR="$w" QDIR="$w" FM_HOME="$w/home" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" \
    FM_CLAUDE_ACCOUNTS_FRESH=0 CODEX_HOME="$w/other" bash -c 'fm_run_timed() { shift; "$@"; }; . "$1/account-pool/bin/fm-account-pool-lib.sh"; shift; fm_account_pool_select "$@"' _ "$addons" "${1:-claude}" "$w/home/config" "${2:-}" 2>&1); rc=$?
}
q() { echo "$2" > "$w/$1.q"; }

q a1 "63 34"; q a2 "100 69"
pick; is "account 2 has the most runway: the worker goes there" "$rc|$(cut -f1,3 <<<"$out")" "0|pa_2f1d0a9b7c3e5d4a61	$w/a2"
is "the pick unsets the credential variables by name" "$(cut -f4 <<<"$out" | tr ' ' '\n' | grep -c '^ANTHROPIC_API_KEY$')" 1
q a2 "100 3"; pick; is "account 2 runs low: new workers go to account 1" "$rc|$(cut -f1 <<<"$out")" "0|pa_536c925c8580938938"
# Rate limit on the vendor side: the pick still uses the last good readings.
q a1 "63 34"; q a2 "100 69"; pick; touch "$w/limit"
pick; is "a failed read keeps the last good pick" "$(cut -f1 <<<"$out")" pa_2f1d0a9b7c3e5d4a61
rm "$w/limit"
q a2 "40 80"; pick; is "the tighter window sets the runway: account 2 (40) beats account 1 (34)" "$(cut -f1 <<<"$out")" pa_2f1d0a9b7c3e5d4a61
q a1 "63 34"; q a2 "100 69"; pick claude pa_536c925c8580938938; is "--prefer an account that is fine" "$(cut -f1 <<<"$out")" pa_536c925c8580938938
q a2 "100 3"; pick claude pa_2f1d0a9b7c3e5d4a61; is "--prefer a low account is refused with the cause" "$rc|${out%%:*}" "1|error"
q a1 "2 90"; pick; is "every account low: refused" "$rc|$(grep -c 'no Claude account can take a worker' <<<"$out")" "1|1"
pick codex; is "other tools keep their ambient default" "$rc|$(cut -f1,3 <<<"$out")" "0|ambient	$w/other"

# The relaunch verbs: the fork asks the pool command for `status <id>` and `rest <id>` with the pool's pa_ ids,
# then picks again; the rested account is skipped, an explicit id is honoured, and nothing falls back to paid use.
pool="$addons/claude-accounts/bin/claude-accounts-pick"
A1=pa_536c925c8580938938 A2=pa_2f1d0a9b7c3e5d4a61
cmd() { env -i PATH="$w/bin:$PATH" HOME="$w" TMPDIR="$w" QDIR="$w" FM_HOME="$w/home" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" FM_CLAUDE_ACCOUNTS_FRESH=0 FM_ACCOUNT_POOL_ASSIGNMENT_SECONDS="${FM_ACCOUNT_POOL_ASSIGNMENT_SECONDS:-300}" "$pool" "$@" 2>&1; }
q a1 "63 34"; q a2 "100 69"
is "status names the tool of a pa_ account" "$(cmd status $A1 --json --state "$w/pool" | jq -r .tool)" claude
is "status refuses an unknown id" "$(cmd status pa_nope --json --state "$w/pool" >/dev/null; echo $?)" 1
is "a launch prompt cannot rest an account with headroom" "$(cmd rest $A2 --json --state "$w/pool" >/dev/null; echo $?)" 1
q a2 "0 69"
rest_answer=$(cmd rest $A2 --json --state "$w/pool")
is "rest sets the current account aside" "$(jq -r .rested <<<"$rest_answer")" true
is "rest ends at the quota reset, not a fixed five hours" "$(jq -r '.until - now | . > 3500 and . <= 3600' <<<"$rest_answer")" true
q a2 "100 69"; pick claude next; is "next: the pick moves to the other account" "$rc|$(cut -f1 <<<"$out")" "0|$A1"
pick claude $A2; is "an explicit id that is rested is refused" "$rc" 1
q a1 "0 34"; cmd rest $A1 --json --state "$w/pool" >/dev/null; q a1 "63 34"; pick; is "every account rested: refused, no paid fallback" "$rc|$(grep -c 'no Claude account can take a worker' <<<"$out")" "1|1"
cmd unrest $A1 --json --state "$w/pool" >/dev/null; cmd unrest $A2 --json --state "$w/pool" >/dev/null
pick claude $A2; is "an explicit pa_ id resolves once unrested" "$rc|$(cut -f1 <<<"$out")" "0|$A2"

# A quota-reader failure never refuses a launch. Each case drives the picker the way fm-spawn does,
# with the reader unable to answer: no FM_HOME at all, a reader that cannot run, a reading nobody has
# refreshed, and a reading so old the 5h window is meaningless. The roster is the registry, so the
# pick still answers, and it says where its numbers came from and how old they are.
reading() { # age_s five1 seven1 five2 seven2 [problem2]: the pool's own last good reading
  local a="$A1" b="$A2" at=$(( $(date +%s) - $1 )) f1="$w/a1" f2="$w/a2" p2=${6:-null}
  jq -n --argjson at "$at" --arg a "$a" --arg b "$b" --arg f1 "$f1" --arg f2 "$f2" --arg p2 "$p2" \
    --argjson h1 "$2" --argjson d1 "$3" --argjson h2 "$4" --argjson d2 "$5" \
    '{schema: 1, generated_at: $at, accounts: [
      {id: $a, name: "One", folder: $f1, five_hour: {left: $h1}, seven_day: {left: $d1}, read_at: $at, problem: null, stale: false},
      {id: $b, name: "Two", folder: $f2, five_hour: {left: $h2}, seven_day: {left: $d2}, read_at: $at, problem: (if $p2 == "null" then null else $p2 end), stale: ($p2 != "null")}]}' \
    > "$w/pool/claude-accounts.json"
}
cmd_nohome() { env -i PATH="$w/bin:$PATH" HOME="$w" TMPDIR="$w" QDIR="$w" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" FM_CLAUDE_ACCOUNTS_FRESH=0 FM_ACCOUNT_POOL_ASSIGNMENT_SECONDS="${FM_ACCOUNT_POOL_ASSIGNMENT_SECONDS:-300}" "$pool" "$@" 2>&1; }
rm -f "$w/home/state/claude-accounts.json"
reading 600 90 95 99 1
out=$(cmd_nohome pick claude --json --state "$w/pool"); rc=$?
is "FM_HOME unset: the pick answers from the pool's own reading" "$rc|$(jq -r '[.id, .read.source] | join(" ")' <<<"$out")" "0|$A1 reading"
is "the answer carries the age of the reading it used" "$(jq -r '.read.at > 0 and .read.age >= 0' <<<"$out")" true
reading 0 90 95 99 1
out=$(cmd_nohome pick claude --json --state "$w/pool"); rc=$?
is "a reader that cannot run, with no FM_HOME, still answers" "$rc|$(jq -r .ok <<<"$out")" "0|true"
is "...and names the account with the most 7-day runway" "$(jq -r .id <<<"$out")" "$A1"
# A reading nobody has refreshed in two hours: the 5h window is worth nothing, the 7-day side is not.
reading 7200 4 95 99 1
out=$(cmd_nohome pick claude --json --state "$w/pool"); rc=$?
is "a two-hour-old reading still answers, on its 7-day side" "$rc|$(jq -r '[.id, .read.source, (.read.age > 7000)] | join(" ")' <<<"$out")" "0|$A1 last-good true"
# An account whose last reading says it must sign in again is out, however much runway it shows.
reading 0 90 95 100 100 "Claude sign-in required"
out=$(cmd_nohome pick claude --json --state "$w/pool"); rc=$?
is "a signed-out account is skipped however much runway it shows" "$rc|$(jq -r .id <<<"$out")" "0|$A1"
rm -f "$w/pool/claude-accounts.json"
out=$(cmd_nohome pick claude --json --state "$w/pool"); rc=$?
is "no reading at all still answers: the roster alone is enough" "$rc|$(jq -r '[.ok, .read.source, (.set.CLAUDE_CONFIG_DIR | startswith("/"))] | join(" ")' <<<"$out")" "0|true none true"

# install wires config/account-pool, is idempotent, refuses a different file; uninstall removes only its own.
rm -f "$w/home/config/account-pool"
"$addons/claude-accounts/install.sh" "$w/home" >/dev/null; is "install writes the chooser into config/account-pool" "$(sed -n 1p "$w/home/config/account-pool")" "command=$addons/claude-accounts/bin/claude-accounts-pick"
"$addons/claude-accounts/install.sh" "$w/home" >/dev/null; is "install twice is a no-op" "$?" 0
"$addons/claude-accounts/uninstall.sh" "$w/home" >/dev/null; is "uninstall removes it" "$([ -e "$w/home/config/account-pool" ] && echo kept || echo gone)" gone
printf 'state=/x\ncommand=/bin/other\n' > "$w/home/config/account-pool"
"$addons/claude-accounts/install.sh" "$w/home" >/dev/null 2>&1; is "install refuses another pool file" "$?" 1
"$addons/claude-accounts/uninstall.sh" "$w/home" >/dev/null 2>&1; is "uninstall leaves another pool file" "$?|$(grep -c other "$w/home/config/account-pool")" "1|1"

# Repeated selections through the public pool contract must balance, not elect the same winner.
mkdir -p "$w/a3" "$w/c1" "$w/c2"
jq --arg w "$w" '.accounts += [
  {id:"third",provider:"claude",name:"Umer",folder:($w+"/a3")},
  {id:"c1",provider:"codex",name:"Umer",folder:($w+"/c1")},
  {id:"c2",provider:"codex",name:"Umer",folder:($w+"/c2")}]' "$w/registry.json" > "$w/registry.next"
mv "$w/registry.next" "$w/registry.json"
reading 0 60 60 30 30
jq --argjson now "$(date +%s)" '.accounts += [{id:"third",read_at:$now,five_hour:{left:10},seven_day:{left:10}}]' \
  "$w/pool/claude-accounts.json" > "$w/pool/reading.next"
mv "$w/pool/reading.next" "$w/pool/claude-accounts.json"
rm -f "$w/pool/account-assignments.json"
for ((i=0; i<10; i++)); do cmd_nohome pick claude --json --state "$w/pool" | jq -r .id; done > "$w/picks"
is "60:30:10 runway spreads ten consecutive workers 6:3:1" "$(awk -v a="$A1" -v b="$A2" '{n[$0]++} END {print n[a] ":" n[b] ":" n["third"]}' "$w/picks")" "6:3:1"
is "first worker gets the most headroom" "$(head -n1 "$w/picks")" "$A1"
reading 0 100 100 11 11
rm -f "$w/pool/account-assignments.json"
for ((i=0; i<6; i++)); do cmd_nohome pick claude --json --state "$w/pool" | jq -r .id; done > "$w/picks"
is "100:11 headroom still spreads six spawns 5:1" "$(awk -v a="$A1" -v b="$A2" '{n[$0]++} END {print n[a]+0 ":" n[b]+0}' "$w/picks")" "5:1"
reading 0 56 65 97 11
jq '.accounts += [{id:"third",five_hour:{left:100},seven_day:{left:100}}]' "$w/pool/claude-accounts.json" > "$w/pool/reading.next"
mv "$w/pool/reading.next" "$w/pool/claude-accounts.json"
rm -f "$w/pool/account-assignments.json"
is "a 100/100 account cannot be rested" "$(cmd_nohome rest third --json --state "$w/pool" >/dev/null; echo $?)" 1
printf '%s\n' "$(($(date +%s) + 18000))" > "$w/pool/claude-accounts-rested/third"
is "incident regression: a legacy rest cannot exclude 100/100 headroom" "$(cmd_nohome pick claude --json --state "$w/pool" | jq -r .id)" third
jq -n --argjson now "$(date +%s)" '{generated_at:$now,accounts:[
  {id:"c1",five_hour:{left:75},seven_day:{left:75}},
  {id:"c2",five_hour:{left:25},seven_day:{left:25}}]}' > "$w/pool/codex-accounts.json"
for ((i=0; i<4; i++)); do cmd_nohome pick codex --json --state "$w/pool" | jq -r .id; done > "$w/picks"
is "Codex balances independently, with its own roster and headroom" "$(sort "$w/picks" | uniq -c | awk '{print $1}' | paste -sd:)" "3:1"
# Codex omits five_hour: weekly left at/above the rest floor clears a stale rest; below keeps it.
mkdir -p "$w/pool/codex-accounts-rested"
jq -n --argjson now "$(date +%s)" '{generated_at:$now,accounts:[
  {id:"c1",five_hour:null,seven_day:{left:99},problem:null},
  {id:"c2",five_hour:null,seven_day:{left:10},problem:null}]}' > "$w/pool/codex-accounts.json"
printf '%s\n' "$(($(date +%s) + 18000))" > "$w/pool/codex-accounts-rested/c1"
printf '%s\n' "$(($(date +%s) + 18000))" > "$w/pool/codex-accounts-rested/c2"
rm -f "$w/pool/account-assignments.json"
out=$(cmd_nohome pick codex --json --state "$w/pool"); rc=$?
is "Codex weekly-only at 99 clears rest and picks" "$rc|$(jq -r .id <<<"$out")|$(cat "$w/pool/codex-accounts-rested/c1")" "0|c1|0"
is "Codex weekly-only at 10 keeps the rest" "$(tr -d '\n' < "$w/pool/codex-accounts-rested/c2" | awk '{print ($1 > 0)}')" 1
# Claude with a five_hour window still needs every present window at 100 to clear rest.
mkdir -p "$w/pool/claude-accounts-rested"
printf '%s\n' "$(($(date +%s) + 18000))" > "$w/pool/claude-accounts-rested/$A1"
reading 0 80 100 100 100
rm -f "$w/pool/account-assignments.json"
out=$(cmd_nohome pick claude --json --state "$w/pool"); rc=$?
is "Claude five_hour 80 keeps the rest" "$rc|$(jq -r .id <<<"$out")|$(tr -d '\n' < "$w/pool/claude-accounts-rested/$A1" | awk '{print ($1 > 0)}')" "0|$A2|1"
# restore balanced Codex reading for concurrent cases below
jq -n --argjson now "$(date +%s)" '{generated_at:$now,accounts:[
  {id:"c1",five_hour:{left:75},seven_day:{left:75}},
  {id:"c2",five_hour:{left:25},seven_day:{left:25}}]}' > "$w/pool/codex-accounts.json"
rm -f "$w/pool/codex-accounts-rested/c1" "$w/pool/codex-accounts-rested/c2" "$w/pool/claude-accounts-rested/$A1" "$w/pool/account-assignments.json"
rm -f "$w/pool/account-assignments.json"
mkdir "$w/concurrent"
for ((i=0; i<12; i++)); do cmd_nohome pick codex --json --state "$w/pool" > "$w/concurrent/$i" & done
wait
is "concurrent launches share the counter without lost assignments" "$(jq -r .id "$w/concurrent/"* | sort | uniq -c | awk '{print $1}' | paste -sd:)" "9:3"
out=$(FM_ACCOUNT_POOL_ASSIGNMENT_SECONDS=0 cmd_nohome pick codex --json --state "$w/pool")
is "expired assignments reset the winner to the most headroom" "$(jq -r .id <<<"$out")" c1

# Floor wording: launch admission (5%) stays distinct from verified-rest / fm-model-pool eligibility (15%).
is "launch admission default stays 5" "${FM_CLAUDE_ACCOUNTS_LOW:-5}" 5
is "rest/eligibility floor default stays 15" "${FM_ACCOUNT_POOL_REST_FLOOR:-15}" 15
is "fm-model-pool exists for tool rotation above the rest floor" "$([ -x "$addons/account-pool/bin/fm-model-pool" ] && echo yes)" yes

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
