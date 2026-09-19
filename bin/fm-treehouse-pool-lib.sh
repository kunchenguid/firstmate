# shellcheck shell=bash
# Treehouse pool inspection for spawn preflight and spawn failure reporting.
# Usage: . bin/fm-treehouse-pool-lib.sh
#
# `treehouse get` is sent into the task pane as interactive text, so its exit
# status and its diagnosis never reach fm-spawn.sh: the spawn watched the pane's
# cwd for a change and, when the pool was full, reported only a 60s timeout and
# the path the shell was still sitting in. This library answers the question
# that timeout could not - can an isolated copy be obtained at all, and if not,
# why - from `treehouse status --json`, which reports the same pool the pane's
# `treehouse get` would draw from.
#
# FM_TREEHOUSE_POOL_TIMEOUT bounds the pool read in seconds (default 45).
#
# fm_treehouse_pool_inspect <project-dir> always returns 0 and sets:
#   FM_TREEHOUSE_POOL_VERDICT  available | full | config | unknown
#   FM_TREEHOUSE_POOL_DETAIL   the report body for every verdict but `available`
#
# `unknown` is the fail-open verdict and covers every case the inspection cannot
# settle: no treehouse on PATH, an unrecognized non-zero exit, output this
# library will not parse. A caller must never refuse a spawn on `unknown`,
# because a wrong refusal costs more than the wait it would have replaced; the
# spawn's own timeout stays the backstop for those. Only `full` and `config` are
# proven, and both name the remedy.

FM_TREEHOUSE_POOL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tangle-lib.sh
. "$FM_TREEHOUSE_POOL_LIB_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_TREEHOUSE_POOL_LIB_DIR/fm-timeout-lib.sh"

# Seconds the pool read may take before the inspection gives up on it. Reading
# the pool means a git status of every worktree in it, which on a large
# repository is slow and, on a wedged filesystem, unbounded. This runs ahead of
# every spawn, so it is bounded: hitting the bound is an unsettled question, not
# a refusal, and the spawn proceeds exactly as it did before.
FM_TREEHOUSE_POOL_TIMEOUT=${FM_TREEHOUSE_POOL_TIMEOUT:-45}

# treehouse's own default when treehouse.toml sets no max_trees, as written by
# `treehouse init`. Only ever used to decide that a pool is AT its cap, so a
# drift in that default can delay a refusal, never invent one.
FM_TREEHOUSE_DEFAULT_MAX_TREES=16

fm_treehouse_pool_shell_quote() {  # <text>
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Extract one string field from a single `treehouse status --json` object.
fm_treehouse_pool_json_field() {  # <object> <key>
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# Split `treehouse status --json`'s array into one object per line.
fm_treehouse_pool_json_objects() {  # <json>
  printf '%s' "$1" | tr -d '\n' | sed -e 's/^[[:space:]]*\[//' -e 's/\][[:space:]]*$//' \
    | sed -e 's/},[[:space:]]*{/}\n{/g'
}

# Read the single top-level max_trees assignment from a treehouse.toml.
# Sets FM_TREEHOUSE_POOL_CAP and FM_TREEHOUSE_POOL_CAP_LINE (0 when unset).
# A key inside a [table] is not the top-level one treehouse reads, and a file
# with two assignments never loads at all, so both are reported as unset.
fm_treehouse_pool_read_cap() {  # <toml>
  local toml=$1 hits
  FM_TREEHOUSE_POOL_CAP=$FM_TREEHOUSE_DEFAULT_MAX_TREES
  FM_TREEHOUSE_POOL_CAP_LINE=0
  [ -f "$toml" ] || return 0
  hits=$(awk '
    /^[[:space:]]*\[/ { intable = 1 }
    intable { next }
    /^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/ {
      value = $0
      sub(/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[^0-9].*$/, "", value)
      print NR " " value
    }
  ' "$toml")
  [ "$(printf '%s\n' "$hits" | grep -c .)" = 1 ] || return 0
  FM_TREEHOUSE_POOL_CAP=${hits#* }
  FM_TREEHOUSE_POOL_CAP_LINE=${hits%% *}
}

# Describe what blocks one dirty pool slot, as the report's indented block.
# A slot carrying commits that are not on the default branch is real unlanded
# work: it is named as such and gets no clearing command, because discarding it
# is the captain's call alone (AGENTS.md hard rule 3). Every other dirty slot
# holds leftovers, and gets both the command that preserves them and the command
# that clears them.
fm_treehouse_pool_blocked_slot_detail() {  # <slot-name> <slot-path>
  local name=$1 path=$2 default ref commits status modified untracked q
  q=$(fm_treehouse_pool_shell_quote "$path")
  default=$(fm_default_branch "$path" 2>/dev/null || true)
  ref=
  if [ -n "$default" ]; then
    if git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}" >/dev/null 2>&1; then
      ref="origin/$default"
    elif git -C "$path" rev-parse --verify --quiet "refs/heads/$default^{commit}" >/dev/null 2>&1; then
      ref="$default"
    fi
  fi
  if [ -z "$ref" ]; then
    printf '    unlanded work: unknown, this copy has no default branch to compare against - left untouched\n'
    return 0
  fi
  commits=$(git -C "$path" rev-list --count "$ref..HEAD" 2>/dev/null || true)
  case "$commits" in
    ''|*[!0-9]*)
      printf '    unlanded work: unknown, its history could not be compared against %s - left untouched\n' "$ref"
      return 0
      ;;
  esac
  if [ "$commits" -gt 0 ]; then
    printf '    unlanded work: %s commit(s) not on %s - left untouched\n' "$commits" "$ref"
    return 0
  fi
  status=$(git -C "$path" -c core.quotePath=false status --porcelain --untracked-files=all 2>/dev/null || true)
  modified=$(printf '%s\n' "$status" | grep -c '^[^?]' || true)
  untracked=$(printf '%s\n' "$status" | grep -c '^??' || true)
  printf '    leftovers only: %s modified tracked file(s), %s untracked path(s), no commits off %s\n' \
    "$modified" "$untracked" "$ref"
  # shellcheck disable=SC2016 # The command is printed for the captain to run; $(date) expands there, not here.
  printf '      preserve first: (cd %s && git add -A && git commit -q -m %s && git branch "fm-reclaim/%s-$(date +%%s)")\n' \
    "$q" "$(fm_treehouse_pool_shell_quote "wip: firstmate reclaim of pool slot $name")" "$name"
  printf '      then clear:     treehouse return --force %s\n' "$q"
}

fm_treehouse_pool_inspect() {  # <project-dir>
  local project=$1 root toml out err rc objects obj name status path holder
  local total=0 running=0 leased=0 dirty=0 free=0 pool='' blocked='' report=''
  FM_TREEHOUSE_POOL_VERDICT=unknown
  FM_TREEHOUSE_POOL_DETAIL=

  if ! command -v treehouse >/dev/null 2>&1; then
    FM_TREEHOUSE_POOL_DETAIL='treehouse is not on PATH, so its pool could not be inspected'
    return 0
  fi
  root=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$root" ]; then
    FM_TREEHOUSE_POOL_DETAIL="$project is not a git repository, so its treehouse pool could not be inspected"
    return 0
  fi
  toml="$root/treehouse.toml"

  err=$(mktemp "${TMPDIR:-/tmp}/fm-treehouse-status.XXXXXX") || return 0
  # Split across the || so a non-zero status is captured rather than aborting a
  # caller that runs under set -e.
  out=$(cd "$project" && fm_run_timed "$FM_TREEHOUSE_POOL_TIMEOUT" treehouse status --json 2>"$err") \
    && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    err=$(cat "$err"; rm -f "$err")
    if [ "$rc" -eq 124 ]; then
      FM_TREEHOUSE_POOL_DETAIL="reading the worktree pool for $project did not finish within ${FM_TREEHOUSE_POOL_TIMEOUT}s"
      return 0
    fi
    case "$err" in
      *'failed to load config'*)
        FM_TREEHOUSE_POOL_VERDICT=config
        FM_TREEHOUSE_POOL_DETAIL=$(printf 'treehouse cannot load %s, so no worktree can be handed out:\n  %s\nFix that file before any spawn; treehouse reads it only at the repository root.' \
          "$toml" "$(printf '%s' "$err" | grep 'failed to load config' | head -n 1)")
        ;;
      *)
        FM_TREEHOUSE_POOL_DETAIL=$(printf "'treehouse status --json' exited %s in %s:\n  %s" \
          "$rc" "$project" "${err:-it printed nothing}")
        ;;
    esac
    return 0
  fi
  rm -f "$err"

  objects=$(fm_treehouse_pool_json_objects "$out")
  while IFS= read -r obj; do
    case "$obj" in *'"path"'*) ;; *) continue ;; esac
    name=$(fm_treehouse_pool_json_field "$obj" name)
    status=$(fm_treehouse_pool_json_field "$obj" status)
    path=$(fm_treehouse_pool_json_field "$obj" path)
    if [ -z "$path" ] || [ ! -d "$path" ]; then
      FM_TREEHOUSE_POOL_DETAIL="'treehouse status --json' in $project named a worktree this inspection could not read"
      return 0
    fi
    [ -n "$pool" ] || pool=$(dirname "$(dirname "$path")")
    total=$((total + 1))
    case "$status" in
      available) free=$((free + 1)) ;;
      in-use) running=$((running + 1)) ;;
      leased)
        leased=$((leased + 1))
        holder=$(fm_treehouse_pool_json_field "$obj" lease_holder)
        ;;
      dirty)
        dirty=$((dirty + 1))
        blocked+="  slot $name  $path"$'\n'
        blocked+=$(fm_treehouse_pool_blocked_slot_detail "$name" "$path")$'\n'
        ;;
      *)
        FM_TREEHOUSE_POOL_DETAIL="'treehouse status --json' in $project reported worktree state '$status', which this inspection does not know"
        return 0
        ;;
    esac
  done <<< "$objects"

  fm_treehouse_pool_read_cap "$toml"
  if [ "$free" -gt 0 ] || [ "$total" -lt "$FM_TREEHOUSE_POOL_CAP" ]; then
    FM_TREEHOUSE_POOL_VERDICT=available
    return 0
  fi

  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_POOL_VERDICT=full
  report="all $total of $total worktrees in the pool are in use or dirty (max_trees = $FM_TREEHOUSE_POOL_CAP)"$'\n'
  report+="  pool: $pool"$'\n'
  report+="  $running held by a running worker, $leased held by a durable lease${holder:+ (${holder})}, $dirty blocked by leftovers"$'\n'
  report+=$blocked
  if [ "$FM_TREEHOUSE_POOL_CAP_LINE" -gt 0 ]; then
    report+="  to raise the cap instead: edit line $FM_TREEHOUSE_POOL_CAP_LINE of $toml, which reads \"max_trees = $FM_TREEHOUSE_POOL_CAP\", to a larger number - a second max_trees key makes treehouse refuse the file entirely"
  else
    report+="  to raise the cap instead: add a \"max_trees = $((FM_TREEHOUSE_POOL_CAP + 8))\" line to $toml, which currently sets none, so treehouse applies its default of $FM_TREEHOUSE_POOL_CAP"
  fi
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_POOL_DETAIL=$report
}
