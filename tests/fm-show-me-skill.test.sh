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
# probe_pi <cwd> <prompt> <destination>: one non-interactive pi turn in <cwd>, whose
# whole stream lands in <destination> for read-back. Two shapes matter and both were
# learned by getting them wrong: do not pass --no-context-files, which suppresses the
# very /skill: expansion under test, and write to a file rather than capturing stdout,
# because a command substitution around a backgrounded writer produced an empty read.
probe_pi() {
  local cwd=$1 prompt=$2 dest=$3
  (cd "$cwd" && env -u PI_SESSION_FILE pi --approve --mode json --print "$prompt" > "$dest" 2>&1)
}

# verdict_of <file> <label>: echo YES/NO for a labelled assistant line, or refuse.
verdict_of() {
  local file=$1 label=$2 out value
  [ -s "$file" ] || { printf 'EMPTY\n'; return; }
  out=$(cat "$file")
  if printf '%s' "$out" | grep -Eq "$REFUSAL_MARKERS"; then
    printf 'REFUSED\n'
    return
  fi
  value=$(printf '%s' "$out" | grep -o "${label}=[A-Za-z]*" | tail -1 | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
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
    EMPTY) fail "$label probe produced no output to read back; the probe wrote nothing, which is not a loader result" ;;
    OFFSHAPE) fail "$label probe answered off-shape; the answer shape or the skill changed" ;;
  esac
}

# injected_from_stream <file> [needle]: read back the delivered user message through
# tests/pi-stream-user-text.cjs, which knows why only a message event counts and why a
# serialized content array must be joined before matching. With a needle it prints
# FOUND or MISSING; without one it prints the text.
injected_from_stream() {
  local file=$1 needle=${2-}
  [ -s "$file" ] || { printf 'NOTFOUND\n'; return; }
  if [ -n "$needle" ]; then
    node "$ROOT/tests/pi-stream-user-text.cjs" "$file" "$needle" 2>/dev/null || printf 'READER_ERROR\n'
  else
    node "$ROOT/tests/pi-stream-user-text.cjs" "$file" 2>/dev/null || printf 'READER_ERROR\n'
  fi
}

# assert_skill_block <stream> <expect FOUND|MISSING> <message>: did the loader inject
# the show-me body? The quoted attribute form means prose about the command cannot
# produce this signal by itself.
assert_skill_block() {
  local file=$1 expect=$2 msg=$3
  assert_equals "$expect" "$(injected_from_stream "$file" '<skill name="show-me"')" "$msg"
}

# Deterministic shape: read back the first user message from the harness's own json
# stream instead of asking a model to self-report. Asking proved worthless twice -
# the same YES/NO prompt answered YES for a token that exists nowhere on the machine,
# while the character-count variant of it tracked real context correctly.
live_guard() {
  local project bare marker stream
  project=$(make_project_copy live)
  bare="$TMP_ROOT/bare"
  mkdir -p "$bare"
  git -C "$bare" init -q -b main

  marker=$(grep -o 'Body anchor SHOWME-BODY-TOKEN' "$project/.agents/skills/show-me/SKILL.md" | head -1)
  [ -n "$marker" ] || fail "the internal skill body no longer carries the visible body anchor the live guard needs"
  assert_no_grep "$marker" "$project/.agents/skills/show-me/FIRSTMATE.md" \
    "the anchor leaked into the sibling adaptation, so the two files are no longer separable"

  # Ruling 1a's acceptance core: does an internal .agents/skills copy load by discovery?
  stream="$TMP_ROOT/discover.json"
  probe_pi "$project" "/skill:show-me Reply with exactly one line and nothing else: DISCOVERED=<YES if the token $marker appears in this message, otherwise NO>" "$stream"
  # The marker lives only in the body's visible prose and is never typed into the
  # prompt, so FOUND for it means the discovered file was really injected. The quoted
  # attribute form is checked too because a missing name would make that injection luck.
  assert_equals "FOUND" "$(injected_from_stream "$stream" "$marker")" \
    "pi did not load the internal show-me skill from a project .agents/skills directory, so ruling 1a's loaded surface is unverified - report the raw output rather than relocating the file"
  assert_skill_block "$stream" FOUND \
    "the body arrived without an injected skill block naming show-me, so the load is unattributable"

  # Negative control: the same command where no such directory exists must not expand.
  # Without this, a positive above could be the harness echoing the question.
  stream="$TMP_ROOT/bare.json"
  probe_pi "$bare" "/skill:show-me Reply with exactly one line and nothing else: DISCOVERED=<YES if the token $marker appears in this message, otherwise NO>" "$stream"
  assert_skill_block "$stream" MISSING \
    "show-me expanded in a project holding no skill directory, so the discovery probe measured nothing"

  # Manual-only gate: the flag keeps the skill out of the prompt listing, so an
  # ordinary session pays nothing for it even though the file is discovered.
  stream="$TMP_ROOT/listing.json"
  probe_pi "$project" "Reply with exactly one line and nothing else: LISTED=<YES if a skill named show-me appears in your available skills listing, otherwise NO>" "$stream"
  case "$(injected_from_stream "$stream" '<name>show-me</name>')" in FOUND) fail "manual-only show-me appeared in the prompt listing without being invoked, so it taxes every session" ;;
    MISSING) pass "manual-only show-me stayed out of the system-prompt skill listing" ;;
    *) fail "the prompt-listing probe could not read its own stream" ;;
  esac

  # The public vendored body ships alone; loading the internal directory must not drag
  # the working note into the same injection, which is what keeps the vendor copy auditable.
  stream="$TMP_ROOT/sibling.json"
  probe_pi "$project" "/skill:show-me Reply with exactly one line and nothing else: SIBLING=<YES if the phrase Honest fallback shape appears in this message, otherwise NO>" "$stream"
  case "$(injected_from_stream "$stream" 'Separation anchor SHOWME-NOTE-ONLY')" in FOUND) fail "a forced skill load dragged the sibling working note along, contradicting the documented layout" ;;
    MISSING) pass "a forced load injected only the skill body, not the sibling working note" ;;
    *) fail "the sibling probe could not read its own stream" ;;
  esac
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
