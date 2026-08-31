# firstmate

Firstmate is a local coordinator for Ross' project work.

It coordinates visible local crewmates in isolated worktrees, records durable fleet state, and uses a local tmux watcher to surface work that needs attention.

## Product boundary

- tmux is the only supported runtime backend.
- Local secondmates are supported.
- Remote secondmates, Relay, and non-tmux backends are intentionally out of scope for this fork.
- Validation evidence supports recommendations but does not authorize sensitive actions.

Sensitive actions need Ross' explicit direction, including spawning work, pushing, creating or merging a pull request, applying local changes to a primary checkout, discarding work, using credentials, and spending money.

## Quick start

Install Git, the GitHub CLI, tmux, and one supported primary harness.

```sh
git clone <fork-url>
cd firstmate
tmux new -s firstmate
```

Start the primary harness inside the tmux session.

The repository instructions in [AGENTS.md](AGENTS.md) define the operating contract.

## How it works

Firstmate reads project clones and maintains private backlog, brief, and state records.

Each crewmate runs in its own tmux window and isolated worktree.

The local watcher records durable wakes, and the primary reconciles those wakes before taking further action.

Local secondmates have their own isolated Firstmate homes and tmux sessions.

## Documentation

- [docs/configuration.md](docs/configuration.md) - local configuration, state formats, and toolchain requirements.
- [docs/architecture.md](docs/architecture.md) - maintainer architecture for local supervision, secondmates, and lifecycle boundaries.
- [docs/tmux-backend.md](docs/tmux-backend.md) - tmux setup, current behavior, and verification entry points.
- [docs/scripts.md](docs/scripts.md) - the local `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - maintained documentation audience boundaries.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active tmux verification evidence.
- [CONTRIBUTING.md](CONTRIBUTING.md) - contributor workflow and validation commands.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for normal branch and pull request workflow.

## License

MIT - see [LICENSE](LICENSE).
