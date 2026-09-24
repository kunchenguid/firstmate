---
name: jev
description: >-
  Configure or inspect Firstmate's Jev dispatch resolver when the captain invokes /jev, /jev status, /jev shadow, /jev on, or /jev off.
user-invocable: true
metadata:
  internal: true
---

# jev

Use `bin/fm-jev.sh` as the single mutation and status interface for this home's Jev mode.

- `/jev` and `/jev status` run `bin/fm-jev.sh status`.
- `/jev shadow` records Jev's recommendation for every eligible dispatch but leaves the normal Firstmate intake authoritative.
- `/jev on` allows a clear Jev result to select the dispatch profile.
- `/jev off` stops Jev calls without deleting credentials or prior shadow records.

After the command, report its one-line result in plain language.
If the key is missing, say that `OPENROUTER_API_KEY` must be added to this home's `.env` or environment before `shadow` or `on` can make requests; never ask for or print the key itself.
Do not reinterpret `shadow` as permission to apply a recommendation.
