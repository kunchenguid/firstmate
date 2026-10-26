<p align="center">
  <picture>
    <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="assets/hero-mobile-dark.png">
    <source media="(max-width: 600px)" srcset="assets/hero-mobile-light.png">
    <source media="(prefers-color-scheme: dark)" srcset="assets/hero-dark.png">
    <img src="assets/hero-light.png" alt="Juggernaut — Ship like it's a game. An armoured operator charges forward through ember and dust." width="100%">
  </picture>
</p>

<p align="center">
  <a href="#what-it-is">WHAT IT IS</a> ·
  <a href="#features">FEATURES</a> ·
  <a href="#how-it-works">HOW IT WORKS</a> ·
  <a href="#quick-start">QUICK START</a> ·
  <a href="#built-in-skills">SKILLS</a> ·
  <a href="#proof-and-decision-tools">TOOLS</a> ·
  <a href="#documentation">DOCS</a>
</p>

<p align="center">
  <a href="https://github.com/umeranjum17/juggernaut"><img alt="Platform: macOS and Linux" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-FF5A1F?style=flat-square&labelColor=0A0908"></a>
  <a href="https://x.com/umership"><img alt="X: @umership" src="https://img.shields.io/badge/-@umership-EDE6DA?style=flat-square&labelColor=FF5A1F&logo=x&logoColor=0A0908"></a>
</p>

<p align="center"><sub><strong>Ship like it's a game.</strong> · Talk to one agent. Ship with a crew.</sub></p>

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## What it is

You can run one coding agent easily. But the moment you want three missions running at once — fixes, recons, plans, audits — you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

| The tab-juggler | The Juggernaut |
|---|---|
| Three missions, three terminals. You are the router, the memory, and the status board. | One liaison. The Overwatch dispatches the squad, each operator in its own worktree, and reports plain objectives secured. |

Juggernaut flips the model. You talk to a single agent — the **Overwatch** — and it runs the squad for you: spawning autonomous operators in a visible session backend, giving each a clean git worktree, supervising them to the objective, and handing you finished PRs, approved local merges, or standalone recon reports.

For larger fleets, you can opt in to persistent secondmates: second mates that are still ordinary direct reports, but run from their own isolated Juggernaut homes on this machine or another SSH-reachable host.

> Juggernaut is not a model, not a harness, not a skill, not an MCP server, and not a CLI. It is an **agent distro** for running a squad of agents.

An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one. There is no app to install: the cloned repo is the distro — `AGENTS.md`, bundled Juggernaut skills, and helper scripts that any terminal coding agent can follow. Launching a supported harness inside it for your primary session instantiates your Overwatch — and makes you the Captain.

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## Features

### Command

- **One liaison** — you talk only to the Overwatch; it dispatches, supervises, escalates only real decisions, and reports plain objectives secured.
- **A visible squad** — every operator works in its own tmux window or Herdr tab, or in an experimental Zellij, cmux, or Orca terminal you can watch or type into; the Overwatch reconciles.
- **Explicit project modes** — each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with optional `+yolo` merge autonomy, a `branch=<prefix>` override for the default `fm/` ship-branch prefix, and a `forge=gerrit` binding that publishes a Gerrit change instead of a pull request.

### Mission

- **Two mission shapes** — ship missions deliver authorized changes; recon missions leave standalone findings when the intake contract warrants separate research.
- **Disposable worktrees** — each mission runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Event-driven, zero-token supervision** — a bash watcher sleeps on the fleet and wakes the Overwatch only when something needs you; verified harnesses also get a turn-end backstop.
- **Restart-proof** — all state lives on disk and in the active session backend; the next session reconciles after a restart, and ordinary supervision recovers confirmed-dead operators.

### Boundaries

- **Self-repo boundary** — a home runs as a Juggernaut user/operator by default; publishing to Juggernaut's own repository needs the `config/firstmate-role` maintainer opt-in or per-mission Captain consent ([schema](docs/configuration.md#juggernaut-role-configfirstmate-role)).
- **Strict project boundary** — the Overwatch is read-only over your projects except the narrow, Captain-approved operations in [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including fleet sync's guarded safe branch pruning; operators make every other change behind the merge authority.

### Scale and reach

- **Optional secondmates** — opt in to persistent second mates in isolated Juggernaut homes with their own `FM_HOME`, state, projects, and session lock, locally or on an SSH-reachable host, with guarded updates and recovery.
- **Optional Relay** — opt in with one local `.env` pairing token so Juggernaut can answer public X and Discord mentions through the same lifecycle as chat, acknowledge spawned work, and post up to three public-safe follow-ups within seven days; dry-run previews would-be replies locally.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## How it works

<p align="center">
  <picture>
    <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="assets/flow-mobile-dark.png">
    <source media="(max-width: 600px)" srcset="assets/flow-mobile-light.png">
    <source media="(prefers-color-scheme: dark)" srcset="assets/flow-dark.png">
    <img src="assets/flow-light.png" alt="Juggernaut mission flow: the Captain talks to the Overwatch, which dispatches operators into isolated worktrees and brings back PRs, merges, or recon reports." width="100%">
  </picture>
</p>

You chat with the Overwatch. It routes each request to an operator in its own session endpoint and git worktree, supervises the squad with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or recon reports.

Optional secondmates extend this to persistent local or remote second mates; dispatch profiles steer which harness handles which mission; Relay lets the same squad answer public mentions. `codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns that boundary.

Full architecture — supervision, worktrees, secondmates, project modes, Relay, fleet sync, and self-update — is in [docs/architecture.md](docs/architecture.md).

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## Quick start

### Requirements

- A verified primary agent harness: Claude Code, Grok, Pi, `pi-signed`, Oh My Pi (`omp`), Codex, OpenCode, or Cursor Agent CLI.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- The CLI and dependencies for your selected runtime backend; tmux is the reference default.

The Overwatch detects and offers to install supported missing tools after you approve. Backend-specific setup is linked in [Documentation](#documentation).

### Install and launch

```sh
gh auth login
gh repo clone umeranjum17/juggernaut
cd juggernaut
```

Then launch one of the co-primary harnesses; `AGENTS.md` takes over from there:

| Harness | Launch |
|---|---|
| **Claude Code** | `claude` |
| **Grok** | `grok --trust` |
| **Pi** | `pi` — or `FM_PI_HARNESS=pi-signed pi-signed` when the signed wrapper is installed |
| **Oh My Pi** | `omp` — or `FM_OMP_HARNESS=omp omp` from inside a Claude Code pane |

Codex, OpenCode, and Cursor Agent CLI are also verified primaries. See the harness notes below.

<details>
<summary><strong>Harness notes</strong></summary>

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary Juggernaut session, with `pi-signed` supported as Pi's distinct signed-wrapper identity. Claude Code uses a tracked Stop hook for tokenless watcher re-arm and rewake, Grok uses background-notify wake cycles, and Pi uses its tracked primary watcher extension. All three have verified turn-end guard paths when launched with their documented setup. Pick whichever one matches your subscription and workflow.

Oh My Pi (`omp`), a Pi fork, is verified as a primary with the same extension-owned watcher model as Pi and a stronger turn-end guard: its blocking `session_stop` hook compels a continuation instead of requesting one. Start `omp` with this checkout as its working directory: it auto-discovers the tracked `.omp/extensions/*.ts` files with no trust dialog, and naming them with `-e` as well would load each twice.

Codex and OpenCode are also verified and supported as primary harnesses; Codex uses bounded foreground checkpoints, and OpenCode uses a TUI plugin, so both carry more harness-specific supervision tradeoffs than the three co-primaries.

Cursor Agent CLI is verified as a primary too, using a tracked project-scope `.cursor/hooks.json` whose `stop` hook parks on the watcher between turns, closest in shape to Claude Code's. Launch it with `--trust`, or none of its project hooks load; it also has no turn-end hook in headless `cursor-agent -p`, so run the primary session interactively.

For Grok, `--trust` is needed once per clone so project hooks and the turn-end guard load; `/hooks-trust` inside Grok works too. For Pi, approve the project trust prompt once per clone on first launch so the tracked `.pi/extensions/*.ts` files auto-load.

The `/calm` toggle on Pi, and on Claude Code behind its default-off early-access function-hooks flag, hides supported transcript chrome, including canonically classified Juggernaut operational user rows, and uses a Calm-only animated working boat during active runs while preserving all model context and session data. Calm changes only presentation, not the user-role delivery, ordering, authority, persistence, or exports of the operational inputs it hides. The preference persists for the effective Juggernaut home, and toggling it off restores ordinary rendering. [Calm's current behavior and supported limits](docs/calm.md) are separate from its [version-scoped maintainer evidence](docs/calm-mode-feasibility.md).

Pi's `/supervision-model` command pins a cheaper model and a shallower reasoning effort for the supervision branch alone, from the eligible models and thinking levels Pi itself reports; with no pin, the branch normally follows your own conversation's model and effort. See the [configuration schema](docs/configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).

</details>

### Talk to it

```sh
> ahoy! look at my project xyz
  fix flaky login test, add dark mode

# Checks toolchain, asks before installing.
# Clones the project, spawns two operators.
# Minutes later:

  PR ready for review, Captain:
  https://github.com/you/xyz/pull/42
  (login test - risk: low - CI green)

> alright merge it
```

<p align="center">
  <picture>
    <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="assets/secured-mobile-dark.png">
    <source media="(max-width: 600px)" srcset="assets/secured-mobile-light.png">
    <source media="(prefers-color-scheme: dark)" srcset="assets/secured-dark.png">
    <img src="assets/secured-light.png" alt="Objective secured: the operator raises a fist; the Overwatch reports a PR ready for review, Captain." width="100%">
  </picture>
</p>

### More backends

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## Built-in skills

Juggernaut ships these user-invocable built-in skills. Claude and Grok use the slash form shown here; Codex uses the same names with `$`, such as `$afk`.

- **`/afk`** — away-mode supervision: Pi's in-process branch, a [supervision host](docs/configuration.md#supervision-host-configsupervision-host), or the daemon handles wakes while you step away. See the [away procedure](.agents/skills/afk/SKILL.md) for the posture and return contract.
- **`/quiet`** — keep routine wakes off main while you stay and chat; `/quiet off` ends it.
- **`/ahoy`** — recap session events and unanswered Captain decisions, then walk open decisions one at a time.
- **`/bearings`** — four-section fleet sitrep; `file` writes a dated report, `include PRs` adds live GitHub enrichment.
- **`/updatefirstmate`** — guardedly update Juggernaut and its secondmates, then restart live mates on the target commit.
- **`/stow`** — sweep the session for uncaptured durable knowledge and report what is safe to reset.

Bearings invocation examples:

- `/bearings` returns the four-section sitrep in chat only.
- `/bearings file` writes today's dated `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file include PRs` adds live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by Juggernaut at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Juggernaut's skills live in two separate places with different audiences:

- `.agents/skills/` — agent-loaded skills for live Juggernaut homes. Each carries `metadata.internal: true`, which hides it from installer discovery such as the [skills.sh](https://skills.sh) `npx skills add` installer.
- `skills/` — public, installer-facing skills meant to stand alone in any project; today that is `skills/stow`, a generic session-knowledge-sweep skill.

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## Proof and decision tools

Three companion tools fit Juggernaut without changing it, and each also works with no Juggernaut at all. Every hook below is optional and does nothing until you add it.

- **[done-done](https://github.com/umeranjum17/done-done-axi)** — proof that "done" is real.
- **[sign-off](https://github.com/umeranjum17/sign-off)** — answer decisions with one click.
- **[learn-from-mistakes](https://github.com/umeranjum17/learn-from-mistakes)** — stop repeated mistakes.

<details>
<summary><strong>Install the three tools</strong></summary>

```sh
# done-done
npx skills add umeranjum17/done-done-axi --skill done-done -g -a claude-code -y
npm install -g --allow-git=all github:umeranjum17/done-done-axi
cat "$(npm root -g)/done-done-axi/integrations/firstmate/brief-include.md" >> "$FM_HOME/config/brief-include.md"
cp "$(npm root -g)/done-done-axi/integrations/firstmate/merge-gate" "$FM_HOME/config/merge-gate"

# sign-off
npx skills add umeranjum17/sign-off --skill sign-off-axi

# learn-from-mistakes
npx skills add umeranjum17/learn-from-mistakes --skill lfm-retro
```

Run the `cat >>` line once: each run appends the brief include again, duplicating it in every brief.

- `config/brief-include.md` is appended to every ship and recon brief, so every operator proves its change with done-done ([details](docs/configuration.md#home-brief-include-configbrief-includemd)).
- `config/merge-gate` is enforced by the merge-card add-on when it is installed; without the add-on, core does not check it. The gate runs `done-done check` against the mission's PR, or its `data/<task-id>/checks.md` when there is no PR, with the default-branch rules, then `receipt --verify <head>`. A nonzero exit refuses the merge and shows its output. Run `git fetch origin` first, since the gate reads local origin refs.

**sign-off** raises a card on the sign-off board for every mission held in a home where it is armed. Run `bin/fm-procevent-signoff.sh arm` once in a home; arm each secondmate home the same way, and your click comes back to Juggernaut as the answer to that hold ([details](docs/configuration.md#process-to-event-sources-stateprocevent)). The adapter needs `sign-off-axi` on your PATH; open the board with `sign-off-axi open`, and turn the link off with `bin/fm-procevent-signoff.sh retire`.

**learn-from-mistakes** needs no Juggernaut hook. Point it at the records your fleet already keeps, such as a defect log or failed pipeline steps, and it counts the causes that keep coming back and proposes changes that cite the real records.

</details>

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## Documentation

### Architecture and configuration

- [docs/architecture.md](docs/architecture.md) — maintainer architecture for the squad, supervision, worktrees, secondmates, and project modes.
- [docs/configuration.md](docs/configuration.md) — environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/extension-bindings.md](docs/extension-bindings.md) — maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) — current setup, routing, transfer, recovery, and safety behavior for whole-home remote second mates.
- [docs/calm.md](docs/calm.md) — current `/calm` behavior on Pi and Claude Code and its supported presentation limits.
- [docs/voice-relay.md](docs/voice-relay.md) — the optional spoken interface: setup on both machines, measured round-trip cost, what a spoken answer may read, and what this build does not do yet.
- [docs/fleet-ledger.md](docs/fleet-ledger.md) — the opt-in activity ledger outside tools can read to follow a home's missions, and its record contract.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) — configure the active alert for an away-mode escalation delivery that gets stuck.

### Backends

- [docs/tmux-backend.md](docs/tmux-backend.md) — current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) — current setup, CI coverage, safety boundaries, and limits for the Herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) — current setup and limits for the experimental Zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) — current setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) — current setup, socket security, and limits for the experimental cmux backend.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) — the current blocked Codex App backend boundary and rollout contract.

### Verification and integrations

- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) — active maintainer verification for runtime backend guarantees.
- [docs/gerrit-forge-integration.md](docs/gerrit-forge-integration.md) — maintainer architecture for the forge axis: why change-shaped review is not a forge variant, the mode/forge/shape composition test, and where responsibility for forge mechanics sits.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) — maintainer verification for watching and merging GitLab merge requests on arbitrary instances.
- [docs/gerrit-change-watch.md](docs/gerrit-change-watch.md) — maintainer verification for watching Gerrit changes read-only, and why the merge path refuses one.
- [docs/forgejo-tea-integration.md](docs/forgejo-tea-integration.md) — maintainer verification for watching and merging Forgejo/Gitea pull requests via `tea`.
- [docs/turnend-guard.md](docs/turnend-guard.md) — the primary session's current "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/verification/supervision.md](docs/verification/supervision.md) — active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) — rendered primary-harness watcher protocols for Claude, Codex, OpenCode, Pi and `pi-signed`, omp, Grok, Cursor, and unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) — the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) — documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) — the supervision contract, role boundary, and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute, including the dev/test commands.

<p align="center"><img src="assets/brand/rule-ember.svg" width="72" alt=""></p>

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT — see [LICENSE](LICENSE). Juggernaut is a fork of [Firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen; the original MIT copyright and licence notice are preserved in [LICENSE](LICENSE).


