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

write_skill_fixture() {
  local repo=$1 name=$2 invocable=$3
  mkdir -p "$repo/.agents/skills/$name"
  cat > "$repo/.agents/skills/$name/SKILL.md" <<MD
---
name: '$name'
description: >-
  Load for the fixture's original condition.
user-invocable: $invocable
metadata:
  internal: true
---

# $name
MD
}

make_skill_index_fixture() {
  local repo=$1 name
  mkdir -p "$repo/docs"
  git -C "$repo" init -q
  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  for name in setup policy evidence; do
    printf '# %s\n' "$name" > "$repo/docs/$name.md"
  done
  write_fixture_inventory "$repo"
  for name in alpha captain-hold-lifecycle agent-skill-trigger-index decision-hold-lifecycle; do
    write_skill_fixture "$repo" "$name" false
  done
  write_skill_fixture "$repo" ahoy true
  cat >> "$repo/.agents/skills/agent-skill-trigger-index/SKILL.md" <<'MD'

- [alpha](../alpha/SKILL.md)
- [captain-hold-lifecycle](../captain-hold-lifecycle/SKILL.md)
MD
  printf '\nRead captain-hold-lifecycle instead.\n' \
    >> "$repo/.agents/skills/decision-hold-lifecycle/SKILL.md"
  python3 - "$repo" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
inventory = root / "docs/documentation-audiences.json"
data = json.loads(inventory.read_text())
data["allowedAudiences"].append("agent-runtime")
data["surfaces"].extend(
    {"path": str(path.relative_to(root)), "audience": "agent-runtime"}
    for path in sorted(root.glob(".agents/skills/*/SKILL.md"))
)
inventory.write_text(json.dumps(data))
PY
  git -C "$repo" add .
}

test_skill_index_membership() {
  local repo="$TMP_ROOT/skill-membership" index
  make_skill_index_fixture "$repo"
  index="$repo/.agents/skills/agent-skill-trigger-index/SKILL.md"
  "$CHECK" --root "$repo" >/dev/null || fail "canonical directory with exclusions should pass"

  # A tracked new canonical skill must be indexed even though its audience is valid.
  write_skill_fixture "$repo" new-procedure false
  python3 - "$repo/docs/documentation-audiences.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["surfaces"].append({"path": ".agents/skills/new-procedure/SKILL.md", "audience": "agent-runtime"})
path.write_text(json.dumps(data))
PY
  git -C "$repo" add .agents/skills/new-procedure docs/documentation-audiences.json
  run_expect_failure "missing canonical skills: .agents/skills/new-procedure/SKILL.md" "$CHECK" --root "$repo"
  printf '\n- [new-procedure](../new-procedure/SKILL.md)\n' >> "$index"
  "$CHECK" --root "$repo" >/dev/null || fail "adding the missing owner link should pass"
  cp "$index" "$TMP_ROOT/skill-index.md"

  printf '\n- [alias](../alpha/./SKILL.md)\n' >> "$index"
  run_expect_failure "duplicate agent skill index membership" "$CHECK" --root "$repo"
  cp "$TMP_ROOT/skill-index.md" "$index"
  printf '\n- [missing](../missing/SKILL.md)\n' >> "$index"
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"
  cp "$TMP_ROOT/skill-index.md" "$index"

  local excluded
  for excluded in agent-skill-trigger-index decision-hold-lifecycle ahoy; do
    printf '\n- [%s](../%s/SKILL.md)\n' "$excluded" "$excluded" >> "$index"
    run_expect_failure "non-canonical members: .agents/skills/$excluded/SKILL.md" "$CHECK" --root "$repo"
    cp "$TMP_ROOT/skill-index.md" "$index"
  done
  pass "agent skill directory enforces complete, unique owner links and excludes self, redirect, and user skills"
}

test_skill_metadata_and_description_changes() {
  local repo="$TMP_ROOT/skill-metadata" skill mode
  make_skill_index_fixture "$repo"
  skill="$repo/.agents/skills/alpha/SKILL.md"
  cp "$skill" "$TMP_ROOT/alpha-original.md"
  for mode in missing-name wrong-name empty-description invalid-description invalid-invocable missing-internal invalid-internal duplicate-name no-frontmatter; do
    python3 - "$TMP_ROOT/alpha-original.md" "$skill" "$mode" <<'PY'
import sys
from pathlib import Path
source, destination, mode = sys.argv[1:]
text = Path(source).read_text()
changes = {
    "missing-name": ("name: 'alpha'\n", ""),
    "wrong-name": ("name: 'alpha'", "name: another-skill"),
    "empty-description": ("description: >-\n  Load for the fixture's original condition.", 'description: ""'),
    "invalid-description": ("description: >-\n  Load for the fixture's original condition.", 'description: [not, a, string]'),
    "invalid-invocable": ("user-invocable: false", 'user-invocable: "false"'),
    "missing-internal": ("  internal: true\n", ""),
    "invalid-internal": ("internal: true", "internal: false"),
    "duplicate-name": ("name: 'alpha'", "name: 'alpha'\nname: 'alpha'"),
    "no-frontmatter": ("---", ""),
}
old, new = changes[mode]
Path(destination).write_text(text.replace(old, new))
PY
    run_expect_failure "invalid skill metadata in .agents/skills/alpha/SKILL.md" "$CHECK" --root "$repo"
  done

  cat > "$skill" <<'MD'
---
metadata:
    internal: TRUE # normalized boolean
description: |-
  A completely different trigger, with no matching index edit.
  # This is description content.
name: "alpha"
user-invocable: False
---

# Alpha
MD
  "$CHECK" --root "$repo" >/dev/null || fail "description edits and equivalent metadata should pass"
  # Files not tracked by the repository must not expand the canonical inventory.
  write_skill_fixture "$repo" local-scratch false
  "$CHECK" --root "$repo" >/dev/null || fail "untracked skills must not affect directory membership"
  pass "required skill metadata fails safely while descriptions, formatting, and untracked skills do not change membership"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
test_skill_index_membership
test_skill_metadata_and_description_changes
