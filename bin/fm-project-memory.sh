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
#   fm-project-memory.sh source set <project> <path>
#   fm-project-memory.sh source get <project>
#   fm-project-memory.sh source clear <project>
#   fm-project-memory.sh source list
#   fm-project-memory.sh scan <project> [--source <path>] [--canonical repo|source] [--limit <n>]
#   fm-project-memory.sh scan --all [--limit <n>]
#
# Usage (continued):
#   fm-project-memory.sh home <project> [--clone <dir>]
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
# `home` prints the directory that IS the project's knowledge home under that
# record: the source checkout when it is canonical and reachable, and this
# home's clone otherwise. `--clone <dir>` names that fallback explicitly, for a
# caller such as bin/fm-spawn.sh that already holds the project directory it is
# working from and must not re-derive it. Callers that must read a project's committed agent
# memory or recipe catalog resolve it through this command rather than assuming
# the clone.
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
  GIT_OPTIONAL_LOCKS=0 git --no-optional-locks -C "$repo" --no-pager "$sub" "$@"
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
looks_like_knowledge() {  # <relative path>
  local p=$1 base=${1##*/}
  case $base in
    AGENTS.md | CLAUDE.md | GEMINI.md | QWEN.md | .cursorrules | .windsurfrules) return 0 ;;
    README* | CONTRIBUTING* | CHANGELOG* | NOTES* | TODO*) return 0 ;;
  esac
  case $base in
    *.md | *.mdx | *.rst | *.adoc | *.org | *.txt | *.pdf | *.docx) return 0 ;;
  esac
  case $p in
    docs/* | doc/* | notes/* | knowledge/* | playbooks/* | reference/* | research/* | findings/* | .agents/* | .claude/* | .cursor/* | .github/instructions/*) return 0 ;;
  esac
  return 1
}

# Scratch: build output, caches, editor state, and per-run artifacts. Reported
# as a count only, because listing it is what turns a report into noise.
looks_like_scratch() {  # <relative path>
  local p=$1 base=${1##*/}
  case $base in
    .DS_Store | Thumbs.db) return 0 ;;
    *.pyc | *.pyo | *.class | *.o | *.so | *.a | *.log | *.tmp | *.swp | *.bak | *.orig | *.rej) return 0 ;;
  esac
  case "/$p" in
    */node_modules/* | */__pycache__/* | */.venv/* | */venv/* | */.pytest_cache/* | */.mypy_cache/* | */.ruff_cache/* | */.gradle/* | */.idea/* | */.vscode/* | */dist/* | */build/* | */target/* | */coverage/* | */.next/* | */.turbo/*) return 0 ;;
  esac
  case $p in
    node_modules/ | __pycache__/ | .venv/ | venv/ | .pytest_cache/ | .mypy_cache/ | .ruff_cache/ | .gradle/ | .idea/ | .vscode/ | dist/ | build/ | target/ | coverage/ | .next/ | .turbo/) return 0 ;;
    *.egg-info/) return 0 ;;
  esac
  return 1
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

# --- scan -------------------------------------------------------------------

scan_project() {  # <project> <source-or-empty> <limit> [canonical-override]
  local project=$1 source=$2 limit=$3 canonical_override=${4:-}
  local clone rc source_head clone_head source_branch
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

  if [ -z "$source" ]; then
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
  fi
  [ -z "$canonical_override" ] || canonical=$canonical_override
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

  source_git "$source" status --porcelain >"$tmp/status" 2>/dev/null || : >"$tmp/status"
  : >"$tmp/modified_knowledge"
  : >"$tmp/knowledge"
  : >"$tmp/other"
  local scratch=0 modified_other=0 line path code
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code=${line:0:2}
    path=${line:3}
    # Porcelain quotes a path holding unusual bytes; keep the quoted form so the
    # report never prints a half-decoded path as if it were the real name.
    case $code in
      '??')
        if looks_like_scratch "$path"; then
          scratch=$((scratch + 1))
        elif looks_like_knowledge "$path"; then
          printf '%s\n' "$path" >>"$tmp/knowledge"
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
    print_capped_list "$limit" <"$tmp/knowledge"
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
    print_capped_list "$limit" <"$tmp/other"
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
  local count
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case $root in
      */) ;;
      *) continue ;;
    esac
    grep -qxF "${root%/}" "$tmp/agentmem_paths" 2>/dev/null && continue
    looks_like_scratch "$root" && continue
    [ -d "$source/$root" ] || continue
    count=$(bounded_file_count "$source/$root" 500)
    case $count in
      0) continue ;;
    esac
    printf '%s (%s files)\n' "$root" "$count" >>"$tmp/ignored_material"
  done <"$tmp/ignored_roots_uniq"
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
      get)
        NAME=${1:-}
        [ -n "$NAME" ] || die "usage: source get <project>"
        valid_project_name "$NAME" || die "invalid project name: $NAME"
        if read_source_record "$NAME"; then
          printf 'path=%s\ncanonical=%s\n' "$SOURCE_RECORD_PATH" "$SOURCE_RECORD_CANONICAL"
        else
          RC=$?
          [ "$RC" -eq 1 ] || exit 1
          echo "none recorded"
        fi
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
      list)
        [ -d "$SOURCES_DIR" ] || { echo "none recorded"; exit 0; }
        FOUND=0
        for REC in "$SOURCES_DIR"/*; do
          [ -f "$REC" ] || continue
          NAME=$(basename "$REC")
          valid_project_name "$NAME" || continue
          if read_source_record "$NAME"; then
            printf '%s\t%s\t%s\n' "$NAME" "$SOURCE_RECORD_CANONICAL" "$SOURCE_RECORD_PATH"
            FOUND=1
          fi
        done
        [ "$FOUND" -eq 1 ] || echo "none recorded"
        ;;
      *) die "usage: source set|get|clear|list" ;;
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
    if read_source_record "$NAME"; then
      if [ "$SOURCE_RECORD_CANONICAL" = source ] && [ -d "$SOURCE_RECORD_PATH" ]; then
        HOME_DIR=$SOURCE_RECORD_PATH
      fi
    else
      RC=$?
      [ "$RC" -eq 1 ] || exit 1
    fi
    [ -d "$HOME_DIR" ] || die "no reachable knowledge home for $NAME"
    printf '%s\n' "$HOME_DIR"
    ;;
  scan)
    ALL=0
    NAME=
    SOURCE_OVERRIDE=
    CANONICAL_OVERRIDE=
    LIMIT=40
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --all)
          ALL=1
          shift
          ;;
        --source)
          [ "$#" -gt 1 ] || die "--source requires a path"
          SOURCE_OVERRIDE=$2
          shift 2
          ;;
        --canonical)
          [ "$#" -gt 1 ] || die "--canonical requires repo or source"
          CANONICAL_OVERRIDE=$2
          shift 2
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
      [ -z "$SOURCE_OVERRIDE" ] || die "--source cannot be combined with --all"
      FIRST=1
      while IFS= read -r P; do
        valid_project_name "$P" || continue
        [ "$FIRST" -eq 1 ] || echo
        FIRST=0
        scan_project "$P" "" "$LIMIT"
      done < <(registry_projects)
      [ "$FIRST" -eq 0 ] || echo "no projects registered"
      exit 0
    fi
    [ -n "$NAME" ] || die "usage: scan <project> | scan --all"
    valid_project_name "$NAME" || die "invalid project name: $NAME"
    if [ -n "$SOURCE_OVERRIDE" ]; then
      case $SOURCE_OVERRIDE in
        /*) ;;
        *) die "--source must be an absolute path" ;;
      esac
    fi
    case "$CANONICAL_OVERRIDE" in
      '' | repo | source) ;;
      *) die "--canonical must be repo or source" ;;
    esac
    scan_project "$NAME" "$SOURCE_OVERRIDE" "$LIMIT" "$CANONICAL_OVERRIDE"
    ;;
  *)
    die "unknown command: $CMD (try --help)"
    ;;
esac
