#!/usr/bin/env bash
# Carry a project's untracked LOCAL MATERIAL into a task worktree, so a worker can
# start a dev server, run e2e tests, and take screenshots without anyone copying
# credentials by hand.
#
# Usage: fm-local-material.sh entries <project-path>
#        fm-local-material.sh apply <project-path> <worktree-path>
#        fm-local-material.sh brief-section <project-path>
#        fm-local-material.sh validate [<project-path>]
#
#   entries        print one "<mode>\t<relative-path>" line per configured entry,
#                  in configured order. Prints nothing and succeeds when this
#                  project configures no material.
#   apply          place every configured entry into <worktree-path>, then print
#                  one summary line. Refuses, without placing anything, when a
#                  listed source is missing.
#   brief-section  print the worker-facing operating rules for the material this
#                  project configures, as a launch-brief section. Prints nothing
#                  and succeeds when this project configures no material.
#   validate       check the configuration file, or one project's entry in it,
#                  and print nothing on success.
#
# A project that configures no material leaves every subcommand a silent no-op,
# so an unconfigured fleet behaves exactly as it did before this file existed.
#
# WHY THIS EXISTS
# Firstmate clones a project from its forge, so the clone holds only what the
# forge tracks. Every pooled worktree is cut from that clone, so a worker that
# needs a running app finds no .env, no stored browser session, and no local MCP
# configuration. Observed on a live fleet, none of it hypothetical: a worker
# that found no .env copied one from a sibling checkout, got PRODUCTION, and
# wrote rows into real data; a second task lost every one of its live-validation
# scenarios because no server could start; a third burned half an hour of its
# step budget on setup and timed out twice. The cost of the absence is not
# inconvenience.
#
# WHY IT IS HERE RATHER THAN IN TREEHOUSE
# Treehouse's configuration is a pool size and a root. It has no per-repo setup
# step and no untracked-file list, so there is no hook to carry this. The
# placement therefore belongs to the spawn, immediately after the worktree is
# acquired. The shape is the one worktree helpers have long used for this: a
# per-repo list of untracked paths placed into every new worktree.
#
# WHY IT FAILS RATHER THAN SKIPS
# A missing listed source produces a worktree that looks ready and cannot test,
# which is exactly the state the three incidents above started from. A refusal
# at spawn costs one spawn; a silent skip costs a validation round, or a write
# against production. The list is explicit and per-project for the same reason:
# this must never become "copy whatever is lying around next door".
#
# LINK VERSUS COPY - BOTH MODES ARE LOAD-BEARING
#   link  A symlink to the source file. One source of truth: a rotated key
#         reaches every live worktree at once, and the secret exists in one
#         place on disk instead of one copy per worktree. This is the right
#         default for environment files.
#   copy  A real copy, made with timestamps PRESERVED. Required whenever the
#         consumer decides freshness by mtime, or re-mints the file in place.
#         A stored browser session is usually both: a Playwright global-setup
#         re-mints the saved session once it is older than a max-age constant,
#         and decides that by MTIME, so a copy that reset the timestamp would
#         present an expired session as brand new, and a symlink shared across
#         concurrent workers would race when one of them re-mints it.
#
# WHAT NOT TO LIST
# Anything a worktree must own separately. A per-worktree dev-server port file
# is the standard example: ports are derived per worktree precisely so
# concurrent workers do not collide, so carrying one everywhere would
# reintroduce the collision. Its absence is correct, not a gap.
#
# CONFIGURATION
# config/project-local-material.json, LOCAL and gitignored, inherited by
# secondmate homes. Schema and a worked example: docs/configuration.md
# "Project local material". Keys are project directory names.
#
#   {
#     "<project>": {
#       "source": "<absolute path>",       // optional; default: the project clone
#       "environments": {                  // optional; drives the brief's env rules
#         "default":         "<relative path>",
#         "production":      "<relative path>",
#         "production_note": "<why production is ever needed>"
#       },
#       "entries": [
#         { "path": "<relative path>", "mode": "link" },
#         { "path": "<relative path>", "mode": "copy" }
#       ]
#     }
#   }
#
# Every entry path is repository-relative: an absolute path, a ".." component, or
# a path that resolves to the project root is refused, so a manifest can never
# reach outside the source, write outside the worktree, or aim apply's clear at
# the worktree itself. A path git tracks is refused too, because tracked content
# arrives with the checkout and a manifest naming it is a configuration error
# rather than local material. So is a path the project does not gitignore: it
# would leave every worktree reading as having uncommitted changes, which blocks
# teardown's unlanded-work check and invites a worker to commit a credential.
#
# OPERATOR WORKFLOW
# Write the manifest, run `validate` to confirm it is well formed, then run
# `entries <project>` once per project to confirm each one resolves, then spawn.
# `entries` and `validate` are tooling for whoever writes the manifest rather
# than spawn-path code, which is why neither has a caller in bin/fm-spawn.sh:
# the manifest is hand-written and gitignored per machine, so without them a
# failed spawn would be the only way to learn it was wrong.
#
# SECURITY POSTURE
# This places live credentials into agent worktrees. That is the point, and it
# needs the captain's deliberate authorization rather than a default: an
# explicitly listed, reviewable, per-project mechanism is the right shape for
# that authorization, and an ad-hoc copy is the wrong one. The rules the worker
# is held to ship with the material: brief-section is their single owner,
# and bin/fm-spawn.sh puts them in the launch brief of every worker that
# receives material.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MANIFEST="$CONFIG/project-local-material.json"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# Read one project's manifest object into MANIFEST_JSON, or leave it empty when
# this project configures nothing. An absent manifest file is "nothing
# configured" for every project; a present but unreadable or malformed one is an
# error, because silently treating it as absent is how a fleet ends up believing
# material was placed that never was.
manifest_read() { # <project-key>
  local key=$1
  MANIFEST_JSON=
  [ -e "$MANIFEST" ] || return 0
  [ -f "$MANIFEST" ] || die "$MANIFEST is not a regular file"
  [ -r "$MANIFEST" ] || die "$MANIFEST is not readable"
  command -v jq >/dev/null 2>&1 ||
    die "$MANIFEST exists but jq is not installed; install jq or remove the file"
  jq empty "$MANIFEST" >/dev/null 2>&1 || die "$MANIFEST is not valid JSON"
  jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 ||
    die "$MANIFEST must be a JSON object keyed by project directory name"
  MANIFEST_JSON=$(jq -c --arg k "$key" '.[$k] // empty' "$MANIFEST") ||
    die "could not read project '$key' from $MANIFEST"
}

# Validate one project's object and echo its normalized entries as
# "<mode>\t<relative-path>" lines. Every refusal names the project and the
# offending value, because this file is hand-edited.
manifest_entries() { # <project-key> <manifest-json>
  local key=$1 json=$2 mode rel raw count seen=0
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json" ||
    die "$MANIFEST: project '$key' must be an object"
  jq -e 'has("entries") and (.entries | type == "array") and (.entries | length > 0)' \
    >/dev/null 2>&1 <<<"$json" ||
    die "$MANIFEST: project '$key' needs a non-empty \"entries\" array"
  count=$(jq -r '.entries | length' 2>/dev/null <<<"$json") ||
    die "$MANIFEST: project '$key' has a malformed \"entries\" array"
  # jq runs to completion before the loop rather than feeding it through a
  # process substitution. A jq failure inside one exits only that subshell, so
  # the loop would see no input and the caller would read a malformed manifest
  # as "nothing configured" - the one outcome this file must never produce.
  raw=$(jq -r '.entries[] | [(.mode // ""), (.path // "")] | @tsv' 2>/dev/null <<<"$json") ||
    die "$MANIFEST: project '$key' has a malformed entry; each one must be an object with \"path\" and \"mode\""
  while IFS=$'\t' read -r mode rel; do
    seen=$((seen + 1))
    case "$mode" in
      link|copy) ;;
      *) die "$MANIFEST: project '$key' entry '$rel' has mode '${mode:-<missing>}'; use \"link\" or \"copy\"" ;;
    esac
    manifest_check_relpath "$key" "$rel"
    printf '%s\t%s\n' "$mode" "$rel"
  done <<<"$raw"
  # An entry that produced no line is an entry that was silently dropped.
  [ "$seen" = "$count" ] ||
    die "$MANIFEST: project '$key' declares $count entries but only $seen could be read; fix the malformed one rather than shipping a partly equipped worktree"
}

# Refuse anything that could reach outside the source tree or write outside the
# worktree, and anything the tab-separated wire format cannot carry.
manifest_check_relpath() { # <project-key> <relative-path>
  local key=$1 rel=$2 component rest named=0
  [ -n "$rel" ] || die "$MANIFEST: project '$key' has an entry with an empty \"path\""
  case "$rel" in
    /*) die "$MANIFEST: project '$key' path '$rel' must be relative to the project, not absolute" ;;
    *$'\t'*|*$'\n'*) die "$MANIFEST: project '$key' path contains a tab or newline" ;;
  esac
  rest=$rel
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$rest" = "$component" ]; then rest=; else rest=${rest#*/}; fi
    case "$component" in
      ''|.) continue ;;
      ..) die "$MANIFEST: project '$key' path '$rel' escapes the project with '..'" ;;
      *) named=1 ;;
    esac
  done
  # A path made only of "." components names the project root itself. Apply
  # clears a destination before placing it, so accepting one would point that
  # clear at the whole worktree. Nothing downstream may be the only thing
  # standing between a manifest typo and a wiped worktree.
  [ "$named" = 1 ] ||
    die "$MANIFEST: project '$key' path '$rel' names the project root rather than a file inside it"
}

manifest_source_root() { # <project-key> <manifest-json> <project-path>
  local key=$1 json=$2 project=$3 source
  source=$(jq -r '.source // ""' <<<"$json")
  [ -n "$source" ] || { printf '%s\n' "$project"; return 0; }
  case "$source" in
    /*) ;;
    *) die "$MANIFEST: project '$key' \"source\" must be an absolute path, got '$source'" ;;
  esac
  [ -d "$source" ] ||
    die "$MANIFEST: project '$key' \"source\" directory '$source' does not exist"
  (cd -P -- "$source" && pwd -P) ||
    die "$MANIFEST: project '$key' \"source\" directory '$source' could not be resolved"
}

project_key() { # <project-path>
  local project=$1
  [ -n "$project" ] || die "a project path is required"
  basename -- "${project%/}"
}

# A home with no manifest at all can never have a spawn refused by this file, so
# the absent case returns before the project path is even resolved. Opting in is
# what makes any of the refusals below reachable.
manifest_absent() {
  [ ! -e "$MANIFEST" ]
}

project_abs() { # <project-path>
  local project=$1
  [ -d "$project" ] || die "project path '$project' is not a directory"
  (cd -P -- "$project" && pwd -P) || die "project path '$project' could not be resolved"
}

# --- entries ----------------------------------------------------------------

cmd_entries() { # <project-path>
  local project key
  manifest_absent && return 0
  project=$(project_abs "${1:-}") || exit 1
  key=$(project_key "$project") || exit 1
  manifest_read "$key"
  [ -n "$MANIFEST_JSON" ] || return 0
  manifest_entries "$key" "$MANIFEST_JSON"
}

# --- apply ------------------------------------------------------------------

# Place every configured entry. Sources are checked up front, as a set, so a
# manifest with one missing file refuses before placing the others rather than
# leaving a half-equipped worktree behind.
cmd_apply() { # <project-path> <worktree-path>
  local project worktree key source mode rel src dest placed=0
  manifest_absent && return 0
  project=$(project_abs "${1:-}") || exit 1
  [ -n "${2:-}" ] || die "apply needs a worktree path"
  [ -d "$2" ] || die "worktree path '$2' is not a directory"
  worktree=$(cd -P -- "$2" && pwd -P) || die "worktree path '$2' could not be resolved"
  key=$(project_key "$project") || exit 1
  manifest_read "$key"
  [ -n "$MANIFEST_JSON" ] || return 0

  local entries
  entries=$(manifest_entries "$key" "$MANIFEST_JSON") || exit 1
  source=$(manifest_source_root "$key" "$MANIFEST_JSON" "$project") || exit 1

  [ "$source" != "$worktree" ] ||
    die "$MANIFEST: project '$key' source resolves to the worktree itself ($worktree)"

  while IFS=$'\t' read -r mode rel; do
    [ -n "$mode" ] || continue
    src="$source/$rel"
    [ -e "$src" ] ||
      die "project '$key' lists '$rel' as local material, but '$src' does not exist; place it there or drop the entry - a worktree without it cannot run the app or its tests"
    if git -C "$worktree" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      die "$MANIFEST: project '$key' lists '$rel', which git tracks; local material is untracked material only"
    fi
    # Material the project does not ignore would show up as an untracked change
    # in every worktree it is placed in: the unlanded-work check would then
    # refuse teardown for every task, and a worker staging everything could
    # commit a credential. Both are worse than refusing the entry here. A
    # directory-only ignore pattern matches only with the trailing slash, which
    # is why the second form is tried before refusing.
    if ! git -C "$worktree" check-ignore -q -- "$rel" 2>/dev/null &&
      ! git -C "$worktree" check-ignore -q -- "$rel/" 2>/dev/null; then
      die "$MANIFEST: project '$key' lists '$rel', which $(basename -- "$project") does not gitignore; add it to that project's .gitignore first, or every worktree carrying it reads as having uncommitted changes"
    fi
  done <<<"$entries"

  while IFS=$'\t' read -r mode rel; do
    [ -n "$mode" ] || continue
    src="$source/$rel"
    dest="$worktree/$rel"
    # A pooled worktree is reused, so it can still hold the previous task's
    # material. Every path reaching here is manifest-validated as relative and
    # git-untracked, so replacing it cannot touch tracked work.
    rm -rf -- "$dest" 2>/dev/null || die "could not clear '$dest' before placing '$rel'"
    mkdir -p -- "$(dirname -- "$dest")" || die "could not create the parent directory for '$rel'"
    case "$mode" in
      link)
        ln -s -- "$src" "$dest" || die "could not link '$rel' into $worktree"
        ;;
      copy)
        # -p preserves MTIME, which is load-bearing rather than tidy: a consumer
        # that decides staleness by timestamp would read a fresh copy of an
        # expired file as current and use it, instead of re-minting it.
        if [ -d "$src" ]; then
          cp -Rp -- "$src" "$dest" || die "could not copy directory '$rel' into $worktree"
        else
          cp -p -- "$src" "$dest" || die "could not copy '$rel' into $worktree"
        fi
        ;;
    esac
    placed=$((placed + 1))
  done <<<"$entries"

  printf 'local-material: placed %d entr%s for %s from %s\n' \
    "$placed" "$([ "$placed" = 1 ] && printf 'y' || printf 'ies')" "$key" "$source"
}

# --- brief-section ----------------------------------------------------------

# The single owner of the worker-facing operating rules. They ship with the
# material because material that arrives without them is what produced the
# production write: a worker that needs a server running will reach for whatever
# makes it start. "Do not read them" alone already proved too vague, so the rule
# is stated as the concrete difference between letting a tool consume a file and
# looking inside it.
# shellcheck disable=SC2016 # Backticks in these format strings are Markdown code spans, not command substitution.
cmd_brief_section() { # <project-path>
  local project key entries mode rel env_default env_prod env_note
  manifest_absent && return 0
  project=$(project_abs "${1:-}") || exit 1
  key=$(project_key "$project") || exit 1
  manifest_read "$key"
  [ -n "$MANIFEST_JSON" ] || return 0
  entries=$(manifest_entries "$key" "$MANIFEST_JSON") || exit 1
  [ -n "$entries" ] || return 0

  env_default=$(jq -r '.environments.default // ""' <<<"$MANIFEST_JSON")
  env_prod=$(jq -r '.environments.production // ""' <<<"$MANIFEST_JSON")
  env_note=$(jq -r '.environments.production_note // ""' <<<"$MANIFEST_JSON")

  cat <<'EOF'
# Local material in this worktree
This section governs the project's own credential, configuration, and session files, which were placed in this worktree for you so you can run a dev server, run e2e tests, and take screenshots without anyone copying credentials by hand.
It supersedes any conflicting instruction about how to use those files.

Placed here for this task:
EOF
  while IFS=$'\t' read -r mode rel; do
    [ -n "$mode" ] || continue
    case "$mode" in
      link) printf -- '- `%s` (a link to the project'"'"'s own copy, so a rotated value reaches you immediately)\n' "$rel" ;;
      copy) printf -- '- `%s` (a copy, with its original timestamp preserved)\n' "$rel" ;;
    esac
  done <<<"$entries"

  if [ -n "$env_default" ] || [ -n "$env_prod" ]; then
    printf '\n'
    printf 'Which environment to run in:\n'
    if [ -n "$env_default" ]; then
      printf -- '- A dev server defaults to STAGING (`%s`). Start it that way unless the captain asks for the other environment by name.\n' "$env_default"
    fi
    if [ -n "$env_prod" ]; then
      if [ -n "$env_note" ]; then
        printf -- '- `%s` is PRODUCTION. Use it only when the captain names it, and only for the reason it exists: %s.\n' "$env_prod" "$env_note"
      else
        printf -- '- `%s` is PRODUCTION. Use it only when the captain names it.\n' "$env_prod"
      fi
      if [ -n "$env_default" ]; then
        printf -- '- Never reach for `%s` because staging would not start. A dev server that will not come up in staging is a blocker to report, not a reason to switch to production.\n' "$env_prod"
      fi
    fi
    if [ -n "$env_default" ]; then
      printf -- '- e2e tests and screenshots ALWAYS run in staging (`%s`). There is no exception, and no captain request changes this one.\n' "$env_default"
    fi
  fi

  cat <<'EOF'

How to handle these files:
These files are inputs to tools, never reading material.
You may let a process consume one: start a dev server with it, point a test runner at it, pass its path to a command that needs it.
You may not open one, print one, `cat` one, `head` one, `echo` one, grep a value out of one, or load one into your own context by any other means.
You may not put a value from one into a status line, a terminal message, a commit, a pull request, a report, a comment, or a test fixture.
If a tool needs a value from one of these files, give the tool the file and let it read the value; do not read the value and hand it over yourself.
Never copy one of these files out of this worktree, and never copy one in from anywhere else - if something you need is missing, that is a blocker to report, not a file to go find.
EOF
}

# --- validate ---------------------------------------------------------------

cmd_validate() { # [<project-path>]
  local key keys project
  if [ -n "${1:-}" ]; then
    project=$(project_abs "$1") || exit 1
    key=$(project_key "$project") || exit 1
    manifest_read "$key"
    [ -n "$MANIFEST_JSON" ] || return 0
    manifest_entries "$key" "$MANIFEST_JSON" >/dev/null || exit 1
    manifest_source_root "$key" "$MANIFEST_JSON" "$project" >/dev/null || exit 1
    return 0
  fi
  [ -e "$MANIFEST" ] || return 0
  manifest_read ''
  keys=$(jq -r 'keys[]' "$MANIFEST" 2>/dev/null) || die "$MANIFEST: could not list projects"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    manifest_read "$key"
    [ -n "$MANIFEST_JSON" ] || continue
    manifest_entries "$key" "$MANIFEST_JSON" >/dev/null || exit 1
    # A source root is validated only when the manifest states one. The default
    # is the project clone, which validate has no path for and must not invent.
    if jq -e 'has("source")' >/dev/null 2>&1 <<<"$MANIFEST_JSON"; then
      manifest_source_root "$key" "$MANIFEST_JSON" '' >/dev/null || exit 1
    fi
  done <<<"$keys"
}

case "${1:-}" in
  entries)       shift; cmd_entries "$@" ;;
  apply)         shift; cmd_apply "$@" ;;
  brief-section) shift; cmd_brief_section "$@" ;;
  validate)      shift; cmd_validate "$@" ;;
  '')            usage >&2; exit 1 ;;
  *)             printf 'error: unknown subcommand %s\n' "$1" >&2; usage >&2; exit 1 ;;
esac
