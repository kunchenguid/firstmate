#!/usr/bin/env bash
set -u
case "$*" in
  "kanban show --json "*)
    printf '%s\n' '{"task":{"id":"task:1","status":"running"},"events":[],"runs":[],"latest_summary":"active"}'
    ;;
  "kanban stats --json")
    printf '%s\n' '{"by_status":{"ready":2},"by_assignee":{"crew":{"ready":2}},"oldest_ready_age_seconds":259200,"now":1789052400}'
    ;;
  "kanban notify-list")
    printf '%s\n' '  task:1  discord:123  (since event 9)  owner=owner-1  chat_type=channel  mode=notify+wake'
    ;;
  "monitoring status")
    printf '%s\n' 'Gateway monitoring' '  Health export:  disabled (monitoring.gateway_health_export.enabled)' '  OTLP endpoint:  not configured (monitoring.export.otlp)' '  OTel SDK:       not installed (optional extra: hermes-agent[otlp])' '  Scope: gateway service health + redacted diagnostics only.'
    ;;
  "insights --days 1")
    printf '%s\n' 'Period: Sep 09, 2026 - Sep 10, 2026' 'Sessions: 30 Messages: 1,182' 'Tool calls: 738' 'Total tokens: 23,780,716' 'Model gpt-5.6-sol 8 9,466,897' 'Platform kanban 8 356 9,466,309'
    ;;
  "doctor")
    printf '%s\n' '◆ Auth Providers' '  ✓ OpenAI Codex auth (logged in)' '  ⚠ MiniMax OAuth (not logged in)' '  ⚠ No API key found in profile .env'
    ;;
  "cron list")
    printf '%s\n' '  job:1 [active]' '    Name:      pilot-disk-alert' '    Schedule:  0 * * * *' '    Next run:  2026-09-10T16:00:00+00:00' '    Deliver:   local' '    Script:    disk-occupancy.sh' '    Last run:  2026-09-10T15:00:00+00:00  ok' '    Execution: succeeded  execution-1'
    ;;
  "cron doctor")
    printf '%s\n' 'Cron doctor found 1 issue(s) across 1 job(s):' '  job:1 pilot-disk-alert' '    - script not found: disk-occupancy.sh'
    ;;
  *) printf 'unexpected fixture command: %s\n' "$*" >&2; exit 64 ;;
esac
