# gex CI runner - reference copies

Verbatim copies of the files that run the self-hosted GitHub Actions runners on
gex44. The operating manual is [`../../gex-ci-laeufer.md`](../../gex-ci-laeufer.md);
the per-repo migration is [`../../gex-ci-uebergabe-phase2.md`](../../gex-ci-uebergabe-phase2.md).

These are host-specific operations material for one machine, not fleet tooling,
which is why they live here and not under `bin/`.

| File | Installed on | Path |
|---|---|---|
| `Containerfile` | gex | `/home/ghrunner/image/Containerfile` |
| `entrypoint.sh` | gex (inside the image) | `/usr/local/bin/entrypoint.sh` |
| `gh-runner-supervise.sh` | gex | `/opt/gh-runner/supervise.sh` |
| `gh-runner.slice` | gex | `~ghrunner/.config/systemd/user/gh-runner.slice` |
| `gh-runner@.service` | gex | `~ghrunner/.config/systemd/user/gh-runner@.service` |
| `gh-runner-token-relay.sh` | captain's laptop | `~/.local/bin/gh-runner-token-relay.sh` |
| `gh-runner-token-relay.service` | captain's laptop | `~/.config/systemd/user/` |
| `gh-runner-token-relay.timer` | captain's laptop | `~/.config/systemd/user/` |

Editing a copy here does not change the running system; re-deploy it to the
path above and restart the affected unit.
