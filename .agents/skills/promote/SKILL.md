---
name: promote
description: >-
  Run the full PropPlane keeper ladder promote after sandbox work is committed:
  active agent branch (or named branch) → prakrit → main → production. Use when
  the captain invokes /promote, /prmote, "promote to prakrit", "promote to main
  and production", or asks to ship the PropPlane ladder end to end.
user-invocable: true
metadata:
  internal: true
---

# promote

Captain shortcut for the PropPlane multi-agent ladder.
Load `proplane-ladder` for branch names, ports, and what each step does.

## Preconditions

- PropPlane changes are **committed** on the owning keeper branch (usually the active sandbox from `config/proplane-active-sandbox`, default `cursor-2`).
- Work happened in that sandbox worktree only, not in the prakrit integration tree.
- `no-mistakes` CLI is available for the prakrit → main step.
- `config/proplane-agent-branches` and `config/proplane-active-sandbox` are configured under `FM_HOME`.

## What to run

From the firstmate repo root with `FM_HOME` set to this home:

```sh
bin/fm-proplane-promote-full.sh
```

Optional:

```sh
bin/fm-proplane-promote-full.sh cursor-2          # explicit agent branch
bin/fm-proplane-promote-full.sh --no-production   # stop after main (Vercel Preview only)
bin/fm-proplane-promote-full.sh --dry-run         # print the steps and preview the promotion record PR, opening nothing
bin/fm-proplane-promote-full.sh --skip-agent-push # agent branch already pushed
```

The script:

1. Pushes the agent branch if local commits are ahead of `origin/<branch>`.
2. Runs `bin/fm-proplane-promote-to-prakrit.sh` (merge into prakrit, push, reset sandboxes).
3. Runs `bin/fm-proplane-promote-prakrit-to-main.sh --push-main` (security review, no-mistakes validation, promotion record PR, fast-forward `main`).
4. Runs `scripts/promote-main-to-production.sh` in the PropPlane git root (fast-forward `production`, live deploy, **iOS TestFlight**).

## iOS (TestFlight)

The native iOS app is a Capacitor shell that loads the live site (`prop-lane.space`). It does **not** update from `main` alone.

- **TestFlight uploads run only when `production` moves** — GitHub Action `iOS TestFlight` on push to `production`.
- A full `/promote` must include step 4. Do **not** use `--no-production` unless the captain explicitly wants Preview-only (no live site, no iOS).
- After production push, confirm the workflow is green: `gh run list --repo PrakritR/PropLane --workflow=ios-testflight.yml --limit 1`

## If no-mistakes parks

When step 3 stops at a gate, drive it with `no-mistakes axi respond`, then:

```sh
bin/fm-proplane-promote-prakrit-to-main.sh --validate-only
bin/fm-proplane-promote-prakrit-to-main.sh --push-main
```

Simpler recovery after gates pass:

```sh
bin/fm-proplane-promote-full.sh --skip-agent-push
```

Production-only after main is already pushed:

```sh
GIT_ROOT="$(awk -F '\t' '$1=="GIT_ROOT"{print $2; exit}' "${FM_HOME}/config/proplane-agent-branches")"
bash "$GIT_ROOT/scripts/promote-main-to-production.sh"
```

## Report to the captain

Translate outcomes per `AGENTS.md` section 9: integration on localhost **3000**, Preview on `main`, live site on **production** / prop-lane.space, **iOS TestFlight** after production push.
Mention any blocked merge, failed push, or no-mistakes gate in plain language with the next action.
When production was promoted, note whether the iOS TestFlight workflow is queued, running, or green.
Give the captain the promotion PR's full `https://...` URL, and say plainly when it could not be opened and that the promotion itself still completed.

## Promotion PR

The `prakrit` → `main` step opens a promotion-record PR by the captain's standing order, so each promotion leaves a readable record of what moved and on what evidence.
`proplane-ladder` and `bin/fm-proplane-promote-pr-lib.sh` own that contract; nothing waits on the PR, and a re-run updates the open one instead of opening a second.
Open no other PR unless the captain explicitly asks.
