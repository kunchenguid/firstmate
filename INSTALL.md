# Install Firstmate on a team machine (instructions for an agent)

You are installing Firstmate for a teammate on their own machine.
Work through this file top to bottom.
Every step gives a command and the result that means it passed.
If a step does not pass, stop at that step and report it; do not improvise a workaround.

**What you have when this file is done.**

- A Firstmate checkout at `~/firstmate` on the lite preset.
- Codex as the teammate's first mate, and Pi workers running on the teammate's own Codex quota.
- The team crew-dispatch profiles, so each task gets a model tier picked by task class and current quota.
- One real dispatch proving the setup works end to end.

**What you must never do.**

- Never log in for the teammate, and never read, copy, print, or write any credential, token, or key.
  Logins are the teammate's own step; when one is needed, tell them the exact command and wait.
- Never copy another person's `config/`, `data/`, `state/`, or `.env` onto this machine.
  Each machine keeps its own private files; only the tracked repository and its team templates are shared.

[`CONTEXT.md`](CONTEXT.md) defines the terms used here, and [`docs/configuration.md`](docs/configuration.md) owns every setting.

---

## 1. Preflight

Run each check before installing anything.

| Check | Command | Pass | If it fails |
| --- | --- | --- | --- |
| Git | `git --version` | a version prints | stop: install Git |
| GitHub CLI | `gh auth status` | logged in to github.com with access to the `lighthouser-agent` organization | ask the teammate to run `gh auth login`, then re-check |
| Node | `node --version` | v20 or newer | stop: install Node |
| tmux | `tmux -V` | a version prints | install with `brew install tmux` (or the platform's package manager) |
| Codex CLI | `codex --version` | a version prints | stop: install the Codex CLI, then ask the teammate to run `codex login` |
| Pi | `pi --version` | a version prints | stop: install Pi; the workers run on it |

The teammate logs Pi in to their Codex (ChatGPT) account themselves: start `pi`, run `/login`, choose the OpenAI Codex provider, then quit.

## 2. Clone

```sh
git clone https://github.com/lighthouser-agent/firstmate ~/firstmate
cd ~/firstmate
```

Pass: `git -C ~/firstmate status --short` prints nothing and `git -C ~/firstmate branch --show-current` prints `main`.
Run every later command from `~/firstmate`.

## 3. Choose the lite preset

```sh
bin/fm-features.sh preset lite
bin/fm-features.sh show
```

Pass: every switch shows `off (config/features)`.
A teammate who later needs one feature turns it back on alone, for example `bin/fm-features.sh set no-mistakes on`; `bin/fm-features.sh preset normal` turns everything on.
Do not edit `config/features` by hand.

## 4. Configure workers and dispatch

```sh
mkdir -p config
printf 'pi\n' > config/crew-harness
cp docs/examples/team/crew-dispatch.json config/crew-dispatch.json
```

Pass: `jq . config/crew-dispatch.json` prints the profiles without an error.

This template sends every task to Pi on the teammate's Codex quota and picks the model tier by task class: errand checks, moderate engineering, difficult investigation, routine implementation.
A teammate who also uses Claude Code copies `docs/examples/team/crew-dispatch.claude.json` instead, which adds the Claude candidates; they log in with `claude` themselves first.
Never invent a model name; the templates are the team's current tiers.

## 5. Install the Firstmate toolchain

```sh
npm install -g gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi
gh-axi setup hooks
chrome-devtools-axi setup hooks
lavish-axi setup hooks
curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh
```

Pass: `gh-axi --version`, `tasks-axi --version`, `quota-axi --version`, and `treehouse --version` each print a version.
The public `quota-axi` package covers Codex quota.
The team build at `github.com/lighthouser-agent/quota-axi` adds Claude cchost quota; install it only for a Claude Code teammate, and only after its version meets the floor that `bin/fm-session-start.sh` checks (a lower build reports `MISSING: quota-axi`).

## 6. First session

Start the first mate:

```sh
codex
```

On first launch, Codex asks to trust the directory and to review the project hooks in `.codex/hooks.json`; the teammate approves both themselves, because Firstmate's turn-end guard and watcher run from those hooks.
The first mate runs `bin/fm-session-start.sh` on its own.

Pass: the digest's CONTEXT section lists `Feature switches (config/features)` with every lite switch off, and its BOOTSTRAP section prints no `MISSING:` or `CREW_DISPATCH: invalid` line.
If BOOTSTRAP reports a missing tool, install it from the command the line names and start a new session.

## 7. Projects

Team projects live in the `lighthouser-agent` GitHub organization.
List them with:

```sh
gh-axi repo list lighthouser-agent --limit 100
```

Skip repositories whose names start with `older-`; they are archived predecessors.
Do not clone anything now.
Firstmate clones a project and registers it the first time the teammate asks for work on it, for example "look at lighthouser-agent/erp-cli and fix the failing test".
Each project defaults to direct pull requests with merges approved by the teammate.

When a team project's `AGENTS.md` does not yet carry the team work principles from [`docs/examples/team/project-principles.md`](docs/examples/team/project-principles.md), the first mate has its first ship on that project add them.

## 8. Verify one dispatch

Ask the first mate, in the Codex session:

> Scout lighthouser-agent/firstmate: summarize what bin/fm-features.sh does and list its switches.

Pass, all of these:

- A tmux window opens for the worker and runs Pi.
- The first mate reports the scout's findings in chat within a few minutes, naming the eight switches.
- `bin/fm-tasks-axi.sh list` shows the task moved to done.

If the worker stops at a Pi trust prompt or a login screen, the teammate answers it in that window and the first mate resumes.

## 9. Updating

Ask the first mate to update itself (`$updatefirstmate` in Codex).
It fast-forwards this checkout from `main`; local `config/`, `data/`, and `state/` stay as they are.
Re-run `bin/fm-features.sh show` after an update to see any newly added switch, which starts on.
