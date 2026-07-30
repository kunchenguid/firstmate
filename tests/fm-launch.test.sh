#!/usr/bin/env bash
# tests/fm-launch.test.sh - bin/fm-launch.sh, the captain's front door.
#
# The launcher is the one place in firstmate a human, not an agent, starts a
# session, so this suite pins the properties that make that safe and honest:
#
#   1. Availability is PROBED, never declared. An entry renders available only
#      when it could actually start right now, and an entry that could not stays
#      VISIBLE and unselectable with one actionable line, so the menu never
#      changes shape under the captain's muscle memory.
#   2. The menu touches NO network and executes no harness binary. Both probes
#      are local reads; that is what holds the first-paint budget.
#   3. The autonomy notice is present on every render. bin/fm-launch-lib.sh's
#      header binds every consumer of a `primary` template to tell the captain
#      the session runs without permission prompts, and this launcher is that
#      consumer.
#   4. Herdr is mandatory, with no silent fallback to a bare shell.
#   5. A second launch can never produce two primaries in one home.
#   6. Nothing is created before a selection, and a scripted caller must select
#      EXPLICITLY - a blank line or EOF refuses rather than launching whatever
#      the default happens to be.
#
# Property 6 is here because it was a real defect, not a hypothetical: the first
# draft took the default on EOF, and one `printf '\n' | fm-launch.sh` against a
# live machine started an unattended Claude primary in the captain's own herdr
# workspace. The fake below exists so this file can never repeat that.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCH="$ROOT/bin/fm-launch.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch)

# --- fakes ------------------------------------------------------------------

# make_launch_fakebin <dir>: a fakebin holding a STATEFUL `herdr` plus logging
# stubs for every harness binary and every network tool. Two jobs:
#
#   - model enough of herdr for a full select -> gate -> create -> send -> attach
#     run (the canned-response fake in tests/fm-backend-herdr.test.sh cannot
#     carry state across calls, and models neither `pane read` nor `session
#     attach`, which this path needs);
#   - PROVE the menu is inert. Every stub appends to $FM_LAUNCH_EXEC_LOG when it
#     is EXECUTED, so a menu render that shells out to a harness or the network
#     is a visible failure rather than a slow test.
#
# `command -v` never executes a stub, so an inert menu leaves the log empty even
# though every harness resolves on PATH.
make_launch_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin" tool
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{},"server":"true","prompt":"$ "}\n' > "$dir/state.json"

  for tool in claude codex opencode pi pi-signed grok kimi curl wget nc ping; do
    cat > "$fb/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "${FM_LAUNCH_EXEC_LOG:-/dev/null}"
exit 0
SH
    chmod +x "$fb/$tool"
  done

  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
printf 'herdr %s\n' "$*" >> "${FM_LAUNCH_EXEC_LOG:-/dev/null}"
printf 'herdr %s\n' "$*" >> "${FM_HERDR_LOG:-/dev/null}"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
if [ "${FM_FAKE_HERDR_FAIL:-}" = "$cmd $sub" ]; then
  exit 1
fi
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":%s},"server":{"running":%s}}\n' \
      "${FM_FAKE_HERDR_PROTOCOL:-14}" "$(jq_state -r '.server')"
    ;;
  "server ")
    jq_state '.server = "true"' | save
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"%s"}}\n' "$pane" >&2
    else
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    fi
    ;;
  "pane read")
    jq_state -r '.prompt'
    ;;
  "pane close")
    jq_state --arg p "${3:-}" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"%s"}}\n' "$pane" >&2
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# launch_case <name>: a private FM_HOME plus a fakebin, both under TMP_ROOT.
# Echoes "<home>\n<fakebin>\n<state.json>\n<exec log>".
launch_case() {  # <name>
  local dir="$TMP_ROOT/$1" fb
  mkdir -p "$dir/home/state" "$dir/home/config"
  fb=$(make_launch_fakebin "$dir")
  : > "$dir/exec.log"
  printf '%s\n%s\n%s\n%s\n' "$dir/home" "$fb" "$dir/state.json" "$dir/exec.log"
}

# run_launch <home> <fakebin> <state> <execlog> <stdin> [env=val ...]
# Runs the launcher with a PATH containing ONLY the fakebin and the system dirs
# jq/git live in, so no real harness or herdr can ever be reached.
run_launch() {
  local home=$1 fb=$2 state=$3 execlog=$4 input=$5
  shift 5
  printf '%s' "$input" | env \
    PATH="$fb:/usr/bin:/bin" \
    FM_HOME="$home" \
    FM_BACKEND= \
    FM_LAUNCH_PI_AUTH="$home/pi-auth.json" \
    FM_FAKE_HERDR_STATE="$state" \
    FM_LAUNCH_EXEC_LOG="$execlog" \
    FM_LAUNCH_READY_ATTEMPTS=3 \
    FM_LAUNCH_READY_SLEEP=0.01 \
    FM_LAUNCH_NO_ATTACH=1 \
    "$@" \
    bash "$LAUNCH" 2>&1
}

# render_menu_out <home> <fakebin> [env=val ...]: the menu only, never a launch.
render_menu_out() {
  local home=$1 fb=$2
  shift 2
  printf '' | env \
    PATH="$fb:/usr/bin:/bin" \
    FM_HOME="$home" \
    FM_BACKEND= \
    FM_LAUNCH_PI_AUTH="$home/pi-auth.json" \
    "$@" \
    bash "$LAUNCH" --print-menu 2>&1
}

# menu_row <menu> <label>: the single rendered row for <label>. Row-scoped
# assertions matter here - a whole-menu substring match would happily find one
# entry's fix line while claiming it belongs to another.
menu_row() {
  printf '%s\n' "$1" | grep -F -- "$2" | head -1
}

write_pi_auth() {  # <home> <provider>...
  local home=$1 provider body=""
  shift
  for provider in "$@"; do
    body="$body\"$provider\": {\"type\": \"oauth\", \"access\": \"x\"},"
  done
  printf '{%s"_end": {}}\n' "$body" > "$home/pi-auth.json"
}

# --- menu: probed availability ----------------------------------------------

test_menu_shows_all_five_entries_always() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case five-entries)
EOF
  out=$(render_menu_out "$home" "$fb")
  local label
  for label in Claude "ChatGPT Sol" Grok Codex OpenCode; do
    assert_contains "$out" "$label" "the menu must always list $label"
  done
  assert_contains "$out" "1-5 select" "the menu must offer all five slots"
  pass "menu: all five entries are always visible"
}

test_menu_probes_rather_than_declares_availability() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case probe)
EOF
  # No pi auth record at all: both Pi-routed entries must be unavailable, and
  # each must carry its own actionable line rather than just disappearing.
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$out" "sign in: pi /login" "an unauthenticated Pi provider must show its sign-in fix"
  assert_contains "$out" "Grok" "an unavailable entry stays visible"

  # Authenticate exactly one provider: that entry flips to available and the
  # other keeps its fix line. Availability tracks the local record, nothing else.
  write_pi_auth "$home" openai-codex
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$(menu_row "$out" "ChatGPT Sol")" "via pi" \
    "the authenticated Pi entry must show its route"
  assert_not_contains "$(menu_row "$out" "ChatGPT Sol")" "sign in" \
    "an authenticated Pi provider must not show a sign-in fix"
  assert_contains "$(menu_row "$out" Grok)" "sign in: pi /login" \
    "the still-unauthenticated Pi provider keeps its fix"
  pass "menu: availability is probed from the local Pi auth record, not declared"
}

test_menu_marks_missing_native_binaries_unavailable() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case native-missing)
EOF
  rm -f "$fb/codex" "$fb/opencode"
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$out" "not installed - install codex" "a missing native binary must show an install fix"
  assert_contains "$out" "not installed - install opencode" "a missing native binary must show an install fix"
  assert_contains "$out" "Codex" "an uninstalled entry stays visible"
  pass "menu: a missing native binary renders unavailable with an install fix"
}

test_menu_reports_the_two_launch_template_refusals_differently() {
  local home fb state execlog out presets
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case template-refusals)
EOF
  # bin/fm-launch-lib.sh's header binds a consumer that passes kind=primary to
  # tell the two refusal causes apart: an unverified adapter's remedy is a raw
  # launch command, while a verified adapter with no primary shape is fixed by
  # choosing another entry. kimi is today's only cause-2 harness.
  presets="$home/presets.json"
  cat > "$presets" <<'JSON'
{"entries":[
  {"id":"kimi","label":"Kimi","harness":"kimi","model":"default","effort":"default"},
  {"id":"bogus","label":"Bogus","harness":"nosuchharness","model":"default","effort":"default"}
]}
JSON
  out=$(render_menu_out "$home" "$fb" FM_LAUNCH_PRESETS="$presets")
  assert_contains "$out" "no primary session - choose another entry" \
    "a verified adapter with no primary shape must say to choose another entry"
  assert_contains "$out" "unknown runtime nosuchharness" \
    "an unverified adapter must be named as a preset error"
  assert_not_contains "$out" "raw launch" "the menu must not offer a raw-launch escape hatch"
  pass "menu: the two launch_template refusal causes get different wording"
}

test_pi_signed_shares_the_provider_probe_but_not_the_executable() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case pi-signed)
EOF
  cat > "$home/config/launch-presets.json" <<'JSON'
{"entries":[{"id":"grok-signed","label":"Grok Signed","harness":"pi-signed","model":"xai/grok-4","effort":"high"}]}
JSON
  # Provider half: pi-signed reads the same auth record as pi, so an
  # unauthenticated provider must show the sign-in fix even though the
  # pi-signed executable resolves on PATH.
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$(menu_row "$out" "Grok Signed")" "via pi - sign in: pi /login" \
    "a pi-signed entry with an unauthenticated provider must show the sign-in fix"

  write_pi_auth "$home" xai
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$(menu_row "$out" "Grok Signed")" "via pi" \
    "an authenticated pi-signed entry must show its route"
  assert_not_contains "$(menu_row "$out" "Grok Signed")" "sign in" \
    "an authenticated pi-signed entry must not show a sign-in fix"

  # PATH half: pi-signed is an explicitly selected executable identity
  # (bin/fm-spawn.sh), never an alias for pi, so pi on PATH is not enough.
  rm -f "$fb/pi-signed"
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$(menu_row "$out" "Grok Signed")" "not installed - install pi-signed" \
    "a pi-signed entry must be unavailable when only pi is on PATH"
  pass "probe: pi-signed shares pi's provider probe but keeps its own executable identity"
}

# --- menu: the inherited consumer obligation --------------------------------

test_menu_states_the_no_permission_prompt_posture() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case autonomy-notice)
EOF
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$out" "without permission prompts" \
    "bin/fm-launch-lib.sh's CONSUMER OBLIGATION requires the launcher to state the session posture at the front door"
  # It must be at the door, before the choice - not buried after a selection.
  case "${out%%Claude*}" in
    *"without permission prompts"*) : ;;
    *) fail "the autonomy notice must appear before the entries, while the captain is still choosing:"$'\n'"$out" ;;
  esac
  pass "menu: the no-permission-prompt posture is stated before the choice"
}

# --- menu: no network, no side effects --------------------------------------

test_menu_executes_nothing() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case inert)
EOF
  write_pi_auth "$home" openai-codex xai
  out=$(render_menu_out "$home" "$fb" FM_FAKE_HERDR_STATE="$state" FM_LAUNCH_EXEC_LOG="$execlog")
  [ -s "$execlog" ] \
    && fail "rendering the menu must execute no harness, herdr, or network binary, but ran:"$'\n'"$(cat "$execlog")"
  assert_contains "$out" "Firstmate" "the menu still rendered"
  pass "menu: renders with zero subprocess execution - no network, no herdr status"
}

test_menu_creates_nothing() {
  local home fb state execlog before after
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case no-side-effects)
EOF
  before=$(find "$home" | sort)
  run_launch "$home" "$fb" "$state" "$execlog" $'q\n' >/dev/null 2>&1
  after=$(find "$home" | sort)
  [ "$before" = "$after" ] || fail "quitting the menu must leave the home untouched"
  [ "$(jq -r '.workspaces | length' "$state")" = 0 ] \
    || fail "quitting the menu must create no herdr workspace"
  pass "menu: q quits clean, creating nothing"
}

test_print_menu_is_fast() {
  local home fb state execlog start end elapsed
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case speed)
EOF
  write_pi_auth "$home" openai-codex xai
  start=$(date +%s%N 2>/dev/null) || start=""
  render_menu_out "$home" "$fb" >/dev/null 2>&1
  end=$(date +%s%N 2>/dev/null) || end=""
  if [ -z "$start" ] || [ -z "$end" ] || [ "$start" = "$end" ]; then
    pass "menu: speed ceiling skipped (no nanosecond clock)"
    return 0
  fi
  elapsed=$(( (end - start) / 1000000 ))
  # The DESIGN target is 150 ms of first paint; the ENFORCED ceiling is 500 ms
  # so a loaded CI box, or a PATH whose misses cross a slow filesystem mount,
  # cannot flake this. See bin/fm-launch.sh's harness_on_path note.
  [ "$elapsed" -lt 500 ] || fail "menu render took ${elapsed}ms, over the 500ms ceiling"
  pass "menu: renders in ${elapsed}ms, inside the 500ms ceiling"
}

# --- selection --------------------------------------------------------------

test_scripted_selection_refuses_rather_than_reprompting() {
  local home fb state execlog out rc bad
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case scripted-refusals)
EOF
  write_pi_auth "$home" openai-codex
  for bad in 9 x; do
    out=$(run_launch "$home" "$fb" "$state" "$execlog" "$bad"$'\n') && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "a non-TTY selection of '$bad' must refuse, not reprompt"
    assert_contains "$out" "q to quit" "the refusal must say how to choose"
  done
  [ "$(jq -r '.workspaces | length' "$state")" = 0 ] \
    || fail "a refused selection must create nothing"
  pass "selection: a scripted invalid choice refuses without reprompting"
}

test_scripted_selection_requires_an_explicit_choice() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case explicit-choice)
EOF
  # THE REGRESSION. An empty line and EOF must both refuse. Taking the default
  # here means `fm-launch.sh < /dev/null` silently starts a real unattended
  # session - which is exactly what happened once against a live machine.
  for input in "" $'\n'; do
    out=$(run_launch "$home" "$fb" "$state" "$execlog" "$input") && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "a non-TTY launcher must refuse an empty selection, not take the default"
    assert_contains "$out" "No selection was made" "the refusal must name the cause"
  done
  [ "$(jq -r '.tabs | length' "$state")" = 0 ] \
    || fail "an empty scripted selection must create no tab"
  grep -q '^claude ' "$execlog" 2>/dev/null \
    && fail "an empty scripted selection must never start an agent"
  pass "selection: EOF and a blank line refuse instead of launching the default"
}

test_scripted_leading_zero_selection_refuses_cleanly() {
  local home fb state execlog out rc i entries=""
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case leading-zero)
EOF
  # '08' on an 8-entry menu passes a decimal range check but reads as octal to
  # bash arithmetic; it must get the same refuse-with-guidance every other
  # invalid scripted input gets, not an arithmetic crash under set -eu.
  for i in 1 2 3 4 5 6 7 8; do
    entries="$entries{\"id\":\"e$i\",\"label\":\"Entry $i\",\"harness\":\"claude\"},"
  done
  printf '{"entries":[%s]}\n' "${entries%,}" > "$home/config/launch-presets.json"
  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'08\n') && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a scripted selection of '08' must refuse"
  assert_contains "$out" "not one of the menu choices" \
    "the refusal must carry the same guidance every invalid input gets"
  assert_not_contains "$out" "value too great" \
    "a 0-prefixed selection must never reach bash's octal arithmetic"
  [ "$(jq -r '.tabs | length' "$state")" = 0 ] || fail "a refused selection must create nothing"
  pass "selection: a 0-prefixed scripted choice refuses with guidance instead of crashing"
}

test_selecting_an_unavailable_entry_refuses() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case unavailable-selection)
EOF
  rm -f "$fb/codex"
  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'4\n') && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "selecting an unavailable entry must refuse"
  assert_contains "$out" "not installed - install codex" "the refusal must repeat the entry's own fix line"
  [ "$(jq -r '.tabs | length' "$state")" = 0 ] || fail "a refused selection must create nothing"
  pass "selection: an unavailable entry cannot be launched"
}

# --- the Herdr gate ---------------------------------------------------------

test_herdr_absent_refuses_with_one_actionable_line() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case herdr-absent)
EOF
  rm -f "$fb/herdr"
  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'1\n') && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing herdr must refuse the launch"
  assert_contains "$out" "Herdr is required and was not found." "the refusal must name the condition"
  assert_contains "$out" "https://herdr.dev" "the refusal must carry the one thing that fixes it"
  grep -q '^claude ' "$execlog" 2>/dev/null \
    && fail "there must be no silent fallback to a bare shell or a direct harness launch"
  pass "herdr gate: an absent herdr refuses, with no silent fallback"
}

test_old_herdr_protocol_refuses_and_relays_the_numbers() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case herdr-old)
EOF
  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'1\n' FM_FAKE_HERDR_PROTOCOL=3) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "an under-minimum herdr protocol must refuse the launch"
  assert_contains "$out" "protocol 3" "the refusal must relay the version owner's actual numbers"
  assert_contains "$out" "herdr update" "the refusal must carry the fix"
  [ "$(jq -r '.tabs | length' "$state")" = 0 ] || fail "a refused gate must create nothing"
  pass "herdr gate: an old protocol refuses and relays the owner's numbers"
}

# --- launch -----------------------------------------------------------------

test_launch_composes_the_verified_primary_command() {
  local home fb state execlog herdrlog out sent
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case launch-command)
EOF
  herdrlog="$home/herdr.log"
  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'1\n' FM_HERDR_LOG="$herdrlog")
  sent=$(grep 'pane send-text' "$herdrlog" | head -1)

  # The command is composed from bin/fm-launch-lib.sh, never hand-written here:
  # the ghost-text suppression prefix is the exact fragment a downstream registry
  # once dropped, so its presence is what proves the single owner was used.
  assert_contains "$sent" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" \
    "the launch must come from launch_template, ghost-text suppression included"
  assert_contains "$sent" "--dangerously-skip-permissions" "the verified primary flags must survive"
  assert_contains "$sent" "clear && " "the launch must wipe the echoed command and any shell banner"
  assert_contains "$sent" "FM_HOME=" "the pane must be pinned to this home, not the server's inherited env"
  assert_contains "$sent" "$home" "the pinned home must be the launcher's own FM_HOME"
  assert_contains "$out" "Claude" "the captain sees which entry started"
  pass "launch: the pane receives the verified primary command from the single owner"
}

test_launch_creates_exactly_one_primary_tab_in_this_home() {
  local home fb state execlog labels
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case one-tab)
EOF
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null
  labels=$(jq -r '.tabs[].label' "$state" | sort | tr '\n' ' ')
  assert_contains "$labels" "firstmate" "the launch must create this home's primary tab"
  [ "$(jq -r '[.tabs[]|select(.label=="firstmate")]|length' "$state")" = 1 ] \
    || fail "the launch must create exactly one primary tab, got: $labels"
  [ "$(jq -r '.workspaces | length' "$state")" = 1 ] \
    || fail "the launch must use this home's one workspace"
  pass "launch: exactly one primary tab in this home's workspace"
}

test_launch_records_the_choice_atomically() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case last-used)
EOF
  write_pi_auth "$home" openai-codex
  run_launch "$home" "$fb" "$state" "$execlog" $'2\n' >/dev/null
  assert_present "$home/state/.launch-last" "the launcher must remember the choice"
  assert_grep "chatgpt-sol" "$home/state/.launch-last" "the remembered choice must be the selected entry id"
  [ -z "$(find "$home/state" -name '.launch-last.tmp.*' -print -quit)" ] \
    || fail "the atomic write must leave no temp file behind"

  # A remembered choice becomes the Enter default on the next render.
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$out" "⏎ ChatGPT Sol" "the remembered entry must become the Enter default"
  assert_contains "$out" "← last" "the remembered entry must be marked as the last used"
  pass "launch: the choice is recorded atomically and becomes the next default"
}

test_stale_last_used_never_becomes_an_unlaunchable_default() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case stale-last-used)
EOF
  # Remember an entry, then take away what made it available.
  printf 'codex\n' > "$home/state/.launch-last"
  rm -f "$fb/codex"
  out=$(render_menu_out "$home" "$fb")
  assert_not_contains "$out" "⏎ Codex" "Enter must never default to an entry that cannot launch"
  assert_contains "$out" "⏎ Claude" "Enter must fall back to the first available entry"
  pass "launch: a now-unavailable remembered entry never becomes the Enter default"
}

# --- the reattach guard -----------------------------------------------------

test_a_live_primary_blocks_a_second_one() {
  local home fb state execlog out rc pane tabs_before
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case reattach)
EOF
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null
  pane=$(jq -r '.tabs[]|select(.label=="firstmate")|.pane_id' "$state")
  # Register an agent in that pane: the primary is now genuinely live.
  jq --arg p "$pane" '.agent_status[$p] = "idle"' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  tabs_before=$(jq -r '.tabs | length' "$state")

  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'1\n') && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a second scripted launch must refuse while a primary is live"
  assert_contains "$out" "already running" "the refusal must name the live session"
  [ "$(jq -r '.tabs | length' "$state")" = "$tabs_before" ] \
    || fail "a refused second launch must create no additional tab"
  [ "$(jq -r '[.tabs[]|select(.label=="firstmate")]|length' "$state")" = 1 ] \
    || fail "there must never be two primaries in one home"
  pass "reattach guard: a live primary blocks a second one in the same home"
}

test_a_dead_primary_does_not_block_a_relaunch() {
  local home fb state execlog rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case relaunch-after-death)
EOF
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null
  # No agent was ever registered in that pane, so it is a husk, not a session.
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "an agent-less husk must not block a relaunch"
  [ "$(jq -r '[.tabs[]|select(.label=="firstmate")]|length' "$state")" = 1 ] \
    || fail "a relaunch must replace the husk, not stack a second primary tab"
  pass "reattach guard: an agent-less husk is replaced, not treated as a live session"
}

test_a_launch_in_flight_blocks_a_second_launch_until_released() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case launch-lock)
EOF
  # The startup window: the first launch has created its tab and sent its
  # command, but no agent has registered in the pane yet, so the reattach
  # check alone would read it as a husk and let a second launch replace it.
  # Simulate that launcher still being in flight by holding the launch lock
  # with a live pid, the same way bin/fm-wake-lib.sh's owner records it.
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null
  mkdir -p "$home/state/.launch.lock"
  printf '%s\n' "$$" > "$home/state/.launch.lock/pid"

  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'1\n') && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a second launch must refuse while another launch holds the lock"
  assert_contains "$out" "already starting a session here" \
    "the refusal must name the in-flight launch"
  [ "$(jq -r '[.tabs[]|select(.label=="firstmate")]|length' "$state")" = 1 ] \
    || fail "the in-flight primary's tab must survive a refused second launch"

  # Released, the same agent-less tab is a husk again and relaunch must stay
  # open: the lock, not any pane state, is what tells a launch in flight apart
  # from a session that died.
  rm -rf "$home/state/.launch.lock"
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a released launch lock must not block relaunch after a crash"
  [ "$(jq -r '[.tabs[]|select(.label=="firstmate")]|length' "$state")" = 1 ] \
    || fail "the relaunch must replace the husk, not stack a second primary tab"
  pass "launch lock: an in-flight launch blocks a second one, and only while held"
}

test_reattach_check_fails_closed_when_herdr_stops_answering() {
  local home fb state execlog out rc tabs_before
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case pane-list-race)
EOF
  run_launch "$home" "$fb" "$state" "$execlog" $'1\n' >/dev/null
  tabs_before=$(jq -r '.tabs | length' "$state")
  # The narrow race: the herdr server answers the status check, then dies
  # before the pane list. The guard must refuse with the front door's
  # actionable line - not die silently under set -eu, and not fail open into
  # creating the second primary this guard exists to prevent.
  out=$(run_launch "$home" "$fb" "$state" "$execlog" $'1\n' FM_FAKE_HERDR_FAIL="pane list") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a failing pane list must refuse the launch, not proceed"
  assert_contains "$out" "could not confirm whether a session is already running" \
    "the refusal must name what herdr failed to answer"
  assert_contains "$out" "Retry, or run with --verbose" "the refusal must carry the one thing that fixes it"
  [ "$(jq -r '.tabs | length' "$state")" = "$tabs_before" ] \
    || fail "a failed reattach check must create nothing"
  pass "reattach guard: a dying pane list refuses loudly instead of silently or fail-open"
}

# --- refusals that precede the menu -----------------------------------------

test_missing_home_refuses_at_the_door() {
  local out rc
  out=$(env FM_HOME="$TMP_ROOT/nope" bash "$LAUNCH" --print-menu 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing firstmate home must refuse"
  assert_contains "$out" "No firstmate home at" "the refusal must name the path"
  assert_contains "$out" "FM_HOME" "the refusal must name the variable that fixes it"
  pass "door: a missing firstmate home refuses before anything else"
}

test_broken_presets_refuse_instead_of_guessing() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case broken-presets)
EOF
  printf 'not json at all\n' > "$home/config/launch-presets.json"
  out=$(render_menu_out "$home" "$fb") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable presets must refuse rather than silently fall back"
  assert_contains "$out" "not valid" "the refusal must name the cause"

  # Valid JSON is not enough: jq renders a missing key as an empty field, so an
  # incomplete entry would otherwise render as a blank row that cannot launch.
  printf '{"entries":[{"label":"No Harness"}]}\n' > "$home/config/launch-presets.json"
  out=$(render_menu_out "$home" "$fb") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "an entry missing its required keys must refuse"
  assert_contains "$out" "missing its id, label, or harness" "the refusal must name what is missing"
  pass "door: broken and incomplete presets refuse instead of silently using the built-in menu"
}

test_presets_beyond_one_keypress_refuse() {
  local home fb state execlog out rc i entries=""
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case too-many-presets)
EOF
  # Ten entries cannot all be reached by a single keypress, so the mapping from
  # input to entry would stop being total - and totality is what makes the TTY
  # reprompt safe rather than a guess.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    entries="$entries{\"id\":\"e$i\",\"label\":\"Entry $i\",\"harness\":\"claude\"},"
  done
  printf '{"entries":[%s]}\n' "${entries%,}" > "$home/config/launch-presets.json"
  out=$(render_menu_out "$home" "$fb") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a menu with unreachable rows must refuse"
  assert_contains "$out" "9 is the most one keypress can select" "the refusal must name the limit"
  pass "presets: a menu too large for one keypress refuses instead of stranding entries"
}

test_configured_non_herdr_backend_refuses_before_the_menu() {
  local home fb state execlog out rc
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case backend-mismatch)
EOF
  # The launcher only starts Herdr sessions. A home explicitly configured for
  # another backend would get a primary that fm-send/fm-watch/fm-spawn cannot
  # see and the reattach guard cannot find, so it must refuse at the door.
  printf 'tmux\n' > "$home/config/backend"
  out=$(render_menu_out "$home" "$fb") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a home whose config/backend selects tmux must refuse"
  assert_contains "$out" "config/backend selects tmux" "the refusal must name the configured value"
  assert_contains "$out" "herdr" "the refusal must name the one thing that fixes it"
  assert_not_contains "$out" "1-5 select" "the refusal must land before the menu is drawn"

  out=$(render_menu_out "$home" "$fb" FM_BACKEND=zellij) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "FM_BACKEND selecting a non-herdr backend must refuse"
  assert_contains "$out" "FM_BACKEND selects the zellij backend" \
    "the refusal must name the FM_BACKEND value that caused it"

  printf 'herdr\n' > "$home/config/backend"
  out=$(render_menu_out "$home" "$fb") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "config/backend=herdr must render the menu normally: $out"
  assert_contains "$out" "1-5 select" "a herdr-configured home keeps its menu"
  pass "door: an explicitly configured non-herdr backend refuses before the menu"
}

test_glob_characters_in_preset_fields_never_shift_the_record() {
  local home fb state execlog out globdir
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case glob-label)
EOF
  # A field carrying a glob character must survive the record split intact.
  # Rendered from a cwd holding files the pattern matches, an expanded label
  # would shift harness/model/effort one place left - a corrupted record that
  # still passes the required-field validation.
  cat > "$home/config/launch-presets.json" <<'JSON'
{"entries":[{"id":"glob","label":"file*","harness":"claude","model":"claude-opus-5","effort":"low"}]}
JSON
  globdir="$TMP_ROOT/glob-label/cwd"
  mkdir -p "$globdir"
  : > "$globdir/fileA"
  : > "$globdir/fileB"
  out=$(cd "$globdir" && render_menu_out "$home" "$fb")
  assert_contains "$(menu_row "$out" 'file*')" "claude-opus-5 · low" \
    "a glob character in a label must not shift the entry's harness/model/effort"
  assert_not_contains "$out" "fileA" "a preset field must never expand against the launcher's cwd"
  pass "presets: a glob character in a field parses intact from a matching cwd"
}

test_custom_presets_replace_the_builtin_menu() {
  local home fb state execlog out
  { read -r home; read -r fb; read -r state; read -r execlog; } <<EOF
$(launch_case custom-presets)
EOF
  cat > "$home/config/launch-presets.json" <<'JSON'
{"entries":[{"id":"only","label":"Only One","harness":"claude","model":"claude-opus-5","effort":"low"}]}
JSON
  out=$(render_menu_out "$home" "$fb")
  assert_contains "$out" "Only One" "a custom preset entry must appear"
  assert_contains "$out" "claude-opus-5 · low" "a pinned model and effort must be shown"
  assert_not_contains "$out" "ChatGPT Sol" "custom presets replace the built-in menu"
  assert_contains "$out" "1-1 select" "the footer must match the custom entry count"
  pass "presets: a custom file replaces the built-in five"
}

# --- run --------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || { pass "fm-launch: skipped (jq is required by the herdr fake)"; exit 0; }

test_menu_shows_all_five_entries_always
test_menu_probes_rather_than_declares_availability
test_menu_marks_missing_native_binaries_unavailable
test_menu_reports_the_two_launch_template_refusals_differently
test_pi_signed_shares_the_provider_probe_but_not_the_executable
test_menu_states_the_no_permission_prompt_posture
test_menu_executes_nothing
test_menu_creates_nothing
test_print_menu_is_fast
test_scripted_selection_refuses_rather_than_reprompting
test_scripted_selection_requires_an_explicit_choice
test_scripted_leading_zero_selection_refuses_cleanly
test_selecting_an_unavailable_entry_refuses
test_herdr_absent_refuses_with_one_actionable_line
test_old_herdr_protocol_refuses_and_relays_the_numbers
test_launch_composes_the_verified_primary_command
test_launch_creates_exactly_one_primary_tab_in_this_home
test_launch_records_the_choice_atomically
test_stale_last_used_never_becomes_an_unlaunchable_default
test_a_live_primary_blocks_a_second_one
test_a_dead_primary_does_not_block_a_relaunch
test_a_launch_in_flight_blocks_a_second_launch_until_released
test_reattach_check_fails_closed_when_herdr_stops_answering
test_missing_home_refuses_at_the_door
test_broken_presets_refuse_instead_of_guessing
test_presets_beyond_one_keypress_refuse
test_configured_non_herdr_backend_refuses_before_the_menu
test_glob_characters_in_preset_fields_never_shift_the_record
test_custom_presets_replace_the_builtin_menu
