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
#   2. VALIDATE before writing anything by running bin/fm-epic-lint.sh (the single
#      owner of the epic/story contract) on the epic dir, so promote and the
#      epic-review gate enforce ONE identical contract; a failure writes nothing.
#   3. MOVE the epic dir -> data/plans/<epic-dir>/ (the canonical, durable copy
#      the dashboard/dispatch read) and leave a BACK-SYMLINK in the umbrella at
#      umbrellas/<id>/plans/<epic-dir> pointing to it, so the captain keeps
#      designing the epic in the lab (next to repos/) with edits writing through
#      to the real files - one source of truth, no duplicate, no "materialize on
#      done" step. Idempotent and never-clobber: an existing identical target is
#      reconciled, a DIFFERING target refuses rather than clobbering, and the
#      back-symlink is replaced/verified rather than erroring on a re-run.
#   4. SEED each story into the backlog deriving id/title-tag/repo FROM the story
#      frontmatter, so backlog ids + `[<epic>]` tags always match the story files
#      by construction (no orphans, one epic). CONVERGE the backlog to the
#      canonical epic on every re-run: a missing story is added, and an
#      already-present story whose title/repo/kind DRIFTED from its current
#      frontmatter is rewritten in place (state, blocked-by, holds, and notes
#      preserved). A story FILE renamed to a case/kebab variant of its backlog id
#      (the aimica `LH-01` -> `lh-01` failure) has its backlog id rewritten rather
#      than left orphaned. Only genuinely unresolvable drift - a task carrying
#      this epic's tag that matches no story, or a real double-seed - is REFUSED.
#   5. STOP at the sign-off gate and print the remaining human/firstmate steps
#      (review + sign epic.md, cut epic branches, dispatch, teardown). This script
#      NEVER signs, cuts a branch, or dispatches - those are judgment/approval
#      steps that stay human/firstmate-owned.
#
# The `verify <umbrella-id>` subcommand asserts the promoted end-state without
# mutating anything: the epic is canonical at data/plans, the umbrella
# back-symlink resolves to it, the .promoted marker is present and correct, every
# story file has a matching backlog entry whose brief resolves, and no orphan or
# case-drifted tag remains. It exits non-zero and prints every concrete failure,
# so it is the loud end-state check the aimica incident lacked (and the primitive
# fm-epic-status/dispatch-plan reuse).
#
# Every mutation is fail-closed: all validation AND the full reconcile plan are
# computed first, so a validation or unresolvable-drift failure writes nothing,
# and the move + seed + reconcile are idempotent so a re-run after a partial
# failure safely converges. Same header/--help/override-seam style as
# bin/fm-epic-branch.sh and bin/fm-epic-ship.sh.
#
# Usage:
#   fm-umbrella-promote.sh [promote] <umbrella-id>
#   fm-umbrella-promote.sh verify <umbrella-id>
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
# The epic/story frontmatter parser and the registry check are shared with the
# lint (bin/fm-epic-lint.sh), which is the single owner of "is this epic valid".
# shellcheck source=bin/fm-epic-lint-lib.sh
. "$FM_ROOT/bin/fm-epic-lint-lib.sh"

LINT="$FM_ROOT/bin/fm-epic-lint.sh"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-umbrella-promote.sh [promote] <umbrella-id>   promote a designed umbrella epic
  fm-umbrella-promote.sh verify <umbrella-id>       assert the promoted end-state
  fm-umbrella-promote.sh -h | --help

Run WITH FM_HOME set to the home that owns the umbrella. `promote` (the default)
moves the designed epic under umbrellas/<id>/plans/<epic-dir>/ into data/plans/,
seeds its stories into the backlog (ids + [<epic>] tags derived from the story
frontmatter, so they match by construction), then STOPS at the sign-off gate and
prints the remaining sign/branch/dispatch/teardown steps. Idempotent and
fail-closed: validation and the full reconcile plan run before any write, a
re-run CONVERGES the backlog to the canonical epic (adds missing stories,
rewrites drifted title/repo/kind, rewrites a case/kebab-renamed id), and only
unresolvable drift is refused. Never signs, branches, or dispatches.

`verify` mutates nothing and exits non-zero (naming every failure) unless the
epic is canonical at data/plans, the umbrella back-symlink resolves to it, the
.promoted marker is correct, every story has a matching backlog brief, and no
orphan/case-drifted tag remains.
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

# The frontmatter parser, heading reader, lowercase helper, registry check, and
# story-id validation all live in bin/fm-epic-lint-lib.sh (fm_frontmatter_get,
# fm_heading_of, fm_lower, fm_repo_registered) and the lint itself, so there is
# exactly one copy of that logic, shared with the lint.

# read_backlog: parse data/backlog.md into parallel global arrays BL_IDS, BL_TAGS,
# BL_REPOS, BL_KINDS, BL_TITLES (the derived title, i.e. before any `blocked-by:`
# or the trailing metadata). Both the tasks-axi and manual backends render to the
# same file, so this is backend-agnostic. Empty (all arrays reset) when the
# backlog is absent.
read_backlog() {
  BL_IDS=(); BL_TAGS=(); BL_REPOS=(); BL_KINDS=(); BL_TITLES=()
  [ -f "$BACKLOG" ] || return 0
  local id tag repo kind ct
  while IFS=$'\t' read -r id tag repo kind ct; do
    [ -n "$id" ] || continue
    BL_IDS+=("$id"); BL_TAGS+=("$tag"); BL_REPOS+=("$repo"); BL_KINDS+=("$kind"); BL_TITLES+=("$ct")
  done < <(awk '
    /^- \[[ x]\] / {
      raw=$0; sub(/^- \[[ x]\] +/, "", raw)
      id=raw; sub(/[ \t].*/, "", id)
      rest=""; p=index(raw, id " - "); if (p==1) rest=substr(raw, length(id)+4)
      ct=rest; ri=index(rest, " (repo:"); bi=index(rest, " blocked-by:"); end=0
      if (ri>0 && (bi==0 || ri<bi)) end=ri; else if (bi>0) end=bi
      if (end>0) ct=substr(rest, 1, end-1)
      tag=""; if (match(ct, /\[[^]]+\]/)) tag=substr(ct, RSTART+1, RLENGTH-2)
      repo=""; if (match(raw, /\(repo: [^)]*\)/)) repo=substr(raw, RSTART+7, RLENGTH-8)
      kind=""; if (match(raw, /\(kind: [^)]*\)/)) kind=substr(raw, RSTART+7, RLENGTH-8)
      printf "%s\t%s\t%s\t%s\t%s\n", id, tag, repo, kind, ct
    }
  ' "$BACKLOG")
}

# rewrite_backlog_id <old> <new>: rewrite ONLY the id token on the single task
# line whose id is <old>, preserving state, title, notes, and every trailing
# field. Backend-agnostic (both backends render to data/backlog.md).
rewrite_backlog_id() {
  local old=$1 new=$2 tmp
  [ -f "$BACKLOG" ] || die "cannot rewrite id in missing $BACKLOG"
  tmp="$(mktemp "${TMPDIR:-/tmp}/fm-umbrella-promote.XXXXXX")" || die "cannot create temp file"
  awk -v old="$old" -v new="$new" '
    {
      pfx=substr($0, 1, 6)
      if (pfx ~ /^- \[.\] /) {
        after=substr($0, 7); sp=index(after, " ")
        if (sp>0 && substr(after, 1, sp-1)==old) { print pfx new substr(after, sp); next }
      }
      print
    }
  ' "$BACKLOG" > "$tmp" || { rm -f "$tmp"; die "failed to rewrite backlog id $old -> $new"; }
  mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; die "failed to write $BACKLOG"; }
}

# manual_reconcile_fields <id> <title> <repo> <kind>: rewrite the derived fields
# (title, repo, kind) on the task line whose id is <id>, preserving state, any
# `blocked-by:`, the `(since ...)` date, holds, and indented note lines. The
# manual-backend equivalent of `tasks-axi update`.
manual_reconcile_fields() {
  local id=$1 title=$2 repo=$3 kind=$4 tmp
  [ -f "$BACKLOG" ] || die "cannot reconcile in missing $BACKLOG"
  tmp="$(mktemp "${TMPDIR:-/tmp}/fm-umbrella-promote.XXXXXX")" || die "cannot create temp file"
  awk -v id="$id" -v title="$title" -v repo="$repo" -v kind="$kind" '
    {
      pfx=substr($0, 1, 6)
      if (pfx ~ /^- \[.\] /) {
        after=substr($0, 7); sp=index(after, " ")
        if (sp>0 && substr(after, 1, sp-1)==id) {
          rest=substr(after, sp+1); sub(/^- /, "", rest)
          ri=index(rest, " (repo:")
          if (ri>0) {
            left=substr(rest, 1, ri-1); right=substr(rest, ri+1)
            bb=""; bi=index(left, " blocked-by:"); if (bi>0) bb=substr(left, bi)
            sub(/\(repo: [^)]*\)/, "(repo: " repo ")", right)
            sub(/\(kind: [^)]*\)/, "(kind: " kind ")", right)
            print pfx id " - " title bb " " right
            next
          }
        }
      }
      print
    }
  ' "$BACKLOG" > "$tmp" || { rm -f "$tmp"; die "failed to reconcile fields for $id"; }
  mv "$tmp" "$BACKLOG" || { rm -f "$tmp"; die "failed to write $BACKLOG"; }
}

# reconcile_fields <id> <title> <repo> <kind>: refresh a present task's derived
# fields through the active backend, preserving state and hand-added notes.
reconcile_fields() {
  local id=$1 title=$2 repo=$3 kind=$4
  if [ "$seed_manual" -eq 1 ]; then
    manual_reconcile_fields "$id" "$title" "$repo" "$kind"
  else
    "$TASKS" update "$id" --title "$title" --repo "$repo" --kind "$kind" --file "$BACKLOG" >/dev/null \
      || die "tasks-axi update failed reconciling story $id"
  fi
}

# do_verify: assert the promoted end-state for $UMBRELLA_ID without mutating
# anything. Collects EVERY failure and prints them together, then returns 1;
# returns 0 only when the whole end-state is healthy. Locates the epic from the
# .promoted marker (or, if it is lost, the single umbrella back-symlink) so it can
# still report a missing/incorrect marker as a failure rather than aborting.
do_verify() {
  local marker base canon link slug target sf sid m
  local fails=()
  marker="$UMBRELLA_DIR/.promoted"

  base=""
  [ -f "$marker" ] && base="$(cat "$marker" 2>/dev/null || true)"
  if [ -z "$base" ] && [ -d "$UMBRELLA_DIR/plans" ]; then
    local L n=0 cand=""
    for L in "$UMBRELLA_DIR"/plans/*; do
      [ -L "$L" ] || continue
      cand="$(basename "$L")"; n=$((n + 1))
    done
    [ "$n" -eq 1 ] && base="$cand"
  fi
  [ -n "$base" ] || die "verify: umbrella \"$UMBRELLA_ID\" has no promoted epic (no .promoted marker and no back-symlink); nothing to verify"

  canon="$PLANS_DST/$base"
  link="$UMBRELLA_DIR/plans/$base"

  # (c) .promoted marker present + correct.
  if [ ! -f "$marker" ]; then
    fails+=("(c) marker: umbrellas/$UMBRELLA_ID/.promoted is missing")
  elif [ "$(cat "$marker" 2>/dev/null || true)" != "$base" ]; then
    fails+=("(c) marker: .promoted says \"$(cat "$marker" 2>/dev/null || true)\" but the epic dir is \"$base\"")
  fi

  # (a) epic canonical at data/plans (a REAL directory, not a symlink).
  if [ -L "$canon" ] || [ ! -d "$canon" ]; then
    fails+=("(a) canonical: data/plans/$base is missing or a symlink (must be the real epic directory)")
  elif [ ! -f "$canon/epic.md" ]; then
    fails+=("(a) canonical: data/plans/$base/epic.md is missing")
  fi

  slug=""
  [ -f "$canon/epic.md" ] && slug="$(fm_frontmatter_get "$canon/epic.md" epic)"

  # (b) umbrella back-symlink resolves to the canonical dir.
  if [ ! -L "$link" ]; then
    fails+=("(b) back-symlink: umbrellas/$UMBRELLA_ID/plans/$base is not a symlink")
  else
    target="$(cd "$link" 2>/dev/null && pwd -P || true)"
    if [ -z "$target" ] || [ "$target" != "$(cd "$canon" 2>/dev/null && pwd -P || true)" ]; then
      fails+=("(b) back-symlink: umbrellas/$UMBRELLA_ID/plans/$base does not resolve to data/plans/$base")
    fi
  fi

  # (d) every story file has a matching backlog entry whose brief resolves, and
  # (e) no backlog task carries this epic's tag under an orphan/case-drifted id.
  if [ -z "$slug" ]; then
    fails+=("(d) backlog: cannot read epic slug from data/plans/$base/epic.md; backlog cross-check skipped")
  elif [ ! -d "$canon/stories" ]; then
    fails+=("(d) backlog: data/plans/$base/stories/ is missing")
  else
    read_backlog
    local story_id_list=() have_story=0 k j exact civar lc b inset
    for sf in "$canon"/stories/*.md; do
      [ -f "$sf" ] || continue
      have_story=1
      sid="$(fm_frontmatter_get "$sf" id)"
      [ -n "$sid" ] || { fails+=("(d) story file $(basename "$sf") has no id:"); continue; }
      story_id_list+=("$sid")
      exact=-1; civar=""; lc="$(fm_lower "$sid")"
      for ((k = 0; k < ${#BL_IDS[@]}; k++)); do
        if [ "${BL_IDS[$k]}" = "$sid" ]; then exact=$k
        elif [ "$(fm_lower "${BL_IDS[$k]}")" = "$lc" ]; then civar="${BL_IDS[$k]}"; fi
      done
      if [ "$exact" -lt 0 ]; then
        if [ -n "$civar" ]; then
          fails+=("(d) story \"$sid\" has only a stale case-variant backlog entry \"$civar\" (id not reconciled)")
        else
          fails+=("(d) story \"$sid\" (brief data/plans/$base/stories/$(basename "$sf")) has no backlog entry")
        fi
      elif [ "${BL_TAGS[$exact]}" != "$slug" ]; then
        fails+=("(d) backlog \"$sid\" carries tag [${BL_TAGS[$exact]}] not [$slug]")
      fi
    done
    [ "$have_story" -eq 1 ] || fails+=("(d) no story files under data/plans/$base/stories/")
    for ((k = 0; k < ${#BL_IDS[@]}; k++)); do
      [ "${BL_TAGS[$k]}" = "$slug" ] || continue
      b="${BL_IDS[$k]}"; inset=0
      for ((j = 0; j < ${#story_id_list[@]}; j++)); do
        [ "${story_id_list[$j]}" = "$b" ] && { inset=1; break; }
      done
      [ "$inset" -eq 1 ] || fails+=("(e) backlog \"$b\" carries tag [$slug] but no story file has that id (orphan)")
    done
  fi

  if [ "${#fails[@]}" -gt 0 ]; then
    {
      printf 'verify FAILED for umbrella "%s" (epic "%s", data/plans/%s):\n' "$UMBRELLA_ID" "$slug" "$base"
      for m in "${fails[@]}"; do printf '  - %s\n' "$m"; done
    } >&2
    return 1
  fi
  say "verify OK: epic \"$slug\" is canonical at data/plans/$base, the umbrella back-symlink resolves, the .promoted marker is correct, and every story has a matching queued brief."
  return 0
}

# --- arg parse --------------------------------------------------------------
MODE=promote
case "${1-}" in
  verify) MODE=verify; shift ;;
  promote) MODE=promote; shift ;;
esac

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

if [ "$MODE" = verify ]; then
  do_verify
  exit $?
fi

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
    # Skip the post-promote back-symlink (points at data/plans/<epic>): it is not
    # a fresh source, so a re-run falls through to the .promoted reconcile path.
    [ -L "${d%/}" ] && continue
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

# --- validate the epic against the single contract owner ---------------------
# fm-epic-lint.sh is THE check for "is this epic valid" (the seven story keys,
# lower-kebab unique ids matching filenames, matching epic slug, registered
# repos, valid pr_base, exactly one gate, acyclic depends, resolving plan
# pointer). Promote runs it FIRST, before any mutation, so a contract failure
# writes nothing - the same enforcement the epic-review gate applies at authoring
# time. FM_PROJECTS_REG pins the lint's registry to the exact one promote uses.
FM_PROJECTS_REG="$REG" "$LINT" "$EPIC_DIR" >/dev/null \
  || die "epic \"$EPIC_BASE\" fails the epic/story contract (see the lint problems above); fix the epic before promoting"

# --- parse what the seed/branch steps need (the contract already holds) -------
# The lint validated the epic; here we only READ the fields promote seeds from,
# using the shared parser so there is no second copy of frontmatter parsing.
EPIC_SLUG="$(fm_frontmatter_get "$EPIC_MD" epic)"

EPIC_REPOS_RAW="$(fm_frontmatter_get "$EPIC_MD" repos)"
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

story_ids=()
story_repos=()
story_kinds=()
story_titles=()
story_files=()

story_count=0
for sf in "$STORIES_DIR"/*.md; do
  [ -f "$sf" ] || continue
  story_count=$((story_count + 1))
  base="$(basename "$sf")"

  sid="$(fm_frontmatter_get "$sf" id)"
  srepo="$(fm_frontmatter_get "$sf" repo)"
  skind="$(fm_frontmatter_get "$sf" kind)"
  [ -n "$skind" ] || skind=ship
  shead="$(fm_heading_of "$sf")"
  [ -n "$shead" ] || shead="$sid"

  story_ids+=("$sid")
  story_repos+=("$srepo")
  story_kinds+=("$skind")
  story_titles+=("[$EPIC_SLUG] $shead")
  story_files+=("$base")
done

# --- plan the backlog reconcile against the current backlog ------------------
# Read the existing backlog and classify each story into add / reconcile /
# rename, and detect any drift this script will NOT auto-resolve. Both backends
# render to the same data/backlog.md, so read_backlog is backend-agnostic. The
# whole plan (including the refuse decision) is computed HERE, before any write,
# so an unresolvable-drift failure leaves the backlog untouched.
read_backlog

to_add_idx=()      # story indices needing a fresh seed
recon_story=()     # story indices whose exact-id entry drifted (title/repo/kind)
rename_story=()    # story indices whose entry is a case/kebab-variant id
rename_from=()     # parallel to rename_story: the current (wrong) backlog id
refuse=()          # drift this script will not auto-resolve

# Track which backlog entries a story claims, so an unclaimed epic-tagged task is
# reported as an orphan rather than silently ignored.
bl_claimed=()
for ((k = 0; k < ${#BL_IDS[@]}; k++)); do bl_claimed[k]=0; done

for ((i = 0; i < ${#story_ids[@]}; i++)); do
  sid="${story_ids[$i]}"
  lc_sid="$(fm_lower "$sid")"
  exact=-1
  ci_idx=()
  for ((k = 0; k < ${#BL_IDS[@]}; k++)); do
    if [ "${BL_IDS[$k]}" = "$sid" ]; then
      exact=$k
    elif [ "$(fm_lower "${BL_IDS[$k]}")" = "$lc_sid" ]; then
      ci_idx+=("$k")
    fi
  done

  if [ "$exact" -ge 0 ]; then
    bl_claimed[exact]=1
    if [ "${#ci_idx[@]}" -gt 0 ]; then
      # Both the exact id and a case-variant are present: a real double-seed.
      # Refuse rather than guess which to delete.
      for k in ${ci_idx[@]+"${ci_idx[@]}"}; do bl_claimed[k]=1; done
      refuse+=("story \"$sid\" is present AND has a case-variant seed (${BL_IDS[${ci_idx[0]}]}); reconcile by hand")
    elif [ "${BL_REPOS[$exact]}" != "${story_repos[$i]}" ] \
      || [ "${BL_KINDS[$exact]}" != "${story_kinds[$i]}" ] \
      || [ "${BL_TITLES[$exact]}" != "${story_titles[$i]}" ]; then
      recon_story+=("$i")
    fi
  elif [ "${#ci_idx[@]}" -eq 1 ]; then
    # A story FILE renamed to a case/kebab variant of its backlog id (the aimica
    # LH-01 -> lh-01 failure): rewrite the id rather than orphaning it.
    k="${ci_idx[0]}"
    bl_claimed[k]=1
    rename_story+=("$i")
    rename_from+=("${BL_IDS[$k]}")
  elif [ "${#ci_idx[@]}" -gt 1 ]; then
    for k in "${ci_idx[@]}"; do bl_claimed[k]=1; done
    refuse+=("story \"$sid\" matches multiple case-variant backlog ids; reconcile by hand")
  else
    to_add_idx+=("$i")
  fi
done

# Any unclaimed backlog task carrying THIS epic's tag matches no story: a stale
# or foreign seed this script must not silently delete.
for ((k = 0; k < ${#BL_IDS[@]}; k++)); do
  [ "${bl_claimed[$k]}" = "1" ] && continue
  [ "${BL_TAGS[$k]}" = "$EPIC_SLUG" ] \
    && refuse+=("backlog task \"${BL_IDS[$k]}\" carries tag [$EPIC_SLUG] but matches no story in this epic")
done

if [ "${#refuse[@]}" -gt 0 ]; then
  {
    printf 'error: cannot promote epic "%s": the backlog has drift this script will not auto-resolve:\n' "$EPIC_SLUG"
    for m in "${refuse[@]}"; do printf '  - %s\n' "$m"; done
    printf 'Reconcile the backlog by hand (tasks-axi rm/rename) so ids + [%s] tags match the story files, then re-run.\n' "$EPIC_SLUG"
  } >&2
  exit 1
fi

# ============================================================================
# Validation passed. From here we MUTATE (move + seed), idempotently.
# ============================================================================

# --- move the epic dir into data/plans/ -------------------------------------
# The epic is canonical in data/plans (durable + synced on homes where data/ is
# a git repo), and the umbrella keeps only a BACK-SYMLINK to it, so the captain
# can keep designing the epic in the lab (next to repos/) with edits writing
# through to the real files - one source of truth, no duplicate. The umbrella is
# machine-local scratch and never synced, so an absolute link target is stable
# and correct regardless of the cwd it is read from. Idempotent: replaces a
# stale link, never errors on a re-run, and never leaves a dangling link.
ensure_backsymlink() {
  [ -d "$EPIC_DST" ] || return 0   # canonical dir absent: create no dangling link
  local link="$UMBRELLA_DIR/plans/$EPIC_BASE" target
  target="$(cd "$PLANS_DST" && pwd)/$EPIC_BASE"
  mkdir -p "$UMBRELLA_DIR/plans" || die "cannot create $UMBRELLA_DIR/plans"
  # A real dir/file at the link path (a stale pre-symlink copy) must go first;
  # an existing symlink is replaced in place by `ln -sfn`.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    rm -rf -- "$link" || die "cannot remove stale $link before linking"
  fi
  ln -sfn "$target" "$link" || die "cannot create back-symlink $link -> $target"
}

mkdir -p "$PLANS_DST" || die "cannot create $PLANS_DST"

if [ -n "$EPIC_SRC" ]; then
  # Record the promotion target BEFORE the move so a crash between move and seed
  # still lets a re-run find the moved copy.
  printf '%s\n' "$EPIC_BASE" > "$MARKER" || die "cannot write promote marker $MARKER"
  if [ -e "$EPIC_DST" ]; then
    # Target already exists (a prior interrupted run, or an unrelated collision).
    if diff -rq "$EPIC_SRC" "$EPIC_DST" >/dev/null 2>&1; then
      rm -rf -- "$EPIC_SRC" || die "cannot remove already-promoted source $EPIC_SRC"
      ensure_backsymlink
      say "epic dir already at data/plans/$EPIC_BASE (identical); replaced the umbrella copy with a back-symlink."
    else
      die "data/plans/$EPIC_BASE already exists and DIFFERS from the umbrella copy; refusing to clobber. Reconcile them by hand, then re-run."
    fi
  else
    mv "$EPIC_SRC" "$EPIC_DST" || die "failed to move $EPIC_SRC -> $EPIC_DST"
    ensure_backsymlink
    say "moved epic dir -> data/plans/$EPIC_BASE (umbrella keeps a back-symlink to it)"
  fi
else
  ensure_backsymlink   # heal an older plain-mv promote that left no back-symlink
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

# --- converge already-present stories to the canonical epic ------------------
# A story FILE renamed to a case/kebab variant of its backlog id: rewrite the id
# (backend-agnostic line edit), then refresh its derived fields.
renamed=0
for ((r = 0; r < ${#rename_story[@]}; r++)); do
  i="${rename_story[$r]}"
  old="${rename_from[$r]}"
  sid="${story_ids[$i]}"
  rewrite_backlog_id "$old" "$sid"
  reconcile_fields "$sid" "${story_titles[$i]}" "${story_repos[$i]}" "${story_kinds[$i]}"
  say "renamed backlog id $old -> $sid and refreshed its fields  [$EPIC_SLUG]"
  renamed=$((renamed + 1))
done

# An already-present story whose title/repo/kind drifted from the current
# frontmatter: rewrite the derived fields in place (state and notes preserved).
reconciled=0
for ((r = 0; r < ${#recon_story[@]}; r++)); do
  i="${recon_story[$r]}"
  sid="${story_ids[$i]}"
  reconcile_fields "$sid" "${story_titles[$i]}" "${story_repos[$i]}" "${story_kinds[$i]}"
  say "refreshed backlog entry $sid to match the story  [$EPIC_SLUG]"
  reconciled=$((reconciled + 1))
done

# --- report + STOP at the sign-off gate -------------------------------------
correct=$((story_count - added - renamed - reconciled))
say ""
say "Promoted umbrella \"$UMBRELLA_ID\" -> epic \"$EPIC_SLUG\" (data/plans/$EPIC_BASE)."
say "  seeded: $added    reconciled: $reconciled    renamed: $renamed    already correct: $correct    total: $story_count"
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
