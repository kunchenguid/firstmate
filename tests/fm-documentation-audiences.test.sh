#!/usr/bin/env bash
# Structural regression tests for the tracked documentation audience inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-doc-audience-check.sh"
INVENTORY="$ROOT/docs/documentation-audiences.json"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-doc-audiences.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# The check itself runs wherever Python 3 answers to either spelling, so the
# fixture mutations here resolve an interpreter the same two ways.
FIXTURE_PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null) \
  || fail "these tests need Python 3 on PATH as python3 or python"

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
  "$FIXTURE_PYTHON" - "$source" "$destination" "$mode" <<'PY'
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

# path_provides <search-path> <name>: true when <name> is executable somewhere on
# <search-path>. Plain file tests rather than `command -v` under a substituted
# PATH: that needs a subshell per entry, and on Windows the forks cost tens of
# seconds for a full-size PATH.
path_provides() {
  local search=$1 name=$2 entry outer_ifs=$IFS
  IFS=:
  for entry in $search; do
    IFS=$outer_ifs
    if [ -n "$entry" ] && { [ -x "$entry/$name" ] || [ -x "$entry/$name.exe" ]; }; then
      return 0
    fi
    IFS=:
  done
  IFS=$outer_ifs
  return 1
}

# path_without <dir> <name>...: echoes a search path that still carries the
# ordinary tools the check reaches for and genuinely provides none of <name>. A
# stub cannot express "this name does not exist", so the interpreter-resolution
# cases have to run against a path that really lacks the name, wherever the host
# installs it.
#
# Whole path entries are dropped rather than the search path being rebuilt from
# symlinks: a rebuilt path breaks on Windows, where MSYS symlinks are sysfiles a
# NATIVE child cannot execute - and the interpreter this fixture resolves spawns
# git natively. Any tool the pruning takes with it is restored as a symlink under
# <dir>, which only happens where the pruned name shares a directory with them.
path_without() {
  local dir=$1
  shift
  local names="$*"
  local kept="" entry name drop cmd resolved outer_ifs=$IFS
  mkdir -p "$dir"
  IFS=:
  for entry in $PATH; do
    IFS=$outer_ifs
    if [ -n "$entry" ]; then
      drop=
      for name in $names; do
        path_provides "$entry" "$name" && drop=1
      done
      [ -n "$drop" ] || kept="${kept:+$kept:}$entry"
    fi
    IFS=:
  done
  IFS=$outer_ifs
  for cmd in bash dirname git; do
    path_provides "$kept" "$cmd" && continue
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$dir/$cmd" ;; esac
  done
  printf '%s\n' "$dir:$kept"
}

test_interpreter_resolution() {
  local base="$TMP_ROOT/interpreter" real_python out rc
  local shim="$base/only-python" two="$base/python2" both="$base/both"
  mkdir -p "$shim" "$two" "$both"
  real_python=$(command -v python3 2>/dev/null || command -v python 2>/dev/null) \
    || fail "fixture needs Python 3 on PATH as python3 or python"

  # A shim rather than a symlink to the interpreter: the check execs it from
  # bash, and a Windows interpreter linked or copied out of its own install tree
  # cannot find its standard library.
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_python" > "$shim/python"
  chmod +x "$shim/python"
  cat > "$two/python" <<'SH'
#!/bin/sh
# Answers the version probe the way a Python 2 interpreter does. The check must
# refuse it by version rather than trust the spelling and exec a program whose
# source it cannot run.
printf '2.7'
SH
  chmod +x "$two/python"
  cp "$shim/python" "$both/python3"
  cat > "$both/python" <<'SH'
#!/bin/sh
# Poisoned: a host that has python3 must never reach the second spelling.
printf 'fallback-consulted\n' >&2
exit 127
SH
  chmod +x "$both/python"

  local no_python3 no_python
  no_python3=$(path_without "$base/no-python3" python3)
  no_python=$(path_without "$base/no-python" python3 python)

  out=$(PATH="$both:$no_python" "$CHECK" 2>&1) \
    || fail "check failed on a host that has python3"
  assert_contains "$out" "fm-doc-audience-check: ok surfaces=" \
    "python3 host did not validate the repository inventory"
  assert_not_contains "$out" "fallback-consulted" \
    "python3 host consulted the python fallback"

  out=$(PATH="$shim:$no_python3" "$CHECK") \
    || fail "check did not fall back to python on a host without python3"
  assert_contains "$out" "fm-doc-audience-check: ok surfaces=" \
    "python fallback did not validate the repository inventory"

  set +e
  out=$(PATH="$two:$no_python" "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "check accepted a Python 2 interpreter"
  assert_contains "$out" 'refusing "python": it is Python 2.7' \
    "Python 2 refusal did not name the interpreter and its version"

  set +e
  out=$(PATH="$no_python" "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "check ran with no Python interpreter on PATH"
  assert_contains "$out" 'tried "python3" then "python"' \
    "missing-interpreter failure did not name both spellings"
  assert_contains "$out" 'install Python 3 and expose it under either name' \
    "missing-interpreter failure was not actionable"
  pass "the check resolves python3 then a verified Python 3 python, and refuses anything else loudly"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
test_interpreter_resolution
