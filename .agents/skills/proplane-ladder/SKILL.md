---
name: proplane-ladder
description: >-
  Agent-only reference for PropPlane multi-agent branch ladder work: keeper branches,
  localhost review ports, token-efficient Playwright smoke tests, and no remote feature branches.
  Load before PropPlane ship or scout work, before running branch e2e, and when briefing
  crewmates on proplane tasks.
user-invocable: false
metadata:
  internal: true
---

# proplane-ladder

Load before PropPlane ship or scout work, when running ladder Playwright smoke tests, or when briefing crewmates on proplane.

Canonical owner: `data/captain.md` (captain gates), `config/proplane-agent-branches` (paths and ports),
and `config/proplane-active-sandbox` (which keeper branch this Cursor pane owns).

**Cursor IDE (direct prompts):** load `.cursor/rules/proplane-active-sandbox.mdc` in the firstmate workspace, or open the
assigned worktree as the workspace folder. Resolve paths with `bin/fm-proplane-active-worktree.sh`.
Implement only in that worktree; never treat `projects/proplane-prakrit` as the edit target from an agent sandbox pane.

## Keeper branches (GitHub must hold only these)

| Agent | Branch | Localhost |
|-------|--------|-----------|
| Claude 1 | `claude-1` | http://localhost:3012 |
| Claude 2 | `claude-2` | http://localhost:3013 |
| Cursor 1 | `cursor-1` | http://localhost:3010 |
| Cursor 2 | `cursor-2` | http://localhost:3011 |
| Integration | `prakrit` | http://localhost:3000 |
| Preview | `main` | Vercel Preview |
| Live | `production` | prop-lane.space |

Also allowed on `origin`: `main` and `production` only besides the five agent/integration branches above.

**Never push** `fm/*`, feature, or task branches to GitHub.
Land commits on the owning keeper branch in that agent's worktree only.

**Promotion PR (standing captain order, 2026-07-31):** every `prakrit` → `main` promotion opens a promotion-record PR from `prakrit` into `main`, carrying the promoted commit range, the security-review outcome, and the validation outcome.
`bin/fm-proplane-promote-prakrit-to-main.sh --push-main` opens it, and `bin/fm-proplane-promote-pr-lib.sh` owns the contract.
It is a record, not a second gate: the ladder fast-forwards `main` right after opening it, and a GitHub failure warns without stopping the promotion.
The promotion is built on `integrate/prakrit-to-main`, which is never pushed to GitHub, so the PR is opened from `prakrit` and the body reconciles the two: the promoted range is authoritative, and any commit the PR's diff omits or shows without landing is named there.
GitHub closes the PR as merged only when `prakrit` carries nothing the promotion left behind; when it does not close, the body says so and the next promotion's record replaces it.
Open **no other** PR unless the captain explicitly asks.

## After changes land

Promote and sync restart only the dev servers they touch (no browser, no full-port sweep).
When the captain wants every port refreshed or a browser tab opened:

```bash
bin/fm-proplane-open-localhost.sh --no-browser          # restart all ports (default: no browser)
bin/fm-proplane-open-localhost.sh --open-browser prakrit  # open integration in browser when wanted
```

## Token-efficient verification

Default to ladder smoke, not the full Playwright suite.

```bash
bin/fm-proplane-branch-e2e.sh --smoke           # all ports
bin/fm-proplane-branch-e2e.sh --smoke cursor-2   # one agent
```

Inside a worktree (dev server already on that port):

```bash
PLAYWRIGHT_SKIP_WEBSERVER=1 PLAYWRIGHT_BASE_URL=http://localhost:3011 npm run test:e2e:ladder-smoke
```

Use `--full` only when the captain explicitly wants the entire e2e suite (expensive).

Use scout deliverables for investigation and audits instead of exploratory full-suite runs.

## Automation owners

| Event | Script |
|-------|--------|
| `origin/prakrit` moved | `bin/fm-prakrit-sync-agent-branches.sh` (watcher: `state/proplane-prakrit-sync.check.sh`) |
| Agent branch ready for integration | `bin/fm-proplane-promote-to-prakrit.sh <branch>` (merge, prune remotes, reset sandboxes, smoke e2e) |
| Full ladder (captain `/promote`) | `bin/fm-proplane-promote-full.sh` — see `promote` skill (includes **production → iOS TestFlight**) |
| Prakrit ready for Vercel Preview (`main`) | `bin/fm-proplane-promote-prakrit-to-main.sh` then `--push-main` after captain tests localhost (script also fast-forwards `prakrit` from `main` and resets sandboxes) |
| Refresh dev servers (optional browser) | `bin/fm-proplane-open-localhost.sh` |
| Security review only | `bin/fm-proplane-security-review.sh <worktree> --base main` |
| Prune stray GitHub branches | `bin/fm-proplane-prune-stray-branches.sh` (also runs after promote-to-prakrit) |

After promote, sandboxes reset from `origin/prakrit` so each agent starts self-contained from integration.

## What moves when you promote (not MD-only)

There is **no separate “update markdown only” step**. Every file on the branch — `.md`,
`.tsx`, tests, etc. — moves together with git.

### Promote agent → `prakrit` (`fm-proplane-promote-to-prakrit.sh <branch>`)

1. **Into integration:** merge `origin/<agent-branch>` **into** `prakrit` (in the prakrit worktree), then push `prakrit`.
2. **Back out to every sandbox:** `fm-prakrit-sync-agent-branches.sh --reset-from-prakrit` sets **each** keeper branch (`claude-1`, `claude-2`, `cursor-1`, `cursor-2`) to **exactly** `origin/prakrit` (`git reset --hard`, not a second merge), then pushes that branch.

So after promote, all agent branches **match** `prakrit` (integration + every prior promote), not just the branch you promoted.

### When `origin/prakrit` moves without a full promote reset

`fm-prakrit-sync-agent-branches.sh` (no `--reset-from-prakrit`) **merges** `origin/prakrit`
**into** each agent branch when the sandbox does not already contain it, then pushes the
agent branch. Use this when integration moved and sandboxes should pick up prakrit without
wiping local-only commits.

| Direction | When | Mechanism |
|-----------|------|-----------|
| `<agent>` → `prakrit` | Captain approves promote | merge in prakrit worktree |
| `prakrit` → all sandboxes | After promote (`--reset-from-prakrit`) | hard reset each sandbox to `origin/prakrit` |
| `prakrit` → each sandbox | Watcher / manual sync (default) | merge `origin/prakrit` into sandbox if needed |

Pushing to `prakrit` by hand (without the promote script) updates integration only; run
`fm-prakrit-sync-agent-branches.sh --reset-from-prakrit` so sandboxes receive the same
commits before the next PropPlane task.

## Firstmate / crewmate dispatch

- **Never** implement PropPlane features in `proplane-prakrit` — that tree is
  integration-only (localhost **3000**).
- **Always** brief crewmates with the owning sandbox worktree from
  `config/proplane-agent-branches` and require commits on that keeper branch only.
- **After every `origin/prakrit` push**, run `bin/fm-prakrit-sync-agent-branches.sh
  --reset-from-prakrit` (or ensure the prakrit-sync watcher has fired) before
  dispatching the next PropPlane prompt.

## Worktree isolation

Never check out another agent's worktree or branch without captain approval.
Never develop on `projects/proplane` git root for feature work — use the assigned worktree.
