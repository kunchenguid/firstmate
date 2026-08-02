#!/usr/bin/env bash
# Shared Treehouse lease authority helpers.
#
# Consumers may prove that one exact worktree is durably leased to one exact
# holder, or resolve the unique leased worktree for an exact project and holder.
# The latter is intentionally narrow: it walks only Git's registered worktrees
# for the trusted project and refuses zero or multiple matches.

fm_treehouse_state_for_worktree() {  # <worktree>
  local worktree=$1 slot pool state
  worktree=$(fm_checkout_trusted_dir "$worktree") || return 1
  slot=$(fm_checkout_trusted_dir "$(dirname "$worktree")") || return 1
  pool=$(fm_checkout_trusted_dir "$(dirname "$slot")") || return 1
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  printf '%s\n' "$state"
}

fm_treehouse_require_task_lease() {  # <worktree> <expected-holder>
  local worktree=$1 expected_holder=$2 state
  worktree=$(fm_checkout_trusted_dir "$worktree") || {
    echo "error: Treehouse worktree is unavailable or redirected: $1" >&2
    return 1
  }
  state=$(fm_treehouse_state_for_worktree "$worktree") || {
    echo "error: cannot resolve authoritative Treehouse state for $worktree" >&2
    return 1
  }
  python3 - "$state" "$worktree" "$expected_holder" <<'PY'
import json
import os
import sys

state_path, expected_path, expected_holder = sys.argv[1:]
try:
    with open(state_path, encoding="utf-8") as stream:
        state = json.load(stream)
    worktrees = state["worktrees"]
    if not isinstance(worktrees, list):
        raise TypeError("worktrees must be an array")
    matches = []
    for entry in worktrees:
        if not isinstance(entry, dict):
            continue
        path = entry.get("path")
        if not isinstance(path, str) or not path:
            continue
        if os.path.realpath(path) == expected_path:
            matches.append(entry)
    if len(matches) != 1:
        raise ValueError("expected exactly one matching worktree entry")
    entry = matches[0]
    if entry.get("leased") is not True:
        raise ValueError("worktree is not durably leased")
    if entry.get("lease_holder") != expected_holder:
        raise ValueError(
            f"lease holder is {entry.get('lease_holder')!r}, expected {expected_holder!r}"
        )
    if entry.get("destroying") is True:
        raise ValueError("worktree is already being destroyed")
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
    print(
        f"error: Treehouse ownership for {expected_path} is unprovable: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

fm_treehouse_find_task_lease() {  # <project> <expected-holder>
  local project=$1 expected_holder=$2 listed line candidate common project_common
  local matches=0 match=
  project=$(fm_checkout_trusted_dir "$project") || return 1
  [ "$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)" = "$project" ] || return 1
  project_common=$(fm_checkout_git_common_dir "$project") || return 1
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        candidate=$(fm_checkout_trusted_dir "${line#worktree }" 2>/dev/null || true)
        [ -n "$candidate" ] || continue
        [ "$candidate" != "$project" ] || continue
        common=$(fm_checkout_git_common_dir "$candidate" 2>/dev/null || true)
        [ "$common" = "$project_common" ] || continue
        if fm_treehouse_require_task_lease "$candidate" "$expected_holder" >/dev/null 2>&1; then
          matches=$((matches + 1))
          match=$candidate
        fi
        ;;
    esac
  done <<EOF
$listed
EOF
  case "$matches" in
    1) printf '%s\n' "$match" ;;
    0)
      echo "error: no Treehouse lease exists for $expected_holder in $project" >&2
      return 2
      ;;
    *)
      echo "error: multiple Treehouse leases exist for $expected_holder in $project" >&2
      return 3
      ;;
  esac
}

fm_treehouse_prove_task_lease_absent() {  # <recorded-worktree> <expected-holder>
  local recorded_worktree=$1 expected_holder=$2 slot pool state
  [ -n "$recorded_worktree" ] || return 1
  slot=$(dirname "$recorded_worktree")
  pool=$(fm_checkout_trusted_dir "$(dirname "$slot")") || return 1
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  python3 - "$state" "$expected_holder" <<'PY'
import json
import os
import sys

state_path, expected_holder = sys.argv[1:]
try:
    with open(state_path, encoding="utf-8") as stream:
        state = json.load(stream)
except OSError as error:
    print(
        f"error: Treehouse lease absence for {expected_holder} is unprovable: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
except json.JSONDecodeError as error:
    print(
        f"error: authoritative Treehouse lease state is corrupt: {error}",
        file=sys.stderr,
    )
    raise SystemExit(2)

try:
    worktrees = state["worktrees"]
    if not isinstance(worktrees, list):
        raise TypeError("worktrees must be an array")
    seen_paths = set()
    for entry in worktrees:
        if not isinstance(entry, dict):
            raise TypeError("worktree entry must be an object")
        path = entry.get("path")
        leased = entry.get("leased")
        holder = entry.get("lease_holder")
        destroying = entry.get("destroying", False)
        if (
            not isinstance(path, str)
            or not path.strip()
            or "\0" in path
            or not os.path.isabs(path)
        ):
            raise TypeError("worktree path must be a non-empty absolute string")
        canonical_path = os.path.realpath(path)
        if canonical_path in seen_paths:
            raise TypeError("worktree paths must be unique")
        seen_paths.add(canonical_path)
        if not isinstance(leased, bool):
            raise TypeError("leased must be a boolean")
        if not isinstance(destroying, bool):
            raise TypeError("destroying must be a boolean when present")
        if destroying:
            raise ValueError("Treehouse state contains a worktree being destroyed")
        if leased:
            if not isinstance(holder, str) or not holder.strip():
                raise TypeError("leased worktree holder must be a non-empty string")
            if holder == expected_holder:
                raise ValueError("matching Treehouse lease still exists")
        elif holder not in (None, ""):
            raise TypeError("returned worktree holder must be null or empty")
except ValueError as error:
    print(
        f"error: Treehouse lease absence for {expected_holder} is unprovable: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
except (TypeError, KeyError) as error:
    print(
        f"error: authoritative Treehouse lease state is corrupt: {error}",
        file=sys.stderr,
    )
    raise SystemExit(2)
PY
}
