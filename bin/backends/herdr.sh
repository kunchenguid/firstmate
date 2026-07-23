#!/usr/bin/env bash
# bin/backends/herdr.sh - the herdr session-provider adapter (EXPERIMENTAL).
#
# Design: data/fm-backend-design-d7/herdr-addendum.md ("Interface mapping",
# decisions D1-D6) and the empirical verification recorded in
# data/fm-backend-design-d7/herdr-verification-p2.md (real herdr v0.7.1,
# protocol 14, macOS aarch64), refined by docs/herdr-backend.md's
# "workspace-per-home" pass (AGENTS.md task herdr-sm-spaces-k4). Herdr is a
# session provider ONLY (D3): the worktree provider stays treehouse, exactly
# like tmux. Sourced only through bin/fm-backend.sh's fm_backend_source in
# normal operation; the unit tests source it directly, so the FM_HOME fallback
# below keeps that path sane without fm-backend.sh's preamble.
#
# Container shape (D4, decided empirically - see herdr-verification-p2.md
# "Task container shape", refined by docs/herdr-backend.md "Task container
# shape"): ONE herdr workspace PER FIRSTMATE HOME (the primary, and each
# secondmate, gets its own), ONE herdr TAB per task inside its home's
# workspace. Workspace-per-task was tried and rejected (bad human-watching
# ergonomics); workspace-per-HOME keeps that same rejection while giving every
# home its own space, labeled distinctly, in the shared spaces sidebar. Target
# resolution and the human-watch story stay parallel to the tmux adapter.
#
# Target string shape: "<herdr-session>:<pane-id>", e.g. "default:w1:p2" (the
# pane id itself contains a colon; the session is always the FIRST field, the
# remainder is the whole pane id - fm_backend_herdr_parse_target splits on the
# first colon only). This is the value stored in a herdr task's meta window=
# field and is what fm_backend_resolve_selector already returns unchanged for
# exact task-id, legacy fm-<id>, and explicit backend-target forms (that
# function has no herdr-specific logic; it just returns meta's window=
# verbatim).
#
# Recovery/orphan discovery (ids may not deterministically match live state
# after a server restart in a differently-configured session; see the
# verification doc) uses LABEL matching (fm-<id> tab labels), never trusts a
# stored pane id blindly: fm_backend_herdr_list_live.
#
# Requires: herdr (CLI + socket), jq (JSON parsing), nohup, and perl (portable
# detached setsid server launcher). Bootstrap detects these through
# fm_backend_required_tools only when herdr is the resolved backend; this
# adapter also gates them again before spawning.

# FM_HOME fallback: every real caller (fm-spawn.sh, fm-peek.sh, fm-send.sh,
# fm-teardown.sh, fm-watch.sh, fm-crew-state.sh) already sets FM_HOME as a
# global before sourcing fm-backend.sh (which sources this file), so this
# never overrides a real invocation. It exists only so this file's own unit
# tests, which source it directly without that preamble, resolve to a sane
# default (the firstmate repo root - never a secondmate home, so
# fm_backend_herdr_workspace_label falls through to "firstmate" exactly like
# pre-P3 behavior when a test does not care about home-specific labeling).
FM_BACKEND_HERDR_SOURCE_DIR=${BASH_SOURCE[0]%/*}
[ "$FM_BACKEND_HERDR_SOURCE_DIR" != "${BASH_SOURCE[0]}" ] || FM_BACKEND_HERDR_SOURCE_DIR=.
FM_BACKEND_HERDR_ROOT="$(cd "$FM_BACKEND_HERDR_SOURCE_DIR/../.." && pwd -P)"
unset FM_BACKEND_HERDR_SOURCE_DIR
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_HERDR_CONTROL_PATH=/usr/bin:/bin:/usr/sbin:/sbin
FM_BACKEND_HERDR_ENV_BIN=
[ ! -x /usr/bin/env ] || FM_BACKEND_HERDR_ENV_BIN=/usr/bin/env
[ -n "$FM_BACKEND_HERDR_ENV_BIN" ] || [ ! -x /bin/env ] || FM_BACKEND_HERDR_ENV_BIN=/bin/env
FM_BACKEND_HERDR_PERL_BIN=
[ ! -x /usr/bin/perl ] || FM_BACKEND_HERDR_PERL_BIN=/usr/bin/perl
FM_BACKEND_HERDR_NOHUP_BIN=
[ ! -x /usr/bin/nohup ] || FM_BACKEND_HERDR_NOHUP_BIN=/usr/bin/nohup
[ -n "$FM_BACKEND_HERDR_NOHUP_BIN" ] || [ ! -x /bin/nohup ] || FM_BACKEND_HERDR_NOHUP_BIN=/bin/nohup
FM_BACKEND_HERDR_JQ_BIN=
[ ! -x /usr/bin/jq ] || FM_BACKEND_HERDR_JQ_BIN=/usr/bin/jq
[ -n "$FM_BACKEND_HERDR_JQ_BIN" ] || [ ! -x /bin/jq ] || FM_BACKEND_HERDR_JQ_BIN=/bin/jq
FM_BACKEND_HERDR_HEAD_BIN=
[ ! -x /usr/bin/head ] || FM_BACKEND_HERDR_HEAD_BIN=/usr/bin/head
[ -n "$FM_BACKEND_HERDR_HEAD_BIN" ] || [ ! -x /bin/head ] || FM_BACKEND_HERDR_HEAD_BIN=/bin/head
FM_BACKEND_HERDR_GREP_BIN=
[ ! -x /usr/bin/grep ] || FM_BACKEND_HERDR_GREP_BIN=/usr/bin/grep
[ -n "$FM_BACKEND_HERDR_GREP_BIN" ] || [ ! -x /bin/grep ] || FM_BACKEND_HERDR_GREP_BIN=/bin/grep

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-composer-lib.sh"

# Shared, backend-neutral normalized-transition shape and the single-owner
# status->action policy table (bin/fm-transition-lib.sh). This adapter's event
# subscriber (fm_backend_herdr_wait_transition) normalizes every
# pane.agent_status_changed edge through fm_transition_record and routes it
# through fm_transition_policy - it never re-encodes the mapping.
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-transition-lib.sh"

FM_BACKEND_HERDR_MIN_PROTOCOL=14
# events.subscribe (the native pane.agent_status_changed push stream) and its
# subscription_event schema first shipped at protocol 16 (verified: herdr
# 0.7.3). Below this, or with the events surface absent from `herdr api schema`,
# the event fast-path fails closed to the watcher's poll loop
# (fm_backend_herdr_events_capable). Distinct from FM_BACKEND_HERDR_MIN_PROTOCOL
# (14): the adapter's spawn/capture/send primitives work on 14, only the push
# subscriber needs 16.
FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL=16
# Per-pane escalation dedupe marker prefix, under the state dir. One marker per
# window (keyed like the watcher's own .stale-<key>): set when a ->blocked edge
# is enqueued, cleared on any working edge, so exactly one wake fires per
# ->blocked edge and a reconnect level-reconcile never re-delivers a still-
# blocked pane. Mirrors bin/fm-watch.sh's .stale-<key> naming.
FM_BACKEND_HERDR_ESCALATED_PREFIX=".herdr-escalated-"
# .fm-secondmate-home is written by bin/fm-home-seed.sh (AGENTS.md section 6)
# at a seeded secondmate home's root, containing exactly that secondmate's id.
# The primary firstmate home never carries this marker.
FM_BACKEND_HERDR_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_herdr_test_lab_enabled() {
  [ "${FM_BACKEND_HERDR_TEST_LAB:-}" = firstmate-herdr-test-lab-v1 ]
}

# Perl honors ambient module and dynamic-loader injection variables even when
# invoked by absolute path.  Control-plane Perl runs in a closed environment;
# detached Herdr launch below has its own separately closed runtime envelope.
fm_backend_herdr_control_perl() {
  [ -n "$FM_BACKEND_HERDR_ENV_BIN" ] && [ -n "$FM_BACKEND_HERDR_PERL_BIN" ] || return 127
  "$FM_BACKEND_HERDR_ENV_BIN" -i HOME=/ PATH="$FM_BACKEND_HERDR_CONTROL_PATH" LC_ALL=C \
    "$FM_BACKEND_HERDR_PERL_BIN" "$@"
}

# Absolute paths and a fixed PATH do not neutralize dynamic-loader or language
# runtime injection inherited from the caller.  Every authority-bearing Herdr
# control subprocess runs through this scrubbed envelope.  Keep the ordinary
# environment (HOME, the validated worker PATH, session/test controls) because
# the Herdr CLI and its panes intentionally consume it; remove only executable
# startup hooks that can run code before the requested program reaches main.
fm_backend_herdr_scrubbed_exec() {
  local -x LD_PRELOAD='' LD_LIBRARY_PATH='' LD_AUDIT='' LD_DEBUG=''
  local -x DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' DYLD_FRAMEWORK_PATH=''
  local -x DYLD_FALLBACK_LIBRARY_PATH='' DYLD_FALLBACK_FRAMEWORK_PATH=''
  local -x PERL5OPT='' PERL5LIB='' PERLLIB='' NODE_OPTIONS='' NODE_PATH=''
  local -x PYTHONHOME='' PYTHONPATH='' RUBYOPT='' RUBYLIB='' BASH_ENV='' ENV=''
  local -x GCONV_PATH=''
  "$@"
}

# Resolve ordinary control utilities only from the fixed system PATH, bypassing
# same-name shell functions, then launch the resolved absolute binary through
# the same loader/runtime scrub as Herdr itself. This keeps lock, marker, and
# event-stream authority independent of both caller PATH and injected runtimes.
fm_backend_herdr_control_exec() {
  local name=$1 bin
  shift
  # Two submit-timing regressions install an in-process sleep recorder. Honor
  # that function only behind the adapter's exact lab opt-in; production never
  # accepts shell functions as control-command authority.
  if [ "$name" = sleep ] && fm_backend_herdr_test_lab_enabled \
    && declare -F sleep >/dev/null 2>&1; then
    fm_backend_herdr_scrubbed_exec sleep "$@"
    return
  fi
  bin=$(PATH="$FM_BACKEND_HERDR_CONTROL_PATH" builtin type -P "$name") || return 127
  case "$bin" in
    /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*) ;;
    *) return 127 ;;
  esac
  fm_backend_herdr_scrubbed_exec "$bin" "$@"
}

fm_backend_herdr_control_jq() {
  [ -n "$FM_BACKEND_HERDR_JQ_BIN" ] || return 127
  fm_backend_herdr_scrubbed_exec "$FM_BACKEND_HERDR_JQ_BIN" "$@"
}

fm_backend_herdr_control_head() {
  [ -n "$FM_BACKEND_HERDR_HEAD_BIN" ] || return 127
  fm_backend_herdr_scrubbed_exec "$FM_BACKEND_HERDR_HEAD_BIN" "$@"
}

fm_backend_herdr_control_grep() {
  [ -n "$FM_BACKEND_HERDR_GREP_BIN" ] || return 127
  fm_backend_herdr_scrubbed_exec "$FM_BACKEND_HERDR_GREP_BIN" "$@"
}

# shellcheck disable=SC2016
fm_backend_herdr_passwd_home() {
  fm_backend_herdr_control_perl -e \
    'my @p = getpwuid($<); exit 1 unless @p && defined $p[7] && length $p[7]; print $p[7]'
}

FM_BACKEND_HERDR_PINNED_BIN=
# shellcheck disable=SC2016
fm_backend_herdr_bin() {
  local passwd_home discovered physical
  [ -z "$FM_BACKEND_HERDR_PINNED_BIN" ] || {
    fm_backend_herdr_validate_physical_bin "$FM_BACKEND_HERDR_PINNED_BIN" || return 1
    printf '%s\n' "$FM_BACKEND_HERDR_PINNED_BIN"
    return 0
  }
  [ -n "$FM_BACKEND_HERDR_PERL_BIN" ] || return 1
  if fm_backend_herdr_test_lab_enabled; then
    discovered=$(command -v herdr 2>/dev/null) || return 1
  else
    passwd_home=$(fm_backend_herdr_passwd_home 2>/dev/null) || return 1
    case "$passwd_home" in /*) ;; *) return 1 ;; esac
    discovered=$passwd_home/.local/bin/herdr
  fi
  physical=$(fm_backend_herdr_control_perl -MCwd=abs_path -e \
    'my $p = abs_path($ARGV[0]); exit 1 unless defined $p; print $p' \
    "$discovered" 2>/dev/null) || return 1
  fm_backend_herdr_validate_physical_bin "$physical" || return 1
  FM_BACKEND_HERDR_PINNED_BIN=$physical
  printf '%s\n' "$physical"
}

# fm_backend_herdr_workspace_label: the per-firstmate-HOME herdr workspace
# label (docs/herdr-backend.md "Task container shape"). The PRIMARY home (no
# secondmate marker) resolves to the constant "firstmate", byte-identical to
# every pre-existing task's recorded label - no forced migration. A SECONDMATE
# home resolves to "2ndmate-<secondmate-id>", so its tasks land in their own
# workspace, obviously distinguishable from the primary's (and from every
# other secondmate's) in herdr's spaces sidebar. Read fresh from FM_HOME on
# every call rather than cached at source time: FM_HOME is the home's own
# durable identity, not env plumbing threaded through a call chain, so the
# label is automatically stable across every respawn/recovery for the life of
# that home. fm-spawn.sh briefly shadows FM_HOME to a secondmate's own home
# when the PRIMARY spawns that secondmate (its own process's FM_HOME still
# names the primary at that point) - see fm-spawn.sh's herdr case arm.
fm_backend_herdr_workspace_label_for_home() {  # <home>
  local marker="$1/$FM_BACKEND_HERDR_SECONDMATE_MARKER" id
  if [ -f "$marker" ]; then
    id=$(fm_backend_herdr_control_exec tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      printf '2ndmate-%s' "$id"
      return 0
    fi
  fi
  printf 'firstmate'
}

fm_backend_herdr_workspace_label() {
  fm_backend_herdr_workspace_label_for_home "$FM_HOME"
}

# fm_backend_herdr_cli: run `herdr <args...>` scoped to <session>, setting
# BOTH the HERDR_SESSION env var AND appending a trailing `--session <name>`
# CLI flag. Verified empirically (docs/herdr-backend.md "Session targeting: the
# --session flag, not HERDR_SESSION alone"): on the installed herdr 0.7.1
# client, the HERDR_SESSION env var is NOT reliably honored by CLI subcommands
# once ANY other herdr server is already bound on the machine - queries
# silently fall back to whatever server IS running (the wrong one) instead of
# routing to the requested session or refusing. The `--session <name>` global
# flag (verified in both leading and trailing position; trailing used here to
# keep every call site a minimal, append-only diff) always routes correctly,
# including starting a genuinely separate, isolated server process. The env
# var is kept alongside it - harmless, self-documenting, and forward-
# compatible if a future herdr build honors it. Never used by
# fm_backend_herdr_version_check, which is intentionally session-independent
# (reads only .client.* fields).
fm_backend_herdr_cli() {  # <session> <herdr-subcommand-and-args...>
  local session=$1 herdr_bin
  shift
  herdr_bin=$(fm_backend_herdr_bin) || return 1
  HERDR_SESSION="$session" fm_backend_herdr_scrubbed_exec \
    "$herdr_bin" "$@" --session "$session"
}

# fm_backend_herdr_tool_check: refuse loudly if herdr, jq, or the portable
# setsid launcher prerequisites are missing.
fm_backend_herdr_tool_check() {
  fm_backend_herdr_bin >/dev/null 2>&1 || { echo "error: backend=herdr selected but the fixed current-user Herdr CLI is unavailable or unsafe (https://herdr.dev)" >&2; return 1; }
  [ -n "$FM_BACKEND_HERDR_JQ_BIN" ] || { echo "error: backend=herdr selected but the fixed system jq is unavailable" >&2; return 1; }
  [ -n "$FM_BACKEND_HERDR_NOHUP_BIN" ] || { echo "error: backend=herdr selected but the fixed system nohup is unavailable" >&2; return 1; }
  [ -n "$FM_BACKEND_HERDR_PERL_BIN" ] || { echo "error: backend=herdr selected but the fixed system perl is unavailable" >&2; return 1; }
  return 0
}

# fm_backend_herdr_version_check: refuse loudly on a missing/incompatible
# herdr client. Verified locally: v0.7.1, protocol 14 (herdr status --json's
# .client.protocol; client info is session-independent, unlike .server).
fm_backend_herdr_version_check() {
  fm_backend_herdr_tool_check || return 1
  local status protocol version herdr_bin
  herdr_bin=$(fm_backend_herdr_bin) || return 1
  status=$(fm_backend_herdr_scrubbed_exec "$herdr_bin" status --json 2>/dev/null) || { echo "error: 'herdr status --json' failed; is herdr installed correctly?" >&2; return 1; }
  protocol=$(printf '%s' "$status" | fm_backend_herdr_control_jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | fm_backend_herdr_control_jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL; update herdr (herdr update) before using backend=herdr" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_session: resolve which named herdr session this normal
# spawn/op uses. HERDR_SESSION mirrors tmux's $TMUX ambient-selection for
# adapter workspace/tab/pane operations: an operator (or firstmate's own
# isolated test harness) sets it explicitly; absent means herdr's own
# "default" session. Do not use HERDR_SESSION alone for destructive test
# cleanup; tests/herdr-test-safety.sh documents and guards that path.
fm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# fm_backend_herdr_server_launch_detached: start exactly one headless Herdr
# server outside the caller's process group, session, controlling terminal,
# and stdio lifetime. A portable Perl double-fork performs setsid even on
# macOS, where the util-linux `setsid` executable is absent. The adapter stays
# the single lifecycle owner; captain launchers never start or stop Herdr.
fm_backend_herdr_server_launch_detached() {  # <session>
  local session=$1 herdr_bin perl_bin passwd_home worker_path certificate certificate_key managed_config managed_shell ps_bin name value launch_env=()
  local managed_shell_proof managed_shell_digest managed_shell_identity managed_config_proof managed_config_digest managed_config_identity
  herdr_bin=$(fm_backend_herdr_bin) || return 1
  perl_bin=$FM_BACKEND_HERDR_PERL_BIN
  passwd_home=$(fm_backend_herdr_passwd_home 2>/dev/null) || return 1
  case "$passwd_home" in /*) ;; *) return 1 ;; esac
  worker_path=$(fm_backend_herdr_worker_path "${PATH:-}") || return 1
  certificate=
  certificate_key=
  # Direct adapter unit tests that do not exercise the server lock may omit a
  # test lock root. Production, and lock-aware lab tests, always publish the
  # process-bound closed-environment certificate consumed by routed spawns.
  if ! fm_backend_herdr_test_lab_enabled \
    || [ -n "${FM_BACKEND_HERDR_SERVER_LOCK_ROOT:-}" ]; then
    certificate=$(fm_backend_herdr_server_env_certificate_path "$session") || return 1
    certificate_key=$(fm_backend_herdr_server_lock_key "$session") || return 1
    managed_shell=$(fm_backend_herdr_managed_shell_bin) || return 1
    managed_config=$(fm_backend_herdr_managed_config_ensure "$session" "$managed_shell") || return 1
    managed_shell_proof=$(fm_backend_herdr_file_identity "$managed_shell" 0500 owner) || return 1
    managed_shell_digest=${managed_shell_proof%%$'\n'*}
    managed_shell_identity=${managed_shell_proof#*$'\n'}
    managed_config_proof=$(fm_backend_herdr_file_identity "$managed_config" 0600 owner) || return 1
    managed_config_digest=${managed_config_proof%%$'\n'*}
    managed_config_identity=${managed_config_proof#*$'\n'}
    fm_backend_herdr_artifact_recover_candidates "$certificate" 0600 || return 1
    ps_bin=$(fm_backend_herdr_ps_bin) || return 1
  fi
  [ -n "$perl_bin" ] && [ -n "$FM_BACKEND_HERDR_NOHUP_BIN" ] \
    && [ -n "$FM_BACKEND_HERDR_ENV_BIN" ] || return 1
  launch_env=(
    "HOME=$passwd_home"
    "PATH=$worker_path"
    "HERDR_SESSION=$session"
    "LC_ALL=C"
  )
  if [ -n "$managed_config" ]; then
    launch_env+=("HERDR_CONFIG_PATH=$managed_config" "SHELL=$managed_shell")
  fi
  # Fake servers need a narrow set of fixture paths.  This branch is reachable
  # only behind the exact lab opt-in; production never forwards test state.
  if fm_backend_herdr_test_lab_enabled; then
    for name in FM_HERDR_DETACH_MARKER FM_HERDR_LOG FM_HERDR_RESPONSES \
      FM_FAKE_HERDR_STATE FM_FAKE_AGENT_DIR FM_FAKE_HERDR_RUNNING \
      FM_FAKE_HERDR_SERVER_PIDS FM_FAKE_HERDR_LAUNCH_INVOKED; do
      value=${!name:-}
      [ -z "$value" ] || launch_env+=("$name=$value")
    done
  fi
  (
    # Dollar expressions in the single-quoted program below belong to Perl.
    # shellcheck disable=SC2016
    "$FM_BACKEND_HERDR_ENV_BIN" -i "${launch_env[@]}" \
      "$FM_BACKEND_HERDR_NOHUP_BIN" "$perl_bin" -MFcntl=:DEFAULT -MIO::Handle -MPOSIX -e '
      my ($certificate, $certificate_key, $ps, $managed_shell,
          $managed_shell_digest, $managed_shell_identity, $managed_config,
          $managed_config_digest, $managed_config_identity, @command) = @ARGV;
      my $pid = fork();
      defined $pid or die "first fork: $!";
      exit 0 if $pid;
      POSIX::setsid() >= 0 or die "setsid: $!";
      $pid = fork();
      defined $pid or die "second fork: $!";
      exit 0 if $pid;
      if (length $certificate) {
        open my $process, "-|", $ps, "-o", "lstart=", "-p", "$$"
          or die "process-start probe: $!";
        local $/;
        my $start = <$process> // "";
        close $process or die "process-start probe failed";
        $start =~ s/^\s+|\s+$//g;
        length $start or die "empty process-start token";
        my $candidate = "$certificate.candidate.$$";
        sysopen my $owner, $candidate, O_WRONLY | O_CREAT | O_EXCL, 0600
          or die "certificate candidate: $!";
        chmod 0600, $candidate or die "certificate mode: $!";
        print {$owner} "firstmate-herdr-closed-env-v2\n",
          "$certificate_key\n", "$$\n", "$start\n",
          "$managed_shell\n", "$managed_shell_digest\n",
          "$managed_shell_identity\n", "$managed_config\n",
          "$managed_config_digest\n", "$managed_config_identity\n"
          or die "certificate write: $!";
        $owner->flush or die "certificate flush: $!";
        $owner->sync or die "certificate sync: $!";
        close $owner or die "certificate close: $!";
        rename $candidate, $certificate or die "certificate publish: $!";
      }
      exec { $command[0] } @command;
      die "exec $command[0]: $!";
    ' -- "$certificate" "$certificate_key" "${ps_bin:-}" \
      "${managed_shell:-}" "${managed_shell_digest:-}" "${managed_shell_identity:-}" \
      "${managed_config:-}" "${managed_config_digest:-}" "${managed_config_identity:-}" \
      "$herdr_bin" server --session "$session" </dev/null >/dev/null 2>&1 &
  ) || return 1
}

fm_backend_herdr_path_mode() {
  local PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if [ "$(fm_backend_herdr_control_exec uname)" = Darwin ]; then
    fm_backend_herdr_control_exec stat -f %Lp "$1" 2>/dev/null
  else
    fm_backend_herdr_control_exec stat -c %a "$1" 2>/dev/null
  fi
}

fm_backend_herdr_path_age() {
  local modified PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if [ "$(fm_backend_herdr_control_exec uname)" = Darwin ]; then
    modified=$(fm_backend_herdr_control_exec stat -f %m "$1" 2>/dev/null) || return 1
  else
    modified=$(fm_backend_herdr_control_exec stat -c %Y "$1" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$(( $(fm_backend_herdr_control_exec date +%s) - modified ))"
}

fm_backend_herdr_path_inode() {
  local PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if [ "$(fm_backend_herdr_control_exec uname)" = Darwin ]; then
    fm_backend_herdr_control_exec stat -f '%d:%i' "$1" 2>/dev/null
  else
    fm_backend_herdr_control_exec stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_path_nlink() {
  local PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if [ "$(fm_backend_herdr_control_exec uname)" = Darwin ]; then
    fm_backend_herdr_control_exec stat -f %l "$1" 2>/dev/null
  else
    fm_backend_herdr_control_exec stat -c %h "$1" 2>/dev/null
  fi
}

fm_backend_herdr_path_uid() {
  local PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if [ "$(fm_backend_herdr_control_exec uname)" = Darwin ]; then
    fm_backend_herdr_control_exec stat -f %u "$1" 2>/dev/null
  else
    fm_backend_herdr_control_exec stat -c %u "$1" 2>/dev/null
  fi
}

fm_backend_herdr_path_has_sticky_bit() {
  local raw PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if [ "$(fm_backend_herdr_control_exec uname)" = Darwin ]; then
    raw=$(fm_backend_herdr_control_exec stat -f %p "$1" 2>/dev/null) || return 1
  else
    raw=$(fm_backend_herdr_control_exec stat -c %a "$1" 2>/dev/null) || return 1
  fi
  case "$raw" in ''|*[!0-7]*) return 1 ;; esac
  [ $((8#$raw & 8#1000)) -ne 0 ]
}

# Validate one already-physical path and all of its physical ancestors.  A
# root-owned sticky directory (notably /private/tmp) is the sole writable
# ancestor exception.  The check is repeated whenever the cached Herdr binary
# is requested, including immediately before detached launch.
fm_backend_herdr_validate_safe_ancestry() {  # <physical-path> <file|directory>
  local current=$1 kind=$2 leaf=1 owner_uid uid mode numeric links PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  case "$current" in /*) ;; *) return 1 ;; esac
  owner_uid=$(fm_backend_herdr_control_exec id -u) || return 1
  while :; do
    [ -e "$current" ] && [ ! -L "$current" ] || return 1
    uid=$(fm_backend_herdr_path_uid "$current") || return 1
    mode=$(fm_backend_herdr_path_mode "$current") || return 1
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    numeric=$((8#$mode))
    [ "$uid" -eq 0 ] || [ "$uid" -eq "$owner_uid" ] || return 1
    if [ "$leaf" -eq 1 ] && [ "$kind" = file ]; then
      [ -f "$current" ] && [ -x "$current" ] || return 1
      links=$(fm_backend_herdr_path_nlink "$current") || return 1
      [ "$links" = 1 ] || return 1
      [ $((numeric & 8#22)) -eq 0 ] || return 1
    else
      [ -d "$current" ] || return 1
      if [ $((numeric & 8#22)) -ne 0 ]; then
        [ "$uid" -eq 0 ] && fm_backend_herdr_path_has_sticky_bit "$current" || return 1
      fi
    fi
    [ "$current" != / ] || break
    current=${current%/*}
    [ -n "$current" ] || current=/
    leaf=0
  done
}

fm_backend_herdr_validate_physical_bin() {  # <physical-path>
  fm_backend_herdr_validate_safe_ancestry "$1" file
}

# Build the environment inherited by Herdr panes independently from the fixed
# control PATH. Managed workers still need safe Homebrew/user tool directories
# (for example node and uv), but a caller-controlled writable PATH entry must
# never become executable search authority in the detached server. Resolve each
# directory physically, require safe owner/mode ancestry, reject a writable
# search leaf even when it is root-sticky, deduplicate, and append the control
# directories as a guaranteed floor.
fm_backend_herdr_worker_path() {  # [candidate-path]
  local source=${1:-} combined raw physical mode numeric result='' old_ifs
  local -a candidates=()
  case "$source" in *$'\n'*) source= ;; esac
  combined=${source:+$source:}$FM_BACKEND_HERDR_CONTROL_PATH
  old_ifs=$IFS
  IFS=:
  read -r -a candidates <<< "$combined"
  IFS=$old_ifs
  for raw in "${candidates[@]}"; do
    case "$raw" in /*) ;; *) continue ;; esac
    # Dollar expressions in the single-quoted program belong to Perl.
    # shellcheck disable=SC2016
    physical=$(fm_backend_herdr_control_perl -MCwd=abs_path -e \
      'my $p = abs_path($ARGV[0]); exit 1 unless defined $p; print $p' \
      "$raw" 2>/dev/null) || continue
    case "$physical" in ''|*$'\n'*|*:*) continue ;; esac
    fm_backend_herdr_validate_safe_ancestry "$physical" directory || continue
    mode=$(fm_backend_herdr_path_mode "$physical") || continue
    case "$mode" in ''|*[!0-7]*) continue ;; esac
    numeric=$((8#$mode))
    [ $((numeric & 8#22)) -eq 0 ] || continue
    case ":$result:" in *":$physical:"*) continue ;; esac
    if [ -n "$result" ]; then
      result=$result:$physical
    else
      result=$physical
    fi
  done
  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

fm_backend_herdr_test_hooks_enabled() {
  fm_backend_herdr_test_lab_enabled \
    && [ "${FM_BACKEND_HERDR_TEST_HOOKS:-}" = firstmate-herdr-tests-v1 ]
}

fm_backend_herdr_ps_bin() {
  if fm_backend_herdr_test_hooks_enabled && [ -n "${FM_TEST_HERDR_PS_BIN:-}" ]; then
    [ -x "$FM_TEST_HERDR_PS_BIN" ] || return 1
    printf '%s\n' "$FM_TEST_HERDR_PS_BIN"
  elif [ -x /bin/ps ]; then
    printf '%s\n' /bin/ps
  elif [ -x /usr/bin/ps ]; then
    printf '%s\n' /usr/bin/ps
  else
    return 1
  fi
}

fm_backend_herdr_process_start() {
  local value ps_bin PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  ps_bin=$(fm_backend_herdr_ps_bin) || return 1
  value=$(LC_ALL=C fm_backend_herdr_scrubbed_exec "$ps_bin" -o lstart= -p "$1" 2>/dev/null) || return 1
  value=$(printf '%s\n' "$value" | fm_backend_herdr_control_exec sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# Return success only when ps proves a PID is absent. Any output-bearing error,
# successful-but-empty result, or unavailable probe is indeterminate and must
# never authorize artifact deletion.
fm_backend_herdr_process_absent() {  # <pid>
  local probe status ps_bin PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  ps_bin=$(fm_backend_herdr_ps_bin) || return 2
  probe=$(LC_ALL=C fm_backend_herdr_scrubbed_exec "$ps_bin" -o lstart= -p "$1" 2>&1)
  status=$?
  probe=$(printf '%s\n' "$probe" | fm_backend_herdr_control_exec sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$status" -eq 0 ]; then
    [ -n "$probe" ] || return 2
    return 1
  fi
  [ -z "$probe" ] || return 2
  return 0
}

fm_backend_herdr_server_lock_root() {
  local raw parent_raw parent leaf owner_uid PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  if fm_backend_herdr_test_lab_enabled && [ -n "${FM_BACKEND_HERDR_SERVER_LOCK_ROOT:-}" ]; then
    raw=$FM_BACKEND_HERDR_SERVER_LOCK_ROOT
  else
    [ -z "${FM_BACKEND_HERDR_SERVER_LOCK_ROOT:-}" ] || return 1
    owner_uid=$(fm_backend_herdr_control_exec id -u) || return 1
    raw=/tmp/firstmate-herdr-server-locks-$owner_uid
  fi
  case "$raw" in /*) ;; *) return 1 ;; esac
  leaf=${raw##*/}
  parent_raw=${raw%/*}
  [ -n "$parent_raw" ] || parent_raw=/
  case "$leaf" in ''|.|..) return 1 ;; esac
  parent=$(cd "$parent_raw" 2>/dev/null && pwd -P) || return 1
  fm_backend_herdr_validate_safe_ancestry "$parent" directory || {
    echo "error: unsafe Herdr server lock-root ancestry: $parent" >&2
    return 1
  }
  printf '%s/%s\n' "$parent" "$leaf"
}

fm_backend_herdr_server_lock_root_prepare() {
  local root parent mode PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  root=$(fm_backend_herdr_server_lock_root) || return 1
  parent=${root%/*}
  [ -n "$parent" ] || parent=/
  fm_backend_herdr_validate_safe_ancestry "$parent" directory || return 1
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    (umask 077 && fm_backend_herdr_control_exec mkdir "$root") 2>/dev/null || true
  fi
  fm_backend_herdr_validate_safe_ancestry "$parent" directory || return 1
  mode=$(fm_backend_herdr_path_mode "$root") || mode=
  if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -O "$root" ] || [ "$mode" != 700 ]; then
    echo "error: Herdr server lock root must be a current-user 0700 directory: $root" >&2
    return 1
  fi
}

fm_backend_herdr_server_lock_key() {
  local session=$1
  printf '%s' "$session" | fm_backend_herdr_control_perl \
    -MDigest::SHA=sha256_hex -e 'local $/; print sha256_hex(<STDIN>)'
}

fm_backend_herdr_server_env_certificate_path() {  # <session>
  local root key
  fm_backend_herdr_server_lock_root_prepare || return 1
  root=$(fm_backend_herdr_server_lock_root) || return 1
  key=$(fm_backend_herdr_server_lock_key "$1") || return 1
  printf '%s/%s.closed-shell-v2\n' "$root" "$key"
}

fm_backend_herdr_server_legacy_env_certificate_path() {  # <session>
  local root key
  fm_backend_herdr_server_lock_root_prepare || return 1
  root=$(fm_backend_herdr_server_lock_root) || return 1
  key=$(fm_backend_herdr_server_lock_key "$1") || return 1
  printf '%s/%s.closed-shell-v1\n' "$root" "$key"
}

fm_backend_herdr_server_certificate_required() {
  ! fm_backend_herdr_test_lab_enabled && return 0
  [ "${FM_TEST_HERDR_REQUIRE_CERT_LIFECYCLE:-}" = firstmate-herdr-tests-v1 ]
}

fm_backend_herdr_file_read_verified() {  # <identity|snapshot> <path> <mode|executable> <owner|root-or-owner>
  local operation=$1 path=$2 expected_mode=$3 owner_policy=$4
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *$'\n'*) return 1 ;; esac
  # The descriptor, both fstat snapshots, and the final lstat all have to name
  # one regular file. O_NOFOLLOW prevents a symlink from entering between the
  # shell's ancestry check and the actual read. The first two output lines are
  # always SHA-256 and a supplemental dev:ino:size:mtime identity.
  # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
  fm_backend_herdr_control_perl -MDigest::SHA -MFcntl=:DEFAULT -e '
    my ($operation, $path, $expected_mode, $owner_policy) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined $nofollow or die "O_NOFOLLOW unavailable";
    sysopen my $fh, $path, O_RDONLY | $nofollow or die "open: $!";
    my @before = stat($fh);
    @before or die "fstat before: $!";
    -f $fh or die "not regular";
    my $mode = $before[2] & 07777;
    $before[3] == 1 or die "link count";
    if ($expected_mode eq "executable") {
      ($mode & 0111) && !($mode & 0022) or die "unsafe executable mode";
    } else {
      $mode == oct($expected_mode) or die "mode";
    }
    if ($owner_policy eq "owner") {
      $before[4] == $< or die "owner";
    } elsif ($owner_policy eq "root-or-owner") {
      ($before[4] == 0 || $before[4] == $<) or die "owner";
    } else {
      die "owner policy";
    }
    my $sha = Digest::SHA->new(256);
    my $payload = "";
    while (1) {
      my $count = sysread($fh, my $chunk, 65536);
      defined $count or die "read: $!";
      last unless $count;
      $sha->add($chunk);
      $payload .= $chunk if $operation eq "snapshot";
    }
    my @after = stat($fh);
    @after or die "fstat after: $!";
    for my $index (0, 1, 2, 3, 4, 7, 9) {
      $before[$index] == $after[$index] or die "changed during read";
    }
    my @path_after = lstat($path);
    @path_after or die "lstat after: $!";
    ($path_after[0] == $after[0] && $path_after[1] == $after[1])
      or die "path replaced after read";
    close $fh or die "close: $!";
    my $digest = $sha->hexdigest;
    my $identity = join(":", @after[0, 1, 7, 9]);
    print "$digest\n$identity\n";
    print $payload if $operation eq "snapshot";
  ' "$operation" "$path" "$expected_mode" "$owner_policy" 2>/dev/null
}

fm_backend_herdr_file_identity() {  # <path> <mode|executable> <owner-policy>
  fm_backend_herdr_file_read_verified identity "$@"
}

fm_backend_herdr_file_snapshot() {  # <path> <mode|executable> <owner-policy>
  fm_backend_herdr_file_read_verified snapshot "$@"
}

# Prove that <candidate> and <target> are the two names of exactly one regular,
# current-user-owned inode left by no-replace publication. This proof is kept
# separate from ordinary artifact reads, which intentionally require nlink=1.
fm_backend_herdr_hardlink_pair_identity() {  # <candidate> <target> <mode>
  local candidate=$1 target=$2 mode=$3
  case "$candidate:$target" in *$'\n'*) return 1 ;; esac
  # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
  fm_backend_herdr_control_perl -MDigest::SHA -MFcntl=:DEFAULT -e '
    my ($candidate, $target, $expected_mode) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined $nofollow or die "O_NOFOLLOW unavailable";
    sysopen my $candidate_fh, $candidate, O_RDONLY | $nofollow
      or die "candidate open: $!";
    sysopen my $target_fh, $target, O_RDONLY | $nofollow
      or die "target open: $!";
    my @candidate_before = stat($candidate_fh);
    my @target_before = stat($target_fh);
    @candidate_before && @target_before or die "fstat";
    -f $candidate_fh && -f $target_fh or die "not regular";
    ($candidate_before[2] & 07777) == oct($expected_mode) or die "candidate mode";
    ($target_before[2] & 07777) == oct($expected_mode) or die "target mode";
    $candidate_before[3] == 2 && $target_before[3] == 2 or die "link count";
    $candidate_before[4] == $< && $target_before[4] == $< or die "owner";
    for my $index (0, 1, 2, 3, 4, 7, 9) {
      $candidate_before[$index] == $target_before[$index] or die "not one inode";
    }
    my $sha = Digest::SHA->new(256);
    while (1) {
      my $count = sysread($candidate_fh, my $chunk, 65536);
      defined $count or die "read: $!";
      last unless $count;
      $sha->add($chunk);
    }
    my @candidate_after = stat($candidate_fh);
    my @target_after = stat($target_fh);
    for my $index (0, 1, 2, 3, 4, 7, 9) {
      $candidate_before[$index] == $candidate_after[$index]
        && $target_before[$index] == $target_after[$index]
        or die "changed during read";
    }
    my @candidate_path = lstat($candidate);
    my @target_path = lstat($target);
    @candidate_path && @target_path or die "path disappeared";
    $candidate_path[0] == $candidate_after[0]
      && $candidate_path[1] == $candidate_after[1]
      && $target_path[0] == $target_after[0]
      && $target_path[1] == $target_after[1]
      or die "path replaced";
    close $candidate_fh or die "candidate close: $!";
    close $target_fh or die "target close: $!";
    print $sha->hexdigest, "\n",
      join(":", @candidate_after[0, 1, 7, 9]), "\n";
  ' "$candidate" "$target" "$mode" 2>/dev/null
}

fm_backend_herdr_managed_shell_source() {
  local physical candidate="$FM_BACKEND_HERDR_ROOT/bin/fm-herdr-worker-shell"
  if fm_backend_herdr_test_hooks_enabled \
    && [ -n "${FM_TEST_HERDR_MANAGED_SHELL_SOURCE:-}" ]; then
    candidate=$FM_TEST_HERDR_MANAGED_SHELL_SOURCE
  fi
  # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
  physical=$(fm_backend_herdr_control_perl -MCwd=abs_path -e \
    'my $p = abs_path($ARGV[0]); exit 1 unless defined $p; print $p' \
    "$candidate" 2>/dev/null) || return 1
  fm_backend_herdr_validate_physical_bin "$physical" || return 1
  printf '%s\n' "$physical"
}

fm_backend_herdr_managed_shell_path_for_digest() {  # <sha256>
  local digest=$1 root
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  root=$(fm_backend_herdr_server_lock_root) || return 1
  printf '%s/managed-worker-shell-v1-%s\n' "$root" "$digest"
}

fm_backend_herdr_artifact_has_quarantine() {  # <target>
  local quarantine
  for quarantine in "$1".quarantine.*; do
    [ -e "$quarantine" ] || [ -L "$quarantine" ] || continue
    return 0
  done
  return 1
}

# Read one quarantine through its directory descriptor, accepting only an
# owner-private 0700 directory whose exact contents are empty or `artifact`.
fm_backend_herdr_artifact_quarantine_snapshot() {  # <quarantine>
  local quarantine=$1
  case "$quarantine" in *$'\n'*) return 1 ;; esac
  # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
  fm_backend_herdr_control_perl -e '
    my ($path) = @ARGV;
    opendir my $dir, $path or die "opendir: $!";
    my @before = stat($dir);
    @before && -d $dir or die "not directory";
    ($before[2] & 07777) == 0700 or die "mode";
    $before[4] == $< or die "owner";
    my @names = sort grep { $_ ne "." && $_ ne ".." } readdir $dir;
    my @after = stat($dir);
    for my $index (0, 1, 2, 3, 4, 9) {
      $before[$index] == $after[$index] or die "directory changed";
    }
    my @path_after = lstat($path);
    @path_after
      && $path_after[0] == $after[0]
      && $path_after[1] == $after[1]
      && ($path_after[2] & 07777) == 0700
      && $path_after[4] == $<
      or die "path replaced";
    closedir $dir or die "closedir: $!";
    my $contents = !@names ? "empty"
      : @names == 1 && $names[0] eq "artifact" ? "artifact"
      : "occupied";
    print "$after[0]:$after[1]\n$contents\n";
  ' "$quarantine" 2>/dev/null
}

# Resume any finite phase of one already-authorized attributed deletion. The
# caller owns the safety proof for <path>; this primitive descriptor-proves the
# private quarantine and never deletes a moved generation until its inode is
# exactly the attributed inode. Ambiguous or occupied generations are kept.
fm_backend_herdr_artifact_resume_attributed() {  # <path> <expected-dev:ino>
  local path=$1 expected_inode=$2 quarantine quarantine_key snapshot quarantine_inode contents
  local moved_inode after PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  case "$expected_inode" in ''|*[!0-9:]*|:*|*:) return 1 ;; esac
  quarantine_key=${expected_inode/:/_}
  quarantine="$path.quarantine.$quarantine_key"
  snapshot=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
  case "$snapshot" in *$'\n'*) ;; *) return 1 ;; esac
  quarantine_inode=${snapshot%%$'\n'*}
  contents=${snapshot#*$'\n'}
  case "$contents" in
    empty)
      if [ -e "$path" ] || [ -L "$path" ]; then
        [ "$(fm_backend_herdr_path_inode "$path" 2>/dev/null)" = "$expected_inode" ] \
          || return 1
        after=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
        [ "$after" = "$snapshot" ] || return 1
        if fm_backend_herdr_test_hooks_enabled \
          && [ "${FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET:-}" = "$path" ] \
          && [ -n "${FM_TEST_HERDR_ARTIFACT_REMOVE_READY:-}" ] \
          && [ -n "${FM_TEST_HERDR_ARTIFACT_REMOVE_PROCEED:-}" ]; then
          : > "$FM_TEST_HERDR_ARTIFACT_REMOVE_READY"
          while [ ! -e "$FM_TEST_HERDR_ARTIFACT_REMOVE_PROCEED" ]; do
            fm_backend_herdr_control_exec sleep 0.01
          done
        fi
        fm_backend_herdr_control_exec mv "$path" "$quarantine/artifact" 2>/dev/null \
          || return 1
        moved_inode=$(fm_backend_herdr_path_inode "$quarantine/artifact" 2>/dev/null) \
          || return 1
        after=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
        if [ "$moved_inode" != "$expected_inode" ] \
          || [ "${after%%$'\n'*}" != "$quarantine_inode" ] \
          || [ "${after#*$'\n'}" != artifact ]; then
          echo "error: preserved ambiguous Herdr artifact generation at $quarantine/artifact" >&2
          return 1
        fi
        contents=artifact
      else
        after=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
        [ "$after" = "$snapshot" ] || return 1
      fi
      ;;
    artifact)
      [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
      moved_inode=$(fm_backend_herdr_path_inode "$quarantine/artifact" 2>/dev/null) \
        || return 1
      [ "$moved_inode" = "$expected_inode" ] || return 1
      ;;
    *) return 1 ;;
  esac
  if [ "$contents" = artifact ]; then
    after=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
    [ "${after%%$'\n'*}" = "$quarantine_inode" ] \
      && [ "${after#*$'\n'}" = artifact ] \
      && [ "$(fm_backend_herdr_path_inode "$quarantine/artifact" 2>/dev/null)" = "$expected_inode" ] \
      || return 1
    if fm_backend_herdr_test_hooks_enabled \
      && [ "${FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET:-}" = "$path" ] \
      && [ -n "${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE:-}" ]; then
      : > "$FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE"
      kill -KILL "${BASHPID:-$$}"
    fi
    fm_backend_herdr_control_exec rm -f "$quarantine/artifact" 2>/dev/null || return 1
    if fm_backend_herdr_test_hooks_enabled \
      && [ "${FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET:-}" = "$path" ] \
      && [ -n "${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK:-}" ]; then
      : > "$FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK"
      kill -KILL "${BASHPID:-$$}"
    fi
  fi
  after=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
  [ "${after%%$'\n'*}" = "$quarantine_inode" ] \
    && [ "${after#*$'\n'}" = empty ] || return 1
  fm_backend_herdr_control_exec rmdir "$quarantine" 2>/dev/null || return 1
}

# Move the pathname generation into a private, deterministic device/inode-keyed
# quarantine before deletion. Every later phase is resumable by the state
# machine above.
fm_backend_herdr_artifact_remove_attributed() {  # <path> <expected-dev:ino>
  local path=$1 expected_inode=$2 quarantine quarantine_key PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  case "$expected_inode" in ''|*[!0-9:]*|:*|*:) return 1 ;; esac
  quarantine_key=${expected_inode/:/_}
  fm_backend_herdr_artifact_has_quarantine "$path" && return 1
  quarantine="$path.quarantine.$quarantine_key"
  (umask 077 && fm_backend_herdr_control_exec mkdir "$quarantine") 2>/dev/null || return 1
  fm_backend_herdr_control_exec chmod 700 "$quarantine" 2>/dev/null || return 1
  fm_backend_herdr_artifact_quarantine_snapshot "$quarantine" >/dev/null || return 1
  if fm_backend_herdr_test_hooks_enabled \
    && [ "${FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET:-}" = "$path" ] \
    && [ -n "${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR:-}" ]; then
    : > "$FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR"
    kill -KILL "${BASHPID:-$$}"
  fi
  fm_backend_herdr_artifact_resume_attributed "$path" "$expected_inode"
}

# Recover every attributed candidate cleanup phase: empty quarantine before
# move, quarantined artifact before unlink, and empty quarantine before rmdir.
# Both ordinary nlink=1 candidates and published target/candidate nlink=2 pairs
# use the same state machine and retain their stale/dead PID authorization.
fm_backend_herdr_artifact_recover_candidate_quarantines() {  # <target> <mode>
  local target=$1 mode=$2 quarantine candidate pid key expected_inode snapshot contents artifact_path
  local links identity_before identity_after artifact_inode target_after PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  for quarantine in "$target".candidate.*.quarantine.*; do
    [ -e "$quarantine" ] || [ -L "$quarantine" ] || continue
    candidate=${quarantine%.quarantine.*}
    pid=${candidate##*.candidate.}
    key=${quarantine##*.quarantine.}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$key" in ''|*[!0-9_]*|_*|*_|*_*_*) return 1 ;; esac
    expected_inode=${key/_/:}
    fm_backend_herdr_server_lock_is_stale_age "$quarantine" || continue
    fm_backend_herdr_process_absent "$pid" || continue
    snapshot=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") || return 1
    contents=${snapshot#*$'\n'}
    case "$contents" in
      empty)
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
          identity_before=
          links=0
        else
          artifact_path=$candidate
          links=$(fm_backend_herdr_path_nlink "$artifact_path" 2>/dev/null) || return 1
        fi
        ;;
      artifact)
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
        artifact_path="$quarantine/artifact"
        links=$(fm_backend_herdr_path_nlink "$artifact_path" 2>/dev/null) || return 1
        ;;
      *) return 1 ;;
    esac
    case "$links" in
      0) ;;
      1)
        identity_before=$(fm_backend_herdr_file_identity "$artifact_path" "$mode" owner 2>/dev/null) \
          || return 1
        artifact_inode=$(fm_backend_herdr_path_inode "$artifact_path") || return 1
        [ "$artifact_inode" = "$expected_inode" ] || return 1
        identity_after=$(fm_backend_herdr_file_identity "$artifact_path" "$mode" owner 2>/dev/null) \
          || return 1
        [ "$identity_after" = "$identity_before" ] || return 1
        ;;
      2)
        identity_before=$(fm_backend_herdr_hardlink_pair_identity \
          "$artifact_path" "$target" "$mode") || return 1
        artifact_inode=$(fm_backend_herdr_path_inode "$artifact_path") || return 1
        [ "$artifact_inode" = "$expected_inode" ] || return 1
        identity_after=$(fm_backend_herdr_hardlink_pair_identity \
          "$artifact_path" "$target" "$mode") || return 1
        [ "$identity_after" = "$identity_before" ] || return 1
        ;;
      *) return 1 ;;
    esac
    [ "$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine")" = "$snapshot" ] \
      || return 1
    fm_backend_herdr_process_absent "$pid" || return 1
    fm_backend_herdr_server_lock_is_stale_age "$quarantine" || return 1
    fm_backend_herdr_artifact_resume_attributed "$candidate" "$expected_inode" || return 1
    if [ "$links" -eq 2 ]; then
      target_after=$(fm_backend_herdr_file_identity "$target" "$mode" owner 2>/dev/null) \
        || return 1
      [ "$target_after" = "$identity_after" ] || return 1
    fi
  done
}

fm_backend_herdr_artifact_recover_candidates() {  # <target> <mode>
  local target=$1 mode=$2 candidate pid inode links identity_before identity_after target_after
  fm_backend_herdr_artifact_has_quarantine "$target" && return 1
  fm_backend_herdr_artifact_recover_candidate_quarantines "$target" "$mode" || return 1
  for candidate in "$target".candidate.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    pid=${candidate##*.candidate.}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    links=$(fm_backend_herdr_path_nlink "$candidate" 2>/dev/null) || continue
    case "$links" in
      1)
        identity_before=$(fm_backend_herdr_file_identity "$candidate" "$mode" owner 2>/dev/null) || continue
        fm_backend_herdr_server_lock_is_stale_age "$candidate" || continue
        fm_backend_herdr_process_absent "$pid" || continue
        inode=$(fm_backend_herdr_path_inode "$candidate") || continue
        identity_after=$(fm_backend_herdr_file_identity "$candidate" "$mode" owner 2>/dev/null) || continue
        [ "$identity_after" = "$identity_before" ] || continue
        fm_backend_herdr_process_absent "$pid" || continue
        fm_backend_herdr_server_lock_is_stale_age "$candidate" || continue
        fm_backend_herdr_artifact_remove_attributed "$candidate" "$inode" || return 1
        ;;
      2)
        identity_before=$(fm_backend_herdr_hardlink_pair_identity "$candidate" "$target" "$mode") || {
          if fm_backend_herdr_server_lock_is_stale_age "$candidate" \
            && fm_backend_herdr_process_absent "$pid"; then
            echo "error: refusing ambiguous Herdr published candidate pair: $candidate" >&2
            return 1
          fi
          continue
        }
        fm_backend_herdr_server_lock_is_stale_age "$candidate" || continue
        fm_backend_herdr_process_absent "$pid" || continue
        inode=$(fm_backend_herdr_path_inode "$candidate") || continue
        identity_after=$(fm_backend_herdr_hardlink_pair_identity "$candidate" "$target" "$mode") || return 1
        [ "$identity_after" = "$identity_before" ] || return 1
        fm_backend_herdr_process_absent "$pid" || continue
        fm_backend_herdr_server_lock_is_stale_age "$candidate" || continue
        if fm_backend_herdr_test_hooks_enabled \
          && [ "${FM_TEST_HERDR_ARTIFACT_PAIR_TARGET:-}" = "$target" ] \
          && [ -n "${FM_TEST_HERDR_ARTIFACT_PAIR_READY:-}" ] \
          && [ -n "${FM_TEST_HERDR_ARTIFACT_PAIR_PROCEED:-}" ]; then
          : > "$FM_TEST_HERDR_ARTIFACT_PAIR_READY"
          while [ ! -e "$FM_TEST_HERDR_ARTIFACT_PAIR_PROCEED" ]; do
            fm_backend_herdr_control_exec sleep 0.01
          done
        fi
        fm_backend_herdr_artifact_remove_attributed "$candidate" "$inode" || return 1
        target_after=$(fm_backend_herdr_file_identity "$target" "$mode" owner 2>/dev/null) || return 1
        if [ "$target_after" != "$identity_after" ]; then
          echo "error: Herdr published target changed during candidate recovery: $target" >&2
          return 1
        fi
        ;;
      *)
        if fm_backend_herdr_server_lock_is_stale_age "$candidate" \
          && fm_backend_herdr_process_absent "$pid"; then
          echo "error: refusing Herdr candidate with ambiguous link count: $candidate" >&2
          return 1
        fi
        ;;
    esac
  done
}

fm_backend_herdr_managed_shell_bin() {
  local source source_identity digest target target_identity publication candidate candidate_inode kill_after_link=
  fm_backend_herdr_server_lock_root_prepare || return 1
  source=$(fm_backend_herdr_managed_shell_source) || return 1
  source_identity=$(fm_backend_herdr_file_identity "$source" executable root-or-owner) || return 1
  digest=${source_identity%%$'\n'*}
  target=$(fm_backend_herdr_managed_shell_path_for_digest "$digest") || return 1
  fm_backend_herdr_artifact_recover_candidates "$target" 0500 || return 1
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    # Copy through O_NOFOLLOW descriptors, publish with a no-overwrite hard
    # link, and verify both the source snapshot and installed digest. A racing
    # installer may win the link; both converge on the same content address.
    if fm_backend_herdr_test_hooks_enabled \
      && [ -n "${FM_TEST_HERDR_KILL_AFTER_HELPER_LINK:-}" ]; then
      kill_after_link=$FM_TEST_HERDR_KILL_AFTER_HELPER_LINK
    fi
    # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
    publication=$(fm_backend_herdr_control_perl -MDigest::SHA -MFcntl=:DEFAULT -MIO::Handle -e '
      my ($source, $target, $expected_digest, $kill_after_link) = @ARGV;
      my $nofollow = eval { O_NOFOLLOW() };
      defined $nofollow or die "O_NOFOLLOW unavailable";
      sysopen my $input, $source, O_RDONLY | $nofollow or die "source: $!";
      my @before = stat($input);
      @before && -f $input && $before[3] == 1 or die "source identity";
      my $payload = "";
      my $sha = Digest::SHA->new(256);
      while (1) {
        my $count = sysread($input, my $chunk, 65536);
        defined $count or die "source read: $!";
        last unless $count;
        $payload .= $chunk;
        $sha->add($chunk);
      }
      my @after = stat($input);
      for my $index (0, 1, 2, 3, 4, 7, 9) {
        $before[$index] == $after[$index] or die "source changed";
      }
      my @source_path = lstat($source);
      ($source_path[0] == $after[0] && $source_path[1] == $after[1])
        or die "source path changed";
      $sha->hexdigest eq $expected_digest or die "source digest changed";
      close $input or die "source close: $!";
      my $candidate = "$target.candidate.$$";
      sysopen my $output, $candidate,
        O_WRONLY | O_CREAT | O_EXCL | $nofollow, 0500 or die "candidate: $!";
      chmod 0500, $candidate or die "candidate mode: $!";
      my $offset = 0;
      while ($offset < length $payload) {
        my $count = syswrite($output, $payload, length($payload) - $offset, $offset);
        defined $count && $count > 0 or die "candidate write: $!";
        $offset += $count;
      }
      $output->flush or die "candidate flush: $!";
      $output->sync or die "candidate sync: $!";
      my @candidate = stat($output);
      close $output or die "candidate close: $!";
      my $published = link($candidate, $target);
      if (!$published) {
        die "publish: $!" unless -e $target;
      }
      if ($published && length $kill_after_link) {
        sysopen my $marker, $kill_after_link, O_WRONLY | O_CREAT | O_EXCL, 0600
          or die "kill marker: $!";
        close $marker or die "kill marker close: $!";
        kill "KILL", $$;
        die "post-link kill failed";
      }
      my @candidate_path = lstat($candidate);
      @candidate_path && $candidate_path[0] == $candidate[0]
        && $candidate_path[1] == $candidate[1] or die "candidate replaced";
      print "$candidate\n$candidate[0]:$candidate[1]\n";
    ' "$source" "$target" "$digest" "$kill_after_link") || return 1
    case "$publication" in *$'\n'*) ;; *) return 1 ;; esac
    candidate=${publication%%$'\n'*}
    candidate_inode=${publication#*$'\n'}
    case "$candidate_inode" in ''|*$'\n'*|*[!0-9:]*) return 1 ;; esac
    fm_backend_herdr_artifact_remove_attributed "$candidate" "$candidate_inode" || return 1
  fi
  target_identity=$(fm_backend_herdr_file_identity "$target" 0500 owner) || return 1
  [ "${target_identity%%$'\n'*}" = "$digest" ] || return 1
  [ "$(fm_backend_herdr_file_identity "$source" executable root-or-owner)" = "$source_identity" ] || return 1
  printf '%s\n' "$target"
}

fm_backend_herdr_managed_config_path() {  # <session> [managed-shell]
  local root key shell_bin shell_proof shell_digest
  fm_backend_herdr_server_lock_root_prepare || return 1
  root=$(fm_backend_herdr_server_lock_root) || return 1
  key=$(fm_backend_herdr_server_lock_key "$1") || return 1
  shell_bin=${2:-}
  [ -n "$shell_bin" ] || shell_bin=$(fm_backend_herdr_managed_shell_bin) || return 1
  shell_proof=$(fm_backend_herdr_file_identity "$shell_bin" 0500 owner) || return 1
  shell_digest=${shell_proof%%$'\n'*}
  printf '%s/%s.closed-shell-config-v2-%s.toml\n' "$root" "$key" "$shell_digest"
}

fm_backend_herdr_managed_config_expected() {  # [managed-shell]
  local shell_bin=${1:-}
  [ -n "$shell_bin" ] || shell_bin=$(fm_backend_herdr_managed_shell_bin) || return 1
  # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
  fm_backend_herdr_control_perl -e '
    my $shell = $ARGV[0];
    exit 1 if $shell =~ /[\x00-\x1f\x7f]/;
    $shell =~ s/\\/\\\\/g;
    $shell =~ s/"/\\"/g;
    print "onboarding = false\n",
      "[terminal]\n",
      "default_shell = \"$shell\"\n",
      "shell_mode = \"non_login\"\n",
      "[session]\n",
      "resume_agents_on_restore = false\n";
  ' "$shell_bin"
}

fm_backend_herdr_managed_config_ready() {  # <session> [managed-shell]
  local path expected snapshot actual
  path=$(fm_backend_herdr_managed_config_path "$1" "${2:-}") || return 1
  expected=$(fm_backend_herdr_managed_config_expected "${2:-}") || return 1
  snapshot=$(fm_backend_herdr_file_snapshot "$path" 0600 owner) || return 1
  snapshot=${snapshot#*$'\n'}
  actual=${snapshot#*$'\n'}
  [ "$actual" = "$expected" ]
}

fm_backend_herdr_managed_config_ensure() {  # <session> [managed-shell]; prints path
  local path expected shell_bin publication candidate candidate_inode kill_after_link=
  shell_bin=${2:-}
  [ -n "$shell_bin" ] || shell_bin=$(fm_backend_herdr_managed_shell_bin) || return 1
  path=$(fm_backend_herdr_managed_config_path "$1" "$shell_bin") || return 1
  expected=$(fm_backend_herdr_managed_config_expected "$shell_bin") || return 1
  fm_backend_herdr_artifact_recover_candidates "$path" 0600 || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_backend_herdr_managed_config_ready "$1" "$shell_bin" || return 1
    printf '%s\n' "$path"
    return 0
  fi
  if fm_backend_herdr_test_hooks_enabled \
    && [ -n "${FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK:-}" ]; then
    kill_after_link=$FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK
  fi
  # shellcheck disable=SC2016  # Dollar expressions belong to Perl.
  publication=$(fm_backend_herdr_control_perl -MFcntl=:DEFAULT -MIO::Handle -e '
    my ($path, $payload, $kill_after_link) = @ARGV;
    my $candidate = "$path.candidate.$$";
    sysopen my $fh, $candidate, O_WRONLY | O_CREAT | O_EXCL, 0600 or die $!;
    chmod 0600, $candidate or die $!;
    print {$fh} $payload, "\n" or die $!;
    $fh->flush or die $!;
    $fh->sync or die $!;
    close $fh or die $!;
    my $published = link($candidate, $path);
    if (!$published) {
      die $! unless -e $path;
    }
    if ($published && length $kill_after_link) {
      sysopen my $marker, $kill_after_link, O_WRONLY | O_CREAT | O_EXCL, 0600
        or die "kill marker: $!";
      close $marker or die "kill marker close: $!";
      kill "KILL", $$;
      die "post-link kill failed";
    }
    my @candidate = lstat($candidate);
    @candidate or die "candidate identity: $!";
    print "$candidate\n$candidate[0]:$candidate[1]\n";
  ' "$path" "$expected" "$kill_after_link") || return 1
  case "$publication" in *$'\n'*) ;; *) return 1 ;; esac
  candidate=${publication%%$'\n'*}
  candidate_inode=${publication#*$'\n'}
  case "$candidate_inode" in ''|*$'\n'*|*[!0-9:]*) return 1 ;; esac
  fm_backend_herdr_artifact_remove_attributed "$candidate" "$candidate_inode" || return 1
  fm_backend_herdr_managed_config_ready "$1" "$shell_bin" || return 1
  printf '%s\n' "$path"
}

# Prove that the live server process for this session was launched by the
# adapter's env-i path. Herdr panes inherit the server environment, so routed
# workers may enter a pane only while this process-bound certificate remains
# valid. A restored/manual/older server has no usable proof and fails closed.
fm_backend_herdr_server_closed_shell_environment_ready() {  # <session>
  local session=$1 certificate key certificate_snapshot payload schema recorded_key pid start current
  local managed_shell managed_shell_digest managed_shell_identity managed_shell_proof expected_shell
  local source source_proof source_digest managed_config managed_config_digest managed_config_identity expected_config
  local config_snapshot config_proof_digest config_proof_identity config_payload expected_config_payload
  certificate=$(fm_backend_herdr_server_env_certificate_path "$session") || return 1
  key=$(fm_backend_herdr_server_lock_key "$session") || return 1
  certificate_snapshot=$(fm_backend_herdr_file_snapshot "$certificate" 0600 owner) || return 1
  certificate_snapshot=${certificate_snapshot#*$'\n'}
  payload=${certificate_snapshot#*$'\n'}
  schema=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  recorded_key=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  pid=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  start=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  managed_shell=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  managed_shell_digest=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  managed_shell_identity=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  managed_config=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  managed_config_digest=${payload%%$'\n'*}
  managed_config_identity=${payload#*$'\n'}
  case "$managed_config_identity" in ''|*$'\n'*) return 1 ;; esac
  [ "$schema" = firstmate-herdr-closed-env-v2 ] \
    && [ "$recorded_key" = "$key" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$start" ] || return 1
  expected_shell=$(fm_backend_herdr_managed_shell_path_for_digest "$managed_shell_digest") || return 1
  [ "$managed_shell" = "$expected_shell" ] || return 1
  managed_shell_proof=$(fm_backend_herdr_file_identity "$managed_shell" 0500 owner) || return 1
  [ "${managed_shell_proof%%$'\n'*}" = "$managed_shell_digest" ] \
    && [ "${managed_shell_proof#*$'\n'}" = "$managed_shell_identity" ] || return 1
  # An fm-update that changes the reviewed source wrapper invalidates an old
  # live server even though its immutable content-addressed copy still exists.
  # The adapter must restart that server while idle before routing any worker.
  source=$(fm_backend_herdr_managed_shell_source) || return 1
  source_proof=$(fm_backend_herdr_file_identity "$source" executable root-or-owner) || return 1
  source_digest=${source_proof%%$'\n'*}
  [ "$source_digest" = "$managed_shell_digest" ] || return 1
  expected_config=$(fm_backend_herdr_managed_config_path "$session" "$managed_shell") || return 1
  [ "$managed_config" = "$expected_config" ] || return 1
  config_snapshot=$(fm_backend_herdr_file_snapshot "$managed_config" 0600 owner) || return 1
  config_proof_digest=${config_snapshot%%$'\n'*}
  config_snapshot=${config_snapshot#*$'\n'}
  config_proof_identity=${config_snapshot%%$'\n'*}
  config_payload=${config_snapshot#*$'\n'}
  [ "$config_proof_digest" = "$managed_config_digest" ] \
    && [ "$config_proof_identity" = "$managed_config_identity" ] || return 1
  expected_config_payload=$(fm_backend_herdr_managed_config_expected "$managed_shell") || return 1
  [ "$config_payload" = "$expected_config_payload" ] || return 1
  current=$(fm_backend_herdr_process_start "$pid") || return 1
  [ "$current" = "$start" ]
}

# Establish only lifecycle ownership, independently from the stronger current-
# release helper/config proof above. This permits a server launched by the
# immediately preceding adapter release to be restarted after an update, while
# a manual or forged/unreadable server remains ineligible for automatic stop.
fm_backend_herdr_server_adapter_owned() {  # <session>
  local session=$1 certificate key snapshot payload schema recorded_key pid start current
  key=$(fm_backend_herdr_server_lock_key "$session") || return 1
  certificate=$(fm_backend_herdr_server_env_certificate_path "$session") || return 1
  if [ ! -e "$certificate" ] && [ ! -L "$certificate" ]; then
    certificate=$(fm_backend_herdr_server_legacy_env_certificate_path "$session") || return 1
  fi
  snapshot=$(fm_backend_herdr_file_snapshot "$certificate" 0600 owner) || return 1
  snapshot=${snapshot#*$'\n'}
  payload=${snapshot#*$'\n'}
  schema=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  recorded_key=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  pid=${payload%%$'\n'*}
  payload=${payload#*$'\n'}
  start=${payload%%$'\n'*}
  case "$schema" in
    firstmate-herdr-closed-env-v1|firstmate-herdr-closed-env-v2) ;;
    *) return 1 ;;
  esac
  [ "$recorded_key" = "$key" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$start" ] || return 1
  current=$(fm_backend_herdr_process_start "$pid") || return 1
  [ "$current" = "$start" ]
}

fm_backend_herdr_server_lock_file_ready() {  # <lock>
  local mode links
  mode=$(fm_backend_herdr_path_mode "$1") || return 1
  links=$(fm_backend_herdr_path_nlink "$1") || return 1
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] \
    && [ "$mode" = 600 ] && [ "$links" -eq 1 ]
}

FM_BACKEND_HERDR_SERVER_OWNER_PID=
FM_BACKEND_HERDR_SERVER_OWNER_START=
FM_BACKEND_HERDR_SERVER_OWNER_TOKEN=
FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT=
fm_backend_herdr_server_lock_owner_read() {  # <lock>
  local owner=$1 mode payload line_count inode_before inode_after links PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  FM_BACKEND_HERDR_SERVER_OWNER_PID=
  FM_BACKEND_HERDR_SERVER_OWNER_START=
  FM_BACKEND_HERDR_SERVER_OWNER_TOKEN=
  FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT=
  [ -f "$owner" ] && [ ! -L "$owner" ] && [ -O "$owner" ] || return 1
  mode=$(fm_backend_herdr_path_mode "$owner") || return 1
  [ "$mode" = 600 ] || return 1
  links=$(fm_backend_herdr_path_nlink "$owner") || return 1
  [ "$links" -eq 1 ] || [ "$links" -eq 2 ] || return 1
  inode_before=$(fm_backend_herdr_path_inode "$owner") || return 1
  payload=$(fm_backend_herdr_control_exec cat "$owner" 2>/dev/null) || return 1
  inode_after=$(fm_backend_herdr_path_inode "$owner") || return 1
  [ "$inode_before" = "$inode_after" ] || return 1
  line_count=$(printf '%s\n' "$payload" | fm_backend_herdr_control_exec awk 'END { print NR }')
  [ "$line_count" -eq 3 ] || return 1
  FM_BACKEND_HERDR_SERVER_OWNER_PID=$(printf '%s\n' "$payload" | fm_backend_herdr_control_exec sed -n '1p')
  FM_BACKEND_HERDR_SERVER_OWNER_START=$(printf '%s\n' "$payload" | fm_backend_herdr_control_exec sed -n '2p')
  FM_BACKEND_HERDR_SERVER_OWNER_TOKEN=$(printf '%s\n' "$payload" | fm_backend_herdr_control_exec sed -n '3p')
  case "$FM_BACKEND_HERDR_SERVER_OWNER_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$FM_BACKEND_HERDR_SERVER_OWNER_START" ] || return 1
  case "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT=$payload
}

# Return 0 only for the same live process, 1 only when ps proves that the PID
# is absent or reused, 2 for an indeterminate process probe, and 3 for an
# incomplete owner record. Indeterminate probes are never treated as stale.
fm_backend_herdr_server_lock_owner_state() {  # <lock>
  local probe_status probe ps_bin PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  fm_backend_herdr_server_lock_owner_read "$1" || return 3
  ps_bin=$(fm_backend_herdr_ps_bin) || return 2
  probe=$(LC_ALL=C fm_backend_herdr_scrubbed_exec "$ps_bin" -o lstart= -p "$FM_BACKEND_HERDR_SERVER_OWNER_PID" 2>&1)
  probe_status=$?
  probe=$(printf '%s\n' "$probe" | fm_backend_herdr_control_exec sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$probe_status" -eq 0 ]; then
    [ -n "$probe" ] || return 2
    [ "$probe" = "$FM_BACKEND_HERDR_SERVER_OWNER_START" ] && return 0
    return 1
  fi
  [ -n "$probe" ] && return 2
  return 1
}

fm_backend_herdr_server_lock_has_quarantine() {  # <lock>
  local candidate
  for candidate in "$1".stale.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    return 0
  done
  fm_backend_herdr_artifact_has_quarantine "$1" && return 0
  return 1
}

fm_backend_herdr_server_lock_token() {
  local PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  printf '%s-%s-%s%s\n' "${BASHPID:-$$}" "$(fm_backend_herdr_control_exec date +%s)" "${RANDOM:-0}" "${RANDOM:-0}"
}

fm_backend_herdr_server_lock_stale_seconds() {
  local seconds=${FM_BACKEND_HERDR_SERVER_LOCK_STALE_SECONDS:-11}
  case "$seconds" in
    ''|*[!0-9]*)
      echo "error: FM_BACKEND_HERDR_SERVER_LOCK_STALE_SECONDS must be an integer of at least 11" >&2
      return 1
      ;;
  esac
  [ "$seconds" -ge 11 ] || {
    echo "error: FM_BACKEND_HERDR_SERVER_LOCK_STALE_SECONDS must cover the 10-second Herdr startup window" >&2
    return 1
  }
  printf '%s\n' "$seconds"
}

fm_backend_herdr_server_lock_is_stale_age() {  # <path>
  local path=$1 age seconds
  age=$(fm_backend_herdr_path_age "$path") || return 1
  seconds=$(fm_backend_herdr_server_lock_stale_seconds) || return 1
  [ "$age" -ge "$seconds" ]
}

fm_backend_herdr_server_lock_mark_launch_epoch() {  # <lock> <token> <inode>
  local lock=$1 token=$2 expected_inode=$3 pid current_start PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  fm_backend_herdr_server_lock_file_ready "$lock" || return 1
  [ "$(fm_backend_herdr_path_inode "$lock" 2>/dev/null)" = "$expected_inode" ] || return 1
  fm_backend_herdr_server_lock_owner_read "$lock" || return 1
  pid=${BASHPID:-$$}
  current_start=$(fm_backend_herdr_process_start "$pid") || return 1
  [ "$FM_BACKEND_HERDR_SERVER_OWNER_PID" = "$pid" ] \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_START" = "$current_start" ] \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" = "$token" ] || return 1
  fm_backend_herdr_control_exec touch "$lock" 2>/dev/null || return 1
  [ "$(fm_backend_herdr_path_inode "$lock" 2>/dev/null)" = "$expected_inode" ] \
    && fm_backend_herdr_server_lock_file_ready "$lock" \
    && fm_backend_herdr_server_lock_owner_read "$lock" \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_PID" = "$pid" ] \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_START" = "$current_start" ] \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" = "$token" ]
}

fm_backend_herdr_server_lock_remove_exact() {  # <path> <inode>
  fm_backend_herdr_artifact_remove_attributed "$1" "$2"
}

# Resume an interrupted attributed deletion of a lifecycle lock, lock
# candidate, or stale-lock quarantine. Authorization mirrors ordinary stale
# lock recovery: a present generation must be proven dead/reused or malformed
# and stale twice; a post-unlink empty quarantine can only be removed after its
# own private descriptor identity and stale age are repeated.
fm_backend_herdr_server_lock_recover_attributed() {  # <path> <quarantine>
  local path=$1 quarantine=$2 key expected_inode quarantine_snapshot contents artifact
  local artifact_inode state snapshot current_state PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  case "$quarantine" in "$path".quarantine.*) ;; *) return 1 ;; esac
  key=${quarantine##*.quarantine.}
  case "$key" in ''|*[!0-9_]*|_*|*_|*_*_*) return 1 ;; esac
  expected_inode=${key/_/:}
  quarantine_snapshot=$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine") \
    || return 1
  contents=${quarantine_snapshot#*$'\n'}
  fm_backend_herdr_server_lock_is_stale_age "$quarantine" || return 1
  case "$contents" in
    empty)
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        artifact=
      else
        artifact=$path
      fi
      ;;
    artifact)
      [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
      artifact="$quarantine/artifact"
      ;;
    *) return 1 ;;
  esac
  if [ -n "$artifact" ]; then
    artifact_inode=$(fm_backend_herdr_path_inode "$artifact" 2>/dev/null) || return 1
    [ "$artifact_inode" = "$expected_inode" ] || return 1
    if fm_backend_herdr_server_lock_owner_state "$artifact"; then state=0; else state=$?; fi
    snapshot=$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT
    case "$state" in
      1|3) fm_backend_herdr_server_lock_is_stale_age "$artifact" || return 1 ;;
      *) return 1 ;;
    esac
    [ "$(fm_backend_herdr_path_inode "$artifact" 2>/dev/null)" = "$artifact_inode" ] \
      || return 1
    if [ "$state" -eq 1 ]; then
      if fm_backend_herdr_server_lock_owner_state "$artifact"; then current_state=0; else current_state=$?; fi
      [ "$current_state" -eq 1 ] \
        && [ "$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT" = "$snapshot" ] || return 1
    else
      fm_backend_herdr_server_lock_owner_read "$artifact" && return 1
      fm_backend_herdr_server_lock_is_stale_age "$artifact" || return 1
    fi
  fi
  [ "$(fm_backend_herdr_artifact_quarantine_snapshot "$quarantine")" = "$quarantine_snapshot" ] \
    || return 1
  fm_backend_herdr_server_lock_is_stale_age "$quarantine" || return 1
  fm_backend_herdr_artifact_resume_attributed "$path" "$expected_inode"
}

fm_backend_herdr_server_lock_cleanup_initialization() {  # <lock> <inode> <token>
  local lock=$1 expected_inode=$2 token=$3
  [ "$(fm_backend_herdr_path_inode "$lock" 2>/dev/null)" = "$expected_inode" ] || return 1
  fm_backend_herdr_server_lock_owner_read "$lock" || return 1
  [ "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" = "$token" ] || return 1
  fm_backend_herdr_server_lock_remove_exact "$lock" "$expected_inode"
}

FM_BACKEND_HERDR_SERVER_LOCK_TOKEN=
FM_BACKEND_HERDR_SERVER_LOCK_INODE=
fm_backend_herdr_server_lock_try_create() {  # <lock>
  local lock=$1 pid start token inode candidate lock_inode PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  FM_BACKEND_HERDR_SERVER_LOCK_TOKEN=
  FM_BACKEND_HERDR_SERVER_LOCK_INODE=
  pid=${BASHPID:-$$}
  start=$(fm_backend_herdr_process_start "$pid") || return 1
  token=$(fm_backend_herdr_server_lock_token) || return 1
  fm_backend_herdr_server_lock_has_quarantine "$lock" && return 1
  candidate="$lock.candidate.$token"
  (umask 077; set -C; printf '%s\n%s\n%s\n' "$pid" "$start" "$token" > "$candidate") \
    2>/dev/null || return 1
  fm_backend_herdr_control_exec chmod 600 "$candidate" 2>/dev/null || {
    fm_backend_herdr_control_exec rm -f "$candidate" 2>/dev/null || true
    return 1
  }
  inode=$(fm_backend_herdr_path_inode "$candidate") || {
    fm_backend_herdr_control_exec rm -f "$candidate" 2>/dev/null || true
    return 1
  }
  if ! fm_backend_herdr_server_lock_file_ready "$candidate" \
    || ! fm_backend_herdr_server_lock_owner_read "$candidate" \
    || [ "$FM_BACKEND_HERDR_SERVER_OWNER_PID" != "$pid" ] \
    || [ "$FM_BACKEND_HERDR_SERVER_OWNER_START" != "$start" ] \
    || [ "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" != "$token" ]; then
    fm_backend_herdr_server_lock_remove_exact "$candidate" "$inode" >/dev/null 2>&1 || true
    return 1
  fi
  if fm_backend_herdr_test_hooks_enabled \
    && [ -n "${FM_TEST_HERDR_CANDIDATE_READY_FILE:-}" ]; then
    : > "$FM_TEST_HERDR_CANDIDATE_READY_FILE"
  fi
  if fm_backend_herdr_test_hooks_enabled \
    && [ -n "${FM_TEST_HERDR_CANDIDATE_RELEASE_FILE:-}" ]; then
    while [ ! -e "$FM_TEST_HERDR_CANDIDATE_RELEASE_FILE" ]; do fm_backend_herdr_control_exec sleep 0.01; done
  fi
  if fm_backend_herdr_server_lock_has_quarantine "$lock" \
    || ! fm_backend_herdr_control_exec ln "$candidate" "$lock" 2>/dev/null; then
    fm_backend_herdr_server_lock_remove_exact "$candidate" "$inode" >/dev/null 2>&1 || true
    return 1
  fi
  lock_inode=$(fm_backend_herdr_path_inode "$lock") || lock_inode=
  if [ "$lock_inode" != "$inode" ]; then
    fm_backend_herdr_server_lock_remove_exact "$candidate" "$inode" >/dev/null 2>&1 || true
    return 1
  fi
  if fm_backend_herdr_test_hooks_enabled \
    && [ -n "${FM_TEST_HERDR_KILL_AFTER_LOCK_LINK:-}" ]; then
    : > "$FM_TEST_HERDR_KILL_AFTER_LOCK_LINK"
    kill -KILL "${BASHPID:-$$}"
  fi
  if ! fm_backend_herdr_server_lock_remove_exact "$candidate" "$inode"; then
    fm_backend_herdr_server_lock_remove_exact "$lock" "$inode" >/dev/null 2>&1 || true
    return 1
  fi
  if ! fm_backend_herdr_server_lock_file_ready "$lock" \
    || ! fm_backend_herdr_server_lock_owner_read "$lock" \
    || [ "$FM_BACKEND_HERDR_SERVER_OWNER_PID" != "$pid" ] \
    || [ "$FM_BACKEND_HERDR_SERVER_OWNER_START" != "$start" ] \
    || [ "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" != "$token" ] \
    || fm_backend_herdr_server_lock_has_quarantine "$lock"; then
    fm_backend_herdr_server_lock_cleanup_initialization "$lock" "$inode" "$token" \
      >/dev/null 2>&1 || true
    return 1
  fi
  FM_BACKEND_HERDR_SERVER_LOCK_TOKEN=$token
  FM_BACKEND_HERDR_SERVER_LOCK_INODE=$inode
}

fm_backend_herdr_server_lock_restore_quarantine() {  # <quarantine> <lock>
  local PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  [ ! -e "$2" ] && [ ! -L "$2" ] || return 1
  fm_backend_herdr_control_exec mv "$1" "$2" 2>/dev/null
}

fm_backend_herdr_server_lock_remove_quarantine() {  # <quarantine>
  local quarantine=$1 inode
  inode=$(fm_backend_herdr_path_inode "$quarantine") || return 1
  fm_backend_herdr_server_lock_remove_exact "$quarantine" "$inode"
}

fm_backend_herdr_server_lock_recover_candidates() {  # <lock>
  local lock=$1 candidate quarantine inode state snapshot current_state
  for quarantine in "$lock".candidate.*.quarantine.*; do
    [ -e "$quarantine" ] || [ -L "$quarantine" ] || continue
    candidate=${quarantine%.quarantine.*}
    fm_backend_herdr_server_lock_recover_attributed "$candidate" "$quarantine" || return 1
  done
  for candidate in "$lock".candidate.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    case "$candidate" in *.quarantine.*) continue ;; esac
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -O "$candidate" ] || return 1
    inode=$(fm_backend_herdr_path_inode "$candidate") || return 1
    if fm_backend_herdr_server_lock_owner_state "$candidate"; then state=0; else state=$?; fi
    snapshot=$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT
    case "$state" in
      0|2) continue ;;
      1|3) fm_backend_herdr_server_lock_is_stale_age "$candidate" || continue ;;
      *) return 1 ;;
    esac
    [ "$(fm_backend_herdr_path_inode "$candidate" 2>/dev/null)" = "$inode" ] || return 1
    if [ "$state" -eq 1 ]; then
      if fm_backend_herdr_server_lock_owner_state "$candidate"; then current_state=0; else current_state=$?; fi
      [ "$current_state" -eq 1 ] \
        && [ "$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT" = "$snapshot" ] || return 1
    else
      fm_backend_herdr_server_lock_owner_read "$candidate" && return 1
      fm_backend_herdr_server_lock_is_stale_age "$candidate" || return 1
    fi
    fm_backend_herdr_server_lock_remove_exact "$candidate" "$inode" || return 1
  done
}

fm_backend_herdr_server_lock_try_reclaim() {  # <lock>
  local lock=$1 inode state snapshot quarantine quarantine_token current_state PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  [ -f "$lock" ] && [ ! -L "$lock" ] && [ -O "$lock" ] || return 1
  inode=$(fm_backend_herdr_path_inode "$lock") || return 1
  if fm_backend_herdr_server_lock_owner_state "$lock"; then state=0; else state=$?; fi
  snapshot=$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT
  case "$state" in
    1|3) fm_backend_herdr_server_lock_is_stale_age "$lock" || return 1 ;;
    *) return 1 ;;
  esac
  [ "$(fm_backend_herdr_path_inode "$lock" 2>/dev/null)" = "$inode" ] || return 1
  if [ "$state" -eq 1 ]; then
    if fm_backend_herdr_server_lock_owner_state "$lock"; then current_state=0; else current_state=$?; fi
    [ "$current_state" -eq 1 ] \
      && [ "$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT" = "$snapshot" ] || return 1
  else
    fm_backend_herdr_server_lock_owner_read "$lock" && return 1
    fm_backend_herdr_server_lock_is_stale_age "$lock" || return 1
  fi
  quarantine_token=$(fm_backend_herdr_server_lock_token) || return 1
  quarantine="$lock.stale.$quarantine_token"
  fm_backend_herdr_control_exec mv "$lock" "$quarantine" 2>/dev/null || return 1
  if fm_backend_herdr_test_hooks_enabled \
    && [ -n "${FM_TEST_HERDR_KILL_AFTER_QUARANTINE_RENAME:-}" ]; then
    : > "$FM_TEST_HERDR_KILL_AFTER_QUARANTINE_RENAME"
    kill -KILL "${BASHPID:-$$}"
  fi
  if [ "$(fm_backend_herdr_path_inode "$quarantine" 2>/dev/null)" != "$inode" ]; then
    fm_backend_herdr_server_lock_restore_quarantine "$quarantine" "$lock" >/dev/null 2>&1 || true
    return 2
  fi
  if [ "$state" -eq 1 ]; then
    if fm_backend_herdr_server_lock_owner_state "$quarantine"; then current_state=0; else current_state=$?; fi
    if [ "$current_state" -ne 1 ] \
      || [ "$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT" != "$snapshot" ]; then
      fm_backend_herdr_server_lock_restore_quarantine "$quarantine" "$lock" >/dev/null 2>&1 || true
      return 2
    fi
  else
    if fm_backend_herdr_server_lock_owner_read "$quarantine"; then
      fm_backend_herdr_server_lock_restore_quarantine "$quarantine" "$lock" >/dev/null 2>&1 || true
      return 2
    fi
    if ! fm_backend_herdr_server_lock_is_stale_age "$quarantine"; then
      fm_backend_herdr_server_lock_restore_quarantine "$quarantine" "$lock" >/dev/null 2>&1 || true
      return 2
    fi
  fi
  fm_backend_herdr_server_lock_remove_quarantine "$quarantine" || return 2
}

fm_backend_herdr_server_lock_recover_quarantine() {  # <quarantine> <lock>
  local quarantine=$1 lock=$2 inode state snapshot current_state PATH=$FM_BACKEND_HERDR_CONTROL_PATH
  [ -f "$quarantine" ] && [ ! -L "$quarantine" ] && [ -O "$quarantine" ] || return 1
  inode=$(fm_backend_herdr_path_inode "$quarantine") || return 1
  if fm_backend_herdr_server_lock_owner_state "$quarantine"; then state=0; else state=$?; fi
  snapshot=$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT
  case "$state" in
    0|2)
      [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 1
      [ "$(fm_backend_herdr_path_inode "$quarantine" 2>/dev/null)" = "$inode" ] || return 1
      fm_backend_herdr_server_lock_owner_read "$quarantine" || return 1
      [ "$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT" = "$snapshot" ] || return 1
      fm_backend_herdr_control_exec mv "$quarantine" "$lock" 2>/dev/null || return 1
      [ "$(fm_backend_herdr_path_inode "$lock" 2>/dev/null)" = "$inode" ] || return 1
      ;;
    1|3)
      fm_backend_herdr_server_lock_is_stale_age "$quarantine" || return 1
      [ "$(fm_backend_herdr_path_inode "$quarantine" 2>/dev/null)" = "$inode" ] || return 1
      if [ "$state" -eq 1 ]; then
        if fm_backend_herdr_server_lock_owner_state "$quarantine"; then current_state=0; else current_state=$?; fi
        [ "$current_state" -eq 1 ] \
          && [ "$FM_BACKEND_HERDR_SERVER_OWNER_SNAPSHOT" = "$snapshot" ] || return 1
      else
        fm_backend_herdr_server_lock_owner_read "$quarantine" && return 1
      fi
      fm_backend_herdr_server_lock_remove_quarantine "$quarantine" || return 1
      ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_server_lock_recover_quarantines() {  # <lock>
  local lock=$1 quarantine attributed
  for quarantine in "$lock".quarantine.*; do
    [ -e "$quarantine" ] || [ -L "$quarantine" ] || continue
    fm_backend_herdr_server_lock_recover_attributed "$lock" "$quarantine" || return 1
  done
  for quarantine in "$lock".stale.*.quarantine.*; do
    [ -e "$quarantine" ] || [ -L "$quarantine" ] || continue
    attributed=${quarantine%.quarantine.*}
    fm_backend_herdr_server_lock_recover_attributed "$attributed" "$quarantine" || return 1
  done
  for quarantine in "$lock".stale.*; do
    [ -e "$quarantine" ] || [ -L "$quarantine" ] || continue
    case "$quarantine" in *.quarantine.*) continue ;; esac
    fm_backend_herdr_server_lock_recover_quarantine "$quarantine" "$lock" || return 1
  done
  fm_backend_herdr_server_lock_has_quarantine "$lock" && return 1
  return 0
}

fm_backend_herdr_server_lock_release() {  # <lock> <token> [inode]
  local lock=$1 token=$2 expected_inode=${3:-} pid current_start
  fm_backend_herdr_server_lock_file_ready "$lock" || return 1
  [ -n "$expected_inode" ] || expected_inode=$(fm_backend_herdr_path_inode "$lock") || return 1
  if [ -n "$expected_inode" ]; then
    [ "$(fm_backend_herdr_path_inode "$lock" 2>/dev/null)" = "$expected_inode" ] || return 1
  fi
  fm_backend_herdr_server_lock_owner_read "$lock" || return 1
  pid=${BASHPID:-$$}
  current_start=$(fm_backend_herdr_process_start "$pid") || return 1
  [ "$FM_BACKEND_HERDR_SERVER_OWNER_PID" = "$pid" ] \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_START" = "$current_start" ] \
    && [ "$FM_BACKEND_HERDR_SERVER_OWNER_TOKEN" = "$token" ] || return 1
  fm_backend_herdr_server_lock_remove_exact "$lock" "$expected_inode"
}

fm_backend_herdr_server_lock_try_acquire() {  # <lock>
  local lock=$1
  fm_backend_herdr_server_lock_recover_candidates "$lock" || return 1
  fm_backend_herdr_server_lock_recover_quarantines "$lock" || return 1
  fm_backend_herdr_server_lock_try_create "$lock" && return 0
  fm_backend_herdr_server_lock_try_reclaim "$lock" || return 1
  fm_backend_herdr_server_lock_try_create "$lock"
}

FM_BACKEND_HERDR_SERVER_LOCK=
fm_backend_herdr_server_lock_acquire() {  # <session> [launch|lifecycle]; launch rc=2 means server became ready
  local session=$1 purpose=${2:-launch} root key lock attempt wait_steps running
  FM_BACKEND_HERDR_SERVER_LOCK=
  FM_BACKEND_HERDR_SERVER_LOCK_TOKEN=
  FM_BACKEND_HERDR_SERVER_LOCK_INODE=
  fm_backend_herdr_server_lock_root_prepare || return 1
  root=$(fm_backend_herdr_server_lock_root) || return 1
  key=$(fm_backend_herdr_server_lock_key "$session") || return 1
  lock="$root/$key.lock"
  wait_steps=${FM_BACKEND_HERDR_SERVER_LOCK_WAIT_STEPS:-300}
  case "$wait_steps" in ''|*[!0-9]*|0) echo "error: FM_BACKEND_HERDR_SERVER_LOCK_WAIT_STEPS must be a positive integer" >&2; return 1 ;; esac
  fm_backend_herdr_server_lock_stale_seconds >/dev/null || return 1
  case "$purpose" in launch|lifecycle) ;; *) return 1 ;; esac
  attempt=1
  while [ "$attempt" -le "$wait_steps" ]; do
    if fm_backend_herdr_server_lock_try_acquire "$lock"; then
      FM_BACKEND_HERDR_SERVER_LOCK=$lock
      return 0
    fi
    if [ "$purpose" = launch ]; then
      running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | fm_backend_herdr_control_jq -r '.server.running // false' 2>/dev/null)
      [ "$running" != true ] || return 2
    fi
    fm_backend_herdr_control_exec sleep 0.05
    attempt=$((attempt + 1))
  done
  echo "error: timed out waiting for the Herdr server launch lock for session '$session'" >&2
  return 1
}

fm_backend_herdr_server_exact_session_state() {  # <session>; prints empty|occupied|indeterminate
  local session=$1 payload count
  payload=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    printf 'indeterminate'
    return 0
  }
  count=$(printf '%s' "$payload" | fm_backend_herdr_control_jq -er \
    'if (.result.workspaces | type) == "array" then (.result.workspaces | length) else error("workspaces") end' \
    2>/dev/null) || { printf 'indeterminate'; return 0; }
  [ "$count" -eq 0 ] || { printf 'occupied'; return 0; }

  payload=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || {
    printf 'indeterminate'
    return 0
  }
  count=$(printf '%s' "$payload" | fm_backend_herdr_control_jq -er \
    'if (.result.tabs | type) == "array" then (.result.tabs | length) else error("tabs") end' \
    2>/dev/null) || { printf 'indeterminate'; return 0; }
  [ "$count" -eq 0 ] || { printf 'occupied'; return 0; }

  payload=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null) || {
    printf 'indeterminate'
    return 0
  }
  count=$(printf '%s' "$payload" | fm_backend_herdr_control_jq -er \
    'if (.result.panes | type) == "array" then (.result.panes | length) else error("panes") end' \
    2>/dev/null) || { printf 'indeterminate'; return 0; }
  [ "$count" -eq 0 ] && printf 'empty' || printf 'occupied'
}

# Stop only the exact, explicitly named session after two complete empty-state
# proofs and a repeated adapter-process ownership proof. Never use Herdr's
# ambient `server stop`, and never delete session state (including `default`).
fm_backend_herdr_server_stop_owned_empty() {  # <session>
  local session=$1 state running attempt false_count=0
  fm_backend_herdr_server_adapter_owned "$session" || return 1
  state=$(fm_backend_herdr_server_exact_session_state "$session") || return 1
  [ "$state" = empty ] || return 1
  fm_backend_herdr_server_adapter_owned "$session" || return 1
  state=$(fm_backend_herdr_server_exact_session_state "$session") || return 1
  [ "$state" = empty ] || return 1
  fm_backend_herdr_cli "$session" session stop "$session" --json >/dev/null 2>&1 || return 1
  attempt=1
  while [ "$attempt" -le 100 ]; do
    running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null \
      | fm_backend_herdr_control_jq -er 'if (.server.running | type) == "boolean" then (.server.running | tostring) else error("running") end' 2>/dev/null) \
      || running=indeterminate
    if [ "$running" = false ]; then
      false_count=$((false_count + 1))
      [ "$false_count" -lt 2 ] || return 0
    else
      false_count=0
    fi
    fm_backend_herdr_control_exec sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

# fm_backend_herdr_server_ensure: serialize the complete process/certificate
# lifecycle before any caller may inspect or create a workspace. A current
# certified server is reused. An adapter-owned but release-drifted server is
# restarted only when the exact named session is proven structurally empty;
# occupied, unreadable, or manual servers fail closed without mutation.
fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running
  running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | fm_backend_herdr_control_jq -r '.server.running // false' 2>/dev/null)
  if ! fm_backend_herdr_server_certificate_required; then
    [ "$running" = "true" ] && return 0
  fi
  (
    lock_status=0
    if fm_backend_herdr_server_certificate_required; then
      fm_backend_herdr_server_lock_acquire "$session" lifecycle || lock_status=$?
    else
      fm_backend_herdr_server_lock_acquire "$session" launch || lock_status=$?
    fi
    [ "$lock_status" -ne 2 ] || exit 0
    [ "$lock_status" -eq 0 ] || exit "$lock_status"
    server_lock=$FM_BACKEND_HERDR_SERVER_LOCK
    server_lock_token=$FM_BACKEND_HERDR_SERVER_LOCK_TOKEN
    server_lock_inode=$FM_BACKEND_HERDR_SERVER_LOCK_INODE
    # Invoked through the EXIT trap below.
    # shellcheck disable=SC2329
    cleanup_server_lock() {
      fm_backend_herdr_server_lock_release \
        "$server_lock" "$server_lock_token" "$server_lock_inode" >/dev/null 2>&1 || true
    }
    trap cleanup_server_lock EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Recheck under the per-session machine-local lock. Two FirstMate homes or
    # two simultaneous callers may both observe the server as absent, but only
    # the lifecycle owner is allowed to reuse, stop, or launch it.
    running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null \
      | fm_backend_herdr_control_jq -er 'if (.server.running | type) == "boolean" then (.server.running | tostring) else error("running") end' 2>/dev/null) \
      || running=indeterminate
    if [ "$running" = true ]; then
      if ! fm_backend_herdr_server_certificate_required; then
        exit 0
      fi
      if fm_backend_herdr_server_closed_shell_environment_ready "$session"; then
        exit 0
      fi
      if ! fm_backend_herdr_server_adapter_owned "$session"; then
        echo "error: refusing to replace an uncertified or manually launched Herdr server for exact session '$session'" >&2
        exit 1
      fi
      exact_state=$(fm_backend_herdr_server_exact_session_state "$session") || exact_state=indeterminate
      case "$exact_state" in
        empty) ;;
        occupied)
          echo "error: refusing to restart release-drifted Herdr session '$session' because its exact workspace/tab/pane state is occupied" >&2
          exit 1
          ;;
        *)
          echo "error: refusing to restart release-drifted Herdr session '$session' because its exact workspace/tab/pane state is indeterminate" >&2
          exit 1
          ;;
      esac
      fm_backend_herdr_server_stop_owned_empty "$session" || {
        echo "error: exact Herdr session '$session' changed or did not stop cleanly before its certified restart" >&2
        exit 1
      }
      running=false
    elif [ "$running" != false ]; then
      echo "error: cannot determine whether exact Herdr session '$session' is running; refusing lifecycle mutation" >&2
      exit 1
    fi
    if fm_backend_herdr_test_hooks_enabled \
      && [ -n "${FM_TEST_HERDR_DELAY_BEFORE_LAUNCH:-}" ]; then
      fm_backend_herdr_control_exec sleep "$FM_TEST_HERDR_DELAY_BEFORE_LAUNCH"
    fi
    fm_backend_herdr_server_lock_mark_launch_epoch \
      "$server_lock" "$server_lock_token" "$server_lock_inode" || exit 1
    fm_backend_herdr_server_launch_detached "$session" || exit 1
    # Give the double-forked grandchild one scheduling turn to exec before the
    # first status poll. The bounded loop below remains the readiness authority.
    fm_backend_herdr_control_exec sleep "${FM_BACKEND_HERDR_LAUNCH_SETTLE:-0.1}"
    i=1
    while [ "$i" -le 20 ]; do
      running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | fm_backend_herdr_control_jq -r '.server.running // false' 2>/dev/null)
      if [ "$running" = "true" ]; then
        if ! fm_backend_herdr_server_certificate_required \
          || fm_backend_herdr_server_closed_shell_environment_ready "$session"; then
          exit 0
        fi
      fi
      fm_backend_herdr_control_exec sleep 0.5
      i=$((i + 1))
    done
    echo "error: herdr server for session '$session' did not report running within 10s" >&2
    exit 1
  )
}

# fm_backend_herdr_workspace_find: this HOME's own workspace id inside
# <session> (fm_backend_herdr_workspace_label), or empty (never creates).
# Read-only, safe for recovery/list paths. Label-collision semantics
# (docs/herdr-backend.md "Label collisions"): herdr enforces no label
# uniqueness at all, so this adopts the FIRST matching workspace `jq` returns
# (list order, normally creation order/oldest) rather than disambiguating -
# identical in spirit to the pre-existing tab duplicate-label check below.
# shellcheck disable=SC2016
fm_backend_herdr_workspace_find() {  # <session>
  local session=$1 label list
  label=$(fm_backend_herdr_workspace_label)
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  # NOTE: the jq variable is $want, NOT $label - `label` is a jq reserved
  # keyword (label/break), so declaring a jq variable named "label" is a
  # compile error that `2>/dev/null` would silently swallow, making this find
  # ALWAYS return empty and every spawn mint a fresh "firstmate" workspace
  # (the workspace leak).
  printf '%s' "$list" | fm_backend_herdr_control_jq -r --arg want "$label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null | fm_backend_herdr_control_head -1
}

# fm_backend_herdr_workspace_prune_seeded_default_tab: close EXACTLY
# <seeded_tab_id>, the auto-created default tab id that THIS SAME
# fm_backend_herdr_workspace_ensure call captured straight from its own
# `workspace create` response (never re-derived from a label pattern at
# create_task time - see the incident note below). Best-effort: a failure
# here never fails the caller, mirroring the fm_backend_herdr_kill `|| true`
# contract.
#
# Live-fire incident fix (2026-07-02): the prior implementation
# (fm_backend_herdr_workspace_prune_default_tabs, removed) re-derived
# "prunable" at create_task time from a pure label heuristic - exactly one
# tab, labeled "1" - run against whatever workspace fm_backend_herdr_workspace_find
# had just resolved. Herdr enforces no label uniqueness (docs/herdr-backend.md
# "Label collisions") and derives an unlabeled workspace's DISPLAYED label from
# its pane cwd's basename, so a captain launching herdr directly inside a
# directory named "firstmate" produces a workspace that looks byte-identical,
# by label alone, to firstmate's own auto-created container - one tab, label
# "1". workspace_find adopted that pre-existing (captain-owned, LIVE) workspace
# by the label match, the heuristic matched too, and the very next spawn
# closed the captain's own live pane 27ms after creating its task tab. The
# fix is structural, not another heuristic: only a workspace THIS SAME
# fm_backend_herdr_workspace_ensure call just created carries a non-empty
# seeded_tab_id at all (see FM_BACKEND_HERDR_WS_SEEDED_TAB_ID below); an
# ADOPTED workspace's seeded_tab_id is always empty, so create_task never
# calls this function for one, regardless of how its tabs happen to be
# labeled.
#
# Defense in depth on top of that gate (not the primary safety mechanism):
# re-verify <seeded_tab_id> is still present, still carries label "1" (a
# human could have renamed or repurposed it in the interim), and refuse to
# close it if its pane hosts an actively working agent per herdr's own
# agent-state detection (`agent get`) - belt-and-suspenders against any other
# unforeseen path landing a live agent in a tab this function was about to
# close.
#
# Verified real-herdr behavior (not modeled by the canned-response fake-CLI
# unit tests; modeled by make_herdr_statefake): closing a workspace's LAST
# remaining tab deletes the whole workspace, not just the tab. So this must
# never run while the seeded default tab is still the ONLY tab in the
# workspace - callers only invoke it once at least one other (real task) tab
# exists alongside it, never right after workspace creation - and this
# function independently re-checks the tab count as a second layer.
# shellcheck disable=SC2016
fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace_id> <seeded_tab_id>
  local session=$1 wsid=$2 tab_id=$3 tabs tab_count current_label pane_id agent_out agent_status
  [ -n "$tab_id" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  tab_count=$(printf '%s' "$tabs" | fm_backend_herdr_control_jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$tab_count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  current_label=$(printf '%s' "$tabs" | fm_backend_herdr_control_jq -r --arg t "$tab_id" '.result.tabs[]? | select(.tab_id == $t) | .label' 2>/dev/null)
  [ "$current_label" = "1" ] || return 0
  pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 0
  [ -n "$pane_id" ] || return 0
  agent_out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null)
  agent_status=$(printf '%s' "$agent_out" | fm_backend_herdr_control_jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$agent_status" = working ] && return 0
  fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
}

# fm_backend_herdr_workspace_ensure: this HOME's persistent workspace inside
# <session>, creating it in <cwd> if absent. Must be called as a PLAIN
# STATEMENT, never through command substitution ($(...)) - it communicates
# through these globals, not solely through stdout, and a command
# substitution forks a subshell that would discard them:
#   FM_BACKEND_HERDR_WS_ID          - the resolved workspace_id (also echoed,
#                                      for callers that only need the id)
#   FM_BACKEND_HERDR_WS_SEEDED_TAB_ID - non-empty ONLY when THIS call just
#                                      CREATED the workspace: the tab_id of
#                                      the auto-created default tab herdr
#                                      seeded it with, read straight from the
#                                      `workspace create` response's
#                                      `.result.tab.tab_id` (verified
#                                      empirically against the real binary -
#                                      no follow-up tab-list call needed).
#                                      Empty whenever this call instead
#                                      ADOPTED a pre-existing workspace
#                                      (fm_backend_herdr_workspace_find
#                                      matched by label - docs/herdr-backend.md
#                                      "Label collisions": that match can
#                                      never distinguish an explicitly
#                                      `--label`-created workspace from one
#                                      whose label only coincidentally
#                                      matches this home's own, e.g. a
#                                      cwd-basename-derived label). An
#                                      ADOPTED workspace's tabs are NEVER
#                                      inspected or identified as prunable by
#                                      this function, no matter what they are
#                                      labeled - see
#                                      fm_backend_herdr_workspace_prune_seeded_default_tab.
# --no-focus (docs/herdr-backend.md "Focus behavior"): verified that workspace
# create does NOT focus by default once at least one workspace already exists
# in the session, matching pre-existing (flagless) behavior; the ONE exception
# is the very first workspace ever created in a brand-new session, which
# focuses regardless of --no-focus (herdr always needs something focused to
# attach to). --no-focus is passed unconditionally anyway, for defense in
# depth and because it is a no-op in the already-safe case.
fm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 wsid out label
  FM_BACKEND_HERDR_WS_ID=""
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  wsid=$(fm_backend_herdr_workspace_find "$session")
  if [ -n "$wsid" ]; then
    FM_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi
  label=$(fm_backend_herdr_workspace_label)
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  wsid=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  FM_BACKEND_HERDR_WS_ID=$wsid
  # Herdr seeds a new workspace with one auto-created default tab firstmate
  # never uses. It is NOT pruned here: at this instant it is the workspace's
  # ONLY tab, and closing a workspace's last tab deletes the workspace itself
  # (verified against the real herdr binary) - pruning here would destroy the
  # workspace we just created. fm_backend_herdr_create_task prunes it instead,
  # once the first real task tab exists alongside it, and only ever targets
  # this exact captured tab_id.
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  printf '%s' "$wsid"
}

# fm_backend_herdr_container_ensure: the full spawn-time container-ensure
# sequence (version gate, server, workspace). Echoes
# "<session>:<workspace_id>\t<seeded_default_tab_id>" - a single TAB character
# always separates the two fields (the second is empty for an ADOPTED
# workspace) so a caller can split unambiguously with
# CONTAINER=${RAW%%$'\t'*}; SEEDED_TAB_ID=${RAW#*$'\t'}. The seeded tab id
# must be threaded through to fm_backend_herdr_create_task, which is the only
# function allowed to prune it (fm_backend_herdr_workspace_prune_seeded_default_tab).
fm_backend_herdr_container_ensure() {  # <cwd-for-a-fresh-workspace>
  local cwd=${1:-$PWD} session label
  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  fm_backend_herdr_workspace_ensure "$session" "$cwd" >/dev/null || { label=$(fm_backend_herdr_workspace_label); echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2; return 1; }
  if [ -z "$FM_BACKEND_HERDR_WS_ID" ]; then
    label=$(fm_backend_herdr_workspace_label)
    echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2
    return 1
  fi
  printf '%s:%s\t%s' "$session" "$FM_BACKEND_HERDR_WS_ID" "$FM_BACKEND_HERDR_WS_SEEDED_TAB_ID"
}

# fm_backend_herdr_pane_agent_state: classify <pane_id> in <session> as one of
# dead|no-agent|live|unknown, purely from the JSON body of two read-only
# calls - never from process exit status, since a business-logic "not found"
# response is a normal, expected outcome here, not a call failure (real herdr
# 0.7.1 exits 1 for it; the canned-response test fakes exit 0; parsing only
# the JSON keeps this function correct against either).
#
#   dead     - `pane get` responds with error code pane_not_found: the pane
#              itself is gone (closed, or its process died and herdr already
#              reaped it - verified empirically: killing a pane's shell pid
#              on a live server makes herdr immediately drop both the pane
#              and its tab from `pane get`/`tab list`).
#   no-agent - `pane get` succeeds (the pane structurally exists) but `agent
#              get` responds with error code agent_not_found: nothing is
#              registered in it - exactly what a herdr session-layout restore
#              produces (verified empirically: `session stop` + fresh `herdr
#              server` restart leaves the pane alive, agent_status "unknown",
#              agent get -> agent_not_found - docs/herdr-backend.md "ID
#              stability across a server restart"), and what a future
#              `resume_agents_on_restore = false` restore would produce too
#              (a plain shell, never an agent).
#   live     - `agent get` succeeds and reports a real agent_status (working,
#              idle, done, or blocked - any registered value). An idle or
#              blocked agent is still a genuine, still-registered agent, not
#              a restored husk, so it is never a close-and-replace candidate.
#   unknown  - anything else: an unparseable/unexpected response from either
#              call, or a `pane get` success whose own echoed pane_id does not
#              round-trip (guards against misreading a herdr response shape
#              change as "the pane exists"). The caller must fail safe toward
#              refusal here, never toward closing - this is the conservative
#              backstop the husk check depends on.
fm_backend_herdr_pane_agent_state() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out code pid status
  # 2>&1, not 2>/dev/null: verified empirically that real herdr 0.7.1 writes
  # an error response's JSON body to STDERR (success bodies go to stdout), so
  # discarding stderr here would blind this function to exactly the
  # error.code values (pane_not_found, agent_not_found) it exists to read -
  # every OTHER call site in this file discards stderr safely only because
  # its caller collapses both the error and the not-an-error paths to the
  # same final answer, which this function's dead/no-agent/live/unknown
  # distinction cannot afford to do.
  out=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "pane_not_found" ] && printf 'dead' || printf 'unknown'
    return 0
  fi
  pid=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [ "$pid" != "$pane_id" ]; then
    printf 'unknown'
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "agent_not_found" ] && printf 'no-agent' || printf 'unknown'
    return 0
  fi
  status=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working|idle|done|blocked) printf 'live' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_tab_is_husk: true (0) only for the two conservative husk
# states (dead, no-agent) fm_backend_herdr_pane_agent_state can positively
# confirm; live and unknown both refuse (1), so an inconclusive read never
# licenses closing anything. Restored-layout recovery depends on this
# fail-safe-toward-refusal behavior.
fm_backend_herdr_tab_is_husk() {  # <session> <pane_id>
  case "$(fm_backend_herdr_pane_agent_state "$1" "$2")" in
    dead|no-agent) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_herdr_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS under <target> ("<session>:<pane_id>"), for the same
# session-start secondmate-liveness sweep fm_backend_tmux_agent_alive serves
# (bin/fm-bootstrap.sh; docs/herdr-backend.md "Agent liveness probe reuses the
# husk classifier"). Reuses fm_backend_herdr_pane_agent_state, the
# already-verified husk classifier ("Respawn idempotency" above): `dead`
# (structurally gone pane) and `no-agent` (a restored, agent-less bare shell
# - EXACTLY the shape a dead secondmate leaves behind) both collapse to
# `dead`; `live` (a real registered agent_status, including idle/blocked)
# maps to `alive`; `unknown` stays `unknown` - fail-safe toward refusal,
# exactly like the husk check itself. Callers must never treat `unknown` as a
# confirmed-dead signal.
fm_backend_herdr_agent_alive() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} identity_state
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  if [ -n "$expected_label" ]; then
    identity_state=$(fm_backend_herdr_identity_state "$target" "$expected_label")
    case "$identity_state" in
      absent) printf 'dead'; return 0 ;;
      match) ;;
      *) printf 'unknown'; return 0 ;;
    esac
  fi
  case "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" in
    dead|no-agent) printf 'dead' ;;
    live) printf 'alive' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_create_task: create the task's tab (one pane) in
# <container> ("session:workspace_id"). Herdr does NOT enforce label
# uniqueness itself (verified: two tabs can share a label), so the duplicate
# check is ours, mirroring tmux's manual check.
#
# A same-labeled tab already existing no longer means an automatic refusal:
# herdr persists and restores its whole session layout (workspaces/tabs/
# panes) across a server restart, including a reboot, and a restored fm-<id>
# task tab comes back a HUSK - a dead pane, or (today, and unconditionally
# once a future `resume_agents_on_restore = false` config ships) a plain
# agent-less shell sitting in the saved cwd, never the crewmate that used to
# be there. Before this fix, every fleet respawn after such a restart needed
# the operator to manually close each husk pane first before firstmate could
# spawn into it again. fm_backend_herdr_tab_is_husk classifies the existing
# tab's pane conservatively (dead or no-agent only; anything live or
# ambiguous refuses exactly as before) and, when it is a confirmed husk,
# this function CLOSES AND REPLACES it instead of refusing.
#
# Ordering is deliberate: the REPLACEMENT tab is created FIRST, and the husk
# is closed only AFTER that succeeds - never the reverse. Closing a
# workspace's LAST remaining tab deletes the whole workspace on real herdr
# (docs/herdr-backend.md "Workspace lifecycle"), and a session-restore husk
# can legitimately be that workspace's only tab (e.g. its own seeded default
# tab was already pruned, long before the restart, by a prior real task tab
# existing alongside it). Herdr's lack of label-uniqueness enforcement is
# exactly what makes this safe: the new and the husk tab can briefly share
# the same label with no error, so the workspace never drops to zero tabs.
# This mirrors fm_backend_herdr_workspace_prune_seeded_default_tab's own
# create-before-close safety argument.
#
# --no-focus: verified tab create never focuses by default regardless of
# sibling tabs, so this is defense in depth rather than a behavior change.
# <seeded_default_tab_id> (4th arg, may be empty) is exactly the value
# fm_backend_herdr_workspace_ensure captured as FM_BACKEND_HERDR_WS_SEEDED_TAB_ID
# for THIS SAME container - non-empty only when this spawn's own
# container_ensure call just created the workspace. Once the real task tab
# above is created, this is the ONLY input that may trigger a prune, and it is
# passed by the caller, never re-derived here from tab list contents or
# labels (the live-fire self-kill fix - see
# fm_backend_herdr_workspace_prune_seeded_default_tab for the incident and
# the safety argument). An ADOPTED workspace's caller always passes an empty
# 4th arg, so this function never even queries for a prune candidate in that
# case. Echoes "<tab_id> <pane_id>" on success.
# shellcheck disable=SC2016
fm_backend_herdr_create_task() {  # <container> <label> <cwd> <seeded_default_tab_id>
  local container=$1 label=$2 cwd=$3 seeded_tab_id=${4:-} session wsid list dup_tabs dup dup_pane dup_tab_ids out tab_id pane_id remaining_dup_tabs
  session=${container%%:*}
  wsid=${container#*:}
  list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup_tabs=$(printf '%s' "$list" | fm_backend_herdr_control_jq -r --arg want "$label" 'if (.result.tabs | type) == "array" then .result.tabs[] | select(.label == $want) | .tab_id else error("missing result.tabs") end' 2>/dev/null) || {
    echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
    return 1
  }
  dup_tab_ids=""
  if [ -n "$dup_tabs" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      dup_pane=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$dup")
      if [ -z "$dup_pane" ] || ! fm_backend_herdr_tab_is_husk "$session" "$dup_pane"; then
        echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
        return 1
      fi
      dup_tab_ids="${dup_tab_ids}${dup}"$'\n'
    done <<EOF
$dup_tabs
EOF
  fi
  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    echo "error: could not parse tab/pane id from herdr tab create output" >&2
    return 1
  fi
  [ -z "$seeded_tab_id" ] || fm_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded_tab_id"
  if [ -n "$dup_tab_ids" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      fm_backend_herdr_cli "$session" tab close "$dup" >/dev/null 2>&1 || true
    done <<EOF
$dup_tab_ids
EOF
    list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not verify herdr husk removal for tab '$label' in workspace $wsid (session $session)" >&2
      fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || true
      return 1
    }
    if ! printf '%s' "$list" | fm_backend_herdr_control_jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
      fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || true
      return 1
    fi
    remaining_dup_tabs=$(printf '%s' "$list" | fm_backend_herdr_control_jq -r --arg want "$label" --arg replacement "$tab_id" \
      '.result.tabs[]? | select(.label == $want and .tab_id != $replacement) | .tab_id' 2>/dev/null) || {
      echo "error: could not parse herdr husk-removal verification listing for tab '$label' in workspace $wsid (session $session)" >&2
      fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || true
      return 1
    }
    remaining_dup_tabs=${remaining_dup_tabs//$'\n'/ }
    if [ -n "$remaining_dup_tabs" ]; then
      echo "error: failed to remove preexisting herdr tab(s) $remaining_dup_tabs for label '$label' in workspace $wsid (session $session)" >&2
      fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || true
      return 1
    fi
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# fm_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# FM_BACKEND_HERDR_SESSION and FM_BACKEND_HERDR_PANE for the caller.
fm_backend_herdr_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_HERDR_SESSION=${target%%:*}
  FM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$FM_BACKEND_HERDR_SESSION" ] && [ -n "$FM_BACKEND_HERDR_PANE" ] && [ "$FM_BACKEND_HERDR_PANE" != "$target" ]
}

fm_backend_herdr_identity_pack() {  # <label> <workspace-id> <workspace-label> [tab-id]
  local label=$1 workspace=$2 workspace_label=$3 tab=${4:-}
  case "$label$workspace$workspace_label$tab" in *'|'*|*$'\t'*|*$'\n'*) return 1 ;; esac
  [ -n "$label" ] && [ -n "$workspace" ] && [ -n "$workspace_label" ] || return 1
  printf '%s|%s|%s|%s' "$label" "$workspace" "$workspace_label" "$tab"
}

fm_backend_herdr_identity_parse() {  # <packed-identity>
  local packed=$1 rest
  case "$packed" in *'|'*'|'*'|'*) ;; *) return 1 ;; esac
  FM_BACKEND_HERDR_EXPECTED_LABEL=${packed%%|*}
  rest=${packed#*|}
  FM_BACKEND_HERDR_EXPECTED_WORKSPACE=${rest%%|*}
  rest=${rest#*|}
  FM_BACKEND_HERDR_EXPECTED_WORKSPACE_LABEL=${rest%%|*}
  FM_BACKEND_HERDR_EXPECTED_TAB=${rest#*|}
  case "$FM_BACKEND_HERDR_EXPECTED_TAB" in *'|'*) return 1 ;; esac
  [ -n "$FM_BACKEND_HERDR_EXPECTED_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE" ] \
    && [ -n "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE_LABEL" ]
}

fm_backend_herdr_identity_from_meta() {  # <target> <expected-label>
  local target=$1 expected_label=$2 state meta id target_of_meta workspace tab kind endpoint_home workspace_label marker_id
  command -v fm_meta_get >/dev/null 2>&1 || return 1
  command -v fm_backend_of_meta >/dev/null 2>&1 || return 1
  command -v fm_backend_target_of_meta >/dev/null 2>&1 || return 1
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
    target_of_meta=$(fm_backend_target_of_meta "$meta")
    [ "$target_of_meta" = "$target" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$expected_label" = "fm-$id" ] || continue
    workspace=$(fm_meta_get "$meta" herdr_workspace_id)
    tab=$(fm_meta_get "$meta" herdr_tab_id)
    [ -n "$workspace" ] || return 1
    kind=$(fm_meta_get "$meta" kind)
    endpoint_home=$FM_HOME
    if [ "$kind" = secondmate ]; then
      endpoint_home=$(fm_meta_get "$meta" home)
      [ -n "$endpoint_home" ] || return 1
      marker_id=$(fm_backend_herdr_control_exec tr -d '[:space:]' \
        < "$endpoint_home/$FM_BACKEND_HERDR_SECONDMATE_MARKER" 2>/dev/null) || return 1
      [ "$marker_id" = "$id" ] || return 1
    fi
    workspace_label=$(fm_backend_herdr_workspace_label_for_home "$endpoint_home")
    fm_backend_herdr_identity_pack "$expected_label" "$workspace" "$workspace_label" "$tab"
    return
  done
  return 1
}

fm_backend_herdr_expected_identity() {  # <target> <expected-label-or-identity>
  local target=$1 expected=${2:-} workspace workspace_label
  [ -n "$expected" ] || return 1
  if fm_backend_herdr_identity_parse "$expected"; then
    printf '%s' "$expected"
    return 0
  fi
  if fm_backend_herdr_identity_from_meta "$target" "$expected"; then
    return 0
  fi
  workspace=$(fm_backend_herdr_workspace_find "$FM_BACKEND_HERDR_SESSION") || return 1
  [ -n "$workspace" ] || return 1
  workspace_label=$(fm_backend_herdr_workspace_label)
  fm_backend_herdr_identity_pack "$expected" "$workspace" "$workspace_label"
}

# shellcheck disable=SC2016
fm_backend_herdr_identity_state() {  # <target> [expected-label-or-identity]
  local target=$1 expected=${2:-} identity panes pane_record tabs tab_id workspaces labeled_workspaces labeled_workspace
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  if [ -n "$expected" ]; then
    identity=$(fm_backend_herdr_expected_identity "$target" "$expected") \
      || { printf 'unknown'; return 0; }
    fm_backend_herdr_identity_parse "$identity" || { printf 'unknown'; return 0; }
  fi
  panes=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane list 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if ! printf '%s\n' "$panes" | fm_backend_herdr_control_jq -e '
    (.result.panes | type) == "array"
    and all(.result.panes[];
      type == "object"
      and (.pane_id | type) == "string"
      and (.pane_id | length) > 0
      and (.tab_id | type) == "string"
      and (.tab_id | length) > 0)
  ' >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  pane_record=$(printf '%s\n' "$panes" | fm_backend_herdr_control_jq -cr --arg pane "$FM_BACKEND_HERDR_PANE" \
    '[.result.panes[] | select(.pane_id == $pane)] | first // null' 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if [ -z "$expected" ]; then
    if [ "$pane_record" = null ]; then printf 'absent'; else printf 'match'; fi
    return 0
  fi
  workspaces=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" workspace list 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if ! printf '%s\n' "$workspaces" | fm_backend_herdr_control_jq -e '
    (.result.workspaces | type) == "array"
    and all(.result.workspaces[];
      type == "object"
      and (.workspace_id | type) == "string"
      and (.workspace_id | length) > 0
      and (.label | type) == "string")
  ' >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  if ! printf '%s\n' "$workspaces" | fm_backend_herdr_control_jq -e \
    --arg workspace "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE" \
    --arg want_label "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE_LABEL" \
    'any(.result.workspaces[]?; (.workspace_id | tostring) == $workspace and .label == $want_label)' >/dev/null 2>&1; then
    # The recorded workspace-id+label pair is gone (killing a workspace's last
    # tab auto-deletes the workspace, so this IS the normal shape of a
    # torn-down task). Absence still needs three independent proofs: the
    # recorded pane is gone, the recorded workspace id no longer exists under
    # ANY label (a recycled or relabeled id is a collision, not absence), and
    # no workspace still carrying the expected home label holds the expected
    # fm-<task> tab (a replacement generation). Anything short of all three -
    # including any CLI or parse failure below - stays mismatch/unknown so
    # callers fail closed instead of releasing a live target's lease.
    if [ "$pane_record" != null ]; then printf 'mismatch'; return 0; fi
    if printf '%s\n' "$workspaces" | fm_backend_herdr_control_jq -e \
      --arg workspace "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE" \
      'any(.result.workspaces[]?; (.workspace_id | tostring) == $workspace)' >/dev/null 2>&1; then
      printf 'mismatch'
      return 0
    fi
    labeled_workspaces=$(printf '%s\n' "$workspaces" | fm_backend_herdr_control_jq -r \
      --arg want_label "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE_LABEL" \
      '.result.workspaces[]? | select(.label == $want_label) | .workspace_id' 2>/dev/null) \
      || { printf 'unknown'; return 0; }
    while IFS= read -r labeled_workspace; do
      [ -n "$labeled_workspace" ] || continue
      tabs=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" tab list --workspace "$labeled_workspace" 2>/dev/null) \
        || { printf 'unknown'; return 0; }
      if ! printf '%s\n' "$tabs" | fm_backend_herdr_control_jq -e '
        (.result.tabs | type) == "array"
        and all(.result.tabs[];
          type == "object"
          and (.tab_id | type) == "string"
          and (.tab_id | length) > 0
          and (.workspace_id | type) == "string"
          and (.workspace_id | length) > 0
          and (.label | type) == "string")
      ' >/dev/null 2>&1; then
        printf 'unknown'
        return 0
      fi
      if printf '%s\n' "$tabs" | fm_backend_herdr_control_jq -e \
        --arg want_label "$FM_BACKEND_HERDR_EXPECTED_LABEL" \
        'any(.result.tabs[]?; .label == $want_label)' >/dev/null 2>&1; then
        printf 'mismatch'
        return 0
      fi
    done <<EOF
$labeled_workspaces
EOF
    printf 'absent'
    return 0
  fi
  tabs=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" tab list --workspace "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if ! printf '%s\n' "$tabs" | fm_backend_herdr_control_jq -e '
    (.result.tabs | type) == "array"
    and all(.result.tabs[];
      type == "object"
      and (.tab_id | type) == "string"
      and (.tab_id | length) > 0
      and (.workspace_id | type) == "string"
      and (.workspace_id | length) > 0
      and (.label | type) == "string")
  ' >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  if [ "$pane_record" = null ]; then
    if printf '%s\n' "$tabs" | fm_backend_herdr_control_jq -e \
      --arg workspace "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE" \
      --arg want_label "$FM_BACKEND_HERDR_EXPECTED_LABEL" \
      'any(.result.tabs[]?;
        (.workspace_id | tostring) == $workspace
        and .label == $want_label)' >/dev/null 2>&1; then
      printf 'unknown'
    else
      printf 'absent'
    fi
    return 0
  fi
  tab_id=$(printf '%s\n' "$pane_record" | fm_backend_herdr_control_jq -r '.tab_id' 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if printf '%s\n' "$tabs" | fm_backend_herdr_control_jq -e \
    --arg tab "$tab_id" \
    --arg recorded_tab "$FM_BACKEND_HERDR_EXPECTED_TAB" \
    --arg workspace "$FM_BACKEND_HERDR_EXPECTED_WORKSPACE" \
    --arg want_label "$FM_BACKEND_HERDR_EXPECTED_LABEL" \
    'any(.result.tabs[]?;
      (.tab_id | tostring) == $tab
      and ($recorded_tab == "" or (.tab_id | tostring) == $recorded_tab)
      and (.workspace_id | tostring) == $workspace
      and .label == $want_label)' >/dev/null 2>&1; then
    printf 'match'
  elif printf '%s\n' "$tabs" | fm_backend_herdr_control_jq -e --arg tab "$tab_id" \
    'any(.result.tabs[]?; (.tab_id | tostring) == $tab)' >/dev/null 2>&1; then
    printf 'mismatch'
  else
    printf 'unknown'
  fi
}

fm_backend_herdr_expected_label_matches() {  # <target> [expected-label]
  [ -n "${2:-}" ] || return 0
  [ "$(fm_backend_herdr_identity_state "$1" "${2:-}")" = match ]
}

fm_backend_herdr_target_ready() {  # <target> [expected-label]
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_server_ensure "$FM_BACKEND_HERDR_SESSION" || return 1
  fm_backend_herdr_expected_label_matches "$1" "${2:-}" || return 1
}

# fm_backend_herdr_current_path: the live FOREGROUND process's cwd, or empty on
# any error. Mirrors tmux's pane_current_path poll used to verify the endpoint
# started in its leased worktree.
#
# Verified pitfall: `pane get`'s `.result.pane.cwd` is the pane's cwd AT
# CREATION TIME and does not follow later shell directory changes.
# `.result.pane.foreground_cwd` tracks the ACTUALLY RUNNING foreground
# process's cwd instead, which is what identifies the live task directory.
fm_backend_herdr_current_path() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | fm_backend_herdr_control_jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

# fm_backend_herdr_send_text_line: send one line of TEXT then submit,
# ATOMICALLY - mirrors tmux's `send-keys -t T text Enter`. Used for the fixed
# spawn-time commands (the GOTMPDIR export and harness launch). `pane run` types
# the command and submits it in one call (verified).
fm_backend_herdr_send_text_line() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane run "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Mirrors tmux's `send-keys -t T -l text`.
# Verified: `pane send-text` does NOT auto-submit (contrary to the addendum's
# original guess); it behaves exactly like tmux's `-l` literal send.
fm_backend_herdr_send_literal() {  # <target> <text> [expected-label]
  fm_backend_herdr_target_ready "$1" "${3:-}" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-text "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c, as used by fm-send.sh --key and stuck-crewmate-recovery) onto
# herdr's `pane send-keys` names. Verified empirically: enter, escape/esc, and
# both ctrl+c/C-c all work (case-insensitive on herdr's side, but normalize
# explicitly rather than relying on that).
fm_backend_herdr_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_herdr_send_key: one named special key. Mirrors fm-send.sh's --key
# path (tmux's `send-keys -t T key`).
fm_backend_herdr_send_key() {  # <target> <key> [expected-label]
  fm_backend_herdr_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

# fm_backend_herdr_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's/fm-watch.sh's `tmux capture-pane -p -t T -S -N`. --source recent
# is the closest herdr analogue to tmux's scrollback-bounded capture.
#
# Verified CLI quirk (herdr-verification-p2.md "pane read --lines bug", v0.7.1):
# `pane read --source recent --lines N` returns COMPLETELY EMPTY output when N
# is smaller than the pane's current viewport height (observed threshold ~23
# rows for a default-sized pane), instead of clamping to the last N lines - it
# does not merely ignore the bound, it drops the read entirely. This silently
# broke exactly the small bounded reads this adapter relies on most (including
# the composer-state guard/fallback reads around submit and injection). Workaround:
# always request a generous fetch far above any realistic viewport height, then
# trim to the caller's requested bound ourselves with `tail`.
fm_backend_herdr_capture() {  # <target> <lines> [expected-label]
  fm_backend_herdr_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

fm_backend_herdr_capture_ansi() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" --format ansi 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# Thin adapter over the shared plain-text stripper (bin/fm-composer-lib.sh),
# used only for STRUCTURAL row/shape detection where ghost text must be kept so
# the box border or bare prompt glyph is still visible. Content extraction uses
# the shared fm_composer_strip_ghost instead.
fm_backend_herdr_strip_ansi() {  # <text>
  printf '%s' "$1" | fm_composer_strip_ansi
}

# fm_backend_herdr_composer_state: classify the composer's own row as
# empty|pending|unknown, scanning a generous tail-window capture of <target>.
# herdr's CLI exposes no cursor-row primitive (unlike tmux's #{cursor_y}), so
# this locates the composer row structurally, recognizing TWO row shapes and
# keeping whichever match comes LAST (scanning forward), so a shape earlier in
# scrollback/a popup can never outrank the real (bottom-anchored) composer row:
#
#   bordered - a boxed composer (verified grok 0.2.82): the row's TRIMMED
#              content both STARTS and ENDS with the same border glyph (│, ┃,
#              or a plain ASCII |). The box's own top/bottom rows use rounded
#              corners (╭─…─╮ / ╰─…─╯), which never match; popup item rows and
#              horizontal separator rows carry no border glyph at all; the
#              footer help line ("Enter:send │ … │ …") uses │ only as an
#              INTERIOR separator and does not start with one, so it never
#              matches either.
#   bare     - an UNBORDERED composer (verified real claude 2.x and codex
#              0.142.x, both under herdr 0.7.1, docs/herdr-backend.md
#              "Incident (2026-07-07)"): the row's TRIMMED content starts with
#              one of the verified agent-specific prompt glyphs but carries no
#              closing border at all - claude's own live input row is a bare
#              "❯ …" with no surrounding │, and codex's is a bare "› …". Both
#              harnesses ALSO render bordered decorative boxes elsewhere (a
#              startup welcome banner, an update-available notice) that
#              satisfy the bordered shape above; requiring a match on EITHER
#              shape and keeping the last (bottom-most) one is what keeps the
#              live composer winning over a stale decorative box still sitting
#              in the same capture window - a bordered box is only ever
#              followed later on screen by the actual live composer, never the
#              reverse, in every harness observed so far. The bare shape is
#              deliberately narrower than the bordered content classifier so a
#              no-agent shell fallback prompt (`>`, `$`, `%`, or `#`) falls
#              through to `unknown` instead of being misread as delivered.
#
#   empty   - blank, a bare prompt glyph, known ghost/placeholder text
#             ("Type a message...", verified grok 0.2.82's empty-composer
#             placeholder), or only de-emphasised ANSI ghost/placeholder text
#             recognized by the shared fm_composer_strip_ghost extractor
#             (dim/faint or dark-TRUECOLOR foreground). Safe to treat as
#             submitted.
#   pending - real, unsubmitted text sits in the composer. This deliberately
#             also covers a slash-command popup that just closed but only
#             auto-completed or filled an argument-hint placeholder into the
#             composer (e.g. "/compact" -> "/compact compaction
#             instructions", verified live against real grok 0.2.82) - that
#             first Enter is a SELECTION, not a submission.
#   unknown - the pane could not be read, or no composer row (of either shape)
#             was found in the captured window.
#
# Ghost/placeholder note: herdr's ANSI pane read preserves the harness's own
# de-emphasis styling, and the classifier extracts real typed content with the
# shared fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops dim/faint
# runs (claude's rotating prompt suggestion, codex's idle suggestion after the
# bare `›` prompt) AND dark/muted truecolor foreground runs (grok's placeholder),
# while keeping non-de-emphasised real typed input. This is the same owner the
# tmux adapter routes through, so the two backends cannot drift (task
# afk-herdr-false-pending); it superseded a herdr-only faint byte-pattern check
# that recognized only codex's bold-wrapped bare prompt and missed claude's own
# dim ghost - the overnight away-mode injection wedge on the primary claude pane.
FM_BACKEND_HERDR_COMPOSER_LINES=${FM_BACKEND_HERDR_COMPOSER_LINES:-20}
# Known ghost/placeholder composer text. Extend this if another
# herdr-verified harness needs its own idle placeholder recognized.
FM_BACKEND_HERDR_IDLE_RE=${FM_BACKEND_HERDR_IDLE_RE:-'^Type a message\.\.\.$'}
# Known bare (unbordered) prompt glyphs a composer row may start with: ❯
# (claude) and › (codex) only. Generic shell-style glyphs > $ % # are still
# recognized after a bordered composer row has already been structurally found.
FM_BACKEND_HERDR_BARE_PROMPT_RE=${FM_BACKEND_HERDR_BARE_PROMPT_RE:-'^[❯›]'}

fm_backend_herdr_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cap line trimmed found=0 shape="" raw_match="" bordered=0 stripped
  cap=$(fm_backend_herdr_capture_ansi "$target" "$FM_BACKEND_HERDR_COMPOSER_LINES" 2>/dev/null \
    || fm_backend_herdr_capture "$target" "$FM_BACKEND_HERDR_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  # Structural scan: locate the bottom-most composer row and remember its RAW
  # (styled) bytes. Shape detection runs on the plain row (fm_backend_herdr_strip_ansi
  # keeps ghost text so the border/prompt glyph is still visible); the raw row is
  # kept for ANSI-aware content extraction after the scan.
  while IFS= read -r line; do
    trimmed=$(fm_backend_herdr_strip_ansi "$line")
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        shape=bordered
        raw_match=$line
        found=1
        ;;
      *)
        if printf '%s' "$trimmed" | fm_backend_herdr_control_grep -qE "$FM_BACKEND_HERDR_BARE_PROMPT_RE"; then
          shape=bare
          raw_match=$line
          found=1
        fi
        ;;
    esac
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  # Content: extract the real typed text from the raw row with the shared,
  # fleet-wide ghost stripper (bin/fm-composer-lib.sh), which drops dim/faint AND
  # dark-truecolor ghost/placeholder runs. This replaces the former herdr-only
  # faint byte-pattern check (which recognized only Codex's bold-wrapped bare
  # prompt and missed claude's own dim prompt-suggestion ghost - the overnight
  # afk-herdr-false-pending wedge) and, in a dark theme, drops the composer's own
  # dark box border too, which is why the bordered flag was read from the plain
  # shape above, not from this ghost-stripped content.
  stripped=$(printf '%s\n' "$raw_match" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [ "$shape" = bordered ]; then
    bordered=1
    stripped=${stripped//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
  fi
  # Delegate the empty/pending/unknown decision to the shared owner. The bare
  # shape only ever starts with an AGENT glyph (FM_BACKEND_HERDR_BARE_PROMPT_RE
  # is '^[❯›]'), so a bare shell prompt never reaches here - it stays 'unknown'
  # via the no-composer-row path above, exactly as before.
  fm_composer_classify_content "$bordered" "$stripped" "$FM_BACKEND_HERDR_IDLE_RE"
}

# fm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until herdr's NATIVE agent-state (agent get)
# confirms a real turn started. Verified hazard (herdr-verification-p2.md
# "slash/$ autocomplete popup"): a `/`- or `$`-prefixed send opens a
# completion popup within ~0.1s, exactly like tmux's claude/codex popups, so
# the caller's <settle> before the first Enter matters here the same way it
# does for tmux.
#
# Confirmation signal (rewritten for the 2026-07-07 incident below;
# superseded a composer-content read that itself replaced a delta-based check
# for the 2026-07-03 incident): when the target is legibly idle before Enter,
# submission is confirmed by fm_backend_herdr_wait_for_working observing a
# submit-active agent_status after Enter, NOT by reading the composer's own
# row. This makes the normal confirmation path cross-agent: it is the same
# semantic signal regardless of what text a harness's idle composer happens
# to display.
#
# Incident (2026-07-07, followed up on 2026-07-08): a redelivery loop in the
# away-mode daemon. Root cause: composer-content submit confirmation was too
# sensitive to harness rendering details. Real claude/codex use bare prompt
# rows, and real codex adds dynamic idle suggestions after `›`; the later
# ANSI-aware composer classifier now handles the compatibility pre-injection
# guard for that Codex shape, but idle-baseline submit confirmation deliberately
# stays on native agent-state so delivery does not depend on composer text.
# Composer content is retained for other callers (the terminal-backed away-mode
# compatibility path's empty-box guard, still dispatched via fm_backend_composer_state /
# fm_backend_herdr_composer_state) and for submit attempts whose pre-Enter
# agent-state baseline is not legibly idle.
#
# This also still correctly handles the earlier 2026-07-03 incident (a
# slash-command popup selection/placeholder-fill on the FIRST Enter is not a
# genuine submission) without any popup-specific logic at all: filling a
# composer placeholder never starts a turn, so agent_status simply never
# reports "working" for that Enter, and the retry loop below sends a second
# Enter exactly as it did before - the fix generalizes instead of special-
# casing the popup shape.
#
# Failure-mode analysis (the two directions the caller-facing contract must
# not get wrong - see docs/herdr-backend.md "Native agent-state submit
# confirmation" for the empirical timing behind this):
#   - Slow transition: fm_backend_herdr_wait_for_working samples repeatedly
#     across herdr's per-attempt confirmation budget (not once at the end), so a
#     transition landing partway through a window is still caught before this
#     loop gives up and sends a needless extra Enter.
#   - Instant round-trip (a turn starts AND returns to idle between two
#     polls): unavoidable in the absolute, but bounded by how tightly polls
#     are packed into the budget; real claude/codex measured first-working
#     at 90-490ms, comfortably inside a several-hundred-ms, multiply-sampled
#     window, so this has not been observed in practice. On the (unobserved)
#     residual chance it happens, the verdict is "pending" and the caller
#     never retypes - only re-sends Enter, which lands on an already-empty
#     composer and is a no-op, not a duplicate delivery of <text> (see
#     fm-send.sh/fm-supervise-daemon.sh: retyping only happens if a caller
#     re-invokes this function from scratch with the same text after seeing
#     an error, which is a human/escalation decision, not an automatic
#     retry).
# Echoes empty|pending|unknown|send-failed, the SAME vocabulary fm-send.sh
# already branches on for tmux ("empty" means "confirmed submitted" for every
# backend; how each backend confirms it is an internal decision - herdr's is
# no longer literally "the composer read empty").
fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i=0 verdict baseline confirm_sleep
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_expected_label_matches "$target" "$expected_label" || { printf 'send-failed'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  fm_backend_herdr_control_exec sleep "$settle"
  baseline=$(fm_backend_herdr_classify_submit_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    fm_backend_herdr_send_key "$target" Enter "$expected_label" || true
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
    else
      fm_backend_herdr_control_exec sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target")
    fi
    case "$verdict" in
      busy) printf 'empty'; return 0 ;;
      empty) printf 'empty'; return 0 ;;
      unknown) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Verified: closing a tab's only pane
# closes the tab too, so a separate tab close is unnecessary.
fm_backend_herdr_kill() {  # <target> [backend-id] [expected-label]
  if ! fm_backend_herdr_target_ready "$1" "${3:-}"; then
    [ -z "${3:-}" ] && return 0
    return 1
  fi
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane close "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || true
}

# fm_backend_herdr_classify_agent_status: map a raw `agent get` agent_status
# value to the adapter's watcher busy|idle|unknown vocabulary. working ->
# busy (actively generating); idle/done -> idle; blocked -> idle (a blocked
# agent is stuck waiting on the human, not grinding - the watcher should
# treat it like a stale pane needing attention, not suppress it as busy);
# unknown/unparseable/empty -> unknown, the caller's cue to fall back to
# pane-regex detection.
fm_backend_herdr_classify_agent_status() {  # <raw-agent_status>
  case "$1" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_classify_submit_agent_status() {  # <raw-agent_status>
  case "$1" in
    working|blocked) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_agent_status_raw: one `agent get` read, echoing the raw
# agent_status string (working/idle/done/blocked/...), or empty on any
# failure. Deliberately skips fm_backend_herdr_target_ready's server-ensure
# round trip (an extra `status --json` call) that fm_backend_herdr_busy_state
# pays on every call: fm_backend_herdr_wait_for_working polls this in a tight
# loop right after a caller has already parsed the target and confirmed the
# server is live (e.g. fm_backend_herdr_send_text_submit, immediately after a
# successful send-text), so re-checking server liveness on every poll would
# only add latency without adding safety.
fm_backend_herdr_agent_status_raw() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$out" | fm_backend_herdr_control_jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

# fm_backend_herdr_busy_state: semantic busy state from herdr's native
# agent-state detection (agent.get), the "first backend where fm_session_busy_state
# gets real semantics" per the design report. See
# fm_backend_herdr_classify_agent_status for the status->busy/idle/unknown
# mapping.
fm_backend_herdr_busy_state() {  # <target> [expected-label]
  fm_backend_herdr_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")"
}

# fm_backend_herdr_wait_for_working: poll <session>:<pane_id>'s NATIVE
# agent-state (agent get) up to <polls> times spread evenly across
# <budget-seconds>, returning on stdout the STRONGEST signal observed:
#
#   busy    - a submit-active status was observed at least once. This is
#             confirmation that a real turn started or reached a prompt -
#             the submit landed - independent of
#             whatever the composer's own text happens to show (docs/
#             herdr-backend.md "Incident (2026-07-07)": composer content is
#             what fooled the OLD confirmation on codex's dynamic idle-tip
#             text). Returned the INSTANT it is seen, without waiting out the
#             rest of the budget.
#   idle    - the target was legibly read at least once and never reported
#             "busy" across the whole window - a genuine "not (yet)
#             submitted" signal, not a read failure. The caller retries
#             Enter on this verdict.
#   unknown - EVERY poll in the window failed to read the target at all (a
#             hard I/O failure - pane gone, socket error - not a timing
#             race). The caller must not keep retrying Enter against a target
#             it cannot even read.
#
# <polls> spread across <budget-seconds> (rather than one check at the end)
# is what makes this robust against a SLOW transition: a caller now gets
# several samples across that window instead of a single one, so a transition
# that lands partway through is not missed just because it had not landed by
# the FIRST sample.
# Empirical evidence (docs/herdr-backend.md "Native agent-state submit
# confirmation"): real claude and codex observed first-working at 90-490ms
# after Enter, so a several-hundred-ms budget sampled repeatedly reliably
# catches it. The remaining, inherent gap - a turn so fast it starts AND
# returns to idle between two samples - is bounded by how tightly <polls> is
# packed into <budget-seconds>; nothing observed in real testing has come
# close to that, but it is a residual risk, not a mathematical impossibility
# (see the doc section for the full characterization and the failure-mode
# analysis for both directions this must guard).
# FM_BACKEND_HERDR_SUBMIT_POLLS (default 6): how many samples
# fm_backend_herdr_send_text_submit spreads across each Enter attempt's
# confirmation budget. Overridable for tests (a value of 1
# reproduces the old single-check-at-the-end timing exactly, for byte-for-byte
# call-count assertions).
FM_BACKEND_HERDR_SUBMIT_POLLS=${FM_BACKEND_HERDR_SUBMIT_POLLS:-6}
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=${FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP:-0.6}

fm_backend_herdr_submit_confirm_budget() {  # <caller-budget-seconds>
  fm_backend_herdr_control_exec awk -v b="${1:-0}" -v m="$FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP" 'BEGIN {
    b += 0
    m += 0
    if (b < 0) b = 0
    if (m < 0) m = 0
    if (m > b) b = m
    printf "%.4f", b
  }' 2>/dev/null || printf '%s' "${1:-0}"
}

fm_backend_herdr_wait_for_working() {  # <session> <pane_id> <budget-seconds> <polls>
  local session=$1 pane_id=$2 budget=$3 polls=${4:-1} i interval raw bs saw_idle=0
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(fm_backend_herdr_control_exec awk -v b="$budget" -v p="$polls" 'BEGIN { d = p - 1; if (d < 1) d = 1; v = b / d; if (v < 0) v = 0; printf "%.4f", v }' 2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=0 ;; esac
  for ((i = 0; i < polls; i++)); do
    if [ "$polls" -eq 1 ] || [ "$i" -gt 0 ]; then
      fm_backend_herdr_control_exec sleep "$interval"
    fi
    raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
    bs=$(fm_backend_herdr_classify_submit_agent_status "$raw")
    case "$bs" in
      busy) printf 'busy'; return 0 ;;
      idle) saw_idle=1 ;;
    esac
  done
  if [ "$saw_idle" -eq 1 ]; then
    printf 'idle'
  else
    printf 'unknown'
  fi
}

# fm_backend_herdr_pane_for_tab: the root pane id for <tab_id> in <workspace_id>
# of <session>, via one pane list call filtered by tab_id (never assumes a
# tab-number/pane-number correspondence - herdr numbers them independently).
# shellcheck disable=SC2016
fm_backend_herdr_pane_for_tab() {  # <session> <workspace_id> <tab_id>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | fm_backend_herdr_control_jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | fm_backend_herdr_control_head -1
}

# fm_backend_herdr_resolve_bare_selector: the live-tab-listing fallback for an
# ad hoc selector with no meta (mirrors tmux's list-windows grep). Searches
# every RUNNING named herdr session (herdr session list) for a tab whose label
# matches <name>, since herdr sessions are not addressed by one ambient
# server the way a single tmux server is. Rare path in practice (herdr tasks
# normally carry meta), best-effort.
# shellcheck disable=SC2016
fm_backend_herdr_resolve_bare_selector() {  # <name>
  local name=$1 sessions session tabs tab_id wsid pane_id herdr_bin
  herdr_bin=$(fm_backend_herdr_bin) || return 1
  sessions=$(fm_backend_herdr_scrubbed_exec "$herdr_bin" session list --json 2>/dev/null \
    | fm_backend_herdr_control_jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null)
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || continue
    tab_id=$(printf '%s' "$tabs" | fm_backend_herdr_control_jq -r --arg want "$name" \
      '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null | fm_backend_herdr_control_head -1)
    [ -n "$tab_id" ] || continue
    wsid=$(printf '%s' "$tabs" | fm_backend_herdr_control_jq -r --arg tab "$tab_id" '.result.tabs[]? | select(.tab_id == $tab) | .workspace_id' 2>/dev/null | fm_backend_herdr_control_head -1)
    [ -n "$wsid" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s' "$session" "$pane_id"
    return 0
  done <<EOF
$sessions
EOF
  echo "error: no herdr tab named $name in any running session" >&2
  return 1
}

# fm_backend_herdr_list_live: recovery/orphan discovery. Lists every tab whose
# label looks like a firstmate task window (fm-<id>) in <session>'s, THIS
# HOME'S OWN workspace (fm_backend_herdr_workspace_label - never another
# home's), by LABEL - never by trusting a stored pane id, since ids are not
# guaranteed stable across every server lifecycle (see herdr-verification-p2.md
# "ID stability"). A caller running as a given home (e.g. a secondmate
# recovering its own in-flight work) naturally scopes to that home's own
# workspace because FM_HOME already names it - no glue needed, unlike the
# primary-spawns-a-secondmate path in fm-spawn.sh. Read-only: a session/
# workspace that does not exist yet simply lists nothing. One
# "<session>:<pane_id>\t<label>" line per live task tab.
fm_backend_herdr_list_live() {  # <session>
  local session=$1 wsid tabs tab_id label pane_id
  wsid=$(fm_backend_herdr_workspace_find "$session") || return 0
  [ -n "$wsid" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  while IFS=$'\t' read -r tab_id label; do
    [ -n "$tab_id" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s\t%s\n' "$session" "$pane_id" "$label"
  done < <(printf '%s' "$tabs" | fm_backend_herdr_control_jq -r '.result.tabs[]? | select(.label | startswith("fm-")) | "\(.tab_id)\t\(.label)"' 2>/dev/null)
}

# --- native event push: pane.agent_status_changed subscriber -----------------
#
# The push half of the immediate blocked-state escalation (AGENTS.md section 8,
# docs/herdr-backend.md "Native pane.agent_status_changed push escalation").
# fm_backend_herdr_wait_transition is the watcher's bounded wait primitive for
# herdr homes: instead of a blind sleep, it blocks on herdr's native event
# stream and returns the instant a subscribed pane transitions to `blocked`, so
# a crew waiting on the human wakes its supervisor sub-second instead of after
# the ~240s stale-pane wedge timer. Everything not `blocked` is streamed too
# (the policy, not the subscription, makes `blocked` the sole immediate action)
# so `working` edges clear the per-pane dedupe marker. Polling stays the
# permanent fail-closed backstop: below-capability, a connect/subscribe failure,
# or a missing reader all fall back to the caller sleeping the same budget.

# fm_backend_herdr_socket_path: the control-socket path for <session>, read from
# `herdr session list --json` (the default session's socket differs from a named
# session's - verified: default -> ~/.config/herdr/herdr.sock, named ->
# ~/.config/herdr/sessions/<name>/herdr.sock). Empty on any failure.
# shellcheck disable=SC2016
fm_backend_herdr_socket_path() {  # <session>
  local session=$1 herdr_bin
  herdr_bin=$(fm_backend_herdr_bin) || return 1
  fm_backend_herdr_scrubbed_exec "$herdr_bin" session list --json 2>/dev/null \
    | fm_backend_herdr_control_jq -r --arg name "$session" '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | fm_backend_herdr_control_head -1
}

# fm_backend_herdr_events_capable: the version/capability gate for the event
# fast-path (report section 5c trigger 1). Fails closed to the poll loop unless
# ALL hold: herdr+jq present; the raw-socket reader available (python3, unless a
# reader override is configured); client protocol >= FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL;
# and both `events.subscribe` and `pane.agent_status_changed` present in `herdr
# api schema`. FM_BACKEND_HERDR_EVENTS_FORCE overrides the whole verdict for
# tests (1 = capable, 0 = incapable) without touching the real binary. The
# `api schema` read is ~220KB, so callers (the watcher) memoize this per session
# for a process lifetime rather than probing every poll.
fm_backend_herdr_events_capable() {  # <session>
  local session=$1 protocol schema herdr_bin
  case "${FM_BACKEND_HERDR_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_herdr_tool_check || return 1
  if [ -z "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    command -v python3 >/dev/null 2>&1 || return 1
  fi
  herdr_bin=$(fm_backend_herdr_bin) || return 1
  protocol=$(fm_backend_herdr_scrubbed_exec "$herdr_bin" status --json 2>/dev/null \
    | fm_backend_herdr_control_jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge "$FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL" ] || return 1
  schema=$(fm_backend_herdr_scrubbed_exec "$herdr_bin" api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | fm_backend_herdr_control_grep -Fq 'events.subscribe' || return 1
  printf '%s' "$schema" | fm_backend_herdr_control_grep -Fq 'pane.agent_status_changed' || return 1
  return 0
}

# fm_backend_herdr_normalize_event: THE single normalize point (report section 5
# refinement: one backend transition shape, one parse point). Both the stream
# reader's projected lines AND the level-reconcile's `agent get` reads flow
# through here into the shared normalized-transition record. herdr's event
# carries no previous status and its stream is edge-triggered, so from_status is
# left empty; to_status drives the policy.
fm_backend_herdr_normalize_event() {  # <pane_id> <workspace_id> <agent_status> <agent>
  fm_transition_record "${1:-}" "${2:-}" "" "${3:-}" "${4:-}"
}

# fm_backend_herdr_event_reader_cmd: emit the reader argv (one word per line) for
# the raw-socket subscriber. Default: `python3 <this dir>/herdr-eventwait.py`.
# FM_BACKEND_HERDR_EVENT_READER overrides it with a whitespace-split command so
# tests can substitute a fake reader that replays canned stream lines.
fm_backend_herdr_event_reader_cmd() {
  local word
  if [ -n "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    for word in $FM_BACKEND_HERDR_EVENT_READER; do
      printf '%s\n' "$word"
    done
    return 0
  fi
  printf 'python3\n'
  printf '%s\n' "$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-eventwait.py"
}

# fm_backend_herdr_escalation_marker: the per-pane dedupe marker path for a
# <window> ("<session>:<pane_id>"), keyed identically to the watcher's
# .stale-<key> (tr ':/.' '___'), under <state_dir>.
fm_backend_herdr_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | fm_backend_herdr_control_exec tr ':/.' '___')
  printf '%s/%s%s' "$state" "$FM_BACKEND_HERDR_ESCALATED_PREFIX" "$key"
}

# fm_backend_herdr_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-pane dedupe marker under <state_dir>.
# On a fresh `actionable` (blocked) edge - policy actionable AND no marker yet -
# it prints the record on stdout and returns 0 (the caller stops and hands the
# record up). The caller commits the marker only after handling the record.
# `absorb` (working) clears the marker and
# returns 1. `defer`/`fallback`, and an already-marked `actionable`, return 1
# with no output. <session> reconstructs the window ("<session>:<pane_id>") for
# the marker key, matching the watcher's own key scheme.
fm_backend_herdr_apply_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id to action window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      fm_backend_herdr_control_exec rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

fm_backend_herdr_commit_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  : > "$marker"
}

fm_backend_herdr_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2 marker
  [ -n "$window" ] || return 0
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  fm_backend_herdr_control_exec rm -f "$marker" 2>/dev/null || true
}

# fm_backend_herdr_wait_transition: the bounded event wait. Blocks up to
# <timeout_secs> for one of <pane_window...> ("<session>:<pane_id>") to reach a
# fresh `blocked` edge, then prints the normalized record and returns 0.
# Returns 1 on a clean timeout (the reader ran the full budget, no fresh
# actionable edge - the caller has effectively already slept and just continues)
# and 2 when the event path is unusable (not capable, socket unresolved, reader
# failed to run/subscribe - the caller sleeps the budget itself, the fail-closed
# backstop). See the header block above for the full contract.
fm_backend_herdr_wait_transition() {  # <session> <timeout_secs> <state_dir> <pane_window...>
  local session=$1 timeout=$2 state=$3
  shift 3
  local windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_herdr_events_capable "$session" || return 2
  fi
  local sock
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 2

  # Map each window to its herdr pane id (strip the leading "<session>:").
  local w pane_id
  local pane_ids=()
  for w in "${windows[@]}"; do
    pane_id=${w#*:}
    if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
      continue
    fi
    pane_ids+=("$pane_id")
  done
  [ "${#pane_ids[@]}" -gt 0 ] || return 2

  # Start the raw-socket reader and wait for its subscription acknowledgement
  # before level reconciliation, so edges occurring during reconciliation are
  # already buffered in the live stream.
  local reader=()
  while IFS= read -r w; do
    reader+=("$w")
  done < <(fm_backend_herdr_event_reader_cmd)
  [ "${#reader[@]}" -gt 0 ] || return 2

  local fifo_dir fifo reader_pid line ws status agent raw record hit rc=1 reader_rc=0
  fifo_dir=$(fm_backend_herdr_control_exec mktemp -d "${TMPDIR:-/tmp}/fm-herdr-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! fm_backend_herdr_control_exec mkfifo "$fifo" 2>/dev/null; then
    fm_backend_herdr_control_exec rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  fm_backend_herdr_scrubbed_exec "${reader[@]}" "$sock" "$timeout" "${pane_ids[@]}" > "$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9< "$fifo"; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
    fm_backend_herdr_control_exec rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  if ! IFS= read -r -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  fi

  # Level reconcile on (re)connect (report section 3d): a pane already `blocked`
  # during the gap since the last subscription is returned now, once, while
  # newer edges accumulate in the active stream. `working` panes clear their
  # marker here too.
  if [ "$rc" -ne 2 ]; then
    for w in "${windows[@]}"; do
      pane_id=${w#*:}
      if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
        continue
      fi
      raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
      [ -n "$raw" ] || continue
      record=$(fm_backend_herdr_normalize_event "$pane_id" "" "$raw" "")
      if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
        printf '%s' "$hit"
        rc=0
        break
      fi
    done
  fi

  # Drain stream edges until a fresh blocked edge or the timeout. The reader is
  # a subprocess of this call (NOT a second watcher), and is killed the instant
  # a blocked edge is found.
  # Split each raw projected line (pane_id\tworkspace_id\tagent_status\tagent)
  # with `cut`, NOT `IFS=$'\t' read`: a tab is IFS-whitespace, so `read` would
  # collapse an empty middle field (e.g. an absent workspace_id) and shift the
  # status into the wrong column. `cut` preserves empty fields.
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    [ -n "$line" ] || continue
    pane_id=$(printf '%s' "$line" | fm_backend_herdr_control_exec cut -f1)
    ws=$(printf '%s' "$line" | fm_backend_herdr_control_exec cut -f2)
    status=$(printf '%s' "$line" | fm_backend_herdr_control_exec cut -f3)
    agent=$(printf '%s' "$line" | fm_backend_herdr_control_exec cut -f4)
    [ -n "$pane_id" ] || continue
    record=$(fm_backend_herdr_normalize_event "$pane_id" "$ws" "$status" "$agent")
    if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
      printf '%s' "$hit"
      rc=0
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  if [ "$rc" -eq 2 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  # No actionable edge: distinguish a clean full-budget wait (reader exit 0 ->
  # return 1, caller already waited) from a reader error (connect/subscribe
  # failure, exit non-zero -> return 2, caller sleeps and counts toward the
  # runtime-disable threshold).
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  fm_backend_herdr_control_exec rm -rf "$fifo_dir" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ "$reader_rc" -eq 0 ] && return 1
  return 2
}
