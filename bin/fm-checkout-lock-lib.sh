#!/usr/bin/env bash
# Shared common-Git-directory lock identity and ownership for checkout mutation.
# Usage: source this file, call fm_checkout_lock_prepare <lock-root>, derive the
# lock with fm_checkout_lock_path <checkout> <lock-root>, then use fm_lock_*.
# Use fm_checkout_lock_run <checkout> <lock-root> <command> [args...] when the
# complete checkout mutation can execute inside one shared lock scope, including
# same-process nested calls for the same common Git directory.
# Use fm_checkout_treehouse_return <checkout> <lock-root> <project> for a
# process-tree-bounded `treehouse return --force` under that lock.
# Use fm_checkout_treehouse_return_safe with the expected lease holder for the
# same boundary with a non-forcing `treehouse return`, which refuses rather than
# clean an unexpectedly dirty tree or release somebody else's lease.
# shellcheck disable=SC2016

if [ "${FM_CHECKOUT_LOCK_LIB_LOADED:-0}" = 1 ]; then
  return 0
fi
FM_CHECKOUT_LOCK_LIB_LOADED=1
case "${BASH_SOURCE[0]}" in
  */*) FM_CHECKOUT_LOCK_LIB_SOURCE_DIR=${BASH_SOURCE[0]%/*} ;;
  *) FM_CHECKOUT_LOCK_LIB_SOURCE_DIR=. ;;
esac
FM_CHECKOUT_LOCK_LIB_DIR="$(cd "$FM_CHECKOUT_LOCK_LIB_SOURCE_DIR" && pwd)"
unset FM_CHECKOUT_LOCK_LIB_SOURCE_DIR
FM_CHECKOUT_LOCK_HELPERS_LOADED=0
FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS=64
FM_CHECKOUT_LOCK_FAILURE_STATUS=74
FM_CHECKOUT_LOCK_CONTENTION_STATUS=75
FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS=76
FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS=124
FM_CHECKOUT_TREEHOUSE_RETURN_UNAVAILABLE_STATUS=127
FM_CHECKOUT_SYSTEM_PERL_BIN=
[ ! -x /usr/bin/perl ] || FM_CHECKOUT_SYSTEM_PERL_BIN=/usr/bin/perl
[ -n "$FM_CHECKOUT_SYSTEM_PERL_BIN" ] || [ ! -x /bin/perl ] || FM_CHECKOUT_SYSTEM_PERL_BIN=/bin/perl
[ "${FM_CHECKOUT_TEST_DISABLE_SYSTEM_PERL:-0}" != 1 ] || FM_CHECKOUT_SYSTEM_PERL_BIN=
# shellcheck source=bin/fm-process-tree-lib.sh
. "$FM_CHECKOUT_LOCK_LIB_DIR/fm-process-tree-lib.sh"

fm_checkout_system_perl() {
  [ -n "$FM_CHECKOUT_SYSTEM_PERL_BIN" ] || return 127
  PERL5OPT='' PERL5LIB='' PERLLIB='' \
    DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' LD_PRELOAD='' \
    LD_LIBRARY_PATH='' LD_AUDIT='' LD_DEBUG='' GCONV_PATH='' \
    BASH_ENV='' ENV='' \
    "$FM_CHECKOUT_SYSTEM_PERL_BIN" "$@"
}

fm_checkout_lock_root() {
  local state_base=$1
  if [ -n "${FM_CHECKOUT_REFRESH_LOCK_ROOT:-}" ]; then
    printf '%s\n' "$FM_CHECKOUT_REFRESH_LOCK_ROOT"
  elif [ -n "${FM_CHECKOUT_REFRESH_STATE_ROOT:-}" ]; then
    printf '%s/locks\n' "$FM_CHECKOUT_REFRESH_STATE_ROOT"
  else
    printf '%s/locks\n' "$state_base"
  fi
}

fm_checkout_canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_checkout_lexical_path() {
  local candidate=$1 allow_missing=${2:-0}
  fm_checkout_system_perl -MCwd=getcwd -MErrno=ENOENT -MFile::Spec -e '
    my ($raw, $allow_missing) = @ARGV;
    exit 1 if !defined($raw) || $raw eq q{} || $raw =~ /[\0\r\n]/;
    my @stack;
    if (!File::Spec->file_name_is_absolute($raw)) {
      my $cwd = getcwd();
      exit 1 if !defined($cwd) || $cwd !~ m{^/};
      @stack = grep { $_ ne q{} } split m{/+}, $cwd;
    }
    my $missing = 0;
    for my $component (split m{/+}, $raw) {
      next if $component eq q{} || $component eq q{.};
      if ($component eq q{..}) {
        pop @stack if @stack;
      } else {
        push @stack, $component;
      }
      my $current = q{/} . join q{/}, @stack;
      if (lstat($current)) {
        exit 1 if -l _;
        $missing = 0;
      } elsif ($! == ENOENT) {
        $missing = 1;
      } else {
        exit 1;
      }
    }
    exit 1 if $missing && $allow_missing ne q{1};
    print q{/} . join(q{/}, @stack) . qq{\n};
  ' "$candidate" "$allow_missing"
}

fm_checkout_trusted_dir() {
  local candidate=$1 lexical physical
  lexical=$(fm_checkout_lexical_path "$candidate" 0) || return 1
  [ -d "$lexical" ] || return 1
  physical=$(cd "$lexical" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$lexical" ] || return 1
  printf '%s\n' "$physical"
}

fm_checkout_git_common_dir() {
  fm_checkout_validate_git_metadata "$1"
}

fm_checkout_validate_git_metadata() {
  local checkout=$1 root metadata absolute_git common top listed line listed_root found=0
  root=$(fm_checkout_trusted_dir "$checkout") || return 1
  metadata="$root/.git"
  [ -e "$metadata" ] && [ ! -L "$metadata" ] || return 1
  absolute_git=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  absolute_git=$(fm_checkout_trusted_dir "$absolute_git") || return 1
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  common=$(fm_checkout_trusted_dir "$common") || return 1
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(fm_checkout_trusted_dir "$top") || return 1
  [ "$top" = "$root" ] || return 1
  if [ -d "$metadata" ]; then
    [ "$(fm_checkout_trusted_dir "$metadata")" = "$absolute_git" ] || return 1
    [ "$absolute_git" = "$common" ] || return 1
  elif [ -f "$metadata" ]; then
    if [ "$absolute_git" != "$common" ]; then
      case "$absolute_git" in "$common"/worktrees/*) ;; *) return 1 ;; esac
    fi
  else
    return 1
  fi
  listed=$(git -C "$root" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        listed_root=$(fm_checkout_trusted_dir "${line#worktree }" 2>/dev/null) || return 1
        if [ "$listed_root" = "$root" ]; then
          found=$((found + 1))
        elif [ -f "$metadata" ] && [ "$absolute_git" = "$common" ] \
          && [ "$listed_root" = "$common" ]; then
          # An absorbed submodule's worktree listing identifies its common
          # Git directory rather than the checked-out root. The exact
          # show-toplevel proof above binds that Git directory back to root.
          found=$((found + 1))
        fi
        ;;
    esac
  done <<EOF
$listed
EOF
  [ "$found" -eq 1 ] || return 1
  printf '%s\n' "$common"
}

fm_checkout_hash_value() {
  local value=$1 length=${2:-64} hash
  case "$length" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$length" -le 64 ] || return 1
  hash=$(fm_checkout_system_perl -MDigest::SHA=sha256_hex -e '
    my ($value, $length) = @ARGV;
    exit 1 if !defined($value) || !defined($length) || $value =~ /[\0\r\n]/;
    print substr(sha256_hex($value), 0, $length);
  ' "$value" "$length") || return 1
  [ "${#hash}" -eq "$length" ] || return 1
  case "$hash" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$hash"
}

fm_checkout_hash_file() {
  local path=$1 hash
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  hash=$(fm_checkout_system_perl -MDigest::SHA -e '
    my $path = shift;
    open my $fh, q{<}, $path or exit 1;
    binmode $fh;
    my $sha = Digest::SHA->new(256);
    $sha->addfile($fh);
    print $sha->hexdigest;
  ' "$path") || return 1
  [ "${#hash}" -eq 64 ] || return 1
  case "$hash" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$hash"
}

fm_checkout_stable_path_key() {
  local path=$1 expected_type=${2:-any} allow_missing=${3:-0} length=${4:-24}
  local lexical identity
  lexical=$(fm_checkout_lexical_path "$path" "$allow_missing") || return 1
  identity=$(fm_checkout_system_perl -MErrno=ENOENT -e '
    my ($path, $expected, $allow_missing) = @ARGV;
    if (lstat($path)) {
      exit 1 if -l _;
      exit 1 if $expected eq q{directory} && !-d _;
      exit 1 if $expected eq q{file} && !-f _;
    } else {
      exit 1 if $! != ENOENT || $allow_missing ne q{1};
    }
    print lc($path);
  ' "$lexical" "$expected_type" "$allow_missing") || return 1
  fm_checkout_hash_value "$identity" "$length"
}

fm_checkout_physical_path_identity() {
  local path=$1 expected_type=${2:-any} lexical identity
  lexical=$(fm_checkout_lexical_path "$path" 0) || return 1
  identity=$(fm_checkout_system_perl -e '
    my ($path, $expected) = @ARGV;
    lstat($path) or exit 1;
    exit 1 if -l _;
    exit 1 if $expected eq q{directory} && !-d _;
    exit 1 if $expected eq q{file} && !-f _;
    my @s = stat(_);
    exit 1 if !@s;
    my $kind = -d _ ? q{directory} : -f _ ? q{file} : q{other};
    print join(q{:}, $kind, $s[0], $s[1]);
  ' "$lexical" "$expected_type") || return 1
  [ -n "$identity" ] || return 1
  case "$identity" in *[!A-Za-z0-9:._-]*) return 1 ;; esac
  printf '%s\n' "$identity"
}

fm_checkout_physical_path_key() {
  local identity
  identity=$(fm_checkout_physical_path_identity "$1" "${2:-any}") || return 1
  fm_checkout_hash_value "existing:$identity" "${3:-24}"
}

fm_checkout_tree_boundary_token() {
  local path=$1
  fm_checkout_system_perl -MDigest::SHA=sha256_hex -MErrno=ENOENT -MFcntl=:mode -MFile::Find -e '
    my $root = shift;
    exit 1 if !defined($root) || $root !~ m{^/} || $root eq q{/};
    my @root_stat = lstat($root);
    exit 1 if !@root_stat || S_ISLNK($root_stat[2]) || !S_ISDIR($root_stat[2]);
    (my $parent = $root) =~ s{/[^/]+$}{};
    $parent = q{/} if $parent eq q{};
    my @parent_stat = stat($parent);
    exit 1 if !@parent_stat || $root_stat[0] != $parent_stat[0];
    my @records;
    find(
      {
        no_chdir => 1,
        preprocess => sub { sort @_ },
        wanted => sub {
          my @metadata = lstat($File::Find::name);
          exit 1 if !@metadata;
          exit 1 if $metadata[0] != $root_stat[0];
          exit 1 if S_ISLNK($metadata[2]);
          push @records, join(
            qq{\0},
            $File::Find::name,
            $metadata[0],
            $metadata[1],
            S_IFMT($metadata[2]),
          );
        },
      },
      $root,
    );
    print sha256_hex(join(qq{\0}, @records));
  ' "$path"
}

fm_checkout_lock_key() {
  fm_checkout_stable_path_key "$1" directory 0 24
}

fm_checkout_lock_path() {
  local checkout=$1 lock_root=$2 common key
  common=$(fm_checkout_git_common_dir "$checkout") || return 1
  key=$(fm_checkout_lock_key "$common") || return 1
  [ "${#key}" -eq 24 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s/%s.lock\n' "$lock_root" "$key"
}

fm_checkout_lock_prepare() {
  local lock_root=$1 caller_root caller_home
  mkdir -p "$lock_root" || return 1
  [ -d "$lock_root" ] && [ ! -L "$lock_root" ] || return 1
  if [ "$FM_CHECKOUT_LOCK_HELPERS_LOADED" -eq 0 ]; then
    caller_root=${FM_ROOT:-$(cd "$FM_CHECKOUT_LOCK_LIB_DIR/.." && pwd)}
    caller_home=${FM_HOME:-$caller_root}
    # shellcheck disable=SC2034
    local FM_ROOT="$caller_root" FM_HOME="$caller_home"
    # shellcheck disable=SC2034
    local FM_STATE_OVERRIDE="$lock_root" STATE='' FM_WAKE_LIB_DIR='' FM_WAKE_DEFAULT_ROOT=''
    # shellcheck disable=SC2034
    local FM_WAKE_QUEUE='' FM_WAKE_QUEUE_LOCK=''
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_CHECKOUT_LOCK_LIB_DIR/fm-wake-lib.sh" || return 1
    FM_CHECKOUT_LOCK_HELPERS_LOADED=1
  fi
}

fm_checkout_lock_active_scope_owns() {
  local checkout_lock=$1 ownerdir owner_pid
  [ "${FM_CHECKOUT_LOCK_ACTIVE_PATH:-}" = "$checkout_lock" ] || return 1
  [ -n "${FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR:-}" ] || return 1
  [ -n "${FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID:-}" ] || return 1
  [ -L "$checkout_lock" ] || return 1
  ownerdir=$(fm_lock_link_owner "$checkout_lock" 2>/dev/null) || return 1
  [ "$ownerdir" = "$FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR" ] || return 1
  owner_pid=$(cat "$ownerdir/pid" 2>/dev/null) || return 1
  [ "$owner_pid" = "$FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID" ] || return 1
  fm_pid_alive "$owner_pid" || return 1
  fm_lock_points_to_owner "$checkout_lock" "$ownerdir"
}

fm_checkout_lock_run() {
  local checkout=$1 lock_root=$2 checkout_lock
  shift 2
  fm_checkout_lock_prepare "$lock_root" || {
    echo "error: cannot prepare shared checkout mutation lock at $lock_root" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  }
  checkout_lock=$(fm_checkout_lock_path "$checkout" "$lock_root") || {
    echo "error: cannot resolve shared checkout mutation lock identity for $checkout" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  }
  if fm_checkout_lock_active_scope_owns "$checkout_lock"; then
    "$@"
    return
  fi
  (
    if ! fm_lock_try_acquire "$checkout_lock"; then
      echo "error: checkout mutation already running for $checkout (pid ${FM_LOCK_HELD_PID:-unknown})" >&2
      return "$FM_CHECKOUT_LOCK_CONTENTION_STATUS"
    fi
    local FM_CHECKOUT_LOCK_ACTIVE_PATH="$checkout_lock"
    local FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR="${FM_LOCK_OWNER_DIR:-}"
    local FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID="${BASHPID:-$$}"
    local FM_PROCESS_TREE_GUARD_FILE="$FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR/process-group"
    export FM_PROCESS_TREE_GUARD_FILE
    trap 'fm_lock_release "$checkout_lock"' EXIT
    "$@"
  )
}

fm_checkout_treehouse_return_locked() {
  local checkout=$1 lock_root=$2 project=$3 mode=${4:---force}
  local checkout_lock timeout status previous_dir cleanup_status
  case "$mode" in
    --force|--safe) ;;
    *)
      echo "error: invalid Treehouse return mode: $mode" >&2
      return "$FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS"
      ;;
  esac
  checkout_lock=$(fm_checkout_lock_path "$checkout" "$lock_root") || {
    echo "error: cannot resolve shared checkout mutation lock identity for $checkout" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  }
  if ! fm_checkout_lock_active_scope_owns "$checkout_lock"; then
    echo "error: refusing unlocked Treehouse return for $checkout" >&2
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  fi
  timeout=${FM_TREEHOUSE_RETURN_TIMEOUT:-60}
  case "$timeout" in
    ''|*[!0-9]*|0)
      echo "error: FM_TREEHOUSE_RETURN_TIMEOUT must be a positive integer" >&2
      return "$FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS"
      ;;
  esac
  previous_dir=$(pwd -P) || return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  cd "$project" || return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  if fm_run_bounded "$timeout" python3 -c '
import os
import stat
import sys

target = os.path.abspath(sys.argv[1])
project = os.path.abspath(sys.argv[2])
mode = sys.argv[3]
if mode not in ("--force", "--safe"):
    raise SystemExit(64)
if not target or target == os.path.sep or os.path.realpath(os.getcwd()) != project:
    raise SystemExit(74)
current = os.path.sep
for component in target.split(os.path.sep):
    if not component:
        continue
    current = os.path.join(current, component)
    metadata = os.lstat(current)
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(74)
metadata = os.lstat(target)
if not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit(74)
flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(target, flags)
opened = os.fstat(descriptor)
if (metadata.st_dev, metadata.st_ino) != (opened.st_dev, opened.st_ino):
    raise SystemExit(74)
parent = os.path.dirname(target)
parent_metadata = os.stat(parent)
if opened.st_dev != parent_metadata.st_dev or os.path.ismount(target):
    raise SystemExit(74)
root_device = opened.st_dev
pending = [([], target)]
while pending:
    chain, path = pending.pop()
    directory_fd = os.dup(descriptor)
    try:
        for component, expected_identity in chain:
            child = os.open(component, flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = child
            opened_child = os.fstat(directory_fd)
            if (
                (opened_child.st_dev, opened_child.st_ino) != expected_identity
                or opened_child.st_dev != root_device
            ):
                raise SystemExit(74)
        for name in sorted(os.listdir(directory_fd)):
            item = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            # A symlink INSIDE the tree is skipped, never refused and never
            # descended. Refusing outright made this boundary reject any repository
            # whose own committed layout uses symlinks - relvino puts 177 in every
            # worktree (its CLAUDE.md -> AGENTS.md convention and symlinked skills),
            # so no crewmate there could ever be reaped. What this walk exists to prove
            # is that the destructive return cannot ESCAPE the tree, and a symlink
            # entry cannot cause that here: it is inspected with
            # follow_symlinks=False, it is not a directory so it is never queued,
            # and every descent below opens with O_NOFOLLOW and re-proves dev/ino,
            # single-device, and non-mount. The path-component loop above still
            # refuses a symlinked ANCESTOR, which is the real redirection vector.
            if stat.S_ISLNK(item.st_mode) or not stat.S_ISDIR(item.st_mode):
                continue
            child_path = os.path.join(path, name)
            child = os.open(name, flags, dir_fd=directory_fd)
            try:
                child_opened = os.fstat(child)
                child_identity = (child_opened.st_dev, child_opened.st_ino)
                if (
                    (item.st_dev, item.st_ino) != child_identity
                    or child_opened.st_dev != root_device
                    or os.path.ismount(child_path)
                ):
                    raise SystemExit(74)
            finally:
                os.close(child)
            pending.append((chain + [(name, child_identity)], child_path))
    finally:
        os.close(directory_fd)
os.set_inheritable(descriptor, True)
os.environ["FM_TREEHOUSE_RETURN_ROOT_FD"] = str(descriptor)
os.environ["FM_TREEHOUSE_RETURN_BOUNDARY_FDS"] = str(descriptor)
os.environ["FM_TREEHOUSE_RETURN_PROJECT"] = project
os.fchdir(descriptor)
bound = os.stat(".")
if (opened.st_dev, opened.st_ino) != (bound.st_dev, bound.st_ino):
    raise SystemExit(74)
if mode == "--safe":
    null_input = os.open(os.devnull, os.O_RDONLY)
    os.dup2(null_input, 0)
    os.close(null_input)
arguments = ("treehouse", "return", "--force", ".") if mode == "--force" else (
    "treehouse",
    "return",
    ".",
)
os.execvp("treehouse", arguments)
' "$checkout" "$project" "$mode"; then
    status=0
  else
    status=$?
  fi
  cleanup_status=$FM_PROCESS_TREE_CLEANUP_STATUS
  cd "$previous_dir" || return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  if [ "$cleanup_status" != verified ]; then
    echo "error: Treehouse return process cleanup could not be verified for $checkout; retained for inspection under the guarded checkout lock" >&2
    return "$FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS"
  fi
  [ "$status" -ne 0 ] || return 0
  if [ "$status" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS" ]; then
    echo "error: Treehouse return timed out after ${timeout}s for $checkout" >&2
  fi
  return "$status"
}

fm_checkout_treehouse_return() {
  local checkout=$1 lock_root=$2 project=$3
  fm_checkout_lock_run "$checkout" "$lock_root" \
    fm_checkout_treehouse_return_locked "$checkout" "$lock_root" "$project"
}

fm_checkout_treehouse_lease_owned() {
  local checkout=$1 expected_holder=$2 canonical slot pool state
  canonical=$(fm_checkout_trusted_dir "$checkout") || return 1
  slot=$(fm_checkout_trusted_dir "$(dirname "$canonical")") || return 1
  pool=$(fm_checkout_trusted_dir "$(dirname "$slot")") || return 1
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  python3 - "$state" "$canonical" "$expected_holder" <<'PY'
import json
import os
import stat
import sys

state_path, expected_path, expected_holder = sys.argv[1:]
try:
    metadata = os.lstat(state_path)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 1024 * 1024:
        raise OSError("state is not a bounded regular file")
    with open(state_path, encoding="utf-8") as stream:
        state = json.load(stream)
    entries = state.get("worktrees")
    if not isinstance(entries, list) or len(entries) > 256:
        raise ValueError("worktrees is not a bounded array")
    matches = [
        entry
        for entry in entries
        if isinstance(entry, dict)
        and isinstance(entry.get("path"), str)
        and os.path.realpath(entry["path"]) == expected_path
    ]
    if len(matches) != 1:
        raise ValueError("expected exactly one matching worktree entry")
    entry = matches[0]
    if entry.get("destroying") is True:
        raise ValueError("worktree is already being destroyed")
    if entry.get("leased") is not True:
        raise ValueError("worktree is not durably leased")
    if entry.get("lease_holder") != expected_holder:
        raise ValueError("lease holder does not match")
except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
    print(
        f"error: Treehouse lease ownership for {expected_path} is unprovable: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

fm_checkout_treehouse_return_safe_locked() {
  local checkout=$1 lock_root=$2 project=$3 expected_holder=$4
  fm_checkout_treehouse_lease_owned "$checkout" "$expected_holder" \
    || return "$FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS"
  fm_checkout_treehouse_return_locked "$checkout" "$lock_root" "$project" --safe
}

fm_checkout_treehouse_return_safe() {
  local checkout=$1 lock_root=$2 project=$3 expected_holder=$4
  fm_checkout_lock_run "$checkout" "$lock_root" \
    fm_checkout_treehouse_return_safe_locked \
      "$checkout" "$lock_root" "$project" "$expected_holder"
}

fm_checkout_treehouse_return_requires_retention() {
  [ "$1" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_CONFIG_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_LOCK_FAILURE_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_LOCK_CONTENTION_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS" ] \
    || [ "$1" -eq "$FM_CHECKOUT_TREEHOUSE_RETURN_UNAVAILABLE_STATUS" ]
}
