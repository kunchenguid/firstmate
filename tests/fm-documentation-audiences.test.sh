#!/usr/bin/env bash
# Structural regressions for documentation audiences and agent-runtime skill registration.
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

test_technical_design_skill_registration() {
  python3 - "$ROOT" <<'PY' || fail "technical-design-docs metadata, discovery, or trigger registration is invalid"
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
skill_path = root / ".agents/skills/technical-design-docs/SKILL.md"
lines = skill_path.read_text(encoding="utf-8").splitlines()
assert lines[0] == "---"
end = lines.index("---", 1)
frontmatter: dict[str, object] = {}
index = 1
while index < end:
    line = lines[index]
    if not line.strip():
        index += 1
        continue
    assert not line.startswith((" ", "\t")) and ":" in line
    key, raw = line.split(":", 1)
    raw = raw.strip()
    if raw in {">", ">-", "|", "|-"}:
        index += 1
        value = []
        while index < end and (not lines[index].strip() or lines[index].startswith("  ")):
            if lines[index].strip():
                value.append(lines[index].strip())
            index += 1
        frontmatter[key] = " ".join(value)
        continue
    if raw == "":
        index += 1
        nested: dict[str, object] = {}
        while index < end and (not lines[index].strip() or lines[index].startswith("  ")):
            if lines[index].strip():
                nested_key, nested_raw = lines[index].strip().split(":", 1)
                nested[nested_key] = nested_raw.strip() == "true"
            index += 1
        frontmatter[key] = nested
        continue
    if raw in {"true", "false"}:
        frontmatter[key] = raw == "true"
    elif raw.startswith('"'):
        frontmatter[key] = json.loads(raw)
    else:
        frontmatter[key] = raw
    index += 1

name = frontmatter["name"]
description = frontmatter["description"]
assert name == skill_path.parent.name == "technical-design-docs"
assert isinstance(description, str) and 0 < len(description) <= 1024
assert re.search(r"\buse before\b", description, re.IGNORECASE)
assert frontmatter["user-invocable"] is False
assert frontmatter["metadata"] == {"internal": True}

discovered = [path for path in (root / ".agents/skills").glob("*/SKILL.md") if path.parent.name == name]
assert discovered == [skill_path]

agents = (root / "AGENTS.md").read_text(encoding="utf-8").splitlines()
start = agents.index("## 13. Agent-only reference skills") + 1
triggers: dict[str, str] = {}
for line in agents[start:]:
    if line.startswith("## "):
        break
    match = re.fullmatch(r"- `([a-z0-9-]+)` - (.+)", line)
    if match:
        assert match.group(1) not in triggers
        triggers[match.group(1)] = match.group(2)
assert name in triggers
assert triggers[name].lower().startswith("load before ")
PY
  pass "technical-design-docs is discoverable as an internal agent-only skill with a precise load trigger"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
test_technical_design_skill_registration
