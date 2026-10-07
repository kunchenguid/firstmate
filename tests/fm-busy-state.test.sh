#!/usr/bin/env bash
# Behavior tests for the semantic busy-state contract (bin/fm-busy-lib.sh and
# its only writer bin/fm-busy-event.sh).
#
# Covers the captain-approved redesign invariants: busy/idle/unknown/dead with
# explicit source attribution; missing, malformed, stale (gen-mismatch), and
# untrusted (source-mismatch) semantic data classify unknown - never idle;
# adapter isolation (one adapter's writer or Grok's regex can never classify
# another adapter); endpoint death is the only process-level override and
# yields dead, never busy; converted adapters never classify from rendered
# footer text. All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-state)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- writer: arm and apply ---------------------------------------------------

test_arm_seeds_busy_spawn() {
  local state gen out
  state=$(new_state_dir arm-seed)
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ -f "$state/t1.busy-gen" ] || fail "arm did not write the gen sidecar"
  [ "$(cat "$state/t1.busy-gen")" = "$gen" ] || fail "sidecar gen does not match printed gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed should classify 'busy fm-spawn', got '$out'"
  pass "arm mints a gen sidecar and seeds busy fm-spawn at seq=1"
}

test_apply_advances_seq_and_source() {
  local state gen out seq
  state=$(new_state_dir apply-seq)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply idle failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "expected 'idle claude-hook', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "apply busy failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy claude-hook" ] || fail "expected 'busy claude-hook', got '$out'"
  seq=$(fm_busy_record_read "$state" t1 | awk '{print $4}')
  [ "$seq" = 3 ] || fail "expected seq 3 after seed + two applies, got '$seq'"
  pass "apply advances seq under the armed gen and attributes the writing source"
}

test_apply_current_gen_reset() {
  local state out
  state=$(new_state_dir apply-current)
  "$EV" arm "$state" t1 >/dev/null
  "$EV" apply "$state" t1 idle --current-gen --source fm-interrupt --event interrupt \
    || fail "apply --current-gen failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle fm-interrupt" ] || fail "expected 'idle fm-interrupt', got '$out'"
  "$EV" apply "$state" t1 unknown --current-gen --source fm-recovery --event relaunch \
    || fail "apply unknown failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown fm-recovery" ] || fail "expected 'unknown fm-recovery', got '$out'"
  pass "firstmate-owned interrupt and recovery events bind to the current gen"
}

test_apply_unarmed_refused() {
  local state
  state=$(new_state_dir apply-unarmed)
  if "$EV" apply "$state" t1 busy --gen g1.2.3 --source claude-hook --event x 2>/dev/null; then
    fail "apply against an unarmed task must be refused"
  fi
  [ ! -f "$state/t1.busy-state" ] || fail "refused apply must not write a record"
  pass "apply is refused for a task whose busy contract was never armed"
}

test_retire_serializes_and_rejects_stale_gen() {
  local state old_gen new_gen out retire_pid i=0
  state=$(new_state_dir retire)
  old_gen=$("$EV" arm "$state" t1)
  mkdir "$state/t1.busy-state.lock"
  "$EV" retire "$state" t1 --gen "$old_gen" >/dev/null 2>&1 &
  retire_pid=$!
  while [ "$i" -lt 20 ] && ! kill -0 "$retire_pid" 2>/dev/null; do
    i=$((i + 1))
  done
  [ -e "$state/t1.busy-state" ] || fail "retire bypassed the writer lock"
  rmdir "$state/t1.busy-state.lock"
  wait "$retire_pid" || fail "retire failed after acquiring the writer lock"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"

  new_gen=$("$EV" arm "$state" t1)
  if "$EV" retire "$state" t1 --gen "$old_gen" 2>/dev/null; then
    fail "retire accepted a superseded incarnation"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale retirement changed the new incarnation, got '$out'"
  [ "$(cat "$state/t1.busy-gen")" = "$new_gen" ] || fail "stale retirement changed the new gen"
  pass "retire waits for the writer lock and cannot remove a new incarnation"
}

# Regression for issue #2625: the writer lock's stale-lock branch resolved the
# lock's mtime with `stat -f %m ... || stat -c %Y ...`. On GNU coreutils `-f` is
# *filesystem* stat, so it consumes the format string as a path, complains on
# stderr, prints "  File: ..." on stdout, and still exits 0 - the GNU form in the
# fallback never ran. The following `$((now - mtime))` then evaluated the word
# `File`, which under `set -u` aborted the writer with "File: unbound variable".
# fm-teardown.sh died there after returning the worktree, leaving state/<id>.meta
# and friends behind to generate stale wakes forever, and every re-run died
# identically because the abandoned lock directory was never broken.
#
# The stat and uname stubs make this deterministic on any host: the writer must
# take the Linux path and still break a provably stale lock.
test_stale_lock_broken_under_gnu_stat() {
  local state gen fakebin real_uname out status
  state=$(new_state_dir gnu-stat-lock)
  gen=$("$EV" arm "$state" t1)
  fakebin=$(fm_fakebin "$TMP_ROOT/gnu-stat-lock")
  real_uname=$(command -v uname)

  # GNU coreutils semantics, self-contained so no real stat is consulted.
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
  printf '%s\n' 1000000000   # long-abandoned lock
  exit 0
fi
if [ "${1:-}" = -f ]; then
  echo "stat: cannot read file system information for '$2': No such file or directory" >&2
  shift 2
  printf '  File: "%s"\n' "${1:-}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/stat"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
if [ \$# -eq 0 ]; then printf 'Linux\n'; exit 0; fi
exec "$real_uname" "\$@"
SH
  chmod +x "$fakebin/uname"

  mkdir "$state/t1.busy-state.lock"
  out=$(PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --gen "$gen" 2>&1) && status=0 || status=$?
  case "$out" in
    *'unbound variable'*) fail "the writer still dies on GNU stat output: $out" ;;
  esac
  [ "$status" = 0 ] || fail "retire did not break a provably stale writer lock: $out"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"
  [ ! -e "$state/t1.busy-state.lock" ] || fail "retire left the stale lock behind"

  # Teardown must be able to run again over the same task without failing.
  PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --current-gen \
    || fail "a repeated retire over already-cleaned state was not idempotent"
  pass "the writer breaks a stale lock instead of dying on GNU stat output"
}

test_retire_missing_sidecar_is_idempotent() {
  local state gen
  state=$(new_state_dir retire-missing)
  gen=$("$EV" arm "$state" t1)
  rm -f "$state/t1.busy-gen"

  "$EV" retire "$state" t1 --gen "$gen" || fail "exact-gen retire rejected a missing sidecar"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left an orphan record behind"
  "$EV" retire "$state" t1 --gen "$gen" || fail "repeated exact-gen retire was not idempotent"
  "$EV" retire "$state" t1 --current-gen || fail "current-gen retire was not idempotent"

  printf 'malformed gen\n' > "$state/t1.busy-gen"
  printf 'orphan\n' > "$state/t1.busy-state"
  if "$EV" retire "$state" t1 --gen "$gen" 2>/dev/null; then
    fail "retire accepted a malformed existing sidecar"
  fi
  [ -e "$state/t1.busy-state" ] || fail "retire removed the record for a malformed existing sidecar"
  pass "retire treats only an absent sidecar as already retired"
}

# --- stale event rejection ----------------------------------------------------

test_stale_gen_event_rejected() {
  local state old_gen new_gen out
  state=$(new_state_dir stale-event)
  old_gen=$("$EV" arm "$state" t1)
  new_gen=$("$EV" arm "$state" t1)
  [ "$old_gen" != "$new_gen" ] || fail "re-arm must mint a fresh gen"
  if "$EV" apply "$state" t1 idle --gen "$old_gen" --source claude-hook --event stop 2>/dev/null; then
    fail "an event carrying a stale gen must be rejected"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale event must not change the record, got '$out'"
  pass "a late event from a previous incarnation is rejected, record unchanged"
}

test_stale_gen_record_unknown() {
  local state gen out
  state=$(new_state_dir stale-record)
  gen=$("$EV" arm "$state" t1)
  # Simulate a record left behind by a superseded incarnation.
  printf 'g-superseded.1.1\n' > "$state/t1.busy-gen.new"
  mv "$state/t1.busy-gen.new" "$state/t1.busy-gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown gen-mismatch" ] || fail "stale record must classify 'unknown gen-mismatch', got '$out'"
  pass "a record from a stale incarnation classifies unknown, never idle"
}

# --- missing and malformed semantic data --------------------------------------

test_missing_record_unknown_not_idle() {
  local state out h
  state=$(new_state_dir missing)
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state")
    [ "$out" = "unknown missing" ] || fail "$h with no record must be 'unknown missing', got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex with no verified source must be 'unknown codex-unverified', got '$out'"
  pass "a converted adapter with no record classifies unknown, never idle"
}

test_malformed_record_unknown() {
  local state gen out
  state=$(new_state_dir malformed)
  gen=$("$EV" arm "$state" t1)
  for bad in \
    'garbage' \
    "v0 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=NaN state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=frobbing source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=bad source event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1 rogue=1"; do
    printf '%s\n' "$bad" > "$state/t1.busy-state"
    out=$(fm_busy_classify tmux w1 claude t1 "$state")
    [ "$out" = "unknown malformed" ] || fail "malformed record '$bad' must be 'unknown malformed', got '$out'"
  done
  printf 'v1 gen=%s seq=1 state=busy source=claude-hook event=x ts=1\nsecond line\n' "$gen" > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "multi-line record must be 'unknown malformed', got '$out'"
  pass "malformed records classify unknown malformed, never busy or idle"
}

test_record_without_sidecar_unknown() {
  local state out
  state=$(new_state_dir orphan-record)
  printf 'v1 gen=g1.1.1 seq=1 state=busy source=claude-hook event=x ts=1\n' > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "record without an armed gen must be unknown, got '$out'"
  pass "a record with no armed gen sidecar classifies unknown"
}

# --- adapter isolation ---------------------------------------------------------

test_source_mismatch_cross_adapter() {
  local state gen out
  state=$(new_state_dir cross-adapter)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "pi-ext record on a claude task must be untrusted, got '$out'"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "pi-ext record on a pi task must classify, got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "grok trusts no semantic source, got '$out'"
  pass "a record is trusted only by the adapter whose source wrote it"
}

test_converted_adapters_ignore_footer_text() {
  local state out h
  state=$(new_state_dir no-footer)
  local tail='• Working (6s • esc to interrupt)
   ■■■■⬝⬝⬝⬝  esc interrupt
Working...
Ctrl+c:cancel'
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" "$tail")
    [ "$out" = "unknown missing" ] || fail "$h must never classify from footer text, got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state" "$tail")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must never classify from footer text, got '$out'"
  pass "converted adapters never classify busy from rendered footer text"
}

# --- launch-prompt backstop (a launch pinned at fm-spawn, parked on a
# recognized interactive prompt, must classify unknown rather than busy) ------

test_launch_prompt_claude_trust_dialog() {
  local state out
  state=$(new_state_dir launch-prompt-claude)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 claude t1 "$state" 'Accessing workspace: /tmp/wt-a
Quick safety check: Is this a project you created or one you trust?
Claude Code'"'"'ll be able to read, edit, and execute files here.
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a launch pinned at fm-spawn parked on Claude's trust dialog must classify unknown launch-prompt, got '$out'"
  out=$(fm_busy_classify tmux w1 claude t1 "$state" 'Allow external CLAUDE.md file imports?
This project'"'"'s CLAUDE.md imports files outside the current working directory.
> No, disable external imports
  Yes, allow external imports')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a launch pinned at fm-spawn parked on Claude's external-imports dialog must classify unknown launch-prompt, got '$out'"
  pass "a Claude launch parked on its trust or external-imports dialog classifies unknown launch-prompt"
}

test_launch_prompt_pi_trust_dialog() {
  local state out h
  for h in pi pi-signed omp; do
    state=$(new_state_dir "launch-prompt-$h")
    "$EV" arm "$state" t1 >/dev/null
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" ' Trust project folder?
 /tmp/fm-pi-trust-check/wt

 This allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.

 > Trust
   Trust parent folder (/tmp/fm-pi-trust-check)
   Trust (this session only)
   Do not trust
   Do not trust (this session only)

 up/down navigate  enter select  escape/ctrl+c cancel')
    [ "$out" = "unknown launch-prompt" ] \
      || fail "a $h launch pinned at fm-spawn parked on the project-trust dialog must classify unknown launch-prompt, got '$out'"
  done
  pass "a Pi-family launch (pi, pi-signed, omp) parked on the project-trust dialog classifies unknown launch-prompt"
}

test_launch_prompt_pi_requires_both_markers() {
  local state out
  state=$(new_state_dir launch-prompt-pi-partial)
  "$EV" arm "$state" t1 >/dev/null
  # "trust" alone, with neither the dialog heading nor its decline option, must
  # not be read as the dialog - it is an ordinary word a worker's own output
  # could easily contain.
  out=$(fm_busy_classify tmux w1 pi t1 "$state" 'I trust this approach and will proceed.')
  [ "$out" = "busy fm-spawn" ] \
    || fail "ordinary prose containing 'trust' must not classify as a parked launch, got '$out'"
  pass "the Pi signature requires both the dialog heading and its decline option, not the bare word trust"
}

test_launch_prompt_gemini_dialogs() {
  local state out
  state=$(new_state_dir launch-prompt-gemini-trust)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 gemini t1 "$state" 'Do you trust the files in this folder?
● 1. Trust folder (worktree)
  2. Trust parent folder (project)
  3. Don'"'"'t trust')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a Gemini launch parked on the workspace-trust dialog must classify unknown launch-prompt, got '$out'"

  state=$(new_state_dir launch-prompt-gemini-auth)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 gemini t1 "$state" 'How would you like to authenticate for this project?
● 2. Use Gemini API Key')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a Gemini launch parked on the auth-method picker must classify unknown launch-prompt, got '$out'"

  state=$(new_state_dir launch-prompt-gemini-apikey)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 gemini t1 "$state" 'Enter Gemini API Key
> ')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a Gemini launch parked on the API-key entry dialog must classify unknown launch-prompt, got '$out'"
  pass "a Gemini launch parked on its trust, auth-picker, or API-key dialog classifies unknown launch-prompt"
}

test_launch_prompt_never_shortens_a_working_launch() {
  local state out
  state=$(new_state_dir launch-prompt-working)
  "$EV" arm "$state" t1 >/dev/null
  # A genuinely working launch (Claude's ordinary busy footer, rendered before
  # its own hook has posted a single event yet) must keep the normal busy
  # bound rather than being shortened by this backstop.
  out=$(fm_busy_classify tmux w1 claude t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "busy fm-spawn" ] \
    || fail "a genuinely busy launch must not be reclassified, got '$out'"
  pass "the launch-prompt backstop never reclassifies a genuinely working launch"
}

test_launch_prompt_scoped_to_armed_harnesses() {
  local state out
  # opencode ships no trust dialog (fm-busy-lib.sh header), so it has no
  # signature at all: even Claude's own dialog text must not reclassify it.
  state=$(new_state_dir launch-prompt-opencode)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 opencode t1 "$state" \
    'Quick safety check: Is this a project you created or one you trust?')
  [ "$out" = "busy fm-spawn" ] \
    || fail "opencode has no launch-prompt signature and must stay busy fm-spawn, got '$out'"
  pass "the launch-prompt backstop is scoped to harnesses with a verified signature"
}

test_launch_prompt_never_reclassifies_an_advanced_record() {
  local state gen out
  state=$(new_state_dir launch-prompt-advanced)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 claude t1 "$state" \
    'Quick safety check: Is this a project you created or one you trust?')
  [ "$out" = "busy claude-hook" ] \
    || fail "a record that has advanced past fm-spawn must never be reclassified by pane text, got '$out'"
  pass "the launch-prompt backstop only ever touches the untouched fm-spawn seed"
}

test_launch_prompt_requires_a_captured_tail() {
  local state out
  state=$(new_state_dir launch-prompt-no-tail)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] \
    || fail "with no captured tail the record's own state must stand, got '$out'"
  pass "the launch-prompt backstop never runs without a captured tail"
}

test_grok_regex_isolated() {
  local state out
  state=$(new_state_dir grok-arm)
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'thinking hard
Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok busy tail must classify 'busy grok-regex', got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'done.
> ')
  [ "$out" = "idle grok-regex" ] || fail "grok idle tail must classify 'idle grok-regex', got '$out'"
  # Another adapter's footer never makes grok busy either.
  out=$(fm_busy_classify tmux w1 grok t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "idle grok-regex" ] || fail "a claude footer must not classify grok busy, got '$out'"
  pass "the grok fallback is regex-scoped to grok and classifies only grok tasks"
}

# --- kimi verification gate -----------------------------------------------------

test_codex_unverified_gate() {
  local state gen out
  state=$(new_state_dir codex-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source codex-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "unverified codex must classify unknown, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no semantic source until one is verified"
  pass "codex classifies unknown until a semantic source passes its verification gate"
}

test_kimi_unverified_gate() {
  local state gen out
  state=$(new_state_dir kimi-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source kimi-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 kimi t1 "$state")
  [ "$out" = "unknown kimi-unverified" ] || fail "unverified kimi must classify unknown, got '$out'"
  out=$(fm_busy_classify tmux w1 kimi t1 "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must not classify from footer text, got '$out'"
  pass "standalone kimi classifies unknown until the live verification gate opens"
}

test_cursor_ignores_rendered_and_native_signals() {
  local state out
  state=$(new_state_dir cursor-gate)
  # Cursor's verdict comes from its own transcript, never from rendered text.
  # With no binding to fold, the honest answer is unknown - and a rendered
  # busy-looking footer must not change that.
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'Working')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from its rendered footer, got '$out'"
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'ctrl+c to stop')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from the ctrl+c busy token either, got '$out'"
  # Herdr's narrower native streaming state is not cursor's turn lifecycle.
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' busy; }
  out=$(fm_busy_classify herdr s:p cursor t1 "$state")
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not borrow herdr's native busy verdict, got '$out'"
  unset -f fm_backend_busy_state
  # The fold is a PULL source: nothing is armed, so no stored record is trusted.
  [ -z "$(fm_busy_sources_for_harness cursor)" ] \
    || fail "cursor must trust no stored record source; its fold has no writer"
  pass "cursor classifies only from its transcript fold, never rendered text or native state"
}

# --- endpoint death and native fallbacks ----------------------------------------

test_dead_endpoint_overrides() {
  local state gen out
  state=$(new_state_dir dead)
  gen=$("$EV" arm "$state" t1)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 1; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "gone endpoint must classify dead, got '$out'"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 0; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "live endpoint must fall through to the record, got '$out'"
  out=$(fm_busy_classify_live tmux '' claude t1 "$state")
  [ "$out" = "unknown no-target" ] || fail "empty target must classify unknown, got '$out'"
  unset -f fm_backend_target_exists
  pass "endpoint death is the only process-level override and yields dead, never busy"
}

test_herdr_native_busy_only() {
  local state out
  state=$(new_state_dir herdr-native)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE"; }
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "busy herdr-native" ] || fail "native busy with no record must classify busy, got '$out'"
  FAKE_NATIVE=idle
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "unknown missing" ] || fail "native idle must NOT classify idle, got '$out'"
  # A valid record outranks the native verdict.
  local gen
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "the adapter record must outrank herdr's native verdict, got '$out'"
  unset -f fm_backend_busy_state
  pass "herdr's native verdict is trusted for busy only, and records outrank it"
}

# The record parser runs inside sourcing callers (the watcher, the daemon, the
# crew-state reader), so it must not disturb their shell: no clobbered
# positional parameters and no changed glob setting.
test_record_read_leaves_caller_shell_intact() {
  local state out
  state=$(new_state_dir parser-isolation)
  "$EV" arm "$state" t1 >/dev/null
  out=$(bash -c '
    set -f
    . "$1/bin/fm-busy-lib.sh"
    set -- keepme second
    fm_busy_record_read "$2" t1 >/dev/null
    printf "%s|%s|%s" "$1" "$#" "$-"
  ' _ "$ROOT" "$state")
  case "$out" in
    keepme\|2\|*f*) : ;;
    *) fail "record parsing disturbed the caller's shell: $out" ;;
  esac
  # A glob-shaped field must survive parsing literally rather than expanding.
  printf 'v1 gen=%s seq=1 state=busy source=* event=x ts=1\n' "$(cat "$state/t1.busy-gen")" \
    > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "a glob-shaped source must be rejected, not expanded, got '$out'"
  pass "record parsing never clobbers the caller's positional parameters, glob setting, or fields"
}

test_boolean_view_never_promotes_unknown() {
  local state gen
  state=$(new_state_dir boolean)
  gen=$("$EV" arm "$state" t1)
  fm_busy_is_busy tmux w1 claude t1 "$state" || fail "busy record must read busy"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "idle record must not read busy"
  fi
  printf 'garbage\n' > "$state/t1.busy-state"
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "malformed record must not read busy"
  fi
  pass "the boolean view reports busy only on an exact busy verdict"
}

test_progress_is_generation_bound_and_not_semantic_state() {
  local state gen replacement before
  state=$(new_state_dir native-progress)
  gen=$("$EV" arm "$state" t1)
  before=$(cat "$state/t1.busy-state")
  "$EV" progress "$state" t1 --gen "$gen" || fail "current progress was refused"
  [ -f "$state/t1.progress" ] || fail "progress marker missing"
  [ ! -e "$state/t1.turn-ended" ] || fail "progress emitted a completed turn"
  [ "$(cat "$state/t1.busy-state")" = "$before" ] || fail "progress changed semantic state"
  replacement=$("$EV" arm "$state" t1)
  [ ! -e "$state/t1.progress" ] || fail "arm retained the previous incarnation's progress"
  if "$EV" progress "$state" t1 --gen "$gen" 2>/dev/null; then fail "stale progress was accepted"; fi
  [ ! -e "$state/t1.progress" ] || fail "stale progress wrote a marker"
  "$EV" progress "$state" t1 --gen "$replacement" || fail "replacement progress was refused"
  "$EV" retire "$state" t1 --gen "$replacement" || fail "retire failed"
  [ ! -e "$state/t1.progress" ] || fail "retire retained progress"
  pass "native progress is generation-bound, separately recorded, and cleared on arm and retire"
}

# --- wiring liveness: a record whose writer is gone is stale, not idle -------

# A real process to stand in for the agent the wiring loaded into. Stores its
# pid in WRITER_PROCESS_PID; the caller ends and waits for it.
writer_process() {
  sleep 600 > /dev/null 2>&1 &
  WRITER_PROCESS_PID=$!
}

test_wired_identity_is_generation_bound() {
  local state gen replacement writer
  state=$(new_state_dir wired-contract)
  gen=$("$EV" arm "$state" t1)
  writer_process
  writer=$WRITER_PROCESS_PID
  "$EV" wired "$state" t1 --gen "$gen" --pid "$writer" || fail "a live writer's identity was refused"
  case "$(cat "$state/t1.busy-wired")" in
    "v1 gen=$gen pid=$writer start="?*) ;;
    *)
      kill "$writer" 2>/dev/null || :
      wait "$writer" 2>/dev/null || [ "$?" -eq 143 ] || :
      fail "unexpected wiring record: $(cat "$state/t1.busy-wired")"
      ;;
  esac
  [ ! -e "$state/t1.turn-ended" ] || fail "recording a wiring identity emitted a completed turn"
  [ "$(fm_busy_classify tmux w1 pi t1 "$state")" = "busy fm-spawn" ] \
    || fail "recording a wiring identity changed semantic state"
  if "$EV" wired "$state" t1 --gen g1.1.1 --pid "$writer" 2>/dev/null; then fail "a stale gen's wiring identity was accepted"; fi
  if "$EV" wired "$state" t1 --gen "$gen" --pid 0 2>/dev/null; then fail "a pid with no process was recorded"; fi
  if "$EV" wired "$state" t1 --gen "$gen" --pid nope 2>/dev/null; then fail "a non-numeric pid was recorded"; fi
  replacement=$("$EV" arm "$state" t1)
  [ ! -e "$state/t1.busy-wired" ] || fail "arm retained the previous incarnation's wiring identity"
  "$EV" wired "$state" t1 --gen "$replacement" --pid "$writer" || fail "the replacement's identity was refused"
  "$EV" retire "$state" t1 --gen "$replacement" || fail "retire failed"
  [ ! -e "$state/t1.busy-wired" ] || fail "retire retained the wiring identity"
  kill "$writer" 2>/dev/null || :
  wait "$writer" 2>/dev/null || [ "$?" -eq 143 ] || fail "could not reap the wiring writer"
  pass "a wiring identity is generation-bound, changes no state, and is cleared on arm and retire"
}

test_wiring_lost_by_identity_withdraws_the_record() {
  local state gen writer out other
  state=$(new_state_dir wired-identity)
  gen=$("$EV" arm "$state" t1)
  writer_process
  writer=$WRITER_PROCESS_PID
  "$EV" wired "$state" t1 --gen "$gen" --pid "$writer"
  "$EV" apply "$state" t1 idle --gen "$gen" --source pi-ext --event agent-settled
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle pi-ext" ] || {
    kill "$writer" 2>/dev/null || :
    wait "$writer" 2>/dev/null || [ "$?" -eq 143 ] || :
    fail "a record with a live writer should classify as written, got '$out'"
  }
  # The process the wiring loaded into is gone: the record is whatever it last
  # wrote, frozen, and that is unknown whichever state it happens to hold.
  kill "$writer" 2>/dev/null || :
  wait "$writer" 2>/dev/null || [ "$?" -eq 143 ] || fail "could not reap the wiring writer"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown wiring-lost" ] || fail "a frozen idle record must classify 'unknown wiring-lost', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown wiring-lost" ] || fail "a frozen busy record must classify 'unknown wiring-lost', got '$out'"
  fm_busy_is_busy tmux w1 pi t1 "$state" && fail "a frozen busy record read as provably busy"
  # A pid that some other process now holds is not the writer either.
  writer_process
  other=$WRITER_PROCESS_PID
  printf 'v1 gen=%s pid=%s start=Thu Jan 1 00:00:00 1970\n' "$gen" "$other" > "$state/t1.busy-wired"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  kill "$other" 2>/dev/null || :
  wait "$other" 2>/dev/null || [ "$?" -eq 143 ] || fail "could not reap the replacement writer"
  [ "$out" = "unknown wiring-lost" ] || fail "a reused pid must not stand in for the writer, got '$out'"
  # An identity recorded for another incarnation says nothing about this one.
  printf 'v1 gen=g1.1.1 pid=1 start=Thu Jan 1 00:00:00 1970\n' > "$state/t1.busy-wired"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "another incarnation's identity must prove nothing, got '$out'"
  # A relaunch arms a fresh incarnation, which is unproven again, not lost.
  "$EV" arm "$state" t1 > /dev/null
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a fresh incarnation must classify from its seed, got '$out'"
  pass "a record whose recorded writer process is gone classifies unknown wiring-lost, never idle or busy"
}

test_wiring_lost_when_writer_is_unreaped() {
  local state gen pid_file release writer supervisor writer_state out i
  state=$(new_state_dir wired-zombie)
  gen=$("$EV" arm "$state" t1)
  pid_file="$state/zombie-writer.pid"
  release="$state/reap-zombie"
  perl - "$pid_file" "$release" <<'PERL' &
use strict;
use warnings;
$| = 1;
my $writer = fork();
die "fork failed: $!\n" unless defined $writer;
if (!$writer) {
  exit 0;
}
open my $pid_file, ">", $ARGV[0] or die "open pid file: $!\n";
print {$pid_file} "$writer\n" or die "write pid file: $!\n";
close $pid_file or die "close pid file: $!\n";
while (!-e $ARGV[1]) {
  select undef, undef, undef, 0.01;
}
waitpid($writer, 0) == $writer or die "waitpid failed: $!\n";
$? == 0 or die "writer did not exit successfully\n";
PERL
  supervisor=$!
  for i in {1..100}; do
    [ -s "$pid_file" ] && break
    sleep 0.01
  done
  if [ ! -s "$pid_file" ]; then
    touch "$release"
    wait "$supervisor" || fail "the zombie-writer fixture failed before publishing its pid"
    fail "the zombie-writer fixture did not publish its pid"
  fi
  IFS= read -r writer < "$pid_file"
  "$EV" wired "$state" t1 --gen "$gen" --pid "$writer" || {
    touch "$release"
    wait "$supervisor" || fail "the zombie-writer fixture failed to clean up"
    fail "the zombie writer's identity was refused"
  }
  for i in {1..100}; do
    writer_state=$(ps -o stat= -p "$writer" 2>/dev/null || :)
    case "$writer_state" in *Z*) break ;; esac
    sleep 0.01
  done
  case "$writer_state" in
    *Z*) ;;
    *)
      touch "$release"
      wait "$supervisor" || fail "the zombie-writer fixture failed to clean up"
      fail "the writer never became unreaped"
      ;;
  esac
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  touch "$release"
  wait "$supervisor" || fail "the zombie-writer fixture did not reap its child successfully"
  [ "$out" = "unknown wiring-lost" ] || fail "an unreaped writer must classify 'unknown wiring-lost', got '$out'"
  pass "an exited but unreaped writer classifies as unknown wiring-lost"
}

test_wiring_lost_by_boot_needs_no_identity() {
  local state gen out now
  state=$(new_state_dir wired-boot)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source pi-ext --event agent-settled
  now=$(date +%s)
  # Booted before the launch: the launched process can still be the one alive.
  out=$(FM_BUSY_BOOT_EPOCH=$((now - 5000)) fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle pi-ext" ] || fail "a launch after boot must classify as written, got '$out'"
  # Booted after it: no process from that launch survived, record or no record.
  out=$(FM_BUSY_BOOT_EPOCH=$((now + 100)) fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown wiring-lost" ] || fail "a launch from before the last boot must classify 'unknown wiring-lost', got '$out'"
  out=$(FM_BUSY_BOOT_EPOCH=$((now + 100)) fm_busy_classify tmux w1 pi-signed t1 "$state")
  [ "$out" = "unknown wiring-lost" ] || fail "pi-signed rides its launch exactly as pi does, got '$out'"
  # A boot time that cannot be read proves nothing.
  out=$(FM_BUSY_BOOT_EPOCH=unreadable fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle pi-ext" ] || fail "an unreadable boot time must prove nothing, got '$out'"
  # Claude's hooks live in the worktree, so an agent resumed there is wired.
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  out=$(FM_BUSY_BOOT_EPOCH=$((now + 100)) fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "a harness whose wiring survives a restart must not lose it to a reboot, got '$out'"
  # The machine's own boot time is readable here, and predates this launch.
  fm_busy_boot_epoch > /dev/null || fail "this host's boot time could not be read"
  [ "$(fm_busy_boot_epoch)" -le "$now" ] || fail "this host's boot time reads as later than now"
  pass "a launch-carried wiring armed before the last boot classifies unknown wiring-lost with no identity record"
}

test_progress_is_generation_bound_and_not_semantic_state
test_wired_identity_is_generation_bound
test_wiring_lost_by_identity_withdraws_the_record
test_wiring_lost_when_writer_is_unreaped
test_wiring_lost_by_boot_needs_no_identity

test_arm_seeds_busy_spawn
test_apply_advances_seq_and_source
test_apply_current_gen_reset
test_apply_unarmed_refused
test_retire_serializes_and_rejects_stale_gen
test_retire_missing_sidecar_is_idempotent
test_stale_lock_broken_under_gnu_stat
test_stale_gen_event_rejected
test_stale_gen_record_unknown
test_missing_record_unknown_not_idle
test_malformed_record_unknown
test_record_without_sidecar_unknown
test_source_mismatch_cross_adapter
test_converted_adapters_ignore_footer_text
test_launch_prompt_claude_trust_dialog
test_launch_prompt_pi_trust_dialog
test_launch_prompt_pi_requires_both_markers
test_launch_prompt_gemini_dialogs
test_launch_prompt_never_shortens_a_working_launch
test_launch_prompt_scoped_to_armed_harnesses
test_launch_prompt_never_reclassifies_an_advanced_record
test_launch_prompt_requires_a_captured_tail
test_grok_regex_isolated
test_codex_unverified_gate
test_kimi_unverified_gate
test_cursor_ignores_rendered_and_native_signals
test_dead_endpoint_overrides
test_herdr_native_busy_only
test_record_read_leaves_caller_shell_intact
test_boolean_view_never_promotes_unknown

echo "all fm-busy-state tests passed"
