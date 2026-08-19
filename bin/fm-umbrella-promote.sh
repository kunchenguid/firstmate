#!/usr/bin/env bash
# fm-umbrella-promote.sh - promote a DESIGNED umbrella epic into this home: move
# the epic dir into data/plans/ and seed its stories into the backlog, then STOP
# at the sign-off gate. Run WITH FM_HOME set to the home that owns the umbrella.
#
# The umbrella lab (bin/fm-umbrella.sh) is where a cross-repo feature is designed;
# its durable output can include a delegable epic under
# umbrellas/<id>/plans/<epic-dir>/ (epic.md + stories/*.md, the harness-agnostic
# standard from the gflow epic). Turning that designed epic into queued backlog
# work used to be a manual, error-prone hand-off: move the dir into the home,
# seed N stories by hand, then sign/branch/dispatch. Two home firstmates botched
# the seed - one hand-seed used ids `lh-01`/tag `[lh]` while the story files were
# `LH-01`/epic `aimica-learning-hub`, so the lint gate flagged 10 ORPHAN tasks and
# the dashboard showed TWO epics (the signed design epic + a mismatched backlog
# epic). This script makes the mechanical promote reliable:
#
#   1. LOCATE the designed epic under umbrellas/<id>/plans/<epic-dir>/.
#   2. VALIDATE before writing anything - epic slug + repos:, and every story's
#      id: / repo: / pr_base: / matching epic:, and every involved repo registered
#      in this home's data/projects.md.
#   3. MOVE the epic dir -> data/plans/<epic-dir>/ (where the dashboard/dispatch
#      read). Idempotent and never-clobber: an existing identical target is
#      reconciled, a DIFFERING target refuses rather than clobbering.
#   4. SEED each story into the backlog deriving id/title-tag/repo FROM the story
#      frontmatter, so backlog ids + `[<epic>]` tags always match the story files
#      by construction (no orphans, one epic). Idempotent: an already-present
#      story is skipped. A botched prior seed (a task carrying this epic's work
#      under a mismatched id/tag) is DETECTED and REFUSED, never duplicated.
#   5. STOP at the sign-off gate and print the remaining human/firstmate steps
#      (review + sign epic.md, cut epic branches, dispatch, teardown). This script
#      NEVER signs, cuts a branch, or dispatches - those are judgment/approval
#      steps that stay human/firstmate-owned.
#
# Every mutation is fail-closed: all validation runs first, so a validation
# failure writes nothing, and the move + seed are idempotent so a re-run after a
# partial failure safely converges. Same header/--help/override-seam style as
# bin/fm-epic-branch.sh and bin/fm-epic-ship.sh.
#
# Usage:
#   fm-umbrella-promote.sh <umbrella-id>
#   fm-umbrella-promote.sh -h | --help
#
# Overrides (mechanical/test seams, same style as bin/fm-epic-ship.sh):
#   FM_ROOT_OVERRIDE       firstmate code root (default: this script's ..).
#   FM_HOME                the home whose umbrella is promoted (default: FM_ROOT).
#   FM_DATA_OVERRIDE       data dir (default $FM_HOME/data).
#   FM_UMBRELLAS_OVERRIDE  umbrellas dir (default $FM_HOME/umbrellas).
#   FM_PROJECTS_OVERRIDE   projects dir - not read directly, kept for parity.
#   FM_CONFIG_OVERRIDE     config dir (default $FM_HOME/config); backlog-backend.
#   FM_TASKS_BIN           tasks-axi wrapper (default tasks-axi).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
UMBRELLAS="${FM_UMBRELLAS_OVERRIDE:-$FM_HOME/umbrellas}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TASKS="${FM_TASKS_BIN:-tasks-axi}"
REG="$DATA/projects.md"
BACKLOG="$DATA/backlog.md"
PLANS_DST="$DATA/plans"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$FM_ROOT/bin/fm-tasks-axi-lib.sh"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-umbrella-promote.sh <umbrella-id>   promote a designed umbrella epic
  fm-umbrella-promote.sh -h | --help

Run WITH FM_HOME set to the home that owns the umbrella. Moves the designed epic
under umbrellas/<id>/plans/<epic-dir>/ into data/plans/, seeds its stories into
the backlog (ids + [<epic>] tags derived from the story frontmatter, so they match
by construction), then STOPS at the sign-off gate and prints the remaining
sign/branch/dispatch/teardown steps. Idempotent and fail-closed: validation runs
before any write, a re-run is a safe no-op, and a botched prior seed is refused
rather than duplicated. Never signs, branches, or dispatches.
EOF
  exit "$code"
}

# A safe umbrella id: same character class as fm-umbrella.sh (no traversal, no
# leading dot, no shell metacharacters).
umbrella_id_valid() {
  case "${1-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# frontmatter_get <file> <key>: value of `key:` inside the leading --- ... ---
# YAML frontmatter, trimmed. Empty (rc 0) when absent so callers test emptiness.
frontmatter_get() {
  awk -v key="$2" '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm {
      line=$0
      if (sub("^" key "[[:space:]]*:[[:space:]]*", "", line)) {
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

# heading_of <file>: first `# ` ATX heading text (the `# ` stripped), or empty.
heading_of() {
  awk '/^#[[:space:]]+/ { sub(/^#[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1"
}

# lower <string>: lowercase, for case-insensitive id comparison.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# repo_registered <name>: 0 if data/projects.md lists `- <name> ...`. A missing
# registry means nothing is registered (fail-closed).
repo_registered() {
  [ -f "$REG" ] || return 1
  awk -v n="$1" '$1=="-" && $2==n { found=1; exit } END { exit !found }' "$REG"
}

# A story id must be a single clean token so it can never smuggle a flag into
# tasks-axi and always resolves to one backlog key.
story_id_valid() {
  case "${1-}" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- arg parse --------------------------------------------------------------
UMBRELLA_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage 0 ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$UMBRELLA_ID" ]; then UMBRELLA_ID=$1; else usage; fi ;;
  esac
  shift
done
[ -n "$UMBRELLA_ID" ] || usage
umbrella_id_valid "$UMBRELLA_ID" || die "invalid umbrella id: $UMBRELLA_ID"

UMBRELLA_DIR="$UMBRELLAS/$UMBRELLA_ID"
[ -d "$UMBRELLA_DIR" ] || die "unknown umbrella \"$UMBRELLA_ID\": no directory at umbrellas/$UMBRELLA_ID"

MARKER="$UMBRELLA_DIR/.promoted"

# --- locate the designed epic -----------------------------------------------
# Source of truth for what to promote. Before the first successful move the epic
# lives under umbrellas/<id>/plans/<epic-dir>/; after it, that dir is gone and a
# .promoted marker records the basename so a re-run finds the already-moved copy
# under data/plans/ and reconciles the backlog rather than failing.
EPIC_SRC=""
EPIC_BASE=""
src_matches=()
if [ -d "$UMBRELLA_DIR/plans" ]; then
  for d in "$UMBRELLA_DIR"/plans/*/; do
    [ -f "${d}epic.md" ] || continue
    src_matches+=("${d%/}")
  done
fi

if [ "${#src_matches[@]}" -gt 1 ]; then
  printf 'error: umbrella %s has more than one epic under plans/; promote is ambiguous:\n' "$UMBRELLA_ID" >&2
  for d in "${src_matches[@]}"; do printf '  - %s\n' "$(basename "$d")" >&2; done
  exit 1
elif [ "${#src_matches[@]}" -eq 1 ]; then
  EPIC_SRC="${src_matches[0]}"
  EPIC_BASE="$(basename "$EPIC_SRC")"
elif [ -f "$MARKER" ]; then
  # Already promoted on an earlier run: reconcile from the moved copy.
  EPIC_BASE="$(cat "$MARKER")"
  [ -n "$EPIC_BASE" ] || die "corrupt promote marker at $MARKER (empty)"
else
  die "no designed epic under umbrellas/$UMBRELLA_ID/plans/ (needs <epic-dir>/epic.md + stories/); design is not done"
fi

EPIC_DST="$PLANS_DST/$EPIC_BASE"

# The directory the story/epic files live in RIGHT NOW (source before move, or
# the moved copy on a reconcile run). Validation reads from here.
if [ -n "$EPIC_SRC" ]; then
  EPIC_DIR="$EPIC_SRC"
else
  EPIC_DIR="$EPIC_DST"
  [ -d "$EPIC_DIR" ] || die "promote marker names \"$EPIC_BASE\" but data/plans/$EPIC_BASE is missing; state is inconsistent"
fi

EPIC_MD="$EPIC_DIR/epic.md"
STORIES_DIR="$EPIC_DIR/stories"
[ -f "$EPIC_MD" ] || die "no epic.md in $EPIC_DIR"
[ -d "$STORIES_DIR" ] || die "no stories/ dir in $EPIC_DIR"

# --- validate the epic ------------------------------------------------------
EPIC_SLUG="$(frontmatter_get "$EPIC_MD" epic)"
[ -n "$EPIC_SLUG" ] || die "epic.md has no epic: slug ($EPIC_MD)"
git check-ref-format "refs/heads/epic/$EPIC_SLUG" 2>/dev/null \
  || die "epic slug \"$EPIC_SLUG\" is not a valid branch name (epic/<slug> must be valid)"

EPIC_REPOS_RAW="$(frontmatter_get "$EPIC_MD" repos)"
[ -n "$EPIC_REPOS_RAW" ] || die "epic.md has no repos: list ($EPIC_MD)"
# repos: [a, b, c] or repos: a, b - strip brackets, split on comma.
EPIC_REPOS_RAW="${EPIC_REPOS_RAW#[}"
EPIC_REPOS_RAW="${EPIC_REPOS_RAW%]}"
epic_repos=()
IFS_SAVE=$IFS
IFS=','
for r in $EPIC_REPOS_RAW; do
  r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"  # trim
  [ -n "$r" ] && epic_repos+=("$r")
done
IFS=$IFS_SAVE
[ "${#epic_repos[@]}" -gt 0 ] || die "epic.md repos: list is empty ($EPIC_MD)"

# --- parse + validate every story -------------------------------------------
story_ids=()
story_repos=()
story_kinds=()
story_titles=()
story_files=()
involved_repos=()   # union of epic repos + story repos, for registration check

for r in "${epic_repos[@]}"; do involved_repos+=("$r"); done

story_count=0
for sf in "$STORIES_DIR"/*.md; do
  [ -f "$sf" ] || continue
  story_count=$((story_count + 1))
  base="$(basename "$sf")"

  sid="$(frontmatter_get "$sf" id)"
  [ -n "$sid" ] || die "story $base has no id:"
  story_id_valid "$sid" || die "story $base has an invalid id: \"$sid\""

  sepic="$(frontmatter_get "$sf" epic)"
  [ -n "$sepic" ] || die "story $base ($sid) has no epic:"
  [ "$sepic" = "$EPIC_SLUG" ] \
    || die "story $base ($sid) epic: \"$sepic\" does not match epic.md epic: \"$EPIC_SLUG\""

  srepo="$(frontmatter_get "$sf" repo)"
  [ -n "$srepo" ] || die "story $base ($sid) has no repo:"

  spr="$(frontmatter_get "$sf" pr_base)"
  [ -n "$spr" ] || die "story $base ($sid) has no pr_base: (required; typically the epic's epic/$EPIC_SLUG or a production branch)"

  skind="$(frontmatter_get "$sf" kind)"
  [ -n "$skind" ] || skind=ship

  shead="$(heading_of "$sf")"
  [ -n "$shead" ] || shead="$sid"

  story_ids+=("$sid")
  story_repos+=("$srepo")
  story_kinds+=("$skind")
  story_titles+=("[$EPIC_SLUG] $shead")
  story_files+=("$base")

  # collect repo for registration check (dedup)
  seen=0
  for r in "${involved_repos[@]}"; do [ "$r" = "$srepo" ] && { seen=1; break; }; done
  [ "$seen" -eq 1 ] || involved_repos+=("$srepo")
done
[ "$story_count" -gt 0 ] || die "no story files in $STORIES_DIR; design is not done"

# Duplicate story ids inside the epic would collide in the backlog.
dupe=""
for i in "${!story_ids[@]}"; do
  for j in "${!story_ids[@]}"; do
    [ "$i" -lt "$j" ] || continue
    [ "${story_ids[$i]}" = "${story_ids[$j]}" ] && dupe="${story_ids[$i]}"
  done
done
[ -z "$dupe" ] || die "two story files share id \"$dupe\"; ids must be unique within the epic"

# --- every involved repo must be registered in THIS home --------------------
missing_repos=()
for r in "${involved_repos[@]}"; do
  repo_registered "$r" || missing_repos+=("$r")
done
if [ "${#missing_repos[@]}" -gt 0 ]; then
  printf 'error: these epic repos are not registered in this home (data/projects.md); register them first so epic branches can be cut:\n' >&2
  for r in "${missing_repos[@]}"; do printf '  - %s\n' "$r" >&2; done
  exit 1
fi

# --- detect a botched prior seed against the current backlog -----------------
# Read existing backlog (id, first-[tag]) pairs. Both the tasks-axi and manual
# backends render to the same data/backlog.md, so parsing the file is
# backend-agnostic.
declare -a bl_ids=()
declare -a bl_tags=()
if [ -f "$BACKLOG" ]; then
  while IFS=$'\t' read -r bid btag; do
    [ -n "$bid" ] || continue
    bl_ids+=("$bid")
    bl_tags+=("$btag")
  done < <(awk '
    /^- \[[ x]\] / {
      line=$0; sub(/^- \[[ x]\] +/, "", line)
      id=line; sub(/[ \t].*/, "", id)
      tag=""
      if (match(line, /\[[^]]+\]/)) tag=substr(line, RSTART+1, RLENGTH-2)
      print id "\t" tag
    }
  ' "$BACKLOG")
fi

# in_story_ids <id>: 0 if <id> exactly names one of this epic's stories.
in_story_ids() {
  local q=$1 s
  for s in "${story_ids[@]}"; do [ "$s" = "$q" ] && return 0; done
  return 1
}

drift=()   # mismatched prior seeds carrying this epic's work under a bad id/tag

# An empty backlog has nothing to mismatch. (Guarding the whole block also keeps
# the `${!arr[@]}` expansions below off an empty array, which bash 3.2 rejects
# under `set -u`.)
if [ "${#bl_ids[@]}" -gt 0 ]; then
  # Signal 1: a backlog id that case-insensitively matches a story id but is not
  # an exact match (the aimica `lh-01` vs `LH-01` failure).
  for i in "${!story_ids[@]}"; do
    sid="${story_ids[$i]}"
    lc_sid="$(lower "$sid")"
    for k in "${!bl_ids[@]}"; do
      bid="${bl_ids[$k]}"
      [ "$bid" = "$sid" ] && continue
      if [ "$(lower "$bid")" = "$lc_sid" ]; then
        drift+=("backlog task \"$bid\" case-mismatches story id \"$sid\"")
      fi
    done
  done

  # Signal 2: a backlog task carrying THIS epic's tag whose id is not one of this
  # epic's stories (right tag, wrong id).
  for k in "${!bl_ids[@]}"; do
    [ "${bl_tags[$k]}" = "$EPIC_SLUG" ] || continue
    in_story_ids "${bl_ids[$k]}" && continue
    drift+=("backlog task \"${bl_ids[$k]}\" carries tag [$EPIC_SLUG] but is not one of this epic's stories")
  done

  # Signal 3: a story's exact id is already in the backlog but under the WRONG tag
  # (present but inconsistent - the invariant is tag == epic slug).
  for k in "${!bl_ids[@]}"; do
    in_story_ids "${bl_ids[$k]}" || continue
    [ "${bl_tags[$k]}" = "$EPIC_SLUG" ] && continue
    drift+=("backlog task \"${bl_ids[$k]}\" matches a story id but carries tag [${bl_tags[$k]}] instead of [$EPIC_SLUG]")
  done
fi

if [ "${#drift[@]}" -gt 0 ]; then
  {
    printf 'error: the backlog already carries a MISMATCHED prior seed of epic "%s"; refusing to add a second parallel set.\n' "$EPIC_SLUG"
    for m in "${drift[@]}"; do printf '  - %s\n' "$m"; done
    printf 'Reconcile the backlog first: remove or rename the mismatched task(s) (tasks-axi rm <id>) so ids + [%s] tags match the story files, then re-run.\n' "$EPIC_SLUG"
  } >&2
  exit 1
fi

# Which stories are already present (exact id) vs need adding. After the drift
# checks a present id is guaranteed to carry the correct tag.
already_present=()
to_add_idx=()
for i in "${!story_ids[@]}"; do
  present=0
  if [ "${#bl_ids[@]}" -gt 0 ]; then
    for bid in "${bl_ids[@]}"; do [ "$bid" = "${story_ids[$i]}" ] && { present=1; break; }; done
  fi
  if [ "$present" -eq 1 ]; then already_present+=("${story_ids[$i]}"); else to_add_idx+=("$i"); fi
done

# ============================================================================
# Validation passed. From here we MUTATE (move + seed), idempotently.
# ============================================================================

# --- move the epic dir into data/plans/ -------------------------------------
mkdir -p "$PLANS_DST" || die "cannot create $PLANS_DST"

if [ -n "$EPIC_SRC" ]; then
  # Record the promotion target BEFORE the move so a crash between move and seed
  # still lets a re-run find the moved copy.
  printf '%s\n' "$EPIC_BASE" > "$MARKER" || die "cannot write promote marker $MARKER"
  if [ -e "$EPIC_DST" ]; then
    # Target already exists (a prior interrupted run, or an unrelated collision).
    if diff -rq "$EPIC_SRC" "$EPIC_DST" >/dev/null 2>&1; then
      rm -rf -- "$EPIC_SRC" || die "cannot remove already-promoted source $EPIC_SRC"
      say "epic dir already at data/plans/$EPIC_BASE (identical); removed the umbrella copy."
    else
      die "data/plans/$EPIC_BASE already exists and DIFFERS from the umbrella copy; refusing to clobber. Reconcile them by hand, then re-run."
    fi
  else
    mv "$EPIC_SRC" "$EPIC_DST" || die "failed to move $EPIC_SRC -> $EPIC_DST"
    say "moved epic dir -> data/plans/$EPIC_BASE"
  fi
else
  say "epic dir already promoted to data/plans/$EPIC_BASE (reconciling backlog only)."
fi

# --- seed the stories into the backlog --------------------------------------
seed_manual=0
if ! fm_tasks_axi_backend_available "$CONFIG"; then
  seed_manual=1
fi

# ensure_backlog_sections: a manual seed needs the section skeleton to exist.
ensure_backlog_sections() {
  [ -f "$BACKLOG" ] && return 0
  mkdir -p "$(dirname "$BACKLOG")" || die "cannot create $(dirname "$BACKLOG")"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$BACKLOG" || die "cannot create $BACKLOG"
}

# manual_add <id> <title> <repo> <kind>: append a Queued line matching tasks-axi's
# rendered format, right after the `## Queued` header.
manual_add() {
  local id=$1 title=$2 repo=$3 kind=$4 today line tmp
  ensure_backlog_sections
  today="$(date -u +%Y-%m-%d)"
  line="- [ ] $id - $title (repo: $repo) (kind: $kind) (since $today)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/fm-umbrella-promote.XXXXXX")" || die "cannot create temp file"
  awk -v line="$line" '
    { print }
    !done && /^##[[:space:]]+Queued[[:space:]]*$/ { print line; done=1 }
  ' "$BACKLOG" > "$tmp" || { rm -f "$tmp"; die "failed to render backlog line for $id"; }
  if ! grep -qF -- "$line" "$tmp"; then
    rm -f "$tmp"
    die "no '## Queued' section in $BACKLOG; cannot seed $id manually"
  fi
  mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; die "failed to write $BACKLOG"; }
}

added=0
for i in ${to_add_idx[@]+"${to_add_idx[@]}"}; do
  sid="${story_ids[$i]}"
  title="${story_titles[$i]}"
  repo="${story_repos[$i]}"
  kind="${story_kinds[$i]}"
  if [ "$seed_manual" -eq 1 ]; then
    manual_add "$sid" "$title" "$repo" "$kind"
  else
    "$TASKS" add "$sid" "$title" --kind "$kind" --repo "$repo" --queue --file "$BACKLOG" >/dev/null \
      || die "tasks-axi add failed for story $sid; backlog left partially seeded - re-run to converge (already-added stories are skipped)"
  fi
  say "seeded $sid  [$EPIC_SLUG]  (repo: $repo, kind: $kind)"
  added=$((added + 1))
done

# --- report + STOP at the sign-off gate -------------------------------------
say ""
say "Promoted umbrella \"$UMBRELLA_ID\" -> epic \"$EPIC_SLUG\" (data/plans/$EPIC_BASE)."
say "  stories seeded now: $added    already present: ${#already_present[@]}    total: $story_count"
if [ "$seed_manual" -eq 1 ]; then
  say "  backlog backend: manual (config/backlog-backend=manual or tasks-axi unavailable)"
fi
say ""
say "STOP - the remaining steps are human/firstmate-owned (this script never signs, branches, or dispatches):"
say "  1. Review umbrellas/$UMBRELLA_ID/DESIGN.md, then SIGN the epic:"
say "     set epic.md status pending -> active and add 'signed_off: $(date -u +%Y-%m-%d)' in data/plans/$EPIC_BASE/epic.md"
say "  2. Cut one epic branch per involved repo:"
for r in "${epic_repos[@]}"; do
  say "     bin/fm-epic-branch.sh create $EPIC_SLUG $r"
done
say "  3. Firstmate dispatches the queued stories (each anchored to its epic branch)."
say "  4. When the epic has landed, tear down the umbrella:"
say "     bin/fm-umbrella.sh teardown $UMBRELLA_ID"
