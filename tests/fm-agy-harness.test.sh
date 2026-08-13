#!/usr/bin/env bash
# tests/fm-agy-harness.test.sh - the portable regression for the agy
# (Antigravity CLI) crewmate/scout adapter.
#
# agy's identity and composer checks are HARNESS-DEPENDENT: their verdicts come
# from what the vendor emits (an env marker, a process name, a drawn composer).
# This suite pins the LOGIC with real processes and real captures and NO agy
# installed, so CI enforces it everywhere; the live-harness guard in
# tests/fm-harness-liveness-drift-live-e2e.test.sh is what catches vendor drift
# against a real agy. Neither replaces the other.
#
# The load-bearing contracts:
#   1. agy's env marker is tested LAST, because the Antigravity terminal leaks
#      it into non-agy workers; it must never outrank an unambiguous marker.
#   2. Ancestry matches the exact command name `agy`, never a substring, so an
#      unrelated command cannot be misread as this harness.
#   3. agy's composer is a `>` prompt row between two `─` rules. It reads empty
#      or pending WITHOUT any agent-identity capability, while pi's blank
#      separated region - the same rule pair with no glyph - still needs one.
#   4. The dead-shell rule survives: a `>` prompt with no rule beneath it is
#      never `empty`, on any capability shape.
#   5. Both model spellings agy accepts resolve against its catalogue, and a
#      model absent from the catalogue is refused.
#   6. agy runs every task kind, because it has a supervision protocol and a
#      blocking primary Stop guard; muse still refuses a secondmate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

# The exact truecolor agy draws, measured from a live pane (agy 1.1.12): the
# rules are dark enough that the shared ghost stripper drops them, and the
# prompt glyph is bright enough to survive it. Both facts matter: structural
# detection must read the rules from the UNSTRIPPED row, and the glyph must
# still be there after stripping.
AGY_RULE_SGR=$'\033[38;2;65;72;104m'
AGY_GLYPH_SGR=$'\033[38;2;122;162;247m'
RESET=$'\033[0m'
AGY_RULE=$(printf '─%.0s' $(seq 1 60))

# A rendered agy screen: transcript rows, then rule / `>`<content> / rule, then
# the model+quota footer agy draws below its composer.
agy_screen() {  # <composer-content>
  printf '%s\n' \
    "${RESET}  Some earlier agent output${RESET}" \
    "${RESET}${RESET}" \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}" \
    "${AGY_GLYPH_SGR}>${RESET}$1" \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}" \
    "${RESET}Gemini 3.1 Pro (High) | ctx: 0.1% | quota: 97.6% (4h 50m)${RESET}"
}
AGY_COMPOSER_ROW=3

# --- 1. Detection ------------------------------------------------------------

# agy's marker is the one that must be tested LAST, which is the exact reverse
# of cursor's rule and is deliberate. ANTIGRAVITY_AGENT is exported by the
# Antigravity IDE's own terminal into EVERY process it starts, not just agy's
# children, so a claude/codex/pi worker started from that terminal carries it
# too - observed directly on a real claude session. Testing it early would
# misidentify every such worker as agy.
test_agy_marker_never_outranks_an_unambiguous_marker() {
  local out
  out=$(CLAUDECODE=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = claude ] \
    || fail "a claude worker carrying a leaked ANTIGRAVITY_AGENT must stay claude, got '$out'"
  out=$(env -u CLAUDECODE CURSOR_AGENT=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] \
    || fail "a cursor worker carrying a leaked ANTIGRAVITY_AGENT must stay cursor, got '$out'"
  out=$(env -u CLAUDECODE PI_CODING_AGENT=true ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = pi ] || fail "a pi worker carrying a leaked ANTIGRAVITY_AGENT must stay pi, got '$out'"
  out=$(env -u CLAUDECODE GROK_AGENT=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = grok ] || fail "a grok worker carrying a leaked ANTIGRAVITY_AGENT must stay grok, got '$out'"
  # With no competing marker it is still the agy identity.
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
        -u GROK_AGENT ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT alone must detect agy, got '$out'"
  # A different ANTIGRAVITY_* value is agy CONTEXT, not the identity marker.
  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u PI_CODING_AGENT -u GROK_AGENT ANTIGRAVITY_PROJECT_ID=default-cli-project "$HARNESS")
  [ "$out" != agy ] \
    || fail "an unrelated ANTIGRAVITY_* setting must not claim the agy identity, got '$out'"
  pass "fm-harness.sh: agy's leak-prone marker never outranks an unambiguous one"
}

# Detection must follow a REAL running process rather than a string, so each
# case launches an actual renamed executable and asks fm-harness.sh from a child
# of it. The foreign markers are cleared because the marker layer deliberately
# outranks ancestry, and the command substitution around the probe is
# load-bearing: a bare `-c <cmd>` lets the shell exec the probe in place, which
# would REPLACE the very process name the walk is supposed to find. Real agy
# keeps its TUI process alive and runs tools as children (verified: its live
# `comm` is exactly `agy`, with sidecar children below it), so forcing a fork is
# what reproduces that shape.
test_agy_ancestry_is_anchored_to_the_exact_command_name() {
  local dir bin out
  dir="$TMP_ROOT/ancestry"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/agy"
  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u PI_CODING_AGENT -u GROK_AGENT "$dir/agy" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "fm-harness.sh under process 'agy' reported '$out', expected agy"

  # An unrelated command whose name merely CONTAINS agy is a different program
  # and must not be claimed by this adapter.
  for bin in agyzilla magy agy-bin legagy notagy; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u PI_CODING_AGENT -u GROK_AGENT "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != agy ] || fail "fm-harness.sh misdetected unrelated process '$bin' as agy"
  done
  pass "fm-harness.sh: agy ancestry matches the exact command name only"
}

# --- 2. The composer shape ---------------------------------------------------

test_agy_composer_reads_empty_and_pending_without_identity() {
  local screen out caps
  # No identity=1 anywhere: agy's glyph inside the rule pair IS the container
  # proof, which is exactly what pi's blank region lacks.
  for caps in $'styled=1\ncursor=1' $'styled=1' $'styled=0'; do
    screen=$(agy_screen "")
    if [ "$caps" = $'styled=1\ncursor=1' ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" "$AGY_COMPOSER_ROW")
    else
      out=$(fm_composer_classify_screen "$caps" "$screen")
    fi
    [ "$out" = empty ] || fail "an empty agy composer must read empty for caps '$caps', got '$out'"

    screen=$(agy_screen " run the tests")
    if [ "$caps" = $'styled=1\ncursor=1' ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" "$AGY_COMPOSER_ROW")
    else
      out=$(fm_composer_classify_screen "$caps" "$screen")
    fi
    [ "$out" = pending ] || fail "typed agy text must read pending for caps '$caps', got '$out'"
  done
  pass "fm-composer-lib: agy's separated glyph composer reads empty and pending with no identity probe"
}

test_pi_blank_separated_region_still_requires_identity() {
  local screen out
  # The SAME rule pair with no prompt glyph is pi's shape, and teaching agy must
  # not have downgraded pi's identity conjunction into a structural guess.
  screen=$(printf '%s\n' \
    "${RESET}  earlier output${RESET}" \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}" \
    "${RESET}${RESET}" \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}")
  out=$(fm_composer_classify_screen $'styled=1' "$screen")
  [ "$out" = unknown ] \
    || fail "pi's blank separated region must stay unknown without identity, got '$out'"
  out=$(fm_composer_classify_screen $'styled=1\nidentity=1' "$screen" '' "$(printf 'pi\tidle')")
  [ "$out" = empty ] || fail "an idle pi identity must still prove pi's empty composer, got '$out'"
  pass "fm-composer-lib: pi's blank separated composer still needs its identity conjunction"
}

test_dead_shell_prompt_is_never_empty() {
  local screen out
  # A dead shell's `>` has no rule beneath it, so it is not inside any pair.
  screen=$(printf '%s\n' \
    "${RESET}  earlier output${RESET}" \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}" \
    "${RESET}some transcript text${RESET}" \
    "${RESET}> ${RESET}")
  out=$(fm_composer_classify_screen $'styled=1' "$screen")
  [ "$out" = unknown ] || fail "a bare shell prompt must never read empty, got '$out'"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1' "$screen" 3)
  [ "$out" = unknown ] || fail "a bare shell prompt under the cursor must never read empty, got '$out'"

  # And a shell prompt BELOW a stale agy composer keeps the pane unknown too,
  # rather than folding the stale composer as if the agent were still live.
  screen=$(printf '%s\n' \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}" \
    "${AGY_GLYPH_SGR}>${RESET}" \
    "${AGY_RULE_SGR}${AGY_RULE}${RESET}" \
    "${RESET}\$ ${RESET}")
  out=$(fm_composer_classify_screen $'styled=1' "$screen")
  [ "$out" = unknown ] \
    || fail "a shell prompt below a stale agy composer must read unknown, got '$out'"
  pass "fm-composer-lib: the dead-shell rule survives the agy shape"
}

# --- 3. Model catalogue ------------------------------------------------------

test_catalogue_accepts_both_spellings_agy_accepts() {
  local catalogue
  # agy's `models` output is "<id><TAB><Display Name>", and --model accepts
  # EITHER column (verified: both resolved to the same backing model).
  catalogue=$(printf '%s\n' \
    'gemini-3.1-pro-high	Gemini 3.1 Pro (High)' \
    'gemini-3.6-flash-high	Gemini 3.6 Flash (High)' \
    'claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)')
  printf '%s\n' "$catalogue" | fm_agy_catalog_has_model 'Gemini 3.1 Pro (High)' \
    || fail "the display-name spelling must resolve"
  printf '%s\n' "$catalogue" | fm_agy_catalog_has_model 'gemini-3.1-pro-high' \
    || fail "the kebab-id spelling must resolve"
  printf '%s\n' "$catalogue" | fm_agy_catalog_has_model 'Claude Opus 4.6 (Thinking)' \
    || fail "a display name containing spaces and parentheses must resolve"
  ! printf '%s\n' "$catalogue" | fm_agy_catalog_has_model 'Gemini 3.1 Pro' \
    || fail "a partial display name must NOT resolve"
  ! printf '%s\n' "$catalogue" | fm_agy_catalog_has_model 'Totally Bogus Model' \
    || fail "a model absent from the catalogue must NOT resolve"
  pass "fm-agy-lib: both accepted model spellings resolve and near-misses do not"
}

test_resolve_binary_refuses_when_absent() {
  local out rc=0
  out=$(PATH="$TMP_ROOT/empty-path" HOME="$TMP_ROOT/empty-home" fm_agy_resolve_binary 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "resolution must fail when agy is absent, printed '$out'"
  case "$out" in
    *'agy is not installed'*) : ;;
    *) fail "the refusal must name the missing executable, got '$out'" ;;
  esac
  pass "fm-agy-lib: a missing agy is a loud refusal, not a silent fallback"
}

# --- 4. Adapter capability tables -------------------------------------------

test_agy_runs_every_task_kind() {
  fm_control_harness_supported agy || fail "agy must be a supported control-plane adapter"
  fm_control_harness_supports_kind agy ship || fail "agy must run a ship task"
  fm_control_harness_supports_kind agy scout || fail "agy must run a scout task"
  # Unlike muse, agy HAS a primary supervision protocol and a blocking primary
  # Stop guard, so it is not restricted to crewmate/scout work.
  fm_control_harness_supports_kind agy secondmate \
    || fail "agy has a primary supervision protocol and must run a secondmate"
  [ -f "$ROOT/docs/supervision-protocols/agy.md" ] \
    || fail "agy's secondmate support requires its emitted supervision protocol"
  [ -x "$ROOT/bin/fm-turnend-guard-agy.sh" ] \
    || fail "agy's secondmate support requires its primary turn-end guard"
  ! fm_control_harness_supports_kind muse secondmate \
    || fail "muse must still refuse a secondmate"
  pass "fm-control-lib: agy runs every task kind, and muse still does not"
}

test_agy_lifecycle_mechanics_are_the_verified_ones() {
  local out
  out=$(fm_control_interrupt_key agy)
  [ "$out" = Escape ] || fail "agy interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat agy)
  [ "$out" = 1 ] || fail "agy interrupts on a SINGLE Escape, got '$out'"
  out=$(fm_control_interrupt_clear_key agy)
  [ -z "$out" ] || fail "agy's composer is empty after an interrupt and needs no clear key, got '$out'"
  out=$(fm_control_interrupt_ack_source agy)
  [ "$out" = none ] \
    || fail "agy fires no interrupt hook, so no cancellation may be claimed, got '$out'"
  out=$(fm_control_exit_command agy)
  [ "$out" = /exit ] || fail "agy exits with /exit, got '$out'"
  pass "fm-control-lib: agy's verified interrupt and exit mechanics"
}

test_agy_busy_source_trust_is_scoped() {
  local trusted
  trusted=$(fm_busy_sources_for_harness agy)
  case " $trusted " in
    *' agy-hook '*) : ;;
    *) fail "agy must trust its own agy-hook source, got '$trusted'" ;;
  esac
  # One adapter's writer may never classify another adapter.
  case " $(fm_busy_sources_for_harness claude) " in
    *' agy-hook '*) fail "agy-hook must not be trusted for claude" ;;
  esac
  case " $trusted " in
    *' claude-hook '*) fail "claude-hook must not be trusted for agy" ;;
  esac
  pass "fm-busy-lib: the agy-hook source is trusted only for agy"
}

test_agy_wiring_paths_cover_every_installed_artifact() {
  local out
  out=$(fm_control_harness_wiring_paths agy /wt /state task1)
  assert_contains "$out" '/wt/.fm-agy-turnend' "the worktree pointer must be retired on relaunch"
  assert_contains "$out" '/state/task1.agy-turnend-token' "the token sidecar must be retired"
  assert_contains "$out" '/state/task1.agy-session' "the session sidecar must be retired"
  out=$(fm_control_harness_turnend_token_path agy /state task1)
  [ "$out" = '/state/task1.agy-turnend-token' ] || fail "unexpected token path '$out'"
  out=$(FM_AGY_CONFIG_HOME=/cfg fm_control_harness_turnend_auth_path agy fm.abcdefabcdef)
  [ "$out" = '/cfg/plugins/fm-turn-end/fm-turn-end.d/fm.abcdefabcdef' ] \
    || fail "the registry entry must resolve under the firstmate-owned plugin, got '$out'"
  # A token that is not the minted shape resolves to nothing rather than to an
  # attacker-chosen path under the plugin directory.
  out=$(FM_AGY_CONFIG_HOME=/cfg fm_control_harness_turnend_auth_path agy '../../etc/passwd')
  [ -z "$out" ] || fail "a malformed token must resolve to no path, got '$out'"
  pass "fm-control-lib: every agy artifact fm-spawn installs is retired by path"
}

test_agy_marker_never_outranks_an_unambiguous_marker
test_agy_ancestry_is_anchored_to_the_exact_command_name
test_agy_composer_reads_empty_and_pending_without_identity
test_pi_blank_separated_region_still_requires_identity
test_dead_shell_prompt_is_never_empty
test_catalogue_accepts_both_spellings_agy_accepts
test_resolve_binary_refuses_when_absent
test_agy_runs_every_task_kind
test_agy_lifecycle_mechanics_are_the_verified_ones
test_agy_busy_source_trust_is_scoped
test_agy_wiring_paths_cover_every_installed_artifact
