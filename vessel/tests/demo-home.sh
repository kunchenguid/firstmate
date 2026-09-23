#!/usr/bin/env bash
# demo-home.sh - build a throwaway firstmate home with a small, realistic fleet.
#
# Usage: vessel/tests/demo-home.sh <dir>
#   then: cargo run --manifest-path vessel/Cargo.toml -- --home <dir>
#
# The home has no bin/ of its own; vessel serves it with the scripts of the
# checkout it runs from (firstmate's FM_HOME override). Jira and GitHub are
# turned off so the demo needs no credentials. Nothing outside <dir> is touched.
set -eu

dir=${1:?usage: demo-home.sh <dir>}
mkdir -p "$dir/state" "$dir/data/vessel" "$dir/config/vessel" "$dir/projects/webapp"
now=$(date +%s)
ago() { echo $((now - $1)); }

meta() {
  local id=$1 kind=$2
  shift 2
  {
    echo "window=fm-$id"
    echo "worktree=$dir/projects/webapp"
    echo "project=webapp"
    echo "harness=pi"
    echo "kind=$kind"
    echo "model=gpt-5.6-luna"
    echo "spawn_gen=1"
    for line in "$@"; do echo "$line"; done
  } > "$dir/state/$id.meta"
}

meta implement-aa4fi-1234 ship mode=direct-PR yolo=off pr=https://github.com/acme/webapp/pull/7
meta review-webapp-42 scout
printf 'working at=%s: reproduced the login redirect bug\nworking at=%s: fix pushed, waiting on CI\n' "$(ago 1500)" "$(ago 300)" \
  > "$dir/state/implement-aa4fi-1234.status"
printf 'needs-decision key=scope at=%s: review only the API layer, or the UI too?\n' "$(ago 120)" \
  > "$dir/state/review-webapp-42.status"

cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

- [ ] implement-aa4fi-1234 - Implement AA4FI-1234 login redirect fix (repo: webapp, kind: ship)
- [ ] review-webapp-42 - Review acme/webapp#42 (repo: webapp, kind: scout)

## Queued

- [ ] plan-aa4fi-99 - Plan AA4FI-99 checkout redesign (repo: webapp, kind: scout)

## Done

- [x] plan-aa4fi-1234 - Plan AA4FI-1234 login redirect fix (repo: webapp, kind: scout, reported 2026-09-23)
- [x] fix-flaky-ci - Fix the flaky CI job (repo: webapp, kind: ship, merged 2026-09-23)
EOF

mkdir -p "$dir/data/plan-aa4fi-1234" "$dir/data/implement-aa4fi-1234" "$dir/data/review-webapp-42"
cat > "$dir/data/plan-aa4fi-1234/report.md" <<'EOF'
# Plan: AA4FI-1234 login redirect fix

1. Reproduce with an expired session cookie.
2. Keep `returnTo` through the SSO round trip in `auth/callback.ts`.
3. Add a regression test in `auth/callback.test.ts`.

**Risk:** the mobile client shares the callback route.
EOF
printf '# Task\n\n## Captain'"'"'s intent\n\nImplement AA4FI-1234 following the approved plan.\n' > "$dir/data/implement-aa4fi-1234/brief.md"
printf '# Task\n\n## Captain'"'"'s intent\n\nReview acme/webapp#42.\n' > "$dir/data/review-webapp-42/brief.md"

ledger=$dir/state/fleet-ledger.jsonl
{
  printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"fix-flaky-ci","kind":"ship","project":"webapp","harness":"claude","model":null}\n' "$(ago 20000)"
  printf '{"v":1,"ts":%s,"event":"task.status","task":"fix-flaky-ci","state":"done","key":null,"text":" PR green"}\n' "$(ago 16000)"
  printf '{"v":1,"ts":%s,"event":"task.merged","task":"fix-flaky-ci","via":"pr","pr":"https://github.com/acme/webapp/pull/5"}\n' "$(ago 15000)"
  printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"fix-flaky-ci"}\n' "$(ago 14900)"
  printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"plan-aa4fi-1234","kind":"scout","project":"webapp","harness":"pi","model":"gpt-5.6-luna"}\n' "$(ago 9000)"
  printf '{"v":1,"ts":%s,"event":"task.status","task":"plan-aa4fi-1234","state":"working","key":null,"text":" reading auth flow"}\n' "$(ago 8800)"
  printf '{"v":1,"ts":%s,"event":"task.status","task":"plan-aa4fi-1234","state":"done","key":null,"text":" plan in report.md"}\n' "$(ago 7000)"
  printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"plan-aa4fi-1234"}\n' "$(ago 6900)"
  printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"implement-aa4fi-1234","kind":"ship","project":"webapp","harness":"pi","model":"gpt-5.6-luna"}\n' "$(ago 1800)"
  printf '{"v":1,"ts":%s,"event":"task.status","task":"implement-aa4fi-1234","state":"working","key":null,"text":" reproduced the login redirect bug"}\n' "$(ago 1500)"
  printf '{"v":1,"ts":%s,"event":"task.status","task":"implement-aa4fi-1234","state":"working","key":null,"text":" fix pushed, waiting on CI"}\n' "$(ago 300)"
  printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"review-webapp-42","kind":"scout","project":"webapp","harness":"pi","model":"gpt-5.6-luna"}\n' "$(ago 600)"
  printf '{"v":1,"ts":%s,"event":"task.status","task":"review-webapp-42","state":"needs-decision","key":"scope","text":" review only the API layer, or the UI too?"}\n' "$(ago 120)"
} > "$ledger"

record() { VESSEL_RUNS_FILE=$dir/data/vessel/runs.jsonl "$(dirname "$0")/../bin/vessel-record-run.sh" "$@" >/dev/null; }
record --task plan-aa4fi-1234 --workflow plan --agent Stringer --harness pi --model gpt-5.6-luna --effort high \
  --project webapp --title "Login redirect fix" --ticket AA4FI-1234
record --task implement-aa4fi-1234 --workflow implement --agent "Slim Charles" --harness pi --model gpt-5.6-luna \
  --effort high --project webapp --title "Login redirect fix" --ticket AA4FI-1234 \
  --repo acme/webapp --pr 7 --plan-task plan-aa4fi-1234
record --task review-webapp-42 --workflow review --agent Snoop --harness pi --model gpt-5.6-luna --effort high \
  --project webapp --title "Add rate limiting to the login API" --repo acme/webapp --pr 42 --pr-head 3f2a9c1
# The recorder stamps "now"; move each record next to its dispatch.
tmp=$(mktemp)
jq -c --argjson now "$now" '
  .ts = (if .task == "plan-aa4fi-1234" then $now - 9000
         elif .task == "implement-aa4fi-1234" then $now - 1800
         else $now - 600 end)' "$dir/data/vessel/runs.jsonl" > "$tmp"
mv "$tmp" "$dir/data/vessel/runs.jsonl"

: > "$dir/config/fleet-ledger"
touch "$dir/state/.last-watcher-beat"
printf '{"github_enabled": false, "jira_enabled": false}\n' > "$dir/config/vessel/vessel.json"
echo "demo home ready: $dir"
