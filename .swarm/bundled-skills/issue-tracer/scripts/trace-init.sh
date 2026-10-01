#!/usr/bin/env bash
# trace-init.sh — initialize an issue-tracer trace directory (issue-tracer).
#
# Creates .agents/issue-traces/<slug>/ at the repo root and ensures that path is
# excluded from version control via .git/info/exclude — a LOCAL exclusion, never
# a tracked .gitignore edit inside a fix PR. Idempotent.
#
# Usage:
#   trace-init.sh <issue-slug>
set -eu
# Force the C locale: POSIX bracket-range collation (e.g. [a-z]) is
# locale-dependent, not fixed-ASCII. Under some runner locales (observed on
# macOS CI), "dictionary order" collation makes [a-z] also match uppercase
# letters, silently defeating the slug allowlist below. C locale guarantees
# strict ASCII-only ranges regardless of the invoking environment.
export LC_ALL=C

# Native Git for Windows prints drive-qualified paths (C:/...) even when it is
# invoked from MSYS/Git Bash. Coreutils do not consistently interpret that form
# as absolute in restricted/non-login shells, so normalize Git-reported paths
# before passing them to cd, mkdir, or redirection. POSIX hosts are unchanged.
to_shell_path() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
        return
      fi
      ;;
  esac
  printf '%s\n' "$1"
}

slug="${1:-}"
if [ -z "$slug" ]; then
  echo "usage: trace-init.sh <issue-slug>" >&2
  exit 2
fi

# Positive allowlist: lowercase alphanumeric and '-' only. This also rejects
# '/', '\', '..', '.', shell metacharacters, and whitespace, since none of
# those characters are in the allowed set — a slug that fails this check can
# never traverse a path or be misread as a shell option/argument elsewhere
# the slug is embedded (e.g. `git switch -c fix/<issue-slug>`).
case "$slug" in
  *[!a-z0-9-]*)
    echo "trace-init: invalid slug — lowercase alphanumeric and '-' only: $slug" >&2
    exit 2
    ;;
esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "trace-init: not inside a git work tree — run this from within the target repository" >&2
  exit 2
}
root="$(to_shell_path "$root")"
root_real="$(cd "$root" && pwd -P)"
trace_dir="$root/.agents/issue-traces/$slug"

# The validators deliberately reject symlinks in the `.agents/issue-traces`
# ancestry, even when a link resolves back inside this repository. Refuse the
# same components before any state, manifest, or exclude-file write so init can
# never create a trace that later validators cannot read.
refuse_symlinked_agents_components() {
  local component component_real
  for component in \
    "$root/.agents" \
    "$root/.agents/issue-traces" \
    "$trace_dir"; do
    if [ -L "$component" ]; then
      # Keep the established outside-repo diagnostic below, but reject links
      # that resolve back inside the repository because validators reject those
      # path components too. A dangling link is also fail-closed here.
      if component_real="$(cd "$component" 2>/dev/null && pwd -P)"; then
        case "$component_real" in
          "$root_real"|"$root_real"/*)
            echo "trace-init: refusing symlinked .agents component: $component" >&2
            exit 2
            ;;
        esac
      else
        echo "trace-init: refusing symlinked .agents component: $component" >&2
        exit 2
      fi
    fi
  done
}
refuse_symlinked_agents_components

# Reject a symlink escape before creating anything: walk up from trace_dir to
# the nearest existing ancestor (e.g. an already-committed `.agents` that is
# actually a symlink to outside the repo) and verify it resolves inside the
# repo root. `mkdir -p` happily follows an existing symlinked ancestor, so
# this check MUST run before mkdir -p, not after.
check_dir="$trace_dir"
while [ ! -e "$check_dir" ]; do
  check_dir="$(dirname "$check_dir")"
done
check_real="$(cd "$check_dir" && pwd -P)"
case "$check_real" in
  "$root_real" | "$root_real"/*) ;;
  *)
    echo "trace-init: refusing to create trace dir — existing path '$check_dir' resolves to '$check_real', outside the repo root '$root_real' (likely a symlink escape)" >&2
    exit 2
    ;;
esac

mkdir -p "$trace_dir"

# Re-verify after creation: mkdir -p only creates the components that did not
# already exist, so this catches nothing new versus the pre-check above, but
# it is cheap defense-in-depth against the trace dir itself having become a
# symlink between the check and the mkdir.
trace_dir_real="$(cd "$trace_dir" && pwd -P)"
case "$trace_dir_real" in
  "$root_real" | "$root_real"/*) ;;
  *)
    echo "trace-init: trace dir '$trace_dir' resolved to '$trace_dir_real', outside the repo root '$root_real'; aborting" >&2
    exit 2
    ;;
esac

# Ensure the trace root is excluded locally.
#
# Use --git-common-dir, not --absolute-git-dir: in a linked worktree,
# --absolute-git-dir resolves to the worktree-private admin dir, which
# `git status --ignored` / `git check-ignore` do not consult for exclude
# rules — those read info/exclude from the shared common dir. Prefer
# --path-format=absolute (git >= 2.31) so the result is unambiguous; fall
# back to the plain form (resolved against cwd) on older git. Mirrors the
# fix in src/knowledge/cohort-identity.ts (issue #1846, PR #1851).
git_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || git_dir=""
if [ -z "$git_dir" ]; then
  git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || {
    echo "trace-init: could not resolve the git directory" >&2
    exit 2
  }
  git_dir="$(to_shell_path "$git_dir")"
  case "$git_dir" in
    /*) ;; # already absolute
    *) git_dir="$(pwd)/$git_dir" ;;
  esac
else
  git_dir="$(to_shell_path "$git_dir")"
fi
exclude_file="$git_dir/info/exclude"
entry='.agents/issue-traces/'
mkdir -p "$(dirname "$exclude_file")"
# Refuse to redirect into a pre-existing non-regular exclude-file path (e.g. a
# symlink). `[ ! -e ]` alone is not enough: a dangling symlink reports
# non-existent (dereferenced) while a bare `>>` still follows the link and
# writes through it to whatever it points at.
if [ -L "$exclude_file" ] || { [ -e "$exclude_file" ] && [ ! -f "$exclude_file" ]; }; then
  echo "trace-init: refusing non-regular target: $exclude_file" >&2
  exit 2
fi
if [ ! -f "$exclude_file" ] || ! grep -qxF "$entry" "$exclude_file" 2>/dev/null; then
  printf '%s\n' "$entry" >> "$exclude_file"
fi

# Resolve the base identity before seeding state. Prefer the remote's declared
# default branch, then use the same conservative fallbacks as scan-deferred.
base_ref=""
if symbolic_ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
  base_ref="origin/${symbolic_ref#refs/remotes/origin/}"
fi
if [ -z "$base_ref" ]; then
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
      base_ref="$candidate"
      break
    fi
  done
fi
base_sha="unset"
if [ -n "$base_ref" ]; then
  base_sha="$(git rev-parse "$base_ref^{commit}")"
else
  base_ref="unset"
fi

# Use a disposable index so the identity includes tracked and untracked source
# changes without touching the caller's real index. The trace directory is
# removed from the disposable index explicitly (same recipe as trace-check.sh
# tree-id), so it cannot affect the result even without the exclude entry.
tree_index="$(mktemp "${TMPDIR:-/tmp}/issue-tracer-index.XXXXXX")"
rm -f "$tree_index"
phase0_tree_id=""
if phase0_tree_id="$(GIT_INDEX_FILE="$tree_index" git -C "$root" read-tree HEAD && GIT_INDEX_FILE="$tree_index" git -C "$root" add -A -- . && GIT_INDEX_FILE="$tree_index" git -C "$root" rm -r --cached --ignore-unmatch -q -- .agents/issue-traces && GIT_INDEX_FILE="$tree_index" git -C "$root" write-tree)"; then
  :
else
  rm -f "$tree_index"
  echo "trace-init: could not calculate phase-0 tree identity" >&2
  exit 2
fi
rm -f "$tree_index"

# Seed state.md so the trail has a resumable starting point.
state_file="$trace_dir/state.md"
# Refuse to redirect into a pre-existing non-regular state.md path (e.g. a
# symlink). `[ ! -e ]` alone is not enough: a dangling symlink reports
# non-existent (dereferenced) while a bare `>` still follows the link and
# writes through it to whatever it points at.
if [ -L "$state_file" ] || { [ -e "$state_file" ] && [ ! -f "$state_file" ]; }; then
  echo "trace-init: refusing non-regular target: $state_file" >&2
  exit 2
fi
if [ ! -e "$state_file" ]; then
  cat > "$state_file" <<EOF
# Trace State: $slug
protocol: 3.0.0
phase: 0
tier: unset
classification: unset
base-ref: $base_ref
base-sha: $base_sha
freshness: unset
phase0-tree-id: $phase0_tree_id
checkpoint-tree-id: unset
handshake: unset
tools: none
merge: not-applicable
next-action: unset

## Gates
| gate | verdict | reviewed-commit | tree-id | artifact |
|---|---|---|---|---|
EOF
fi

repro_dir="$trace_dir/repro"
manifest_file="$repro_dir/checkpoint.manifest"
if [ -L "$repro_dir" ]; then
  echo "trace-init: refusing to use 'repro/' - it is a symlink" >&2
  exit 2
fi
mkdir -p "$repro_dir"
if [ -L "$repro_dir" ]; then
  echo "trace-init: refusing to use 'repro/' - it is a symlink" >&2
  exit 2
fi
# Refuse to redirect into a pre-existing non-regular manifest path (e.g. a
# symlink). `[ ! -e ]` alone is not enough: a broken symlink reports
# non-existent (dereferenced) while a bare `>` still follows the link and
# writes through it to whatever it points at.
if { [ -e "$manifest_file" ] && [ ! -f "$manifest_file" ]; } || [ -L "$manifest_file" ]; then
  echo "trace-init: refusing non-regular target: $manifest_file" >&2
  exit 2
fi
if [ ! -e "$manifest_file" ]; then
  # The header carries the expected data-row count, restamped by every
  # `repro-check.sh checkpoint` append. Seeding it without `rows=0` would make
  # repro-check refuse the manifest: a header with no count is rejected there so it
  # cannot be used to disable the count check (see validate_manifest).
  printf '%s\n' '# issue-tracer checkpoint manifest v1 rows=0' > "$manifest_file"
fi

echo "trace-init: created $trace_dir"
echo "trace-init: ensured '$entry' in $exclude_file"
