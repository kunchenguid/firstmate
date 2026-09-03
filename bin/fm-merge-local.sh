#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
#
# Context-contract gate (landing-only): when the branch carries project-code
# changes for a KNOWN slug (explicit repo->slug map below), the slug's detail
# record must exist in the home's data/projects/ dir as exactly 7 lines: YAML
# frontmatter with the 4 keys (milestone/focus/blocker/next_move) as plain
# scalars, then one body line carrying an authoritative source pointer - a
# URL (http/https/file) or a path token that resolves to an existing file
# (relative candidates are checked under the record dir, FM_HOME, and the
# project repo). http/https URLs are accepted on shape; file URLs must
# resolve to an existing file like path tokens do; otherwise the landing
# is REFUSED. Non-code assets (README,
# docs, LICENSE, metadata dotfiles, lockfiles, images) do not count as
# project-code touches. The record lives in FM_HOME, outside the project repo, so it can
# never appear in the branch diff itself: the worker refreshes that record
# before landing and this gate verifies its presence here. Repos outside the
# map warn and proceed. Teardown/cleanup paths are never gated by this script:
# it only lands, it never cleans up.
# Detail-dir override for tests: FM_DETAIL_DIR_OVERRIDE (default
# "$FM_HOME/data/projects").
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# Context-contract gate: repo basename -> known slug. Unknown repos warn only.
slug_for_repo() {
  case "$1" in
    lia) printf 'lia-core' ;;
    lia-mascot) printf 'lia-mascot' ;;
    kg-hpmor) printf 'kg-hpmor' ;;
    *) return 1 ;;
  esac
}

project_code_diff() {
  git -C "$PROJ" diff --name-only "$DEFAULT...$BRANCH" -- \
    . \
    ':(exclude)README*' \
    ':(exclude)**/README*' \
    ':(exclude)docs/**' \
    ':(exclude)**/docs/**' \
    ':(exclude)LICENSE*' \
    ':(exclude)CONTRIBUTING*' \
    ':(exclude)CODE_OF_CONDUCT*' \
    ':(exclude)SECURITY*' \
    ':(exclude)CODEOWNERS' \
    ':(exclude).gitignore' \
    ':(exclude).gitattributes' \
    ':(exclude).editorconfig' \
    ':(exclude).gitkeep' \
    ':(exclude)*.lock' \
    ':(exclude)*.lockb' \
    ':(exclude)package-lock.json' \
    ':(exclude)pnpm-lock.yaml' \
    ':(exclude)go.sum' \
    ':(exclude)*.png' \
    ':(exclude)*.jpg' \
    ':(exclude)*.jpeg' \
    ':(exclude)*.gif' \
    ':(exclude)*.svg' \
    ':(exclude)*.ico' \
    ':(exclude)*.webp' \
    ':(exclude)*.avif' \
    ':(exclude)*.bmp'
}

detail_frontmatter_has_key() {
  local detail_file=$1 key=$2
  awk -v key="$key" '
    NR >= 2 && NR <= 5 && $0 ~ ("^" key ":[[:space:]]+") { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$detail_file"
}

detail_record_is_current() {
  local detail_file=$1
  [ -f "$detail_file" ] || return 1
  awk '
    BEGIN {
      valid = 1
      body_ok = 0
      double_quote = sprintf("%c", 34)
      single_quote = sprintf("%c", 39)
      non_plain_leaders = "[{>|&*!%@`,]"
    }
    function field_is_valid(line, key, value, prefix, c) {
      prefix = "^" key ":[[:space:]]+"
      if (line !~ prefix) return 0
      value = line
      sub(prefix, "", value)
      if (value == "") return 0
      if (value == double_quote double_quote || value == single_quote single_quote) return 0
      c = substr(value, 1, 1)
      if (c == double_quote || c == single_quote) {
        return length(value) >= 2 && substr(value, length(value), 1) == c
      }
      if (c == "#") return 0
      if (index(non_plain_leaders, c)) return 0
      return 1
    }
    NR == 1 { if ($0 != "---") valid=0; next }
    NR == 2 { if (!field_is_valid($0, "milestone")) valid=0; next }
    NR == 3 { if (!field_is_valid($0, "focus")) valid=0; next }
    NR == 4 { if (!field_is_valid($0, "blocker")) valid=0; next }
    NR == 5 { if (!field_is_valid($0, "next_move")) valid=0; next }
    NR == 6 { if ($0 != "---") valid=0; next }
    NR == 7 {
      if ($0 != "" && $0 !~ /^(milestone|focus|blocker|next_move):([[:space:]]|$)/) body_ok=1
      else valid=0
      next
    }
    { valid=0 }
    END { if (NR != 7 || !body_ok) valid=0; exit(valid ? 0 : 1) }
  ' "$detail_file" || return 1
  detail_body_has_source "$detail_file"
}

# The body line must carry an authoritative source pointer: an http/https
# URL (accepted on shape), or a file URL or path token that resolves to an
# existing file - relative path candidates are checked under the detail
# dir, FM_HOME, and the project repo, so a slash-bearing token alone is
# not accepted.
detail_body_has_source() {
  local detail_file=$1 body candidates token found=1 had_glob_off=0
  body=$(awk 'NR==7{print; exit}' "$detail_file")
  if printf '%s\n' "$body" | grep -Eq '(^|[[:space:]])https?://[^[:space:]]+'; then
    return 0
  fi
  candidates=$(printf '%s\n' "$body" | awk -v sq="'" -v dq='"' '
    BEGIN {
      junk_lead = "<([{" dq "`" sq
      junk_trail = ".,;:!?)]>" dq "`" sq
    }
    {
      n = split($0, tok, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (match(t, /\]\([^)]+\)/)) t = substr(t, RSTART + 2, RLENGTH - 3)
        while (length(t) > 0 && index(junk_lead, substr(t, 1, 1))) t = substr(t, 2)
        while (length(t) > 0 && index(junk_trail, substr(t, length(t), 1))) t = substr(t, 1, length(t) - 1)
        if (length(t) > 0) print t
      }
    }
  ')
  case $- in *f*) ;; *) had_glob_off=1; set -f ;; esac
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case $token in
      "~"/*) token="$HOME${token#~}" ;;
      file://*)
        token=${token#file://}
        case $token in
          /*) ;;
          */*) token=/${token#*/} ;;
          *) continue ;;
        esac
        ;;
    esac
    if [ -e "$token" ] || [ -e "$DETAIL_DIR/$token" ] || [ -e "$FM_HOME/$token" ] || [ -e "$PROJ/$token" ]; then
      found=0
      break
    fi
  done <<< "$candidates"
  if [ "$had_glob_off" -eq 1 ]; then set +f; fi
  return "$found"
}

DETAIL_DIR="${FM_DETAIL_DIR_OVERRIDE:-$FM_HOME/data/projects}"
repo=${PROJ##*/}
if slug=$(slug_for_repo "$repo"); then
  if ! touched=$(project_code_diff); then
    echo "error: cannot inspect the project diff for $BRANCH in $PROJ; refusing to merge." >&2
    exit 1
  fi
  if [ -n "$touched" ]; then
    detail="$DETAIL_DIR/$slug.md"
    missing=""
    [ -f "$detail" ] || missing="missing file"
    if [ -f "$detail" ] && ! detail_record_is_current "$detail"; then
      missing="invalid frontmatter/detail record"
      for key in milestone focus blocker next_move; do
        if ! detail_frontmatter_has_key "$detail" "$key"; then
          missing="${missing:+$missing, }missing frontmatter key '$key'"
        fi
      done
    fi
    if [ -n "$missing" ]; then
      echo "REFUSED: $BRANCH touches project code under projects/$repo without a current detail record." >&2
      echo "Update $detail ($missing), then retry." >&2
      exit 1
    fi
  fi
else
  echo "warning: projects/$repo has no known slug; skipping the context-contract check." >&2
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
