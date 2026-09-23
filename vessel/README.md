# vessel

vessel is this fork's addition to [firstmate](https://github.com/kunchenguid/firstmate): a read-only terminal view of what firstmate's crew is doing, with Jira and GitHub alongside, in the style of Remy (hamsterdam). It also teaches firstmate Remy's workflows (implement or plan a ticket, review a PR, address feedback, resolve conflicts, describe a PR, create a ticket), run by the captain's own agents.

vessel never edits a file firstmate tracks, so the fork merges upstream cleanly. Everything it adds lives in `vessel/`, `.agents/skills/vessel-workflows/`, and `.github/workflows/vessel-sync.yml`.

## Setup

In this checkout (your firstmate home):

```sh
touch config/fleet-ledger                 # firstmate's opt-in activity ledger: run history
cargo install --path vessel               # or: cargo run --manifest-path vessel/Cargo.toml
```

Then run `claude` here as usual, and `vessel` in another terminal. vessel finds the home from `--home`, `$VESSEL_FM_HOME`, `$FM_HOME`, or the checkout it runs in.

To look around without a live fleet:

```sh
vessel/tests/demo-home.sh /tmp/vessel-demo
cargo run --manifest-path vessel/Cargo.toml -- --home /tmp/vessel-demo
```

## What it shows

- **Overview**: the crew (needs you, running, finished today, queued), your Jira tickets by feature, and your GitHub pull requests. `⚓ <task>` marks a ticket or PR the crew is working on.
- **Run** (Enter on a run): agent, harness, model, ticket and PR, the status history, the brief, the report, and the live terminal while the crewmate runs.
- **PR** and **ticket** pages: Remy's views with a **Runs** tab, plus **Plans** for tickets, including runs that finished long ago.
- **Activity** (`a`): the fleet ledger, newest first.
- **Settings** (`0`): the agents, editable, and where everything lives.

It reads firstmate only through documented contracts: `state/fleet-ledger.jsonl`, `bin/fm-fleet-snapshot.sh --json`, `bin/fm-peek.sh`, and `data/<task>/`. The only files it writes are the agent files in `config/vessel/`.

## Workflows

Ask firstmate in plain words: "review https://github.com/acme/webapp/pull/42", "plan AA4FI-1234", "implement AA4FI-1234 with Slim Charles using plan plan-aa4fi-1234", "address the unresolved feedback on acme/webapp#42". The `vessel-workflows` skill picks the agent, writes the brief from Remy's templates and the agent's instructions, spawns through `bin/fm-spawn.sh` with the agent's harness, model, and effort, and records the run in `data/vessel/runs.jsonl` so vessel can show it under the ticket and PR.

| Workflow | Default agent | firstmate task |
| --- | --- | --- |
| implement | Slim Charles | ship |
| plan | Stringer | scout (plan in `report.md`) |
| review | Snoop | scout (findings in `report.md`) |
| address | Proposition Joe | ship on the existing PR |
| conflicts | Conflict Resolver | ship on the existing PR |
| description | PR Description | scout |
| ticket | Ticket Creator | scout |

Delivery mode, merge authority, and supervision stay firstmate's. The request grammar for tools is in [docs/requests.md](docs/requests.md).

## Configuration

`config/vessel/agents.json` and `config/vessel/agents/*.md` hold the agents. They are created from `vessel/defaults/` on first run; edit them in Settings. Harnesses are firstmate's verified adapters (there is no Copilot adapter; the defaults use `pi` with `gpt-5.6-luna`).

`config/vessel/vessel.json` is optional:

```json
{
  "jira_jql": "assignee = currentUser() AND resolution = EMPTY",
  "ticket_projects": ["AA4FI"],
  "feature_projects": {"AA4FI-100": "webapp"},
  "repo_projects": {"acme/webapp": "webapp"},
  "github_enabled": true,
  "jira_enabled": true
}
```

`ticket_projects` limits which `ABC-123` words count as Jira keys in PR titles. The `*_projects` maps tell the skill which firstmate project a feature or repository belongs to.

## Staying current with firstmate

`.github/workflows/vessel-sync.yml` merges upstream into `main` every six hours, after vessel's tests pass against the new upstream. `tests/contract.rs` and the snapshot contract test fail if an upstream change breaks something vessel relies on. When that happens, the merge is parked on a `sync/failed-*` branch and `main` stays where it was. `/updatefirstmate` keeps working because `main` only ever moves forward.

Upstream merges that touch upstream's own workflow files need a `VESSEL_SYNC_TOKEN` secret (see the workflow header). By hand: `git fetch upstream && git merge upstream/main && git push`.

## Later: hotkeys

Remy's action keys (Jira `I`/`P`/`N`, PR `N`/`F`/`C`/`A`/`U`) are left unbound on purpose. They will send a `[vessel]` request through `bin/fm-inbox.sh note --request-id`, so firstmate dispatches the work through the same skill and scripts. vessel will never launch agents itself.

## Development

```sh
cargo test --manifest-path vessel/Cargo.toml
cargo fmt --check --manifest-path vessel/Cargo.toml
```
