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

write_toolbelt_fixture() {
  local repo=$1
  mkdir -p "$repo/bin/backends" "$repo/docs"
  git -C "$repo" init -q
  printf '%s\n' '#!/bin/sh' > "$repo/bin/fm-present.sh"
  printf '%s\n' 'print("helper")' > "$repo/bin/backends/helper.py"
  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  printf '%s\n' '# Setup' > "$repo/docs/setup.md"
  printf '%s\n' '# Policy' > "$repo/docs/policy.md"
  printf '%s\n' '# Evidence' > "$repo/docs/evidence.md"
  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| [`fm-present.sh`](../bin/fm-present.sh) | Present entrypoint |
| `backends/helper.py` | Nested helper |
MD
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
    {"path": "docs/scripts.md", "audience": "operator-current"},
    {"path": "docs/setup.md", "audience": "operator-current"}
  ]
}
JSON
  git -C "$repo" add README.md docs bin
}

test_toolbelt_rows_match_tracked_bin() {
  local repo="$TMP_ROOT/toolbelt"
  local out
  write_toolbelt_fixture "$repo"
  out=$("$CHECK" --root "$repo") || fail "matching toolbelt rows were rejected"
  assert_contains "$out" "fm-doc-audience-check: ok surfaces=" \
    "matching toolbelt fixture did not pass"

  printf '%s\n' '#!/bin/sh' > "$repo/bin/fm-absent.sh"
  git -C "$repo" add bin/fm-absent.sh
  run_expect_failure "bin toolbelt coverage: missing rows: fm-absent.sh" \
    "$CHECK" --root "$repo"

  git -C "$repo" rm -fq bin/fm-absent.sh || fail "could not remove the extra bin fixture"
  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
| `backends/helper.py` | Nested helper |
| `fm-ghost.sh` | Names no file |
| `fm-present.sh` | Repeated row |
MD
  git -C "$repo" add docs/scripts.md
  run_expect_failure "bin toolbelt rows repeated: fm-present.sh" \
    "$CHECK" --root "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
| `backends/helper.py` | Nested helper |
| `fm-ghost.sh` | Names no file |
MD
  git -C "$repo" add docs/scripts.md
  run_expect_failure "rows without a tracked bin file: fm-ghost.sh" \
    "$CHECK" --root "$repo"
  pass "toolbelt rows must match tracked bin files exactly"
}

test_toolbelt_rows_require_purpose_and_backticks() {
  local repo="$TMP_ROOT/toolbelt-shape"
  write_toolbelt_fixture "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| [`fm-present.sh`](../bin/fm-present.sh) | Present entrypoint |
| `backends/helper.py` |
MD
  git -C "$repo" add docs/scripts.md
  run_expect_failure "bin toolbelt row missing purpose: backends/helper.py" \
    "$CHECK" --root "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| `fm-present.sh` |
| `backends/helper.py` | Nested helper |
MD
  git -C "$repo" add docs/scripts.md
  run_expect_failure "bin toolbelt row missing purpose: fm-present.sh" \
    "$CHECK" --root "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| [`fm-present.sh`](../bin/fm-present.sh) | Present entrypoint |
| `backends/helper.py` | Nested helper |
| fm-ghost.sh | Names no file |
MD
  git -C "$repo" add docs/scripts.md
  run_expect_failure "bin toolbelt row filename is not in backticks: fm-ghost.sh" \
    "$CHECK" --root "$repo"
  pass "toolbelt rows need a backticked filename and a non-empty purpose"
}

test_toolbelt_ignores_other_tables_and_pipe_examples() {
  local repo="$TMP_ROOT/toolbelt-other-tables"
  write_toolbelt_fixture "$repo"
  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

Other tables and pipe-prefixed examples are not toolbelt rows.

| Column | Note |
| --- | --- |
| `fm-present.sh` | Unrelated table must not count as a second row |
| fm-not-backticked.sh | Unrelated table must not be rejected |

```
| `fm-example.sh` | Pipe-prefixed example |
```

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
| `backends/helper.py` | Nested helper |

| `fm-later.sh` | Pipe-prefixed example after the table |

| Later | Column |
| --- | --- |
| `fm-ghost.sh` | Later table is outside the toolbelt |
MD
  git -C "$repo" add docs/scripts.md
  "$CHECK" --root "$repo" >/dev/null \
    || fail "unrelated tables and pipe-prefixed examples were treated as toolbelt rows"
  pass "only the toolbelt table contributes rows"
}

test_toolbelt_counts_rows_with_up_to_three_leading_spaces() {
  local repo="$TMP_ROOT/toolbelt-indent"
  write_toolbelt_fixture "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
   | `backends/helper.py` | Nested helper |
MD
  git -C "$repo" add docs/scripts.md
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a toolbelt row indented by three spaces was not counted"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
   | `fm-present.sh` | Indented duplicate |
| `backends/helper.py` | Nested helper |
MD
  git -C "$repo" add docs/scripts.md
  run_expect_failure "bin toolbelt rows repeated: fm-present.sh" \
    "$CHECK" --root "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
| `backends/helper.py` | Nested helper |
    | `fm-present.sh` | Four spaces is not a table row |
MD
  git -C "$repo" add docs/scripts.md
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a four-space pipe line was counted as a toolbelt row"
  pass "toolbelt rows may be indented by up to three spaces"
}

test_toolbelt_fenced_tables_cannot_hide_real_rows() {
  local repo="$TMP_ROOT/toolbelt-fences" fence mode expected
  write_toolbelt_fixture "$repo"
  for fence in '```' '~~~'; do
    for mode in valid missing extra duplicate; do
      python3 - "$repo/docs/scripts.md" "$fence" "$mode" <<'PYFIXTURE'
import sys
from pathlib import Path

path, fence, mode = sys.argv[1:]
header = "| Script | Purpose |\n| --- | --- |\n"
rows = ["| `fm-present.sh` | Present entrypoint |\n",
        "| `backends/helper.py` | Nested helper |\n"]
# Wrong delimiters and short runs must not close the indented fence.
other = "~~~" if fence[0] == "`" else "```"
example = ("   " + fence + fence[0] + " example\n" + other + "\n" +
           fence + "\n" + header + "".join(rows) +
           "   " + fence + fence[0] * 2 + "  \n\n")
if mode == "missing":
    rows.pop()
elif mode == "extra":
    rows.append("| `fm-ghost.sh` | Extra row |\n")
elif mode == "duplicate":
    rows.append(rows[0])
Path(path).write_text(example + "# The bin/ toolbelt\n\n" + example + header + "".join(rows))
PYFIXTURE
      case "$mode" in
        valid)
          "$CHECK" --root "$repo" >/dev/null             || fail "a $fence example was selected instead of the real table"
          continue ;;
        missing) expected="missing rows: backends/helper.py" ;;
        extra) expected="rows without a tracked bin file: fm-ghost.sh" ;;
        duplicate) expected="bin toolbelt rows repeated: fm-present.sh" ;;
      esac
      run_expect_failure "$expected" "$CHECK" --root "$repo"
    done
  done
  pass "backtick and tilde examples cannot hide missing, extra, or repeated toolbelt rows"
}

test_toolbelt_requires_one_unfenced_script_table() {
  local repo="$TMP_ROOT/toolbelt-candidates"
  write_toolbelt_fixture "$repo"
  python3 - "$repo/docs/scripts.md" <<'PYFIXTURE'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text("| Script | Note |\n| --- | --- |\n| unrelated | Example |\n\n" + path.read_text())
PYFIXTURE
  "$CHECK" --root "$repo" >/dev/null \
    || fail "an unrelated Script table before the toolbelt was selected"

  cat >> "$repo/docs/scripts.md" <<'MD'

## More tools

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Second candidate inside the section |
MD
  run_expect_failure "bin toolbelt table ambiguous: found 2 unfenced Script tables" \
    "$CHECK" --root "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

```markdown
| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Example |
```

| Column | Note |
| --- | --- |
| unrelated | Example |
MD
  run_expect_failure "bin toolbelt table missing: expected exactly one unfenced Script table"     "$CHECK" --root "$repo"
  write_toolbelt_fixture "$repo"
  cat >> "$repo/docs/scripts.md" <<'MD'

# Other section

| Script | Purpose |
| --- | --- |
| `fm-ghost.sh` | Outside the toolbelt section |
MD
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a Script table after the next level-one heading was selected"

  cat > "$repo/docs/scripts.md" <<'MD'
# The bin/ toolbelt

# Other section

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Outside the toolbelt section |
| `backends/helper.py` | Outside the toolbelt section |
MD
  run_expect_failure "bin toolbelt table missing: expected exactly one unfenced Script table" \
    "$CHECK" --root "$repo"

  cat > "$repo/docs/scripts.md" <<'MD'
```markdown
# The bin/ toolbelt
```

# Other section

| Script | Purpose |
| --- | --- |
| `fm-present.sh` | Present entrypoint |
| `backends/helper.py` | Nested helper |
MD
  run_expect_failure "bin toolbelt section missing: expected # The bin/ toolbelt" \
    "$CHECK" --root "$repo"
  pass "only one unfenced Script table inside the toolbelt section is accepted"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
test_toolbelt_rows_match_tracked_bin
test_toolbelt_rows_require_purpose_and_backticks
test_toolbelt_ignores_other_tables_and_pipe_examples
test_toolbelt_counts_rows_with_up_to_three_leading_spaces
test_toolbelt_fenced_tables_cannot_hide_real_rows
test_toolbelt_requires_one_unfenced_script_table
