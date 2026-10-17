#!/usr/bin/env bash
set -euo pipefail
source tests/fixtures.sh
case_dir="$ROOT/.e3-diagnostic"
home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; id=native-full-record
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
fm_test_spawn_home "$home" codex
fm_git_worktree "$proj" "$wt" wt-full-record
mkdir -p "$home/data/$id" "$home/user-home/.codex"
python3 - "$home/data/$id/brief.md" <<'PY'
import secrets,sys
codes={k:secrets.token_hex(12) for k in ('begin','middle','end')}
goal="Synthetic Firstmate launch transport proof only. Read the entire launch record before acting, using sequential bounded reads with no omitted/truncated bytes. Write only receipt.json in the current directory. Its JSON must contain the three receipt constraint fields distributed through this intent, plus role=\"crewmate\" and inbox equal to the exact steering inbox from the worker role contract. Do not touch notification markers. Do not commit, initialize tools, run validation or contact any external service. After writing the receipt, end the turn with a short acknowledgement.\n"
parts=[goal+'Receipt constraint begin='+codes['begin']+'\n']+['Synthetic inert transport padding. No additional action is authorized.\n'*500]+['Receipt constraint middle='+codes['middle']+'\n']+['Synthetic inert transport padding. No additional action is authorized.\n'*500]+['Receipt constraint end='+codes['end']+'\n']
intent=''.join(parts); intent+='p'*(83828-len(intent.encode()))
open(sys.argv[1],'w').write("# Task\n## Captain's intent\n"+intent+'\n\n## Firstmate spec\nSynthetic source-only launch proof.\n'+('Extra inert specification padding.\n'*1000))
PY
printf 'developer_instructions = "Operator witness %s: fixture authority only."\n' "$(python3 -c 'import secrets;print(secrets.token_hex(16))')" > "$home/user-home/.codex/config.toml"
FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --model gpt-6-sol --effort high --mode no-mistakes --yolo off > "$case_dir/spawn.log" 2>&1
launch=$(<"$case_dir/launch.log")
eval "set -- ${launch#*codex }"
doorbell=${!#}
source bin/fm-operational-input.sh
fm_operational_doorbell_kind "$doorbell" "$home/state" arg
fm_operational_doorbell_path "$doorbell" record
bin/fm-operational-input.sh encode launch-brief < "$home/data/$id/launch-brief.md" > "$case_dir/expected-envelope"
cmp "$record" "$case_dir/expected-envelope"
assignment=''
for arg do case "$arg" in developer_instructions=*) assignment=$arg;; esac; done
[ -n "$assignment" ]
bootstrap=${assignment#developer_instructions=}
bootstrap=${bootstrap#\"}; bootstrap=${bootstrap%\"}
bootstrap="$bootstrap $doorbell"
printf '%s\n' "cwd=$wt" "version=$(codex --version)" "R argv: codex debug prompt-input -c <stock developer_instructions assignment> <canonical doorbell>" "C argv: codex debug prompt-input <stock bootstrap + canonical doorbell>" "doorbell=$doorbell"
sha256sum "$home/user-home/.codex/config.toml" "$home/data/$id/brief.md" "$home/data/$id/launch-brief.md" "$record" "$case_dir/expected-envelope"
cd "$wt"
set +e
HOME="$home/user-home" CODEX_HOME="$home/user-home/.codex" codex debug prompt-input -c "$assignment" "$doorbell" > "$case_dir/R.json" 2> "$case_dir/R.stderr"; r=$?
HOME="$home/user-home" CODEX_HOME="$home/user-home/.codex" codex debug prompt-input "$bootstrap" > "$case_dir/C.json" 2> "$case_dir/C.stderr"; c=$?
set -e
printf 'R exit=%s C exit=%s\n' "$r" "$c"
printf 'R stderr:\n'; head -c 2048 "$case_dir/R.stderr"; printf '\nC stderr:\n'; head -c 2048 "$case_dir/C.stderr"; printf '\n'
wc -c "$case_dir/"{R,C}.json
