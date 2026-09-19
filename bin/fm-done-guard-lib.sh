#!/usr/bin/env bash
# Single owner of the ship-done acceptance check: a PR-requiring ship task may
# report `done:` only after its own branch is on a remote and the forge confirms
# an open PR, in that task's own repository, named by the done line, the recorded
# pr=, or the forge itself. Scout, secondmate, and local-only (and any other mode
# that does not require a PR) are skipped. A missing mode, or a worktree that is
# missing or is not a git checkout, is also skipped so incomplete task metadata
# does not change classification.
# Sourced by the watcher, away-mode daemon, crew-state reader, and
# bin/fm-done-guard.sh. No side effects on source.
# bin/fm-pr-lib.sh owns URL validation and the forge record reads; a URL that
# only parses is a claim, not evidence, so every accept ends in a live read.
# The gate is fail-closed: an unreachable forge, a timed-out read, a PR in
# another repository, or any non-open state refuses the done. Every forge call
# is bounded by bin/fm-timeout-lib.sh, so no classifier blocks on the network.
# FM_DONE_GUARD_NO_FORGE=1 keeps a caller offline; offline it can still refuse an
# unpushed or unreferenced done but can never accept one.
# fm_done_guard_accepts_status_line is the classifier hook: return 0 to keep a
# done line actionable, 1 to drop it. fm_done_guard_steer_status is the watcher
# side effect that tells the worker to push.

_FM_DONE_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" \
  || _FM_DONE_GUARD_LIB_DIR="."

if ! command -v fm_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_DONE_GUARD_LIB_DIR/fm-pr-lib.sh"
fi
if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_DONE_GUARD_LIB_DIR/fm-timeout-lib.sh"
fi

FM_DONE_GUARD_VERDICT=
FM_DONE_GUARD_REASON=

fm_done_guard_meta_field() {  # <meta> <key>
  local meta=$1 key=$2 line
  [ -f "$meta" ] && [ -r "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -1 || true)
  printf '%s' "${line#*=}"
}

# 0 when this kind/mode pair requires a pushed branch and an open PR.
fm_done_guard_requires_pr() {  # <kind> <mode>
  local kind=$1 mode=$2
  case "$kind" in
    scout|secondmate) return 1 ;;
  esac
  case "$mode" in
    no-mistakes|direct-PR) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 when the task's OWN branch exists on a remote and contains HEAD. Reachability
# from any remote-tracking ref is not enough: a worktree still sitting on the base
# commit has nothing missing from the remotes and would otherwise read as pushed.
fm_done_guard_head_is_pushed() {  # <worktree>
  local wt=$1 branch head ref pushed=1
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git -C "$wt" merge-base --is-ancestor "$head" "$ref" >/dev/null 2>&1 || continue
    pushed=0
    break
  done <<EOF
$(git -C "$wt" for-each-ref --format='%(refname)' "refs/remotes/*/$branch" 2>/dev/null)
EOF
  return "$pushed"
}

# Print a canonical PR/MR URL found in <line>, or return 1.
fm_done_guard_pr_url_from_line() {  # <line>
  local line=$1 tok
  [ -n "$line" ] || return 1
  # shellcheck disable=SC2086  # word-split the status note into URL candidates
  for tok in $line; do
    while :; do
      case "$tok" in
        *')'|*,|*.|*';') tok=${tok%?} ;;
        *) break ;;
      esac
    done
    case "$tok" in
      https://*)
        fm_pr_url_parse "$tok" || continue
        printf '%s' "$FM_PR_URL"
        return 0
        ;;
    esac
  done
  return 1
}

fm_done_guard_pr_url_from_meta() {  # <meta>
  local meta=$1 value
  value=$(fm_done_guard_meta_field "$meta" pr)
  [ -n "$value" ] || return 1
  fm_pr_url_parse "$value" || return 1
  printf '%s' "$FM_PR_URL"
}

fm_done_guard_pr_url_from_forge() {  # <worktree>
  local wt=$1 url
  [ "${FM_DONE_GUARD_NO_FORGE:-}" = 1 ] && return 1
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  command -v fm_run_timed >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  url=$(fm_run_timed "${FM_DONE_GUARD_FORGE_SECS:-5}" bash -c \
    'cd "$1" 2>/dev/null || exit 1
     exec env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh pr view --json url -q .url' \
    _ "$wt" 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  fm_pr_url_parse "$url" || return 1
  printf '%s' "$FM_PR_URL"
}

# Print the forge's state for one PR/MR through a hard bound. The reader runs in
# a child shell because fm_run_timed bounds a command, not a shell function, and
# bin/fm-pr-lib.sh returns its record in variables.
fm_done_guard_forge_state() {  # <reader-function> <arg1> <arg2> <number>
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  fm_run_timed "${FM_DONE_GUARD_FORGE_SECS:-5}" bash -c '
    . "$1"
    "$2" "$3" "$4" "$5" || exit 1
    printf "%s" "$FM_PR_RECORD_STATE"
  ' _ "$_FM_DONE_GUARD_LIB_DIR/fm-pr-lib.sh" "$@" 2>/dev/null
}

# 0 only when <url> names a PR/MR in the worktree's own origin repository that
# the forge reports open. Fail-closed: an offline caller, a foreign repository,
# an unreachable forge, a hit bound, or any non-open state returns 1.
fm_done_guard_pr_is_open() {  # <url> <worktree>
  local url=$1 wt=$2 origin state
  fm_pr_url_parse "$url" || return 1
  [ "${FM_DONE_GUARD_NO_FORGE:-}" = 1 ] && return 1
  command -v fm_run_timed >/dev/null 2>&1 || return 1
  origin=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 1
  origin=${origin%/}
  origin=${origin%.git}
  origin=${origin%/}
  case "$origin" in
    *"$FM_PR_HOST/$FM_PR_PATH"|*"$FM_PR_HOST:$FM_PR_PATH") ;;
    *) return 1 ;;
  esac
  case "$FM_PR_PROVIDER" in
    github)
      state=$(fm_done_guard_forge_state fm_pr_github_read_record \
        "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER") || return 1
      ;;
    gitlab)
      state=$(fm_done_guard_forge_state fm_pr_gitlab_read_record \
        "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER") || return 1
      ;;
    *) return 1 ;;
  esac
  case "$state" in
    OPEN|open|opened) return 0 ;;
  esac
  return 1
}

# Inspect one status file and optional done line. Sets FM_DONE_GUARD_VERDICT to
# accepted, skipped, or refused and FM_DONE_GUARD_REASON to a short token.
# Return 0 for accepted or skipped, 1 for refused.
fm_done_guard_check() {  # <status-file> [<done-line>]
  local status=$1 line=${2-} meta kind mode wt source url referenced=0
  FM_DONE_GUARD_VERDICT=skipped
  FM_DONE_GUARD_REASON=no-status
  [ -n "$status" ] || return 0
  meta=${status%.status}.meta
  kind=$(fm_done_guard_meta_field "$meta" kind)
  mode=$(fm_done_guard_meta_field "$meta" mode)
  wt=$(fm_done_guard_meta_field "$meta" worktree)
  if [ -z "$line" ]; then
    command -v last_status_line >/dev/null 2>&1 \
      && line=$(last_status_line "$status")
    [ -n "$line" ] || line=$(tail -n 1 "$status" 2>/dev/null || true)
  fi
  if ! fm_done_guard_requires_pr "$kind" "$mode"; then
    FM_DONE_GUARD_REASON=${mode:-${kind:-no-mode}}
    return 0
  fi
  # A recorded worktree that is not a checkout carries no branch to judge, which
  # is the same absence of evidence as no worktree at all - not proof of an
  # unpushed branch. Refusing here would strand the task on a steer ("push your
  # branch") its worker has no repository to satisfy.
  if [ -z "$wt" ] || [ ! -d "$wt" ] \
    || ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FM_DONE_GUARD_REASON=no-worktree
    return 0
  fi
  if ! fm_done_guard_head_is_pushed "$wt"; then
    FM_DONE_GUARD_VERDICT=refused
    FM_DONE_GUARD_REASON=unpushed
    return 1
  fi
  # Sources are tried cheapest first and a source that names no URL costs
  # nothing, so the forge is asked only when the recorded references did not
  # already confirm an open PR - and a stale claim on the done line cannot mask
  # a good recorded or live one.
  for source in line meta forge; do
    case "$source" in
      line) url=$(fm_done_guard_pr_url_from_line "$line") || continue ;;
      meta) url=$(fm_done_guard_pr_url_from_meta "$meta") || continue ;;
      forge) url=$(fm_done_guard_pr_url_from_forge "$wt") || continue ;;
    esac
    referenced=1
    if fm_done_guard_pr_is_open "$url" "$wt"; then
      FM_DONE_GUARD_VERDICT=accepted
      FM_DONE_GUARD_REASON=accepted
      return 0
    fi
  done
  FM_DONE_GUARD_VERDICT=refused
  if [ "$referenced" -eq 1 ]; then
    FM_DONE_GUARD_REASON=unverified-pr
  else
    FM_DONE_GUARD_REASON=no-pr
  fi
  return 1
}

# Classifier hook. 0 keeps the done line actionable.
fm_done_guard_accepts_status_line() {  # <status-file> <line>
  local status=$1 line=$2 verb
  command -v status_line_verb >/dev/null 2>&1 || return 0
  verb=$(status_line_verb "$line")
  [ "$verb" = "done" ] || return 0
  fm_done_guard_check "$status" "$line"
}

# A pipeline's status is its last stage, and awk exits 0 on empty input, so each
# hasher is selected by presence rather than by letting a failed pipeline fall
# through to the next one.
fm_done_guard_steer_fingerprint() {  # <line>
  local line=$1 fp=''
  if command -v sha256sum >/dev/null 2>&1; then
    fp=$(printf '%s' "$line" | sha256sum 2>/dev/null | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    fp=$(printf '%s' "$line" | shasum -a 256 2>/dev/null | awk '{print $1}')
  fi
  [ -n "$fp" ] || fp=$line
  printf '%s' "$fp"
}

# Steer once per distinct refused done line. Return 0 if a steer was sent or
# already recorded for this line, 1 if send failed.
fm_done_guard_steer_status() {  # <status-file> <line>
  local status=$1 line=$2 task marker fp send home state msg
  task=$(basename "$status")
  task=${task%.status}
  case "$task" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  state=$(cd "$(dirname "$status")" && pwd) || return 1
  marker="$state/${task}.done-guard-steered"
  fp=$(fm_done_guard_steer_fingerprint "$line")
  [ -n "$fp" ] || return 1
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$fp" ]; then
    return 0
  fi
  msg="Your done report was refused: this ship task requires a pushed branch and an open PR. Push the branch to origin and open a PR, then report done with the PR's full https URL. For a no-mistakes ship, start /no-mistakes so the pipeline can push and open the PR; do not report done until it prints done: PR <url> checks green."
  send=${FM_DONE_GUARD_SEND:-$_FM_DONE_GUARD_LIB_DIR/fm-send.sh}
  home=${FM_HOME:-$(cd "$state/.." && pwd)}
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$send" "$task" "$msg"; then
    return 1
  fi
  printf '%s\n' "$fp" > "$marker" || return 1
  return 0
}

fm_done_guard_print_check() {
  printf 'verdict=%s\n' "$FM_DONE_GUARD_VERDICT"
  printf 'reason=%s\n' "$FM_DONE_GUARD_REASON"
}
