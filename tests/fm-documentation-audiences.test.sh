#!/usr/bin/env bash
# Structural regression tests for the tracked documentation audience inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-doc-audience-check.sh"
INVENTORY="$ROOT/docs/documentation-audiences.json"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-doc-audiences.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

mutate_inventory() {
  local source=$1 destination=$2 mode=$3
  python3 - "$source" "$destination" "$mode" <<'PY'
import json
import sys
from pathlib import Path

source, destination, mode = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
if mode.name == "duplicate":
    data["surfaces"].append(dict(data["surfaces"][0]))
elif mode.name == "bad-setup-audience":
    for entry in data["surfaces"]:
        if entry["path"] == "docs/tmux-backend.md":
            entry["audience"] = "maintainer-verification"
            break
elif mode.name == "missing-owner-pointer":
    data["requiredOwnerPointers"][0] = {
        "source": "README.md",
        "target": "docs/sessionstart-nudge.md",
    }
elif mode.name == "shrink-scope":
    data["scope"]["trackedPatterns"] = ["README.md"]
elif mode.name == "missing-injection":
    del data["surfaces"][0]["injection"]
elif mode.name == "bad-injection":
    data["surfaces"][0]["injection"] = "sometimes"
elif mode.name == "missing-responsibility":
    del data["surfaces"][0]["responsibility"]
elif mode.name == "two-sentence-responsibility":
    data["surfaces"][0]["responsibility"] = "Owns one thing. It also owns another thing."
else:
    raise SystemExit(f"unknown mode: {mode.name}")
destination.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

test_repository_inventory_passes() {
  local out
  out=$("$CHECK") || fail "repository documentation audience check failed"
  assert_contains "$out" "fm-doc-audience-check: ok surfaces=" \
    "audience check did not report exact surface coverage"
  assert_contains "$out" "local_links=" \
    "audience check did not report local-link validation"
  pass "documentation inventory classifies every maintained prose surface exactly once"
}

test_duplicate_and_setup_classification_fail() {
  local duplicate="$TMP_ROOT/duplicate.json"
  local bad_setup="$TMP_ROOT/bad-setup.json"
  local shrink_scope="$TMP_ROOT/shrink-scope.json"
  mutate_inventory "$INVENTORY" "$duplicate" duplicate
  mutate_inventory "$INVENTORY" "$bad_setup" bad-setup-audience
  mutate_inventory "$INVENTORY" "$shrink_scope" shrink-scope
  run_expect_failure "surfaces classified more than once" \
    "$CHECK" --inventory "$duplicate"
  run_expect_failure "README setup target docs/tmux-backend.md has disallowed audience" \
    "$CHECK" --inventory "$bad_setup"
  run_expect_failure "scope.trackedPatterns must match the fixed maintained-prose scope" \
    "$CHECK" --inventory "$shrink_scope"
  pass "classification, setup routing, and maintained-prose scope fail safely"
}

test_injection_and_responsibility_are_required() {
  local missing_injection="$TMP_ROOT/missing-injection.json"
  local bad_injection="$TMP_ROOT/bad-injection.json"
  local missing_responsibility="$TMP_ROOT/missing-responsibility.json"
  local two_sentence="$TMP_ROOT/two-sentence.json"
  mutate_inventory "$INVENTORY" "$missing_injection" missing-injection
  mutate_inventory "$INVENTORY" "$bad_injection" bad-injection
  mutate_inventory "$INVENTORY" "$missing_responsibility" missing-responsibility
  mutate_inventory "$INVENTORY" "$two_sentence" two-sentence-responsibility
  run_expect_failure "unsupported injection" \
    "$CHECK" --inventory "$missing_injection"
  run_expect_failure "unsupported injection 'sometimes'" \
    "$CHECK" --inventory "$bad_injection"
  run_expect_failure "responsibility must be a non-empty one-sentence string" \
    "$CHECK" --inventory "$missing_responsibility"
  run_expect_failure "responsibility must be exactly one sentence" \
    "$CHECK" --inventory "$two_sentence"
  pass "every surface must declare a supported injection and exactly one sentence of responsibility"
}

test_always_loaded_set_is_queryable() {
  local always
  always=$(python3 - "$INVENTORY" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for entry in data["surfaces"]:
    if entry["injection"] == "always":
        print(entry["path"])
PY
) || fail "could not query the always-loaded set"
  assert_contains "$always" "AGENTS.md" \
    "the always-loaded set does not name the operating contract"
  # The always-loaded plane is the scarcest resource in the fleet; a surface
  # joining it should be a deliberate, visible review event, not a default.
  [ "$(printf '%s\n' "$always" | grep -c .)" -le 2 ] \
    || fail "the always-loaded prose set grew beyond AGENTS.md and its symlink alias"
  pass "the always-loaded prose set is a queryable list, not a claim"
}

test_required_pointer_fails() {
  local missing_pointer="$TMP_ROOT/missing-pointer.json"
  mutate_inventory "$INVENTORY" "$missing_pointer" missing-owner-pointer
  run_expect_failure "required owner pointer missing" \
    "$CHECK" --inventory "$missing_pointer"
  pass "required documentation owner pointers cannot silently disappear"
}

write_fixture_inventory() {
  local repo=$1
  cat > "$repo/docs/documentation-audiences.json" <<'JSON'
{
  "version": 1,
  "scope": {"trackedPatterns": ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]},
  "allowedAudiences": ["public-product", "operator-current", "maintainer-verification"],
  "allowedInjections": ["always", "lazy", "generated", "referenced", "never"],
  "setupAudiences": ["public-product", "operator-current"],
  "readmeSetupTargets": ["docs/setup.md"],
  "requiredOwnerPointers": [
    {"source": "README.md", "target": "docs/policy.md"}
  ],
  "surfaces": [
    {"path": "README.md", "audience": "public-product", "injection": "never",
     "responsibility": "Introduces the fixture product."},
    {"path": "docs/evidence.md", "audience": "maintainer-verification", "injection": "referenced",
     "responsibility": "Records fixture verification evidence."},
    {"path": "docs/policy.md", "audience": "operator-current", "injection": "referenced",
     "responsibility": "Owns the fixture policy."},
    {"path": "docs/setup.md", "audience": "operator-current", "injection": "referenced",
     "responsibility": "Owns fixture setup."}
  ]
}
JSON
}

test_local_links_and_no_keyword_heuristic() {
  local repo="$TMP_ROOT/fixture"
  mkdir -p "$repo/docs"
  git -C "$repo" init -q
  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  printf '%s\n' '# Setup' > "$repo/docs/setup.md"
  printf '%s\n' '# Policy' > "$repo/docs/policy.md"
  cat > "$repo/docs/evidence.md" <<'MD'
# Incident verification on 2026-07-23

```sh
/tmp/task-worktree/bin/tool --version
```

Observed version 1.2.3 on branch `fm/example`.
MD
  write_fixture_inventory "$repo"
  git -C "$repo" add README.md docs
  "$CHECK" --root "$repo" >/dev/null \
    || fail "structural checker rejected legitimate maintainer evidence prose"

  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md) [Broken](docs/missing.bin)' \
    > "$repo/README.md"
  git -C "$repo" add README.md
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"
  pass "local links resolve while dates, versions, commands, and incident prose remain semantically reviewed"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_injection_and_responsibility_are_required
test_always_loaded_set_is_queryable
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
