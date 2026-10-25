<div align="center">

<h1><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/logo-dark.svg">
  <img src="docs/media/logo-light.svg" width="40" height="40" align="top" alt="Firstmate add-ons logo">
</picture> Firstmate add-ons</h1>

**Keep your coding-agent fleet moving through stalled tasks, depleted quota, and destructive commands.**

Independent add-ons for developers running a fleet on their own machine. They live in this repository's `addons/` directory.

[Quick start](#quick-start) · [Add-on reference](docs/addons-reference.md) · [Roadmap](VISION.md)

</div>

## Quick start

Install the memory gate so heavy jobs wait for free RAM instead of wedging the machine.
From the repository root:

```sh
bash addons/host-memory/install.sh
```

That copies the gate into your user data directory and registers a systemd user timer for heavy-job adoption.
Preview without writing by adding `--dry-run` after the script name.
Git and Bash are required; the install uses a systemd user service.
[Setup details and other add-ons](docs/addons-reference.md#install).

## Why the add-ons

| When you manage it by hand | With the matching add-on |
| --- | --- |
| Watch host memory before every heavy job | A memory gate waits for headroom before starting work. |
| Check whether ready work has stopped moving | Fleet-stall alerts on idle leads and workers waiting on them. |
| Watch allowed pull requests until checks finish | Merge-on-green checks CI and proof receipts before merging. |
| Scan separate task status files | The dashboard groups lanes, stuck work, waiting tasks, and queue reasons. |

Install each add-on independently and remove it independently.
Choose the job you need first; the reference lists the full catalog and dependencies.

## Choose your job

Run these from the repository root.
For home-specific installers, export `FM_HOME` pointing to your existing Firstmate home: the directory containing its `bin/`, `config/`, and `state/`.
Each job names one starting add-on.

**Protect the machine** — [Memory gate](host-memory/install.sh); also delete, kill, and read guards.

```sh
bash addons/host-memory/install.sh
```

**Keep work moving** — [Stall alerts](docs/addons-reference.md#fleet-stall); also quota recovery and account routing.

```sh
bash addons/fleet-stall/install.sh
```

**Ship checked work** — [Merge-on-green](docs/addons-reference.md#merge-on-green); also merge cards and identity checks.

```sh
bash \
  addons/merge-on-green/install.sh \
  "$FM_HOME"
```

**Understand the fleet** — [Flow check](fleet-flow/install.sh); also dashboard, metrics, and ticket sync.

```sh
bash addons/fleet-flow/install.sh
```

These are entry points, not install-all bundles.
Preview an install by putting `--dry-run` immediately after the script name.
The [reference](docs/addons-reference.md) covers hooks, platform requirements, removal, and the additional add-ons in each job.

## Proof you can inspect

The [pull-request CI workflow](.github/workflows/addons-ci.yml) runs shell checks and executable integration journeys against disposable homes.
For example, [the memory-gate journey](host-memory/tests/fm-mem-gate.test.sh) exercises waiting and release under changing memory readings without starting a heavy job.
The [Lookout Overview hero journey](docs/capture-lookout-hero.sh) captures phone and desktop views from a live Lookout (or from lookout-adapter into a Lookout clone).

## Setup and limits

Install from the GitHub clone; add-on installers are under `addons/`, and there is no install-all command.
Some add-ons need fork-side hooks or remain dormant copies; check [FORK-EXIT.md](FORK-EXIT.md) before choosing one.
Installers can change hooks, configuration, or user services; read the selected add-on's setup before applying it.

- [Full catalog, installation, checks, and removal](docs/addons-reference.md)
- [Fork dependencies and exit paths](FORK-EXIT.md)
- [Product direction](VISION.md)
- [Contributor verification journeys](.agents/skills/done-done-verify-firstmate-addons/SKILL.md)
