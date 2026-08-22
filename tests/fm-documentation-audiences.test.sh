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
elif mode.name == "linktext-without-fragment":
    for pointer in data["requiredOwnerPointers"]:
        if pointer["target"] == "bin/fm-search.sh":
            pointer["linkText"] = "search script"
            break
elif mode.name == "shrink-scope":
    data["scope"]["trackedPatterns"] = ["README.md"]
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

test_required_pointer_fails() {
  local missing_pointer="$TMP_ROOT/missing-pointer.json"
  mutate_inventory "$INVENTORY" "$missing_pointer" missing-owner-pointer
  run_expect_failure "required owner pointer missing" \
    "$CHECK" --inventory "$missing_pointer"
  pass "required documentation owner pointers cannot silently disappear"
}

test_linktext_without_fragment_fails() {
  local orphan_label="$TMP_ROOT/orphan-label.json"
  mutate_inventory "$INVENTORY" "$orphan_label" linktext-without-fragment
  run_expect_failure "linkText requires fragment" \
    "$CHECK" --inventory "$orphan_label"
  pass "an owner pointer cannot carry a linkText label without the fragment that enforces it"
}

write_fixture_inventory() {
  local repo=$1
  cat > "$repo/docs/documentation-audiences.json" <<'JSON'
{
  "version": 1,
  "scope": {"trackedPatterns": ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]},
  "allowedAudiences": ["public-product", "operator-current", "maintainer-verification"],
  "setupAudiences": ["public-product", "operator-current"],
  "readmeSetupTargets": ["docs/setup.md"],
  "requiredOwnerPointers": [
    {"source": "README.md", "target": "docs/policy.md"}
  ],
  "surfaces": [
    {"path": "README.md", "audience": "public-product"},
    {"path": "docs/evidence.md", "audience": "maintainer-verification"},
    {"path": "docs/policy.md", "audience": "operator-current"},
    {"path": "docs/setup.md", "audience": "operator-current"}
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

write_pointer_fixture() {
  local repo=$1
  mkdir -p "$repo/docs" "$repo/bin"
  git -C "$repo" init -q
  printf '%s\n' '#!/usr/bin/env bash' > "$repo/bin/fm-search.sh"
  printf '%s\n' '# README

[Configuration](docs/configuration.md)' > "$repo/README.md"
  cat > "$repo/AGENTS.md" <<'MD'
# AGENTS

Specific entries resolve through [operational home layout and state](docs/configuration.md#operational-home-layout-and-state) and the producing script headers named there.
Metadata entries also resolve through [docs/configuration.md](docs/configuration.md#operational-home-layout-and-state).
Three state families must never be touched directly; see [docs/configuration.md](docs/configuration.md#agent-private-state-never-touch) for the prohibition.
To search that private and hidden corpus, use bin/fm-search.sh; docs/configuration.md "Local knowledge search" owns it.
MD
  cat > "$repo/docs/configuration.md" <<'MD'
# Configuration

## Operational home layout and state

Owner of the top-level contract.

### Agent-private state (never touch)

Three state families are agent-private runtime machinery.
MD
  cat > "$repo/docs/documentation-audiences.json" <<'JSON'
{
  "version": 1,
  "scope": {"trackedPatterns": ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]},
  "allowedAudiences": ["public-product", "operator-current", "operator-example", "maintainer-architecture", "maintainer-verification", "agent-runtime"],
  "setupAudiences": ["public-product", "operator-current", "operator-example"],
  "readmeSetupTargets": ["docs/configuration.md"],
  "requiredOwnerPointers": [
    {"source": "AGENTS.md", "target": "docs/configuration.md", "fragment": "operational-home-layout-and-state", "linkText": "operational home layout and state"},
    {"source": "AGENTS.md", "target": "docs/configuration.md", "fragment": "agent-private-state-never-touch"},
    {"source": "AGENTS.md", "target": "bin/fm-search.sh"}
  ],
  "surfaces": [
    {"path": "README.md", "audience": "public-product"},
    {"path": "AGENTS.md", "audience": "agent-runtime"},
    {"path": "docs/configuration.md", "audience": "operator-current"}
  ]
}
JSON
  git -C "$repo" add README.md AGENTS.md docs bin
}

remove_line_containing() {
  local file=$1 needle=$2
  grep -v -F -- "$needle" "$file" > "$file.tmp" && mv -f -- "$file.tmp" "$file"
}

test_anchored_owner_pointer_pins_collapsed_block() {
  local repo="$TMP_ROOT/pointer-fixture"
  write_pointer_fixture "$repo"
  "$CHECK" --root "$repo" >/dev/null \
    || fail "anchored owner-pointer contract rejected the intact collapsed block"
  [ "$(grep -Fc 'docs/configuration.md#operational-home-layout-and-state' "$repo/AGENTS.md")" -eq 2 ] \
    || fail "pointer fixture did not reproduce the duplicate layout fragment"
  remove_line_containing "$repo/AGENTS.md" "[operational home layout and state](docs/configuration.md#operational-home-layout-and-state)"
  git -C "$repo" add AGENTS.md
  run_expect_failure "required owner pointer missing: AGENTS.md -> docs/configuration.md#operational-home-layout-and-state" \
    "$CHECK" --root "$repo"
  pass "deleting only the layout pointer fails while the duplicate metadata fragment remains"
}

test_never_touch_stub_is_pinned() {
  local repo="$TMP_ROOT/stub-fixture"
  write_pointer_fixture "$repo"
  remove_line_containing "$repo/AGENTS.md" "agent-private-state-never-touch"
  git -C "$repo" add AGENTS.md
  run_expect_failure "required owner pointer missing: AGENTS.md -> docs/configuration.md#agent-private-state-never-touch" \
    "$CHECK" --root "$repo"
  pass "deleting the never-touch safety stub fails the anchored owner-pointer contract"
}

test_local_search_pointer_is_pinned() {
  local repo="$TMP_ROOT/search-pointer-fixture"
  write_pointer_fixture "$repo"
  "$CHECK" --root "$repo" >/dev/null \
    || fail "local search owner pointer rejected while intact"
  remove_line_containing "$repo/AGENTS.md" "bin/fm-search.sh"
  git -C "$repo" add AGENTS.md
  run_expect_failure "required owner pointer missing: AGENTS.md -> bin/fm-search.sh" \
    "$CHECK" --root "$repo"
  pass "deleting the local search pointer fails the owner-pointer contract"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_linktext_without_fragment_fails
test_local_links_and_no_keyword_heuristic
test_anchored_owner_pointer_pins_collapsed_block
test_never_touch_stub_is_pinned
test_local_search_pointer_is_pinned
