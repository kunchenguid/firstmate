#!/usr/bin/env bash
# Shared deploy classification: what is pending, and which of it the captain owns.
#
# One classifier, sourced by bin/fm-deploy-status.sh (which reports) and
# bin/fm-deploy.sh (which refuses), so the two can never disagree about whether
# a range needs the captain's permission.
#
# The safety decision is made on the whole range's changed-path set
# (`git diff --name-only <from> <to>`), never per commit. A merge commit's
# `git diff-tree` output is empty, so a per-commit walk would silently report a
# merged design change as auto-deployable. Per-commit listing is used only for
# the human-readable pending display.
#
# A policy file is a plain list of path patterns, one per line, `#` comments and
# blank lines ignored. A pattern is a bash pattern in which `*` matches any
# characters INCLUDING `/`, so `dashboard/v2/src/**` covers the whole subtree and
# `openspec/changes/dashboard-v21-*` covers every file under every matching
# directory. docs/configuration.md owns the operator-facing description.
#
# No policy file means no deploy automation for that project at all: every entry
# point that consumes this library stays inert rather than defaulting to
# auto-deployable. Absence is the off switch, not permission.
#
# Sourced only; no side effects on source.

# fm_deploy_config_dir <home>
fm_deploy_config_dir() { printf '%s/config' "${1%/}"; }

# fm_deploy_policy_file <home> <project>
fm_deploy_policy_file() {
  printf '%s/deploy-policy/%s' "$(fm_deploy_config_dir "$1")" "$2"
}

# fm_deploy_target_file <home> <project>
fm_deploy_target_file() {
  printf '%s/deploy-target/%s' "$(fm_deploy_config_dir "$1")" "$2"
}

# fm_deploy_policy_readable <file>
# A policy must be a regular file, never a symlink: it decides what ships
# without the captain, so it is not something an unrelated link may redirect.
fm_deploy_policy_readable() {
  [ -n "${1:-}" ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

# fm_deploy_policy_patterns <policy-file>
# Prints one pattern per line, comments and blanks removed.
fm_deploy_policy_patterns() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # Trim surrounding whitespace without a subshell.
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done <"$1"
}

# fm_deploy_path_captain_pattern <path> <pattern>...
# Prints the first pattern that claims <path> and returns 0; returns 1 when none
# does.
fm_deploy_path_captain_pattern() {
  local path=$1 pattern
  shift
  for pattern in "$@"; do
    # Deliberately unquoted: $pattern is a bash pattern, and `*` crosses `/`
    # here because this is string matching, not pathname expansion.
    # shellcheck disable=SC2053
    if [[ $path == $pattern ]]; then
      printf '%s\n' "$pattern"
      return 0
    fi
  done
  return 1
}

# fm_deploy_sha_valid <sha>
# A deployed checkout must report a full 40-hex commit. Anything else - a branch
# name, a short sha, an error string - is a checkout that deploy/PROVISIONING.md
# forbids ("an exact commit, never a moving branch"), and must surface rather
# than be treated as a deployable baseline.
fm_deploy_sha_valid() {
  case "${1:-}" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# fm_deploy_classify <repo> <from-sha> <to-sha> <policy-file>
#
# Sets, on success:
#   FM_DEPLOY_PENDING       newline-separated "<short-sha> <subject>" pending commits
#   FM_DEPLOY_PENDING_COUNT how many
#   FM_DEPLOY_CAPTAIN       newline-separated "<pattern>\t<path>" captain-owned matches
#   FM_DEPLOY_CAPTAIN_COUNT how many changed paths the captain owns
#
# Returns 2 when the range is not a fast-forward: the host is on a commit that
# is not an ancestor of the target, so "what is pending" has no honest answer
# and nothing may be deployed on that basis.
fm_deploy_classify() {
  local repo=$1 from=$2 to=$3 policy=$4
  local patterns=() path claimed
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_DEPLOY_PENDING=''
  FM_DEPLOY_PENDING_COUNT=0
  FM_DEPLOY_CAPTAIN=''
  FM_DEPLOY_CAPTAIN_COUNT=0

  git -C "$repo" rev-parse --verify --quiet "$from^{commit}" >/dev/null || return 2
  git -C "$repo" rev-parse --verify --quiet "$to^{commit}" >/dev/null || return 2
  git -C "$repo" merge-base --is-ancestor "$from" "$to" || return 2

  if [ "$from" = "$to" ]; then
    return 0
  fi

  FM_DEPLOY_PENDING=$(git -C "$repo" log --no-merges --format='%h %s' "$from..$to") || return 1
  if [ -n "$FM_DEPLOY_PENDING" ]; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_DEPLOY_PENDING_COUNT=$(printf '%s\n' "$FM_DEPLOY_PENDING" | wc -l | tr -d ' ')
  fi

  if fm_deploy_policy_readable "$policy"; then
    mapfile -t patterns < <(fm_deploy_policy_patterns "$policy")
  fi
  [ "${#patterns[@]}" -gt 0 ] || return 0

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if claimed=$(fm_deploy_path_captain_pattern "$path" "${patterns[@]}"); then
      FM_DEPLOY_CAPTAIN="${FM_DEPLOY_CAPTAIN}${claimed}	${path}
"
      FM_DEPLOY_CAPTAIN_COUNT=$((FM_DEPLOY_CAPTAIN_COUNT + 1))
    fi
  done < <(git -C "$repo" diff --name-only "$from" "$to")

  return 0
}

# fm_deploy_json_escape <text>
# Minimal JSON string escaping for the durable ledger.
fm_deploy_json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# --- the ledger ---------------------------------------------------------------

# fm_deploy_ledger_rollback_candidates <ledger-file> [max]
# Prints the commits a rollback could return to, newest attempt first, deduped.
#
# A candidate is the `from` of an attempt that actually reached the machine -
# `deployed` or `failed` - because both set the outgoing version aside under
# rollback_root before stopping anything. A deploy that FAILED is exactly when a
# rollback is wanted, so restricting this to completed deploys (as it once was)
# left the tool unable to undo the only case it exists for.
#
# `refused` never appears: a refusal happens before anything is set aside.
# `rolled-back` and `recorded-live` never appear either: rolling back to the
# version a rollback just replaced would walk back into the broken release, and
# a hand-restored version was never deployed from here at all.
#
# The caller decides which candidate is usable, by asking the machine whether
# that version's set-aside copy is still there.
fm_deploy_ledger_rollback_candidates() {
  local ledger=${1:-} max=${2:-20}
  local -a lines=()
  local line result from seen=' ' found=0 i
  [ -n "$ledger" ] && [ -f "$ledger" ] && [ ! -L "$ledger" ] && [ -r "$ledger" ] || return 0
  mapfile -t lines <"$ledger"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    line=${lines[i]}
    result=''
    from=''
    [[ $line =~ \"result\":\"([a-z-]+)\" ]] && result=${BASH_REMATCH[1]}
    case "$result" in
      deployed | failed) ;;
      *) continue ;;
    esac
    [[ $line =~ \"from\":\"([0-9a-f]{40})\" ]] && from=${BASH_REMATCH[1]}
    [ -n "$from" ] || continue
    case "$seen" in
      *" $from "*) continue ;;
    esac
    seen="$seen$from "
    printf '%s\n' "$from"
    found=$((found + 1))
    [ "$found" -lt "$max" ] || return 0
  done
  return 0
}

# --- host preconditions the units enforce at start ----------------------------

# Where a project keeps its unit files. bin/fm-deploy.sh already installs
# <checkout>/deploy/systemd/<unit>.service from this directory; drop-ins live
# beside them in <unit>.service.d/, and their ExecStartPre lines gate the start
# of the surrounding stack just as much as a .service file's do.
FM_DEPLOY_UNIT_DIR='deploy/systemd'

# fm_deploy_unit_files <repo> <sha>
# Prints every unit file and drop-in carried at <sha>, one path per line.
fm_deploy_unit_files() {
  git -C "$1" ls-tree -r --name-only "$2" -- "$FM_DEPLOY_UNIT_DIR/" 2>/dev/null
}

# fm_deploy_unit_user <repo> <sha> <unit-file>
# Prints the user the unit runs as, empty when it does not say (systemd runs it
# as root then). Section-aware, because `User=` is only meaningful in [Service].
fm_deploy_unit_user() {
  local content line section=''
  content=$(git -C "$1" show "$2:$3" 2>/dev/null) || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '#'* | ';'* | '') continue ;;
      '['*']')
        section=$line
        continue
        ;;
    esac
    [ "$section" = '[Service]' ] || continue
    case "$line" in
      User=*)
        printf '%s\n' "${line#User=}"
        return 0
        ;;
    esac
  done <<EOF
$content
EOF
  return 0
}

# fm_deploy_as_user <user> <command>
# The remote command that runs <command> as <user>.
#
# `cd /` first, and not as decoration. A command run under `sudo -u` inherits
# the working directory of the shell that invoked it, which on a host whose
# login user has a private home is a directory the service user cannot read.
# `find` walks by changing directory and then fails to return to the one it
# started in, so a front-end readability check run from there reported the
# release unreadable when the release was fine, and left the site down. `/` is
# readable by every user on the machine, and every path this home hands a
# validator is absolute, so nothing depends on the directory it starts in.
#
# One helper rather than a prefix repeated at each call site, so a third
# service-user command cannot be added without the fix.
fm_deploy_as_user() {
  printf "cd / && sudo -u '%s' %s" "$1" "$2"
}

# fm_deploy_preconditions <repo> <sha> <checkout> <precheck-dir>
#
# Prints one tab-separated record per ExecStartPre found in <sha>'s unit files:
#
#   check<TAB><unit-file><TAB><user><TAB><command to run>
#   skip<TAB><unit-file><TAB><user><TAB><why it cannot be checked first>
#
# A `check` record is a start-time precondition this home can honestly prove
# BEFORE it stops anything: it names at least one absolute path outside the
# checkout, so its verdict depends on host-owned state rather than on the new
# release being in place. That is the class the failed cutover hit - an
# allow-list file at /etc that the incoming release required and the machine did
# not have - and the class is what is selected here, never a named list.
#
# Everything else is a `skip` with its reason, printed rather than silently
# dropped, because "not proved" and "proved good" must not look the same.
#
# Tokens naming a path the commit itself carries are rewritten into
# <precheck-dir>, so what runs is the TARGET version of the validator, not the
# one the machine still has. A token under the checkout that the commit does not
# carry - the virtualenv interpreter, say - is host state and is left alone.
#
# Only the top-level directories the selected commands actually reference are
# extracted into <precheck-dir>, so a validator that imports across trees fails
# its pre-check loudly rather than passing on a file that was never put there.
#
# The command is assembled from the project's own unit file, which this deploy
# would install and run moments later, so it is no wider a trust boundary than
# the deploy itself. It is still held to the same data-only discipline as
# config/deploy-target: anything that could end a word and start a command is
# skipped rather than quoted and hoped about.
fm_deploy_preconditions() {
  local repo=$1 sha=$2 checkout=$3 precheck=$4
  local unit content line section user cmd prefix tok rel
  local -a cmds=() tokens=() rebuilt=()
  local host_owned rewritten reason as_root ignore_failure

  checkout=${checkout%/}
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    content=$(git -C "$repo" show "$sha:$unit" 2>/dev/null) || continue
    section=''
    user=''
    cmds=()
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      case "$line" in
        '#'* | ';'* | '') continue ;;
        '['*']')
          section=$line
          continue
          ;;
      esac
      [ "$section" = '[Service]' ] || continue
      case "$line" in
        User=*)
          user=${line#User=}
          continue
          ;;
        ExecStartPre=*) ;;
        *) continue ;;
      esac
      cmd=${line#ExecStartPre=}
      # An empty assignment resets the list systemd has accumulated so far.
      if [ -z "$cmd" ]; then
        cmds=()
        continue
      fi
      cmds+=("$cmd")
    done <<EOF
$content
EOF

    for cmd in "${cmds[@]:-}"; do
      [ -n "$cmd" ] || continue
      # systemd's command prefixes. `-` means systemd ignores a failure, so it
      # is not a precondition at all; `+`, `!` and `!!` run with full
      # privileges regardless of User=.
      as_root=0
      ignore_failure=0
      prefix=1
      while [ "$prefix" -eq 1 ]; do
        case "$cmd" in
          -*)
            cmd=${cmd#-}
            ignore_failure=1
            ;;
          '+'*)
            cmd=${cmd#+}
            as_root=1
            ;;
          '!!'*)
            cmd=${cmd#!!}
            as_root=1
            ;;
          '!'*)
            cmd=${cmd#!}
            as_root=1
            ;;
          ':'*) cmd=${cmd#:} ;;
          *) prefix=0 ;;
        esac
      done
      cmd=${cmd#"${cmd%%[![:space:]]*}"}
      [ -n "$cmd" ] || continue
      # systemd starts the unit anyway when this one fails, so it decides
      # nothing and this home must not refuse a deploy on its verdict.
      [ "$ignore_failure" -eq 0 ] || continue

      reason=''
      case "$cmd" in
        *[\;\&\|\`\$\<\>\(\)\"\'\\]*)
          reason='its command line is not plain data this home can safely re-run'
          ;;
        /*) ;;
        *) reason='it does not name an absolute program' ;;
      esac
      if [ -n "$reason" ]; then
        printf 'skip\t%s\t%s\t%s\n' "$unit" "$user" "$reason"
        continue
      fi

      read -r -a tokens <<<"$cmd"
      host_owned=0
      rebuilt=()
      for tok in "${tokens[@]}"; do
        rewritten=$tok
        case "$tok" in
          "$checkout"/*)
            rel=${tok#"$checkout"/}
            if git -C "$repo" cat-file -e "$sha:$rel" 2>/dev/null; then
              rewritten="$precheck/$rel"
            fi
            ;;
          /*) host_owned=$((host_owned + 1)) ;;
        esac
        rebuilt+=("$rewritten")
      done
      # The program itself is not the host-owned file this looks for; a
      # validator that takes no host path is a runtime check (readiness,
      # environment) and cannot be answered before the app is stopped.
      case "${tokens[0]}" in
        "$checkout"/*) ;;
        /*) host_owned=$((host_owned - 1)) ;;
      esac
      if [ "$host_owned" -le 0 ]; then
        printf 'skip\t%s\t%s\t%s\n' "$unit" "$user" \
          'it checks no host-owned file, so its answer depends on the release already running'
        continue
      fi
      if [ "$as_root" -eq 1 ] || [ -z "$user" ]; then
        printf 'check\t%s\troot\t%s\n' "$unit" "${rebuilt[*]}"
      else
        printf 'check\t%s\t%s\t%s\n' "$unit" "$user" "${rebuilt[*]}"
      fi
    done
  done < <(fm_deploy_unit_files "$repo" "$sha")
}
