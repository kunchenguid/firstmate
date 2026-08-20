#!/usr/bin/env bash
# fm-epic-lint.sh - the SINGLE owner of "is this epic valid". One runnable check
# that enforces the epic/story contract at AUTHORING time (the epic-review gate)
# and at PROMOTE time (fm-umbrella-promote.sh validate), so a non-standard epic
# can never slip through to become a mess later (kills incident root cause R5:
# the contract was only caught at promote-validate, too late, and an epic authored
# outside the pipeline with `story: LH-01`/uppercase keys broke every brief path).
#
# Usage:
#   fm-epic-lint.sh <epic-dir>      lint an epic dir (epic.md + stories/*.md)
#   fm-epic-lint.sh -h | --help
#
# <epic-dir> holds `epic.md` and a `stories/` dir of `<id>.md` story files.
# The check asserts, and exits non-zero with a numbered problem list naming each
# failure, that:
#   - epic.md has a valid `epic:` slug (a valid epic/<slug> branch name) and a
#     non-empty `repos:` list, every repo registered in this home;
#   - every story file's frontmatter is EXACTLY the seven contract keys
#     (id/epic/repo/pr_base/depends/kind/gate) - no missing key and no ad-hoc key
#     such as `story:` or `phase:`;
#   - each `id:` is lower-kebab, unique in the epic, and equals its filename stem;
#   - each `epic:` equals epic.md's slug;
#   - each `repo:` is registered in this home;
#   - each `pr_base:` is a valid branch name;
#   - each `kind:` is ship or scout and each `gate:` is true or false, with
#     EXACTLY ONE `gate: true` story in the epic;
#   - every `depends:` id names a real story in the epic, with no dependency cycle;
#   - each story's plan/brief pointer (the backtick path in its `## Implementation
#     plan` section) RESOLVES relative to the epic dir. A still-templated pointer
#     (one containing `...`) or a story with no such section is treated as
#     not-yet-planned and skipped, so the same lint is green on a freshly
#     scaffolded epic AND catches a concrete pointer that points nowhere.
#
# Exit codes: 0 valid, 1 contract problems (numbered list on stderr), 2 usage/
# structural error (bad args, no epic.md, no stories/).
#
# Overrides (mechanical/test seams, same style as bin/fm-umbrella-promote.sh):
#   FM_ROOT_OVERRIDE   firstmate code root (default: this script's ..).
#   FM_HOME            the home whose registry is checked (default: FM_ROOT).
#   FM_DATA_OVERRIDE   data dir (default $FM_HOME/data); its projects.md is the
#                      registry.
#   FM_PROJECTS_REG    direct path to the registry file, overriding the above.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="${FM_PROJECTS_REG:-$DATA/projects.md}"

# shellcheck source=bin/fm-epic-lint-lib.sh
. "$FM_ROOT/bin/fm-epic-lint-lib.sh"

die() { echo "error: $*" >&2; exit 2; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-epic-lint.sh <epic-dir>   lint an epic dir (epic.md + stories/*.md)
  fm-epic-lint.sh -h | --help

Exits 0 when the epic is valid, 1 with a numbered problem list when it is not,
and 2 on a usage or structural error. Enforces the epic/story contract (the
seven story keys, lower-kebab unique ids matching their filenames, matching
epic slug, registered repos, valid pr_base, exactly one gate story, acyclic
depends, and a resolving plan pointer). See the header for the full contract.
EOF
  exit "$code"
}

EPIC_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help | help) usage 0 ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$EPIC_DIR" ]; then EPIC_DIR=$1; else usage; fi ;;
  esac
  shift
done
[ -n "$EPIC_DIR" ] || usage
[ -d "$EPIC_DIR" ] || die "no such epic dir: $EPIC_DIR"

EPIC_MD="$EPIC_DIR/epic.md"
STORIES_DIR="$EPIC_DIR/stories"
[ -f "$EPIC_MD" ] || die "no epic.md in $EPIC_DIR"
[ -d "$STORIES_DIR" ] || die "no stories/ dir in $EPIC_DIR"

REQUIRED_KEYS="id epic repo pr_base depends kind gate"

problems=()
add() { problems+=("$*"); }

# key_allowed <key>: 0 if <key> is one of the seven contract keys.
key_allowed() {
  case " $REQUIRED_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# valid_branch <name>: 0 if <name> is a valid git branch name (for pr_base and the
# epic slug's epic/<slug> branch). git check-ref-format is a pure string check.
valid_branch() { git check-ref-format "refs/heads/$1" 2>/dev/null; }

# --- epic.md ----------------------------------------------------------------
EPIC_SLUG="$(fm_frontmatter_get "$EPIC_MD" epic)"
if [ -z "$EPIC_SLUG" ]; then
  add "epic.md: missing epic: slug"
elif ! valid_branch "epic/$EPIC_SLUG"; then
  add "epic.md: epic slug \"$EPIC_SLUG\" is not a valid epic/<slug> branch name"
fi

epic_repos_raw="$(fm_frontmatter_get "$EPIC_MD" repos)"
epic_repos_raw="${epic_repos_raw#[}"
epic_repos_raw="${epic_repos_raw%]}"
epic_repos=()
IFS_SAVE=$IFS
IFS=','
for r in $epic_repos_raw; do
  r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
  [ -n "$r" ] && epic_repos+=("$r")
done
IFS=$IFS_SAVE
if [ "${#epic_repos[@]}" -eq 0 ]; then
  add "epic.md: missing or empty repos: list"
else
  for r in "${epic_repos[@]}"; do
    fm_repo_registered "$REG" "$r" \
      || add "epic.md: repo \"$r\" is not registered in this home (data/projects.md)"
  done
fi

# --- stories ----------------------------------------------------------------
# Parallel arrays keep this Bash 3.2-safe (macOS stock bash has no associative
# arrays), matching bin/fm-umbrella-promote.sh.
story_ids=()      # each story's id: value (may be empty if the key is missing)
story_deps=()     # space-joined depends ids, parallel to story_ids
story_count=0
gate_true=0

for sf in "$STORIES_DIR"/*.md; do
  [ -f "$sf" ] || continue
  story_count=$((story_count + 1))
  base="$(basename "$sf")"
  stem="${base%.md}"

  # Exactly the seven keys: flag every missing required key and every ad-hoc key.
  present_keys=" "
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    present_keys="$present_keys$k "
    key_allowed "$k" || add "story $base: unexpected frontmatter key \"$k:\" (only id/epic/repo/pr_base/depends/kind/gate are allowed)"
  done < <(fm_frontmatter_keys "$sf")
  for k in $REQUIRED_KEYS; do
    case "$present_keys" in *" $k "*) : ;; *) add "story $base: missing frontmatter key \"$k:\"" ;; esac
  done

  sid="$(fm_frontmatter_get "$sf" id)"
  story_ids+=("$sid")
  if [ -z "$sid" ]; then
    : # missing id already reported by the key check
  else
    fm_lower_kebab "$sid" || add "story $base: id \"$sid\" is not lower-kebab"
    [ "$sid" = "$stem" ] || add "story $base: id \"$sid\" does not match its filename (expected id \"$stem\")"
  fi

  if fm_frontmatter_has "$sf" epic; then
    sepic="$(fm_frontmatter_get "$sf" epic)"
    [ "$sepic" = "$EPIC_SLUG" ] \
      || add "story $base: epic: \"$sepic\" does not match epic.md epic: \"$EPIC_SLUG\""
  fi

  if fm_frontmatter_has "$sf" repo; then
    srepo="$(fm_frontmatter_get "$sf" repo)"
    if [ -z "$srepo" ]; then
      add "story $base: repo: is empty"
    else
      fm_repo_registered "$REG" "$srepo" \
        || add "story $base: repo \"$srepo\" is not registered in this home (data/projects.md)"
    fi
  fi

  if fm_frontmatter_has "$sf" pr_base; then
    spr="$(fm_frontmatter_get "$sf" pr_base)"
    if [ -z "$spr" ]; then
      add "story $base: pr_base: is empty"
    elif ! valid_branch "$spr"; then
      add "story $base: pr_base \"$spr\" is not a valid branch name"
    fi
  fi

  if fm_frontmatter_has "$sf" kind; then
    skind="$(fm_frontmatter_get "$sf" kind)"
    case "$skind" in
      ship | scout) : ;;
      *) add "story $base: kind \"$skind\" must be ship or scout" ;;
    esac
  fi

  if fm_frontmatter_has "$sf" gate; then
    sgate="$(fm_frontmatter_get "$sf" gate)"
    case "$sgate" in
      true) gate_true=$((gate_true + 1)) ;;
      false) : ;;
      *) add "story $base: gate \"$sgate\" must be true or false" ;;
    esac
  fi

  # depends: [] or [a, b] - strip brackets, split on comma, collect ids.
  dep_raw="$(fm_frontmatter_get "$sf" depends)"
  dep_raw="${dep_raw#[}"
  dep_raw="${dep_raw%]}"
  deps=""
  IFS_SAVE=$IFS
  IFS=','
  for d in $dep_raw; do
    d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
    [ -n "$d" ] && deps="$deps $d"
  done
  IFS=$IFS_SAVE
  story_deps+=("$deps")

  # Plan/brief pointer: RED only when it names a concrete path that does not
  # resolve; a templated `...` pointer or no section is not-yet-planned (skip).
  ptr="$(fm_plan_pointer "$sf")"
  if [ -n "$ptr" ] && [ "${ptr#*...}" = "$ptr" ]; then
    [ -e "$EPIC_DIR/$ptr" ] || add "story $base: plan/brief pointer \"$ptr\" does not resolve (no $EPIC_DIR/$ptr)"
  fi
done

if [ "$story_count" -eq 0 ]; then
  add "no story files in $STORIES_DIR/"
fi

# Duplicate ids across stories (independent of the filename check).
for ((i = 0; i < ${#story_ids[@]}; i++)); do
  [ -n "${story_ids[$i]}" ] || continue
  for ((j = i + 1; j < ${#story_ids[@]}; j++)); do
    [ "${story_ids[$i]}" = "${story_ids[$j]}" ] \
      && add "duplicate story id \"${story_ids[$i]}\" (ids must be unique within the epic)"
  done
done

# Exactly one gate: true across the epic.
if [ "$story_count" -gt 0 ] && [ "$gate_true" -ne 1 ]; then
  add "epic has $gate_true stories with gate: true (exactly one contract-gate story is required)"
fi

# depends: every id must name a real story, with no cycle.
id_index() {  # <id> -> echoes the story index, or -1
  local want=$1 i
  for ((i = 0; i < ${#story_ids[@]}; i++)); do
    [ "${story_ids[$i]}" = "$want" ] && { printf '%s' "$i"; return; }
  done
  printf '%s' -1
}
for ((i = 0; i < ${#story_ids[@]}; i++)); do
  [ -n "${story_ids[$i]}" ] || continue
  for d in ${story_deps[$i]}; do
    [ "$(id_index "$d")" -ge 0 ] \
      || add "story ${story_ids[$i]}: depends id \"$d\" names no story in this epic"
  done
done

# Cycle detection: iterative-friendly DFS with a color array (0 unvisited, 1
# on-stack, 2 done). Bash-3.2-safe; only edges to real stories are followed.
cycle_from=""
colors=()
for ((i = 0; i < ${#story_ids[@]}; i++)); do colors[i]=0; done
dfs() {  # <index>; sets cycle_from on the first back-edge found
  local n=$1 d di
  colors[n]=1
  for d in ${story_deps[$n]}; do
    di="$(id_index "$d")"
    [ "$di" -ge 0 ] || continue
    if [ "${colors[$di]}" = "1" ]; then
      cycle_from="${story_ids[$n]} -> $d"; return
    elif [ "${colors[$di]}" = "0" ]; then
      dfs "$di"
      [ -n "$cycle_from" ] && return
    fi
  done
  colors[n]=2
}
for ((i = 0; i < ${#story_ids[@]}; i++)); do
  [ -n "${story_ids[$i]}" ] || continue
  [ "${colors[$i]}" = "0" ] || continue
  dfs "$i"
  [ -n "$cycle_from" ] && { add "dependency cycle among stories (e.g. $cycle_from)"; break; }
done

# --- verdict ----------------------------------------------------------------
if [ "${#problems[@]}" -gt 0 ]; then
  {
    printf 'epic lint FAILED for %s (%d problem(s)):\n' "$EPIC_DIR" "${#problems[@]}"
    n=0
    for m in "${problems[@]}"; do n=$((n + 1)); printf '  %d. %s\n' "$n" "$m"; done
  } >&2
  exit 1
fi

echo "epic lint OK: \"$EPIC_SLUG\" - $story_count stories, contract satisfied."
