#!/usr/bin/env bash
# fm-chatgpt-return.sh - write a ChatGPT-bound captain-facing return.
#
# The primary firstmate is the sole consolidating writer. Call this BEFORE
# presenting a return that is explicitly intended to be carried back to
# ChatGPT. Do not write routine status updates or every internal message.
# The destination is transient transport, not canonical storage.
#
# A secondmate home always refuses. An FM_CHATGPT_RETURN_PATH that resolves
# to a different canonical path than the live default is required when
# FM_TASK_ID is set, so a crewmate cannot write the live transport as if it
# were the primary (including via a symlink, "." segment, or relative spelling
# of the same file).
#
# write assembles the return, verifies that enumerated PR counts agree with
# listed items, then atomically replaces the destination.
# verify checks an existing file and writes nothing.
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
#   FM_TASK_ID                 when set, the default live path is refused
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
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

# Unique PR identifiers from a text blob: /pull/N, PR #N, and #N.
collect_pr_ids() {
  printf '%s\n' "$1" \
    | grep -oE '(/pull/[0-9]+|[Pp][Rr][[:space:]]*#[0-9]+|#[0-9]+)' \
    | grep -oE '[0-9]+' \
    | LC_ALL=C sort -u
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
  local claimed=$1 buf=$2 ids id_count
  ids=$(collect_pr_ids "$buf" || true)
  if [ -z "$ids" ]; then
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

# Resolve a path to its canonical absolute form, tolerating missing trailing
# components (like GNU `realpath -m`): symlinks and "." / ".." segments are
# resolved component-by-component against the already-resolved prefix, so a
# symlink, "./" spelling, or "../" spelling of an existing live file still
# canonicalizes to that file's real path even when the leaf itself is absent.
canonical_path() {  # <path> -> resolved absolute path
  perl -e '
    my $path = $ARGV[0];
    $path = "$ENV{PWD}/$path" unless $path =~ m{^/};
    my @parts = split m{/+}, $path;
    my $resolved = "";
    for my $part (@parts) {
      next if $part eq "" || $part eq ".";
      if ($part eq "..") {
        $resolved =~ s{/[^/]*$}{} if $resolved ne "";
        next;
      }
      my $candidate = "$resolved/$part";
      if (-e $candidate || -l $candidate) {
        require Cwd;
        my $rp = Cwd::realpath($candidate);
        $resolved = defined $rp ? $rp : $candidate;
      } else {
        $resolved = $candidate;
      }
    }
    print(($resolved eq "" ? "/" : $resolved), "\n");
  ' "$1" 2>/dev/null
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
  local dest_canonical default_canonical
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
  dest=${FM_CHATGPT_RETURN_PATH:-$DEFAULT_RETURN_PATH}
  if [ -n "${FM_TASK_ID:-}" ]; then
    dest_canonical=$(canonical_path "$dest") || dest_canonical=$dest
    default_canonical=$(canonical_path "$DEFAULT_RETURN_PATH") || default_canonical=$DEFAULT_RETURN_PATH
    if [ "$dest_canonical" = "$default_canonical" ]; then
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
