#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Both bind a run on
# strict branch-and-head identity, or on the bounded pipeline-custody exemption
# defined below. Getting this wrong in either direction is unsafe: a false
# negative hides a genuinely parked run and lets a wedged crew read as working
# forever, while a false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
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

# Scalar value of key $3 directly under the TOP-LEVEL `$2:` block in TOON $1.
#
# Anchored at both ends, because a same-named key elsewhere in the document must
# never be mistaken for this one:
#   - only a block header at ZERO indentation is bound, so a nested `$2:`
#     sub-block can never win over the real top-level block; and
#   - within that block the first more-indented line fixes the direct-child
#     indent (TOON's indent unit is never assumed), only lines at exactly that
#     indent are read, and the scan stops at the first line back at or above
#     the block's own indent, so a nested sub-block's own key is skipped.
# Empty when the top-level block or the key is absent. Every caller reads empty
# as absent evidence and denies attribution, but that denial is NOT uniformly
# safe, so do not treat empty as a free fallback:
#   - bin/fm-crew-state.sh falls back to the pane and status log, which
#     SURFACES the crew, so denial there is the conservative direction; but
#   - bin/fm-teardown.sh gets 1 back from fm_nm_run_is_pipeline_owned_active,
#     issues no `axi abort`, and leaves a parked run orphaned holding a fleet
#     slot - which is exactly the harm this change set out to remove.
# Empty is acceptable only because the top-level block shape is the verified
# contract (the captured fixtures record it). A CLI that ever indents the whole
# document under a root key would read empty everywhere, degrading crew-state
# safely and silently regressing teardown to orphaning, with no error on
# either side; re-verify the shape before relying on that.
fm_nm_block_child_scalar() {  # <toon-output> <block-key> <child-key>
  local v
  v=$(printf '%s\n' "$1" | awk -v blk="$2" -v key="$3" '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    function strip(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    !inblk {
      if (ind($0) == 0 && strip($0) == blk ":") { inblk = 1; bi = 0; ci = -1 }
      next
    }
    {
      if ($0 ~ /^[ \t]*$/) next
      i = ind($0)
      if (i <= bi) exit
      if (ci < 0) ci = i
      if (i != ci) next
      line = strip($0)
      if (index(line, key ":") == 1) { print substr(line, length(key) + 2); exit }
    }
  ')
  fm_nm_trim "$v"
}

# branch_sync.state from captured `axi status` TOON $1: the scalar DIRECTLY
# under the top-level `branch_sync:` block, never a nested sub-block's own
# `state:`. Empty when the block is absent: no run on the current branch,
# another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  fm_nm_strip_quotes "$(fm_nm_block_child_scalar "$1" branch_sync state)"
}

# 0 if run status WORD $1 is terminal: the run has finished and released the
# branch. This is the ONE place that word set is spelled. fm_nm_run_is_active
# below asks through here, so a CLI that adds a terminal word is handled by
# editing this list alone - a second copy that missed the addition would treat
# a finished run as in-flight and bind it through the exemption. Every other
# word, known or not, is treated as in-flight, which is the direction that
# keeps a genuinely live crew attributed.
fm_nm_run_word_is_terminal() {  # <status-word>
  case "${1:-}" in completed|failed|cancelled) return 0 ;; esac
  return 1
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: a POSITIVE
# non-terminal status and no terminal outcome. An ABSENT status is not evidence
# of a live run and returns 1 - the exemption below trades away the head rule,
# so it must never bind on missing information.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  [ -n "$status" ] || return 1
  ! fm_nm_run_word_is_terminal "$status"
}

# 0 if the run in $1 is parked at a gate awaiting the agent. The daemon wrote
# that gate and is holding the branch for it, which is itself positive evidence
# that the custody record is current, and a parked run never maps to `working`
# (bin/fm-crew-state.sh maps it to `parked`, which supervision surfaces rather
# than absorbs), so it cannot make a wedged crew invisible.
#
# That last clause is the reason the exemption below accepts a gate WITHOUT an
# age bound, so it is enforced rather than asserted: this is the ONE place the
# shared gate signals are spelled, and bin/fm-crew-state.sh selects its `parked`
# arm by calling here (union'd with its own extra nm_gate_status signal) instead
# of respelling them. Adding a signal here therefore widens that parked arm in
# the same edit. Never let a second copy of these signals grow: a signal known
# here but not there would bind the exemption age-unbounded and then fall
# through to `working`, restoring the permanent supervision blind spot the bound
# exists to close.
fm_nm_run_is_gate_parked() {  # <toon-output>
  local status
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  case "$status" in awaiting_approval|fix_review) return 0 ;; esac
  printf '%s\n' "$1" | grep -Eq '^[[:space:]]*(awaiting_agent|gate):'
}

# Oldest a pipeline-owned run may be and still bind through the exemption
# below, in seconds. FM_NM_CUSTODY_MAX_AGE_SECS overrides it; a malformed or
# non-positive override falls back to the default rather than removing the
# bound.
#
# 6h is not "longer than any single step": one step provably outlives it. On a
# repo where merge is left to the captain, the ci step keeps the run `running`
# for the entire CI-monitor phase and only reaches a terminal outcome once the
# PR is merged or closed (bin/fm-crew-state.sh's PR #252 note owns that fact).
# A pipeline-owned run waiting there past 6h stops binding and the crew falls
# back to its pane and status log. That is the ACCEPTED outcome, for two
# reasons: it surfaces rather than hides, which is the direction this whole
# bound exists to enforce; and a crew that reached the CI-monitor phase has
# normally already appended its own `done: PR ... checks green` line, which the
# status-log fallback reads as done. Widening the window instead would trade
# that back for the harm the bound removes - a daemon that died without writing
# an outcome reporting a wedged crew as working for as long as the window runs.
FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT=21600
fm_nm_custody_max_age_secs() {
  local v=${FM_NM_CUSTODY_MAX_AGE_SECS:-}
  case "$v" in ''|*[!0-9]*) v=$FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT ;; esac
  [ "$v" -gt 0 ] 2>/dev/null || v=$FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT
  printf '%s' "$v"
}

# Epoch seconds at which the run captured in `axi status` output $1 was
# created, decoded from that run's OWN id. Prints nothing and returns 1 when
# the id is absent or is not a ULID.
#
# This is the only run-age evidence that cannot be attributed to the wrong run.
# `axi status` publishes no timestamp field, and the one other surface that
# publishes a run date - `no-mistakes runs` - publishes no run id, so a row read
# from it can only be matched back to the captured run by branch and head sha.
# Neither identifies a run instance: a replacement run started on the same
# `fm/<id>` branch, from the same commit, between the two calls carries the same
# branch and the same sha, and lending its fresh date to the stranded run the
# first call captured restores the exact supervision blind spot the custody
# bound exists to close. A bounded row window cannot even detect that
# ambiguity, because the older of the two rows can sit past the fetch limit.
# The id travels in the SAME output being attributed, so it is the captured
# run's own age by construction, and it costs no second CLI call.
#
# no-mistakes run ids are ULIDs: 26 Crockford base32 characters whose first 10
# are the creation time in milliseconds. Verified 2026-09-02 against the
# installed no-mistakes v1.57.0 - for run 01M1J2XASY2PXBBB142ZF8A8J8 those
# characters decode to epoch 1788387175, which is exactly that run's
# runs.created_at column in ~/.no-mistakes/state.sqlite, the birth time of its
# ~/.no-mistakes/logs/<id>/ directory, and the `2026-09-02 16:12` local date
# `no-mistakes runs` printed for that row.
#
# An id that is not a ULID yields NO age, which denies the exemption and lets
# the caller fall back to the pane and log, which SURFACE the crew - the same
# conservative direction every other denial here takes. Re-verify the id format
# against a real run before relaxing that.
fm_nm_run_started_epoch() {  # <toon-output>
  fm_nm_ulid_epoch "$(fm_nm_strip_quotes "$(fm_nm_field "$1" id)")"
}

# Epoch seconds encoded in ULID $1's 48-bit timestamp prefix. Returns 1 for
# anything that is not a 26-character Crockford base32 ULID; Crockford excludes
# I, L, O and U, so an id carrying one of those is not a ULID either. Case is
# insignificant in Crockford, so a lower-case id decodes the same.
fm_nm_ulid_epoch() {  # <ulid>
  local id=${1:-} alphabet='0123456789ABCDEFGHJKMNPQRSTVWXYZ' i=0 c head ms=0
  [ ${#id} -eq 26 ] || return 1
  id=$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')
  case "$id" in *[!0123456789ABCDEFGHJKMNPQRSTVWXYZ]*) return 1 ;; esac
  while [ "$i" -lt 10 ]; do
    c=${id:$i:1}
    head=${alphabet%%"$c"*}
    [ ${#head} -lt 32 ] || return 1
    ms=$((ms * 32 + ${#head}))
    i=$((i + 1))
  done
  printf '%s' $((ms / 1000))
}

# 0 if epoch $1 is inside the custody window: not older than
# fm_nm_custody_max_age_secs and not implausibly far in the future. A missing
# or unparseable epoch is NOT fresh - absence of evidence never grants the
# exemption.
fm_nm_custody_age_fresh() {  # <epoch>
  local started=${1:-} now max
  case "$started" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  max=$(fm_nm_custody_max_age_secs)
  [ "$started" -le $((now + 300)) ] || return 1
  [ $((now - started)) -le "$max" ]
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and head equality must not be required -
# the pipeline's lane head is routinely not a git object in the task worktree
# (rebase and fix commits that were never pushed back), so the head rule
# rejects exactly the run that is most current.
#
# The exemption never applies to a terminal run: a terminal run has released
# the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
#
# It is also BOUNDED, because a run row reads `running` + `pipeline_owned`
# forever when the daemon dies without writing an outcome (host restart, OOM,
# an abort that never completed). An unbounded exemption reports such a run as
# working, which absorbs every signal and turn-end wake from that crew
# permanently - the head rule used to reject the unresolvable head and let the
# crew fall through to pane and log, which surfaces. So the exemption binds
# only with positive, current custody evidence:
#   - the run is parked at a gate (fm_nm_run_is_gate_parked): the daemon wrote
#     that gate, and parked never maps to working; or
#   - the run was created inside the custody window
#     (fm_nm_custody_age_fresh over fm_nm_run_started_epoch). That age is read
#     from the captured run's OWN id, in this same output, so no other run's
#     freshness can ever stand in for it - see fm_nm_run_started_epoch for why
#     the run-listing surface cannot supply it.
# With neither, attribution is unknown and the caller falls back to the pane
# and log, which surface a wedged crew instead of hiding it.
#
# SCOPE of that bound, so it is not read as covering more than it does: it
# bounds the EXEMPTION only, which is to say only the path where head equality
# has already failed. A run whose recorded head still equals the worktree HEAD
# never reaches here at all - it binds through the ordinary head rule above,
# with no age bound of any kind - so a daemon that dies BEFORE the pipeline
# moves the head off the crew's own commit can still report that crew working
# indefinitely. That path is left unbounded deliberately: a head-matched run
# legitimately stays `running` for the whole CI-monitor phase on a repo where
# merge is left to the captain, so bounding it would start surfacing crews that
# are correctly waiting on a captain merge. Closing that gap is a separate
# product decision about the head rule, not an oversight of this bound.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1" || return 1
  fm_nm_run_is_gate_parked "$1" && return 0
  fm_nm_custody_age_fresh "$(fm_nm_run_started_epoch "$1")"
}
