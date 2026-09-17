#!/usr/bin/env bash
# fm-chatgpt-return.sh - write a ChatGPT-bound captain-facing return.
#
# The primary firstmate is the sole consolidating writer. Call this BEFORE
# presenting a return that is explicitly intended to be carried back to
# ChatGPT. Do not write routine status updates or every internal message.
# The destination is transient transport, not canonical storage.
#
# A secondmate home always refuses. Writing to the live default path is also
# refused whenever FM_TASK_ID is set OR the script's own root is not a genuine
# primary checkout (fm-primary-scope-lib.sh's fm_primary_scope_matches: a
# linked task worktree fails this the same way a spawned task's isolated
# checkout always does, per AGENTS.md's worktree-isolation contract), so an
# environment-clearing wrapper that merely unsets FM_TASK_ID cannot make a
# task worker pass as the primary - worktree identity is not caller-supplied.
# An FM_CHATGPT_RETURN_PATH that canonicalizes (via `realpath -m`, which
# resolves through symlinks - including a dangling one - the same way whether
# or not the leaf exists yet) to the live default's own canonical path is
# required to differ under either of those conditions, so a crewmate cannot
# write the live transport as if it were the primary, including via a
# symlink, a "." or ".." segment, or a relative spelling of the same file.
# The write itself always targets the canonicalized destination, so the guard
# check and the actual write path can never diverge.
#
# write assembles the return, verifies that enumerated PR counts agree with
# listed items, then atomically replaces the destination.
# verify checks an existing file and writes nothing.
#
# PR identity for the count/list QA is repo-qualified when the text carries a
# repo (a full .../OWNER/REPO/pull/N URL or an OWNER/REPO#N shorthand), so two
# different repos' PR #6 are counted as two items rather than deduplicated into
# one; a bare "PR #N" or "#N" with no repo qualifier falls into one shared
# unqualified bucket per number, matching prior single-repo behavior. When a
# claim's list carries no numbered PR identity at all (title-only bullets),
# the QA falls back to counting the list's own top-level bullets against the
# claimed count instead of accepting the claim on no evidence.
#
# Usage:
#   fm-chatgpt-return.sh write --status <text> --return-file <path> \
#     [--task <text>] [--artifact <path>]... [--blocker <text>]... \
#     [--clear-safe yes|no]
#   fm-chatgpt-return.sh verify --file <path>
#
# Environment:
#   FM_HOME                    operational home; a secondmate marker refuses write
#   FM_CHATGPT_RETURN_PATH     destination override (tests). Default:
#                              $HOME/inbox/FIRST_MATE_TO_CHATGPT.md
#   FM_CHATGPT_RETURN_NOW      UTC timestamp override YYYY-MM-DDTHH:MM:SSZ
#   FM_TASK_ID                 when set, the default live path is refused; a
#                              linked task worktree is refused regardless
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DEFAULT_RETURN_PATH="${HOME}/inbox/FIRST_MATE_TO_CHATGPT.md"

# shellcheck source=bin/fm-primary-scope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-chatgpt-return: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'fm-chatgpt-return: %s\n' "$*" >&2
  usage >&2
  exit 2
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

word_to_count() {  # <token>
  local w
  w=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$w" in
    one) printf '1\n' ;;
    two) printf '2\n' ;;
    three) printf '3\n' ;;
    four) printf '4\n' ;;
    five) printf '5\n' ;;
    six) printf '6\n' ;;
    seven) printf '7\n' ;;
    eight) printf '8\n' ;;
    nine) printf '9\n' ;;
    ten) printf '10\n' ;;
    eleven) printf '11\n' ;;
    twelve) printf '12\n' ;;
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$w" ;;
  esac
}

# Unique repo-qualified PR identities from a text blob, one per line:
# "OWNER/REPO#N" when a repo is present (a full .../OWNER/REPO/pull/N URL or an
# OWNER/REPO#N shorthand), or the shared "#N" bucket for an unqualified "PR #N"
# / "#N" mention whose number was not already claimed by some repo-qualified
# reference. Matched repo-qualified references are consumed (removed from the
# working text) before the unqualified scan runs, so a URL's own trailing "#N"
# is never double-counted as a second reference; and a later bare "#N" that
# repeats a number already seen in a repo-qualified reference is treated as the
# same item rather than a new one, so "PR #6 (also #6 above)" still counts as
# one item while two different repos' own PR #6 still count as two.
collect_pr_ids() {
  perl -e '
    my $text = $ARGV[0];
    my %seen;
    my %numbers;
    while ($text =~ s{https?://\S*?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)\S*}{ }) {
      $seen{"$1#$2"} = 1;
      $numbers{$2} = 1;
    }
    while ($text =~ s{([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)}{ }) {
      $seen{"$1#$2"} = 1;
      $numbers{$2} = 1;
    }
    while ($text =~ m{(?:[Pp][Rr][[:space:]]*)?#([0-9]+)}g) {
      next if $numbers{$1};
      $seen{"#$1"} = 1;
    }
    print "$_\n" for sort keys %seen;
  ' "$1"
}

# First "N PRs" / "N pull requests" claim on a line, ignoring "PR #N".
claim_count_from_line() {  # <line> -> count or empty
  local line=$1 match token
  match=$(printf '%s' "$line" | grep -oE -i \
    '(all[[:space:]]+)?(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[0-9]+)[[:space:]]+([A-Za-z0-9._/-]+[[:space:]]+){0,6}(prs?|pull[[:space:]]+requests?)' \
    | head -n1) || true
  [ -n "$match" ] || return 1
  match=$(printf '%s' "$match" | sed -E 's/^[Aa]ll[[:space:]]+//')
  token=${match%%[[:space:]]*}
  word_to_count "$token"
}

chatgpt_return_check_claim() {  # <claimed-count> <buffer>
  local claimed=$1 buf=$2 ids id_count list_count
  ids=$(collect_pr_ids "$buf" || true)
  if [ -z "$ids" ]; then
    # No numbered PR identity was found anywhere in the claim's own buffer
    # (e.g. title-only bullets: "Three PRs landed:" followed by two bullets
    # naming no PR number). Fall back to counting the buffer's own top-level
    # list bullets - unindented lines starting with "-", the same shape
    # verify_file's own fold already collects into this buffer - rather than
    # accepting the claim on no evidence at all. A claim with neither IDs nor
    # a list to count against it (a bare inline sentence) stays permissive,
    # since there is nothing here to compare it to.
    list_count=$(printf '%s\n' "$buf" | grep -c '^-' || true)
    if [ "$list_count" -eq 0 ]; then
      return 0
    fi
    if [ "$list_count" -ne "$claimed" ]; then
      printf 'fm-chatgpt-return: claimed %s PRs but listed %s items\n' \
        "$claimed" "$list_count" >&2
      return 1
    fi
    return 0
  fi
  id_count=$(printf '%s\n' "$ids" | grep -c . || true)
  if [ "$id_count" -ne "$claimed" ]; then
    printf 'fm-chatgpt-return: claimed %s PRs but listed %s items\n' \
      "$claimed" "$id_count" >&2
    return 1
  fi
  return 0
}

verify_file() {  # <path>
  local file=$1 line claimed buf disagreements=0 collecting=0 saw_list=0
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] \
    || fail "return file is unavailable: $file"
  claimed=
  buf=
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$collecting" = 1 ]; then
      case "$line" in
        '#'*)
          chatgpt_return_check_claim "$claimed" "$buf" || disagreements=$((disagreements + 1))
          collecting=0
          claimed=
          buf=
          saw_list=0
          ;;
        '')
          if [ "$saw_list" = 1 ]; then
            chatgpt_return_check_claim "$claimed" "$buf" || disagreements=$((disagreements + 1))
            collecting=0
            claimed=
            buf=
            saw_list=0
            continue
          fi
          buf=$(printf '%s\n%s' "$buf" "$line")
          continue
          ;;
        -*)
          saw_list=1
          buf=$(printf '%s\n%s' "$buf" "$line")
          continue
          ;;
        *)
          if [ "$saw_list" = 1 ]; then
            case "$line" in
              [[:space:]]*)
                buf=$(printf '%s\n%s' "$buf" "$line")
                continue
                ;;
            esac
            chatgpt_return_check_claim "$claimed" "$buf" || disagreements=$((disagreements + 1))
            collecting=0
            claimed=
            buf=
            saw_list=0
          else
            buf=$(printf '%s\n%s' "$buf" "$line")
            continue
          fi
          ;;
      esac
    fi
    if claimed=$(claim_count_from_line "$line"); then
      collecting=1
      saw_list=0
      buf=$line
    fi
  done < "$file"
  if [ "$collecting" = 1 ]; then
    chatgpt_return_check_claim "$claimed" "$buf" || disagreements=$((disagreements + 1))
  fi
  [ "$disagreements" -eq 0 ] || return 1
}

# Resolve a path to its canonical absolute form via `realpath -m`: every
# symlink actually present is followed to its recorded target - including a
# dangling one, whose target need not exist - and only components that are not
# present at all (not even as a symlink) are appended literally. This is the
# property the guard below depends on: a dangling symlink at or above the
# destination still canonicalizes to whatever it points at, so it cannot be
# used to make a live-path alias look "different" to the guard.
canonical_path() {  # <path> -> resolved absolute path
  realpath -m -- "$1"
}

atomic_replace() {  # <dest> <content-file>
  local dest=$1 src=$2 dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir" || fail "could not create $dir"
  tmp=$(umask 077; mktemp "$dir/.fm-chatgpt-return.XXXXXX") \
    || fail "could not stage the ChatGPT return"
  if ! cat "$src" > "$tmp"; then
    rm -f -- "$tmp"
    fail "could not write the staged ChatGPT return"
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; fail "could not set ChatGPT return mode"; }
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    fail "could not replace $dest"
  fi
}

markdown_list() {  # items on stdin -> "- item" lines, or "None."
  local item out=''
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    out=$(printf '%s- %s\n' "$out" "$item")
  done
  if [ -z "$out" ]; then
    printf '%s\n' "None."
  else
    printf '%s' "$out"
  fi
}

command_verify() {
  local file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) shift; file=${1:-} ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown verify argument: $1" ;;
    esac
    shift
  done
  [ -n "$file" ] || usage_error "verify requires --file"
  verify_file "$file" || fail "enumerated PR counts disagree with listed items"
  printf 'ok: %s\n' "$file"
}

command_write() {
  local status='' return_file='' task='' clear_safe=yes dest now tmp
  local artifacts='' blockers='' item art_block blk_block
  local default_canonical
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) shift; status=${1:-} ;;
      --return-file) shift; return_file=${1:-} ;;
      --task) shift; task=${1:-} ;;
      --artifact)
        shift
        item=${1:-}
        validate_one_line artifact "$item"
        artifacts="${artifacts}${item}"$'\n'
        ;;
      --blocker)
        shift
        item=${1:-}
        validate_one_line blocker "$item"
        blockers="${blockers}${item}"$'\n'
        ;;
      --clear-safe) shift; clear_safe=${1:-} ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown write argument: $1" ;;
    esac
    shift
  done
  [ -n "$status" ] || usage_error "write requires --status"
  [ -n "$return_file" ] || usage_error "write requires --return-file"
  validate_one_line status "$status"
  [ -z "$task" ] || validate_one_line task "$task"
  case "$clear_safe" in
    yes|no) ;;
    *) fail "--clear-safe must be yes or no" ;;
  esac
  [ -f "$return_file" ] && [ -r "$return_file" ] && [ ! -L "$return_file" ] \
    || fail "return file is unavailable: $return_file"
  if fm_root_is_secondmate_home "$FM_HOME"; then
    fail "secondmate homes must not write the ChatGPT return transport"
  fi
  dest=$(canonical_path "${FM_CHATGPT_RETURN_PATH:-$DEFAULT_RETURN_PATH}") \
    || fail "could not canonicalize the destination path"
  default_canonical=$(canonical_path "$DEFAULT_RETURN_PATH") \
    || fail "could not canonicalize the live return path"
  if [ "$dest" = "$default_canonical" ]; then
    # FM_TASK_ID is an optional, caller-controlled signal: an
    # environment-clearing wrapper can unset it without ceasing to be a task
    # worker. fm_primary_scope_matches reads a fact FM_TASK_ID cannot spoof
    # away - whether this script's own root is a genuine primary checkout
    # (git_dir == git_common_dir) rather than a spawned task's linked
    # worktree - so either signal alone is enough to refuse.
    if [ -n "${FM_TASK_ID:-}" ] || ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
      fail "a task worker must not write the live ChatGPT return transport"
    fi
  fi
  now=${FM_CHATGPT_RETURN_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$now" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) fail "FM_CHATGPT_RETURN_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  art_block=$(printf '%s' "$artifacts" | markdown_list)
  blk_block=$(printf '%s' "$blockers" | markdown_list)
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-chatgpt-return-body.XXXXXX") \
    || fail "could not stage the ChatGPT return body"
  {
    printf '%s\n' "# First Mate → ChatGPT return"
    printf '\n'
    printf '%s\n' "Generated: $now"
    if [ -n "$task" ]; then
      printf '%s\n' "Originating task/packet: $task"
    fi
    printf '%s\n' "Result/status: $status"
    printf '\n'
    printf '%s\n' "## Concise return"
    printf '\n'
    cat "$return_file"
    printf '\n'
    printf '%s\n' "## Referenced artifacts"
    printf '\n'
    printf '%s\n' "$art_block"
    printf '\n'
    printf '%s\n' "## Blockers and genuine decisions"
    printf '\n'
    printf '%s\n' "$blk_block"
    printf '\n'
    printf '%s\n' "## Clear safety"
    printf '\n'
    if [ "$clear_safe" = yes ]; then
      printf '%s\n' "CLEAR_SAFE: YES"
    else
      printf '%s\n' "CLEAR_SAFE: NO"
    fi
  } > "$tmp" || { rm -f -- "$tmp"; fail "could not assemble the ChatGPT return"; }
  if ! verify_file "$tmp"; then
    rm -f -- "$tmp"
    fail "assembled return failed count/list QA"
  fi
  atomic_replace "$dest" "$tmp"
  rm -f -- "$tmp"
  printf '%s\n' "$dest"
}

case "${1:-}" in
  write) shift; command_write "$@" ;;
  verify) shift; command_verify "$@" ;;
  -h|--help) usage ;;
  *) usage_error "expected write or verify" ;;
esac
