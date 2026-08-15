#!/usr/bin/env bash
# Behavior tests for the verified Cline CLI crewmate adapter (cline 3.0.55).
#
# Every literal in this file is an EMPIRICAL capture from a live `cline -i --tui`
# pane driven through tmux (see docs/verification/cline-adapter.md):
#   - busy footer:      " ⠇ Thinking... (esc to cancel)"   (interrupt = esc)
#   - idle placeholders: "What can I do for you?" (first ready), "Ask anything..."
#   - agent glyph:      ❯ (U+276F, already a verified empty-composer glyph)
#   - launch:           cline -i --tui --auto-approve true [--model M] [--thinking E] "<brief>"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"   # brings fm-composer-lib.sh + busy defaults/matcher
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# The tmux backend adapter owns the process-name classification the control
# plane depends on; it needs its lib dir declared before sourcing.
FM_BACKEND_LIB_DIR="$ROOT/bin"
# shellcheck source=bin/backends/tmux.sh
. "$ROOT/bin/backends/tmux.sh"

TMP_ROOT=$(fm_test_tmproot cline-harness)

classify() { fm_composer_classify_content "$@"; }

# Verified idle placeholders as one anchored alternation (what the backend IDLE_RE
# must cover so an empty cline composer is not misread as pending).
CLINE_IDLE_RE='^(What can I do for you\?|Ask anything\.\.\.)$'

# --- launch template (mechanics half) ---------------------------------------

# --- spawn scaffolding ------------------------------------------------------
#
# The launch shape is asserted from the command fm-spawn actually hands the
# backend, captured off the fake tmux's `send-keys -l`, rather than from the
# template line in the source. A source-byte assertion would pass on a template
# that no longer reaches a pane, which is precisely the failure these cases
# exist to catch.

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" cline gh-axi gh
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> [operator-settings-json]: a throwaway home plus a fake
# cline data dir. When the operator settings argument is given it is written as
# cline's own global-settings.json, which is what the spawn must carry over
# without editing.
make_spawn_case() {
  local name=$1 operator=${2-} case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cline-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/clinedata/settings" "$case_dir/clinedata/sessions"
  printf 'brief\nDelivery contract: mode=no-mistakes yolo=off\n' > "$home/data/$id/brief.md"
  [ -z "$operator" ] || printf '%s\n' "$operator" > "$case_dir/clinedata/settings/global-settings.json"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_cline_spawn() {  # <case-dir> <home> <proj> <wt> <fakebin> <id> [extra args...]
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    CLINE_DATA_DIR="$case_dir/clinedata" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cline "$@" 2>&1
}

# Write a cline session fixture: <sessions-root> <id> <workspace> <status>
# [last-message-role]. Mirrors the real on-disk shape - a per-session directory
# holding <id>.json and, when a role is given, <id>.messages.json.
write_session() {
  local root=$1 sid=$2 workspace=$3 status=$4 role=${5-} dir
  dir="$root/$sid"
  mkdir -p "$dir"
  cat > "$dir/$sid.json" <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "pid": 71393,
  "exit_code": null,
  "status": "$status",
  "interactive": true,
  "cwd": "$workspace",
  "workspace_root": "$workspace",
  "messages_path": "$dir/$sid.messages.json"
}
EOF
  [ -z "$role" ] || cat > "$dir/$sid.messages.json" <<EOF
{
  "version": 1,
  "sessionId": "$sid",
  "messages": [
    {"id": "m1", "role": "user", "content": [{"type": "text", "text": "go"}]},
    {"id": "m2", "role": "$role", "content": [{"type": "text", "text": "ok"}]}
  ]
}
EOF
}

# --- gap 1: a firstmate-spawned crewmate starts in ACT mode -----------------

test_spawn_forces_act_mode_without_touching_operator_config() {
  local rec case_dir home proj wt fakebin id out status settings before after
  rec=$(make_spawn_case actmode '{"autoUpdateEnabled": true, "telemetryOptOut": true, "planActMode": "plan"}')
  IFS='|' read -r case_dir home proj wt fakebin id <<<"$rec"
  before=$(cksum < "$case_dir/clinedata/settings/global-settings.json")
  out=$(run_cline_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off) && status=0 || status=$?
  expect_code 0 "$status" "cline spawn should succeed: $out"

  settings="$home/state/$id.cline-settings.json"
  assert_present "$settings" "spawn did not write the firstmate-owned cline settings file"
  # The launch must actually carry the redirect, or the crewmate reads the
  # operator's plan mode no matter what the file says.
  assert_grep "CLINE_GLOBAL_SETTINGS_PATH=" "$home/launch.log" \
    "cline launch does not redirect CLINE_GLOBAL_SETTINGS_PATH"
  assert_grep "$id.cline-settings.json" "$home/launch.log" \
    "cline launch does not point at this task's own settings file"
  [ "$(LC_ALL=C jq -r '.planActMode' "$settings")" = act ] \
    || fail "firstmate-owned cline settings do not force act mode"
  # The operator's other choices ride along; silently re-opting them into
  # telemetry would be a real regression, not a cosmetic one.
  [ "$(LC_ALL=C jq -r '.telemetryOptOut' "$settings")" = true ] \
    || fail "firstmate-owned cline settings dropped the operator's telemetry choice"

  after=$(cksum < "$case_dir/clinedata/settings/global-settings.json")
  [ "$before" = "$after" ] \
    || fail "spawn rewrote the operator's own cline global settings"
  pass "fm-spawn: cline starts in act mode via a firstmate-owned settings redirect"
}

test_spawn_forces_act_mode_with_no_operator_settings() {
  local rec case_dir home proj wt fakebin id out status settings
  rec=$(make_spawn_case actmode-fresh)
  IFS='|' read -r case_dir home proj wt fakebin id <<<"$rec"
  out=$(run_cline_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off) && status=0 || status=$?
  expect_code 0 "$status" "cline spawn should succeed with no operator settings: $out"
  settings="$home/state/$id.cline-settings.json"
  [ "$(LC_ALL=C jq -r '.planActMode' "$settings")" = act ] \
    || fail "with nothing to carry over, the minimal settings file must still force act"
  pass "fm-spawn: cline forces act mode when the operator has no settings file"
}

test_launch_keeps_verified_argv_shape() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case argv)
  IFS='|' read -r case_dir home proj wt fakebin id <<<"$rec"
  out=$(run_cline_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off) && status=0 || status=$?
  expect_code 0 "$status" "cline spawn should succeed: $out"
  assert_grep "cline -i --tui --auto-approve true" "$home/launch.log" \
    "cline launch lost its verified interactive/autonomy flags"
  assert_grep "encode launch-brief" "$home/launch.log" \
    "cline launch no longer seeds the brief as a positional prompt"
  pass "fm-spawn: cline keeps its verified interactive, autonomy, and brief-seed shape"
}

# --- gap 3: the pane is bound to cline's own session record -----------------

test_spawn_writes_session_binding_excluding_prior_sessions() {
  local rec case_dir home proj wt fakebin id out status sidecar
  rec=$(make_spawn_case binding)
  IFS='|' read -r case_dir home proj wt fakebin id <<<"$rec"
  # One session already exists for this workspace (a previous incarnation) and
  # one belongs to a different workspace entirely.
  write_session "$case_dir/clinedata/sessions" 1000_prior "$wt" completed assistant
  write_session "$case_dir/clinedata/sessions" 1000_other "$case_dir/elsewhere" running
  out=$(run_cline_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off) && status=0 || status=$?
  expect_code 0 "$status" "cline spawn should succeed: $out"
  sidecar="$home/state/$id.cline-session"
  assert_present "$sidecar" "spawn did not write the cline session binding"
  assert_grep "sessions_root=$case_dir/clinedata/sessions" "$sidecar" "binding lost the sessions root"
  assert_grep "workspace_root=$wt" "$sidecar" "binding lost the workspace root"
  assert_grep "prior_session=" "$sidecar" "binding did not record any pre-existing session"
  assert_grep "1000_prior/1000_prior.json" "$sidecar" \
    "binding did not record the pre-existing session for this workspace"
  assert_no_grep "1000_other" "$sidecar" \
    "binding recorded a session belonging to a different workspace"
  pass "fm-spawn: cline session binding pins the root, workspace, and prior sessions"
}

test_existing_launch_templates_untouched() {
  grep -Fq "claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "claude launch template changed"
  grep -Fq "grok --always-approve __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "grok launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_cline_is_a_known_bare_adapter_name() {
  # cline must be accepted as a bare adapter name, not routed to the raw-launch hatch.
  # (Robust to later adapters appended after cline, e.g. |cline|cursor-agent).)
  grep -Fq "|kimi|cline" "$SPAWN" \
    || fail "fm-spawn: cline not added to a known-harness allowlist"
  pass "fm-spawn: cline is recognized as a known bare adapter name"
}

test_cline_model_and_effort_flags() {
  # cline takes --model (long form of -m) and maps effort to --thinking (no max).
  # (Robust to later adapters appended after cline in the --model allowlist.)
  grep -Fq "|kimi|cline" "$SPAWN" \
    || fail "fm-spawn: cline not in the --model allowlist"
  grep -Fq "'--thinking %s '" "$SPAWN" \
    || fail "fm-spawn: cline effort->--thinking mapping missing"
  pass "fm-spawn: cline gets --model and effort->--thinking (low|medium|high|xhigh)"
}

# --- detection --------------------------------------------------------------

test_cline_detection_wired() {
  grep -Fq '*cline*) echo cline; return ;;' "$HARNESS" \
    || fail "fm-harness: cline ancestry case missing"
  pass "fm-harness: cline is detected by process ancestry"
}

# --- busy signature (knowledge half) ----------------------------------------

test_cline_busy_default_defined() {
  [ -n "${FM_DELIVERY_CLINE_BUSY_REGEX_DEFAULT:-}" ] \
    || fail "FM_DELIVERY_CLINE_BUSY_REGEX_DEFAULT is not defined"
  pass "fm-composer-lib: FM_DELIVERY_CLINE_BUSY_REGEX_DEFAULT is defined"
}

test_cline_busy_line_matches() {
  printf '%s' ' ⠇ Thinking... (esc to cancel)' | fm_busy_lines_match cline \
    || fail "cline busy footer 'esc to cancel' did not classify busy"
  pass "fm_busy_lines_match: cline 'esc to cancel' footer reads busy"
}

test_cline_idle_line_not_busy() {
  if printf '%s' '❯ Ask anything...' | fm_busy_lines_match cline; then
    fail "cline idle composer must not read busy"
  fi
  pass "fm_busy_lines_match: cline idle composer does not read busy"
}

test_cline_does_not_borrow_signatures() {
  # A cline pane showing claude's 'esc to interrupt' must NOT be cline-busy:
  # cline's own footer is 'esc to cancel'. Guards against cross-harness borrow.
  if printf '%s' 'esc to interrupt' | fm_busy_lines_match cline; then
    fail "cline busy regex borrowed another harness's 'esc to interrupt'"
  fi
  pass "fm_busy_lines_match: cline uses only its own verified footer"
}

# --- composer idle classification -------------------------------------------

test_cline_idle_placeholders_read_empty() {
  local p out
  # cline's placeholder is bold/truecolor (NOT dim), so the shared ghost stripper
  # keeps it; the classifier recognizes it as idle through the idle-RE on a PLAIN
  # (styled=0) bordered capture at a proven placeholder position (position=1) -
  # the same plain-box placeholder contract fm-composer-lib.test.sh pins in
  # test_idle_placeholder_is_empty. The full 7-arg form is how the tmux/backend
  # classifiers actually call in, so exercise that path here.
  for p in 'What can I do for you?' 'Ask anything...'; do
    out=$(classify 1 "$p" "$CLINE_IDLE_RE" insensitive "$p" 1 0)
    [ "$out" = empty ] \
      || fail "cline idle placeholder '$p' must read empty (given idle-RE), got '$out'"
  done
  # After a leading agent glyph, still empty.
  out=$(classify 1 "❯ Ask anything..." "$CLINE_IDLE_RE" insensitive "❯ Ask anything..." 1 0)
  [ "$out" = empty ] || fail "'❯ Ask anything...' must read empty, got '$out'"
  pass "fm_composer_classify_content: cline idle placeholders read empty"
}

test_cline_real_input_reads_pending() {
  local out
  out=$(classify 1 "Fix the null-pointer in the parser" "$CLINE_IDLE_RE" insensitive)
  [ "$out" = pending ] \
    || fail "real cline composer input must read pending, got '$out'"
  pass "fm_composer_classify_content: real cline input still reads pending"
}

# --- shared idle default covers cline (tmux + every backend) ----------------

test_shared_idle_default_covers_cline() {
  local p b bad=0 up
  for p in 'What can I do for you?' 'Ask anything...'; do
    printf '%s' "$p" | grep -qE "$FM_COMPOSER_IDLE_RE_DEFAULT" \
      || fail "shared FM_COMPOSER_IDLE_RE_DEFAULT does not match cline placeholder '$p'"
  done
  for b in herdr cmux orca; do
    up=$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')
    grep -Eq "FM_BACKEND_${up}_IDLE_RE=.*FM_COMPOSER_IDLE_RE_DEFAULT" \
      "$ROOT/bin/backends/$b.sh" || { echo "  backend $b IDLE_RE does not use the shared default"; bad=1; }
  done
  [ "$bad" -eq 0 ] || fail "one or more backend IDLE_RE defaults do not use the shared idle default"
  pass "shared idle default covers cline placeholders and backs herdr/cmux/orca"
}

# --- gap 3: the structural busy fold ----------------------------------------
#
# Two independent signals back this source: cline's own `status` lifecycle field
# and the last role in its turn log. These cases drive them APART on purpose,
# because the whole point of the second signal is the one state the first cannot
# express - `status: idle` covering both a finished turn and a turn that was
# accepted and never ran.

bind_task() {  # <state-dir> <id> <sessions-root> <workspace>
  printf 'sessions_root=%s\nworkspace_root=%s\n' "$3" "$4" > "$1/$2.cline-session"
}

fold() {  # <sessions-root> <session-id>
  fm_busy_cline_session_state "$1/$2/$2.json"
}

test_busy_fold_reads_the_status_signal() {
  local root="$TMP_ROOT/fold/sessions"
  mkdir -p "$root"
  write_session "$root" s_running /w running assistant
  write_session "$root" s_completed /w completed assistant
  write_session "$root" s_failed /w failed assistant
  [ "$(fold "$root" s_running)" = busy ] || fail "status=running must fold busy"
  [ "$(fold "$root" s_completed)" = settled ] || fail "status=completed must fold settled"
  [ "$(fold "$root" s_failed)" = settled ] || fail "status=failed must fold settled"
  pass "fm_busy_cline_session_state: the status signal drives busy and settled"
}

test_busy_fold_separates_a_finished_turn_from_an_unprocessed_one() {
  local root="$TMP_ROOT/fold2/sessions" a b
  mkdir -p "$root"
  # Identical status; only the turn log differs. This IS the divergence: if the
  # second signal were dropped, both would collapse to one verdict and the wedge
  # would be invisible again.
  write_session "$root" s_done /w idle assistant
  write_session "$root" s_stalled /w idle user
  a=$(fold "$root" s_done)
  b=$(fold "$root" s_stalled)
  [ "$a" = settled ] || fail "idle + assistant close must fold settled, got '$a'"
  [ "$b" = stalled ] || fail "idle + trailing user message must fold stalled, got '$b'"
  [ "$a" != "$b" ] \
    || fail "the two signals did not diverge: status alone cannot separate these"
  pass "fm_busy_cline_session_state: a queued-but-unprocessed turn is distinguishable"
}

test_busy_fold_never_invents_idle_when_a_signal_is_missing() {
  local root="$TMP_ROOT/fold3/sessions"
  mkdir -p "$root"
  # Losing the second signal must not promote an ambiguous idle into settled.
  write_session "$root" s_nolog /w idle
  rm -f "$root/s_nolog/s_nolog.messages.json"
  [ "$(fold "$root" s_nolog)" = none ] \
    || fail "idle with no readable turn log must fold none, never settled"
  # A record that is not JSON at all resolves to nothing rather than a verdict.
  mkdir -p "$root/s_bad"
  printf 'not json\n' > "$root/s_bad/s_bad.json"
  [ "$(fold "$root" s_bad)" = none ] || fail "an unparseable record must fold none"
  pass "fm_busy_cline_session_state: a missing or unreadable signal never reads settled"
}

test_classify_reports_cline_verdicts_with_their_source() {
  local root="$TMP_ROOT/classify/sessions" state="$TMP_ROOT/classify/state"
  mkdir -p "$root" "$state"
  write_session "$root" c_busy /wt running assistant
  bind_task "$state" busy-task "$root" /wt
  [ "$(fm_busy_classify tmux t cline busy-task "$state")" = "busy cline-session" ] \
    || fail "a running cline session must classify 'busy cline-session'"

  rm -rf "$root"; mkdir -p "$root"
  write_session "$root" c_idle /wt idle assistant
  bind_task "$state" idle-task "$root" /wt
  [ "$(fm_busy_classify tmux t cline idle-task "$state")" = "idle cline-session" ] \
    || fail "a finished cline turn must classify 'idle cline-session'"

  rm -rf "$root"; mkdir -p "$root"
  write_session "$root" c_stalled /wt idle user
  bind_task "$state" stalled-task "$root" /wt
  [ "$(fm_busy_classify tmux t cline stalled-task "$state")" = "idle cline-session-stalled" ] \
    || fail "an unprocessed cline turn must name itself in the source token"
  pass "fm_busy_classify: cline verdicts carry a source that names what was read"
}

test_classify_is_unknown_when_the_binding_cannot_be_resolved() {
  local root="$TMP_ROOT/unresolved/sessions" state="$TMP_ROOT/unresolved/state"
  mkdir -p "$root" "$state"
  # No sidecar at all.
  [ "$(fm_busy_classify tmux t cline no-sidecar "$state")" = "unknown cline-session" ] \
    || fail "a cline task with no binding must be unknown, never idle"
  # Two candidate sessions for the same workspace: the pane cannot be told apart.
  write_session "$root" a1 /wt idle assistant
  write_session "$root" a2 /wt running assistant
  bind_task "$state" ambiguous "$root" /wt
  [ "$(fm_busy_classify tmux t cline ambiguous "$state")" = "unknown cline-session" ] \
    || fail "an ambiguous cline binding must be unknown, never a guessed verdict"
  # A workspace with no session of its own resolves to nothing.
  bind_task "$state" nomatch "$root" /other
  [ "$(fm_busy_classify tmux t cline nomatch "$state")" = "unknown cline-session" ] \
    || fail "a cline binding matching no session must be unknown"
  pass "fm_busy_classify: an unresolvable cline binding is unknown, never idle"
}

test_prior_session_is_excluded_from_the_binding() {
  local root="$TMP_ROOT/prior/sessions" state="$TMP_ROOT/prior/state"
  mkdir -p "$root" "$state"
  write_session "$root" p_old /wt idle user
  write_session "$root" p_new /wt running assistant
  {
    printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" /wt
    printf 'prior_session=%s\n' "$root/p_old/p_old.json"
  } > "$state/relaunched.cline-session"
  # Without the exclusion this is ambiguous; with it the pane folds its OWN turn.
  [ "$(fm_busy_classify tmux t cline relaunched "$state")" = "busy cline-session" ] \
    || fail "a relaunched cline task must fold its own session, not its predecessor's"
  pass "fm_busy_classify: a relaunched cline task ignores its predecessor's session"
}

test_cline_source_cannot_classify_another_adapter() {
  local root="$TMP_ROOT/isolation/sessions" state="$TMP_ROOT/isolation/state"
  mkdir -p "$root" "$state"
  write_session "$root" x1 /wt running assistant
  bind_task "$state" crossed "$root" /wt
  # The same binding under a different recorded harness must not produce a cline
  # verdict; one adapter's source can never speak for another.
  case "$(fm_busy_classify tmux t muse crossed "$state")" in
    *cline-session*) fail "the cline source classified a muse task" ;;
  esac
  pass "fm_busy_classify: the cline source never classifies another adapter"
}

# --- gap 2: the pane's agent must be attributable, not just tabled ----------
#
# Registering control mechanics is necessary but not sufficient. Every lifecycle
# verb refuses unless the backend can PROVE an agent is running, and cline runs
# as a bundled Node script whose reported command name is a bare `node`. Its
# identity comes from its install path instead, exactly like cursor-agent's.
# Without that, fm-control refuses a live cline worker a second time - for an
# unattributable endpoint rather than for unverified mechanics.

test_cline_install_path_classifies_as_an_agent() {
  local real=/Users/x/.local/share/fnm/node-versions/v22/installation/lib/node_modules/cline/bin/.cline
  [ "$(fm_backend_tmux_classify_process_name "$real")" = agent ] \
    || fail "cline's real install path must classify as an agent, or its pane reads ambiguous"
  # argv[0] carries it on the platforms where ps reports argv rather than comm.
  [ "$(fm_backend_tmux_classify_process_name '' "$real")" = agent ] \
    || fail "cline's install path must classify as an agent through argv[0] too"
  pass "fm-backend tmux: a real cline install path classifies as a live agent"
}

test_an_unrelated_node_process_is_still_not_an_agent() {
  # The match is an exact `cline` path COMPONENT, never a substring, so a
  # stranger's node pane stays unattributed rather than being claimed. Callers
  # fold `other` into ambiguous, never into dead, so this is what stops an
  # unrelated pane from being reported as agent-free.
  local h
  for h in /usr/local/bin/node /Users/x/projects/clinent/bin/server.js /opt/homebrew/bin/declined; do
    [ "$(fm_backend_tmux_classify_process_name "$h")" != agent ] \
      || fail "'$h' must not classify as a cline agent"
  done
  pass "fm-backend tmux: an unrelated node or cline-like path is never claimed as an agent"
}

# --- gap 2: the executable control plane ------------------------------------

test_control_plane_knows_cline() {
  fm_control_harness_supported cline || fail "fm-control refuses cline as unverified"
  [ "$(fm_control_harness_family cline)" = cline ] || fail "cline family not resolved"
  [ "$(fm_control_harness_family 'cline-3.0.55')" = cline ] \
    || fail "a recorded cline command basename must resolve to the cline family"
  pass "fm-control-lib: cline has registered control mechanics"
}

test_control_plane_uses_clines_own_keys() {
  # cline is the exact inverse of grok: Escape cancels the turn, Ctrl+C exits.
  # Borrowing grok's interrupt key here would stop the agent instead of its turn.
  [ "$(fm_control_interrupt_key cline)" = Escape ] \
    || fail "cline must interrupt on Escape"
  [ "$(fm_control_interrupt_key cline)" != "$(fm_control_interrupt_key grok)" ] \
    || fail "cline borrowed grok's interrupt key; Ctrl+C EXITS cline"
  [ "$(fm_control_interrupt_repeat cline)" = 1 ] || fail "cline interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key cline)" ] \
    || fail "cline is not recorded as needing a composer clear key"
  [ "$(fm_control_interrupt_ack_source cline)" = none ] \
    || fail "cline must claim no cancellation acknowledgement it cannot observe"
  pass "fm-control-lib: cline interrupts on its own verified key, not a borrowed one"
}

test_control_plane_exits_cline_by_key_not_command() {
  [ -z "$(fm_control_exit_command cline)" ] \
    || fail "cline has no composer exit command; recording one would send it as chat"
  [ "$(fm_control_exit_key cline)" = C-c ] || fail "cline must exit on Ctrl+C"
  # Every other verified adapter keeps a command and no key, so the two tables
  # stay mutually exclusive rather than drifting into an overloaded string.
  local h
  for h in claude codex opencode pi pi-signed grok kimi cursor muse; do
    [ -n "$(fm_control_exit_command "$h")" ] || fail "$h lost its exit command"
    [ -z "$(fm_control_exit_key "$h")" ] || fail "$h gained an exit key it does not use"
  done
  pass "fm-control-lib: cline exits by key while every other adapter exits by command"
}

test_control_plane_refuses_a_cline_secondmate() {
  fm_control_harness_supports_kind cline ship || fail "cline must run ship tasks"
  fm_control_harness_supports_kind cline scout || fail "cline must run scout tasks"
  if fm_control_harness_supports_kind cline secondmate; then
    fail "cline is crewmate/scout only; a secondmate must stay refused"
  fi
  pass "fm-control-lib: cline runs crew and scout work and refuses a secondmate"
}

test_control_plane_retires_cline_wiring_on_relaunch() {
  local paths
  paths=$(fm_control_harness_wiring_paths cline /wt /state task1)
  printf '%s' "$paths" | grep -Fq '/state/task1.cline-session' \
    || fail "a cline relaunch would leave a stale session binding behind"
  printf '%s' "$paths" | grep -Fq '/state/task1.cline-settings.json' \
    || fail "a cline relaunch would leave a stale act-mode settings file behind"
  # Only firstmate-owned state, never cline's own managed config.
  printf '%s' "$paths" | grep -Fq '.cline/' \
    && fail "cline wiring paths must never name the operator's own cline config"
  pass "fm-control-lib: a cline relaunch retires only firstmate-owned wiring"
}

test_unverified_adapter_is_still_refused() {
  # The fix for gap 2 was to supply verified facts, never to loosen the refusal.
  if fm_control_harness_supported definitely-not-a-harness; then
    fail "the control plane stopped refusing unverified adapters"
  fi
  fm_control_harness_family definitely-not-a-harness >/dev/null 2>&1 \
    && fail "an unknown recorded harness must not resolve to a family"
  pass "fm-control-lib: an unverified adapter is still refused"
}

# --- plan-mode composer shape -----------------------------------------------

test_plan_mode_placeholder_reads_empty() {
  local out
  # firstmate forces act mode, but an operator's own plan-mode pane must still
  # read as an EMPTY composer: misreading it as pending input would make
  # away-mode supervision refuse to deliver into it.
  printf '%s' 'Plan something...' | grep -qE "$FM_COMPOSER_IDLE_RE_DEFAULT" \
    || fail "shared idle default does not cover cline's plan-mode placeholder"
  out=$(classify 1 '❯ Plan something...' "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive '❯ Plan something...' 1 0)
  [ "$out" = empty ] || fail "cline's plan-mode placeholder must read empty, got '$out'"
  pass "fm-composer-lib: cline's plan-mode placeholder reads empty"
}

# --- run --------------------------------------------------------------------
test_spawn_forces_act_mode_without_touching_operator_config
test_spawn_forces_act_mode_with_no_operator_settings
test_launch_keeps_verified_argv_shape
test_spawn_writes_session_binding_excluding_prior_sessions
test_busy_fold_reads_the_status_signal
test_busy_fold_separates_a_finished_turn_from_an_unprocessed_one
test_busy_fold_never_invents_idle_when_a_signal_is_missing
test_classify_reports_cline_verdicts_with_their_source
test_classify_is_unknown_when_the_binding_cannot_be_resolved
test_prior_session_is_excluded_from_the_binding
test_cline_source_cannot_classify_another_adapter
test_cline_install_path_classifies_as_an_agent
test_an_unrelated_node_process_is_still_not_an_agent
test_control_plane_knows_cline
test_control_plane_uses_clines_own_keys
test_control_plane_exits_cline_by_key_not_command
test_control_plane_refuses_a_cline_secondmate
test_control_plane_retires_cline_wiring_on_relaunch
test_unverified_adapter_is_still_refused
test_plan_mode_placeholder_reads_empty
test_existing_launch_templates_untouched
test_cline_is_a_known_bare_adapter_name
test_cline_model_and_effort_flags
test_cline_detection_wired
test_cline_busy_default_defined
test_cline_busy_line_matches
test_cline_idle_line_not_busy
test_cline_does_not_borrow_signatures
test_cline_idle_placeholders_read_empty
test_cline_real_input_reads_pending
test_shared_idle_default_covers_cline
echo "ALL PASS: fm-cline-harness"
