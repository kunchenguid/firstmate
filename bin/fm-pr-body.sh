#!/usr/bin/env bash
# fm-pr-body.sh - single owner of deterministic PR-body rendering from a
# project's tracked or private template, so a PR body never depends on a
# worker remembering a format and drift is caught structurally rather than
# only after the captain notices it.
#
# Template resolution, per project, in order:
#   1. This home's private per-project template at data/pr-templates/<project>.md
#   2. The target repository's own .github pull-request template, one of:
#      .github/PULL_REQUEST_TEMPLATE.md, .github/pull_request_template.md, or
#      the lexicographically first *.md file under .github/PULL_REQUEST_TEMPLATE/
# When neither exists, `render` exits 3 and prints nothing to stdout: the
# caller must fall back to the project's existing PR-rules discovery path
# (bin/fm-brief.sh's PR requirements section) rather than inventing a
# universal body.
# --project must be one safe path segment (letters, digits, '.', '_', '-';
# no '/', not '.' or '..') so it can never traverse outside data/pr-templates.
#
# A private template's own rendering contract - not the repository fallback's -
# is generic to every private template, not specific to any one project: before
# filling placeholders, render strips a leading H1 title line (the template's
# own name, not part of the PR body) and every `<!-- ... -->` guidance comment
# (including ones spanning multiple lines), then preserves the remaining
# section order untouched. A repository's own .github template is used as-is,
# since its conventions are not this home's to assume.
#
# Usage:
#   fm-pr-body.sh render --project <name> --repo-dir <path> [--out <path>]
#                         [--set KEY=VALUE]... [--set-file KEY=<path>]...
#   fm-pr-body.sh check --file <path>
#   fm-pr-body.sh check                 (reads the body from stdin)
#   fm-pr-body.sh publish [--task <id>] [--expect-key <key>] --file <path> -- <forge command> [args...]
#   fm-pr-body.sh has-template --project <name> --repo-dir <path>
#
# render fills only named {{PLACEHOLDER}} slots explicitly supplied via --set
# or --set-file; every KEY must match ^[A-Z][A-Z0-9_]*$, matching the
# double-brace SCREAMING_SNAKE_CASE convention. Substitution is plain literal
# string replacement (bash parameter expansion): no eval, no shell
# re-parsing of values, and the template's own content is never accepted as
# an argv value, only resolved by project name and repository directory.
# --set-file reads its value from a file, for content too large or too
# structured (multi-line command output) to quote comfortably in argv;
# internal newlines and content are preserved, but - like $(cat file)
# generally - any trailing newlines on the file are not.
# Callers must never pass credentials as a --set value.
#
# render itself refuses (exit 1) when any {{SCREAMING_SNAKE_CASE}} slot
# remains after filling, naming every unresolved key in one concise line on
# stderr; nothing is written to --out and nothing is printed to stdout on
# that path, so a partial or unrendered body never reaches disk. This makes
# the refusal structural: a direct-PR ship's `render ... --out body.md &&
# fm-pr-body.sh publish --file body.md -- gh-axi pr create --body-file
# body.md` never reaches the open call on unresolved input, without depending
# on a worker remembering a second check command. no-mistakes ships have no
# equivalent seam yet: `no-mistakes axi run --help` documents `--intent` as
# the user's goal only, with no PR-body
# input of any kind, so this mechanism does not cover no-mistakes mode in
# this slice. That gap is a follow-up, not something to paper over by
# overloading --intent.
#
# check applies the same unresolved-placeholder scan to an already-rendered
# or externally-sourced body (e.g. one fetched back from a forge, or hand-
# edited) rather than to fresh render output; render's own refusal is the
# primary gate.
#
# publish is the executable publication boundary for every colleague-facing
# text surface a direct-PR worker owns - the PR body (templated or
# untemplated), a PR comment, or a review reply. It applies the same refusal
# as check to the --file content. Unkeyed calls exec the forge command after
# `--` verbatim; keyed PR-comment calls use the durable effect slot and bounded
# readback seam instead, with no exactly-once guarantee. Unsafe text never
# reaches the network. publish never guesses the forge command: a missing or
# empty command after `--` is a usage error.
#
# render, check, and publish also refuse (exit 1) a body that contains a
# local home or temporary-directory path (e.g. /home/<user>/...,
# /Users/<user>/..., /root/..., C:\Users\<user>\... or C:/Users/<user>/...,
# /tmp/..., /var/tmp/..., /private/tmp/...,
# /private/var/folders/...): those shapes leak this machine's local layout
# and are never acceptable evidence. A repository-relative path (no leading
# '/'), a URL, ordinary prose, and a command example that names no real
# local path remain unaffected. The refusal names the problem concisely and
# never echoes the offending path back onto stderr.
# The required evidence contract for anything that would otherwise need a
# local path (a screenshot, a log capture) is an uploaded URL, or a pending-
# upload marker plus a plain-text description; a local path is never an
# acceptable fallback for that evidence.
#
# has-template --project <name> --repo-dir <path> is a silent predicate:
# exit 0 when render would find a private or repository template for that
# project and repo, exit 1 when it would step aside (exit 3), exit 2 on a
# usage error, and exit 4 when template inspection fails, all with no stdout.
# It shares render's own template-resolution so a caller (bin/fm-brief.sh's
# scaffold requirement) never hand-rolls a second detector that can drift
# from render's real behavior.
#
# Exit codes: 0 ok (unkeyed publish propagates the forge command's own exit
# status); 1 refusal, unresolved publication, or an I/O failure; 2 usage error;
# 3 render found no private or repository template (step-aside signal); 4
# template inspection was unreadable or unsafe.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die_usage() {
  echo "error: $1" >&2
  exit 2
}

# Literal substring replacement that never re-interprets the replacement
# text. Bash's built-in ${var//pattern/replacement} treats "replacement" as
# a fresh expansion context rather than an opaque string - observed here to
# special-case a bare "&" as "insert the matched text" - which is unsafe for
# an arbitrary caller-supplied value. Quoting $search inside a %%/# removal
# pattern forces a literal (non-glob) match, and $repl is only ever placed by
# plain concatenation, so nothing here is re-parsed as shell syntax.
replace_literal() {
  local hay=$1 search=$2 repl=$3
  local result='' rest=$hay
  while true; do
    case "$rest" in
      *"$search"*)
        result="$result${rest%%"$search"*}$repl"
        rest=${rest#*"$search"}
        ;;
      *)
        result="$result$rest"
        break
        ;;
    esac
  done
  printf '%s' "$result"
}

# find_unresolved <content>: prints the sorted, de-duplicated, comma-joined
# list of every remaining {{SCREAMING_SNAKE_CASE}} key in <content>, or
# nothing when none remain.
find_unresolved() {
  printf '%s' "$1" | grep -oE '\{\{[A-Z][A-Z0-9_]*\}\}' | sed 's/[{}]//g' | LC_ALL=C sort -u | paste -sd, -
}

# has_local_path_leak <content>: true (exit 0) when <content> contains an
# absolute path shaped like a local home or temporary directory. Every
# candidate path token is extracted first (a maximal run of leading-'/'
# segments), so a URL's domain segment always lands before any /home,
# /Users, /tmp, etc. segment and the token as a whole never matches these
# glob prefixes - a URL is never flagged. A repository-relative path never
# starts with '/' at all, so it is never a candidate token either.
has_local_path_leak() {
  local content=$1 tok
  local tokens
  # Windows local-home shapes (C:\Users\... or C:/Users/...) carry no leading
  # '/', so the absolute-path token scan below never sees them; scan for the
  # drive-letter shape directly. The required separator after "users" keeps a
  # plain mention like "see c:/users guide" from matching.
  if printf '%s' "$content" | grep -qiE '[a-z]:[\\/]users[\\/]'; then
    return 0
  fi
  tokens=$(printf '%s' "$content" | grep -oE '(/[A-Za-z0-9._@-]+)+' || true)
  [ -n "$tokens" ] || return 1
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      /home/*|/Users/*|/root/*) return 0 ;;
      /tmp|/tmp/*) return 0 ;;
      /var/tmp|/var/tmp/*) return 0 ;;
      /private/tmp|/private/tmp/*) return 0 ;;
      /private/var/folders|/private/var/folders/*) return 0 ;;
    esac
  done <<<"$tokens"
  return 1
}

# Strip a private template's own guidance layer before it is filled: a
# leading H1 title line (and any blank lines around it) and every
# `<!-- ... -->` comment, which may span multiple lines. Pure text
# filtering only - the content never passes through eval or re-parsing.
strip_private_template_guidance() {
  awk '
    {
      line = $0
      if (in_comment) {
        idx = index(line, "-->")
        if (idx > 0) { line = substr(line, idx + 3); in_comment = 0 }
        else next
      }
      while (1) {
        s = index(line, "<!--")
        if (s == 0) break
        rest = substr(line, s)
        e = index(rest, "-->")
        if (e > 0) {
          line = substr(line, 1, s - 1) substr(rest, e + 3)
        } else {
          line = substr(line, 1, s - 1)
          in_comment = 1
          break
        }
      }
      print line
    }
  ' | awk '
    BEGIN { phase = 0 }
    {
      line = $0
      trimmed = line
      gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
      if (phase == 0) {
        if (trimmed == "") next
        if (trimmed ~ /^#[ \t]/) { phase = 1; next }
        phase = 2
      } else if (phase == 1) {
        if (trimmed == "") next
        phase = 2
      }
      print line
    }
  ' | awk '
    BEGIN { blank_run = 0 }
    {
      trimmed = $0
      gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
      if (trimmed == "") {
        blank_run++
        if (blank_run > 1) next
      } else {
        blank_run = 0
      }
      print
    }
  '
}

validate_key() {
  case "$1" in
    '') die_usage "empty placeholder key" ;;
  esac
  case "$1" in
    [A-Z]*) ;;
    *) die_usage "placeholder key '$1' must match ^[A-Z][A-Z0-9_]*\$" ;;
  esac
  case "$1" in
    *[!A-Z0-9_]*) die_usage "placeholder key '$1' must match ^[A-Z][A-Z0-9_]*\$" ;;
  esac
}

# validate_project <name>: one safe path segment, so data/pr-templates/<name>.md
# can never traverse outside data/pr-templates.
validate_project() {
  case "$1" in
    '') die_usage "render requires --project <name>" ;;
  esac
  case "$1" in
    */*) die_usage "--project must be a single path segment (no '/'): $1" ;;
  esac
  case "$1" in
    .|..) die_usage "--project must not be '.' or '..': $1" ;;
  esac
  case "$1" in
    [A-Za-z0-9]*) ;;
    *) die_usage "--project must start with a letter or digit: $1" ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) die_usage "--project may contain only letters, digits, '.', '_', '-': $1" ;;
  esac
}

# require_kv <kv> <flag>: die_usage unless <kv> contains a literal '='.
# ${kv%%=*} and ${kv#*=} both silently return the whole string unchanged
# when there is no '=' at all, which would otherwise turn a bare "FOO" into
# key=FOO val=FOO instead of refusing the malformed KEY=VALUE argument.
require_kv() {
  case "$1" in
    *=*) ;;
    *) die_usage "$2 requires KEY=VALUE (no '=' found in '$1')" ;;
  esac
}

canonical_existing_path() {
  local path=$1 probe
  case "$path" in /*) ;; *) path="./$path" ;; esac
  if realpath -e / >/dev/null 2>&1; then
    realpath -e "$path" 2>/dev/null
    return
  fi
  probe="/.__fm-realpath-missing-${UID:-0}-$$"
  if [ -e "$probe" ] || [ -L "$probe" ] || realpath "$probe" >/dev/null 2>&1; then
    return 1
  fi
  realpath "$path" 2>/dev/null
}

nearest_existing_ancestor_is_searchable() {
  local path=$1 parent
  case "$path" in /*) ;; *) path="$PWD/${path#./}" ;; esac
  while :; do
    parent=${path%/*}
    [ -n "$parent" ] || parent=/
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      [ -d "$parent" ] && [ -x "$parent" ]
      return
    fi
    [ "$parent" != "$path" ] || return 1
    path=$parent
  done
}

template_directory_status() {
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ -x "$dir" ] || return 2
    canonical_existing_path "$dir" >/dev/null || return 2
    return 0
  fi
  nearest_existing_ancestor_is_searchable "$dir" || return 2
  return 1
}

opened_directory_matches_path() {
  local path=$1
  perl -e '
    my @opened = stat(STDIN) or exit 1;
    my @path = stat($ARGV[0]) or exit 1;
    exit(($opened[0] == $path[0] && $opened[1] == $path[1]) ? 0 : 1);
  ' "$path" <&8
}

FIRST_TEMPLATE_PATH=''
FIRST_TEMPLATE_DIRECTORY=''

first_template_in_directory() {
  local dir=$1 allowed_root=$2 dir_real root_real name status
  FIRST_TEMPLATE_PATH=''
  FIRST_TEMPLATE_DIRECTORY=''
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    nearest_existing_ancestor_is_searchable "$dir" || return 2
    return 1
  fi
  [ -d "$dir" ] && [ -x "$dir" ] || return 2
  if ! { exec 8< "$dir"; } 2>/dev/null; then
    return 2
  fi
  if ! dir_real=$(canonical_existing_path "$dir") \
      || ! root_real=$(canonical_existing_path "$allowed_root") \
      || ! opened_directory_matches_path "$dir_real"; then
    exec 8<&-
    return 2
  fi
  case "$dir_real" in
    "$root_real"/*) ;;
    *)
      exec 8<&-
      return 2
      ;;
  esac
  if name=$(perl -e '
    use Fcntl qw(S_ISREG);
    open(my $bound, "<&=8") or exit 2;
    chdir($bound) or exit 2;
    opendir(my $dir, ".") or exit 2;
    for my $name (sort grep { /[.]md\z/ } readdir($dir)) {
      my @st = stat($name);
      next unless @st && S_ISREG($st[2]);
      print $name;
      exit 0;
    }
    exit 3;
  ' <&8); then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0)
      FIRST_TEMPLATE_PATH="$dir_real/$name"
      FIRST_TEMPLATE_DIRECTORY=$dir_real
      return 0
      ;;
    3)
      exec 8<&-
      return 3
      ;;
    *)
      exec 8<&-
      return 2
      ;;
  esac
}

opened_template_matches_path() {
  local path=$1
  perl -e '
    my @opened = stat(STDIN) or exit 1;
    my @path = stat($ARGV[0]) or exit 1;
    exit(($opened[0] == $path[0] && $opened[1] == $path[1]) ? 0 : 1);
  ' "$path" <&9
}

BOUND_TEMPLATE=''
BOUND_TEMPLATE_SOURCE=''

# bind_template <root> <candidate>: open candidate on descriptor 9 and retain
# that descriptor only when the opened object remains below the canonical
# allowed root. The refusal deliberately contains no path, because a symlink
# target is untrusted local information.
bind_template() {
  local root=$1 candidate=$2 bound_directory=${3:-} root_real candidate_real
  if ! root_real=$(canonical_existing_path "$root"); then
    echo "error: PR template directory could not be inspected safely" >&2
    return 1
  fi
  if ! { exec 9< "$candidate"; } 2>/dev/null; then
    echo "error: PR template could not be opened safely" >&2
    return 1
  fi
  if ! candidate_real=$(canonical_existing_path "$candidate"); then
    exec 9<&-
    echo "error: PR template could not be inspected safely" >&2
    return 1
  fi
  case "$candidate_real" in
    "$root_real"/*)
      if ! opened_template_matches_path "$candidate_real"; then
        exec 9<&-
        echo "error: PR template changed while it was being resolved" >&2
        return 1
      fi
      if [ -n "$bound_directory" ] \
          && ! opened_directory_matches_path "$bound_directory"; then
        exec 9<&-
        echo "error: PR template directory changed while it was being resolved" >&2
        return 1
      fi
      BOUND_TEMPLATE=$candidate_real
      ;;
    *)
      exec 9<&-
      echo "error: PR template resolves outside its allowed template directory" >&2
      return 1
      ;;
  esac
}

# resolve_template <project> <repo_dir>: the single owner of template
# resolution (private-per-project, then a repository-owned .github
# template), shared by render and has-template so a caller never grows a
# second detector that can drift from render's real behavior. On success,
# leaves the selected template open on descriptor 9 and records its canonical
# path and source; on no template found, returns 3.
resolve_template() {
  local project=$1 repo_dir=$2 status
  local private_root="$DATA/pr-templates" private="$DATA/pr-templates/$project.md"
  local repo_root="$repo_dir/.github" template='' source=''
  BOUND_TEMPLATE=''
  BOUND_TEMPLATE_SOURCE=''
  if template_directory_status "$private_root"; then
    if [ -e "$private" ] || [ -L "$private" ]; then
      if [ ! -f "$private" ]; then
        echo "error: PR template could not be inspected safely" >&2
        return 1
      fi
      template=$private
      source=private
      bind_template "$private_root" "$template" || return $?
    fi
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      echo "error: PR template directory could not be inspected safely" >&2
      return 1
    fi
  fi
  if [ -z "$template" ]; then
    if template_directory_status "$repo_root"; then
      local cand
      for cand in "$repo_dir/.github/PULL_REQUEST_TEMPLATE.md" "$repo_dir/.github/pull_request_template.md"; do
        if [ -e "$cand" ] || [ -L "$cand" ]; then
          if [ ! -f "$cand" ]; then
            echo "error: PR template could not be inspected safely" >&2
            return 1
          fi
          template=$cand
          source=repository
          bind_template "$repo_root" "$template" || return $?
          break
        fi
      done
      if [ -z "$template" ]; then
        local template_dir="$repo_dir/.github/PULL_REQUEST_TEMPLATE"
        if first_template_in_directory "$template_dir" "$repo_root"; then
          status=0
        else
          status=$?
        fi
        case "$status" in
          0)
            template=$FIRST_TEMPLATE_PATH
            source=repository
            if bind_template "$repo_root" "$template" "$FIRST_TEMPLATE_DIRECTORY"; then
              status=0
            else
              status=$?
            fi
            exec 8<&-
            [ "$status" -eq 0 ] || return "$status"
            ;;
          1|3) ;;
          *)
            echo "error: PR template directory could not be inspected safely" >&2
            return 1
            ;;
        esac
      fi
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        echo "error: PR template directory could not be inspected safely" >&2
        return 1
      fi
    fi
  fi
  [ -n "$template" ] || return 3
  BOUND_TEMPLATE_SOURCE=$source
}

cmd_render() {
  local project='' repo_dir='' out=''
  local -a keys=() vals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project=${2:?--project requires a value}; shift 2 ;;
      --project=*) project=${1#--project=}; shift ;;
      --repo-dir) repo_dir=${2:?--repo-dir requires a value}; shift 2 ;;
      --repo-dir=*) repo_dir=${1#--repo-dir=}; shift ;;
      --out) out=${2:?--out requires a value}; shift 2 ;;
      --out=*) out=${1#--out=}; shift ;;
      --set)
        [ $# -ge 2 ] || die_usage "--set requires a KEY=VALUE argument"
        local kv=$2 key val; shift 2
        require_kv "$kv" "--set"
        key=${kv%%=*}; val=${kv#*=}
        validate_key "$key"
        keys+=("$key"); vals+=("$val")
        ;;
      --set=*)
        local kv=${1#--set=} key val; shift
        require_kv "$kv" "--set="
        key=${kv%%=*}; val=${kv#*=}
        validate_key "$key"
        keys+=("$key"); vals+=("$val")
        ;;
      --set-file)
        [ $# -ge 2 ] || die_usage "--set-file requires a KEY=<path> argument"
        local kv=$2 key path val; shift 2
        require_kv "$kv" "--set-file"
        key=${kv%%=*}; path=${kv#*=}
        validate_key "$key"
        [ -n "$path" ] || die_usage "--set-file $key= requires a file path"
        [ -f "$path" ] || die_usage "--set-file source file not found: $path"
        val=$(cat -- "$path") || { echo "error: could not read --set-file source: $path" >&2; exit 1; }
        keys+=("$key"); vals+=("$val")
        ;;
      --set-file=*)
        local kv=${1#--set-file=} key path val; shift
        require_kv "$kv" "--set-file="
        key=${kv%%=*}; path=${kv#*=}
        validate_key "$key"
        [ -n "$path" ] || die_usage "--set-file $key= requires a file path"
        [ -f "$path" ] || die_usage "--set-file source file not found: $path"
        val=$(cat -- "$path") || { echo "error: could not read --set-file source: $path" >&2; exit 1; }
        keys+=("$key"); vals+=("$val")
        ;;
      *) die_usage "unknown render argument: $1" ;;
    esac
  done
  validate_project "$project"
  [ -n "$repo_dir" ] || die_usage "render requires --repo-dir <path>"
  [ -d "$repo_dir" ] || die_usage "--repo-dir is not a directory: $repo_dir"

  local rc=0
  resolve_template "$project" "$repo_dir" || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "no-template: no private template at data/pr-templates/$project.md and no repository PR template found under $repo_dir/.github" >&2
    exit 3
  elif [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  local template=$BOUND_TEMPLATE source=$BOUND_TEMPLATE_SOURCE body
  if ! body=$(cat <&9); then
    exec 9<&-
    echo "error: could not read template: $template" >&2
    exit 1
  fi
  exec 9<&-
  if [ "$source" = private ]; then
    body=$(printf '%s\n' "$body" | strip_private_template_guidance)
  fi
  # Record unresolved keys from the selected template before substitution.
  # This keeps placeholder-looking text supplied by the caller out of the
  # unresolved scan while retaining the original template's gate.
  local unresolved_template unresolved='' key
  unresolved_template=$(find_unresolved "$body")
  if [ -n "$unresolved_template" ]; then
    local -a unresolved_keys=()
    IFS=',' read -r -a unresolved_keys <<< "$unresolved_template"
    local u=0 found_key
    while [ "$u" -lt "${#unresolved_keys[@]}" ]; do
      key=${unresolved_keys[$u]}
      found_key=0
      local k=0
      while [ "$k" -lt "${#keys[@]}" ]; do
        if [ "${keys[$k]}" = "$key" ]; then found_key=1; break; fi
        k=$((k + 1))
      done
      if [ "$found_key" -eq 0 ]; then
        [ -n "$unresolved" ] && unresolved="$unresolved,"
        unresolved="$unresolved$key"
      fi
      u=$((u + 1))
    done
  fi
  # Walk the selected template once. Values are appended as opaque content,
  # so placeholder-looking text inside a value is never parsed again.
  local filled='' rest=$body token key value found
  while [[ "$rest" =~ (\{\{[A-Z][A-Z0-9_]*\}\}) ]]; do
    token=${BASH_REMATCH[1]}
    filled="$filled${rest%%"$token"*}"
    rest=${rest#*"$token"}
    key=${token:2:${#token}-4}
    value=$token
    found=0
    local i=0
    while [ "$i" -lt "${#keys[@]}" ]; do
      if [ "${keys[$i]}" = "$key" ]; then
        value=${vals[$i]}
        found=1
        break
      fi
      i=$((i + 1))
    done
    [ "$found" -eq 1 ] && filled="$filled$value" || filled="$filled$token"
  done
  body="$filled$rest"

  if [ -n "$unresolved" ]; then
    echo "error: unresolved PR body placeholders: $unresolved" >&2
    exit 1
  fi

  if has_local_path_leak "$body"; then
    echo "error: rendered PR body contains a local filesystem path; publish only repo-relative paths, URLs, or an uploaded evidence link" >&2
    exit 1
  fi

  if [ -n "$out" ]; then
    printf '%s\n' "$body" > "$out" || { echo "error: could not write rendered body: $out" >&2; exit 1; }
    echo "rendered: $out (source=$source template=$template)" >&2
  else
    printf '%s\n' "$body"
    echo "source=$source template=$template" >&2
  fi
}

# refuse_unsafe_publication <content>: the single publication-text safety
# scan shared by check and publish so both surfaces enforce one contract that
# cannot drift. Returns 1 with a concise stderr refusal (never echoing the
# offending path) when unresolved placeholders or a local-path leak remain.
refuse_unsafe_publication() {
  local content=$1 unresolved
  unresolved=$(find_unresolved "$content")
  if [ -n "$unresolved" ]; then
    echo "error: unresolved PR body placeholders: $unresolved" >&2
    return 1
  fi
  if has_local_path_leak "$content"; then
    echo "error: publication text contains a local filesystem path; publish only repo-relative paths, URLs, or an uploaded evidence link" >&2
    return 1
  fi
  return 0
}

cmd_check() {
  local file=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file=${2:?--file requires a value}; shift 2 ;;
      --file=*) file=${1#--file=}; shift ;;
      *) die_usage "unknown check argument: $1" ;;
    esac
  done
  local content
  if [ -n "$file" ]; then
    [ -f "$file" ] || die_usage "--file not found: $file"
    content=$(cat -- "$file") || { echo "error: could not read: $file" >&2; exit 1; }
  else
    content=$(cat)
  fi
  refuse_unsafe_publication "$content" || exit 1
  exit 0
}

publication_sha256_file() {
  fm_pr_sha256 "$1"
}

publication_key() {  # <task-id> <generation> <target> <payload>
  local id=$1 gen=$2 target=$3 payload=$4
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n%s\n%s\ncomment\n%s' "$id" "$gen" "$target" "$payload" \
      | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n%s\n%s\ncomment\n%s' "$id" "$gen" "$target" "$payload" \
      | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

KEYED_PUBLICATION_TARGET=
KEYED_PUBLICATION_NUMBER=
KEYED_PUBLICATION_REPO=
KEYED_PUBLICATION_HOST=

classify_keyed_publication() {  # <body-file> <forge argv...>
  local file=$1 body_file repo host file_real body_real
  shift
  [ "$#" -eq 8 ] || return 1
  [ "$1" = gh-axi ] && [ "$2" = pr ] && [ "$3" = comment ] || return 1
  [[ "$4" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$5" = -R ] || return 1
  repo=$6
  [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ "$7" = --body-file ] || return 1
  body_file=$8
  [ -f "$body_file" ] || return 1
  file_real=$(canonical_existing_path "$file") || return 1
  body_real=$(canonical_existing_path "$body_file") || return 1
  [ "$file_real" = "$body_real" ] || return 1
  host=${GH_HOST:-github.com}
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  KEYED_PUBLICATION_NUMBER=$4
  KEYED_PUBLICATION_REPO=$repo
  KEYED_PUBLICATION_HOST=$host
  KEYED_PUBLICATION_TARGET="$host/$repo#$4"
}

normalize_publication_file() {  # <snapshot> <destination>
  local snapshot=$1 destination=$2
  if command -v perl >/dev/null 2>&1; then
    perl -0777 -pe 's/(?:\r?\n)*\z/\n/' "$snapshot" > "$destination"
  else
    local content
    content=$(cat -- "$snapshot") || return 1
    printf '%s\n' "$content" > "$destination"
  fi
}

publication_wire_file() {  # <snapshot> <key> <destination>
  local snapshot=$1 key=$2 destination=$3
  normalize_publication_file "$snapshot" "$destination" || return 1
  printf '<!-- fm-effect:%s -->\n' "$key" >> "$destination"
}

readback_output_parse() {  # <gh-axi TOON output>, sets READBACK_ITEMS/ID
  local output=$1
  READBACK_ITEMS=0
  READBACK_ID=0
  [[ "$output" =~ ^\[2\]:[[:space:]]([0-9]+),([0-9]+)$ ]] || return 1
  READBACK_ITEMS=${BASH_REMATCH[1]}
  READBACK_ID=${BASH_REMATCH[2]}
}

READBACK_ITEMS=0
READBACK_ID=0

publication_readback() {  # <wire> <host> <repo> <number>
  local wire=$1 host=$2 repo=$3 number=$4 page output rc=0 wire_json jq_program
  READBACK_ITEMS=0
  READBACK_ID=0
  wire_json=$(jq -Rs . < "$wire") || return 1
  jq_program='[length, (map(select((((.body // "") | gsub("\\r\\n"; "\\n") | sub("\\n+$"; "")) == ('"$wire_json"' | gsub("\\r\\n"; "\\n") | sub("\\n+$"; ""))))) | .[0].id // 0)]'
  page=1
  while [ "$page" -le 10 ]; do
    output=$(fm_run_timed 5 env GH_HOST="$host" gh-axi api \
      "/repos/$repo/issues/$number/comments?per_page=100&page=$page" \
      --jq "$jq_program" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      return 1
    fi
    readback_output_parse "$output" || return 1
    if [ "$READBACK_ID" -ne 0 ]; then
      return 0
    fi
    if [ "$READBACK_ITEMS" -lt 100 ]; then
      return 1
    fi
    page=$((page + 1))
    rc=0
  done
  return 1
}

publication_unresolved() {  # <key> <task-id> <generation>
  echo "publication unresolved for key $1: no automatic retry; inspect the PR, then rerun this publish with --expect-key $1 and the same body to read back again, or run fm-pipeline.sh effect abandon $2 $1 --gen $3" >&2
}

pipeline_effect_call() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_ROOT/bin/fm-pipeline.sh" effect "$@"
}

publication_forward_lock_refusal() {  # <owner-exit> <owner-output>
  local owner_rc=$1 owner_output=$2
  case "$owner_rc:$owner_output" in
    3:*refused:lock-held*|3:*refused:lock-unavailable*)
      printf '%s\n' "$owner_output" >&2
      return 0
      ;;
  esac
  return 1
}

cmd_publish() {
  local file='' task='' expect_key='' task_seen=0 expect_key_seen=0 forge_argv=() content snapshot wire gen payload key claim_output claim_rc=0 publish_allowed=0 verify_output verify_rc=0 deliver_output deliver_rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)
        [ $# -ge 2 ] || die_usage "--task requires a non-empty value"
        task=$2; task_seen=1; shift 2
        ;;
      --task=*) task=${1#--task=}; task_seen=1; shift ;;
      --expect-key)
        [ $# -ge 2 ] || die_usage "--expect-key requires a non-empty value"
        expect_key=$2; expect_key_seen=1; shift 2
        ;;
      --expect-key=*) expect_key=${1#--expect-key=}; expect_key_seen=1; shift ;;
      --file) file=${2:?--file requires a value}; shift 2 ;;
      --file=*) file=${1#--file=}; shift ;;
      --) shift; break ;;
      *) die_usage "unknown publish argument: $1 (expected: publish [--task <id>] [--expect-key <key>] --file <path> -- <forge command> [args...])" ;;
    esac
  done
  [ -n "$file" ] || die_usage "publish requires --file <path>"
  [ -f "$file" ] || die_usage "--file not found: $file"
  [ $# -gt 0 ] || die_usage "publish requires the forge command after --"
  forge_argv=("$@")
  content=$(cat -- "$file") || { echo "error: could not read: $file" >&2; exit 1; }
  if [ "$task_seen" -eq 0 ]; then
    [ "$expect_key_seen" -eq 0 ] || die_usage "--expect-key requires --task"
    refuse_unsafe_publication "$content" || exit 1
    # shellcheck source=bin/fm-pr-comment-watch-lib.sh
    . "$SCRIPT_DIR/fm-pr-comment-watch-lib.sh"
    if fm_pcw_forge_command_is_rereview_request "${forge_argv[@]}"; then
      if fm_pcw_extract_pr_url_from_forge_argv "${forge_argv[@]}"; then
        "$SCRIPT_DIR/fm-pr-comment-watch.sh" rereview-ready --url "$FM_PCW_PR_URL" || exit 1
      else
        echo "error: could not resolve the pull request URL for re-review readiness" >&2
        exit 1
      fi
    fi
    exec "${forge_argv[@]}"
  fi

  [ -n "$task" ] || die_usage "--task requires a non-empty value"
  if [ "$expect_key_seen" -eq 1 ] && [ -z "$expect_key" ]; then
    die_usage "--expect-key requires a non-empty value"
  fi
  fm_task_id_path_safe "$task" || die_usage "--task must be a safe task id"
  classify_keyed_publication "$file" "${forge_argv[@]}" || {
    echo "publish --task: unsupported argv shape for a keyed publication" >&2
    exit 2
  }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "publish --task: state directory is unavailable" >&2; exit 1; }
  snapshot=$(umask 077; mktemp "$STATE/.fm-effect-body.XXXXXX") || exit 1
  wire=
  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  cleanup_publication() { rm -f -- "$snapshot" "$wire"; }
  trap cleanup_publication EXIT
  cp -- "$file" "$snapshot" || exit 1
  chmod 0600 "$snapshot" || exit 1
  fm_pr_private_file_valid "$snapshot" 600 "$(fm_pr_file_device "$STATE")" || exit 1
  gen=$(awk 'index($0, "spawn_gen=") == 1 { print substr($0, 11); exit }' "$STATE/$task.meta" 2>/dev/null) || gen=
  case "$gen" in ''|*[[:space:]=]*) echo "publish --task: metadata generation is unavailable" >&2; exit 1 ;; esac
  payload=$(publication_sha256_file "$snapshot") || exit 1
  key=$(publication_key "$task" "$gen" "$KEYED_PUBLICATION_TARGET" "$payload") || exit 1
  if [ -n "$expect_key" ] && [ "$expect_key" != "$key" ]; then
    echo "refused:repair-key-mismatch" >&2
    exit 1
  fi
  wire=$(umask 077; mktemp "$STATE/.fm-effect-wire.XXXXXX") || exit 1
  publication_wire_file "$snapshot" "$key" "$wire" || exit 1
  chmod 0600 "$wire" || exit 1
  refuse_unsafe_publication "$(cat -- "$wire")" || exit 1
  if [ -n "$expect_key" ]; then
    verify_output=$(pipeline_effect_call verify "$task" "$key" --gen "$gen" \
      --target "$KEYED_PUBLICATION_TARGET" --payload "$payload" 2>&1) || verify_rc=$?
    if [ "$verify_rc" -ne 0 ]; then
      if publication_forward_lock_refusal "$verify_rc" "$verify_output"; then
        exit 3
      fi
      case "$verify_output" in
        *refused:slot-missing*) echo "refused:repair-slot-missing" >&2 ;;
        '') echo "refused:repair-verify" >&2 ;;
        *) printf '%s\n' "$verify_output" >&2 ;;
      esac
      exit 1
    fi
  else
    claim_output=$(pipeline_effect_call claim "$task" --gen "$gen" --target "$KEYED_PUBLICATION_TARGET" \
      --payload "$payload" 2>&1) || claim_rc=$?
    case "$claim_output" in
      delivered\ *) printf '%s\n' "$claim_output"; exit 0 ;;
      unresolved\ *) ;;
      claimed\ *) publish_allowed=1 ;;
      refused:*) printf '%s\n' "$claim_output" >&2; exit 1 ;;
      *)
        if publication_forward_lock_refusal "$claim_rc" "$claim_output"; then
          exit 3
        fi
        if [ "$claim_rc" -eq 0 ]; then
          echo "refused:effect-claim" >&2
        else
          echo "refused:effect-claim-failed" >&2
        fi
        exit 1
        ;;
    esac
  fi
  if [ "$publish_allowed" -eq 1 ]; then
    forge_argv[7]=$wire
    if "${forge_argv[@]}" >/dev/null 2>&1; then
      :
    else
      pipeline_effect_call ambiguous "$task" "$key" --gen "$gen" >/dev/null 2>&1 || true
    fi
  fi
  if publication_readback "$wire" "$KEYED_PUBLICATION_HOST" "$KEYED_PUBLICATION_REPO" "$KEYED_PUBLICATION_NUMBER"; then
    deliver_output=$(pipeline_effect_call deliver "$task" "$key" --gen "$gen" --receipt "$READBACK_ID" \
      --target "$KEYED_PUBLICATION_TARGET" --payload "$payload" 2>&1) || deliver_rc=$?
    if [ "$deliver_rc" -eq 0 ]; then
      printf 'delivered %s\n' "$READBACK_ID"
      exit 0
    fi
    if publication_forward_lock_refusal "$deliver_rc" "$deliver_output"; then
      exit 3
    fi
    case "$deliver_output" in
      refused:*) printf '%s\n' "$deliver_output" >&2 ;;
      '') echo "refused:effect-deliver" >&2 ;;
      *) printf '%s\n' "$deliver_output" >&2 ;;
    esac
    exit 1
  elif [ "$publish_allowed" -eq 1 ]; then
    pipeline_effect_call ambiguous "$task" "$key" --gen "$gen" >/dev/null 2>&1 || true
  fi
  publication_unresolved "$key" "$task" "$gen"
  exit 1
}


cmd_has_template() {
  local project='' repo_dir=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project=${2:?--project requires a value}; shift 2 ;;
      --project=*) project=${1#--project=}; shift ;;
      --repo-dir) repo_dir=${2:?--repo-dir requires a value}; shift 2 ;;
      --repo-dir=*) repo_dir=${1#--repo-dir=}; shift ;;
      *) die_usage "unknown has-template argument: $1" ;;
    esac
  done
  validate_project "$project"
  [ -n "$repo_dir" ] || die_usage "has-template requires --repo-dir <path>"
  local rc=0
  resolve_template "$project" "$repo_dir" || rc=$?
  case "$rc" in
    0) exec 9<&-; exit 0 ;;
    3) exit 1 ;;
    *) exit 4 ;;
  esac
}

SUBCOMMAND=${1:-}
[ -n "$SUBCOMMAND" ] || die_usage "a subcommand is required: render, check, publish, or has-template"
shift

case "$SUBCOMMAND" in
  render) cmd_render "$@" ;;
  check) cmd_check "$@" ;;
  publish) cmd_publish "$@" ;;
  has-template) cmd_has_template "$@" ;;
  *) die_usage "unknown subcommand '$SUBCOMMAND'; expected render, check, publish, or has-template" ;;
esac
