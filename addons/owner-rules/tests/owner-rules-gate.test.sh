#!/usr/bin/env bash
# owner-rules merge-gate e2e: the config/merge-gate that install.sh writes, run with the args fm-pr-merge.sh passes.
# Usage: owner-rules/tests/owner-rules-gate.test.sh
# Proves one refusal (no receipt) and one clean pass (a stubbed sealed clean done-done run at the head), plus the
# screen: none exemption, the chained previous gate, and the no-op once uninstalled. No forge, no done-done.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-gate.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data/lane/.done-done/runs" "$work/bin" "$work/data/fm-merge-on-green"
printf '#!/bin/sh\nexit 0\n' > "$work/data/fm-merge-on-green/checks-lint.sh"; chmod +x "$work/data/fm-merge-on-green/checks-lint.sh"
pr=https://github.com/umeranjum17/firstmate-addons/pull/9 head=abc123
# gh stub: the PR body is whatever is in $work/body.
printf '#!/bin/sh\ncat "%s/body" 2>/dev/null\n' "$work" > "$work/bin/gh"; chmod +x "$work/bin/gh"
# A previous gate that records it ran.
printf '#!/bin/sh\necho "prev gate ran: $*"\n' > "$home/config/merge-gate"; chmod +x "$home/config/merge-gate"
cat > "$work/bin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] && { jq '{decisions: .items}' "$2"; exit; }
[ "$1" = post ] || exit 2
shift; board=$1; shift
while [ "$1" != --from ]; do shift; done
card=$2
jq --slurpfile c "$card" '.items += [($c[0] + {type:"evidence",filer:"firstmate-merge"})]' "$board" > "$board.tmp" && mv "$board.tmp" "$board"
STUB
chmod +x "$work/bin/sign-off-axi"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
# shellcheck disable=SC2119,SC2120
gate() { PATH=$work/bin:$PATH XDG_DATA_HOME=$work/data FM_HOME=$home FM_FLEET_BOARD=${3:-$work/board.json} "$home/config/merge-gate" lane - "${1:-$head}" "${2:-$pr}" 2>&1; printf 'rc=%s\n' "$?"; }
main=$work/main; mkdir -p "$main/config"
gate_inherit() { env -u FM_FLEET_BOARD PATH="$work/bin:$PATH" FM_HOME="$home" FM_MAIN_HOME="$main" "$home/config/merge-gate" lane - "$head" "$pr" 2>&1; printf 'rc=%s\n' "$?"; }
run=$home/data/lane/.done-done/runs/r1.json
seal() { printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","files":["a.png"],"run_id":"r1"}\n' "$1" > "$run"; }

"$addons/owner-rules/install.sh" "$home" >/dev/null
is "installed: previous gate moved aside" "$([ -x "$home/config/merge-gate.pre-owner-rules" ] && echo yes)" yes
"$addons/owner-rules/install.sh" "$home" >/dev/null && ok "install is idempotent" || no "second install failed"

REFUSAL="owner-rules: no passed-proof receipt for $pr; run the done-done check and post the evidence to the sign-off Evidence tab first"
is "refusal: no receipt" "$(gate)" "$REFUSAL
rc=1"
seal other; is "refusal: a run at a different head" "$(gate | tail -1)" "rc=1"
seal "$head"; printf '{"schema":1,"exit":0,"dirty":true,"commit":"%s","files":["a"],"run_id":"r1"}\n' "$head" > "$run"
is "refusal: a dirty run" "$(gate | tail -1)" "rc=1"
seal "$head"
LINT="owner-rules: no checks-lint PASS for $pr at $head; run FM_HOME=$home $work/data/fm-merge-on-green/checks-lint.sh $pr <evidence folder> first"
is "refusal: receipt but no checks-lint row" "$(gate)" "$LINT
rc=1"
log=$home/data/checks-gate.log
printf 't\t%s\tother\tpass\tok\nt\t%s\t%s\tfail\tno\n' "$pr" "$pr" "$head" > "$log"
is "refusal: lint row for another head, or failed" "$(gate | tail -1)" "rc=1"
printf 't\t%s\t%s\tpass\tok\n' "$pr" "$head" >> "$log"
card_refusal=$(gate)
is "refusal: receipt and lint but missing board card" "$(printf '%s\n' "$card_refusal" | tail -1)" "rc=1"
card_command=$(printf '%s\n' "$card_refusal" | sed -n 's|.*; run FM_HOME=[^ ]* \(/[^ ]*\) post .*|\1|p')
[ -n "$card_command" ] && [ -x "$card_command" ] && ok "card hint names an executable absolute path" || no "card hint command is not an executable absolute path: $card_command"
# Guard gate/check script hints against bare add-on executables (a path is required in every home).
if grep -REn --include='*.sh' --exclude-dir=tests 'run[[:space:]]+(FM_HOME=[^[:space:]]+[[:space:]]+)?(merge-card|fm-[[:alnum:]_-]+\.sh|checks-lint\.sh)([[:space:]]|$)' \
  "$addons/owner-rules" "$addons/merge-card" "$addons/merge-on-green" "$addons/owner-guard" "$addons/read-guard" "$addons/delete-guard" "$addons/kill-guard"; then
  no "bare add-on tool in gate/check hint"
else
  ok "gate/check hints do not name bare add-on tools"
fi
# Main-home fallback, home precedence, then the three-source refusal.
printf '%s\n' "$work/board.json" > "$main/config/fleet-board"
jq --arg h "$head" '.items += [{kind:"evidence",key:"merge-umeranjum17-firstmate-addons-pull-9",run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: lead without board config inherits main board" "$(gate_inherit)" "prev gate ran: lane - $head $pr
rc=0"
printf '%s\n' "$work/own-board.json" > "$home/config/fleet-board"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/own-board.json"
is "refusal: lead board takes precedence over main board" "$(gate_inherit | tail -1)" "rc=1"
rm -f "$home/config/fleet-board" "$main/config/fleet-board"
expected_board="owner-rules: fleet board is not configured (set FM_FLEET_BOARD or $home/config/fleet-board or $main/config/fleet-board) for $pr"
is "refusal: all three board sources missing" "$(gate_inherit | tail -2)" "$expected_board
rc=1"
cardkey=merge-umeranjum17-firstmate-addons-pull-9
jq --arg k "$cardkey" --arg h "$head" '.items += [{kind:"evidence",type:"evidence",filer:"firstmate-merge",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: receipt, lint, and card then previous gate" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"
jq --arg k "$cardkey-$head" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: head-suffixed card matches" "$(gate | tail -1)" "rc=0"
jq --arg k "merge-umeranjum17-firstmate-addons-pull-12-$head" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "refusal: similar pull-12 prefix does not match pull-1" "$(gate | tail -1)" "rc=1"
for fields in '{"run":{"commit":"abc123"}}' '{"evidence":{"commit":"abc123"}}'; do
  jq --argjson fields "$fields" --arg k "$cardkey" '.items = [{kind:"evidence",key:$k} + $fields]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
  is "pass: card commit field $fields" "$(gate | tail -1)" "rc=0"
done
for fields in '{}' '{"run":{"commit":"wrong"}}' '{"evidence":{"commit":"wrong"}}' '{"run":{"commit":"abc123"},"evidence":{"commit":"wrong"}}'; do
  jq --argjson fields "$fields" --arg k "$cardkey" '.items = [{kind:"evidence",key:$k} + $fields]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
  is "refusal: invalid card commit fields $fields" "$(gate | tail -1)" "rc=1"
done
jq --arg k "$cardkey" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
rm -f "$run"; printf 'screen: none\noutcome: checks passed\nevidence: sealed receipt\n' > "$work/body"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
is "refusal: screen: none without receipt refuses" "$(gate | tail -1)" "rc=1"
seal other; is "refusal: screen: none with a sealed run at another head refuses" "$(gate | tail -1)" "rc=1"
seal "$head"
printf '{"verdict":"pass","check":{"claim":"checks passed","evidence":[]}}\n' > "$home/data/lane/merge-card.json"
jq -n '{schema:1,answers_only:false,items:[]}' > "$work/board.json"
is "pass: screen: none and receipt auto-posts text card" "$(gate)" "merge-card: posted text-only $cardkey evidence card
prev gate ran: lane - $head $pr
rc=0"
jq -e --arg k "$cardkey" '.items | any(.[]; .key==$k and .kind=="evidence" and .media==null and .run.commit!=null)' "$work/board.json" >/dev/null && ok "auto-post: text-only receipt card exists" || no "auto-post: text-only receipt card missing"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
is "refusal: unreadable board refuses" "$(gate "$head" "$pr" "$work/missing-board" | tail -1)" "rc=1"
rm -f "$log"; is "refusal: screen: none still needs lint" "$(gate | tail -1)" "rc=1"
rm -f "$work/body"

"$addons/owner-rules/uninstall.sh" "$home" >/dev/null
is "uninstalled: no receipt is fine again" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"

[ "$fails" -eq 0 ] && echo "PASS owner-rules-gate" || { echo "FAIL owner-rules-gate: $fails"; exit 1; }
