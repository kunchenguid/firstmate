#!/usr/bin/env bash
# Report what project knowledge never travelled from the checkout a project was
# originally worked in into the clone firstmate dispatches workers to.
#
# A project the captain started somewhere else carries most of its accumulated
# knowledge outside the clone: local commits nobody pushed, knowledge documents
# nobody committed, and agent memory the project's own .gitignore excludes.
# Every worker firstmate dispatches to such a project starts blind while the
# captain's own sessions stand on all of it. This command names that gap.
#
# REPORTS ONLY, NEVER MUTATES. The source checkout is the captain's live working
# state and routinely holds uncommitted work, so every command this script runs
# against it goes through source_git(), the single function in this file that
# names `git` for the source. That function refuses any subcommand outside its
# read-only allowlist and any caller-supplied global flag, and it runs git with
# --no-optional-locks plus GIT_OPTIONAL_LOCKS=0 so even an index refresh is not
# written. A new read added to this script cannot reach the source checkout
# without passing that gate.
#
# Usage:
#   fm-project-memory.sh source set <project> <path> [--canonical repo|source]
#   fm-project-memory.sh source clear <project>
#   fm-project-memory.sh scan <project> [--limit <n>]
#   fm-project-memory.sh scan --all [--limit <n>]
#
# Usage (continued):
#   fm-project-memory.sh home <project> [--clone <dir>]
#   fm-project-memory.sh activity [<project>] [--home <dir>] [--git-only]
#
# Each project may record a source checkout in config/project-sources/<project>,
# a two-key record:
#
#   path=/absolute/path/to/the/checkout
#   canonical=repo|source
#
# It lives in config/ rather than in the data/projects.md registry because it is
# a machine-local operating fact, not fleet navigation: the path exists only on
# the host that holds that checkout, while the registry line is prose whose
# delivery-posture parser (bin/fm-project-mode.sh) must not grow a second field.
# The record is NOT inherited by secondmate homes, which may run on another host.
# An absent record is a normal, reported state, never an error: the scan then
# reports only what the clone itself can show.
#
# `canonical` names where the project's knowledge actually lands, which is not
# always its repository:
#
#   repo    the repository history is the project's home. Anything sitting only
#           in the source checkout is a leak to repair, and the fix is to get it
#           versioned.
#   source  the source checkout itself is the project's home, and its repository
#           is a mirror nobody has fed in months. Divergence there is how the
#           work is done, not a defect: the scan says so instead of reporting
#           months of normal working state as a fault, and the material reaches
#           workers through the project's local material store
#           (bin/fm-project-local.sh) rather than through a commit.
#
# A SOURCE-CANONICAL HOME IS SHARED AND IN USE. When the project's home is a
# live local folder rather than a repository, there is no isolated copy standing
# between a worker and the captain: he runs his own sessions in that same folder
# while firstmate has work going there, and the two have already come within a
# minute of colliding. Nothing here assumes that folder is still. Every command
# in this file only ever reads it, and `activity` is the cheap, verifiable
# answer to "is he working in there right now" that any authorized write must
# consult first. Deliberately not a lock: a lock nobody can be sure the other
# side honors is worse than an honest reading of what the folder is doing.
#
# `activity` reports two independent signals, either of which alone means the
# folder is in use: a file changed within the window, and a git operation in
# flight (an index lock, a merge, a rebase, a cherry-pick, a revert, a bisect).
# It exits 0 when quiet, 3 when active, and 1 on an error - including a
# source-canonical home that is not reachable, which is never answered with a
# reading of the clone - so a caller can gate on it without parsing prose. `--git-only` reports the operation signal alone,
# for a caller inside its own isolated copy, where recent writes are its own and
# prove nothing about a second person in the folder. The file walk stops at the first hit, so the
# common "he is working" answer costs almost nothing; only the quiet answer
# walks the tree, which is why the window is small.
#
# `home` prints the directory that IS the project's knowledge home under that
# record: the source checkout when it is canonical, and this home's clone
# otherwise. `--clone <dir>` names that clone explicitly, for a caller such as
# bin/fm-spawn.sh that already holds the project directory it is working from
# and must not re-derive it. A source-canonical home that is not reachable
# (the Windows disk behind /mnt/c is down) is never quietly replaced by the
# clone, which is only a stale mirror of it: `home` still prints the recorded
# path but exits 4, so a caller that has to go on can name the home and say it
# was not verified while every other caller fails on the status. `activity
# <project>` resolves the same way and exits 1 there. Callers that must read a
# project's committed agent memory or recipe catalog resolve it through this
# command rather than assuming the clone.
#
# --limit bounds how many paths each category lists (default 40); the counts are
# always complete. A source checkout on a Windows filesystem reached through
# /mnt/c is supported and is the case this was built for; every walk here is
# either a single git call or a bounded find, because that filesystem makes an
# unbounded directory walk expensive.
#
# Exit status: 0 when a scan completed, whatever it found, because the report is
# the deliverable and a divergence is a finding rather than a failure. Nonzero
# only when the scan could not be performed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SOURCES_DIR="$CONFIG/project-sources"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "project-memory: $1" >&2
  exit 1
}

# --- project name and source record ----------------------------------------

valid_project_name() {  # <name>
  case "$1" in
    '' | .* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$1" in
    *..*) return 1 ;;
  esac
  return 0
}

source_record_path() {  # <project>
  printf '%s\n' "$SOURCES_DIR/$1"
}

# Read a project's source-checkout record. On success sets SOURCE_RECORD_PATH
# and SOURCE_RECORD_CANONICAL and returns 0; returns 1 when no record exists,
# and 2 when one exists but is unsafe or malformed, so a broken record is
# reported rather than read as "never configured".
SOURCE_RECORD_PATH=
SOURCE_RECORD_CANONICAL=
read_source_record() {  # <project>
  local rec line key value
  SOURCE_RECORD_PATH=
  SOURCE_RECORD_CANONICAL=repo
  rec=$(source_record_path "$1")
  if [ -L "$rec" ]; then
    echo "project-memory: refusing symlinked source record $rec" >&2
    return 2
  fi
  [ -e "$rec" ] || return 1
  if [ ! -f "$rec" ]; then
    echo "project-memory: source record $rec is not a regular file" >&2
    return 2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in
      \#*) continue ;;
      *=*) ;;
      *)
        echo "project-memory: source record $rec holds a line that is not key=value" >&2
        return 2
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case $key in
      path) SOURCE_RECORD_PATH=$value ;;
      canonical) SOURCE_RECORD_CANONICAL=$value ;;
      *)
        echo "project-memory: source record $rec holds unknown key '$key'" >&2
        return 2
        ;;
    esac
  done <"$rec"
  case $SOURCE_RECORD_PATH in
    /*) ;;
    *)
      echo "project-memory: source record $rec must hold one absolute path=" >&2
      return 2
      ;;
  esac
  case $SOURCE_RECORD_PATH in
    *[[:cntrl:]]*)
      echo "project-memory: source record $rec holds control characters" >&2
      return 2
      ;;
  esac
  case $SOURCE_RECORD_CANONICAL in
    repo | source) ;;
    *)
      echo "project-memory: source record $rec has canonical='$SOURCE_RECORD_CANONICAL'; expected repo or source" >&2
      return 2
      ;;
  esac
  return 0
}

# --- read-only gate to the source checkout ----------------------------------

# The single place this file names git for the SOURCE checkout. Refuses any
# subcommand outside the read-only allowlist and any global flag a caller tries
# to smuggle in front of it, so no future read here can mutate the captain's
# live working state.
source_git() {  # <repo> <read-only subcommand> [args...]
  local repo=$1 sub=$2
  shift 2
  case $sub in
    rev-parse | log | status | ls-files | check-ignore | for-each-ref | cat-file | show-ref | diff | rev-list) ;;
    *)
      echo "project-memory: internal: '$sub' is not an allowed read-only git subcommand" >&2
      return 99
      ;;
  esac
  case $sub in
    -*)
      echo "project-memory: internal: refusing git global flag '$sub'" >&2
      return 99
      ;;
  esac
  # core.quotePath=false: with git's default every non-ASCII byte comes back
  # C-quoted, and the surrounding quotes make an accented document fail every
  # extension and directory test the classifier runs, so the captain's own file
  # names would be the ones this scan is blind to. Control characters, quotes,
  # and backslashes are still quoted, which is what keeps a hostile name from
  # printing as if it were the real one.
  GIT_OPTIONAL_LOCKS=0 git --no-optional-locks -c core.quotePath=false -C "$repo" --no-pager "$sub" "$@"
}

is_git_worktree_root() {  # <path>
  local top
  [ -d "$1" ] || return 1
  top=$(source_git "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ "$(cd "$1" && pwd -P)" = "$(cd "$top" && pwd -P)" ]
}

# --- classification ---------------------------------------------------------

# Durable knowledge: prose, analysis, and agent memory that a future session
# needs. Deliberately generous, because the cost of listing one extra document
# for the captain to judge is far below the cost of silently leaving four
# months of findings on one desktop.
# The project's own knowledge surface: the memory files an agent loads by name,
# and the directories a project keeps its documents in. This is the strongest
# signal the classifier has, which is why a bounded listing spends its slots
# here first.
looks_like_knowledge_home() {  # <relative path>
  case ${1##*/} in
    AGENTS.md | CLAUDE.md | GEMINI.md | QWEN.md | .cursorrules | .windsurfrules) return 0 ;;
  esac
  case $1 in
    docs/* | doc/* | notes/* | knowledge/* | playbooks/* | reference/* | research/* | findings/* | .agents/* | .claude/* | .cursor/* | .github/instructions/*) return 0 ;;
  esac
  return 1
}

# A document anywhere else, recognised by its own name or extension.
looks_like_knowledge_name() {  # <relative path>
  case ${1##*/} in
    README* | CONTRIBUTING* | CHANGELOG* | NOTES* | TODO*) return 0 ;;
    *.md | *.mdx | *.rst | *.adoc | *.org | *.txt | *.pdf | *.docx) return 0 ;;
  esac
  return 1
}

looks_like_knowledge() {  # <relative path>
  looks_like_knowledge_home "$1" || looks_like_knowledge_name "$1"
}

# Scratch: build output, caches, editor state, and per-run artifacts. Reported
# as a count only, because listing it is what turns a report into noise.
# Scratch by LOCATION: the path lives inside a build, cache, or dependency tree,
# and nothing it is named can make it this project's own knowledge - a
# dependency's own README is the dependency's, not the captain's.
looks_like_scratch_tree() {  # <relative path>
  case "/$1" in
    */node_modules/* | */vendor/* | */__pycache__/* | */.venv/* | */venv/* | */.pytest_cache/* | */.mypy_cache/* | */.ruff_cache/* | */.gradle/* | */.idea/* | */.vscode/* | */dist/* | */build/* | */target/* | */coverage/* | */.next/* | */.turbo/*) return 0 ;;
  esac
  case $1 in
    node_modules/ | vendor/ | __pycache__/ | .venv/ | venv/ | .pytest_cache/ | .mypy_cache/ | .ruff_cache/ | .gradle/ | .idea/ | .vscode/ | dist/ | build/ | target/ | coverage/ | .next/ | .turbo/) return 0 ;;
    *.egg-info/) return 0 ;;
  esac
  return 1
}

# Scratch by NAME: only the file's own name or extension says build output, and
# a document in an ordinary tree can carry such a name and still be exactly what
# this scan exists to find, so knowledge is asked before this one.
looks_like_scratch_name() {  # <relative path>
  case ${1##*/} in
    .DS_Store | Thumbs.db) return 0 ;;
    *.pyc | *.pyo | *.class | *.o | *.so | *.a | *.log | *.tmp | *.swp | *.bak | *.orig | *.rej) return 0 ;;
  esac
  return 1
}

looks_like_scratch() {  # <relative path>
  looks_like_scratch_tree "$1" || looks_like_scratch_name "$1"
}

# Agent memory paths a project's own .gitignore commonly excludes. Each is
# checked for existence and for being ignored; an excluded one is the exact
# failure this capability exists for, because it is invisible to every clone.
agent_memory_paths() {
  cat <<'EOF'
AGENTS.md
CLAUDE.md
GEMINI.md
QWEN.md
.claude
.agents
.cursor
.cursorrules
.gemini
.codex
.opencode
.grok
.kimi
.github/copilot-instructions.md
EOF
}

# Bounded file count under a directory: stops reading at cap+1 entries, so a
# 200k-file ignored tree on /mnt/c costs the same as a small one.
bounded_file_count() {  # <dir> <cap>
  local dir=$1 cap=$2 n
  n=$(find "$dir" -type f 2>/dev/null | head -n "$((cap + 1))" | wc -l | tr -d ' ')
  if [ "$n" -gt "$cap" ]; then
    printf '%s+\n' "$cap"
  else
    printf '%s\n' "$n"
  fi
}

# A bounded list of PATHS spends its slots on what the report exists to
# surface. Three rules, all of them about the one thing the cap can cost: the
# captain's own document never being printed.
#   - Order is the signal the classifier already carries, not the alphabet: the
#     project's knowledge surface first, then documents by name, then the rest.
#   - One directory cannot take every slot. When the list does not fit, the
#     fullest directories collapse to one counted line each until it does, so
#     45 caption files beside one audit no longer bury the audit.
#   - Nothing collapses while everything fits, because the names are the point.
# The omission line says how many of what it hides is knowledge, which is the
# number that decides whether to look further with a larger --limit.
print_path_list() {  # <limit> < paths
  local limit=$1 path rank dir
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if looks_like_knowledge_home "$path"; then
      rank=0
    elif looks_like_knowledge_name "$path"; then
      rank=1
    else
      rank=2
    fi
    case $path in
      */*) dir="${path%/*}/" ;;
      *) dir='./' ;;
    esac
    printf '%s\t%s\t%s\n' "$rank" "$dir" "$path"
  done | LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k3,3 | awk -F'\t' -v limit="$limit" '
    {
      rank[NR] = $1 + 0
      dir[NR] = $2
      path[NR] = $3
      count[$2]++
      if ($1 + 0 < 2) known[$2]++
      if (!($2 in seen)) { seen[$2] = 1; order[++nd] = $2 }
      n = NR
    }
    END {
      lines = n
      while (lines > limit) {
        biggest = ""
        most = 1
        for (i = 1; i <= nd; i++) {
          d = order[i]
          if (folded[d]) continue
          if (count[d] > most) { most = count[d]; biggest = d }
        }
        if (biggest == "") break
        folded[biggest] = 1
        lines -= count[biggest] - 1
      }
      shown = 0
      hidden = 0
      hidden_known = 0
      for (i = 1; i <= n; i++) {
        d = dir[i]
        if (folded[d]) {
          if (done[d]) continue
          done[d] = 1
          if (shown < limit) {
            printf "    %s (%d files)\n", d, count[d]
            shown++
          } else {
            hidden += count[d]
            hidden_known += known[d]
          }
          continue
        }
        if (shown < limit) {
          printf "    %s\n", path[i]
          shown++
        } else {
          hidden++
          if (rank[i] < 2) hidden_known++
        }
      }
      if (hidden > 0) printf "    ... and %d more (%d of them knowledge)\n", hidden, hidden_known
    }
  '
}

print_capped_list() {  # <limit> < paths
  local limit=$1 shown=0 total=0 line overflow=
  while IFS= read -r line; do
    total=$((total + 1))
    if [ "$shown" -lt "$limit" ]; then
      printf '    %s\n' "$line"
      shown=$((shown + 1))
    else
      overflow=1
    fi
  done
  [ -z "$overflow" ] || printf '    ... and %s more\n' "$((total - shown))"
}

# Agent-memory paths present in <repo> but excluded from its history. This is
# the exact failure the capability exists for: the file a session needs most is
# the one the project's own .gitignore keeps out of every clone. Prints its own
# report block, leaves the matched top-level paths in <paths-out>, and sets
# AGENT_MEM_COUNT to how many it found.
AGENT_MEM_COUNT=0
scan_agent_memory() {  # <repo> <limit> <label> <paths-out>
  local repo=$1 limit=$2 label=$3 out=$4
  local candidate why listed=0 buf
  AGENT_MEM_COUNT=0
  : >"$out"
  buf=$(
    while IFS= read -r candidate; do
      [ -e "$repo/$candidate" ] || continue
      source_git "$repo" check-ignore -q -- "$candidate" 2>/dev/null || continue
      why=$(source_git "$repo" check-ignore -v -- "$candidate" 2>/dev/null | head -n 1 | cut -d: -f1,2)
      if [ -d "$repo/$candidate" ]; then
        printf '%s/ (excluded by %s, %s files)\n' "$candidate" "${why:-.gitignore}" "$(bounded_file_count "$repo/$candidate" 500)"
      else
        printf '%s (excluded by %s)\n' "$candidate" "${why:-.gitignore}"
      fi
      printf '%s\n' "$candidate" >>"$out"
    done < <(agent_memory_paths)
  )
  if [ -n "$buf" ]; then
    listed=$(printf '%s\n' "$buf" | wc -l | tr -d ' ')
    printf 'AGENT_MEMORY_EXCLUDED (%s): %s\n' "$label" "$listed"
    printf '%s\n' "$buf" | print_capped_list "$limit"
  else
    printf 'AGENT_MEMORY_EXCLUDED (%s): none\n' "$label"
  fi
  AGENT_MEM_COUNT=$listed
  return 0
}

# --- concurrency with whoever else is in the folder -------------------------

# Portable past-timestamp anchor: a file whose mtime is <seconds> ago, so a
# bounded `find -newer` can answer "did anything change since then" without
# stat-ing every entry. Linux date lacks -r and macOS date lacks -d, the same
# split bin/fm-supervision-lib.sh already handles for reading an mtime.
activity_anchor() {  # <path> <seconds-ago>
  local path=$1 seconds=$2 now stamp
  now=$(date +%s) || return 1
  if [ "$(uname)" = Darwin ]; then
    stamp=$(date -r "$((now - seconds))" +%Y%m%d%H%M.%S 2>/dev/null) || return 1
  else
    stamp=$(date -d "@$((now - seconds))" +%Y%m%d%H%M.%S 2>/dev/null) || return 1
  fi
  : >"$path" || return 1
  touch -t "$stamp" "$path" 2>/dev/null || return 1
}

# The git operation, if any, that the working copy is in the middle of. An
# in-flight operation is unambiguous evidence that someone is working the folder
# right now, and unlike a recent write it is never produced by simply reading.
git_operation_in_flight() {  # <repo>; prints the operation name, or nothing
  local repo=$1 gitdir
  gitdir=$(source_git "$repo" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  [ -n "$gitdir" ] || return 0
  [ -e "$gitdir/index.lock" ] && { printf 'index-lock\n'; return 0; }
  [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] && { printf 'rebase\n'; return 0; }
  [ -e "$gitdir/MERGE_HEAD" ] && { printf 'merge\n'; return 0; }
  [ -e "$gitdir/CHERRY_PICK_HEAD" ] && { printf 'cherry-pick\n'; return 0; }
  [ -e "$gitdir/REVERT_HEAD" ] && { printf 'revert\n'; return 0; }
  [ -e "$gitdir/BISECT_LOG" ] && { printf 'bisect\n'; return 0; }
  return 0
}

# Prints the report and sets ACTIVITY_STATE to active or quiet. .git is pruned
# because git's own bookkeeping churns on a plain read and would report every
# folder as busy; the operation check above covers what matters in there.
ACTIVITY_STATE=quiet
report_activity() {  # <home> <window-seconds> [git-only]
  local home=$1 window=$2 git_only=${3:-0} anchor newest operation
  ACTIVITY_STATE=quiet
  printf 'HOME: %s\n' "$home"

  operation=$(git_operation_in_flight "$home")
  if [ -n "$operation" ]; then
    printf 'GIT_OPERATION: %s\n' "$operation"
    ACTIVITY_STATE=active
  else
    printf 'GIT_OPERATION: none\n'
  fi

  # A worker's own isolated copy is always writing, so a caller that only needs
  # to know whether SOMEONE ELSE is mid-operation asks for the git signal alone;
  # recent writes there prove nothing about a second person.
  if [ "$git_only" -eq 1 ]; then
    printf 'ACTIVITY: %s (git signal only; no file walk)\n' "$ACTIVITY_STATE"
    return 0
  fi

  anchor=$(mktemp "${TMPDIR:-/tmp}/fm-project-activity.XXXXXX") || die "could not create a scratch file"
  if ! activity_anchor "$anchor" "$window"; then
    rm -f -- "$anchor"
    printf 'ACTIVITY: unknown (this host could not build a comparison timestamp)\n'
    ACTIVITY_STATE=active
    return 0
  fi
  newest=$(find "$home" -name .git -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  rm -f -- "$anchor"

  if [ -n "$newest" ]; then
    printf 'ACTIVITY: active (changed within the last %ss, for example: %s)\n' "$window" "${newest#"$home"/}"
    ACTIVITY_STATE=active
  elif [ "$ACTIVITY_STATE" = active ]; then
    printf 'ACTIVITY: active (a git operation is in flight; no file changed within the last %ss)\n' "$window"
  else
    printf 'ACTIVITY: quiet (nothing changed in the last %ss)\n' "$window"
  fi
  return 0
}

# --- scan -------------------------------------------------------------------

scan_project() {  # <project> <limit>
  local project=$1 limit=$2
  local clone rc source source_head clone_head source_branch
  local tmp canonical=repo gap=0 context=0
  clone="$PROJECTS_DIR/$project"

  printf 'PROJECT: %s\n' "$project"
  if [ -d "$clone/.git" ] || [ -f "$clone/.git" ]; then
    printf 'CLONE: %s\n' "$clone"
    clone_head=$(source_git "$clone" rev-parse HEAD 2>/dev/null || true)
  else
    printf 'CLONE: absent (no clone at %s)\n' "$clone"
    clone=
    clone_head=
  fi

  if read_source_record "$project"; then
    source=$SOURCE_RECORD_PATH
    canonical=$SOURCE_RECORD_CANONICAL
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'SOURCE: unreadable record\n'
      printf 'VERDICT: unknown - the recorded source checkout could not be read\n'
      return 0
    fi
    source=
  fi
  printf 'HOME_KIND: %s\n' "$canonical"

  if [ -z "$source" ]; then
    printf 'SOURCE: none recorded\n'
    # shellcheck disable=SC2016 # Markdown backticks in the report text, not a command substitution.
    printf 'NOTE: record one with `%s source set %s <path>` when this project was first worked somewhere else; nothing to compare against until then\n' \
      "$(basename "$0")" "$project"
    if [ -n "$clone" ]; then
      scan_agent_memory "$clone" "$limit" clone /dev/null
      gap=$((gap + AGENT_MEM_COUNT))
    fi
    if [ "$gap" -eq 0 ]; then
      printf 'VERDICT: unknown - no source checkout recorded; the clone itself excludes no agent memory\n'
    else
      printf 'VERDICT: divergent - the clone itself excludes agent memory; record the source checkout to see the rest\n'
    fi
    return 0
  fi

  if [ ! -d "$source" ]; then
    printf 'SOURCE: %s (unreachable)\n' "$source"
    printf 'VERDICT: unknown - the recorded source checkout is not reachable from this host\n'
    return 0
  fi
  if ! is_git_worktree_root "$source"; then
    printf 'SOURCE: %s (not a git worktree root)\n' "$source"
    printf 'VERDICT: unknown - the recorded source checkout is not a git worktree root\n'
    return 0
  fi
  printf 'SOURCE: %s\n' "$source"

  source_head=$(source_git "$source" rev-parse HEAD 2>/dev/null || true)
  source_branch=$(source_git "$source" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  printf 'HEAD: source %s (%s)' "${source_head:0:12}" "${source_branch:-detached}"
  if [ -n "$clone_head" ]; then
    if [ "$source_head" = "$clone_head" ]; then
      printf ' == clone %s\n' "${clone_head:0:12}"
    else
      printf ' != clone %s\n' "${clone_head:0:12}"
    fi
  else
    printf ' (no clone commit to compare)\n'
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-memory.XXXXXX") || die "could not create a scratch directory"

  # Commits that exist in the source checkout but were never pushed to any
  # remote it knows, so no clone anywhere can have them.
  source_git "$source" log --format='%h %s' --branches --not --remotes >"$tmp/unpushed" 2>/dev/null || : >"$tmp/unpushed"
  local unpushed
  unpushed=$(wc -l <"$tmp/unpushed" | tr -d ' ')
  if [ "$unpushed" -gt 0 ]; then
    printf 'UNPUSHED_COMMITS: %s\n' "$unpushed"
    print_capped_list "$limit" <"$tmp/unpushed"
    gap=$((gap + unpushed))
  else
    printf 'UNPUSHED_COMMITS: none\n'
  fi

  # --untracked-files=all: git's default folds a wholly untracked directory into
  # one entry, and the classifier reading `informes/` never sees the production
  # audit inside it - the same content counted 0 or 2 in the gap depending only
  # on whether some unrelated tracked file sat beside it. Every untracked path
  # reaches the classifier one by one instead. It is still one git call, but a
  # dependency tree the project has not ignored yet is now enumerated rather
  # than folded, so on /mnt/c the cheap scan is the one whose .gitignore is in
  # order; the report stays bounded either way, because such a tree is scratch
  # by location and never reaches a list.
  source_git "$source" status --porcelain --untracked-files=all >"$tmp/status" 2>/dev/null || : >"$tmp/status"
  : >"$tmp/modified_knowledge"
  : >"$tmp/knowledge"
  : >"$tmp/other"
  local scratch=0 modified_other=0 line path code
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code=${line:0:2}
    path=${line:3}
    # Porcelain still quotes a path holding control characters, a quote, or a
    # backslash; keep that form so the report never prints a half-decoded path
    # as if it were the real name.
    case $code in
      # Scope, not precedence. Inside a dependency or build tree scratch wins
      # whatever the file is called, so `node_modules/react/README.md` stays
      # out of the report. In an ordinary tree knowledge wins over a scratch
      # NAME, so `docs/conversaciones.log` - a conversation dump, not build
      # output - is counted rather than disappearing into a number.
      '??')
        if looks_like_scratch_tree "$path"; then
          scratch=$((scratch + 1))
        elif looks_like_knowledge "$path"; then
          printf '%s\n' "$path" >>"$tmp/knowledge"
        elif looks_like_scratch_name "$path"; then
          scratch=$((scratch + 1))
        else
          printf '%s\n' "$path" >>"$tmp/other"
        fi
        ;;
      *)
        if looks_like_knowledge "$path"; then
          printf '%s %s\n' "$code" "$path" >>"$tmp/modified_knowledge"
        else
          modified_other=$((modified_other + 1))
        fi
        ;;
    esac
  done <"$tmp/status"

  local knowledge other modified_knowledge
  knowledge=$(wc -l <"$tmp/knowledge" | tr -d ' ')
  other=$(wc -l <"$tmp/other" | tr -d ' ')
  modified_knowledge=$(wc -l <"$tmp/modified_knowledge" | tr -d ' ')

  if [ "$knowledge" -gt 0 ]; then
    printf 'UNCOMMITTED_KNOWLEDGE: %s\n' "$knowledge"
    print_path_list "$limit" <"$tmp/knowledge"
    gap=$((gap + knowledge))
  else
    printf 'UNCOMMITTED_KNOWLEDGE: none\n'
  fi
  if [ "$modified_knowledge" -gt 0 ]; then
    printf 'MODIFIED_KNOWLEDGE: %s\n' "$modified_knowledge"
    print_capped_list "$limit" <"$tmp/modified_knowledge"
    gap=$((gap + modified_knowledge))
  else
    printf 'MODIFIED_KNOWLEDGE: none\n'
  fi
  if [ "$other" -gt 0 ]; then
    printf 'UNCOMMITTED_OTHER: %s\n' "$other"
    print_path_list "$limit" <"$tmp/other"
    context=$((context + other))
  else
    printf 'UNCOMMITTED_OTHER: none\n'
  fi
  printf 'MODIFIED_OTHER: %s\n' "$modified_other"
  context=$((context + modified_other))
  printf 'SCRATCH_IGNORED_FROM_REPORT: %s\n' "$scratch"

  scan_agent_memory "$source" "$limit" source "$tmp/agentmem_paths"
  gap=$((gap + AGENT_MEM_COUNT))

  # Ignored trees that actually hold material, excluding the agent-memory paths
  # already reported above. git expands a fully ignored directory into its
  # individual entries as soon as one tracked path lives under it, so each entry
  # is folded back to the highest ancestor the project itself ignores. That fold
  # is what keeps one ignored tree to one line instead of hundreds, and what
  # keeps a cache directory nested under a live source tree from being reported
  # as if the whole source tree were ignored.
  source_git "$source" status --porcelain --ignored >"$tmp/ignored_raw" 2>/dev/null || : >"$tmp/ignored_raw"
  sed -n 's/^!! //p' "$tmp/ignored_raw" >"$tmp/ignored_entries"
  : >"$tmp/ancestors"
  local entry prefix rest
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    prefix=
    rest=${entry%/}
    while [ "$rest" != "${rest#*/}" ]; do
      prefix="$prefix${rest%%/*}/"
      rest=${rest#*/}
      printf '%s\n' "$prefix" >>"$tmp/ancestors"
    done
  done <"$tmp/ignored_entries"
  LC_ALL=C sort -u "$tmp/ancestors" >"$tmp/ancestors_uniq"
  : >"$tmp/ignored_ancestors"
  if [ -s "$tmp/ancestors_uniq" ]; then
    # --no-index deliberately: the question here is what the project's own
    # ignore rules say about a directory, and a fully ignored working directory
    # that still holds one tracked path (a file deleted but not yet committed,
    # say) is reported as unignored without it, which would expand that one tree
    # back into the hundreds of lines this fold exists to collapse.
    source_git "$source" check-ignore --no-index --stdin <"$tmp/ancestors_uniq" >"$tmp/ignored_ancestors" 2>/dev/null || :
  fi
  : >"$tmp/ignored_roots"
  local root
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    root=$entry
    prefix=
    rest=${entry%/}
    while [ "$rest" != "${rest#*/}" ]; do
      prefix="$prefix${rest%%/*}/"
      rest=${rest#*/}
      if grep -qxF "${prefix%/}" "$tmp/ignored_ancestors" 2>/dev/null ||
        grep -qxF "$prefix" "$tmp/ignored_ancestors" 2>/dev/null; then
        root=$prefix
        break
      fi
    done
    printf '%s\n' "$root" >>"$tmp/ignored_roots"
  done <"$tmp/ignored_entries"
  LC_ALL=C sort -u "$tmp/ignored_roots" >"$tmp/ignored_roots_uniq"

  : >"$tmp/ignored_material"
  : >"$tmp/ignored_knowledge"
  local count
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    grep -qxF "${root%/}" "$tmp/agentmem_paths" 2>/dev/null && continue
    looks_like_scratch "$root" && continue
    # What the project's own ignore rules keep out of every clone is the same
    # leak as something uncommitted, and no other pass sees it: porcelain
    # without --ignored never lists it, and the agent-memory scan only knows a
    # fixed set of names. The same classifier decides on both shapes - a
    # `notes/` the project ignores is knowledge exactly as `notes/audit.md` is -
    # so knowledge counts in the gap whether the ignore rule named a file or
    # the whole directory. The fold above is what keeps an ignored tree to one
    # line instead of every file under it.
    case $root in
      */)
        [ -d "$source/$root" ] || continue
        count=$(bounded_file_count "$source/$root" 500)
        case $count in
          0) continue ;;
        esac
        if looks_like_knowledge "$root"; then
          printf '%s (%s files)\n' "$root" "$count" >>"$tmp/ignored_knowledge"
        else
          printf '%s (%s files)\n' "$root" "$count" >>"$tmp/ignored_material"
        fi
        ;;
      *)
        looks_like_knowledge "$root" || continue
        printf '%s\n' "$root" >>"$tmp/ignored_knowledge"
        ;;
    esac
  done <"$tmp/ignored_roots_uniq"
  local ignored_knowledge
  ignored_knowledge=$(wc -l <"$tmp/ignored_knowledge" | tr -d ' ')
  if [ "$ignored_knowledge" -gt 0 ]; then
    printf 'IGNORED_KNOWLEDGE: %s\n' "$ignored_knowledge"
    print_capped_list "$limit" <"$tmp/ignored_knowledge"
    gap=$((gap + ignored_knowledge))
  else
    printf 'IGNORED_KNOWLEDGE: none\n'
  fi
  local ignored_material
  ignored_material=$(wc -l <"$tmp/ignored_material" | tr -d ' ')
  if [ "$ignored_material" -gt 0 ]; then
    printf 'IGNORED_DIRS_WITH_MATERIAL: %s\n' "$ignored_material"
    print_capped_list "$limit" <"$tmp/ignored_material"
    context=$((context + ignored_material))
  else
    printf 'IGNORED_DIRS_WITH_MATERIAL: none\n'
  fi

  rm -rf -- "$tmp"

  printf 'KNOWLEDGE_GAP: %s\n' "$gap"
  printf 'OTHER_MATERIAL: %s\n' "$context"
  if [ "$canonical" = source ]; then
    if [ "$gap" -eq 0 ]; then
      printf 'VERDICT: source-canonical - this project'"'"'s home is the source checkout and it currently holds no agent knowledge beyond the repository\n'
    else
      printf 'VERDICT: source-canonical - this project'"'"'s home is the source checkout, so standing apart from the repository is how the work is done here, not a fault to repair. knowledge lives only there (%s items), and a worker dispatched to the clone starts without it: carry what it needs through the project'"'"'s local material store (bin/fm-project-local.sh) instead of expecting a commit.\n' "$gap"
    fi
  elif [ "$gap" -eq 0 ]; then
    printf 'VERDICT: parity - no agent knowledge found that did not travel; the %s other items above are working material listed for context\n' "$context"
  else
    printf 'VERDICT: divergent - knowledge did not travel (%s items); decide what gets versioned, what is anonymised first, and what stays out\n' "$gap"
  fi
  return 0
}

# --- knowledge home ---------------------------------------------------------

# The directory that is <project>'s knowledge home: the recorded source
# checkout when it is canonical, else <clone>. A canonical home that cannot be
# reached is refused rather than replaced by the clone, which is only a stale
# mirror of it: the recorded path is still printed, and the return is 4, so a
# caller that must go on without the home (a spawn) can still name it and say
# it was not verified, while every other caller fails on the nonzero status.
resolve_knowledge_home() {  # <project> <clone>; prints the directory
  local project=$1 dir=$2 rc
  if read_source_record "$project"; then
    if [ "$SOURCE_RECORD_CANONICAL" = source ]; then
      dir=$SOURCE_RECORD_PATH
      if [ ! -d "$dir" ]; then
        echo "project-memory: the knowledge home of $project is the source checkout $dir, and it is not reachable from this host; the clone is only a stale mirror of it" >&2
        printf '%s\n' "$dir"
        return 4
      fi
    fi
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  if [ ! -d "$dir" ]; then
    echo "project-memory: no reachable knowledge home for $project" >&2
    return 1
  fi
  printf '%s\n' "$dir"
}

# --- registry sweep ---------------------------------------------------------

registry_projects() {
  local reg="${FM_DATA_OVERRIDE:-$FM_HOME/data}/projects.md"
  [ -f "$reg" ] || return 0
  awk '$1 == "-" && $2 != "" { print $2 }' "$reg"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h | --help | '')
    usage
    exit 0
    ;;
esac

CMD=$1
shift

case "$CMD" in
  source)
    ACTION=${1:-}
    shift || true
    case "$ACTION" in
      set)
        NAME=${1:-}
        PATH_IN=${2:-}
        [ -n "$NAME" ] && [ -n "$PATH_IN" ] || die "usage: source set <project> <path> [--canonical repo|source]"
        shift 2
        CANONICAL=repo
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --canonical)
              [ "$#" -gt 1 ] || die "--canonical requires repo or source"
              CANONICAL=$2
              shift 2
              ;;
            *) die "unknown option: $1" ;;
          esac
        done
        case "$CANONICAL" in
          repo | source) ;;
          *) die "--canonical must be repo or source" ;;
        esac
        valid_project_name "$NAME" || die "invalid project name: $NAME"
        case $PATH_IN in
          /*) ;;
          *) die "source path must be absolute: $PATH_IN" ;;
        esac
        case $PATH_IN in
          *[[:cntrl:]]*) die "source path holds control characters" ;;
        esac
        [ -d "$PATH_IN" ] || die "source path is not a directory: $PATH_IN"
        RESOLVED=$(cd "$PATH_IN" && pwd -P) || die "source path cannot be resolved: $PATH_IN"
        is_git_worktree_root "$RESOLVED" || die "source path is not a git worktree root: $RESOLVED"
        if [ "$RESOLVED" = "$(cd "$PROJECTS_DIR/$NAME" 2>/dev/null && pwd -P || true)" ]; then
          die "source path is this home's own clone; record the checkout the project was worked in before firstmate cloned it"
        fi
        case "$RESOLVED/" in
          "$FM_HOME"/*) die "source path is inside the firstmate home; a source checkout lives outside it" ;;
        esac
        [ -L "$SOURCES_DIR" ] && die "refusing symlinked $SOURCES_DIR"
        mkdir -p "$SOURCES_DIR"
        REC=$(source_record_path "$NAME")
        [ -L "$REC" ] && die "refusing symlinked source record $REC"
        printf 'path=%s\ncanonical=%s\n' "$RESOLVED" "$CANONICAL" >"$REC"
        echo "recorded: $NAME source checkout $RESOLVED (canonical=$CANONICAL)"
        ;;
      clear)
        NAME=${1:-}
        [ -n "$NAME" ] || die "usage: source clear <project>"
        valid_project_name "$NAME" || die "invalid project name: $NAME"
        REC=$(source_record_path "$NAME")
        [ -L "$REC" ] && die "refusing symlinked source record $REC"
        if [ -e "$REC" ]; then
          rm -f -- "$REC"
          echo "cleared: $NAME source checkout record"
        else
          echo "none recorded"
        fi
        ;;
      *) die "usage: source set|clear" ;;
    esac
    ;;
  home)
    NAME=${1:-}
    [ -n "$NAME" ] || die "usage: home <project> [--clone <dir>]"
    valid_project_name "$NAME" || die "invalid project name: $NAME"
    shift
    HOME_DIR="$PROJECTS_DIR/$NAME"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --clone)
          [ "$#" -gt 1 ] || die "--clone requires a directory"
          HOME_DIR=$2
          shift 2
          ;;
        *) die "unknown option: $1" ;;
      esac
    done
    resolve_knowledge_home "$NAME" "$HOME_DIR" || exit $?
    ;;
  activity)
    NAME=
    ACT_HOME=
    WINDOW=300
    GIT_ONLY=0
    case "${1:-}" in
      '' | --*) ;;
      *)
        NAME=$1
        shift
        ;;
    esac
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --home)
          [ "$#" -gt 1 ] || die "--home requires a directory"
          ACT_HOME=$2
          shift 2
          ;;
        --git-only)
          GIT_ONLY=1
          shift
          ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [ -n "$NAME" ] || [ -n "$ACT_HOME" ] || die "usage: activity <project> [--home <dir>] [--git-only]"
    [ -z "$NAME" ] || valid_project_name "$NAME" || die "invalid project name: $NAME"
    if [ -z "$ACT_HOME" ]; then
      ACT_HOME=$(resolve_knowledge_home "$NAME" "$PROJECTS_DIR/$NAME") || exit 1
    fi
    [ -d "$ACT_HOME" ] || die "no reachable knowledge home for $ACT_HOME"
    ACT_HOME=$(cd "$ACT_HOME" && pwd -P)
    report_activity "$ACT_HOME" "$WINDOW" "$GIT_ONLY"
    [ "$ACTIVITY_STATE" = quiet ] || exit 3
    ;;
  scan)
    ALL=0
    NAME=
    LIMIT=40
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --all)
          ALL=1
          shift
          ;;
        --limit)
          [ "$#" -gt 1 ] || die "--limit requires a number"
          LIMIT=$2
          shift 2
          ;;
        -*) die "unknown option: $1" ;;
        *)
          [ -z "$NAME" ] || die "scan takes at most one project"
          NAME=$1
          shift
          ;;
      esac
    done
    case "$LIMIT" in
      '' | *[!0-9]*) die "--limit requires a whole number" ;;
    esac
    [ "$LIMIT" -gt 0 ] || die "--limit requires a positive number"
    if [ "$ALL" -eq 1 ]; then
      [ -z "$NAME" ] || die "--all takes no project name"
      FIRST=1
      while IFS= read -r P; do
        valid_project_name "$P" || continue
        [ "$FIRST" -eq 1 ] || echo
        FIRST=0
        scan_project "$P" "$LIMIT"
      done < <(registry_projects)
      [ "$FIRST" -eq 0 ] || echo "no projects registered"
      exit 0
    fi
    [ -n "$NAME" ] || die "usage: scan <project> | scan --all"
    valid_project_name "$NAME" || die "invalid project name: $NAME"
    scan_project "$NAME" "$LIMIT"
    ;;
  *)
    die "unknown command: $CMD (try --help)"
    ;;
esac
