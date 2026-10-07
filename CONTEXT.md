# Context

Terms this repository uses for running Firstmate across a team.
This file defines words only; [`docs/configuration.md`](docs/configuration.md) owns how each one is configured.

## Feature switch

One named optional feature that a home can turn off as a whole, such as `secondmate` or `no-mistakes`.
A switch can only take a feature away: turning it on restores the feature, but a feature that has its own opt-in still needs that opt-in.
A switch that was never declared counts as on.

## Preset

A tracked, named set of feature-switch values that a home copies into its own configuration in one step.
There are two presets, lite and normal.

## Lite

The preset that keeps only the core fleet: dispatch, supervision, recovery, isolated worktrees, the backlog, direct pull requests, away and quiet supervision, bearings and boards, quota-aware dispatch, and project management.
Everything else is switched off.
A brand-new home starts on lite.

## Normal

The preset with every feature switch on.
A home that existed before feature switches behaves as normal.

## Team machine

A teammate's own computer running its own Firstmate home with its own harness logins and model quota.
A team machine shares Firstmate's code and the team templates, never another person's private preferences, state, or credentials.

## Team templates

The tracked starting configuration a team machine copies on install: the presets, the crew-dispatch profiles, and the project work principles.
They live in [`docs/examples/team/`](docs/examples/team/).

## Project work principles

The short team section of working rules that every team project carries in its own `AGENTS.md`.

## Engineering discipline

The short list of inner-loop working habits every ship brief hands its worker, adapted from the pstack principles.
Firstmate stays the only router; the discipline shapes how a worker works, not where work goes.
