# Kimi Code

Verified on 2026-09-17 with Kimi Code CLI 2.0.0; workspace trust re-verified on 2026-09-19 against 2.0.1 with the single-record helper.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute executable resolved from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | Observed default `kimi-code/kimi-for-coding`, `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`; use `kimi provider list --json` for current configuration. |
| Busy state | Standalone Kimi is unknown pending a live-verified semantic source, preferring Wire's `prompt` lifetime then documented hooks including `Interrupt`; Kimi behind Pi uses Pi lifecycle, and the moon-phase spinner is never a state source. |
| Exit command | `/exit`. |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Firstmate skills are discovered. |
| Autonomy | `--auto` is the `Never Ask` tier; `-y` and `--yolo` now select the distinct, weaker `Ask When Needed` tier and are not used. |
| Trust dialog | A fresh worktree shows `Trust this folder?` with `Trust this folder` pre-selected, whether or not the folder has any project MCP configuration, because Kimi trusts each exact root separately and never inherits trust from a parent; `../../../bin/fm-spawn.sh` pre-registers every crewmate or scout worktree in Kimi's own per-root store `~/.kimi-code/workspace-trust/` through `../../../bin/fm-kimi-trust.sh` before launch and refuses the spawn when that fails, so the dialog does not render; the live answer described under Readiness-gated start remains the backstop for a dialog that renders anyway, and its diagnostic then names the two trust causes - the record was not honoured, or the pane read a different store - rather than reporting a delivery drop. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; identity comes from process ancestry command name `kimi`, which `../../../bin/fm-harness.sh` keeps a retained foreign marker from overriding. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | `kimi provider list --json` exposes per-model `supportEfforts` values `low`, `high`, and `max` plus a `defaultEffort`; the launch flag and mapping remain unverified, so spawn records and omits requested effort per `references/common/model-and-effort.md`. |

## Readiness-gated start

`../../../bin/fm-spawn.sh` pre-registers the worktree in Kimi's trust store (see Workspace trust below), launches Kimi bare, answers the complete 2.0.0 trust dialog as a backstop if it renders anyway, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
Every trust predicate reads `fm_backend_visible_capture` - the viewport with no scrollback - never the 120-line history read the delivery gate uses: the dialog is a TUI frame, and a history-backed capture would keep reporting it after Kimi redrew past it, storming Enter into a live composer and then failing an already trusted spawn. That primitive is implemented on tmux (`capture-pane -p -S -0`), herdr (`pane read <pane> --source visible`, verified against Herdr 0.8.0 in `docs/verification/runtime-backends.md`) and zellij (`action dump-screen --pane-id`, no `--full`), and `FM_BACKEND_VISIBLE_CAPTURE` in `bin/fm-backend.sh` is the one list of them. orca has only a history read; cmux's `read-screen` without `--scrollback` plausibly reads just the viewport but has not been live-verified. A Kimi spawn on either is therefore refused at preflight, before the worktree or pane exists, naming the backend and the missing verified viewport capability, pending that verification for cmux. There is no fallback to the scrollback read. A viewport read that exits nonzero fails readiness immediately with the backend named, rather than being mistaken for a blank screen. A successful but blank viewport read is absence of evidence, not evidence of a cleared dialog: it costs that poll, restarts the two-capture ready count below, and leaves the trust diagnostics where they were. The trust answer is retried until the dialog clears - Kimi swallows keypresses during its startup window, so a single Enter can be dropped - and the re-send is gated on the complete dialog still being on that visible pane, so it cannot fire once the dialog cleared. Trust is accepted only after a later visible-pane capture proves that the dialog cleared; a stuck dialog fails with the observed dialog signals and the answer count in the diagnostic.
Any single marker of the dialog on that visible pane - `Trust this folder` or the negative `Don't trust` option - withholds the ready verdict, because a capture caught mid-redraw and a capture that has painted only the box title both miss the complete dialog while the banner above it would otherwise read as ready. The banner also prints before the dialog paints at all, which no single capture can distinguish from a ready pane, so the verdict additionally requires two consecutive captures that are each ready and free of dialog text; a capture that is not ready, and a blank one, restarts that count, which is what keeps the pre-banner boot captures and redraw frames from spending it.
This launch-then-send shape is mandatory because Kimi rejects positional instructions as an unknown command.
The path must be absolute because the instructions live outside the task worktree and Kimi reads them there without `--add-dir`.

On 2026-09-19 three consecutive dispatches on this machine, two ordinary spawns and one relaunch, failed as `kimi brief pointer delivery was not confirmed` and `kimi did not show a verified ready signal before brief delivery`, and each was recorded as an unreliable-delivery quirk.
That attribution was wrong, and it is what kept the real cause hidden for three attempts: a single Escape sent to a failed pane cleared the composer and revealed the folder-trust dialog underneath, so the pointer had been typed in front of a dialog Kimi never cleared and the brief was never reachable.
The cause is the trust gate and the fix is the pre-registration under Workspace trust below; `../../../docs/verification/runtime-backends.md` owns the dated evidence.
Kimi does still swallow keypresses during its startup window, which is why delivery keeps retrying Enter through the shared submit core and keeps its postcondition verification, but that window is a retry hazard, not the cause of a pane that never accepts the pointer.
An early Enter can expand the composer to multiple content rows, leaving pointer text on the first row and the cursor on an empty later row.
The shared tmux reader therefore locates the complete bordered composer and treats real text on any content row as positive evidence that submission remains pending.
No rendering signal proves Kimi will accept input during this window, so delivery retries Enter through the shared submit core and retains the postcondition verification rather than relaxing readiness.

Observed spinner captures had optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, including during tool execution.
The delivery-only matcher requires the observed whitespace, deliberately excludes the unobserved zero-whitespace form, and does not require trailing tip text.
Kimi's footer tip can show `ctrl+c: cancel` while idle, and its idle bar can contain lowercase `thinking` as an effort label.
Neither is a busy-state source.
The delivery-only spinner match covers the full moon-phase glyph set but remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

## Workspace trust

Kimi trusts each exact working directory separately: the lookup hashes the pane's physical working directory and never walks ancestors, so the captain's already trusted home did nothing for the worktrees beneath it and every task worktree needs its own record.
The store is `${KIMI_CODE_HOME:-$HOME/.kimi-code}/workspace-trust/`, one `wd_<slug>_<hash>` file per trusted root, and `../../../bin/fm-kimi-trust.sh`'s header is the one owner of the name derivation, the record body, the modes, and the refusal set.
`../../../bin/fm-spawn.sh` calls it for every crewmate or scout kimi launch at the same point it pre-registers claude trust, and a failed registration refuses the spawn rather than launching a worker that would wedge.
No launch flag suppresses the dialog: `kimi --help` lists none, and `--auto` is a permission tier.
The spawn does not forward `KIMI_CODE_HOME` onto the launch, so a pane whose shell carries a different value reads a different store and meets the dialog; the live backstop then answers it.
A kimi secondmate is not pre-registered: the helper has only the worktree shape, so such a pane still meets the dialog and still depends on that live backstop, and closing the gap needs a `--secondmate-home` mode like the claude helper's.
`../../../tests/fm-kimi-trust-live-e2e.test.sh` (`FM_KIMI_TRUST_LIVE=1`) is the guard that refreshes this fact against the installed Kimi: an unregistered fresh worktree must park on the dialog and a pre-registered one must reach its brief.

## Crew turn-end hook and primary limit

Kimi is outside the primary turn-end guard scope.
`../../../docs/turnend-guard.md` owns its separate global hook surface and captain-approved crew wake integration.

`../../../bin/fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi worker worktree receives a gitignored `.fm-kimi-turnend` pointer.
The global hook touches `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding it did not fire.
The guarded turn-end signal remains a wake notification.
Standalone Kimi has no busy-state source until one is live-verified.
