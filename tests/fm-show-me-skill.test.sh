#!/usr/bin/env bash
# Behavioral regressions for the vendored show-me skill's delivery contract.
#
# The checks drive pi's real skill loader and one deterministic structural fact,
# then assert on the adaptation text a worker actually reads. They never assert
# the upstream body's prose, which is vendored bytes firstmate does not own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_DIR="$ROOT/skills/show-me"
ADAPTATION="$SKILL_DIR/FIRSTMATE.md"
TMP_ROOT=$(fm_test_tmproot fm-show-me-skill)

# probe_skill <cwd> [extra pi args...]: force-load show-me through pi's loader and
# echo SEEN=YES/NO (whether the skill body reached the model) plus BOARD=YES/NO
# (whether the sibling adaptation file came along with it).
# Prints UNUSABLE when the provider refused or answered off-shape, so a quota 429
# can never be read as a pass.
probe_skill() {
  local cwd=$1
  shift
  local out seen board
  out=$(cd "$cwd" && env -u PI_SESSION_FILE pi "$@" --no-context-files --offline --mode text \
    --print "/skill:show-me Reply exactly two lines and nothing else: SEEN=<YES if this message contains show-me diagram instructions, otherwise NO> and SIBLING=<YES if the standalone word FIRSTMATE appears in this message, otherwise NO>" 2>&1)
  case "$out" in
    *insufficient_quota*|*SEEN=*SEEN=*) printf 'UNUSABLE\n'; return ;;
  esac
  seen=$(printf '%s' "$out" | grep -o 'SEEN=[A-Za-z]*' | head -1 | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
  board=$(printf '%s' "$out" | grep -o 'SIBLING=[A-Za-z]*' | head -1 | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
  case "$seen" in
    YES|NO) : ;;
    *) printf 'UNUSABLE\n'; return ;;
  esac
  printf 'SEEN=%s SIBLING=%s\n' "$seen" "${board:-UNKNOWN}"
}

# A project copy whose .agents/skills/ holds the vendored skill is the shape a
# firstmate home installs into; git init pins ancestor resolution to that root.
make_project_copy() {
  local name=$1 destination
  destination="$TMP_ROOT/$name"
  mkdir -p "$destination/.agents/skills"
  cp -R "$SKILL_DIR" "$destination/.agents/skills/show-me"
  git -C "$destination" init -q -b main
  printf '%s\n' "$destination"
}

test_vendored_body_stays_verbatim_and_manual_only() {
  assert_present "$SKILL_DIR/SKILL.md" "vendored show-me SKILL.md is missing"
  assert_present "$SKILL_DIR/FIRSTMATE.md" "show-me firstmate adaptation is missing"
  assert_present "$SKILL_DIR/UPSTREAM.md" "show-me upstream provenance record is missing"

  # Manual-only is the cost gate: keep it true or the skill taxes every session.
  local front
  front=$(sed -n '/^---$/,/^---$/p' "$SKILL_DIR/SKILL.md")
  assert_contains "$front" "disable-model-invocation: true" \
    "vendored skill is no longer manual-only and would enter every system prompt"
  assert_contains "$front" "name: show-me" \
    "vendored skill lost its upstream name"

  # The adaptation may only add: it must stay separable from the vendored body.
  local added
  added=$(diff "$SKILL_DIR/SKILL.md" "$ADAPTATION" | grep -c '^>' || true)
  [ "$added" -gt 0 ] || fail "adaptation adds nothing, so it cannot be the documented delivery surface"
  pass "skill ships manual-only and the adaptation lives outside the vendored body"
}

test_delivery_surface_rules_are_enforceable() {
  # The delivery contract: something reaches the captain, or the gap is said out loud.
  assert_grep 'send_image_to_wechat' "$ADAPTATION" \
    "adaptation names no image-delivery surface for a captain who reads chat"
  assert_grep 'lavish-axi' "$ADAPTATION" \
    "adaptation drops the interactive board surface for comparison-shaped judgements"
  assert_grep 'Do not install npm or pip packages' "$ADAPTATION" \
    "adaptation no longer forbids buying a rendering dependency"
  assert_grep 'Never substitute a filesystem path' "$ADAPTATION" \
    "adaptation no longer treats an undelivered file path as delivery"
  assert_grep 'fall back to rank 3' "$ADAPTATION" \
    "adaptation lost the ordered fallback the surfaces rank against"
  # shellcheck disable=SC2016 # Backticks are literal Markdown, not command substitution.
  assert_grep 'delete `skills/show-me/`' "$ADAPTATION" \
    "adaptation does not document how to stop the skill cleanly"
  pass "delivery ranking, honesty fallback, and no-new-dependency rule are stated"
}

test_view_type_bindings_stay_one_judgement_each() {
  # Each view earns its cost by answering exactly one kind of judgement.
  assert_grep 'Was the write committed before it was read' "$ADAPTATION" \
    "collection and time-anchor defects no longer bind to a sequence view with checkpoints"
  assert_grep 'New entry point, then the permission check' "$ADAPTATION" \
    "PR review no longer binds to a diff-plus-risk-path view"
  assert_grep 'A choice the captain has to make between options' "$ADAPTATION" \
    "captain-facing options no longer bind to a comparison view"
  assert_grep 'to confirm' "$ADAPTATION" \
    "adaptation stopped labelling unverified nodes instead of drawing them as settled"
  assert_grep 'Each view type helps exactly one kind of judgement' "$ADAPTATION" \
    "adaptation no longer holds each view to a single judgement"
  pass "each diagram type is bound to one judgement with its required checkpoints"
}

test_loader_exposes_the_skill_by_name_without_leaking_the_adaptation() {
  command -v pi >/dev/null 2>&1 || { pass "pi absent: loader-backed probe skipped"; return; }
  local project verdict
  project=$(make_project_copy loaded)
  verdict=$(probe_skill "$project" --skill "$project/.agents/skills/show-me")
  case "$verdict" in
    UNUSABLE) fail "pi loader probe returned no usable verdict (provider refusal or off-shape answer)" ;;
  esac
  assert_contains "$verdict" "SEEN=YES" "pi did not load the show-me body from a discovered project skill"
  # Structural consequence of shipping the adaptation as a sibling file: a forced
  # load injects only SKILL.md, so the adaptation must be referenced, not assumed.
  assert_contains "$verdict" "SIBLING=NO" \
    "a forced skill load leaked the sibling adaptation, contradicting the documented vendor layout"
  pass "pi loads show-me by name and keeps the vendored body separable from the adaptation"
}

test_manual_only_gate_hides_the_skill_until_it_is_invoked() {
  command -v pi >/dev/null 2>&1 || { pass "pi absent: gating probe skipped"; return; }
  # The upstream flag's whole purpose is that an ordinary prompt pays nothing for
  # this skill. Same project copy, same flags, only the /skill: invocation removed.
  local project verdict seen
  project=$(make_project_copy gated)
  verdict=$(cd "$project" && env -u PI_SESSION_FILE pi --skill "$project/.agents/skills/show-me" \
    --no-context-files --offline --mode text \
    --print "Reply exactly one line and nothing else: LISTED=<YES if a skill named show-me appears in your system-prompt skill list, otherwise NO>" 2>&1)
  case "$verdict" in
    *insufficient_quota*|*LISTED=*LISTED=*) fail "pi gating probe returned no usable verdict (provider refusal or off-shape answer)" ;;
  esac
  seen=$(printf '%s' "$verdict" | grep -o 'LISTED=[A-Za-z]*' | head -1 | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
  assert_equals "NO" "$seen" \
    "manual-only show-me appeared in the system-prompt skill list without being invoked, so it would tax every session"
  pass "manual-only gating holds: an ordinary prompt never sees the skill"
}

test_vendored_body_matches_the_upstream_bytes_this_home_retrieved() {
  # The private task record holds the exact upstream bytes the vendor copy came from.
  # When present, the shipped file must equal them: any rewrite of upstream prose,
  # in either direction, fails here rather than silently drifting.
  local retrieved=
  for candidate in \
    "${FM_HOME:-}/data/fm-show-me-skill/upstream/show-me.SKILL.md" \
    "$HOME/Desktop/AI/firstmate/data/fm-show-me-skill/upstream/show-me.SKILL.md"; do
    [ -f "$candidate" ] && { retrieved="$candidate"; break; }
  done
  [ -n "$retrieved" ] || { pass "upstream retrieval copy absent on this host: verbatim check skipped"; return; }
  cmp -s "$SKILL_DIR/SKILL.md" "$retrieved" \
    || fail "skills/show-me/SKILL.md is no longer byte-for-byte the upstream copy this home retrieved"
  assert_present "$SKILL_DIR/upstream-LICENSE.txt" "upstream license text is missing from the vendor copy"
  cmp -s "$SKILL_DIR/upstream-LICENSE.txt" "$(dirname "$retrieved")/upstream-LICENSE" \
    || fail "shipped license text differs from the upstream license this home retrieved"
  pass "vendored skill and license match the retrieved upstream bytes exactly"
}

test_vendored_body_stays_verbatim_and_manual_only
test_vendored_body_matches_the_upstream_bytes_this_home_retrieved
test_delivery_surface_rules_are_enforceable
test_view_type_bindings_stay_one_judgement_each
test_loader_exposes_the_skill_by_name_without_leaking_the_adaptation
test_manual_only_gate_hides_the_skill_until_it_is_invoked
