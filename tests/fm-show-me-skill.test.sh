#!/usr/bin/env bash
# Behavioral regressions for the vendored show-me skill's delivery contract.
#
# Portable half: what firstmate guarantees about the vendor copy and the text a
# worker reads, checked without a model.
# Live half: whether pi's own loader actually honours the manual-only gate. That
# submits prompts, so it is an opt-in guard rather than something CI spends quota on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_DIR="$ROOT/skills/show-me"
ADAPTATION="$SKILL_DIR/FIRSTMATE.md"
TMP_ROOT=$(fm_test_tmproot fm-show-me-skill)

test_vendored_body_stays_verbatim_and_manual_only() {
  assert_present "$SKILL_DIR/SKILL.md" "vendored show-me SKILL.md is missing"
  assert_present "$SKILL_DIR/FIRSTMATE.md" "show-me firstmate adaptation is missing"
  assert_present "$SKILL_DIR/UPSTREAM.md" "show-me upstream provenance record is missing"
  assert_present "$SKILL_DIR/upstream-LICENSE.txt" "upstream license text is missing from the vendor copy"

  # Manual-only is the cost gate: widen it and the skill taxes every session.
  local front
  front=$(sed -n '/^---$/,/^---$/p' "$SKILL_DIR/SKILL.md")
  assert_contains "$front" "disable-model-invocation: true" \
    "vendored skill is no longer manual-only and would enter every system prompt"
  assert_contains "$front" "name: show-me" \
    "vendored skill lost its upstream name"

  # The adaptation may only add, so it must stay separable from the vendored body.
  local added
  added=$(diff "$SKILL_DIR/SKILL.md" "$ADAPTATION" | grep -c '^>' || true)
  [ "$added" -gt 0 ] || fail "adaptation adds nothing, so it cannot be the documented delivery surface"
  pass "skill ships manual-only and the adaptation lives outside the vendored body"
}

test_vendored_body_matches_the_upstream_bytes_this_home_retrieved() {
  # The private task record holds the exact upstream bytes the vendor copy came from.
  # When present, the shipped file must equal them: any rewrite of upstream prose,
  # in either direction, fails here rather than drifting silently.
  local retrieved=
  for candidate in \
    "${FM_HOME:-}/data/fm-show-me-skill/upstream/show-me.SKILL.md" \
    "$HOME/Desktop/AI/firstmate/data/fm-show-me-skill/upstream/show-me.SKILL.md"; do
    [ -f "$candidate" ] && { retrieved="$candidate"; break; }
  done
  [ -n "$retrieved" ] || { pass "upstream retrieval copy absent on this host: verbatim check skipped"; return; }
  cmp -s "$SKILL_DIR/SKILL.md" "$retrieved" \
    || fail "skills/show-me/SKILL.md is no longer byte-for-byte the upstream copy this home retrieved"
  cmp -s "$SKILL_DIR/upstream-LICENSE.txt" "$(dirname "$retrieved")/upstream-LICENSE" \
    || fail "shipped license text differs from the upstream license this home retrieved"
  pass "vendored skill and license match the retrieved upstream bytes exactly"
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

test_adaptation_records_what_it_refused_to_claim() {
  # A supported-looking claim about an unrun combination is the failure this guards.
  local unsupported
  for unsupported in "supports Claude Code" "works on every harness" "verified on codex"; do
    assert_no_grep "$unsupported" "$ADAPTATION" \
      "adaptation claims harness support it never exercised: $unsupported"
  done
  assert_grep 'Unverified combinations' "$ADAPTATION" \
    "adaptation no longer separates measured facts from assumed ones"
  assert_grep 'pi 0.84.2' "$ADAPTATION" \
    "adaptation stopped naming the version its facts were measured against"
  pass "adaptation keeps unproven harness combinations out of its support claims"
}

# --- live guard ------------------------------------------------------------
# Everything below submits prompts to a real pi session. It answers the question
# the portable checks structurally cannot: does pi's loader actually honour the
# flag, inject only SKILL.md on a forced load, and stay silent when uninvited?

# probe_pi <cwd> <prompt>: run one non-interactive pi turn against a project copy.
# The prompt must literally begin with the /skill: token: expansion keys on the
# message's leading text, so prose that merely mentions the command does not load it.
probe_pi() {
  local cwd=$1 prompt=$2
  shift 2
  (cd "$cwd" && env -u PI_SESSION_FILE pi "$@" --no-context-files --offline --mode text \
    --print "$prompt" 2>&1)
}

# verdict_of <output> <label>: echo YES/NO for a labelled line, or refuse.
verdict_of() {
  local out=$1 label=$2 value
  case "$out" in
    *insufficient_quota*|*rate*limit*) printf 'REFUSED\n'; return ;;
  esac
  value=$(printf '%s' "$out" | grep -o "${label}=[A-Za-z]*" | head -1 | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
  case "$value" in
    YES|NO) printf '%s\n' "$value" ;;
    *) printf 'OFFSHAPE\n' ;;
  esac
}

# make_project_copy <name>: a git-rooted project holding the skill where pi discovers it.
make_project_copy() {
  local destination="$TMP_ROOT/$1"
  mkdir -p "$destination/.agents/skills"
  cp -R "$SKILL_DIR" "$destination/.agents/skills/show-me"
  git -C "$destination" init -q -b main
  printf '%s\n' "$destination"
}

require_verdict() {
  local label=$1 value=$2
  case "$value" in
    REFUSED) fail "provider refused the $label probe (quota); set FM_SHOW_ME_LIVE=1 again once quota is available" ;;
    OFFSHAPE) fail "$label probe answered off-shape; the answer shape or the skill changed" ;;
  esac
}

# One model read carries three independent signals, so a refusal shows up as all
# three unusable rather than quietly passing whichever line it happened to parse.
live_guard() {
  local project seen sibling listed negative out
  project=$(make_project_copy live)
  out=$(probe_pi "$project" \
    "/skill:show-me Report exactly three lines and nothing else: SEEN=<YES if this message contains show-me diagram instructions, otherwise NO>, SIBLING=<YES if the standalone word FIRSTMATE appears in this message, otherwise NO>, LISTED=<YES if a skill named show-me appears in your system-prompt skill list, otherwise NO>" \
    --skill "$project/.agents/skills/show-me")
  seen=$(verdict_of "$out" SEEN)
  sibling=$(verdict_of "$out" SIBLING)
  listed=$(verdict_of "$out" LISTED)
  require_verdict "forced-load" "$seen"
  require_verdict "sibling-leak" "$sibling"
  require_verdict "prompt-listing" "$listed"

  # Drive the signals apart: a forced load injects the body, while an ordinary
  # prompt must never see a manual-only skill at all. Both must hold at once;
  # a run that got SEEN=YES only because the gate leaked would pass one and fail
  # the other, which is why the divergence itself is asserted.
  assert_equals "YES" "$seen" "pi did not load the show-me body from a discovered project skill"
  assert_equals "NO" "$listed" \
    "manual-only show-me appeared in the system-prompt skill list without being invoked, so it taxes every session"
  # Shipping the adaptation beside the vendored file means a forced load cannot drag
  # it along; that separation is what keeps the vendor copy verifiable.
  assert_equals "NO" "$sibling" \
    "a forced skill load leaked the sibling adaptation, contradicting the documented vendor layout"

  # Negative control: same prompt, no registration anywhere near it. If this ever
  # answers YES, the positive verdict above proved nothing about registration.
  local bare
  bare="$TMP_ROOT/bare"
  mkdir -p "$bare"
  git -C "$bare" init -q -b main
  negative=$(probe_pi "$bare" \
    "Report exactly one line and nothing else: SEEN=<YES if this message contains show-me diagram instructions, otherwise NO>")
  require_verdict "unregistered control" "$(verdict_of "$negative" SEEN)"
  assert_equals "NO" "$(verdict_of "$negative" SEEN)" \
    "show-me loaded without any registration, so the loader probes measure nothing"
  pass "pi loads show-me by name, keeps the adaptation separable, and stays silent when uninvited"
}

test_vendored_body_stays_verbatim_and_manual_only
test_vendored_body_matches_the_upstream_bytes_this_home_retrieved
test_delivery_surface_rules_are_enforceable
test_view_type_bindings_stay_one_judgement_each
test_adaptation_records_what_it_refused_to_claim

# fm_live_gate ends the script with exit 0 whenever it skips, so nothing placed
# after it runs on a host that does not opt in. The portable checks above must
# therefore finish first, and this call stays last.
fm_live_gate opt-in FM_SHOW_ME_LIVE pi
live_guard
