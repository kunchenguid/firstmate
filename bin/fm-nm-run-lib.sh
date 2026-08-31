#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption defined below. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
# Unless an operator explicitly supplies NM_HOME, a Firstmate home owns the
# private `$FM_HOME/.no-mistakes` instance used by every call through this owner.
fm_nm_home() {
  if [ -n "${NM_HOME:-}" ]; then
    printf '%s\n' "$NM_HOME"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/.no-mistakes\n' "${FM_HOME%/}"
  else
    printf '%s/.no-mistakes\n' "${HOME:-}"
  fi
}

fm_nm_converge_agent_config() {  # <config-file>  -> stdout, exit 2 on malformed
  # Format-safe convergence of the `agent:` key to `agent: [codex]`, covering
  # every syntax the current reader (bin/fm-spawn.sh no_mistakes_configured_reviewers)
  # accepts: inline flow sequences, multiline `- ` sequences, full-line and
  # trailing comments, and duplicate keys (collapsed to one). A malformed agent
  # value (e.g. an unterminated flow sequence) is refused rather than silently
  # rewritten into a plausible shape.
  awk '
    function valid_value(v,    depth, i, ch, n) {
      if (v !~ /^\[/) return v !~ /[\[\]]/
      if (v !~ /\][[:space:]]*$/) return 0
      depth = 0; n = length(v)
      for (i = 1; i <= n; i++) {
        ch = substr(v, i, 1)
        if (ch == "[") depth++
        else if (ch == "]") { depth--; if (depth < 0) return 0 }
      }
      return depth == 0
    }
    BEGIN { saw_agent = 0; in_seq = 0 }
    in_seq {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
        val = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", val); sub(/[[:space:]]+#.*$/, "", val)
        if (!valid_value(val)) exit 2
        next
      }
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { print; next }
      in_seq = 0
    }
    !in_seq && /^[[:space:]]*agent[[:space:]]*:/ {
      val = $0
      sub(/^[[:space:]]*agent[[:space:]]*:[[:space:]]*/, "", val)
      sub(/[[:space:]]+#.*$/, "", val)
      if (val != "") {
        if (!valid_value(val)) exit 2
        if (!saw_agent) { print "agent: [codex]"; saw_agent = 1 }
        next
      }
      if (!saw_agent) { print "agent: [codex]"; saw_agent = 1 }
      in_seq = 1
      next
    }
    { print }
    END { if (!saw_agent) print "agent: [codex]" }
  ' "$1"
}

fm_nm_prepare_home() {
  [ -n "${NM_HOME:-}" ] && return 0
  local home config tmp
  home=$(fm_nm_home) || return 1
  # The default root must remain a real directory contained by canonical FM_HOME;
  # reject a symlinked or special-file root before any write so the home-owned
  # config can never escape the home boundary through a pre-existing link.
  if [ -e "$home" ] && { [ ! -d "$home" ] || [ -L "$home" ]; }; then
    return 1
  fi
  # The captain-private root is owner-only under any umask (AGENTS.md classifies
  # .no-mistakes/ as captain-private operational state).
  mkdir -p "$home"
  chmod 0700 "$home"
  config="$home/config.yaml"
  if [ ! -e "$config" ]; then
    # Publish the initial config owner-only via a safe temporary file so a
    # permissive umask never leaves it world-readable mid-publication.
    tmp=$(mktemp "$config.tmp.XXXXXX") || return 1
    printf 'agent: [codex]\n' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$config"
    return 0
  fi
  [ -f "$config" ] && [ ! -L "$config" ] || return 1
  chmod 0600 "$config"
  tmp=$(mktemp "$config.tmp.XXXXXX") || return 1
  if ! fm_nm_converge_agent_config "$config" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$config"
}

# Per-task run-root binding read from state/<id>.meta. A post-rollout task
# records nm_home=<root> at spawn; crew-state and teardown observe that exact
# root so a pre-rollout or mismatched run can never disappear. A task with no
# nm_home binding predates the per-home isolation rollout and is observed at
# the legacy shared default root ($HOME/.no-mistakes), so its parked runs stay
# visible rather than being hidden by the new private root (a false negative
# the owner's own contract forbids). The legacy runs are not migrated.
fm_nm_home_for_meta() {  # <meta-file>
  local meta=$1 nm_home
  [ -n "$meta" ] && [ -f "$meta" ] || {
    printf '%s/.no-mistakes\n' "${HOME:-}"
    return 0
  }
  if ! nm_home=$(fm_meta_optional_exact_value "$meta" nm_home); then
    return 1
  fi
  if [ -n "$nm_home" ]; then
    printf '%s\n' "$nm_home"
    return 0
  fi
  printf '%s/.no-mistakes\n' "${HOME:-}"
}

fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none nm_home
  shift 2
  nm_home=$(fm_nm_home) || return 1
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && NM_HOME="$nm_home" timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && NM_HOME="$nm_home" gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && NM_HOME="$nm_home" perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# fm_nm_run_is_pipeline_owned_active below carries the one exemption: a live
# run whose pipeline currently owns the branch binds without head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}
