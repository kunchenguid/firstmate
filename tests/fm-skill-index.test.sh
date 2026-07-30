#!/usr/bin/env bash
# tests/fm-skill-index.test.sh - behavior tests for bin/fm-skill-index.sh, the
# generated agent-only skill trigger index that replaced AGENTS.md section 13's
# hand-maintained roster.
#
# Coverage:
#   - suppressed on a harness that injects skill descriptions (claude, grok)
#   - emitted on a harness that does not (opencode, pi, pi-signed, codex, kimi)
#   - an unknown or unverified harness EMITS: suppression requires positive
#     evidence, because a wrongly suppressed index silently removes every
#     agent-only skill's load trigger
#   - the roster is exactly the user-invocable:false skills, so captain-invocable
#     skills never leak into it and a new agent-only skill needs no second entry
#   - each rendered trigger is the skill's own frontmatter description, including
#     folded multi-line descriptions collapsed to one line
#   - --force renders even for a suppressed harness
#   - the session-start digest composes the real script: suppressed under a
#     claude primary, present under an opencode primary
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INDEX="$ROOT/bin/fm-skill-index.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
SKILL_DIR="$ROOT/.agents/skills"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-skill-index.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

INJECTING_HARNESSES="claude grok"
NON_INJECTING_HARNESSES="opencode pi pi-signed codex kimi unknown"

test_suppressed_for_injecting_harnesses() {
  local harness out
  for harness in $INJECTING_HARNESSES; do
    out=$("$INDEX" --harness "$harness") \
      || fail "index exited non-zero for $harness"
    [ -z "$out" ] \
      || fail "index must stay silent on $harness, which injects skill descriptions; got: $out"
  done
  pass "index is suppressed on every harness that already injects skill descriptions"
}

test_emitted_for_non_injecting_harnesses() {
  local harness out
  for harness in $NON_INJECTING_HARNESSES; do
    out=$("$INDEX" --harness "$harness") \
      || fail "index exited non-zero for $harness"
    assert_contains "$out" "AGENT-ONLY SKILL TRIGGERS" \
      "index was not emitted for $harness"
    assert_contains "$out" "- harness-adapters - " \
      "index for $harness omitted a known agent-only skill"
  done
  pass "index is emitted for every harness without verified description injection, including unknown"
}

test_roster_is_exactly_the_agent_only_skills() {
  local rendered expected agent_only user_invocable name
  rendered=$("$INDEX" --harness opencode | sed -n 's/^- \([a-z0-9-]*\) - .*/\1/p' | LC_ALL=C sort)
  expected=$("$INDEX" --list-agent-only)
  [ "$rendered" = "$expected" ] \
    || fail "rendered roster does not match --list-agent-only"

  # Derive the truth independently from the skill frontmatter, not from the
  # script's own listing, so a regression in the selector is visible here.
  agent_only=""
  for dir in "$SKILL_DIR"/*/; do
    name=$(basename "$dir")
    [ -f "$dir/SKILL.md" ] || continue
    user_invocable=$(grep -m1 '^user-invocable:' "$dir/SKILL.md" | awk '{print $2}')
    [ "$user_invocable" = "false" ] || continue
    agent_only="$agent_only$name
"
  done
  agent_only=$(printf '%s' "$agent_only" | LC_ALL=C sort)
  [ "$rendered" = "$agent_only" ] \
    || fail "roster is not exactly the user-invocable:false skills"

  # A captain-invocable skill must never appear in the agent-only index.
  assert_not_contains "$rendered" "updatefirstmate" \
    "captain-invocable skill leaked into the agent-only index"
  assert_not_contains "$rendered" "bearings" \
    "captain-invocable skill leaked into the agent-only index"
  pass "roster is exactly the user-invocable:false skills, derived from frontmatter"
}

test_trigger_text_comes_from_frontmatter() {
  local out line
  out=$("$INDEX" --harness pi)
  # bootstrap-diagnostics' trigger detail lives in the second sentence of a
  # folded description; a naive first-line parse would drop it.
  line=$(printf '%s\n' "$out" | grep '^- bootstrap-diagnostics - ')
  assert_contains "$line" "actionable diagnostic line" \
    "folded description was truncated before its trigger condition"
  assert_contains "$line" "BOOTSTRAP_INFO" \
    "folded description lost its final no-load qualification"
  # Folding must produce exactly one line per skill.
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] \
    || fail "a folded description rendered as more than one line"
  pass "rendered triggers are the skills' own folded frontmatter descriptions"
}

test_force_overrides_suppression() {
  local out
  out=$("$INDEX" --harness claude --force) || fail "--force exited non-zero"
  assert_contains "$out" "AGENT-ONLY SKILL TRIGGERS" \
    "--force did not render for a suppressed harness"
  pass "--force renders the index even for a suppressed harness"
}

# A fake `ps` reporting every queried pid as one harness, so ancestry detection
# in bin/fm-harness.sh resolves deterministically for the markerless harnesses.
# Mirrors tests/fm-session-start.test.sh's make_fake_ps_harness.
make_fake_ps_harness() {
  local fakebin=$1 harness=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"comm="*) printf '/usr/local/bin/%s\n' "$harness"; exit 0 ;;
  *"args="*) printf '%s\n' "$harness"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_session_start_composes_the_real_index() {
  local home fakebin base_path digest
  home="$TMP_ROOT/ss-home"
  fakebin="$TMP_ROOT/ss-bin"
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"

  # claude primary: the env marker wins in detect_own, no fake ps needed.
  digest=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT CLAUDECODE=1 \
    FM_HOME="$home" "$SESSION_START" 2>&1) \
    || fail "session start failed under a claude primary"
  assert_contains "$digest" "SESSION START" "claude digest did not render"
  assert_not_contains "$digest" "AGENT-ONLY SKILL TRIGGERS" \
    "claude digest carried a duplicate skill index"

  # opencode is markerless, so drop every harness env marker and pin ancestry.
  make_fake_ps_harness "$fakebin" opencode
  digest=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_HOME="$home" PATH="$fakebin:$base_path" "$SESSION_START" 2>&1) \
    || fail "session start failed under an opencode primary"
  assert_contains "$digest" "AGENT-ONLY SKILL TRIGGERS" \
    "opencode digest lost the agent-only skill index"
  assert_contains "$digest" "- stuck-crewmate-recovery - " \
    "opencode digest index omitted a known agent-only skill"
  pass "session start emits the index for opencode and suppresses it for claude"
}

test_suppressed_for_injecting_harnesses
test_emitted_for_non_injecting_harnesses
test_roster_is_exactly_the_agent_only_skills
test_trigger_text_comes_from_frontmatter
test_force_overrides_suppression
test_session_start_composes_the_real_index
