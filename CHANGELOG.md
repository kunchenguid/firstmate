# Changelog

Notable changes to firstmate. Format follows [Keep a Changelog](https://keepachangelog.com).

Versioning is semantic, and MAJOR is reserved for **contract** breaks that a
running fleet would notice: the `state/<id>.meta` format, configuration file
names, or a script's exit codes. MINOR adds capability, PATCH fixes behaviour.

## [1.1.1] - 2026-08-06

### Fixed

- The scheduled sprint check shipped in 1.1.0 was never reachable. Three links
  were missing: nothing invoked the poll (the watcher sweeps
  `state/*.check.sh` and no shim existed), firstmate had no rule to spawn the
  PM on a `sprint-check` wake, and the shim was hand-made so it would have been
  absent in any other home. Bootstrap now owns the shim, `AGENTS.md` owns the
  dispatch rule, and a test covers the wiring rather than only the behaviour.

## [1.1.0] - 2026-08-06

### Added

- `bin/fm-sprint-poll.sh` - a scheduled wake so the PM checks the sprint board
  without being asked. It emits a *scheduling* signal, not a content one: the
  board lives behind MCP and cannot be read outside an agent turn, so the poll
  can only say "time to look". Inert until `config/sprint-poll.env` exists, so
  the watcher is unchanged for anyone who has not opted in.
- Board skill gains the PM's rules: delegate rather than build, stay silent on
  an empty board, and route an unclear card to the captain **through firstmate**
  as a specific question rather than guessing at it.

## [1.0.0] - 2026-08-06

First numbered release. The harness was mature well before this point - 100+
scripts and several hundred tests - but carried no version at all, only a
`known-good-2026-08-03` tag, which records confidence rather than identity.

### Added

- `bin/fm-image-gen.sh` - spend-capped image generation for the designer role,
  with a dollar-denominated daily cap enforced before any billable call.
- `bin/fm-quota-dash.sh` - htop-style dashboard of provider headroom and image
  spend, over `quota-axi`.
- `bin/fm-version.sh`, `VERSION`, and this file.

### Changed

- **herdr is now the base backend.** tmux keeps only its reference role, which
  remains load-bearing: the unit-test fakes cover tmux alone.
- `fm-spawn.sh` refuses a `--backend` that contradicts a set `config/backend`,
  rather than quietly relocating a task where the captain is not looking.
- The herdr preflight checks the client/server pair, not the client alone.

### Fixed

- Two test suites read the operator's live config because `FM_CONFIG_OVERRIDE=''`
  falls through to the real home instead of isolating it.

### Contract change (why this is 1.0.0 and not 0.x)

`state/<id>.meta` now **always** records `backend=`, including tmux. Previously
its absence meant tmux, which made a task's backend a statement for five
backends and an absence for the sixth - and that asymmetry hid a real incident.
Readers still accept an absent field for metas already in flight.
