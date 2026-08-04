# Provider outage continuity verification

Audience: maintainer verification.

This record holds reusable evidence for the active provider-continuity guarantees.
[`docs/configuration.md`](../configuration.md) "Provider outage continuity" owns current behavior and the operator path, `bin/fm-provider-continuity.sh`'s header owns the commands and tunables, and [`provider-outage-continuity`](../../.agents/skills/provider-outage-continuity/SKILL.md) owns the operator reasoning.
Task chronology, branch names, and delivery transcripts stay in private reports or PR evidence.

Verified 2026-08-04 on macOS 26.5.2 arm64 with GNU bash 3.2.57(1), git 2.50.1 (Apple Git-155), jq 1.7.1-apple, and ShellCheck 0.11.0.

## Classification and qualification

`FM_CONTINUITY_NOW` pins the clock, so every verdict below is reproducible with no waiting and no provider contact.

```sh
export FM_STATE_OVERRIDE=<state>
FM_CONTINUITY_NOW=1000 bin/fm-provider-continuity.sh record vendor-a provider-5xx --detail 'retry-exhausted 503'
FM_CONTINUITY_NOW=1000 bin/fm-provider-continuity.sh record vendor-a quota
FM_CONTINUITY_NOW=1100 bin/fm-provider-continuity.sh record vendor-a provider-connection
FM_CONTINUITY_NOW=1200 bin/fm-provider-continuity.sh record vendor-a provider-stream
```

Observed output:

```text
provider: vendor-a · state: eligible · qualifying: 1/3 · last: 1000 · until: none · non-qualifying: none
provider: vendor-a · state: eligible · qualifying: 1/3 · last: 1000 · until: none · non-qualifying: quota=1
provider: vendor-a · state: eligible · qualifying: 2/3 · last: 1100 · until: none · non-qualifying: quota=1
provider: vendor-a · state: unavailable · qualifying: 3/3 · last: 1200 · until: 3000 · non-qualifying: quota=1
```

One qualifying observation left the provider eligible, and the interleaved quota observation was counted separately and never advanced the qualifying total.

## Deterministic cooldown expiry

```sh
FM_CONTINUITY_NOW=1200 bin/fm-provider-continuity.sh eligible vendor-a   # exit 1: unavailable until 3000
FM_CONTINUITY_NOW=2999 bin/fm-provider-continuity.sh eligible vendor-a   # exit 1: unavailable until 3000
FM_CONTINUITY_NOW=3000 bin/fm-provider-continuity.sh eligible vendor-a   # exit 0: eligible
```

Eligibility returns exactly at `newest qualifying observation + FM_CONTINUITY_COOLDOWN_SECS`, from the recorded evidence alone, with no timer and no extra state.

## Tiered selection

```sh
FM_CONTINUITY_NOW=1200 bin/fm-provider-continuity.sh filter --fallback vendor-b vendor-a
```

Observed output, exit status `0`:

```text
vendor-a excluded outage until 3000 (primary)
vendor-b eligible fallback
```

With the primary tier available the same command prints `fallback: not consulted (primary tier available)`, so a configured outage fallback can never act as a second quota choice.

## Harness and runtime-backend applicability

Every axis below was inspected rather than assumed.

The harness axis is uniform for both new surfaces.
`bin/fm-provider-continuity.sh` never launches or inspects a harness: it reads recorded observations, `state/<id>.meta`, the recorded endpoint's own backend state, and `bin/fm-crew-state.sh`.
`--resume-worktree` changes only which command enters the isolated copy (`cd <path>` instead of `treehouse get`) and leaves `launch_template()`, the model and effort flag builders, and every per-harness hook installation untouched, so `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `kimi` all reach the same launch construction on a resume as on a fresh spawn.
Adapter verification itself is unchanged: `bin/fm-spawn.sh` still refuses an unverified adapter during a resume, so continuity can never introduce one.

| Backend | `--resume-worktree` | Inspection that established it |
|---|---|---|
| tmux | applicable | Session-provider only, with treehouse owning the worktree. `fm_backend_tmux_current_path` backs the settle poll and `fm_backend_tmux_kill` backs the abort cleanup. Covered by `tests/fm-provider-continuity.test.sh`. |
| herdr | applicable | Session-provider only, same treehouse worktree. `fm_backend_herdr_current_path` and `fm_backend_herdr_kill` exist, and the abort path defers to the existing presentation cleanup whenever it owns the panes, so the two cleanups never both act. |
| zellij | applicable | Session-provider only, same treehouse worktree, with `fm_backend_zellij_current_path` and `fm_backend_zellij_kill` present. |
| cmux | applicable | Session-provider only, same treehouse worktree, with `fm_backend_cmux_current_path` and `fm_backend_cmux_kill` present. |
| orca | not applicable, refused | Orca provides both the worktree and the terminal, so ship and scout spawns skip the worktree-entry block entirely and `spawn_current_path` has no Orca branch to settle against. An Orca worktree is addressed by the recorded `orca_worktree_id=` rather than by path, so reuse needs Orca-side resume semantics that do not exist. The flag is refused before any tool probe so the reported blocker is the real one. |

The handoff license reuses `fm_backend_agent_state`, whose own recovery-grade classifier is verified for tmux and herdr and reports `unverified` elsewhere.
`unverified` is not `dead` or `missing`, so a handoff is refused rather than licensed on a backend with no classifier, which is the intended conservative default.
The same conservatism applies to the current-state axis: a readable `unknown` verdict may license a handoff, while a verdict that could not be read at all refuses, because an unreadable read proves nothing about validation ownership.

## Regression coverage

`tests/fm-provider-continuity.test.sh` drives both public interfaces with no provider contact: classification and qualification, burst separation, non-qualifying classes, quota kept separate, deterministic cooldown expiry, single-provider exclusion, tiered fallback consultation, review independence and deferral, unconfigured-home behavior, refusal of unclassified evidence and unsafe tokens, the handoff license across present, working, parked, missing, and unreadable evidence, the repeated-attempt cap, same-copy resume with preserved branch, commits, and dirty files, the split-copy refusal, record and endpoint recovery after a failed relaunch, the shape refusals, retained backend and delivery validation, and an unchanged ordinary spawn.
`tests/fm-bootstrap.test.sh` owns validation of the `provider`, `fallback`, `default_fallback`, and `independent` schema fields.
`tests/fm-spawn-dispatch-profile.test.sh` continues to own spawn's profile resolution and harness refusals, which the resume path leaves unchanged.
