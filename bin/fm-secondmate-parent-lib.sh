#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Parse the durable parent binding written into a seeded secondmate home.
#
# The fm-secondmate-parent.v1 record contains exactly one schema and route.
# A local route contains exactly one absolute parent_home and no parent_host.
# A remote route contains no parent_home; current provisioning includes its SSH
# alias as diagnostic-only parent_host, while legacy-compatible manifests may
# omit that field.
# Unknown fields are reserved for forward-compatible additions.
# Duplicate schema or route fields, a malformed local binding, an unsupported
# route or schema, a NUL-bearing record, and a symlinked record fail closed.
# Writers publish this record before .fm-secondmate-home so that the identity
# marker remains the seed-completion point.

fm_secondmate_parent_record_parse() {
  local file=$1 line schema='' route='' parent_home='' parent_host=''
  local schema_count=0 route_count=0 parent_home_count=0 parent_host_count=0

  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # bash's read drops NUL bytes, and different bash generations disagree on the
  # result (3.2 truncates the value at the NUL, 5.x splices the surrounding
  # bytes together), so a NUL-bearing parent_home can resolve to a home the
  # record's bytes never name contiguously. Reject the whole record as corrupt
  # before any field parsing instead of letting the interpreter pick a home.
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        schema_count=$((schema_count + 1))
        schema=${line#schema=}
        ;;
      route=*)
        route_count=$((route_count + 1))
        route=${line#route=}
        ;;
      parent_home=*)
        parent_home_count=$((parent_home_count + 1))
        parent_home=${line#parent_home=}
        ;;
      parent_host=*)
        parent_host_count=$((parent_host_count + 1))
        parent_host=${line#parent_host=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ "$parent_host_count" -eq 0 ] || return 1
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote)
      [ "$parent_home_count" -eq 0 ] || return 1
      ;;
    *) return 1 ;;
  esac

  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}

# --- moving a seeded home between parents -----------------------------------
#
# WHY THIS EXISTS. Two primaries can each believe they supervise one secondmate.
# A primary running on the mate's own host can rewrite this record from
# route=remote to route=local naming itself, and from then on every reply the
# mate publishes lands in that primary's state/<id>.status, where the original
# remote parent never looks: its pending-reply expectations sit unanswered while
# both primaries keep steering the same mate. Nothing in the reply path can
# notice, because each side only ever reads its own channel.
#
# The fix has two halves and this library owns the record mechanics of both:
#   - bin/fm-secondmate-takeover.sh is the one command that moves the binding,
#     and it writes through the functions below, whether it writes on this
#     filesystem or through bin/fm-remote-secondmate-control.sh on the mate's
#     host, so both routes produce the same bytes.
#   - the displacement check below is what the boundaries that steer or claim a
#     secondmate (bin/fm-send.sh, bin/fm-spawn.sh, and the host-local leg in
#     bin/fm-remote-secondmate-control.sh) call before acting, so a displaced
#     primary refuses instead of supervising in parallel.
#
# The displaced record is kept beside the live one as
# .fm-secondmate-parent-prior, so moving the mate back is one command and the
# operator can always read which parent was displaced.
# A remote binding carries no parent home by schema, so a remote parent is
# confirmed by its route alone; two distinct remote parents are indistinguishable
# here, which is a documented limit rather than a check this record can make.

FM_SECONDMATE_PARENT_ERROR=

fm_secondmate_parent_path() { printf '%s/.fm-secondmate-parent\n' "$1"; }
fm_secondmate_parent_prior_path() { printf '%s/.fm-secondmate-parent-prior\n' "$1"; }

# A record field occupies one line, so a value carrying a line break would forge
# a second field. A NUL cannot survive a shell variable, and the parser above
# rejects a NUL-bearing file outright, so line framing is all this has to guard.
_fm_secondmate_parent_field_safe() { # <value>
  case ${1-} in *$'\n'*|*$'\r'*) return 1 ;; esac
}

# The real path of <path>, or <path> unchanged when it cannot be resolved, so a
# parent home that has since been removed still compares as its recorded string.
_fm_secondmate_parent_realpath() { # <path>
  local resolved
  if resolved=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) && [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
  else
    printf '%s\n' "$1"
  fi
}

# The exact record bytes for one route: the single owner of this format, used by
# every writer (bin/fm-home-seed.sh, bin/fm-remote-home-provision.sh, and the
# rebind below) so no two of them can drift.
fm_secondmate_parent_record_render() { # <route> [parent_home] [parent_host]
  local route=$1 parent_home=${2-} parent_host=${3-}
  _fm_secondmate_parent_field_safe "$parent_home" || return 1
  _fm_secondmate_parent_field_safe "$parent_host" || return 1
  case "$route" in
    local)
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      [ -z "$parent_host" ] || return 1
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=local\n'
      printf 'parent_home=%s\n' "$parent_home"
      ;;
    remote)
      [ -z "$parent_home" ] || return 1
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=remote\n'
      [ -z "$parent_host" ] || printf 'parent_host=%s\n' "$parent_host"
      ;;
    *) return 1 ;;
  esac
}

# Install a new parent binding in <home>, keeping the displaced one.
# A live record that exists must be parsable before it is displaced: a symlinked,
# NUL-bearing, or malformed record is a corruption to report, never something to
# overwrite and lose. A home with no record at all has no parent to displace, so
# the new binding is simply established and no previous one is saved.
# The displaced record lands first and the new one second, each by rename, so an
# interruption between them leaves the saved copy equal to the still-live record
# - a harmless no-op for a later restore - and never a home with no binding.
# A live record that already names the new parent keeps its saved copy, so a
# repeated or retried claim cannot overwrite the binding to restore; only the
# diagnostic-only parent_host is refreshed.
# Returns 0 on success, 1 with FM_SECONDMATE_PARENT_ERROR set otherwise.
# FM_SECONDMATE_PARENT_DISPLACED is 1 when a different parent's binding was
# saved for restore, and 0 when the new binding displaced nothing.
fm_secondmate_parent_rebind() { # <home> <route> [parent_home] [parent_host]
  local home=$1 route=$2 parent_home=${3-} parent_host=${4-}
  local current prior rendered tmp same_parent=0
  FM_SECONDMATE_PARENT_ERROR=
  FM_SECONDMATE_PARENT_DISPLACED=0
  if [ ! -d "$home" ] || [ -L "$home" ]; then
    FM_SECONDMATE_PARENT_ERROR="secondmate home is unavailable or unsafe: $home"
    return 1
  fi
  current=$(fm_secondmate_parent_path "$home")
  prior=$(fm_secondmate_parent_prior_path "$home")
  if ! rendered=$(fm_secondmate_parent_record_render "$route" "$parent_home" "$parent_host"); then
    FM_SECONDMATE_PARENT_ERROR="refusing to write an unsupported parent binding for $home"
    return 1
  fi
  if [ -e "$current" ] || [ -L "$current" ]; then
    if ! fm_secondmate_parent_record_parse "$current"; then
      FM_SECONDMATE_PARENT_ERROR="the live parent binding is unsafe or malformed: $current"
      return 1
    fi
    if [ "$FM_SECONDMATE_PARENT_ROUTE" = "$route" ] \
      && [ "$(_fm_secondmate_parent_realpath "$FM_SECONDMATE_PARENT_HOME")" = "$(_fm_secondmate_parent_realpath "$parent_home")" ]; then
      same_parent=1
    fi
  fi
  if [ "$same_parent" = 0 ] && { [ -e "$current" ] || [ -L "$current" ]; }; then
    if [ -e "$prior" ] || [ -L "$prior" ]; then
      if [ ! -f "$prior" ] || [ -L "$prior" ]; then
        FM_SECONDMATE_PARENT_ERROR="the saved previous parent binding is unsafe: $prior"
        return 1
      fi
    fi
    tmp="$prior.tmp.$$"
    if ! cat "$current" > "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$prior"; then
      rm -f -- "$tmp"
      FM_SECONDMATE_PARENT_ERROR="could not preserve the displaced parent binding at $prior"
      return 1
    fi
    FM_SECONDMATE_PARENT_DISPLACED=1
  fi
  tmp="$current.tmp.$$"
  if ! printf '%s\n' "$rendered" > "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$current"; then
    rm -f -- "$tmp"
    FM_SECONDMATE_PARENT_ERROR="could not install the new parent binding at $current"
    return 1
  fi
}

# Run <command...> holding <home>'s binding lock, so two primaries on the mate's
# filesystem cannot interleave their save-and-install steps.
# Returns the command's status, or 1 with FM_SECONDMATE_PARENT_ERROR set when
# the lock cannot be taken.
fm_secondmate_parent_locked() { # <home> <command...>
  local lock rc=0
  lock="$1/.fm-secondmate-parent.lock"
  shift
  if ! fm_lock_acquire_wait "$lock"; then
    FM_SECONDMATE_PARENT_ERROR="the parent binding for this secondmate could not be locked at $lock"
    return 1
  fi
  "$@" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}

# Put the saved previous binding back, keeping the one it displaces, so moving a
# secondmate back to its other parent is the same single operation in reverse.
fm_secondmate_parent_restore() { # <home>
  local home=$1 prior route parent_home parent_host
  FM_SECONDMATE_PARENT_ERROR=
  prior=$(fm_secondmate_parent_prior_path "$home")
  if ! fm_secondmate_parent_record_parse "$prior"; then
    FM_SECONDMATE_PARENT_ERROR="there is no usable saved previous parent binding at $prior"
    return 1
  fi
  route=$FM_SECONDMATE_PARENT_ROUTE
  parent_home=$FM_SECONDMATE_PARENT_HOME
  parent_host=$FM_SECONDMATE_PARENT_HOST
  fm_secondmate_parent_rebind "$home" "$route" "$parent_home" "$parent_host"
}

# Does <home>'s live parent binding name the caller as its parent?
# <expect-route> is local for a primary on the mate's own filesystem, which must
# also match <claiming-home>, and remote for a primary reaching the mate over the
# remote transport, which the route alone confirms.
# Returns 0 when it does. Returns 1 otherwise, with FM_SECONDMATE_PARENT_ERROR
# describing the displacement in plain words for the refusing caller to report.
fm_secondmate_parent_binding_names() { # <home> <expect-route> [claiming-home]
  local home=$1 expect=$2 claiming=${3-} record bound_home
  FM_SECONDMATE_PARENT_ERROR=
  record=$(fm_secondmate_parent_path "$home")
  # A home with no record at all names no parent, so there is no displacement to
  # report: homes seeded before this record existed keep working, and the missing
  # record already surfaces on its own through the parent channel, which cannot
  # resolve a destination without it. A record that exists but cannot be trusted
  # is the opposite case and fails closed here.
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    return 0
  fi
  if ! fm_secondmate_parent_record_parse "$record"; then
    FM_SECONDMATE_PARENT_ERROR="secondmate home $home has no usable parent binding: $record is malformed, symlinked, or corrupt"
    return 1
  fi
  case "$expect" in
    local)
      if [ "$FM_SECONDMATE_PARENT_ROUTE" != local ]; then
        FM_SECONDMATE_PARENT_ERROR="secondmate home $home is currently bound to a parent that reaches it over the remote route, not to this home"
        return 1
      fi
      bound_home=$(_fm_secondmate_parent_realpath "$FM_SECONDMATE_PARENT_HOME")
      claiming=$(_fm_secondmate_parent_realpath "$claiming")
      if [ "$bound_home" != "$claiming" ]; then
        FM_SECONDMATE_PARENT_ERROR="secondmate home $home is currently bound to the firstmate home $FM_SECONDMATE_PARENT_HOME, not to this home $claiming"
        return 1
      fi
      ;;
    remote)
      if [ "$FM_SECONDMATE_PARENT_ROUTE" != remote ]; then
        FM_SECONDMATE_PARENT_ERROR="secondmate home $home is currently bound to the firstmate home $FM_SECONDMATE_PARENT_HOME on its own host, not to a parent reaching it over the remote route"
        return 1
      fi
      ;;
    *)
      FM_SECONDMATE_PARENT_ERROR="unsupported expected parent route: $expect"
      return 1
      ;;
  esac
}
