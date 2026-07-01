#!/usr/bin/env bash
# Enable/disable PR comment watching for PR-linked firstmate tasks.
# Usage:
#   fm-pr-comments.sh enable [all|<task-id>]   # default: all
#   fm-pr-comments.sh disable [all|<task-id>]  # default: all
#   fm-pr-comments.sh status
#   fm-pr-comments.sh poll [all|<task-id>]     # manual one-shot poll
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STORE="$STATE/.pr-comments"
ENABLED_DIR="$STORE/enabled"
DISABLED_DIR="$STORE/disabled"
CHECK="$STATE/pr-comments.check.sh"
mkdir -p "$STATE" "$ENABLED_DIR" "$DISABLED_DIR"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  cat <<'EOF'
Usage:
  fm-pr-comments.sh enable [all|<task-id>]    Enable watching (default: all PR-linked tasks)
  fm-pr-comments.sh disable [all|<task-id>]   Disable watching (default: all)
  fm-pr-comments.sh status                    Show enabled scope and PR-linked tasks
  fm-pr-comments.sh poll [all|<task-id>]      Run one manual poll now

Comment watching uses state/pr-comments.check.sh so the normal firstmate watcher
polls GitHub on its existing check cadence. New issue comments, PR review
comments, and PR review bodies are deduped in state/.pr-comments/seen/ and sent
to the task with bin/fm-send.sh. Enabling primes existing comments as seen so
only new feedback is injected.
EOF
}

meta_value() {
  local key=$1 file=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

is_pr_linked() {
  local id=$1 meta
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 1
  [ -n "$(meta_value pr "$meta")" ] || return 1
  [ -n "$(meta_value window "$meta")" ] || return 1
}

write_check() {
  local root_q home_q state_q poll_q
  root_q=$(printf '%q' "$FM_ROOT")
  home_q=$(printf '%q' "$FM_HOME")
  state_q=$(printf '%q' "$STATE")
  poll_q=$(printf '%q' "$FM_ROOT/bin/fm-pr-comments-poll.sh")
  cat > "$CHECK" <<EOF
#!/usr/bin/env bash
FM_ROOT_OVERRIDE=\${FM_ROOT_OVERRIDE:-$root_q} FM_HOME=\${FM_HOME:-$home_q} FM_STATE_OVERRIDE=\${FM_STATE_OVERRIDE:-$state_q} exec $poll_q --enabled
EOF
  chmod +x "$CHECK"
}

run_prime() {
  local output rc=0
  output=$("$FM_ROOT/bin/fm-pr-comments-poll.sh" "$@" --prime 2>&1) || rc=$?
  [ -z "$output" ] || printf '%s\n' "$output"
  if [ "$rc" -ne 0 ]; then
    echo "fm-pr-comments: priming failed; leaving PR comment watching unchanged" >&2
    return "$rc"
  fi
  return 0
}

remove_check_if_empty() {
  if [ ! -e "$ENABLED_DIR/all" ] && ! find "$ENABLED_DIR" -type f ! -name all -print -quit 2>/dev/null | grep . >/dev/null; then
    rm -f "$CHECK"
  fi
}

list_pr_tasks() {
  local meta id pr window
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    pr=$(meta_value pr "$meta")
    window=$(meta_value window "$meta")
    [ -n "$pr" ] && [ -n "$window" ] || continue
    printf '%s\t%s\t%s\n' "$id" "$window" "$pr"
  done
}

cmd=${1:-}
scope=${2:-all}
case "$cmd" in
  enable)
    case "$scope" in
      all)
        run_prime --all || exit 1
        touch "$ENABLED_DIR/all"
        rm -rf "$DISABLED_DIR"
        mkdir -p "$DISABLED_DIR"
        write_check
        echo "enabled: PR comment watching for all PR-linked tasks"
        ;;
      '') usage >&2; exit 2 ;;
      *)
        if ! is_pr_linked "$scope"; then
          echo "fm-pr-comments: task '$scope' is not PR-linked (need state/$scope.meta with pr= and window=)" >&2
          exit 1
        fi
        run_prime --task "$scope" || exit 1
        touch "$ENABLED_DIR/$scope"
        rm -f "$DISABLED_DIR/$scope"
        write_check
        echo "enabled: PR comment watching for $scope"
        ;;
    esac
    ;;
  disable)
    case "$scope" in
      all)
        rm -rf "$ENABLED_DIR" "$DISABLED_DIR"
        mkdir -p "$ENABLED_DIR" "$DISABLED_DIR"
        rm -f "$CHECK"
        echo "disabled: PR comment watching"
        ;;
      '') usage >&2; exit 2 ;;
      *)
        if [ -e "$ENABLED_DIR/all" ]; then
          touch "$DISABLED_DIR/$scope"
        else
          rm -f "$ENABLED_DIR/$scope"
          remove_check_if_empty
        fi
        echo "disabled: PR comment watching for $scope"
        ;;
    esac
    ;;
  status)
    if [ -x "$CHECK" ]; then
      echo "check: enabled ($CHECK)"
    else
      echo "check: disabled"
    fi
    if [ -e "$ENABLED_DIR/all" ]; then
      echo "scope: all PR-linked tasks"
      if find "$DISABLED_DIR" -type f -print -quit 2>/dev/null | grep . >/dev/null; then
        printf 'excluded:'
        for f in "$DISABLED_DIR"/*; do
          [ -e "$f" ] || continue
          printf ' %s' "$(basename "$f")"
        done
        printf '\n'
      fi
    else
      printf 'scope:'
      found=0
      for f in "$ENABLED_DIR"/*; do
        [ -e "$f" ] || continue
        found=1
        printf ' %s' "$(basename "$f")"
      done
      [ "$found" = 1 ] || printf ' none'
      printf '\n'
    fi
    echo "PR-linked tasks:"
    list_pr_tasks | while IFS=$(printf '\t') read -r id window pr; do
      printf '  %s (%s) %s\n' "$id" "$window" "$pr"
    done
    ;;
  poll)
    case "$scope" in
      all) "$FM_ROOT/bin/fm-pr-comments-poll.sh" --all ;;
      '') usage >&2; exit 2 ;;
      *) "$FM_ROOT/bin/fm-pr-comments-poll.sh" --task "$scope" ;;
    esac
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
