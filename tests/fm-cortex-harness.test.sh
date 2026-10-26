#!/usr/bin/env bash
# Portable Cortex Code worker adapter regression. Vendor facts are refreshed by
# fm-cortex-signals-live-e2e.test.sh; this suite needs no Snowflake credentials.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-cortex-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI HERDR_ENV HERDR_PANE_ID HERDR_BIN_PATH

mkdir -p "$TMP_ROOT/names"
for name in cortex cortex-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/cortex" -c '"$1"; :' _ "$HARNESS")
[ "$out" = cortex ] || fail "native Cortex ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/cortex-helper" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm cortex' ] || fail "unrelated cortex-helper claimed the adapter"
[ "$(fm_agent_process_classify_name /home/u/.local/share/cortex/1.1.104/cortex)" = agent ] || fail "liveness lost Cortex"
[ "$(fm_agent_process_classify_name cortex-helper)" = other ] || fail "liveness claims unrelated executable"
pass "Cortex native identity; anchored liveness"

[ "$(fm_control_interrupt_key cortex)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat cortex)" = 1 ] || fail 'Cortex interrupts on a single Escape'
[ -z "$(fm_control_interrupt_clear_key cortex)" ] || fail 'Cortex must not erase a composer draft'
[ "$(fm_control_exit_command cortex)" = /quit ] || fail 'wrong exit command'
fm_control_harness_supports_kind cortex ship || fail 'ship refused'
fm_control_harness_supports_kind cortex scout || fail 'scout refused'
! fm_control_harness_supports_kind cortex secondmate || fail 'secondmate accepted'
pass "worker-only resolution and lifecycle capabilities"

# The captured idle, busy, and draft composers below are byte-for-byte shapes
# Cortex Code 1.1.104 drew in a Herdr pane: a rounded box whose TOP rule carries
# the session title, a reverse-video cursor cell on the first placeholder
# letter, and the `>> ... | teams:` mode line under the box.
esc=$'\033'
rule() { local pad; printf -v pad '%*s' "$1" ''; printf '%s' "${pad// /─}"; }
width=92
screen() {  # <styled-cell> <visible-cell-width> <footer-line> [title]
  local title=${4:-New Session} lead
  lead=$((width - ${#title} - 4))
  printf '%s\n' ' › [Hook] Session context (ctrl+o to expand)' ''
  printf '╭%s %s ──╮\n' "$(rule "$lead")" "$title"
  printf '│ %s %s%*s│\n' "${esc}[1m›${esc}[0m" "$1" "$((width - 3 - $2))" ''
  printf '╰%s╯\n' "$(rule "$width")"
  printf '\n'
  printf '%s\n' '>> bypass safeguards  |  teams: off  |  plan: off  |  guard: on      ⧉ CONN [SQL read-only]'
  printf '%s\n' "$3"
}
plain_caps=$'styled=1\ncursor=0\nidentity=0\nrows=0'
caps=$plain_caps$'\ncortex=1'
idle=$(screen "${esc}[7mT${esc}[0m${esc}[2mype your message...${esc}[0m" 20 'view: compact • ? for help •  master')
busy=$(screen "${esc}[7mT${esc}[0m${esc}[2mype to queue message...${esc}[0m" 24 'view: compact • Type to queue next message • esc to i…')
draft=$(screen 'draft text here'"${esc}[7m ${esc}[0m" 16 'view: compact • ? for help •  master')
ghost=$(screen "${esc}[7m ${esc}[0m${esc}[2mpush it${esc}[0m" 8 'view: compact • ? for help •  master' 'Creating A File')
[ "$(fm_composer_classify_screen "$caps" "$idle")" = empty ] || fail 'idle composer not empty'
wide=${idle//'teams: off  |  plan: off  |  guard: on'/'teams mode: off  |  plan mode: off  |  guardrails: on'}
[ "$wide" != "$idle" ] || fail 'wide mode line fixture did not change'
[ "$(fm_composer_classify_screen "$caps" "$wide")" = empty ] || fail 'wide-terminal mode line made the composer unprovable'
[ "$(fm_composer_classify_screen "$caps" "$busy")" = empty ] || fail 'working composer placeholder not empty'
[ "$(fm_composer_classify_screen "$caps" "$ghost")" = empty ] || fail 'dim follow-up suggestion read as a draft'
[ "$(fm_composer_classify_screen "$caps" "$draft")" = pending ] || fail 'typed draft not preserved'
# Without the proven-cortex capability a titled rounded box is never a
# composer: the identical captures stay ambiguous, exactly as on any harness.
for shape in "$idle" "$busy" "$wide" "$ghost" "$draft"; do
  case "$(fm_composer_classify_screen "$plain_caps" "$shape")" in
    unknown|pending-unproven) ;;
    *) fail 'titled box read as a composer without the cortex capability' ;;
  esac
done
# Titled dialogs whose rows open with an agent glyph are not composers
# for any pane without proven cortex identity.
dialog() {  # <title> <row>...: a titled rounded box exactly $width columns wide
  local title=$1 row
  shift
  printf '╭%s %s ──╮\n' "$(rule "$((width - ${#title} - 4))")" "$title"
  for row in "$@"; do
    printf '│%s%*s│\n' "$row" "$((width - ${#row}))" ''
  done
  printf '╰%s╯\n' "$(rule "$width")"
}
dialog_rows=$(dialog 'Select a model' ' ❯ 1. Opus' '   2. Sonnet')
dialog_filter=$(dialog 'Select a model' ' ❯ Type to filter...')
dialog_empty=$(dialog 'Rename session' ' ❯')
for dialog in "$dialog_rows" "$dialog_filter" "$dialog_empty"; do
  [ "$(fm_composer_classify_screen "$caps" "$dialog")" != "$(fm_composer_classify_screen "$plain_caps" "$dialog")" ] \
    || fail 'dialog fixture is not exercising the identity gate'
done
for dialog in "$dialog_rows" "$dialog_filter" "$dialog_empty"; do
  case "$(fm_composer_classify_screen "$plain_caps" "$dialog")" in
    unknown|pending-unproven) ;;
    *) fail 'titled glyph dialog read as a composer without the cortex capability' ;;
  esac
done
# An untitled bordered box keeps its verdict whether or not the capability is set.
untitled=$(printf '╭%s╮\n│ ❯%*s│\n╰%s╯\n' "$(rule 92)" 89 '' "$(rule 92)")
[ "$(fm_composer_classify_screen "$plain_caps" "$untitled")" = "$(fm_composer_classify_screen "$caps" "$untitled")" ] \
  || fail 'cortex capability changed an untitled box verdict'
# A titled box with no agent prompt glyph is a banner or dialog, not a composer.
banner=$(printf '╭%s Select a model ──╮\n│ ○ Auto (Intelligent)%*s│\n╰%s╯\n' "$(rule 20)" 20 '' "$(rule 40)")
case "$(fm_composer_classify_screen "$caps" "$banner")" in
  empty*|pending) fail 'titled glyph-less box proved a composer' ;;
esac
# The mode line is furniture only with its `| teams:` cell; a bare `>>` shell
# prompt under the box keeps the composer unprovable.
prompt=$(printf '%s\n' "${idle%%$'\n'>>*}" '>> echo hi')
case "$(fm_composer_classify_screen "$caps" "$prompt")" in
  empty) fail 'a dead-shell prompt under the box read as an empty composer' ;;
esac
for signal in 'Hunting...  ▼  · 23 tokens  (esc to interrupt)' '│ › Type to queue message...' 'view: compact • Type to queue next message • esc to i…'; do
  printf '%s\n' "$signal" | fm_busy_lines_match cortex || fail "independent delivery signal lost: $signal"
done
! printf '│ › draft text here\n' | fm_busy_lines_match cortex || fail 'draft read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match cortex || fail 'borrowed another harness signal'
pass "composer shape, draft safety, and independent delivery signals"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
"$ROOT/bin/fm-cortex-plugin.sh" "$state" worker "$gen" || fail 'plugin writer failed'
plugin="$state/worker.cortex-plugin"
jq -e '.name == "firstmate-worker"' "$plugin/.cortex-plugin/plugin.json" >/dev/null || fail 'manifest missing'
hooks="$plugin/hooks/hooks.json"
for event in SessionStart UserPromptSubmit Stop SessionEnd; do
  jq -e --arg e "$event" '.hooks[$e][0].matcher == "*" and .hooks[$e][0].hooks[0].type == "command"' "$hooks" >/dev/null \
    || fail "$event hook missing"
done
[ "$(stat -c %a "$plugin" 2>/dev/null || stat -f %Lp "$plugin")" = 700 ] || fail 'plugin dir is not private'
run_hook() { bash -c "$(jq -r --arg event "$1" '.hooks[$event][0].hooks[0].command' "$hooks")"; }
run_hook UserPromptSubmit
[ "$(fm_busy_classify tmux fake:w cortex worker "$state")" = 'busy cortex-hook' ] || fail 'submit did not open busy'
run_hook Stop
[ "$(fm_busy_classify tmux fake:w cortex worker "$state")" = 'idle cortex-hook' ] || fail 'Stop did not settle'
assert_present "$state/worker.turn-ended" 'Stop notification absent'
run_hook UserPromptSubmit
run_hook SessionEnd
[ "$(fm_busy_classify tmux fake:w cortex worker "$state")" = 'idle cortex-hook' ] || fail 'SessionEnd did not settle'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook Stop
[ "$(fm_busy_classify tmux fake:w cortex worker "$state")" = 'busy fm-spawn' ] || fail 'stale Stop cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale Stop woke replacement'
stop_command=$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")
case "$stop_command" in
  *' --turn-ended '*) ;;
  *) fail 'Stop hook does not raise the turn-end notification under the apply lock' ;;
esac
case "$stop_command" in
  *touch*) fail 'Stop hook touches the turn-end marker outside the apply lock' ;;
esac
wiring=$(fm_control_harness_wiring_paths cortex /unused "$state" worker)
case "$wiring" in *"$hooks"*"$plugin/.cortex-plugin/plugin.json"*) ;; *) fail "plugin retirement paths missing: $wiring" ;; esac
! "$ROOT/bin/fm-cortex-plugin.sh" "$state" 'bad id' "$gen" 2>/dev/null || fail 'invalid task id accepted'
jq -e . "$hooks" >/dev/null || fail 'failed write replaced a valid plugin'
pass "private plugin lifecycle and stale-generation rejection"

# The Herdr reporting clause is a no-op outside Herdr and reports through the
# pane's own CLI inside it: working on a prompt, idle on Stop and SessionStart,
# released on exit, always from firstmate's own source name.
fakeherdr="$TMP_ROOT/herdr-bin"
mkdir -p "$fakeherdr"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP_ROOT/herdr.calls" > "$fakeherdr/herdr"
chmod +x "$fakeherdr/herdr"
: > "$TMP_ROOT/herdr.calls"
run_hook UserPromptSubmit
[ ! -s "$TMP_ROOT/herdr.calls" ] || fail 'a non-Herdr launch called herdr'
export HERDR_ENV=1 HERDR_PANE_ID=w9:p9 HERDR_BIN_PATH="$fakeherdr/herdr"
run_hook UserPromptSubmit
run_hook Stop
run_hook SessionStart
run_hook SessionEnd
unset HERDR_ENV HERDR_PANE_ID HERDR_BIN_PATH
assert_grep 'pane report-agent w9:p9 --source firstmate:cortex --agent cortex --state working' "$TMP_ROOT/herdr.calls" 'working report missing'
assert_grep 'pane report-agent w9:p9 --source firstmate:cortex --agent cortex --state idle' "$TMP_ROOT/herdr.calls" 'idle report missing'
assert_grep 'pane release-agent w9:p9 --source firstmate:cortex --agent cortex' "$TMP_ROOT/herdr.calls" 'release missing'
[ "$(grep -c . "$TMP_ROOT/herdr.calls")" = 4 ] || fail 'wrong Herdr report count'
pass "Herdr self-registration reports through the pane CLI and is a no-op elsewhere"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" cortex
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" cortex
fm_git_worktree "$proj" "$wt" cortex-test
fm_test_spawn_brief "$home" cortex-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" cortex-worker "$proj" --scout --harness cortex --model claude-sonnet-5-5 --effort high 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" '--dangerously-allow-all-tool-calls' 'autonomy flag missing'
assert_contains "$launch" "--plugin-dir '$home/state/cortex-worker.cortex-plugin'" 'private plugin missing'
assert_contains "$launch" "--model 'claude-sonnet-5-5'" 'model lost'
assert_contains "$launch" "--effort 'high'" 'effort lost'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
assert_contains "$launch" 'env -u CLAUDECODE' 'CLAUDECODE not cleared before launch'
case "$launch" in *--sql-read-only*|*--bypass\ *|*--config*) fail 'launch carries an unverified flag' ;; esac
assert_present "$home/state/cortex-worker.cortex-plugin/hooks/hooks.json" 'spawn did not wire hooks'
[ "$(fm_busy_classify tmux fake:w cortex cortex-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" cortex-sm "$proj" --secondmate --harness cortex 2>&1)
then fail 'Cortex secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
proj2="$case_dir/project2"
wt2="$case_dir/wt2"
fm_git_worktree "$proj2" "$wt2" cortex-xhigh
fm_test_spawn_brief "$home" cortex-xhigh
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch-xhigh" fm_test_run_spawn "$home" "$wt2" "$fakebin" cortex-xhigh "$proj2" --scout --harness cortex --effort xhigh 2>&1)
then fail "xhigh spawn failed: $out"; fi
case "$(cat "$case_dir/launch-xhigh")" in *--effort*) fail 'xhigh reached Cortex argv, which has no such level' ;; esac
assert_grep 'effort=xhigh' "$home/state/cortex-xhigh.meta" 'effort not recorded'
pass "scout launch carries autonomy, plugin, typed brief and hooks; xhigh effort omitted"

# Only tmux and Herdr supply the Cortex identity that lets its titled composer
# read empty, so every other spawn-capable backend is refused before any
# endpoint, worktree, or busy record exists.
cat > "$fakebin/orca" <<'EOF'
#!/bin/sh
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
EOF
chmod +x "$fakebin/orca"
for backend in zellij cmux orca; do
  fm_test_spawn_brief "$home" "cortex-$backend"
  if out=$(FM_FAKE_LAUNCH_LOG="$case_dir/cortex-$backend.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "cortex-$backend" "$proj" \
    --scout --harness cortex --backend "$backend" 2>&1)
  then fail "Cortex launch accepted on backend=$backend"; fi
  assert_contains "$out" "cortex is verified on the tmux and herdr backends only; backend=$backend" "wrong refusal on $backend: $out"
  assert_absent "$case_dir/cortex-$backend.launch" "Cortex launched on $backend"
  assert_absent "$home/state/cortex-$backend.meta" "refused $backend spawn left a task record"
  assert_absent "$home/state/cortex-$backend.busy-gen" "refused $backend spawn armed busy state"
done
pass "Cortex launches are refused on zellij, cmux, and orca"
