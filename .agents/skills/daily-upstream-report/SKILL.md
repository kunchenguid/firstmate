---
name: daily-upstream-report
description: >-
  Agent-only handling procedure for an authenticated `daily-upstream-report <report-id>` check notification.
  Use it to read the exact preserved morning report, translate deterministic findings into captain-facing outcomes, retain unsupported or report-only conclusions as such, and acknowledge only that report after synthesis.
user-invocable: false
metadata:
  internal: true
---

# daily-upstream-report

Load this skill only for an authenticated `daily-upstream-report <report-id>` check notification.
The public script owner at `bin/fm-daily-upstream.sh` owns the private receipt, report, offer, installation, and acknowledgement mechanics.

1. Copy the exact structural report id from the notification without deriving it from a path or prose.
2. Run `bin/fm-daily-upstream.sh show-report <report-id>` and stop without acknowledging if the command refuses the id or the report cannot be read safely.
3. Treat the report as dated deterministic evidence rather than current-state proof, especially for repository movement, package opportunities, services, backups, credentials, and Mac health.
4. Summarize concrete outcomes, risks, untouched opportunities, and any action that now needs the captain, following `AGENTS.md` section 9 rather than relaying report lines verbatim.
5. Describe a new Kun Chen upload as public metadata awaiting a relevance decision, and never download or analyze it during this handling turn.
6. If later analysis is useful and separately authorized, route it through the accepted `/watch` capability rather than recreating acquisition logic here.
7. After the synthesis is ready to send, run `bin/fm-daily-upstream.sh acknowledge <report-id>` once.
8. If another report remains queued, let the authenticated check mechanism offer it on its ordinary cycle rather than reading arbitrary report files.
