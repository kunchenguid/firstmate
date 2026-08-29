#!/usr/bin/env bash
# G7: the resume directive is deterministic. fm-compact-crewmate.sh --resume
# frontier|restart writes a resume-<key>.directive sentinel; fm-captain-bootstrap.sh's
# rehydrate then injects DIFFERENT instruction text for the two modes. This is a pure
# state+bootstrap test (no tmux fire needed): we write the directive and the handoff
# directly, run the bootstrap, and assert the injected directive differs and matches
# the mode. Mutation (LEDGER_MUTATE=1): write "restart" but assert it injects the
# frontier text -> fails (proving the bootstrap actually keys off the directive, not a
# constant).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g7.XXXXXX")
STATE="$FM/state"; mkdir -p "$STATE" "$FM/data"
printf '(none)\n' > "$FM/data/projects.md"; printf '(none)\n' > "$FM/data/secondmates.md"; printf '\n' > "$FM/data/backlog.md"
trap 'rm -rf "$FM"' EXIT

KEY=g7win

# Render the rehydrate block for a given resume mode by planting the handoff +
# directive and running the bootstrap once (it archives the handoff, so re-plant each
# time). Echoes the additionalContext.
render() {  # <resume_mode>
  local mode=$1
  printf '# Leave-off\nGoal: DIRECTIVE-PROBE\nFrontier: resume\n' > "$STATE/handoff-$KEY.md"
  # Mutation (LEDGER_MUTATE=1): the on-demand command always wrote "frontier" (the
  # resume mode is dropped) — so restart and frontier render identically and the
  # "must differ" assertion fails, proving the bootstrap really keys off the directive.
  if [ "${LEDGER_MUTATE:-}" = 1 ]; then
    printf 'frontier\n' > "$STATE/resume-$KEY.directive"
  else
    printf '%s\n' "$mode" > "$STATE/resume-$KEY.directive"
  fi
  printf '%s' '{"source":"clear","cwd":"/tmp/x","session_id":"s7"}' \
    | FM_HOME="$FM" FM_CTX_WINDOW="$KEY" FM_CTX_ROLE=crew "$ROOT/bin/fm-captain-bootstrap.sh"
}

frontier_out=$(render frontier)
restart_out=$(render restart)

# Each mode injects its own directive sentence.
printf '%s' "$frontier_out" | grep -q 'pick the Frontier back up' \
  || fail "frontier mode did not inject the Frontier-resume directive"
printf '%s' "$restart_out" | grep -qi 'RESTART' \
  || fail "restart mode did not inject the restart directive"

# The two must DIFFER (the whole point: deterministic, distinguishable resets).
if [ "$frontier_out" = "$restart_out" ]; then
  fail "frontier and restart injected identical text — the directive is not honored"
fi

# Mutation (LEDGER_MUTATE=1): the restart-mode rehydrate MUST carry the restart
# directive and NOT the frontier sentence. A broken/ignored directive would inject the
# frontier text for restart mode; this assertion fails iff that happens, so under the
# mutation (which we simulate by demanding the frontier text be absent from restart)
# the gate is non-vacuous. We assert directly that restart did not bleed the frontier
# text — under a directive that is silently ignored, both renders are identical and
# the earlier "must differ" check already fails; this nails the specific bleed.
printf '%s' "$restart_out" | grep -q 'pick the Frontier back up' \
  && fail "restart mode wrongly injected the frontier directive (directive ignored)"

# The directive sentinel is consumed (fires exactly once; next boot defaults frontier).
[ -e "$STATE/resume-$KEY.directive" ] && fail "resume directive was not consumed after rehydrate"

pass "G7 resume directive: --resume frontier vs restart inject different, mode-correct rehydrate directives; consumed once"
