#!/usr/bin/env bash
# shellcheck disable=SC2034 # computed fields are output globals for sourcing callers.
# fm-epic-status-lib.sh - shared READ-ONLY model behind bin/fm-epic-status.sh and
# bin/fm-epic-dispatch-plan.sh. It closes the signed->crew cliff (report
# G-dispatch/G-route): both commands read the same computed model of an epic's
# dispatch readiness so the operator never hand-derives it.
#
# The model is built from three durable, already-owned sources, never re-derived:
#   - the epic dir under data/plans/<dir>/ (epic.md + stories/*.md), located by
#     its canonical `epic: <slug>` identity, same as bin/fm-epic-ship.sh.
#   - the backlog (data/backlog.md), whose `- [x]` Done state is the "merged"
#     signal a story dependency waits on (a merged story lands checked with a PR
#     url + `(merged ...)`), backend-agnostic (both backends render this file).
#   - bin/fm-epic-branch.sh verify, the one owner of "is epic/<slug> cut in repo",
#     called through the FM_EPIC_BRANCH_BIN seam so callers stay testable.
#
# This lib NEVER mutates and NEVER dispatches: dispatch stays firstmate judgment
# (bin/fm-epic-dispatch-plan.sh only PRINTS the commands). The branch check is
# the only network call and is made explicitly by the caller, not at source time.

EPIC_STATUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# epic_fm_get <file> <key>: value of `key:` inside the leading --- ... --- YAML
# frontmatter, trimmed. Empty (rc 0) when absent so callers test emptiness. Same
# mechanism as bin/fm-umbrella-promote.sh's private reader (kept local so this lib
# sources nothing heavier than itself).
epic_fm_get() {
  awk -v key="$2" '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm {
      line=$0
      if (sub("^" key "[[:space:]]*:[[:space:]]*", "", line)) {
        sub(/[[:space:]]+#.*$/, "", line)   # strip a YAML inline comment ( # ...)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

# epic_heading_of <file>: first `# ` ATX heading text, or empty.
epic_heading_of() {
  awk '/^#[[:space:]]+/ { sub(/^#[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1"
}

# epic_split_list <raw>: print each element of a `key: [a, b, c]` or `key: a, b`
# frontmatter list on its own line (brackets stripped, comma/space split,
# trimmed). Used for both `repos:` and a story's `depends:`.
epic_split_list() {
  local raw=$1 tok
  raw="${raw#[}"
  raw="${raw%]}"
  local IFS=', '
  for tok in $raw; do
    [ -n "$tok" ] && printf '%s\n' "$tok"
  done
}

# epic_status_find_dir <plans-dir> <slug>: print the epic dir whose epic.md
# frontmatter carries `epic: <slug>`. rc 1 (nothing printed) when none matches.
# Same canonical-identity locate as bin/fm-epic-ship.sh's find_epic_dir.
epic_status_find_dir() {
  local plans=$1 slug=$2 d
  [ -d "$plans" ] || return 1
  for d in "$plans"/*/; do
    [ -f "${d}epic.md" ] || continue
    if [ "$(epic_fm_get "${d}epic.md" epic)" = "$slug" ]; then
      printf '%s\n' "${d%/}"
      return 0
    fi
  done
  return 1
}

# epic_backlog_state <backlog-file> <id>: "done" if the backlog carries the story
# checked (`- [x] <id> ...`), "queued" if present unchecked, "" if absent. Both
# backends render to data/backlog.md, so this is backend-agnostic.
epic_backlog_state() {
  local backlog=$1 id=$2
  [ -f "$backlog" ] || { printf '\n'; return 0; }
  awk -v id="$id" '
    {
      pfx=substr($0, 1, 6)
      if (pfx ~ /^- \[.\] /) {
        after=substr($0, 7); sp=index(after, " ")
        tid=(sp>0 ? substr(after, 1, sp-1) : after)
        if (tid==id) { print (substr($0,4,1)=="x" ? "done" : "queued"); found=1; exit }
      }
    }
    END { if (!found) print "" }
  ' "$backlog"
}

# epic_status_load <epic-dir> <backlog-file>: populate the shared model globals
# from the epic dir + backlog. Every array is parallel and 0-indexed by story.
#   EPIC_SLUG EPIC_STATUS EPIC_SIGNED_OFF EPIC_TITLE   scalars from epic.md
#   EPIC_REPOS[]                                       involved repos (epic + story union)
#   ST_ID[] ST_REPO[] ST_PRBASE[] ST_DELIVERY[] ST_KIND[] ST_TITLE[]
#   ST_DEPENDS[]     space-joined declared deps ("" = none)
#   ST_STATE[]       done | dispatchable | blocked | unseeded
#   ST_BLOCKEDBY[]   space-joined UNMET deps (deps whose backlog state != done)
# Returns 1 (nothing populated) if epic.md/stories are missing.
epic_status_load() {
  local dir=$1 backlog=$2 epic_md="$1/epic.md" stories_dir="$1/stories"
  [ -f "$epic_md" ] || return 1
  [ -d "$stories_dir" ] || return 1

  EPIC_SLUG="$(epic_fm_get "$epic_md" epic)"
  EPIC_STATUS="$(epic_fm_get "$epic_md" status)"
  EPIC_SIGNED_OFF="$(epic_fm_get "$epic_md" signed_off)"
  EPIC_TITLE="$(epic_fm_get "$epic_md" title)"
  [ -n "$EPIC_TITLE" ] || EPIC_TITLE="$(epic_heading_of "$epic_md")"

  EPIC_REPOS=()
  local r
  while IFS= read -r r; do EPIC_REPOS+=("$r"); done < <(epic_split_list "$(epic_fm_get "$epic_md" repos)")

  ST_ID=(); ST_REPO=(); ST_PRBASE=(); ST_DELIVERY=(); ST_KIND=(); ST_TITLE=()
  ST_DEPENDS=(); ST_STATE=(); ST_BLOCKEDBY=()

  local sf sid srepo spr sdel skind shead deps dep unmet state seen
  for sf in "$stories_dir"/*.md; do
    [ -f "$sf" ] || continue
    sid="$(epic_fm_get "$sf" id)"
    [ -n "$sid" ] || continue
    srepo="$(epic_fm_get "$sf" repo)"
    spr="$(epic_fm_get "$sf" pr_base)"
    sdel="$(epic_fm_get "$sf" delivery)"   # epflow-07's optional key; "" when absent
    skind="$(epic_fm_get "$sf" kind)"
    [ -n "$skind" ] || skind=ship
    shead="$(epic_heading_of "$sf")"
    [ -n "$shead" ] || shead="$sid"

    deps=""
    while IFS= read -r dep; do deps="${deps:+$deps }$dep"; done < <(epic_split_list "$(epic_fm_get "$sf" depends)")

    # Unmet deps = declared deps not yet Done (merged) in the backlog. A dep absent
    # from the backlog is unmet (not merged), same as an unchecked one.
    unmet=""
    for dep in $deps; do
      [ "$(epic_backlog_state "$backlog" "$dep")" = "done" ] || unmet="${unmet:+$unmet }$dep"
    done

    case "$(epic_backlog_state "$backlog" "$sid")" in
      done)   state="done" ;;
      "")     state="unseeded" ;;
      *)      if [ -z "$unmet" ]; then state="dispatchable"; else state="blocked"; fi ;;
    esac

    ST_ID+=("$sid"); ST_REPO+=("$srepo"); ST_PRBASE+=("$spr"); ST_DELIVERY+=("$sdel")
    ST_KIND+=("$skind"); ST_TITLE+=("$shead"); ST_DEPENDS+=("$deps")
    ST_STATE+=("$state"); ST_BLOCKEDBY+=("$unmet")

    # Fold a story repo not already in the epic repos: it is still involved.
    if [ -n "$srepo" ]; then
      seen=0
      for r in ${EPIC_REPOS[@]+"${EPIC_REPOS[@]}"}; do [ "$r" = "$srepo" ] && { seen=1; break; }; done
      [ "$seen" -eq 1 ] || EPIC_REPOS+=("$srepo")
    fi
  done
  return 0
}

# epic_collect_bases: after epic_status_load, populate the distinct set of epic
# base branches the STORIES actually declare (pr_base: epic/<X>), keyed by repo -
# these are the branches that must exist before a story can be cut, so they, not a
# nominal epic/<epic-slug>, drive both the status branch check and the dispatch
# plan's cut step. This is what makes the tool correct when a story's base branch
# name has drifted from the epic slug (the aimica `lh` vs `epic/aimica-learning-hub`
# case), which it also records so callers can surface it.
#   EB_SLUG[] EB_REPO[]   parallel, one per distinct (base-slug, repo) pair
#   EB_DRIFT              space-joined base-slugs that differ from EPIC_SLUG ("" = none)
epic_collect_bases() {
  EB_SLUG=(); EB_REPO=(); EB_DRIFT=""
  local i base bslug repo j seen drift_seen
  for i in "${!ST_ID[@]}"; do
    base="${ST_PRBASE[$i]}"
    case "$base" in epic/*) bslug="${base#epic/}" ;; *) continue ;; esac
    [ -n "$bslug" ] || continue
    repo="${ST_REPO[$i]}"
    [ -n "$repo" ] || continue
    seen=0
    for ((j = 0; j < ${#EB_SLUG[@]}; j++)); do
      [ "${EB_SLUG[$j]}" = "$bslug" ] && [ "${EB_REPO[$j]}" = "$repo" ] && { seen=1; break; }
    done
    [ "$seen" -eq 1 ] && continue
    EB_SLUG+=("$bslug"); EB_REPO+=("$repo")
    if [ "$bslug" != "$EPIC_SLUG" ]; then
      case " $EB_DRIFT " in *" $bslug "*) drift_seen=1 ;; *) drift_seen=0 ;; esac
      [ "$drift_seen" -eq 1 ] || EB_DRIFT="${EB_DRIFT:+$EB_DRIFT }$bslug"
    fi
  done
}

# epic_branch_present <epic-branch-bin> <slug> <repo>: 0 iff epic/<slug> is cut in
# <repo>, via the one owner of that verdict (bin/fm-epic-branch.sh verify). All
# output is swallowed; the exit code is the answer.
epic_branch_present() {
  "$1" verify "$2" "$3" >/dev/null 2>&1
}

# epic_dispatch_owner <secondmates-registry> <repo>...: print the dispatch-owner
# line for the involved repos. Routing is by a secondmate's natural-language
# SCOPE (firstmate judgment, AGENTS.md section 7), NOT the non-exclusive project
# clone list, so this never hard-routes: it prints "this home" and, when a
# registered secondmate's project list mentions an involved repo, surfaces that
# secondmate + its scope as a candidate for firstmate to confirm. An absent or
# empty registry means no secondmates -> this home, full stop.
epic_dispatch_owner() {
  local reg=$1; shift
  local repos=("$@")
  printf 'this home'
  { [ -f "$reg" ] && [ ! -L "$reg" ]; } || { printf '\n'; return 0; }

  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$EPIC_STATUS_LIB_DIR/fm-secondmate-registry-lib.sh"

  local line repo proj candidates="" plist
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    plist=" $(printf '%s' "$SECONDMATE_REGISTRY_PROJECTS" | tr ',' ' ') "
    for repo in ${repos[@]+"${repos[@]}"}; do
      case "$plist" in *" $repo "*)
        candidates="${candidates}
  candidate secondmate \"$SECONDMATE_REGISTRY_ID\" clones $repo - scope: $SECONDMATE_REGISTRY_SCOPE"
        break ;;
      esac
    done
  done < "$reg"

  if [ -n "$candidates" ]; then
    printf ' (confirm routing by scope, not clone list):%s\n' "$candidates"
  else
    printf '\n'
  fi
}
