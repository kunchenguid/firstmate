#!/usr/bin/env bash
# fm-dogfood-verify.sh - immutable pinning and on-demand truth verification for
# local installed-app "dogfood" activations.
#
# The failure this guards against: a dogfood activation points a live symlink
# (e.g. ~/Library/Application Support/<App>/ui) at a path INSIDE a shared task
# worktree that other, unrelated tasks keep committing to. The installed app
# then silently starts serving a different commit than the one that was
# activated, with no notification, so a "still active"/overnight-status claim
# becomes false without anyone touching the activation.
#
# This script is project-agnostic. Any local dogfood-activation flow can use it.
#
# Two subcommands:
#
#   pin      Pin an EXACT commit into a dedicated, activation-owned worktree
#            copy that no other task writes to, point the live symlink at that
#            copy (never at a shared worktree), and record a content-hash
#            manifest plus invariants alongside it. Idempotent and reusable: a
#            second pin of the same commit into the same --pin-dir reuses it.
#
#   verify   Revalidate a recorded activation LIVE, right now, and report a
#            clear PASS or a specific named drift. Read-only: it never deletes
#            or mutates anything. Checks the symlink target, the exact HEAD at
#            the pinned copy, content hashes of the served files against the
#            recorded manifest, any recorded invariant files, and (when
#            recorded) that the serving process/port is actually up.
#
# Usage:
#   fm-dogfood-verify.sh pin \
#     --source <repo-or-worktree> --sha <commit-ish> \
#     --pin-dir <dedicated-copy-path> --record <activation-record-dir> \
#     [--serve-subdir <relpath>] [--link <live-symlink-path>] \
#     [--file <served-relpath>]... \
#     [--port <n>] [--process-pattern <pgrep -f pattern>] \
#     [--invariant <label>=<abs-path>]...
#
#   fm-dogfood-verify.sh verify [--skip-serve] <activation-record-dir | pin.env-path>
#
#   fm-dogfood-verify.sh --help
#
# pin writes into <activation-record-dir>: pin.env (metadata), manifest.tsv
# (<sha256><TAB><served-relpath> per line), and invariants.tsv
# (<label><TAB><sha256><TAB><abs-path> per line). verify reads exactly those.
#
# Exit codes: 0 PASS/success, 1 verify drift, 2 usage or precondition error.
set -eu

PROG=fm-dogfood-verify

fail() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

reject_ctrl() {  # <value> <label>
  case "$1" in
    *$'\n'*) fail "$2 must not contain a newline" ;;
    *$'\t'*) fail "$2 must not contain a tab" ;;
  esac
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

abspath() {  # <path>  (parent directory must already exist)
  # Physical (pwd -P) so the containment check below matches git's physical
  # --show-toplevel even when /tmp or a home dir is itself a symlink.
  local p=$1 dir base
  dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || fail "cannot resolve parent directory of: $p"
  base=$(basename "$p")
  case "$base" in
    .|/) printf '%s\n' "$dir" ;;
    *) printf '%s/%s\n' "$dir" "$base" ;;
  esac
}

# canonicalize <path>: print the fully physical path of an EXISTING path,
# following every symlink (including the final component). Portable stand-in for
# `readlink -f` (absent on macOS). Fails on a symlink cycle. Used to contain
# served files under the pinned worktree even when a component or the file
# itself is a symlink pointing elsewhere.
canonicalize() {
  local p=$1 dir base target i=0
  while [ "$i" -lt 64 ]; do
    dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
    base=$(basename "$p")
    case "$base" in
      /|.) printf '%s\n' "$dir"; return 0 ;;
    esac
    p=$dir/$base
    [ -L "$p" ] || { printf '%s\n' "$p"; return 0; }
    target=$(readlink "$p")
    case "$target" in
      /*) p=$target ;;
      *) p=$dir/$target ;;
    esac
    i=$((i+1))
  done
  return 1
}

read_pin_env() {  # <record-path>  -> sets PE_* globals
  local rp=$1 envf line k v
  if [ -d "$rp" ]; then envf=$rp/pin.env; else envf=$rp; fi
  [ -f "$envf" ] || fail "verify: no pin.env at: $rp"
  PE_RECORD_DIR=$(cd "$(dirname "$envf")" && pwd)
  PE_VERSION=''; PE_SHA=''; PE_PIN_DIR=''; PE_SERVED_ROOT=''
  PE_LINK=''; PE_PORT=''; PE_PROC=''
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    case "$k" in
      fm_dogfood_pin_version) PE_VERSION=$v ;;
      sha) PE_SHA=$v ;;
      pin_dir) PE_PIN_DIR=$v ;;
      served_root) PE_SERVED_ROOT=$v ;;
      link) PE_LINK=$v ;;
      serve_port) PE_PORT=$v ;;
      serve_process_pattern) PE_PROC=$v ;;
    esac
  done < "$envf"
  [ "$PE_VERSION" = 1 ] || fail "verify: unsupported pin.env version: '$PE_VERSION'"
  [ -n "$PE_SHA" ] || fail "verify: pin.env missing sha"
  [ -n "$PE_SERVED_ROOT" ] || fail "verify: pin.env missing served_root"
}

# do_verify <record-path> [skip_serve]  -> 0 PASS, 1 drift. Never mutates.
do_verify() {
  local rp=$1 skip_serve=${2:-0}
  read_pin_env "$rp"
  local fails=0 warns=0

  if [ -n "$PE_LINK" ]; then
    if [ ! -L "$PE_LINK" ]; then
      printf 'FAIL symlink-drift: %s is not a symlink\n' "$PE_LINK"; fails=$((fails+1))
    else
      local actual; actual=$(readlink "$PE_LINK")
      if [ "$actual" != "$PE_SERVED_ROOT" ]; then
        printf 'FAIL symlink-drift: %s -> %s (expected %s)\n' "$PE_LINK" "$actual" "$PE_SERVED_ROOT"
        fails=$((fails+1))
      fi
    fi
  fi

  if [ -n "$PE_PIN_DIR" ]; then
    local head; head=$(git -C "$PE_PIN_DIR" rev-parse HEAD 2>/dev/null) || head=''
    if [ -z "$head" ]; then
      printf 'FAIL head-unreadable: cannot read git HEAD at %s\n' "$PE_PIN_DIR"; fails=$((fails+1))
    elif [ "$head" != "$PE_SHA" ]; then
      printf 'FAIL head-drift: %s at %s (expected %s)\n' "$head" "$PE_PIN_DIR" "$PE_SHA"; fails=$((fails+1))
    fi
  fi

  # Live containment re-check. pin proved the served root and every served file
  # resolve PHYSICALLY inside the immutable pinned worktree, but only at
  # activation time. Between then and now a directory component or a served file
  # could have been replaced by a symlink pointing at mutable content OUTSIDE the
  # pin. If verify merely followed the recorded served_root and hashed whatever it
  # landed on, an escape whose current bytes still match the manifest would report
  # PASS while the app serves content that is no longer the pinned commit -
  # exactly the drift this tool exists to catch. So we re-resolve live and name
  # the escape instead of silently trusting the recorded path.
  local pin_real='' served_real=''
  if [ -n "$PE_PIN_DIR" ]; then
    pin_real=$(canonicalize "$PE_PIN_DIR" 2>/dev/null) || pin_real=''
  fi
  if [ -n "$pin_real" ]; then
    served_real=$(canonicalize "$PE_SERVED_ROOT" 2>/dev/null) || served_real=''
    if [ -n "$served_real" ]; then
      case "$served_real" in
        "$pin_real"|"$pin_real"/*) : ;;
        *) printf 'FAIL serve-root-escape: %s now resolves to %s, outside the pin %s\n' \
             "$PE_SERVED_ROOT" "$served_real" "$pin_real"; fails=$((fails+1)) ;;
      esac
    fi
  fi

  local manifest=$PE_RECORD_DIR/manifest.tsv exp rel cur fphys
  if [ ! -f "$manifest" ]; then
    printf 'FAIL manifest-missing: %s\n' "$manifest"; fails=$((fails+1))
  else
    while IFS=$'\t' read -r exp rel; do
      [ -n "$exp" ] || continue
      if [ ! -f "$PE_SERVED_ROOT/$rel" ]; then
        printf 'FAIL content-missing: %s\n' "$rel"; fails=$((fails+1)); continue
      fi
      # Same containment invariant, per served file: a served path that now
      # resolves outside the pin is an escape, not valid content, even if its
      # bytes match. Skip hashing it and name the escape.
      if [ -n "$pin_real" ]; then
        fphys=$(canonicalize "$PE_SERVED_ROOT/$rel" 2>/dev/null) || fphys=''
        if [ -z "$fphys" ]; then
          printf 'FAIL content-missing: %s\n' "$rel"; fails=$((fails+1)); continue
        fi
        case "$fphys" in
          "$pin_real"|"$pin_real"/*) : ;;
          *) printf 'FAIL content-escape: %s now resolves to %s, outside the pin\n' \
               "$rel" "$fphys"; fails=$((fails+1)); continue ;;
        esac
      fi
      cur=$(sha256_file "$PE_SERVED_ROOT/$rel")
      if [ "$cur" != "$exp" ]; then
        printf 'FAIL content-drift: %s\n' "$rel"; fails=$((fails+1))
      fi
    done < "$manifest"
  fi

  local invfile=$PE_RECORD_DIR/invariants.tsv label iexp ipath icur
  if [ -f "$invfile" ]; then
    while IFS=$'\t' read -r label iexp ipath; do
      [ -n "$label" ] || continue
      if [ ! -f "$ipath" ]; then
        printf 'FAIL invariant-missing: %s (%s)\n' "$label" "$ipath"; fails=$((fails+1)); continue
      fi
      icur=$(sha256_file "$ipath")
      if [ "$icur" != "$iexp" ]; then
        printf 'FAIL invariant-drift: %s (%s)\n' "$label" "$ipath"; fails=$((fails+1))
      fi
    done < "$invfile"
  fi

  if [ "$skip_serve" != 1 ]; then
    if [ -n "$PE_PORT" ]; then
      if command -v lsof >/dev/null 2>&1; then
        if ! lsof -nP -iTCP:"$PE_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
          printf 'FAIL serve-port-down: nothing listening on port %s\n' "$PE_PORT"; fails=$((fails+1))
        fi
      else
        printf 'WARN serve-port-uncheckable: lsof not available\n'; warns=$((warns+1))
      fi
    fi
    if [ -n "$PE_PROC" ]; then
      if command -v pgrep >/dev/null 2>&1; then
        if ! pgrep -f -- "$PE_PROC" >/dev/null 2>&1; then
          printf 'FAIL serve-process-down: no process matches %s\n' "$PE_PROC"; fails=$((fails+1))
        fi
      else
        printf 'WARN serve-process-uncheckable: pgrep not available\n'; warns=$((warns+1))
      fi
    fi
  fi

  if [ "$fails" -eq 0 ]; then
    if [ "$warns" -gt 0 ]; then
      printf 'PASS %s sha=%s (with %s warning(s))\n' "$PE_RECORD_DIR" "$PE_SHA" "$warns"
    else
      printf 'PASS %s sha=%s\n' "$PE_RECORD_DIR" "$PE_SHA"
    fi
    return 0
  fi
  printf 'FAILED %s (%s check(s) failed)\n' "$PE_RECORD_DIR" "$fails"
  return 1
}

cmd_pin() {
  local source='' sha='' pin_dir='' record='' serve_subdir='.' link='' port='' proc_pat=''
  local -a files=() invariants=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source=${2:-}; shift 2 ;;
      --sha) sha=${2:-}; shift 2 ;;
      --pin-dir) pin_dir=${2:-}; shift 2 ;;
      --record) record=${2:-}; shift 2 ;;
      --serve-subdir) serve_subdir=${2:-}; shift 2 ;;
      --link) link=${2:-}; shift 2 ;;
      --file) files+=("${2:-}"); shift 2 ;;
      --port) port=${2:-}; shift 2 ;;
      --process-pattern) proc_pat=${2:-}; shift 2 ;;
      --invariant) invariants+=("${2:-}"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "pin: unknown argument: $1" ;;
    esac
  done

  [ -n "$source" ] || fail "pin: --source is required"
  [ -n "$sha" ] || fail "pin: --sha is required"
  [ -n "$pin_dir" ] || fail "pin: --pin-dir is required"
  [ -n "$record" ] || fail "pin: --record is required"
  command -v git >/dev/null 2>&1 || fail "git is required"

  reject_ctrl "$pin_dir" "--pin-dir"
  reject_ctrl "$serve_subdir" "--serve-subdir"
  reject_ctrl "$link" "--link"
  reject_ctrl "$port" "--port"
  reject_ctrl "$proc_pat" "--process-pattern"

  local src_top resolved
  src_top=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) \
    || fail "pin: --source is not a git repository: $source"
  resolved=$(git -C "$source" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null) \
    || fail "pin: cannot resolve commit '$sha' in $source"

  # A dedicated pin copy must live OUTSIDE the shared source worktree, or it is
  # not actually isolated from the tasks that keep committing there.
  mkdir -p "$(dirname "$pin_dir")" || fail "pin: cannot create parent of --pin-dir"
  pin_dir=$(abspath "$pin_dir")
  case "$pin_dir" in
    "$src_top"|"$src_top"/*) fail "pin: --pin-dir is inside the source worktree ($src_top); choose a dedicated path outside it" ;;
  esac

  if [ -e "$pin_dir" ]; then
    local existing
    existing=$(git -C "$pin_dir" rev-parse HEAD 2>/dev/null) \
      || fail "pin: --pin-dir exists but is not a git worktree: $pin_dir"
    [ "$existing" = "$resolved" ] \
      || fail "pin: --pin-dir already pinned at $existing, not $resolved; refusing to clobber"
  else
    git -C "$source" worktree add --detach --quiet "$pin_dir" "$resolved" \
      || fail "pin: git worktree add failed for $resolved -> $pin_dir"
  fi

  local pinned_head
  pinned_head=$(git -C "$pin_dir" rev-parse HEAD 2>/dev/null) || fail "pin: cannot read pinned HEAD"
  [ "$pinned_head" = "$resolved" ] || fail "pin: pinned HEAD $pinned_head != $resolved"

  local served_root
  case "$serve_subdir" in
    .|'') served_root=$pin_dir ;;
    /*) fail "pin: --serve-subdir must be relative" ;;
    *) served_root=$pin_dir/$serve_subdir ;;
  esac
  [ -d "$served_root" ] || fail "pin: served directory does not exist: $served_root"
  # Resolve physically and require containment: a --serve-subdir with parent
  # components (e.g. ../other) must not let the served root escape the pinned
  # worktree, or the app would serve content outside the pinned commit.
  served_root=$(cd "$served_root" && pwd -P) || fail "pin: cannot resolve served directory: $served_root"
  case "$served_root" in
    "$pin_dir"|"$pin_dir"/*) : ;;
    *) fail "pin: --serve-subdir escapes the pinned worktree: $serve_subdir" ;;
  esac

  mkdir -p "$record" || fail "pin: cannot create --record dir: $record"
  record=$(abspath "$record")

  local -a served_files=()
  if [ "${#files[@]}" -gt 0 ]; then
    local f phys
    for f in "${files[@]}"; do
      reject_ctrl "$f" "--file"
      case "$f" in
        /*) fail "pin: --file must be relative to the served root: $f" ;;
      esac
      [ -e "$served_root/$f" ] || fail "pin: --file not found under served root: $f"
      # Contain it PHYSICALLY: a --file with parent components (../x) or a file
      # that is a symlink to content outside the pinned worktree must not let the
      # activation record/serve mutable external data while claiming the pin is
      # intact. verify follows the same relative path, so both must stay inside.
      phys=$(canonicalize "$served_root/$f") \
        || fail "pin: cannot resolve --file: $f"
      case "$phys" in
        "$pin_dir"|"$pin_dir"/*) : ;;
        *) fail "pin: --file escapes the pinned worktree: $f" ;;
      esac
      [ -f "$phys" ] || fail "pin: --file is not a regular file: $f"
      served_files+=("$f")
    done
  else
    local rel phys
    # Enumerate regular files AND symlinks. A plain `-type f` sweep silently omits
    # symlink entries, so a served path that is (or traverses) a symlink pointing
    # at mutable content OUTSIDE the pinned worktree would never reach the manifest
    # - and pin/verify would both report success while the app serves un-pinned,
    # mutable bytes. Contain every entry PHYSICALLY, exactly like the --file branch:
    # an in-pin regular file (or in-pin symlink to one) is covered, an escape is
    # rejected by name rather than dropped.
    while IFS= read -r rel; do
      rel=${rel#./}
      reject_ctrl "$rel" "served file path"
      phys=$(canonicalize "$served_root/$rel") \
        || fail "pin: cannot resolve served file: $rel"
      case "$phys" in
        "$pin_dir"|"$pin_dir"/*) : ;;
        *) fail "pin: served file escapes the pinned worktree: $rel" ;;
      esac
      [ -f "$phys" ] || fail "pin: served entry is not a regular file: $rel"
      served_files+=("$rel")
    done < <(cd "$served_root" && find . -name .git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort)
  fi
  [ "${#served_files[@]}" -gt 0 ] || fail "pin: no served files found under $served_root"

  local manifest=$record/manifest.tsv h
  : > "$manifest"
  local rel2
  for rel2 in "${served_files[@]}"; do
    h=$(sha256_file "$served_root/$rel2")
    printf '%s\t%s\n' "$h" "$rel2" >> "$manifest"
  done

  local invfile=$record/invariants.tsv
  : > "$invfile"
  if [ "${#invariants[@]}" -gt 0 ]; then
    local spec label path
    for spec in "${invariants[@]}"; do
      case "$spec" in
        *=*) label=${spec%%=*}; path=${spec#*=} ;;
        *) fail "pin: --invariant must be <label>=<path>: $spec" ;;
      esac
      reject_ctrl "$label" "invariant label"
      reject_ctrl "$path" "invariant path"
      [ -f "$path" ] || fail "pin: invariant file not found: $path"
      h=$(sha256_file "$path")
      printf '%s\t%s\t%s\n' "$label" "$h" "$path" >> "$invfile"
    done
  fi

  # Point the live symlink at the dedicated copy with an atomic replace. We
  # never clobber a real file/dir, and we record the previous target so the
  # change is reversible.
  local previous='(none)'
  if [ -n "$link" ]; then
    link=$(abspath "$link")
    if [ -L "$link" ]; then
      previous=$(readlink "$link")
    elif [ -e "$link" ]; then
      fail "pin: refusing to replace a non-symlink at --link: $link"
    fi
    local tmp=$link.fmpin.$$
    rm -f "$tmp"
    ln -s "$served_root" "$tmp" || { rm -f "$tmp"; fail "pin: cannot stage symlink at $tmp"; }
    if [ -L "$link" ]; then
      rm -f "$link" || { rm -f "$tmp"; fail "pin: cannot remove existing symlink at $link"; }
    fi
    mv "$tmp" "$link" || { rm -f "$tmp"; fail "pin: cannot install symlink at $link"; }
  fi

  {
    printf 'fm_dogfood_pin_version=1\n'
    printf 'state=active\n'
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_worktree=%s\n' "$src_top"
    printf 'sha=%s\n' "$resolved"
    printf 'pin_dir=%s\n' "$pin_dir"
    printf 'serve_subdir=%s\n' "$serve_subdir"
    printf 'served_root=%s\n' "$served_root"
    printf 'link=%s\n' "$link"
    printf 'previous_link_target=%s\n' "$previous"
    printf 'serve_port=%s\n' "$port"
    printf 'serve_process_pattern=%s\n' "$proc_pat"
  } > "$record/pin.env"

  # Postflight self-check: prove the pin took, structurally. The app is not
  # necessarily launched yet, so skip the serve checks here.
  local vout vrc
  vout=$(do_verify "$record" 1 2>&1) && vrc=0 || vrc=$?
  if [ "$vrc" -ne 0 ]; then
    printf '%s\n' "$vout" >&2
    fail "pin: postflight verification failed"
  fi

  printf 'PINNED %s sha=%s files=%s pin_dir=%s\n' "$record" "$resolved" "${#served_files[@]}" "$pin_dir"
  if [ -n "$link" ]; then
    printf 'LINK %s -> %s (was: %s)\n' "$link" "$served_root" "$previous"
  fi
}

cmd_verify() {
  local skip_serve=0 target=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-serve) skip_serve=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; target=${1:-}; [ $# -gt 0 ] && shift ;;
      -*) fail "verify: unknown option: $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || fail "verify: activation-record path is required"
  if do_verify "$target" "$skip_serve"; then exit 0; else exit 1; fi
}

case "${1:-}" in
  pin) shift; cmd_pin "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
