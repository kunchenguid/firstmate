# shellcheck shell=bash
# Shared Claude seat resolution, used by bin/fm-seat.sh and bin/fm-spawn.sh.
# Usage: . bin/fm-seat-lib.sh   (after FM_ROOT, FM_HOME, and CONFIG are set, and
#        after bin/fm-timeout-lib.sh, which bounds every quota read, and
#        bin/fm-quota-axi-lib.sh, which owns the quota row join)
#
# A "seat" is one Claude account, reached through a Claude Code profile
# directory named by CLAUDE_CONFIG_DIR. Claude Code derives that profile's
# Keychain service name from the directory path itself, so two seats never share
# a credential store and a worker pointed at a seat that was never logged in
# fails with "Not logged in" rather than silently spending the default account.
# docs/claude-seats.md owns the operator procedure and the login steps; this
# library owns only the resolution rules the spawn path and the seat command
# must agree on.
#
# The contract that makes a switch safe is that it changes only what the NEXT
# claude worker gets. A live worker keeps the profile it launched with, because
# that profile is recorded in its own task record at spawn time and every later
# launch for that task reads the RECORD, never this resolution. Moving a running
# worker between accounts would strand its session history, which lives under
# the profile directory, so the recorded value is a correctness requirement and
# not only a billing one.
#
# Five settings, all optional, all one line, all gitignored, and all inherited
# by LOCAL secondmate homes but never by a remote route
# (FM_MACHINE_LOCAL_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh):
#   config/claude-seat            active seat NAME for new claude workers
#   config/claude-seats-root      where seat profile directories live
#   config/claude-seat-threshold  percent LEFT on the ACTIVE seat that trips an
#                                 automatic switch
#   config/claude-seat-destination-min
#                                 percent LEFT a seat must exceed to be a switch
#                                 DESTINATION
#   config/claude-seat-extra-usage
#                                 what to do when no seat has headroom: `stop`
#                                 or `allow <usd>`
# Every percentage counts percent LEFT, the same direction the quota viewer
# reports, so no setting has to be inverted against another. All five are off
# when absent; see the automatic-mode section at the foot of this file.
# A local home declines all five for itself with config/claude-seat-local, so it
# can spend a separate account; bin/fm-config-inherit-lib.sh owns that decline.
# docs/configuration.md "Claude seats" owns their schema.

# The reserved seat name for "the default login", which is the ambient profile
# Claude Code uses with no CLAUDE_CONFIG_DIR set. It is never a directory under
# the seats root, and switching to it clears config/claude-seat.
FM_SEAT_DEFAULT_NAME=default

# fm_seat_root
# Absolute directory holding one subdirectory per named seat. Seats live outside
# the firstmate home on purpose: the account owner logs into a seat once and
# every home on the machine, primary and secondmate alike, reaches the same
# profile. A home that wants its own set overrides the root.
fm_seat_root() {
  local root=
  if [ -f "$CONFIG/claude-seats-root" ]; then
    root=$(sed -n '1p' "$CONFIG/claude-seats-root" 2>/dev/null | tr -d '[:space:]')
  fi
  [ -n "$root" ] || root="${HOME:-}/.claude-seats"
  printf '%s\n' "$root"
}

# fm_seat_name_valid <name>
# Seat names become a single path component under the seats root, so they are
# restricted to a conservative set rather than sanitized after the fact.
fm_seat_name_valid() {
  local name=${1-}
  local LC_ALL=C
  [ -n "$name" ] || return 1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  case "$name" in
    . | .. | *..*) return 1 ;;
  esac
  return 0
}

# fm_seat_dir <name>
# Absolute profile directory for a seat name. The default seat has no directory
# of its own, so it prints nothing and returns 1: callers treat that as "no
# CLAUDE_CONFIG_DIR", which is exactly the ambient default.
fm_seat_dir() {
  local name=${1-} root
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] || return 1
  fm_seat_name_valid "$name" || return 1
  root=$(fm_seat_root)
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$root" "$name"
}

# fm_seat_active [config-dir]
# The configured active seat NAME, or the default seat name when unset. An
# unreadable or malformed value is reported as the default rather than guessed
# at, because the default is the one seat that always exists.
#
# The optional argument reads ANOTHER home's setting through this same
# resolution, which is how the primary reports the seat a local secondmate home
# that declined inherited seats is actually on. It defaults to this home's own
# config dir, so every existing caller is unchanged.
fm_seat_active() {
  local config_dir=${1:-$CONFIG} name=
  if [ -f "$config_dir/claude-seat" ]; then
    name=$(sed -n '1p' "$config_dir/claude-seat" 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$name" ] || ! fm_seat_name_valid "$name"; then
    printf '%s\n' "$FM_SEAT_DEFAULT_NAME"
    return 0
  fi
  printf '%s\n' "$name"
}

# fm_seat_config_dir <name>
# The CLAUDE_CONFIG_DIR a claude worker launched on seat <name> gets, or empty
# for the ambient default. Resolution order, most specific first:
#   1. the named seat's profile directory, when <name> is not the default seat
#   2. firstmate's OWN ambient CLAUDE_CONFIG_DIR, which predates seats and is
#      how a home running under a non-default profile already hands that same
#      store to its workers
#   3. empty - the single-store default, which adds no launch prefix at all
# The login probe and the threshold read resolve through this too, so they
# always inspect the same profile a worker on that seat would spend.
fm_seat_config_dir() {
  local name=${1-} dir
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] && dir=$(fm_seat_dir "$name"); then
    printf '%s\n' "$dir"
    return 0
  fi
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-}"
}

# fm_seat_spawn_config_dir
# The CLAUDE_CONFIG_DIR a NEW claude worker should launch with: the active
# seat's, resolved by fm_seat_config_dir. Only a fresh spawn calls this. A
# relaunch reads the task's recorded value.
fm_seat_spawn_config_dir() {
  fm_seat_config_dir "$(fm_seat_active)"
}

# fm_seat_list
# Every seat name that has a profile directory under the root, one per line, in
# a stable order. The set is read from the filesystem on every call, so nothing
# assumes which seats exist.
#
# The default seat is not listed here: it has no directory, and callers that
# present it add it themselves. A directory literally NAMED "default" is skipped
# for the same reason - that name is reserved for the ambient login, so such a
# directory can never be selected, and listing it would show a seat that every
# switch then refuses.
fm_seat_list() {
  local root entry name
  root=$(fm_seat_root)
  [ -d "$root" ] || return 0
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}
    [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] || continue
    fm_seat_name_valid "$name" || continue
    printf '%s\n' "$name"
  done
}

# fm_seat_logged_in [config-dir]
# Exit 0 when the profile holds usable Claude credentials, 1 when it plainly
# does not, and 2 when the probe could not reach a verdict.
#
# The probe is `quota-axi --provider claude`, run with the profile's own
# CLAUDE_CONFIG_DIR, and a logged-in profile is the one that reports an oauth
# source. It deliberately does NOT use --profile-only: that flag reads only a
# credential FILE and never the Keychain, and on macOS a logged-in profile keeps
# its credentials in the Keychain, so --profile-only reports "credentials
# missing" for a perfectly good seat. --no-credential-refresh keeps the read
# from delegating a token renewal to the vendor CLI.
fm_seat_logged_in() {
  local dir=${1-} out
  command -v quota-axi >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  # quota-axi exits non-zero when the provider is unavailable but still prints
  # the report that SAYS so, and that report is exactly the "not logged in"
  # verdict this probe needs. So the exit status is deliberately ignored and the
  # decision comes from the document; only unreadable or invalid output is
  # undecided.
  out=$(fm_seat_quota_read "$dir") || return 2
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 2
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .source == "oauth"
  ' >/dev/null 2>&1 && return 0
  # Tell a clean "not logged in" apart from a probe that could not decide, so a
  # switch refuses on the first and reports uncertainty on the second. Only a
  # report where every credential source was actually consulted and came back
  # empty proves the profile holds no login.
  #
  # `keychain_unreachable` is NOT such a report: it says the store could not be
  # read, not that it is empty. Measured read-only against the installed
  # quota-axi on macOS, a profile that was never logged into and a profile that
  # IS signed in but whose one-time Keychain approval has not been granted yet
  # produce the same shape - every source skipped, the keychain unreachable. So
  # that shape cannot distinguish them and must stay undecided; treating it as
  # proof of absence would refuse a correctly signed-in seat with no way
  # through, exactly the state an owner is in moments after logging a seat in.
  # A signed-in seat whose quota endpoint is rate limited is also "unavailable",
  # and stays undecided for the same reason: its keychain attempt got past the
  # lookup and failed afterwards.
  #
  # An undecided read (2) is what `switch --force` may cross, and crossing it is
  # safe: a forced switch to a genuinely empty seat stops the next worker on its
  # first message with "Not logged in" rather than spending another account.
  # A proven-empty read (1) is never crossable. On a file-backed credential
  # store, where an empty profile really can be read and found empty, 1 remains
  # reachable; on macOS it correctly is not.
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .source == "unavailable"
      and ((.attempts // []) | length > 0
        and all(.status == "skipped" and .error == "credentials_missing"))
  ' >/dev/null 2>&1 && return 1
  return 2
}

# fm_seat_account [config-dir]
# The account email a profile is logged in as, when the probe can read one.
# Identity only; no token or credential content is ever read or printed.
fm_seat_account() {
  local dir=${1-} out
  command -v quota-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(fm_seat_quota_read "$dir") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -er '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .account.email // empty
  ' 2>/dev/null
}

# fm_seat_threshold
# The percent LEFT on the ACTIVE seat that trips an automatic switch, or empty
# when unset. Empty means no automatic switching at all: there is deliberately
# no default that would move accounts on a home that never asked for it.
# fm_seat_percent_file, in the automatic-mode section below, owns the parse.
fm_seat_threshold() {
  fm_seat_percent_file "$CONFIG/claude-seat-threshold"
}

# --- automatic mode -----------------------------------------------------------
# Readers and predicates for the three settings the file header lists: the
# TRIGGER on the active seat, the DESTINATION HEADROOM a candidate must exceed,
# and the EXTRA-USAGE POLICY for when neither can be satisfied.

# fm_seat_percent_file <path>
# The shared reader for a one-line percent setting: prints a percentage strictly
# above 0 and at most 100, or returns 1 for absent, empty, or malformed. A
# malformed value is never rounded into a usable number, because a setting that
# silently became something else is worse than one that reads as unset.
fm_seat_percent_file() {
  local path=${1-} v=
  [ -f "$path" ] || return 1
  v=$(sed -n '1p' "$path" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] || return 1
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg v "$v" '($v | tonumber) > 0 and ($v | tonumber) <= 100' >/dev/null 2>&1 || return 1
  printf '%s\n' "$v"
}

# fm_seat_destination_min
# The minimum percent LEFT a seat must have to be a switch DESTINATION, or
# empty when unset. Unset means the rotation gate is login-only, exactly as it
# was before this setting existed: any logged-in seat qualifies and no
# candidate's quota is read at all.
fm_seat_destination_min() {
  fm_seat_percent_file "$CONFIG/claude-seat-destination-min"
}

# fm_seat_extra_usage_policy
# The policy for when no seat has headroom, as one line: `stop`, or
# `allow <usd>`. Returns 1 when unset, which means no dispatch hold of any kind
# - the fleet keeps launching Claude workers exactly as it does today.
#
# `stop` holds NEW Claude dispatch rather than starting workers that would run
# on paid extra usage. `allow <usd>` keeps dispatching while the seat's recorded
# extra-usage spend is below that dollar figure and holds once it is not.
fm_seat_extra_usage_policy() {
  local path="$CONFIG/claude-seat-extra-usage" v='' amount=''
  [ -f "$path" ] || return 1
  v=$(sed -n '1p' "$path" 2>/dev/null)
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  [ -n "$v" ] || return 1
  local LC_ALL=C
  case "$v" in
    stop)
      printf 'stop\n'
      return 0
      ;;
    allow\ *)
      amount=${v#allow }
      amount=${amount#"${amount%%[![:space:]]*}"}
      [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
      printf 'allow %s\n' "$amount"
      return 0
      ;;
  esac
  return 1
}

# fm_seat_read_bound
# Seconds one quota read may take: 10, or less when FM_SEAT_READ_DEADLINE (an
# epoch second) is set and closer than that. Returns 1 when the deadline leaves
# no whole second, so the read is not made at all. bin/fm-seat.sh auto sets the
# deadline from the watcher's per-check budget, so every read one pass makes,
# including those of a switch it runs as a child, fits inside that budget.
fm_seat_read_bound() {
  local bound=10 deadline=${FM_SEAT_READ_DEADLINE:-} left
  case "$deadline" in
    '') ;;
    *[!0-9]*) return 1 ;;
    *)
      left=$((deadline - $(date +%s)))
      [ "$left" -ge "$bound" ] || bound=$left
      ;;
  esac
  [ "$bound" -ge 1 ] || return 1
  printf '%s\n' "$bound"
}

# fm_seat_quota_read <config-dir>
# The one bounded quota-axi call every seat probe and quota read makes, printed
# raw. Returns 1 when quota-axi is missing, no time is left, or the bound was
# hit, which every caller treats as no verdict.
#
# The exit status of quota-axi is otherwise deliberately ignored: an unavailable
# provider still prints the report that says so, and that report is what
# decides.
fm_seat_quota_read() {
  local dir=${1-} bound out
  command -v quota-axi >/dev/null 2>&1 || return 1
  bound=$(fm_seat_read_bound) || return 1
  out=$(fm_run_timed "$bound" env CLAUDE_CONFIG_DIR="$dir" \
    quota-axi --provider claude --no-credential-refresh --full --json 2>/dev/null </dev/null)
  ! fm_timed_out "$?" || return 1
  printf '%s\n' "$out"
}

# fm_seat_quota_json <config-dir>
# One quota-axi read against a seat's own profile, printed raw. Returns 1 when
# the read could not be made, ran out of time, or did not parse, which every
# caller must treat as "no verdict" rather than as any particular number.
fm_seat_quota_json() {
  local dir=${1-} out
  command -v jq >/dev/null 2>&1 || return 1
  out=$(fm_seat_quota_read "$dir") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# fm_seat_remaining_from <quota-json>
# The tightest percent LEFT across a seat's ACCOUNT-level scopes
# (all_models/all_products), read through the same quota_effective the dispatch
# chooser uses, so there is one owner of which windows bound a worker with no
# specific model. A model- or product-only window does not count: it constrains
# only workers on that model.
#
# An exhausted runway prints 0, because a seat with no runway left has no
# headroom whatever its percentage says. Anything else unreadable returns 1, so
# an ambiguous quota can never be mistaken for a number.
fm_seat_remaining_from() {
  local out=${1-} remaining
  [ -n "$out" ] || return 1
  remaining=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_effective(quota_row(.; "claude"; ""); "default")
    | if (.runway.status // "") == "exhausted_now" then "0"
      elif .status == "known" and (.effectivePercentRemaining | type) == "number"
      then (.effectivePercentRemaining | tostring)
      else "error"
      end
  ' 2>/dev/null) || return 1
  [ -n "$remaining" ] && [ "$remaining" != error ] || return 1
  printf '%s\n' "$remaining"
}

# fm_seat_remaining <config-dir>
# Percent LEFT for one seat's profile, or 1 when the quota gave no verdict.
fm_seat_remaining() {
  local out
  out=$(fm_seat_quota_json "${1-}") || return 1
  fm_seat_remaining_from "$out"
}

# fm_seat_extra_spent_from <quota-json>
# Dollars already spent on paid extra usage for this seat, read from the
# `extra_usage` window quota-axi reports (kind `credits`, carrying spentUsd and
# limitUsd). Returns 1 when the account returns no such window or its spend is
# not a number; a seat with no extra-usage window has no observable spend, which
# is not the same as a spend of zero and must not be reported as one.
fm_seat_extra_spent_from() {
  local out=${1-} spent
  [ -n "$out" ] || return 1
  spent=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then "error" else
        (($row.windows // []) | map(select(.id == "extra_usage")) | first) as $w
        | if ($w // null) == null or ($w.spentUsd | type) != "number"
          then "error" else ($w.spentUsd | tostring) end
      end
  ' 2>/dev/null) || return 1
  [ -n "$spent" ] && [ "$spent" != error ] || return 1
  printf '%s\n' "$spent"
}

# fm_seat_extra_limit_from <quota-json>
# The account's own extra-usage ceiling in dollars, for reporting only. The
# firstmate-side cap is a separate, smaller figure this fleet enforces itself.
fm_seat_extra_limit_from() {
  local out=${1-} limit
  [ -n "$out" ] || return 1
  limit=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then "error" else
        (($row.windows // []) | map(select(.id == "extra_usage")) | first) as $w
        | if ($w // null) == null or ($w.limitUsd | type) != "number"
          then "error" else ($w.limitUsd | tostring) end
      end
  ' 2>/dev/null) || return 1
  [ -n "$limit" ] && [ "$limit" != error ] || return 1
  printf '%s\n' "$limit"
}

# fm_seat_in_extra_usage_from <quota-json>
# Exit 0 when this seat is drawing on paid extra usage right now: its plan quota
# reads as gone AND the account reports extra-usage spend above zero. Both halves
# are required, because an account can carry historical extra-usage spend from an
# earlier window while its current plan quota is perfectly healthy.
fm_seat_in_extra_usage_from() {
  local out=${1-} remaining spent
  remaining=$(fm_seat_remaining_from "$out") || return 1
  jq -en --arg r "$remaining" '($r | tonumber) <= 0' >/dev/null 2>&1 || return 1
  spent=$(fm_seat_extra_spent_from "$out") || return 1
  jq -en --arg s "$spent" '($s | tonumber) > 0' >/dev/null 2>&1
}

# fm_seat_dispatch_decision
# The dispatch gate, printed as one line: `allow <reason>` or `hold <reason>`.
#
# What this can and cannot do is worth being exact about. Firstmate controls
# which seat a NEW worker starts on and whether new Claude work is dispatched at
# all. It cannot stop a worker already running from drawing extra usage
# mid-task; only the organisation's Claude admin setting can do that. So a
# `stop` policy means stop STARTING new work, never a guarantee of zero spend.
#
# With no policy configured this returns `allow policy-unset` without reading
# any quota at all, so an unconfigured home pays nothing for the feature.
fm_seat_dispatch_decision() {
  local policy cap out remaining spent
  policy=$(fm_seat_extra_usage_policy) || { printf 'allow policy-unset\n'; return 0; }
  out=$(fm_seat_quota_json "$(fm_seat_spawn_config_dir)") || {
    printf 'hold quota-unreadable\n'
    return 0
  }
  remaining=$(fm_seat_remaining_from "$out") || {
    printf 'hold quota-unreadable\n'
    return 0
  }
  # Plan quota still left means no extra usage is in play, whatever the policy
  # says: the gate exists to guard paid overflow, not to ration the plan.
  if jq -en --arg r "$remaining" '($r | tonumber) > 0' >/dev/null 2>&1; then
    printf 'allow plan-quota-remaining %s\n' "$remaining"
    return 0
  fi
  case "$policy" in
    stop)
      printf 'hold extra-usage-stop\n'
      return 0
      ;;
  esac
  cap=${policy#allow }
  spent=$(fm_seat_extra_spent_from "$out") || {
    printf 'hold extra-usage-spend-unreadable %s\n' "$cap"
    return 0
  }
  if jq -en --arg s "$spent" --arg c "$cap" '($s | tonumber) < ($c | tonumber)' >/dev/null 2>&1; then
    printf 'allow extra-usage-under-cap %s %s\n' "$spent" "$cap"
    return 0
  fi
  printf 'hold extra-usage-cap %s %s\n' "$spent" "$cap"
}

# fm_seat_dispatch_reason <decision-line>
# The operator-facing reason for one fm_seat_dispatch_decision line, the single
# place its wording lives. Exit 0 for an allow and 1 for a hold, so the spawn
# gate and `bin/fm-seat.sh status` both render and branch on the same text.
fm_seat_dispatch_reason() {
  local verb reason a b
  read -r verb reason a b <<< "${1-}"
  if [ "$verb" = allow ]; then
    case "$reason" in
      policy-unset)
        printf 'no extra-usage policy is configured, so no quota is read and nothing holds\n' ;;
      plan-quota-remaining)
        printf 'the active Claude seat still has %s%% of its plan quota left\n' "$a" ;;
      extra-usage-under-cap)
        printf '$%s of extra usage spent on the active Claude seat, under the $%s cap\n' "$a" "$b" ;;
      *)
        printf 'the extra-usage policy allows new Claude dispatch\n' ;;
    esac
    return 0
  fi
  case "$reason" in
    quota-unreadable)
      printf 'the active Claude seat quota could not be read, so whether this worker would run on paid extra usage is unknown, and the policy makes no guess\n' ;;
    extra-usage-stop)
      printf 'the active Claude seat has no plan quota left and the extra-usage policy is stop, so no new Claude worker is started on paid extra usage\n' ;;
    extra-usage-spend-unreadable)
      printf 'the active Claude seat has no plan quota left and its extra-usage spend could not be read, so it cannot be compared against the $%s cap\n' "$a" ;;
    extra-usage-cap)
      printf '$%s of extra usage is already spent on the active Claude seat, at or over the $%s cap\n' "$a" "$b" ;;
    *)
      printf 'the extra-usage policy holds new Claude dispatch\n' ;;
  esac
  printf 'this holds only work not yet started; a worker already running keeps its own seat and can still draw extra usage mid-task\n'
  return 1
}
