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

PUBLIC_DIR="$ROOT/skills/show-me"
INTERNAL_DIR="$ROOT/.agents/skills/show-me"
ADAPTATION="$INTERNAL_DIR/FIRSTMATE.md"
TMP_ROOT=$(fm_test_tmproot fm-show-me-skill)

# Upstream bytes as retrieved, recorded in the provenance file this repo ships.
# The private task copy is used when this home still has it; otherwise the pinned
# fingerprint alone proves the shipped body has not drifted.
UPSTREAM_SHA='434a2346cc95e313b0d367d477dda2e23ba642dd2181757415a09500664af100'

test_vendored_body_stays_verbatim_and_manual_only() {
  assert_present "$PUBLIC_DIR/SKILL.md" "vendored show-me SKILL.md is missing"
  assert_present "$PUBLIC_DIR/UPSTREAM.md" "show-me upstream provenance record is missing"
  assert_present "$PUBLIC_DIR/upstream-LICENSE.txt" "upstream license text is missing from the vendor copy"
  assert_present "$INTERNAL_DIR/SKILL.md" "internal loaded-surface show-me skill is missing"
  assert_present "$ADAPTATION" "show-me firstmate adaptation is missing"

  # Manual-only is the cost gate: widen it and the skill taxes every session.
  local front
  front=$(sed -n '/^---$/,/^---$/p' "$PUBLIC_DIR/SKILL.md")
  assert_contains "$front" "disable-model-invocation: true" \
    "vendored skill is no longer manual-only and would enter every system prompt"
  assert_contains "$front" "name: show-me" \
    "vendored skill lost its upstream name"
  local internal_front
  internal_front=$(sed -n '/^---$/,/^---$/p' "$INTERNAL_DIR/SKILL.md")
  assert_contains "$internal_front" "disable-model-invocation: true" \
    "internal adaptation is no longer manual-only, which contradicts the cost discipline it documents"

  pass "both surfaces ship manual-only and the adaptation lives outside the vendored body"
}

test_public_body_matches_the_upstream_bytes() {
  # Primary guard: the shipped public body must hash to the fingerprint recorded
  # beside it. This holds on every host and every CI runner.
  local actual
  actual=$(shasum -a 256 "$PUBLIC_DIR/SKILL.md" | cut -d' ' -f1)
  assert_equals "$UPSTREAM_SHA" "$actual" \
    "skills/show-me/SKILL.md is no longer byte-for-byte the retrieved upstream copy"

  # Where this home still holds the private retrieval copy, compare the real bytes
  # too, and prove the pinned fingerprint above still describes them.
  local retrieved
  retrieved="${FM_HOME:-$ROOT}/data/fm-show-me-skill/upstream/show-me.SKILL.md"
  if [ -f "$retrieved" ]; then
    cmp -s "$PUBLIC_DIR/SKILL.md" "$retrieved" \
      || fail "skills/show-me/SKILL.md differs from the upstream bytes this home retrieved"
    cmp -s "$PUBLIC_DIR/upstream-LICENSE.txt" "$(dirname "$retrieved")/upstream-LICENSE" \
      || fail "shipped license text differs from the upstream license this home retrieved"
    pass "public body and license match the retrieved upstream bytes exactly"
  else
    pass "public body matches the pinned upstream fingerprint (retrieval copy absent here)"
  fi
}

test_adaptation_points_at_the_public_body_it_does_not_rewrite() {
  # Ruling 1a: the adaptation references the vendored text instead of restating it,
  # so a rewrite of upstream prose cannot hide inside the adaptation.
  assert_grep 'skills/show-me/SKILL.md' "$ADAPTATION" \
    "adaptation no longer points at the public vendored body it is supposed to only reference"
  assert_grep 'byte-for-byte' "$ADAPTATION" \
    "adaptation stopped stating that the public body stays identical to upstream"
  local added
  added=$(diff "$PUBLIC_DIR/SKILL.md" "$ADAPTATION" | grep -c '^>' || true)
  [ "$added" -gt 0 ] || fail "adaptation adds nothing, so it cannot be the documented delivery surface"
  pass "adaptation references the verbatim body and only ever adds to it"
}

test_delivery_surface_rules_are_enforceable() {
  # The delivery contract: something reaches the captain, or the gap is said out loud.
  assert_grep 'send_image_to_wechat' "$ADAPTATION" \
    "adaptation names no image-delivery surface for a captain who reads chat"
  assert_grep 'Do not install npm or pip packages' "$ADAPTATION" \
    "adaptation no longer forbids buying a rendering dependency"
  assert_grep 'Never substitute a filesystem path' "$ADAPTATION" \
    "adaptation no longer treats an undelivered file path as delivery"
  assert_grep 'fall back to rank 2' "$ADAPTATION" \
    "adaptation lost the ordered fallback the surfaces rank against"
  # R3-3: rendered artifacts must not leave the local copy dirty.
  assert_grep 'mktemp -d' "$ADAPTATION" \
    "render recipe no longer works in a temporary directory"
  assert_grep 'rm -f scratchpad-show-me.png' "$ADAPTATION" \
    "render recipe no longer removes its working files"
  assert_grep 'untracked files count as dirt' "$ADAPTATION" \
    "render recipe no longer warns that leftover artifacts block landing"
  # shellcheck disable=SC2016 # Backticks are literal Markdown, not command substitution.
  assert_grep 'delete `.agents/skills/show-me/`' "$ADAPTATION" \
    "adaptation does not document how to stop the loaded skill cleanly"
  pass "delivery ranking, honesty fallback, self-cleaning render, and no-new-dependency rule are stated"
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

test_adaptation_separates_measured_claims_from_assumed_ones() {
  # A supported-looking claim about an unrun combination is the failure this guards.
  # Each needle below is a phrase this repo actually wrote once and had to retract,
  # so the assertion can fail: delete the sentence and grep still finds the wording.
  local unsupported
  for unsupported in 'is **not** one of those discovery locations' 'works on every harness' 'supports Claude Code'; do
    assert_no_grep "$unsupported" "$ADAPTATION" \
      "adaptation reasserts a discovery or support claim the measurement did not support: $unsupported"
  done
  assert_grep 'Unverified combinations' "$ADAPTATION" \
    "adaptation no longer separates measured facts from assumed ones"
  assert_grep 'do not describe these as supported' "$ADAPTATION" \
    "adaptation dropped the instruction that keeps unrun combinations unadvertised"
  pass "adaptation keeps unproven harness and discovery combinations out of its support claims"
}

# --- live guard ------------------------------------------------------------
# Everything below submits prompts to a real pi session. It answers the question
# the portable checks structurally cannot: does pi's loader actually honour the
# flag, inject only SKILL.md on a forced load, and stay silent when uninvited?

# Refusal shapes the provider actually emits, matched as whole words rather than
# loose substrings so an ordinary answer about rate limiting is not read as a block.
REFUSAL_MARKERS='insufficient_quota|exceeded_token_limit|"code": *"429"|status_code.*429'

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
  if printf '%s' "$out" | grep -Eq "$REFUSAL_MARKERS"; then
    printf 'REFUSED\n'
    return
  fi
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
  cp -R "$INTERNAL_DIR" "$destination/.agents/skills/show-me"
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
  local project marker seen sibling listed negative bare
  project=$(make_project_copy live)
  # The injected marker lives only inside the skill body. It is never typed into
  # the prompt, so the answer is a claim about what arrived, and any reply naming
  # it wrongly falsifies the assertion instead of confirming itself.
  marker=$(grep -o 'SHOWME-INJECTED-MARKER' "$project/.agents/skills/show-me/SKILL.md" | head -1)
  [ -n "$marker" ] || fail "the internal skill body no longer carries the injection marker the live guard needs"
  assert_no_grep "$marker" "$project/.agents/skills/show-me/FIRSTMATE.md" \
    "the marker leaked into the sibling adaptation, so SIBLING can no longer separate the two files"

  local out
  out=$(probe_pi "$project" \
    "/skill:show-me Report exactly three lines and nothing else: SEEN=<YES if the token $marker appears in this message, otherwise NO>, SIBLING=<YES if the token $marker appears in a file other than SKILL.md in this message, otherwise NO>, LISTED=<YES if a skill named show-me appears in your system-prompt skill list, otherwise NO>" \
    --skill "$project/.agents/skills/show-me")
  seen=$(verdict_of "$out" SEEN)
  sibling=$(verdict_of "$out" SIBLING)
  listed=$(verdict_of "$out" LISTED)
  require_verdict "forced-load" "$seen"
  require_verdict "sibling-leak" "$sibling"
  require_verdict "prompt-listing" "$listed"

  assert_equals "YES" "$seen" "pi did not load the show-me body from a discovered project skill"
  assert_equals "NO" "$listed" \
    "manual-only show-me appeared in the system-prompt skill list without being invoked, so it taxes every session"
  # Shipping the adaptation beside the vendored file means a forced load cannot drag
  # it along; that separation is what keeps the vendor copy verifiable.
  assert_equals "NO" "$sibling" \
    "a forced skill load dragged the sibling adaptation along, contradicting the documented layout"

  # Negative control: same prompt, no registration anywhere near it. If this ever
  # answers YES, the positive verdict above proved nothing about registration.
  bare="$TMP_ROOT/bare"
  mkdir -p "$bare"
  git -C "$bare" init -q -b main
  negative=$(probe_pi "$bare" \
    "Report exactly one line and nothing else: SEEN=<YES if the token $marker appears in this message, otherwise NO>")
  require_verdict "unregistered control" "$(verdict_of "$negative" SEEN)"
  assert_equals "NO" "$(verdict_of "$negative" SEEN)" \
    "show-me loaded without any registration, so the loader probes measure nothing"
  pass "pi loads show-me by name, keeps the adaptation separable, and stays silent when uninvited"
}

test_vendored_body_stays_verbatim_and_manual_only
test_public_body_matches_the_upstream_bytes
test_adaptation_points_at_the_public_body_it_does_not_rewrite
test_delivery_surface_rules_are_enforceable
test_view_type_bindings_stay_one_judgement_each
test_adaptation_separates_measured_claims_from_assumed_ones

# fm_live_gate ends the script with exit 0 whenever it skips, so nothing placed
# after it would run without ever failing; the live guard therefore stays last.
fm_live_gate opt-in FM_SHOW_ME_LIVE pi
live_guard
